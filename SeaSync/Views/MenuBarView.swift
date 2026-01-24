import SwiftUI

// MARK: - Window Manager (prevents crashes from premature window deallocation)

class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showWindow(id: String, title: String, size: NSSize, content: some View) {
        // Close existing window if any
        windows[id]?.close()
        windows[id] = nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.animationBehavior = .none // Prevent animation-related crashes
        window.isReleasedWhenClosed = false // Keep window alive until we release it
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Store strong reference
        windows[id] = window

        // Clean up reference when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            if let closingWindow = notification.object as? NSWindow {
                self?.windowWillClose(closingWindow)
            }
        }
    }

    private func windowWillClose(_ window: NSWindow) {
        // Find and remove the window reference
        for (key, storedWindow) in windows {
            if storedWindow === window {
                windows[key] = nil
                break
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !appState.isConfigured {
                notConfiguredView
            } else {
                configuredView
            }
        }
        .frame(width: 280)
        .transaction { $0.animation = nil } // Disable all animations to prevent jumping
    }

    // MARK: - Not Configured View

    private var notConfiguredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("SeaSync")
                .font(.headline)

            Text("Connect to your Seafile server")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Set Up...") {
                openSetupWindow()
            }
            .buttonStyle(.borderedProminent)

            Divider()

            Button("Quit SeaSync") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }

    // MARK: - Configured View (Fixed Layout with Isolated Components)

    private var configuredView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header - isolated component
            SyncHeaderSection(appState: appState)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Sync progress area - isolated component with fixed height
            SyncProgressSection(appState: appState)
                .frame(height: 80)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            // Actions - completely static, no changing values passed
            MenuActionsSection(
                onOpenLibraries: openLibrariesWindow,
                onOpenFolder: openSyncFolder,
                onOpenStats: openStatsWindow,
                onOpenErrors: openErrorsWindow
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Footer - static component
            MenuFooterSection()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .id("configured-view") // Stable identity to prevent view diffing
        .transaction { $0.animation = nil } // Disable animations
    }

    // MARK: - Window Helpers

    private func openSetupWindow() {
        WindowManager.shared.showWindow(
            id: "setup",
            title: "Set Up SeaSync",
            size: NSSize(width: 400, height: 300),
            content: SetupView().environmentObject(appState)
        )
    }

    private func openLibrariesWindow() {
        WindowManager.shared.showWindow(
            id: "libraries",
            title: "Libraries",
            size: NSSize(width: 400, height: 350),
            content: LibrariesView().environmentObject(appState)
        )
    }

    private func openSyncFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SyncConfig.localSyncPath))
    }

    private func openStatsWindow() {
        WindowManager.shared.showWindow(
            id: "stats",
            title: "Sync Statistics",
            size: NSSize(width: 350, height: 250),
            content: StatsView().environmentObject(appState)
        )
    }

    private func openErrorsWindow() {
        appState.loadPersistedErrors()

        // Capture weak reference for delayed operations
        weak var weakAppState = appState

        let errorsView = ErrorsView(
            sessionErrors: appState.errors,
            persistedErrors: appState.persistedErrors,
            onClearSession: {
                // Delay the clear to avoid race conditions during window close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    weakAppState?.errors.removeAll()
                }
            },
            onClearHistory: {
                // Delay the clear to avoid race conditions during window close
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
}

// MARK: - Isolated Header Section (Static Layout)

struct SyncHeaderSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Icon - always same size
            Image(systemName: appState.syncStatus.iconName)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
                .frame(width: 20, height: 20)

            // Status text - fixed layout
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.syncStatus.description)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 16, alignment: .leading)

                // Subtitle - always present with fixed height
                Text(subtitleText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(height: 14, alignment: .leading)
            }

            Spacer()

            // Button - always same size, just different icon/action
            syncControlButton
                .frame(width: 32, height: 24)
        }
        .frame(height: 44) // Fixed height
    }

    private var subtitleText: String {
        switch appState.syncStatus {
        case .syncing, .paused:
            return "\(appState.totalRemaining) remaining"
        case .idle, .error:
            if let lastSync = appState.lastSyncTime {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return formatter.localizedString(for: lastSync, relativeTo: Date())
            }
            return ""
        }
    }

    private var syncControlButton: some View {
        Button {
            handleButtonTap()
        } label: {
            Image(systemName: buttonIcon)
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var buttonIcon: String {
        switch appState.syncStatus {
        case .syncing: return "pause.fill"
        case .paused: return "play.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private func handleButtonTap() {
        switch appState.syncStatus {
        case .syncing:
            appState.pauseSync()
        case .paused:
            appState.resumeSync()
        default:
            Task {
                await appState.triggerManualSync()
            }
        }
    }

    private var statusColor: Color {
        switch appState.syncStatus {
        case .idle: return .green
        case .syncing: return .blue
        case .error: return .red
        case .paused: return .orange
        }
    }
}

// MARK: - Minimal Progress Section (No dynamic content)

struct SyncProgressSection: View {
    @ObservedObject var appState: AppState

    // Use a snapshot approach - only update view on explicit refresh
    @State private var displayData = DisplayData()

    struct DisplayData {
        var statusMessage = "All files synced"
        var statusColor = Color.secondary
        var remaining = 0
        var progress: Double = 0
        var showProgress = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayData.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(displayData.statusColor)

            if displayData.showProgress {
                Text("\(displayData.remaining) files remaining")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)

                ProgressView(value: displayData.progress)
                    .progressViewStyle(.linear)
            } else {
                Text(" ")
                    .font(.system(size: 10))

                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .opacity(0)
            }
        }
        .frame(height: 80, alignment: .top)
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            updateDisplay()
        }
        .onAppear {
            updateDisplay()
        }
        .onChange(of: appState.syncStatus) { _ in
            updateDisplay()
        }
    }

    private func updateDisplay() {
        let isSyncing = appState.syncStatus == .syncing || appState.syncStatus == .paused
        let total = appState.totalDownloads + appState.totalUploads + appState.totalDeletes
        let completed = appState.completedDownloads + appState.completedUploads + appState.completedDeletes

        displayData.showProgress = isSyncing && total > 0
        displayData.remaining = max(0, total - completed)
        displayData.progress = total > 0 ? Double(completed) / Double(total) : 0

        switch appState.syncStatus {
        case .syncing:
            displayData.statusMessage = "Syncing..."
            displayData.statusColor = .blue
        case .paused:
            displayData.statusMessage = "Paused"
            displayData.statusColor = .orange
        case .error:
            displayData.statusMessage = "Completed with errors"
            displayData.statusColor = .orange
        case .idle:
            displayData.statusMessage = "All files synced"
            displayData.statusColor = .secondary
        }
    }
}

