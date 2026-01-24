import Foundation

class FileService {
    private let account: Account

    // URLSession with longer timeout for large file transfers
    private lazy var transferSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 minutes
        config.timeoutIntervalForResource = 3600  // 1 hour for large files
        return URLSession(configuration: config)
    }()

    init(account: Account) {
        self.account = account
    }

    // MARK: - Directory Listing

    func listDirectory(libraryId: String, path: String = "/") async throws -> [SeafFile] {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path

        // Note: Seafile API returns all files in one response, pagination params are ignored
        let url = account.apiURL("api2/repos/\(libraryId)/dir/?p=\(encodedPath)")
        log("listDirectory: \(path)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log("listDirectory: invalid response")
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            log("listDirectory error: \(body)")
            throw APIError.serverError(httpResponse.statusCode)
        }

        do {
            let files = try JSONDecoder().decode([SeafFile].self, from: data)
            log("listDirectory: \(path) -> \(files.count) files")
            return files
        } catch {
            log("listDirectory decode error: \(error)")
            throw error
        }
    }

    func listAllFiles(libraryId: String, path: String = "/") async throws -> [DirectoryEntry] {
        var allFiles: [DirectoryEntry] = []

        let files = try await listDirectory(libraryId: libraryId, path: path)

        for file in files {
            let entry = DirectoryEntry(path: path, file: file)
            allFiles.append(entry)

            if file.isDirectory {
                let subPath = path == "/" ? "/\(file.name)" : "\(path)/\(file.name)"
                let subFiles = try await listAllFiles(libraryId: libraryId, path: subPath)
                allFiles.append(contentsOf: subFiles)
            }
        }

        return allFiles
    }

    /// Parallel version of listAllFiles using TaskGroup for better performance
    func listAllFilesParallel(libraryId: String) async throws -> [DirectoryEntry] {
        // Actor for thread-safe collection of results
        actor FileCollector {
            var files: [DirectoryEntry] = []
            var pendingDirs: [String] = ["/"]
            var activeCount = 0

            func addFiles(_ entries: [DirectoryEntry]) {
                files.append(contentsOf: entries)
            }

            func addDirs(_ dirs: [String]) {
                pendingDirs.append(contentsOf: dirs)
            }

            func nextDir() -> String? {
                guard !pendingDirs.isEmpty else { return nil }
                activeCount += 1
                return pendingDirs.removeFirst()
            }

            func finished() {
                activeCount -= 1
            }

            func isDone() -> Bool {
                pendingDirs.isEmpty && activeCount == 0
            }

            func getAll() -> [DirectoryEntry] {
                files
            }

            func getProgress() -> (dirs: Int, files: Int) {
                (pendingDirs.count + activeCount, files.count)
            }
        }

        let collector = FileCollector()
        let maxConcurrent = 6  // Limit parallel API calls to avoid overwhelming server

        log("listAllFilesParallel: starting parallel fetch for library \(libraryId)")

        while await !collector.isDone() {
            try await withThrowingTaskGroup(of: ([DirectoryEntry], [String]).self) { group in
                // Launch up to maxConcurrent parallel directory fetches
                for _ in 0..<maxConcurrent {
                    guard let dir = await collector.nextDir() else { break }

                    group.addTask {
                        let files = try await self.listDirectory(libraryId: libraryId, path: dir)
                        var entries: [DirectoryEntry] = []
                        var subdirs: [String] = []

                        for file in files {
                            entries.append(DirectoryEntry(path: dir, file: file))
                            if file.isDirectory {
                                let subPath = dir == "/" ? "/\(file.name)" : "\(dir)/\(file.name)"
                                subdirs.append(subPath)
                            }
                        }
                        return (entries, subdirs)
                    }
                }

                // Collect results from all tasks in this batch
                for try await (entries, subdirs) in group {
                    await collector.addFiles(entries)
                    await collector.addDirs(subdirs)
                    await collector.finished()
                }
            }

            let progress = await collector.getProgress()
            log("listAllFilesParallel: \(progress.files) files found, \(progress.dirs) dirs pending")
        }

        let allFiles = await collector.getAll()
        log("listAllFilesParallel: completed with \(allFiles.count) total files")
        return allFiles
    }

    // MARK: - Download

    func getDownloadLink(libraryId: String, path: String) async throws -> URL {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = account.apiURL("api2/repos/\(libraryId)/file/?p=\(encodedPath)&reuse=1")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        // Response is a quoted URL string
        var urlString = String(data: data, encoding: .utf8) ?? ""
        urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard let downloadURL = URL(string: urlString) else {
            throw APIError.invalidResponse
        }

        return downloadURL
    }

    func downloadFile(libraryId: String, remotePath: String, to localPath: URL) async throws {
        log("downloadFile: getting link for \(remotePath)")
        let downloadURL = try await getDownloadLink(libraryId: libraryId, path: remotePath)
        log("downloadFile: starting download from \(downloadURL)")

        let (tempURL, response) = try await transferSession.download(from: downloadURL)
        log("downloadFile: download complete, checking response")

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Create parent directory if needed
        let parentDir = localPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        log("downloadFile: moving to \(localPath.path)")

        // Remove existing file if any
        try? FileManager.default.removeItem(at: localPath)

        // Move downloaded file to destination
        try FileManager.default.moveItem(at: tempURL, to: localPath)
    }

    // MARK: - Upload

    func getUploadLink(libraryId: String, path: String = "/") async throws -> URL {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = account.apiURL("api2/repos/\(libraryId)/upload-link/?p=\(encodedPath)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        var urlString = String(data: data, encoding: .utf8) ?? ""
        urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard let uploadURL = URL(string: urlString) else {
            throw APIError.invalidResponse
        }

        return uploadURL
    }

    func uploadFile(libraryId: String, localPath: URL, remotePath: String) async throws {
        log("uploadFile: \(localPath.path) -> \(remotePath)")
        let parentDir = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent

        let uploadURL = try await getUploadLink(libraryId: libraryId, path: parentDir.isEmpty ? "/" : parentDir)
        log("uploadFile: got upload link \(uploadURL)")

        // Create multipart form data
        let boundary = UUID().uuidString
        var body = Data()

        // Add parent_dir field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"parent_dir\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(parentDir.isEmpty ? "/" : parentDir)\r\n".data(using: .utf8)!)

        // Add replace field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"replace\"\r\n\r\n".data(using: .utf8)!)
        body.append("1\r\n".data(using: .utf8)!)

        // Add file
        let fileData = try Data(contentsOf: localPath)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            log("uploadFile: failed with status \(httpResponse.statusCode)")
            if httpResponse.statusCode == 443 {
                throw APIError.quotaExceeded
            }
            throw APIError.serverError(httpResponse.statusCode)
        }
        log("uploadFile: success")
    }

    // MARK: - Delete

    func deleteFile(libraryId: String, path: String) async throws {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = account.apiURL("api2/repos/\(libraryId)/file/?p=\(encodedPath)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }
    }

    func deleteDirectory(libraryId: String, path: String) async throws {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = account.apiURL("api2/repos/\(libraryId)/dir/?p=\(encodedPath)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Create Directory

    func createDirectory(libraryId: String, path: String) async throws {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = account.apiURL("api2/repos/\(libraryId)/dir/?p=\(encodedPath)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "operation=mkdir"
        request.httpBody = body.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}
