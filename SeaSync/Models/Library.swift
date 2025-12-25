import Foundation

struct Library: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let size: Int64
    let mtime: Int64
    let encrypted: Bool
    let permission: String
    let owner: String?
    let ownerName: String?
    let virtual: Bool?

    var localPath: URL {
        URL(fileURLWithPath: SyncConfig.localSyncPath)
            .appendingPathComponent(name)
    }

    var isReadOnly: Bool {
        permission == "r"
    }

    var lastModified: Date {
        Date(timeIntervalSince1970: TimeInterval(mtime))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case size
        case mtime
        case encrypted
        case permission
        case owner
        case ownerName = "owner_name"
        case virtual
    }
}

// API response wrapper for listing repos
struct LibraryListResponse: Codable {
    let repos: [Library]?

    init(from decoder: Decoder) throws {
        // The API returns an array directly, not wrapped
        let container = try decoder.singleValueContainer()
        repos = try container.decode([Library].self)
    }
}