// MARK: - Static Actions Section (completely static, no observed values)

struct MenuActionsSection: View {
    let onOpenLibraries: () -> Void
    let onOpenFolder: () -> Void
    let onOpenStats: () -> Void
    let onOpenErrors: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                onOpenLibraries()
            } label: {
                Label("Libraries", systemImage: "books.vertical")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                onOpenFolder()
            } label: {
                Label("Open Folder", systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                onOpenStats()
            } label: {
                Label("Statistics", systemImage: "chart.bar")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                onOpenErrors()
            } label: {
                Label("Errors", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
            }
            .foregroundColor(.orange)
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Static Footer Section

struct MenuFooterSection: View {
    var body: some View {
        HStack {
            SettingsLink {
                Text("Settings...")
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Libraries View

struct LibrariesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Libraries")
                .font(.headline)
                .padding()

            Divider()

            if appState.libraries.isEmpty {
                VStack {
                    Spacer()
                    Text("No libraries found")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(appState.libraries) { library in
                    HStack {
                        Image(systemName: library.encrypted ? "lock.fill" : "folder.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(library.name)
                                .font(.headline)
                            Text(library.localPath.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 350, minHeight: 250)
    }
}

// MARK: - Stats View

struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats: SyncStats = SyncStats()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Statistics")
                .font(.headline)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Libraries:")
                        .foregroundColor(.secondary)
                    Text("\(stats.libraryCount)")
                }
                GridRow {
                    Text("Files:")
                        .foregroundColor(.secondary)
                    Text("\(stats.totalFiles)")
                }
                GridRow {
                    Text("Directories:")
                        .foregroundColor(.secondary)
                    Text("\(stats.totalDirectories)")
                }
                GridRow {
                    Text("Total Size:")
                        .foregroundColor(.secondary)
                    Text(stats.formattedSize)
                }
                if let oldest = stats.oldestSync {
                    GridRow {
                        Text("Oldest Sync:")
                            .foregroundColor(.secondary)
                        Text(oldest, style: .relative)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear {
            stats = SyncDatabase.shared.getSyncStats()
        }
    }
}

// MARK: - Errors View (uses snapshots to avoid live binding crashes)

struct ErrorsView: View {
    @State private var sessionErrors: [SyncError] = []
    @State private var persistedErrors: [PersistedSyncError] = []
    @State private var selectedTab = 0

    var onClearSession: () -> Void = {}
    var onClearHistory: () -> Void = {}

    init() {}

    init(sessionErrors: [SyncError], persistedErrors: [PersistedSyncError], onClearSession: @escaping () -> Void, onClearHistory: @escaping () -> Void) {
        _sessionErrors = State(initialValue: sessionErrors)
        _persistedErrors = State(initialValue: persistedErrors)
        self.onClearSession = onClearSession
        self.onClearHistory = onClearHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sync Errors")
                    .font(.headline)
                Spacer()
                Text("\(sessionErrors.count + persistedErrors.count) total")
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            Picker("Error Type", selection: $selectedTab) {
                Text("Session (\(sessionErrors.count))").tag(0)
                Text("History (\(persistedErrors.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if selectedTab == 0 {
                sessionErrorsView
            } else {
                persistedErrorsView
            }

            Divider()

            HStack {
                if selectedTab == 0 {
                    Button("Clear Session") {
                        sessionErrors.removeAll()
                        onClearSession()
                    }
                    .disabled(sessionErrors.isEmpty)
                } else {
                    Button("Clear History") {
                        persistedErrors.removeAll()
                        onClearHistory()
                    }
                    .disabled(persistedErrors.isEmpty)
                }
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 450, minHeight: 350)
    }

    private var sessionErrorsView: some View {
        Group {
            if sessionErrors.isEmpty {
                VStack {
                    Spacer()
                    Text("No errors this session")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(Array(sessionErrors.reversed().enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let library = error.libraryName {
                                Text(library)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            Text(error.timestamp, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(error.message)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3)
                        if let filePath = error.filePath {
                            Text(filePath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var persistedErrorsView: some View {
        Group {
            if persistedErrors.isEmpty {
                VStack {
                    Spacer()
                    Text("No error history")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(Array(persistedErrors.enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(error.errorType.capitalized)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(errorTypeColor(error.errorType).opacity(0.2))
                                .foregroundColor(errorTypeColor(error.errorType))
                                .cornerRadius(4)

                            if let library = error.libraryName {
                                Text(library)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            Spacer()
                            Text(error.timestamp, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(error.message)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(3)
                        if let filePath = error.filePath {
                            Text(filePath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func errorTypeColor(_ type: String) -> Color {
        switch type {
        case "crash":
            return .red
        case "network":
            return .orange
        case "sync":
            return .yellow
        default:
            return .gray
        }
    }
}
