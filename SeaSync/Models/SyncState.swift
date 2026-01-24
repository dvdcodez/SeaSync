import Foundation

struct SyncState: Codable {
    let libraryId: String
    var files: [SyncedFile]
    var lastSyncTime: Date

    init(libraryId: String) {
        self.libraryId = libraryId
        self.files = []
        self.lastSyncTime = Date()
    }
}

struct SyncedFile: Codable, Hashable {
    let path: String
    let objectId: String
    let mtime: Int64
    let size: Int64
    let isDirectory: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: SyncedFile, rhs: SyncedFile) -> Bool {
        lhs.path == rhs.path
    }
}

enum SyncAction: CustomStringConvertible {
    case download(remotePath: String, localPath: URL)
    case upload(localPath: URL, remotePath: String)
    case deleteLocal(localPath: URL)
    case deleteRemote(remotePath: String)
    case createDirectory(localPath: URL)
    case conflict(localPath: URL, remotePath: String)

    var path: String? {
        switch self {
        case .download(let remotePath, _): return remotePath
        case .upload(let localPath, _): return localPath.lastPathComponent
        case .deleteLocal(let localPath): return localPath.lastPathComponent
        case .deleteRemote(let remotePath): return remotePath
        case .createDirectory(let localPath): return localPath.lastPathComponent
        case .conflict(_, let remotePath): return remotePath
        }
    }

    var description: String {
        switch self {
        case .download(let remotePath, _): return "download(\(remotePath))"
        case .upload(let localPath, _): return "upload(\(localPath.lastPathComponent))"
        case .deleteLocal(let localPath): return "deleteLocal(\(localPath.lastPathComponent))"
        case .deleteRemote(let remotePath): return "deleteRemote(\(remotePath))"
        case .createDirectory(let localPath): return "createDir(\(localPath.lastPathComponent))"
        case .conflict(_, let remotePath): return "conflict(\(remotePath))"
        }
    }
}

struct SyncStats {
    var totalFiles: Int = 0
    var totalDirectories: Int = 0
    var totalSize: Int64 = 0
    var libraryCount: Int = 0
    var libraryLastSync: [String: Date] = [:]
    var oldestSync: Date?
    var newestSync: Date?

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

// MARK: - Download Progress Tracking

enum DownloadStatus: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

struct DownloadProgress: Codable, Identifiable {
    let id: Int64
    let libraryId: String
    let remotePath: String
    let objectId: String
    let mtime: Int64
    let size: Int64
    let status: DownloadStatus
    let startedAt: Date?
    let completedAt: Date?
    let errorMessage: String?

    init(
        id: Int64 = 0,
        libraryId: String,
        remotePath: String,
        objectId: String,
        mtime: Int64,
        size: Int64,
        status: DownloadStatus = .pending,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.libraryId = libraryId
        self.remotePath = remotePath
        self.objectId = objectId
        self.mtime = mtime
        self.size = size
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

// MARK: - Persisted Error

struct PersistedSyncError: Codable, Identifiable {
    let id: Int64
    let timestamp: Date
    let message: String
    let libraryName: String?
    let filePath: String?
    let errorType: String

    init(
        id: Int64 = 0,
        timestamp: Date = Date(),
        message: String,
        libraryName: String? = nil,
        filePath: String? = nil,
        errorType: String = "sync"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.libraryName = libraryName
        self.filePath = filePath
        self.errorType = errorType
    }
}
