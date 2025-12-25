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
                    // Show errors window
                } label: {
                    Label("View Errors (\(appState.errors.count))", systemImage: "exclamationmark.triangle")
                }
                .foregroundColor(.red)
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
