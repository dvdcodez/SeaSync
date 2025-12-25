import SwiftUI

@main
struct SeaSyncApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.syncStatus.iconName)
        }

        // Settings window (opened from menu)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    init() {
        // Set as accessory app (no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var syncStatus: SyncStatus = .idle
    @Published var isConfigured: Bool = false
    @Published var lastSyncTime: Date?
    @Published var syncProgress: Double = 0
    @Published var currentOperation: String = ""
    @Published var libraries: [Library] = []
    @Published var errors: [SyncError] = []

    private var syncEngine: SyncEngine?
    private var fileWatcher: FileWatcher?

    init() {
        Task {
            await checkConfiguration()
        }
    }

    func checkConfiguration() async {
        do {
            if let account = try KeychainManager.shared.loadAccount() {
                isConfigured = true
                await startSync(with: account)
            }
        } catch {
            isConfigured = false
        }
    }

    func configure(serverURL: String, username: String, password: String) async throws {
        syncStatus = .syncing
        currentOperation = "Authenticating..."

        // Authenticate
        let authService = AuthService(serverURL: serverURL)
        let token = try await authService.login(username: username, password: password)

        // Create and save account
        let account = Account(serverURL: serverURL, username: username, token: token)
        try KeychainManager.shared.saveAccount(account)

        isConfigured = true
        await startSync(with: account)
    }

    func startSync(with account: Account) async {
        syncEngine = SyncEngine(account: account, appState: self)
        fileWatcher = FileWatcher(syncPath: SyncConfig.localSyncPath, appState: self)

        // Start initial sync
        await syncEngine?.performFullSync()

        // Start file watcher
        fileWatcher?.start()

        // Start periodic sync timer
        startPeriodicSync()
    }

    func triggerManualSync() async {
        await syncEngine?.performFullSync()
    }

    private func startPeriodicSync() {
        Timer.scheduledTimer(withTimeInterval: TimeInterval(SyncConfig.syncIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncEngine?.performFullSync()
            }
        }
    }

    func logout() {
        fileWatcher?.stop()
        syncEngine = nil
        try? KeychainManager.shared.deleteAccount()
        isConfigured = false
        libraries = []
        syncStatus = .idle
    }
}

// MARK: - Sync Status

enum SyncStatus {
    case idle
    case syncing
    case error
    case paused

    var iconName: String {
        switch self {
        case .idle: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .error: return "exclamationmark.icloud"
        case .paused: return "pause.circle"
        }
    }

    var description: String {
        switch self {
        case .idle: return "Up to date"
        case .syncing: return "Syncing..."
        case .error: return "Sync error"
        case .paused: return "Paused"
        }
    }
}

// MARK: - Sync Error

struct SyncError: Identifiable {
    let id = UUID()
    let message: String
    let timestamp: Date
    let libraryName: String?
    let filePath: String?
}
