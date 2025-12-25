import Foundation

struct Account: Codable {
    let serverURL: String
    let username: String
    var token: String

    var baseURL: URL {
        URL(string: serverURL)!
    }

    func apiURL(_ endpoint: String) -> URL {
        // Don't use appendingPathComponent as it encodes ? and other query chars
        var urlString = serverURL
        if !urlString.hasSuffix("/") {
            urlString += "/"
        }
        urlString += endpoint
        return URL(string: urlString)!
    }
}
