# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build
xcodebuild -scheme Remindian -configuration Debug build

# Run tests
xcodebuild test -scheme Remindian -destination 'platform=macOS'

# Open in Xcode
open ObsidianRemindersSync.xcodeproj
```

The project file is `ObsidianRemindersSync.xcodeproj` with two targets: `Remindian` (app) and `RemindianTests` (tests). The only scheme is `Remindian`. Requires Xcode 15.0+ and macOS 13.0+ deployment target.

## Architecture

Remindian is a native macOS menu-bar app (SwiftUI) that syncs Obsidian vault tasks to external task managers. The vault is always the source of truth. All edits to vault files are "surgical" — only the checkbox and metadata fields are modified, never the full line.

### Protocol-based source/destination system

The sync system is built on two protocols:

- **`TaskSource`** (`Protocols/TaskSource.swift`): Scans tasks from a source and writes back metadata changes. Implementations:
  - `ObsidianTasksSource` — parses `- [ ] task 📅 2024-01-20 #tag` format
  - `TaskNotesSource` — parses YAML frontmatter (one file per task)

- **`TaskDestination`** (`Protocols/TaskDestination.swift`): CRUD operations against an external task manager. Implementations:
  - `RemindersDestination` — EventKit (Apple Reminders)
  - `Things3Destination` — AppleScript + URL scheme
  - `TodoistDestination` — REST API v1
  - `TickTickDestination` — OAuth 2.0 + REST API
  - `AsanaDestination` — REST API
  - `LinearDestination` — GraphQL API
  - `CalendarFeedDestination` — .ics file export

To add a new source or destination: implement the protocol, add an enum case to `SyncConfiguration`, and add a factory case in `SyncManager`.

### Sync flow

`SyncEngine.performSync()` is the core entry point (~1150 lines):
1. Scan source tasks via `TaskSource.scanTasks()`
2. Fetch destination tasks via `TaskDestination.fetchAllTasks()`
3. Deduplicate (one source task maps to at most one destination task, tracked via `SyncState`)
4. 3-way merge with conflict resolution (source wins by default)
5. Apply creates/updates/deletes to destination
6. Optional writeback of completion/dates/priority/tags back to vault files
7. Atomic backup before any vault writes

`SyncManager` coordinates the engine with UI state via `@Published` properties.

### Key models (all in `Obsync/Models/`)

- **`SyncTask`** — Unified task representation. Has extensions for parsing Obsidian Tasks format (`fromObsidianLine()`), dataview fields, and conversion to/from destination formats. Tracks `obsidianSource` (file + line number) for surgical edits.
- **`SyncConfiguration`** — All user settings (source/destination type, vault path, auth tokens, list mappings, writeback toggles, filtering rules). Persisted as JSON.
- **`SyncState`** — Source-to-destination ID mappings and last sync timestamps. Prevents duplicate syncs.
- **`SyncLog`** — Audit trail of last 100 sync operations.

### UI layer (`Obsync/Views/`)

- `ContentView` — Main window shell (dashboard + inline settings tabs)
- `SettingsView` — General, List Mappings, TaskNotes, Advanced tabs
- `MenuBarView` — Menu bar popup with status and manual sync
- `OnboardingView` — First-run wizard (vault selection, auth, mappings)
- Adapts to macOS version: Liquid Glass on macOS 26+, legacy layout on 13-25

### Data persistence

All files stored in `~/Library/Application Support/Remindian/`:
- `configuration.json`, `sync_state.json`, `sync_log.json`, `debug.log`

### Logging

Use `debugLog()` for diagnostic output — writes timestamped entries to `debug.log`.

## Testing

Four test files in `RemindianTests/`:
- `TaskParserTests` — Obsidian Tasks format parsing (dates, priority emoji, tags, recurrence, dataview fields, FE0F variation selector handling)
- `DeduplicationTests` — Task ID stability and cross-file deduplication
- `TaskNotesParserTests` — YAML frontmatter parsing
- `ConfigurationTests` — Config serialization and migration

## Code Conventions

- Swift async/await for all async operations
- `@Published` properties on `SyncManager` for reactive SwiftUI binding
- App is fully sandboxed; vault access uses security-scoped bookmarks
- Entitlements: sandbox, user-selected files, bookmarks, calendars (EventKit), Apple Events (AppleScript for Things 3), network client
