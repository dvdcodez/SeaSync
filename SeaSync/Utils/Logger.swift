import Foundation

class Logger {
    static let shared = Logger()
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.seasync.logger")
    private let maxLogAgeDays = 7

    private init() {
        // Use Application Support directory for persistent logs
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let seaSyncDir = appSupport.appendingPathComponent("SeaSync")
        try? FileManager.default.createDirectory(at: seaSyncDir, withIntermediateDirectories: true)
        logFileURL = seaSyncDir.appendingPathComponent("seasync.log")

        // Rotate old logs on startup (keep last 7 days)
        rotateLogsIfNeeded()

        log("SeaSync started")
    }

    /// Rotate logs - keep only the last 7 days of entries
    private func rotateLogsIfNeeded() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }

        do {
            let content = try String(contentsOf: logFileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxLogAgeDays, to: Date())!
            let isoFormatter = ISO8601DateFormatter()

            var recentLines: [String] = []
            for line in lines {
                // Extract timestamp from log line format: [2024-01-23T10:30:00Z] message
                if line.starts(with: "["),
                   let endIndex = line.firstIndex(of: "]"),
                   let dateString = String(line[line.index(after: line.startIndex)..<endIndex]).components(separatedBy: " ").first,
                   let logDate = isoFormatter.date(from: dateString) {
                    if logDate >= cutoffDate {
                        recentLines.append(line)
                    }
                } else if !line.isEmpty {
                    // Keep lines we can't parse (might be continuation lines)
                    recentLines.append(line)
                }
            }

            // Only rewrite if we removed some lines
            if recentLines.count < lines.count {
                let newContent = recentLines.joined(separator: "\n")
                try newContent.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // If rotation fails, just continue - don't block startup
            print("Log rotation failed: \(error)")
        }
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"

        queue.async {
            if let data = logMessage.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? logMessage.write(to: self.logFileURL, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Get the log file path for debugging
    var logFilePath: String {
        logFileURL.path
    }
}

func log(_ message: String) {
    Logger.shared.log(message)
}
