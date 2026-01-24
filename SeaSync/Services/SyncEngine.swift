import Foundation

@MainActor
class SyncEngine {
    private let account: Account
    private let libraryService: LibraryService
    private let fileService: FileService
    private weak var appState: AppState?

    private var isSyncing = false
    private var isPaused = false
    private var shouldStop = false

    init(account: Account, appState: AppState) {
        self.account = account
        self.appState = appState
        self.libraryService = LibraryService(account: account)
        self.fileService = FileService(account: account)
    }

    // MARK: - Sync Control

    func pause() {
        guard isSyncing else { return }
        isPaused = true
        appState?.syncStatus = .paused
        log("Sync paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        appState?.syncStatus = .syncing
        log("Sync resumed")
    }

    func stop() {
        shouldStop = true
        isPaused = false
        log("Sync stop requested")
    }

    var isSyncActive: Bool { isSyncing }
    var isSyncPaused: Bool { isPaused }

    // MARK: - Full Sync

    func performFullSync() async {
        guard !isSyncing else {
            log("Sync already in progress, skipping")
            return
        }
        isSyncing = true
        log("Starting full sync")

        // Mark sync as in progress for crash detection
        SyncDatabase.shared.setSyncInProgress(true)

        // CRITICAL: Always reset state when done, even on errors
        defer {
            isSyncing = false
            isPaused = false
            shouldStop = false
            SyncDatabase.shared.setSyncInProgress(false)
            log("Sync finished, state reset")
        }

        appState?.syncStatus = .syncing
        appState?.currentOperation = "Starting sync..."
        appState?.resetProgress()
        var hadErrors = false

        do {
            // Get all libraries
            appState?.currentOperation = "Fetching libraries..."
            let libraries = try await libraryService.listLibraries()
            appState?.libraries = libraries
            log("Got \(libraries.count) libraries, starting sync")

            // Sync each library (continue even if one fails)
            for (index, library) in libraries.enumerated() {
                appState?.currentOperation = "Syncing \(library.name)..."
                appState?.syncProgress = Double(index) / Double(libraries.count)
                log("Syncing library: \(library.name) (\(index + 1)/\(libraries.count))")

                // Track which library is being synced for crash recovery
                SyncDatabase.shared.setLastSyncLibrary(library.id)

                do {
                    try await syncLibrary(library)
                } catch {
                    log("Error syncing library \(library.name): \(error)")
                    hadErrors = true

                    // Add to in-memory errors
                    appState?.errors.append(SyncError(
                        message: error.localizedDescription,
                        timestamp: Date(),
                        libraryName: library.name,
                        filePath: nil
                    ))

                    // Persist error to database
                    SyncDatabase.shared.saveError(PersistedSyncError(
                        message: error.localizedDescription,
                        libraryName: library.name,
                        filePath: nil,
                        errorType: "sync"
                    ))
                    // Continue with next library
                }
            }

            SyncDatabase.shared.setLastSyncLibrary(nil)
            appState?.syncStatus = hadErrors ? .error : .idle
            appState?.lastSyncTime = Date()
            appState?.currentOperation = ""
            appState?.syncProgress = 1.0
            log("Full sync completed \(hadErrors ? "with errors" : "successfully")")

        } catch {
            log("Sync error: \(error)")
            appState?.syncStatus = .error

            // Add to in-memory errors
            appState?.errors.append(SyncError(
                message: error.localizedDescription,
                timestamp: Date(),
                libraryName: nil,
                filePath: nil
            ))

            // Persist error to database
            SyncDatabase.shared.saveError(PersistedSyncError(
                message: error.localizedDescription,
                libraryName: nil,
                filePath: nil,
                errorType: "sync"
            ))
        }
    }

    // MARK: - Library Sync

    private func syncLibrary(_ library: Library) async throws {
        log("syncLibrary: \(library.name), encrypted=\(library.encrypted)")

        // Handle encrypted libraries
        if library.encrypted {
            try await handleEncryptedLibrary(library)
        }

        // Ensure local directory exists
        log("Creating local path: \(library.localPath.path)")
        try FileManager.default.createDirectory(
            at: library.localPath,
            withIntermediateDirectories: true
        )

        // Get remote files (using parallel fetch for better performance)
        log("Listing remote files for library \(library.id)")
        appState?.currentOperation = "Scanning \(library.name)..."
        let remoteFiles = try await fileService.listAllFilesParallel(libraryId: library.id)
        log("Got \(remoteFiles.count) remote files")

        // Get local files
        let localFiles = scanLocalDirectory(library.localPath, basePath: library.localPath)

        // Get last sync state
        let lastSyncState = SyncDatabase.shared.getSyncState(for: library.id)
        let lastSyncedFiles = Set(lastSyncState?.files ?? [])

        // Build current state sets
        let remotePathSet = Set(remoteFiles.map { $0.fullPath })
        let localPathSet = Set(localFiles.keys)

        // Build a map of remote files for quick lookup
        let remoteFileMap = Dictionary(uniqueKeysWithValues: remoteFiles.map { ($0.fullPath, $0) })

        // Calculate sync actions
        var actions: [SyncAction] = []

        // Check for incomplete downloads from previous run
        let incompleteDownloads = SyncDatabase.shared.getIncompleteDownloads(libraryId: library.id)
        var resumedCount = 0

        for incomplete in incompleteDownloads {
            // Check if file still needs download (remote still has it, local doesn't)
            if let remoteEntry = remoteFileMap[incomplete.remotePath] {
                if !localFiles.keys.contains(incomplete.remotePath) {
                    // Still need to download this file
                    let localPath = library.localPath.appendingPathComponent(
                        String(incomplete.remotePath.dropFirst())
                    )
                    actions.append(.download(remotePath: incomplete.remotePath, localPath: localPath))
                    resumedCount += 1
                } else {
                    // File exists locally now - check if it matches the expected version
                    if let localMtime = localFiles[incomplete.remotePath], localMtime >= remoteEntry.file.mtime {
                        // Already completed somehow, mark as done
                        SyncDatabase.shared.markDownloadCompleted(libraryId: library.id, remotePath: incomplete.remotePath)
                    }
                }
            } else {
                // Remote file no longer exists, clear the progress entry
                SyncDatabase.shared.markDownloadCompleted(libraryId: library.id, remotePath: incomplete.remotePath)
            }
        }

        if resumedCount > 0 {
            log("Resuming \(resumedCount) incomplete downloads from previous sync")
        }

        // Track paths we're already handling from resume
        let resumingPaths = Set(incompleteDownloads.map { $0.remotePath })

        // 1. Download new/updated files from server
        for entry in remoteFiles {
            let remotePath = entry.fullPath

            // Skip if we're already resuming this file
            if resumingPaths.contains(remotePath) {
                continue
            }

            let localPath = library.localPath.appendingPathComponent(
                String(remotePath.dropFirst()) // Remove leading "/"
            )

            if entry.file.isDirectory {
                // Create directory if it doesn't exist
                if !FileManager.default.fileExists(atPath: localPath.path) {
                    actions.append(.createDirectory(localPath: localPath))
                }
            } else {
                // Check if file was already completed in a previous interrupted sync
                if SyncDatabase.shared.isFileCompleted(libraryId: library.id, path: remotePath, mtime: entry.file.mtime) {
                    // Skip - we already downloaded this exact version
                    continue
                }

                // Check if file needs download
                if let localMtime = localFiles[remotePath] {
                    if entry.file.mtime > localMtime {
                        actions.append(.download(remotePath: remotePath, localPath: localPath))
                    }
                } else {
                    actions.append(.download(remotePath: remotePath, localPath: localPath))
                }
            }
        }

        // 2. Upload new/updated files to server
        for (localPath, localMtime) in localFiles {
            if let remoteEntry = remoteFiles.first(where: { $0.fullPath == localPath }) {
                // File exists on server - check if local is newer
                if !remoteEntry.file.isDirectory && localMtime > remoteEntry.file.mtime {
                    let fullLocalPath = library.localPath.appendingPathComponent(
                        String(localPath.dropFirst())
                    )
                    actions.append(.upload(localPath: fullLocalPath, remotePath: localPath))
                }
            } else {
                // File doesn't exist on server - upload it
                let fullLocalPath = library.localPath.appendingPathComponent(
                    String(localPath.dropFirst())
                )

                // Check if it's a directory
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullLocalPath.path, isDirectory: &isDir)

                if !isDir.boolValue {
                    actions.append(.upload(localPath: fullLocalPath, remotePath: localPath))
                }
            }
        }

        // 3. Handle deletions (bidirectional)
        for syncedFile in lastSyncedFiles {
            let inRemote = remotePathSet.contains(syncedFile.path)
            let inLocal = localPathSet.contains(syncedFile.path)

            if !inRemote && inLocal {
                // Deleted on server → delete locally
                let localPath = library.localPath.appendingPathComponent(
                    String(syncedFile.path.dropFirst())
                )
                actions.append(.deleteLocal(localPath: localPath))
            } else if !inLocal && inRemote {
                // Deleted locally → delete on server
                actions.append(.deleteRemote(remotePath: syncedFile.path))
            }
        }

        // Count actions by type for progress tracking
        let downloads = actions.filter { if case .download = $0 { return true }; return false }.count
        let uploads = actions.filter { if case .upload = $0 { return true }; return false }.count
        let deletes = actions.filter {
            if case .deleteLocal = $0 { return true }
            if case .deleteRemote = $0 { return true }
            return false
        }.count

        appState?.totalDownloads += downloads
        appState?.totalUploads += uploads
        appState?.totalDeletes += deletes

        log("Actions: \(downloads) downloads, \(uploads) uploads, \(deletes) deletes")

        // Register pending downloads in the progress table
        for action in actions {
            if case .download(let remotePath, _) = action {
                if let entry = remoteFileMap[remotePath] {
                    SyncDatabase.shared.addPendingDownload(
                        libraryId: library.id,
                        remotePath: remotePath,
                        objectId: entry.file.id,
                        mtime: entry.file.mtime,
                        size: entry.file.size ?? 0
                    )
                }
            }
        }

        // Execute actions with streaming parallelism - always keep maxConcurrent tasks running
        let maxConcurrent = 8
        var failedActions = 0
        var nextActionIndex = 0
        let fileService = self.fileService
        let libraryId = library.id
        let totalActions = actions.count

        log("Starting to execute \(totalActions) actions with \(maxConcurrent) parallel workers...")

        // Track active files for display in menu
        var activeFileNames: [String] = []

        // Batch counters - only push to UI periodically
        var pendingDownloads = 0
        var pendingUploads = 0
        var pendingDeletes = 0

        func updateUI() {
            // Update all UI state at once
            appState?.activeFiles = activeFileNames
            appState?.completedDownloads += pendingDownloads
            appState?.completedUploads += pendingUploads
            appState?.completedDeletes += pendingDeletes
            pendingDownloads = 0
            pendingUploads = 0
            pendingDeletes = 0
        }

        func addActiveFile(_ name: String) {
            activeFileNames.append(name)
            updateUI()
        }

        func removeActiveFile(_ name: String) {
            activeFileNames.removeAll { $0 == name }
            updateUI()
        }

        await withTaskGroup(of: (Int, SyncAction, String, Error?).self) { group in
            // Start initial batch
            while nextActionIndex < min(maxConcurrent, totalActions) {
                let index = nextActionIndex
                let action = actions[index]
                let fileName = action.path ?? "file"
                nextActionIndex += 1
                addActiveFile(fileName)

                group.addTask {
                    // Mark download as in progress
                    if case .download(let remotePath, _) = action {
                        await MainActor.run {
                            SyncDatabase.shared.markDownloadInProgress(libraryId: libraryId, remotePath: remotePath)
                        }
                    }

                    let error = await self.executeFileOperation(action, fileService: fileService, libraryId: libraryId)
                    return (index, action, fileName, error)
                }
            }

            // Process results as they complete, immediately starting new tasks
            for await (index, action, fileName, error) in group {
                removeActiveFile(fileName)

                // Update download progress in database
                if case .download(let remotePath, _) = action {
                    if let error = error {
                        SyncDatabase.shared.markDownloadFailed(libraryId: libraryId, remotePath: remotePath, errorMessage: error.localizedDescription)
                    } else {
                        SyncDatabase.shared.markDownloadCompleted(libraryId: libraryId, remotePath: remotePath)
                    }
                }

                // Update UI immediately when each task completes
                if let error = error {
                    failedActions += 1
                    log("Action \(index + 1) failed: \(action) - \(error.localizedDescription)")

                    // Add to in-memory errors
                    appState?.errors.append(SyncError(
                        message: error.localizedDescription,
                        timestamp: Date(),
                        libraryName: library.name,
                        filePath: action.path
                    ))

                    // Persist error to database
                    SyncDatabase.shared.saveError(PersistedSyncError(
                        message: error.localizedDescription,
                        libraryName: library.name,
                        filePath: action.path,
                        errorType: "sync"
                    ))
                }

                // Update progress counters (batched)
                switch action {
                case .download:
                    pendingDownloads += 1
                case .upload:
                    pendingUploads += 1
                case .deleteLocal, .deleteRemote:
                    pendingDeletes += 1
                default:
                    break
                }

                // Check for stop request
                if shouldStop {
                    log("Sync stopped by user")
                    group.cancelAll()
                    break
                }

                // Wait while paused
                while isPaused && !shouldStop {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                // Start next task immediately if there are more
                if nextActionIndex < totalActions && !shouldStop {
                    let nextIndex = nextActionIndex
                    let nextAction = actions[nextIndex]
                    let nextFileName = nextAction.path ?? "file"
                    nextActionIndex += 1
                    addActiveFile(nextFileName)

                    group.addTask {
                        // Mark download as in progress
                        if case .download(let remotePath, _) = nextAction {
                            await MainActor.run {
                                SyncDatabase.shared.markDownloadInProgress(libraryId: libraryId, remotePath: remotePath)
                            }
                        }

                        let error = await self.executeFileOperation(nextAction, fileService: fileService, libraryId: libraryId)
                        return (nextIndex, nextAction, nextFileName, error)
                    }
                }

                // Update UI periodically (throttled to reduce flickering)
                updateUI()

                // Log progress periodically
                let completed = (appState?.completedDownloads ?? 0) + pendingDownloads +
                               (appState?.completedUploads ?? 0) + pendingUploads +
                               (appState?.completedDeletes ?? 0) + pendingDeletes
                if completed % 50 == 0 {
                    log("Progress: \(completed)/\(totalActions) actions completed")
                }
            }
        }

        // Flush pending counters when done
        updateUI()

        if failedActions > 0 {
            log("\(failedActions) actions failed out of \(actions.count)")
        }

        // Save new sync state
        var newState = SyncState(libraryId: library.id)
        newState.files = remoteFiles.map { entry in
            SyncedFile(
                path: entry.fullPath,
                objectId: entry.file.id,
                mtime: entry.file.mtime,
                size: entry.file.size ?? 0,
                isDirectory: entry.file.isDirectory
            )
        }
        SyncDatabase.shared.saveSyncState(newState)

        // Clear completed downloads after successful sync
        SyncDatabase.shared.clearCompletedDownloads(libraryId: library.id)
    }

    // MARK: - Execute Actions

    /// Execute a file operation off the main actor for true parallelism
    nonisolated private func executeFileOperation(_ action: SyncAction, fileService: FileService, libraryId: String) async -> Error? {
        do {
            switch action {
            case .download(let remotePath, let localPath):
                try await fileService.downloadFile(
                    libraryId: libraryId,
                    remotePath: remotePath,
                    to: localPath
                )
            case .upload(let localPath, let remotePath):
                try await fileService.uploadFile(
                    libraryId: libraryId,
                    localPath: localPath,
                    remotePath: remotePath
                )
            case .deleteLocal(let localPath):
                try? FileManager.default.removeItem(at: localPath)
            case .deleteRemote(let remotePath):
                try await fileService.deleteFile(libraryId: libraryId, path: remotePath)
            case .createDirectory(let localPath):
                try FileManager.default.createDirectory(
                    at: localPath,
                    withIntermediateDirectories: true
                )
            case .conflict:
                break
            }
            return nil
        } catch {
            return error
        }
    }

    private func executeAction(_ action: SyncAction, library: Library) async throws {
        switch action {
        case .download(let remotePath, let localPath):
            appState?.currentOperation = "Downloading \(remotePath)..."
            try await fileService.downloadFile(
                libraryId: library.id,
                remotePath: remotePath,
                to: localPath
            )

        case .upload(let localPath, let remotePath):
            appState?.currentOperation = "Uploading \(localPath.lastPathComponent)..."
            try await fileService.uploadFile(
                libraryId: library.id,
                localPath: localPath,
                remotePath: remotePath
            )

        case .deleteLocal(let localPath):
            appState?.currentOperation = "Deleting \(localPath.lastPathComponent)..."
            try? FileManager.default.removeItem(at: localPath)

        case .deleteRemote(let remotePath):
            appState?.currentOperation = "Deleting \(remotePath) from server..."
            try await fileService.deleteFile(libraryId: library.id, path: remotePath)

        case .createDirectory(let localPath):
            try FileManager.default.createDirectory(
                at: localPath,
                withIntermediateDirectories: true
            )

        case .conflict(let localPath, let remotePath):
            // For now, use last-modified-wins (already handled above)
            print("Conflict: \(localPath) vs \(remotePath)")
        }
    }

    // MARK: - Helpers

    private func scanLocalDirectory(_ dirURL: URL, basePath: URL) -> [String: Int64] {
        var files: [String: Int64] = [:]

        guard let enumerator = FileManager.default.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        for case let fileURL as URL in enumerator {
            let relativePath = "/" + fileURL.path.replacingOccurrences(
                of: basePath.path + "/",
                with: ""
            )

            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate {
                files[relativePath] = Int64(modDate.timeIntervalSince1970)
            }
        }

        return files
    }

    private func handleEncryptedLibrary(_ library: Library) async throws {
        // Check if we have a stored password
        if let password = try KeychainManager.shared.loadLibraryPassword(libraryId: library.id) {
            try await libraryService.setLibraryPassword(id: library.id, password: password)
        } else {
            // Need to prompt for password - this should be handled by UI
            throw SyncEngineError.encryptedLibraryNeedsPassword(library.name)
        }
    }

    // MARK: - Single File Operations

    func uploadSingleFile(localPath: URL, library: Library) async throws {
        let basePath = library.localPath.path
        let relativePath = "/" + localPath.path.replacingOccurrences(of: basePath + "/", with: "")

        try await fileService.uploadFile(
            libraryId: library.id,
            localPath: localPath,
            remotePath: relativePath
        )
    }

    func deleteSingleFile(localPath: URL, library: Library) async throws {
        let basePath = library.localPath.path
        let relativePath = "/" + localPath.path.replacingOccurrences(of: basePath + "/", with: "")

        try await fileService.deleteFile(libraryId: library.id, path: relativePath)
    }
}

// MARK: - Errors

enum SyncEngineError: LocalizedError {
    case encryptedLibraryNeedsPassword(String)
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .encryptedLibraryNeedsPassword(let name):
            return "Library '\(name)' is encrypted and needs a password"
        case .syncInProgress:
            return "Sync is already in progress"
        }
    }
}
