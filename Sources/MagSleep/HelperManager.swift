import AppKit
import Foundation
import MagSleepCore
import ServiceManagement

/// Installs, enables, disables, and removes the privileged helper daemon.
final class HelperManager {
    private(set) var isInstalled = false
    private(set) var isLoaded = false
    var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: MagSleep.helperPlistPath)
            && fm.fileExists(atPath: MagSleep.helperBinaryPath)
        isLoaded = isInstalled && isLaunchDaemonLoaded()
    }

    var statusTitle: String {
        if isLoaded { return "Status: Enabled" }
        if isInstalled { return "Status: Disabled" }
        return "Status: Helper not installed"
    }

    private func isLaunchDaemonLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(MagSleep.helperLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func enable(completion: @escaping (Bool) -> Void) {
        runPrivilegedScript(named: "install-helper.sh", completion: completion)
    }

    func disable(completion: @escaping (Bool) -> Void) {
        runPrivilegedScript(named: "disable-helper.sh", completion: completion)
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        runPrivilegedScript(named: "uninstall-helper.sh") { [weak self] success in
            if success {
                try? SMAppService.mainApp.unregister()
            }
            self?.refresh()
            completion(success)
        }
    }

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private func runPrivilegedScript(named scriptName: String,
                                     completion: @escaping (Bool) -> Void) {
        guard let scriptPath = Bundle.main.path(forResource: scriptName, ofType: nil),
              let resourcePath = Bundle.main.resourcePath else {
            lastError = "Helper resources missing; run the built MagSleep.app bundle."
            completion(false)
            return
        }
        let userName = NSUserName()
        let command = [scriptPath, resourcePath, userName]
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        let escaped = "/bin/bash \(command)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            DispatchQueue.main.async {
                self.refresh()
                if result == nil {
                    let message = errorInfo?[NSAppleScript.errorMessage] as? String
                    let code = errorInfo?[NSAppleScript.errorNumber] as? Int
                    self.lastError = code == -128 ? nil : (message ?? "Helper script failed.")
                    completion(false)
                } else {
                    self.lastError = nil
                    completion(true)
                }
            }
        }
    }
}
