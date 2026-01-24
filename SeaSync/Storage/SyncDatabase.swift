import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to make a copy of the string
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class SyncDatabase {
    static let shared = SyncDatabase()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let path = SyncConfig.databasePath.path

        if sqlite3_open(path, &db) != SQLITE_OK {
            print("Error opening database: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func createTables() {
        let createSyncStateTable = """
            CREATE TABLE IF NOT EXISTS sync_state (
                library_id TEXT PRIMARY KEY,
                last_sync_time INTEGER
            );
        """

        let createFilesTable = """
            CREATE TABLE IF NOT EXISTS synced_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                library_id TEXT NOT NULL,
                path TEXT NOT NULL,
                object_id TEXT NOT NULL,
                mtime INTEGER NOT NULL,
                size INTEGER NOT NULL,
                is_directory INTEGER NOT NULL,
                UNIQUE(library_id, path)
            );
        """

        let createIndexes = """
            CREATE INDEX IF NOT EXISTS idx_files_library ON synced_files(library_id);
            CREATE INDEX IF NOT EXISTS idx_files_path ON synced_files(library_id, path);
        """

        // Error log table for persistent error storage
        let createErrorLogTable = """
            CREATE TABLE IF NOT EXISTS error_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                message TEXT NOT NULL,
                library_name TEXT,
                file_path TEXT,
                error_type TEXT NOT NULL DEFAULT 'sync'
            );
        """

        // Download progress table for resume functionality
        let createDownloadProgressTable = """
            CREATE TABLE IF NOT EXISTS download_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                library_id TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                object_id TEXT NOT NULL,
                mtime INTEGER NOT NULL,
                size INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                started_at INTEGER,
                completed_at INTEGER,
                error_message TEXT,
                UNIQUE(library_id, remote_path)
            );
        """

        // Sync status table for crash detection
        let createSyncStatusTable = """
            CREATE TABLE IF NOT EXISTS sync_status (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """

        let createProgressIndexes = """
            CREATE INDEX IF NOT EXISTS idx_progress_library ON download_progress(library_id);
            CREATE INDEX IF NOT EXISTS idx_progress_status ON download_progress(status);
            CREATE INDEX IF NOT EXISTS idx_error_timestamp ON error_log(timestamp);
        """

        executeSQL(createSyncStateTable)
        executeSQL(createFilesTable)
        executeSQL(createIndexes)
        executeSQL(createErrorLogTable)
        executeSQL(createDownloadProgressTable)
        executeSQL(createSyncStatusTable)
        executeSQL(createProgressIndexes)
    }

    private func executeSQL(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("SQL Error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Sync State Operations

    func getSyncState(for libraryId: String) -> SyncState? {
        var state = SyncState(libraryId: libraryId)

        // Get last sync time
        let query = "SELECT last_sync_time FROM sync_state WHERE library_id = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                let timestamp = sqlite3_column_int64(stmt, 0)
                state.lastSyncTime = Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
        }
        sqlite3_finalize(stmt)

        // Get files
        state.files = getFiles(for: libraryId)

        return state.files.isEmpty ? nil : state
    }

    func saveSyncState(_ state: SyncState) {
        // Update last sync time
        let upsertState = """
            INSERT OR REPLACE INTO sync_state (library_id, last_sync_time)
            VALUES (?, ?);
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, upsertState, -1, &stmt, nil) == SQLITE_OK {
            state.libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(stmt, 2, Int64(state.lastSyncTime.timeIntervalSince1970))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Clear old files and insert new ones
        deleteFiles(for: state.libraryId)
        for file in state.files {
            insertFile(file, libraryId: state.libraryId)
        }
    }

    // MARK: - File Operations

    private func getFiles(for libraryId: String) -> [SyncedFile] {
        var files: [SyncedFile] = []
        let query = """
            SELECT path, object_id, mtime, size, is_directory
            FROM synced_files WHERE library_id = ?;
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let objectId = String(cString: sqlite3_column_text(stmt, 1))
                let mtime = sqlite3_column_int64(stmt, 2)
                let size = sqlite3_column_int64(stmt, 3)
                let isDir = sqlite3_column_int(stmt, 4) == 1

                let file = SyncedFile(
                    path: path,
                    objectId: objectId,
                    mtime: mtime,
                    size: size,
                    isDirectory: isDir
                )
                files.append(file)
            }
        }
        sqlite3_finalize(stmt)

        return files
    }

    private func insertFile(_ file: SyncedFile, libraryId: String) {
        let insert = """
            INSERT OR REPLACE INTO synced_files
            (library_id, path, object_id, mtime, size, is_directory)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            file.path.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            file.objectId.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(stmt, 4, file.mtime)
            sqlite3_bind_int64(stmt, 5, file.size)
            sqlite3_bind_int(stmt, 6, file.isDirectory ? 1 : 0)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func deleteFiles(for libraryId: String) {
        let delete = "DELETE FROM synced_files WHERE library_id = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, delete, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteAllData() {
        executeSQL("DELETE FROM sync_state;")
        executeSQL("DELETE FROM synced_files;")
        executeSQL("DELETE FROM error_log;")
        executeSQL("DELETE FROM download_progress;")
        executeSQL("DELETE FROM sync_status;")
    }

    // MARK: - Error Log Operations

    func saveError(_ error: PersistedSyncError) {
        let insert = """
            INSERT INTO error_log (timestamp, message, library_name, file_path, error_type)
            VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(error.timestamp.timeIntervalSince1970))
            error.message.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            if let libraryName = error.libraryName {
                libraryName.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let filePath = error.filePath {
                filePath.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            error.errorType.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getRecentErrors(limit: Int = 100) -> [PersistedSyncError] {
        var errors: [PersistedSyncError] = []
        let query = """
            SELECT id, timestamp, message, library_name, file_path, error_type
            FROM error_log ORDER BY timestamp DESC LIMIT ?;
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let timestamp = sqlite3_column_int64(stmt, 1)
                let message = String(cString: sqlite3_column_text(stmt, 2))
                let libraryName = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let filePath = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let errorType = String(cString: sqlite3_column_text(stmt, 5))

                let error = PersistedSyncError(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                    message: message,
                    libraryName: libraryName,
                    filePath: filePath,
                    errorType: errorType
                )
                errors.append(error)
            }
        }
        sqlite3_finalize(stmt)

        return errors
    }

    func clearErrors() {
        executeSQL("DELETE FROM error_log;")
    }

    func clearOldErrors(olderThanDays: Int = 30) {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(olderThanDays * 24 * 60 * 60)
        let delete = "DELETE FROM error_log WHERE timestamp < ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, delete, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Download Progress Operations

    func addPendingDownload(libraryId: String, remotePath: String, objectId: String, mtime: Int64, size: Int64) {
        let insert = """
            INSERT OR REPLACE INTO download_progress
            (library_id, remote_path, object_id, mtime, size, status, started_at, completed_at, error_message)
            VALUES (?, ?, ?, ?, ?, 'pending', NULL, NULL, NULL);
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            remotePath.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            objectId.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(stmt, 4, mtime)
            sqlite3_bind_int64(stmt, 5, size)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func markDownloadInProgress(libraryId: String, remotePath: String) {
        let update = """
            UPDATE download_progress SET status = 'in_progress', started_at = ?
            WHERE library_id = ? AND remote_path = ?;
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            libraryId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            remotePath.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func markDownloadCompleted(libraryId: String, remotePath: String) {
        let update = """
            UPDATE download_progress SET status = 'completed', completed_at = ?
            WHERE library_id = ? AND remote_path = ?;
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            libraryId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            remotePath.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func markDownloadFailed(libraryId: String, remotePath: String, errorMessage: String) {
        let update = """
            UPDATE download_progress SET status = 'failed', error_message = ?
            WHERE library_id = ? AND remote_path = ?;
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK {
            errorMessage.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            libraryId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            remotePath.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getIncompleteDownloads(libraryId: String) -> [DownloadProgress] {
        var downloads: [DownloadProgress] = []
        let query = """
            SELECT id, library_id, remote_path, object_id, mtime, size, status, started_at, completed_at, error_message
            FROM download_progress
            WHERE library_id = ? AND status IN ('pending', 'in_progress', 'failed');
        """
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let libId = String(cString: sqlite3_column_text(stmt, 1))
                let remotePath = String(cString: sqlite3_column_text(stmt, 2))
                let objectId = String(cString: sqlite3_column_text(stmt, 3))
                let mtime = sqlite3_column_int64(stmt, 4)
                let size = sqlite3_column_int64(stmt, 5)
                let statusStr = String(cString: sqlite3_column_text(stmt, 6))
                let status = DownloadStatus(rawValue: statusStr) ?? .pending

                var startedAt: Date? = nil
                if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
                    startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                }

                var completedAt: Date? = nil
                if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                    completedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 8)))
                }

                let errorMessage = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

                let download = DownloadProgress(
                    id: id,
                    libraryId: libId,
                    remotePath: remotePath,
                    objectId: objectId,
                    mtime: mtime,
                    size: size,
                    status: status,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    errorMessage: errorMessage
                )
                downloads.append(download)
            }
        }
        sqlite3_finalize(stmt)

        return downloads
    }

    func isFileCompleted(libraryId: String, path: String, mtime: Int64) -> Bool {
        let query = """
            SELECT COUNT(*) FROM download_progress
            WHERE library_id = ? AND remote_path = ? AND mtime = ? AND status = 'completed';
        """
        var stmt: OpaquePointer?
        var completed = false

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            path.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(stmt, 3, mtime)

            if sqlite3_step(stmt) == SQLITE_ROW {
                completed = sqlite3_column_int(stmt, 0) > 0
            }
        }
        sqlite3_finalize(stmt)

        return completed
    }

    func clearCompletedDownloads(libraryId: String) {
        let delete = "DELETE FROM download_progress WHERE library_id = ? AND status = 'completed';"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, delete, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func clearAllDownloadProgress(libraryId: String) {
        let delete = "DELETE FROM download_progress WHERE library_id = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, delete, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Sync Status (Crash Detection)

    func setSyncInProgress(_ inProgress: Bool) {
        let upsert = """
            INSERT OR REPLACE INTO sync_status (key, value)
            VALUES ('sync_in_progress', ?);
        """
        var stmt: OpaquePointer?
        let value = inProgress ? "true" : "false"

        if sqlite3_prepare_v2(db, upsert, -1, &stmt, nil) == SQLITE_OK {
            value.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func wasSyncInterrupted() -> Bool {
        let query = "SELECT value FROM sync_status WHERE key = 'sync_in_progress';"
        var stmt: OpaquePointer?
        var interrupted = false

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let value = String(cString: sqlite3_column_text(stmt, 0))
                interrupted = value == "true"
            }
        }
        sqlite3_finalize(stmt)

        return interrupted
    }

    func setLastSyncLibrary(_ libraryId: String?) {
        let upsert = """
            INSERT OR REPLACE INTO sync_status (key, value)
            VALUES ('last_sync_library', ?);
        """
        var stmt: OpaquePointer?
        let value = libraryId ?? ""

        if sqlite3_prepare_v2(db, upsert, -1, &stmt, nil) == SQLITE_OK {
            value.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getLastSyncLibrary() -> String? {
        let query = "SELECT value FROM sync_status WHERE key = 'last_sync_library';"
        var stmt: OpaquePointer?
        var libraryId: String? = nil

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let value = String(cString: sqlite3_column_text(stmt, 0))
                if !value.isEmpty {
                    libraryId = value
                }
            }
        }
        sqlite3_finalize(stmt)

        return libraryId
    }

    // MARK: - Statistics

    func getSyncStats() -> SyncStats {
        var stats = SyncStats()

        // Get total files and size
        let filesQuery = "SELECT COUNT(*), SUM(size) FROM synced_files WHERE is_directory = 0;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, filesQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.totalFiles = Int(sqlite3_column_int64(stmt, 0))
                stats.totalSize = sqlite3_column_int64(stmt, 1)
            }
        }
        sqlite3_finalize(stmt)

        // Get total directories
        let dirsQuery = "SELECT COUNT(*) FROM synced_files WHERE is_directory = 1;"
        if sqlite3_prepare_v2(db, dirsQuery, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                stats.totalDirectories = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)

        // Get library count and last sync times
        let libQuery = "SELECT library_id, last_sync_time FROM sync_state;"
        if sqlite3_prepare_v2(db, libQuery, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let libraryId = String(cString: sqlite3_column_text(stmt, 0))
                let timestamp = sqlite3_column_int64(stmt, 1)
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                stats.libraryLastSync[libraryId] = date

                // Track oldest/newest sync
                if stats.oldestSync == nil || date < stats.oldestSync! {
                    stats.oldestSync = date
                }
                if stats.newestSync == nil || date > stats.newestSync! {
                    stats.newestSync = date
                }
            }
        }
        sqlite3_finalize(stmt)

        stats.libraryCount = stats.libraryLastSync.count

        return stats
    }

    func getFile(libraryId: String, path: String) -> SyncedFile? {
        let query = """
            SELECT path, object_id, mtime, size, is_directory
            FROM synced_files WHERE library_id = ? AND path = ?;
        """
        var stmt: OpaquePointer?
        var file: SyncedFile?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            libraryId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            path.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let objectId = String(cString: sqlite3_column_text(stmt, 1))
                let mtime = sqlite3_column_int64(stmt, 2)
                let size = sqlite3_column_int64(stmt, 3)
                let isDir = sqlite3_column_int(stmt, 4) == 1

                file = SyncedFile(
                    path: path,
                    objectId: objectId,
                    mtime: mtime,
                    size: size,
                    isDirectory: isDir
                )
            }
        }
        sqlite3_finalize(stmt)

        return file
    }
}
