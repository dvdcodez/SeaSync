import SwiftUI

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

    // MARK: - Configured View

    private var configuredView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            statusHeader
                .padding()

            Divider()

            // Libraries list
            if !appState.libraries.isEmpty {
                librariesList
            }

            Divider()

            // Actions
            actionsSection
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            // Footer
            footerSection
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    private var statusHeader: some View {
        HStack {
            Image(systemName: appState.syncStatus.iconName)
                .font(.title2)
                .foregroundColor(statusColor)

            VStack(alignment: .leading) {
                Text(appState.syncStatus.description)
                    .font(.headline)

                if !appState.currentOperation.isEmpty {
                    Text(appState.currentOperation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let lastSync = appState.lastSyncTime {
                    Text("Last sync: \(lastSync, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if appState.syncStatus == .syncing {
                ProgressView()
                    .scaleEffect(0.7)
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

    private var librariesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Libraries")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            ForEach(appState.libraries.prefix(5)) { library in
                LibraryRow(library: library)
            }

            if appState.libraries.count > 5 {
                Text("and \(appState.libraries.count - 5) more...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task {
                    await appState.triggerManualSync()
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(appState.syncStatus == .syncing)
            .buttonStyle(.plain)

            Button {
                openSyncFolder()
            } label: {
                Label("Open Sync Folder", systemImage: "folder")
            }
            .buttonStyle(.plain)

            if !appState.errors.isEmpty {
                Button {
                    openErrorsWindow()
                } label: {
                    Label("View Errors (\(appState.errors.count))", systemImage: "exclamationmark.triangle")
                }
                .foregroundColor(.red)
                .buttonStyle(.plain)

                Button {
                    appState.errors.removeAll()
                } label: {
                    Label("Clear Errors", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerSection: some View {
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
    }

    // MARK: - Actions

    @State private var setupWindow: NSWindow?
    @State private var errorsWindow: NSWindow?

    private func openSetupWindow() {
        // Close existing window if any
        setupWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up SeaSync"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView().environmentObject(appState))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupWindow = window
    }

    private func openSyncFolder() {
        let url = URL(fileURLWithPath: SyncConfig.localSyncPath)
        NSWorkspace.shared.open(url)
    }

    private func openErrorsWindow() {
        errorsWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sync Errors"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ErrorsView().environmentObject(appState))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        errorsWindow = window
    }
}

// MARK: - Errors View

struct ErrorsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sync Errors")
                    .font(.headline)
                Spacer()
                Text("\(appState.errors.count) errors")
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            if appState.errors.isEmpty {
                VStack {
                    Spacer()
                    Text("No errors")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(appState.errors.reversed()) { error in
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

            Divider()

            HStack {
                Button("Clear All") {
                    appState.errors.removeAll()
                }
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - Library Row

struct LibraryRow: View {
    let library: Library

    var body: some View {
        HStack {
            Image(systemName: library.encrypted ? "lock.fill" : "folder.fill")
                .foregroundColor(.blue)

            Text(library.name)
                .lineLimit(1)

            Spacer()

            if library.isReadOnly {
                Text("Read-only")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(library.localPath)
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
