import Darwin
import Foundation

/// 감시 디렉터리와 그 안의 파일을 함께 지켜본다.
/// Claude Code 는 세션 파일을 제자리에서 고쳐 써서(실측: 파일 수정 뒤에도 디렉터리 수정 시각이 그대로) 디렉터리만 보면 상태 변화를 놓친다
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

    /// 사라졌다 다시 생긴 디렉터리와 새 파일에 감시를 붙이고, 없어진 파일의 감시는 뗀다
    func rescan() {
        var present: Set<String> = []
        for directory in directories {
            let path = directory.path
            if directorySources[path] == nil, let source = makeSource(path: path, mask: [.write, .delete, .rename, .link], isDirectory: true) {
                directorySources[path] = source
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            // 세션마다 `.key` 파일이 함께 있어 모두 열면 fd 가 두 배가 된다. 상태는 `.json` 에만 쓰인다
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
        // 지워지거나 이름이 바뀐 대상의 fd 는 더 이상 같은 경로를 가리키지 않아 새로 열어야 한다
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

    /// 한 번 저장에 쓰기·속성 변경 알림이 여러 개 오므로 짧게 모아 한 번만 갱신을 요청한다
    private func scheduleNotify() {
        pendingNotify?.cancel()
        pendingNotify = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.onChange()
        }
    }
}
