import Foundation

class LibraryService {
    private let account: Account

    init(account: Account) {
        self.account = account
    }

    func listLibraries() async throws -> [Library] {
        let url = account.apiURL("api2/repos/")

        log("Fetching libraries from: \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log("Invalid response type")
            throw APIError.invalidResponse
        }

        log("Response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            log("Error response: \(body)")
            throw APIError.serverError(httpResponse.statusCode)
        }

        log("Response body: \(String(data: data, encoding: .utf8) ?? "nil")")

        do {
            let libraries = try JSONDecoder().decode([Library].self, from: data)
            log("Found \(libraries.count) libraries")
            return libraries
        } catch {
            log("JSON decode error: \(error)")
            throw error
        }
    }

    func getLibrary(id: String) async throws -> Library {
        let url = account.apiURL("api2/repos/\(id)/")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Library.self, from: data)
    }

    func setLibraryPassword(id: String, password: String) async throws {
        let url = account.apiURL("api2/repos/\(id)/")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "password=\(password.urlEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 400 {
                throw APIError.incorrectPassword
            }
            throw APIError.serverError(httpResponse.statusCode)
        }
    }
}

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidResponse
    case serverError(Int)
    case incorrectPassword
    case notFound
    case permissionDenied
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .incorrectPassword:
            return "Incorrect library password"
        case .notFound:
            return "Resource not found"
        case .permissionDenied:
            return "Permission denied"
        case .quotaExceeded:
            return "Storage quota exceeded"
        }
    }
}
