import Darwin
import Foundation

/// Watch both the directory and its files.
/// Claude Code writes session files in place without changing the directory mtime, so directory-only watching misses updates.
@MainActor
final class DirectoryWatcher {
    private let directories: [URL]
    private let debounce: Duration
    private let onChange: @MainActor () -> Void

    private var directorySources: [String: any DispatchSourceFileSystemObject] = [:]
    private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    private var pendingNotify: Task<Void, Never>?

    init(directories: [URL], debounce: Duration = .milliseconds(200), onChange: @escaping @MainActor () -> Void) {
        self.directories = directories
        self.debounce = debounce
        self.onChange = onChange
        rescan()
    }

    /// Reattach watchers for recreated directories/new files and remove watchers for deleted files.
    func rescan() {
        var present: Set<String> = []
        for directory in directories {
            let path = directory.path
            if directorySources[path] == nil, let source = makeSource(path: path, mask: [.write, .delete, .rename, .link], isDirectory: true) {
                directorySources[path] = source
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            // Ignore companion .key files to avoid doubling open descriptors; state lives only in .json.
            for name in names where !name.hasPrefix(".") {
                let url = directory.appendingPathComponent(name)
                if url.pathExtension == "json" { present.insert(url.path) }
            }
        }
        for path in present where fileSources[path] == nil {
            if let source = makeSource(path: path, mask: [.write, .extend, .attrib, .delete, .rename], isDirectory: false) {
                fileSources[path] = source
            }
        }
        for (path, source) in fileSources where !present.contains(path) {
            source.cancel()
            fileSources[path] = nil
        }
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent, isDirectory: Bool) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleEvent(path: path, isDirectory: isDirectory, flags: source.data)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func handleEvent(path: String, isDirectory: Bool, flags: DispatchSource.FileSystemEvent) {
        // Deleted or renamed descriptors no longer identify the same path; reopen them.
        if !flags.isDisjoint(with: [.delete, .rename]) {
            if isDirectory {
                directorySources.removeValue(forKey: path)?.cancel()
            } else {
                fileSources.removeValue(forKey: path)?.cancel()
            }
        }
        if isDirectory || !flags.isDisjoint(with: [.delete, .rename]) {
            rescan()
        }
        scheduleNotify()
    }

    /// Coalesce write and attribute notifications from one save before refreshing.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        pendingNotify = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.onChange()
        }
    }
}
