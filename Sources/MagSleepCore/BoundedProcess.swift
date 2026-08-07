import Darwin
import Foundation

/// Result of a bounded subprocess run.
public struct BoundedProcessResult {
    public let terminationStatus: Int32
    public let stdout: Data
    public let stderr: Data
    /// True when the process had to be terminated (and possibly SIGKILLed)
    /// because it exceeded `timeout`.
    public let timedOut: Bool
}

/// Runs a subprocess with a **bounded wait** and a **bounded output drain**, so
/// a hung or chatty child can never leak a thread or deadlock a pipe. This is
/// the single shared implementation of the pattern previously hand-copied in
/// the app's privileged-script runner and the daemon's sun-schedule fetch.
/// Call it from a background queue; it blocks the calling thread (bounded).
public enum BoundedProcess {
    public static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently, bounded by the same deadline, so a
        // hang or a grandchild that inherits a write end can never block a
        // reader forever (readDataToEndOfFile would wait for EOF indefinitely).
        var stdoutBox = Data()
        var stderrBox = Data()
        let queue = DispatchQueue(label: "magsleep.bounded-process")
        let deadline = Date().addingTimeInterval(timeout)
        queue.async { drain(stdoutPipe, into: &stdoutBox, until: deadline) }
        queue.async { drain(stderrPipe, into: &stderrBox, until: deadline) }

        // Bounded wait with SIGTERM → SIGKILL escalation; the termination
        // handler is armed before run() so its signal can never be missed.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            return BoundedProcessResult(terminationStatus: -1, stdout: Data(), stderr: Data(), timedOut: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }

        // Guarantee EOF for the readers (the process is gone, but our
        // references to the write ends would otherwise keep them blocked).
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        queue.sync {}

        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutBox,
            stderr: stderrBox,
            timedOut: timedOut
        )
    }

    private static func drain(_ pipe: Pipe, into data: inout Data, until deadline: Date) {
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
    }
}
