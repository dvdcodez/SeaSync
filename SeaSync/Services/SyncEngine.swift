import Foundation

@MainActor
class SyncEngine {
    private let account: Account
    private let libraryService: LibraryService
    private let fileService: FileService
    private weak var appState: AppState?

    private var isSyncing = false

    init(account: Account, appState: AppState) {
        self.account = account
        self.appState = appState
        self.libraryService = LibraryService(account: account)
        self.fileService = FileService(account: account)
    }

    // MARK: - Full Sync

    func performFullSync() async {
        guard !isSyncing else {
            log("Sync already in progress, skipping")
            return
        }
        isSyncing = true
        log("Starting full sync")

        appState?.syncStatus = .syncing
        appState?.currentOperation = "Starting sync..."

        do {
            // Get all libraries
            appState?.currentOperation = "Fetching libraries..."
            let libraries = try await libraryService.listLibraries()
            appState?.libraries = libraries
            log("Got \(libraries.count) libraries, starting sync")

            // Sync each library
            for (index, library) in libraries.enumerated() {
                appState?.currentOperation = "Syncing \(library.name)..."
                appState?.syncProgress = Double(index) / Double(libraries.count)
                log("Syncing library: \(library.name) (\(index + 1)/\(libraries.count))")

                try await syncLibrary(library)
            }

            appState?.syncStatus = .idle
            appState?.lastSyncTime = Date()
            appState?.currentOperation = ""
            appState?.syncProgress = 1.0
            log("Full sync completed successfully")

        } catch {
            log("Sync error: \(error)")
            appState?.syncStatus = .error
            appState?.errors.append(SyncError(
                message: error.localizedDescription,
                timestamp: Date(),
                libraryName: nil,
                filePath: nil
            ))
        }

        isSyncing = false
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

        // Get remote files
        log("Listing remote files for library \(library.id)")
        let remoteFiles = try await fileService.listAllFiles(libraryId: library.id)
        log("Got \(remoteFiles.count) remote files")

        // Get local files
        let localFiles = scanLocalDirectory(library.localPath, basePath: library.localPath)

        // Get last sync state
        let lastSyncState = SyncDatabase.shared.getSyncState(for: library.id)
        let lastSyncedFiles = Set(lastSyncState?.files ?? [])

        // Build current state sets
        let remotePathSet = Set(remoteFiles.map { $0.fullPath })
        let localPathSet = Set(localFiles.keys)

        // Calculate sync actions
        var actions: [SyncAction] = []

        // 1. Download new/updated files from server
        for entry in remoteFiles {
            let remotePath = entry.fullPath
            let localPath = library.localPath.appendingPathComponent(
                String(remotePath.dropFirst()) // Remove leading "/"
            )

            if entry.file.isDirectory {
                // Create directory if it doesn't exist
                if !FileManager.default.fileExists(atPath: localPath.path) {
                    actions.append(.createDirectory(localPath: localPath))
                }
            } else {
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

        // Execute actions
        for action in actions {
            try await executeAction(action, library: library)
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
    }

    // MARK: - Execute Actions

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
