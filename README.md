# SeaSync

A lightweight, native macOS menu bar app for syncing with self-hosted [Seafile](https://www.seafile.com/) servers.

## Why SeaSync?

### The Problem

The official Seafile desktop client crashes on **macOS 15 Sequoia** and **macOS 26 Tahoe** due to compatibility issues with the Qt UI framework. The crash occurs in `QWidget::ensurePolished()` before the app even fully launches:

```
Exception Type: EXC_BAD_ACCESS (SIGSEGV)
Signal: Segmentation fault: 11
Crashed Thread: 0
Application Specific Information:
QWidget::ensurePolished() → MainWindow::showWindow()
```

This is a known issue reported on the [Seafile Community Forum](https://forum.seafile.com/t/seafile-client-crash-macos-sequoia-15/24399) with no fix available as of late 2024.

### The Solution

SeaSync bypasses the problematic Qt UI entirely by implementing a **pure Swift/SwiftUI** sync client that:
- Uses native macOS APIs (no Qt dependencies)
- Runs as a lightweight menu bar app
- Connects directly to the Seafile REST API
- Provides bidirectional sync with your self-hosted server

## Features

- **Menu Bar Integration**: Unobtrusive menu bar icon showing sync status
- **Bidirectional Sync**: Upload local changes, download server changes
- **Deletion Sync**: Optionally sync file deletions both ways
- **Encrypted Library Support**: Works with password-protected libraries
- **Last-Modified-Wins**: Automatic conflict resolution
- **FSEvents Watching**: Real-time detection of local file changes
- **Secure Credentials**: API tokens stored in macOS Keychain
- **No External Dependencies**: Pure Apple frameworks

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+
- A self-hosted Seafile server (or seafile.com account)

## Installation

### Build from Source

```bash
git clone https://github.com/yourusername/SeaSync.git
cd SeaSync
swift build -c release
```

The executable will be at `.build/release/SeaSync`

### Run

```bash
.build/release/SeaSync
```

Or move to Applications and run from there.

## Configuration

On first launch, SeaSync will prompt you for:

1. **Server URL**: Your Seafile server (e.g., `https://seafile.example.com`)
2. **Username**: Your email/username
3. **Password**: Your account password

Credentials are securely stored in the macOS Keychain.

### Sync Location

Files sync to: `/Volumes/Normal stor/Seafile/` (configurable in `SyncConfig.swift`)

Each library creates a subfolder:
```
/Volumes/Normal stor/Seafile/
├── My Library/
│   ├── Documents/
│   └── Photos/
├── Work Files/
└── Shared Projects/
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        SeaSync App                          │
├─────────────────────────────────────────────────────────────┤
│  MenuBarExtra (SwiftUI)                                     │
│    ↓                                                        │
│  AppState → SyncEngine → FileService → Seafile REST API    │
│               ↓                                             │
│           FileWatcher (FSEvents)                            │
│               ↓                                             │
│           SyncDatabase (SQLite)                             │
└─────────────────────────────────────────────────────────────┘
```

### Sync Flow

1. **Authentication**: POST to `/api2/auth-token/` with credentials
2. **List Libraries**: GET `/api2/repos/` to fetch all repositories
3. **List Files**: GET `/api2/repos/{id}/dir/?p=/` recursively
4. **Compare**: Match remote files against local files and last sync state
5. **Download**: GET download link, then fetch file content
6. **Upload**: GET upload link, then POST multipart form
7. **Track**: Save file states to SQLite for deletion detection

### API Endpoints Used

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Login | POST | `/api2/auth-token/` |
| List Libraries | GET | `/api2/repos/` |
| List Directory | GET | `/api2/repos/{id}/dir/?p={path}` |
| Download File | GET | `/api2/repos/{id}/file/?p={path}` |
| Upload File | POST | `{upload-link}` (multipart) |
| Delete File | DELETE | `/api2/repos/{id}/file/?p={path}` |

## Project Structure

```
SeaSync/
├── SeaSyncApp.swift              # Main app entry, MenuBarExtra
├── Models/
│   ├── Account.swift             # Server URL, token, username
│   ├── Library.swift             # Seafile library/repo model
│   ├── SeafFile.swift            # File/directory entry
│   └── SyncState.swift           # Local sync tracking
├── Services/
│   ├── AuthService.swift         # Login, token management
│   ├── LibraryService.swift      # List/manage libraries
│   ├── FileService.swift         # Download/upload files
│   ├── SyncEngine.swift          # Core sync logic
│   └── FileWatcher.swift         # FSEvents monitoring
├── Storage/
│   ├── KeychainManager.swift     # Secure credential storage
│   └── SyncDatabase.swift        # Local state persistence
├── Views/
│   ├── MenuBarView.swift         # Menu bar dropdown UI
│   ├── SetupView.swift           # First-run configuration
│   └── SettingsView.swift        # Settings window
└── Config/
    └── SyncConfig.swift          # Sync settings
```

## Customization

### Change Sync Location

Edit `SyncConfig.swift`:

```swift
static let localSyncPath = "/your/preferred/path"
```

### Change Sync Interval

```swift
static let syncIntervalSeconds = 300  // 5 minutes
```

### Conflict Resolution

```swift
static let conflictStrategy: ConflictStrategy = .lastModifiedWins
// Options: .lastModifiedWins, .keepBoth, .serverWins, .localWins
```

## Limitations

- **No selective sync**: All libraries are synced (planned feature)
- **No encrypted library creation**: Must create on server/web
- **No file history/versions**: Only current state synced
- **Single account**: One server connection at a time

## References & Acknowledgments

This project was built by studying:

- **[Seafile Client](https://github.com/haiwen/seafile-client)** - Official C++/Qt desktop client
- **[Seafile Web API](https://manual.seafile.com/latest/develop/web_api_v2.1/)** - REST API documentation
- **[Seafile Server](https://github.com/haiwen/seafile-server)** - Server implementation
- **[python-seafile](https://github.com/haiwen/python-seafile)** - Python API client

Special thanks to the Seafile team for their open-source file sync platform.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file.

## Troubleshooting

### "Connection refused" error
- Check your server URL includes `https://`
- Verify the server is accessible from your network

### "Invalid credentials" error
- Ensure you're using your email address, not username
- Check password is correct

### Files not syncing
- Check the sync folder exists and is writable
- Verify external drive is mounted (if using external storage)
- Check Console.app for SeaSync logs

### Encrypted library not accessible
- SeaSync will prompt for the library password
- Password is stored in Keychain for future access

---

**Built with Swift & SwiftUI for macOS** 🍎
