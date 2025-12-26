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
