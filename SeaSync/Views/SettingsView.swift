import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AccountSettingsView()
                .tabItem {
                    Label("Account", systemImage: "person.circle")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
        .environmentObject(appState)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            Section {
                Toggle("Launch SeaSync at login", isOn: $launchAtLogin)
                Toggle("Show sync notifications", isOn: $showNotifications)
            }

            Section {
                HStack {
                    Text("Sync folder:")
                    Spacer()
                    Text(SyncConfig.localSyncPath)
                        .foregroundColor(.secondary)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: SyncConfig.localSyncPath))
                    }
                }

                HStack {
                    Text("Sync interval:")
                    Spacer()
                    Text("\(SyncConfig.syncIntervalSeconds / 60) minutes")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Account Settings

struct AccountSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showLogoutAlert = false

    var body: some View {
        Form {
            if appState.isConfigured {
                Section {
                    if let account = try? KeychainManager.shared.loadAccount() {
                        LabeledContent("Server", value: account.serverURL)
                        LabeledContent("Username", value: account.username)
                        LabeledContent("Status", value: "Connected")
                    }
                }

                Section {
                    Button("Disconnect Account", role: .destructive) {
                        showLogoutAlert = true
                    }
                }
            } else {
                Text("Not connected to any server")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Disconnect Account?", isPresented: $showLogoutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                appState.logout()
            }
        } message: {
            Text("Your local files will remain, but syncing will stop.")
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("SeaSync")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundColor(.secondary)

            Text("A lightweight Seafile sync client for macOS")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()

            Text("Built with Swift & SwiftUI")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
