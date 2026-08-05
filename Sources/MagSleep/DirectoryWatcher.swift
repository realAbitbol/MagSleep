import Foundation

/// Watches a directory (via a kqueue dispatch source) and invokes a handler
/// when its contents change. Re-arms automatically if the directory is deleted
/// and recreated. If the directory does not exist yet, it retries on every
/// `start()` call.
final class DirectoryWatcher {
    private let path: String
    private let handler: () -> Void

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(path: String, handler: @escaping () -> Void) {
        self.path = path
        self.handler = handler
    }

    /// Starts (or re-arms) the watch. Idempotent while already armed.
    func start() {
        guard source == nil else { return }
        arm()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func arm() {
        let newFD = open(path, O_EVTONLY)
        guard newFD >= 0 else { return } // directory does not exist yet
        fd = newFD
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        src.setCancelHandler { [weak self] in
            close(newFD)
            if self?.fd == newFD {
                self?.fd = -1
            }
        }
        src.resume()
        source = src
    }

    private func handleEvent() {
        // If the watched inode no longer matches the live path (directory
        // deleted and recreated), re-arm so events keep flowing.
        var watched = stat()
        if fstat(fd, &watched) == 0 {
            var current = stat()
            if stat(path, &current) == 0,
               current.st_dev == watched.st_dev,
               current.st_ino == watched.st_ino {
                handler()
                return
            }
        }
        // The watched inode no longer matches the path (deleted, or deleted
        // and recreated). Tear down the old watch first so its fd/source
        // cannot leak or keep firing stale events, then re-arm against the
        // live path. If the directory is gone, arm() fails silently and the
        // timer-driven start() call retries later.
        source?.cancel()
        source = nil
        fd = -1
        arm()
        handler()
    }
}
