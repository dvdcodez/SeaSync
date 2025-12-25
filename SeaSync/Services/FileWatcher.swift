import Foundation

class FileWatcher {
    private let syncPath: String
    private weak var appState: AppState?

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceTimer: Timer?
    private var pendingChanges: Set<URL> = []

    init(syncPath: String, appState: AppState) {
        self.syncPath = syncPath
        self.appState = appState
    }

    deinit {
        stop()
    }

    func start() {
        guard FileManager.default.fileExists(atPath: syncPath) else {
            print("FileWatcher: Sync path does not exist: \(syncPath)")
            return
        }

        fileDescriptor = open(syncPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("FileWatcher: Failed to open file descriptor for: \(syncPath)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: DispatchQueue.global(qos: .utility)
        )

        source?.setEventHandler { [weak self] in
            self?.handleFileSystemEvent()
        }

        source?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        source?.resume()
        print("FileWatcher: Started watching \(syncPath)")
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil

        source?.cancel()
        source = nil

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        print("FileWatcher: Stopped")
    }

    private func handleFileSystemEvent() {
        // Debounce: wait for writes to finish before triggering sync
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: SyncConfig.fileChangeDebounceSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.triggerSync()
            }
        }
    }

    private func triggerSync() {
        Task { @MainActor in
            await appState?.triggerManualSync()
        }
    }
}

// MARK: - Advanced File Watcher using FSEvents (for recursive watching)

class FSEventWatcher {
    private let paths: [String]
    private weak var appState: AppState?

    private var stream: FSEventStreamRef?
    private var debounceTimer: Timer?

    init(paths: [String], appState: AppState) {
        self.paths = paths
        self.appState = appState
    }

    deinit {
        stop()
    }

    func start() {
        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallbackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let info = clientCallbackInfo else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvents(numEvents: numEvents, paths: eventPaths, flags: eventFlags)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream = stream else {
            print("FSEventWatcher: Failed to create stream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        print("FSEventWatcher: Started watching \(paths)")
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil

        print("FSEventWatcher: Stopped")
    }

    private func handleEvents(numEvents: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }

        for i in 0..<numEvents {
            let path = pathArray[i]
            let flag = flags[i]

            // Skip hidden files
            if path.contains("/.") {
                continue
            }

            // Check what type of event
            let isFile = (flag & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
            let isDir = (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
            let created = (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            let modified = (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            let renamed = (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0

            print("FSEvent: \(path) - file:\(isFile) dir:\(isDir) created:\(created) removed:\(removed) modified:\(modified) renamed:\(renamed)")
        }

        // Debounce
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: SyncConfig.fileChangeDebounceSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.triggerSync()
            }
        }
    }

    private func triggerSync() {
        Task { @MainActor in
            await appState?.triggerManualSync()
        }
    }
}
