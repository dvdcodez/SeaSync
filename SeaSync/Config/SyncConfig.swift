import Foundation

struct SyncConfig {
    // Local sync path on external drive
    static let localSyncPath = "/Volumes/Normal stor/Seafile"

    // Sync interval in seconds (5 minutes)
    static let syncIntervalSeconds = 300

    // Conflict resolution strategy
    static let conflictStrategy: ConflictStrategy = .lastModifiedWins

    // File change debounce (wait for writes to finish)
    static let fileChangeDebounceSeconds: Double = 2.0

    // Maximum concurrent downloads/uploads
    static let maxConcurrentTransfers = 4

    // Chunk size for large file uploads (5MB)
    static let uploadChunkSize = 5 * 1024 * 1024

    // Database file location
    static var databasePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let seaSyncDir = appSupport.appendingPathComponent("SeaSync")
        try? FileManager.default.createDirectory(at: seaSyncDir, withIntermediateDirectories: true)
        return seaSyncDir.appendingPathComponent("sync_state.sqlite")
    }

    // Keychain service identifier
    static let keychainService = "com.seasync.credentials"
}

enum ConflictStrategy {
    case lastModifiedWins
    case keepBoth
    case serverWins
    case localWins
}
