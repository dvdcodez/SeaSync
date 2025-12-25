import Foundation

struct SeafFile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: FileType
    let size: Int64?
    let mtime: Int64

    var isDirectory: Bool {
        type == .directory
    }

    var lastModified: Date {
        Date(timeIntervalSince1970: TimeInterval(mtime))
    }

    enum FileType: String, Codable {
        case file
        case directory = "dir"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case size
        case mtime
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }

    static func == (lhs: SeafFile, rhs: SeafFile) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

struct SeafFileDetail: Codable {
    let id: String
    let mtime: Int64
    let type: String
    let name: String
    let size: Int64
}

struct DirectoryEntry: Codable {
    let path: String
    let file: SeafFile

    var fullPath: String {
        if path == "/" {
            return "/\(file.name)"
        }
        return "\(path)/\(file.name)"
    }
}
