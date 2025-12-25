import Foundation

class AuthService {
    private let serverURL: String

    init(serverURL: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func login(username: String, password: String) async throws -> String {
        let url = URL(string: "\(serverURL)/api2/auth-token/")!

        log("Logging in to: \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(username.urlEncoded)&password=\(password.urlEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log("Login: Invalid response type")
            throw AuthError.invalidResponse
        }

        log("Login response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            log("Login error: \(body)")
            if httpResponse.statusCode == 400 {
                throw AuthError.invalidCredentials
            }
            throw AuthError.serverError(httpResponse.statusCode)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        log("Login successful, got token")
        return tokenResponse.token
    }

    func ping(token: String) async throws -> Bool {
        let url = URL(string: "\(serverURL)/api2/auth/ping/")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }

        let responseString = String(data: data, encoding: .utf8)
        return responseString?.contains("pong") == true
    }
}

// MARK: - Response Types

struct TokenResponse: Codable {
    let token: String
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidCredentials
    case invalidResponse
    case serverError(Int)
    case twoFactorRequired

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid username or password"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code):
            return "Server error: \(code)"
        case .twoFactorRequired:
            return "Two-factor authentication required"
        }
    }
}

// MARK: - String Extension

extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
