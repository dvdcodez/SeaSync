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

enum SyncAction {
    case download(remotePath: String, localPath: URL)
    case upload(localPath: URL, remotePath: String)
    case deleteLocal(localPath: URL)
    case deleteRemote(remotePath: String)
    case createDirectory(localPath: URL)
    case conflict(localPath: URL, remotePath: String)
}
