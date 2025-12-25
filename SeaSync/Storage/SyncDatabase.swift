import Foundation
import SQLite3

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

        executeSQL(createSyncStateTable)
        executeSQL(createFilesTable)
        executeSQL(createIndexes)
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
            sqlite3_bind_text(stmt, 1, libraryId, -1, nil)

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
            sqlite3_bind_text(stmt, 1, state.libraryId, -1, nil)
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
            sqlite3_bind_text(stmt, 1, libraryId, -1, nil)

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
            sqlite3_bind_text(stmt, 1, libraryId, -1, nil)
            sqlite3_bind_text(stmt, 2, file.path, -1, nil)
            sqlite3_bind_text(stmt, 3, file.objectId, -1, nil)
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
            sqlite3_bind_text(stmt, 1, libraryId, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteAllData() {
        executeSQL("DELETE FROM sync_state;")
        executeSQL("DELETE FROM synced_files;")
    }

    // MARK: - Query Helpers

    func getFile(libraryId: String, path: String) -> SyncedFile? {
        let query = """
            SELECT path, object_id, mtime, size, is_directory
            FROM synced_files WHERE library_id = ? AND path = ?;
        """
        var stmt: OpaquePointer?
        var file: SyncedFile?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, libraryId, -1, nil)
            sqlite3_bind_text(stmt, 2, path, -1, nil)

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
