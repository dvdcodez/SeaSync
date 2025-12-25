import SwiftUI

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)

                Text("Connect to Seafile")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Enter your server details to start syncing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Form
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://seafile.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Username / Email")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("you@example.com", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Sync path info
            VStack(spacing: 4) {
                Text("Files will sync to:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(SyncConfig.localSyncPath)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid || isLoading)
            }

            if isLoading {
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private var isFormValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private func connect() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Normalize server URL
                var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedURL.hasPrefix("http") {
                    normalizedURL = "https://" + normalizedURL
                }
                normalizedURL = normalizedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                try await appState.configure(
                    serverURL: normalizedURL,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )

                // Close the setup window safely
                await MainActor.run {
                    isLoading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SetupView()
        .environmentObject(AppState())
}
