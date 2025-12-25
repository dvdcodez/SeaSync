import Foundation

class Logger {
    static let shared = Logger()
    private let logFile = "/tmp/seasync.log"
    private let queue = DispatchQueue(label: "com.seasync.logger")

    private init() {
        // Clear log on startup
        try? "".write(toFile: logFile, atomically: true, encoding: .utf8)
        log("SeaSync started")
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"

        queue.async {
            if let data = logMessage.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFile) {
                    if let handle = FileHandle(forWritingAtPath: self.logFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? logMessage.write(toFile: self.logFile, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

func log(_ message: String) {
    Logger.shared.log(message)
}
