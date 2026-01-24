import SwiftUI
import AppKit

@main
struct SeaSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window (opened from menu)
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }

    init() {
        // Set as accessory app (no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - App Delegate with NSMenu (no SwiftUI re-rendering issues)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var appState = AppState()

    // Menu items we need to update
    private var statusMenuItem: NSMenuItem!
    private var progressMenuItem: NSMenuItem!
    private var activeFilesMenuItems: [NSMenuItem] = []  // Up to 8 file items
    private var syncControlMenuItem: NSMenuItem!
    private var librariesMenuItem: NSMenuItem!
    private var errorsMenuItem: NSMenuItem!

    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        startUpdateTimer()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status section
        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        progressMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        progressMenuItem.isEnabled = false
        menu.addItem(progressMenuItem)

        // Active files (up to 8) - create placeholder items
        for _ in 0..<8 {
            let fileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            fileItem.isEnabled = false
            fileItem.isHidden = true
            activeFilesMenuItems.append(fileItem)
            menu.addItem(fileItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Sync control
        syncControlMenuItem = NSMenuItem(title: "Sync Now", action: #selector(syncControlTapped), keyEquivalent: "s")
        syncControlMenuItem.target = self
        menu.addItem(syncControlMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Libraries
        librariesMenuItem = NSMenuItem(title: "Libraries", action: #selector(openLibraries), keyEquivalent: "")
        librariesMenuItem.target = self
        menu.addItem(librariesMenuItem)

        // Open Folder
        let folderItem = NSMenuItem(title: "Open Sync Folder", action: #selector(openSyncFolder), keyEquivalent: "o")
        folderItem.target = self
        menu.addItem(folderItem)

        // Statistics
        let statsItem = NSMenuItem(title: "Statistics", action: #selector(openStats), keyEquivalent: "")
        statsItem.target = self
        menu.addItem(statsItem)

        // Errors
        errorsMenuItem = NSMenuItem(title: "Errors", action: #selector(openErrors), keyEquivalent: "")
        errorsMenuItem.target = self
        menu.addItem(errorsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit SeaSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func startUpdateTimer() {
        // Update menu items every 2 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMenuItems()
        }
        updateMenuItems()
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: appState.syncStatus.iconName, accessibilityDescription: "SeaSync")
        }
    }

    private func updateMenuItems() {
        // Update icon
        updateStatusIcon()

        // Update status text
        switch appState.syncStatus {
        case .idle:
            statusMenuItem.title = "✓ Up to date"
            if let lastSync = appState.lastSyncTime {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                progressMenuItem.title = "Last sync: \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
            } else {
                progressMenuItem.title = ""
            }
            syncControlMenuItem.title = "Sync Now"

        case .syncing:
            statusMenuItem.title = "⟳ Syncing..."
            let remaining = appState.totalRemaining
            progressMenuItem.title = remaining > 0 ? "\(remaining) files remaining" : "Scanning..."
            syncControlMenuItem.title = "Pause"

        case .paused:
            statusMenuItem.title = "⏸ Paused"
            progressMenuItem.title = "\(appState.totalRemaining) files remaining"
            syncControlMenuItem.title = "Resume"

        case .error:
            statusMenuItem.title = "⚠ Completed with errors"
            progressMenuItem.title = "\(appState.totalErrorCount) errors"
            syncControlMenuItem.title = "Sync Now"
        }

        // Update active files
        let activeFiles = appState.activeFiles
        for (index, menuItem) in activeFilesMenuItems.enumerated() {
            if index < activeFiles.count {
                let filePath = activeFiles[index]
                let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                // Truncate long names
                let displayName = fileName.count > 35 ? String(fileName.prefix(32)) + "..." : fileName
                menuItem.title = "  ↓ \(displayName)"
                menuItem.isHidden = false
            } else {
                menuItem.title = ""
                menuItem.isHidden = true
            }
        }

        // Update errors count
        let errorCount = appState.totalErrorCount
        errorsMenuItem.title = errorCount > 0 ? "Errors (\(errorCount))" : "Errors"

        // Update libraries count
        let libCount = appState.libraries.count
        librariesMenuItem.title = libCount > 0 ? "Libraries (\(libCount))" : "Libraries"
    }

    // MARK: - Actions

    @objc private func syncControlTapped() {
        switch appState.syncStatus {
        case .syncing:
            appState.pauseSync()
        case .paused:
            appState.resumeSync()
        default:
            Task { @MainActor in
                await appState.triggerManualSync()
            }
        }
        updateMenuItems()
    }

    @objc private func openLibraries() {
        WindowManager.shared.showWindow(
            id: "libraries",
            title: "Libraries",
            size: NSSize(width: 400, height: 350),
            content: LibrariesView().environmentObject(appState)
        )
    }

    @objc private func openSyncFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SyncConfig.localSyncPath))
    }

    @objc private func openStats() {
        WindowManager.shared.showWindow(
            id: "stats",
            title: "Sync Statistics",
            size: NSSize(width: 350, height: 250),
            content: StatsView().environmentObject(appState)
        )
    }

    @objc private func openErrors() {
        appState.loadPersistedErrors()

        weak var weakAppState = appState

        let errorsView = ErrorsView(
            sessionErrors: appState.errors,
            persistedErrors: appState.persistedErrors,
            onClearSession: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    weakAppState?.errors.removeAll()
                }
            },
            onClearHistory: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    weakAppState?.clearPersistedErrors()
                }
            }
        )

        WindowManager.shared.showWindow(
            id: "errors",
            title: "Sync Errors",
            size: NSSize(width: 450, height: 350),
            content: errorsView
        )
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
    @Published var activeFiles: [String] = []
    @Published var libraries: [Library] = []
    @Published var errors: [SyncError] = []
    @Published var persistedErrors: [PersistedSyncError] = []

    // Progress tracking
    @Published var totalDownloads: Int = 0
    @Published var completedDownloads: Int = 0
    @Published var totalUploads: Int = 0
    @Published var completedUploads: Int = 0
    @Published var totalDeletes: Int = 0
    @Published var completedDeletes: Int = 0

    var hasActiveTransfers: Bool {
        totalDownloads > 0 || totalUploads > 0 || totalDeletes > 0
    }

    // Computed properties for remaining counts
    var remainingDownloads: Int { max(0, totalDownloads - completedDownloads) }
    var remainingUploads: Int { max(0, totalUploads - completedUploads) }
    var remainingDeletes: Int { max(0, totalDeletes - completedDeletes) }
    var totalRemaining: Int { remainingDownloads + remainingUploads + remainingDeletes }

    // Total error count (current session + persisted)
    var totalErrorCount: Int { errors.count + persistedErrors.count }

    func resetProgress() {
        totalDownloads = 0
        completedDownloads = 0
        totalUploads = 0
        completedUploads = 0
        totalDeletes = 0
        completedDeletes = 0
    }

    private var syncEngine: SyncEngine?
    private var fileWatcher: FileWatcher?

    init() {
        // Check for interrupted sync from previous run
        checkForInterruptedSync()

        // Load persisted errors from database
        loadPersistedErrors()

        // Clean up old errors (older than 30 days)
        SyncDatabase.shared.clearOldErrors(olderThanDays: 30)

        Task {
            await checkConfiguration()
        }
    }

    private func checkForInterruptedSync() {
        if SyncDatabase.shared.wasSyncInterrupted() {
            log("Previous sync was interrupted - will resume incomplete downloads")

            if let lastLibrary = SyncDatabase.shared.getLastSyncLibrary() {
                log("Last library being synced: \(lastLibrary)")
            }

            SyncDatabase.shared.saveError(PersistedSyncError(
                message: "Previous sync was interrupted (app crash or force quit)",
                libraryName: SyncDatabase.shared.getLastSyncLibrary(),
                filePath: nil,
                errorType: "crash"
            ))

            SyncDatabase.shared.setSyncInProgress(false)
        }
    }

    func loadPersistedErrors() {
        persistedErrors = SyncDatabase.shared.getRecentErrors(limit: 100)
    }

    func clearPersistedErrors() {
        SyncDatabase.shared.clearErrors()
        persistedErrors = []
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

        let authService = AuthService(serverURL: serverURL)
        let token = try await authService.login(username: username, password: password)

        let account = Account(serverURL: serverURL, username: username, token: token)
        try KeychainManager.shared.saveAccount(account)

        isConfigured = true
        await startSync(with: account)
    }

    func startSync(with account: Account) async {
        syncEngine = SyncEngine(account: account, appState: self)
        fileWatcher = FileWatcher(syncPath: SyncConfig.localSyncPath, appState: self)

        await syncEngine?.performFullSync()
        fileWatcher?.start()
        startPeriodicSync()
    }

    func triggerManualSync() async {
        await syncEngine?.performFullSync()
    }

    func pauseSync() {
        syncEngine?.pause()
    }

    func resumeSync() {
        syncEngine?.resume()
    }

    func stopSync() {
        syncEngine?.stop()
    }

    var isSyncActive: Bool {
        syncEngine?.isSyncActive ?? false
    }

    var isSyncPaused: Bool {
        syncEngine?.isSyncPaused ?? false
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
