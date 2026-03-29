# Remindian Security & Code Audit Report

**Date:** 2026-03-29
**Scope:** Full repository review — security, correctness, runtime safety
**Commit:** 064ca35 (main)

---

## Data Leaving the Device

Data **does** leave the device through these non-Apple channels:

| Destination | What's sent | Where |
|---|---|---|
| **Todoist** | Task titles, notes, dates, priority, tags | `api.todoist.com` (Doist, Inc.) |
| **TickTick** | Task titles, notes, dates, priority | `api.ticktick.com` (Appest, Inc.) |
| **Asana** | Task titles, notes, dates | `app.asana.com` (Asana, Inc.) |
| **Linear** | Task titles, descriptions, dates, priority | `api.linear.app` (Linear, Inc.) |
| **GitHub** | Nothing (GET-only version check) | `api.github.com` (Microsoft) |

Apple Reminders (EventKit) and Things 3 (AppleScript) are fully local. CalendarFeed writes a local `.ics` file with no network calls. TaskNotes HTTP source defaults to `localhost:8080` but the URL is user-configurable.

There is **no telemetry, analytics, or crash reporting** anywhere in the codebase.

---

## CRITICAL — AppleScript Command Injection

**`Things3Destination.swift:176`** — Task titles are escaped only for double quotes, not backslashes:

```swift
let escapedTitle = task.title.replacingOccurrences(of: "\"", with: "\\\"")
```

In AppleScript, backslash is the escape character inside strings. A task title like:

```
test\" & (do shell script "whoami") & "
```

After the current escaping becomes:

```
test\\" & (do shell script "whoami") & "
```

The `\\"` is interpreted as an escaped backslash followed by a real closing quote, breaking out of the string and allowing arbitrary AppleScript execution — including `do shell script` which runs shell commands.

This affects every place task content is interpolated into AppleScript: lines 176, 178, 193, 263, 265, 279, 290. The `deleteTask` method (line 428) interpolates `id` without any escaping at all, though `id` comes from Things 3 itself.

**Fix:** Escape backslashes before quotes:

```swift
let escaped = title
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
```

**Practical risk:** The injection payload would have to exist as a task title in the user's own Obsidian vault. This limits exploitation to scenarios where vault content is externally influenced (shared vaults, synced folders, paste from untrusted source).

---

## HIGH — API Tokens Stored in Plaintext JSON

**`SyncConfiguration.swift:105-116`** — All API tokens (Todoist, TickTick access+refresh, Asana, Linear) are stored as plain strings in `~/Library/Application Support/Remindian/config.json`. No Keychain usage anywhere in the codebase (confirmed: zero matches for `SecItem`, `kSecClass`, `Keychain`).

Any process with file-read access to that directory can extract every token. The app sandbox mitigates this — other sandboxed apps can't reach this path — but non-sandboxed processes (scripts, CLI tools, malware) can.

---

## HIGH — Non-Atomic State Writes Risk Corruption

**`SyncState.swift:54`, `SyncConfiguration.swift:464`, `SyncLog.swift:73`** — All three use:

```swift
try data.write(to: url)
```

`Data.write(to:)` without `.atomic` option is **not atomic**. A crash or power loss during write leaves a truncated file. On next launch, `JSONDecoder` fails and the code silently falls back to empty defaults (`SyncState()`, `SyncConfiguration()`), losing all sync mappings and settings.

**Fix:** `try data.write(to: url, options: .atomic)`

---

## HIGH — Stale Line Numbers in Multi-Task Edits

**`ObsidianService.swift`** — When sync completes a task that has recurrence, it inserts a new recurrence line, shifting all subsequent line numbers by +1. If the same sync cycle then needs to edit another task lower in the same file, it uses the original (now-wrong) line number. The content-mismatch guard prevents data corruption but causes the second edit to fail silently.

---

## MEDIUM — TickTick OAuth Missing PKCE and State Parameter

**`TickTickDestination.swift:178`** — The authorization URL includes no `code_challenge` (PKCE) and no `state` parameter. Without PKCE, another app registering the `remindian://` URL scheme could intercept the authorization code. Without `state`, the flow is vulnerable to CSRF (attacker could link victim's app to attacker's TickTick account).

---

## MEDIUM — Security-Scoped Resource Leak

**`SyncManager.swift:422,464`** — `startAccessingSecurityScopedResource()` is called but `stopAccessingSecurityScopedResource()` is never called anywhere in the codebase (confirmed: zero matches). Per Apple's docs these must be balanced. For a long-running menu bar app, this leaks kernel resources.

---

## MEDIUM — No Path Traversal Protection on Writes

**`ObsidianService.swift:207,368,452`** — File write paths are constructed as:

```swift
let fileURL = URL(fileURLWithPath: vaultPath + filePath)
```

If `filePath` (from sync state or CLI output) contains `../` segments, writes would escape the vault. Under normal flow, `filePath` is derived from scanning, but a corrupted `sync_state.json` could produce a traversal path. The `inboxFilePath` config value (line 116) is also unchecked.

**Fix:** After constructing `fileURL`, resolve and verify it is a descendant of `vaultPath`:

```swift
let resolved = fileURL.standardizedFileURL.path
guard resolved.hasPrefix(URL(fileURLWithPath: vaultPath).standardizedFileURL.path) else { throw ... }
```

---

## MEDIUM — Symlinks Followed Without Resolution

The vault scanner (`FileManager.enumerator`) follows symlinks. A symlink inside the vault pointing outside it would cause the app to read (and potentially write back to) files outside the vault boundary. Obsidian vaults commonly include symlinked folders (e.g., to share notes between vaults), making this a realistic scenario.

**Fix:** During enumeration, check `URLResourceKey.isSymbolicLinkKey` and either skip symlinks or resolve them and validate the target is still within the vault.

---

## MEDIUM — NSAppleScript on Wrong Thread

**`Things3Destination.swift`** — All `NSAppleScript.executeAndReturnError` calls run on cooperative thread pool threads (from `async` methods). Apple's documentation states NSAppleScript should be used from the main thread. This can cause intermittent failures. Additionally, `Thread.sleep(forTimeInterval: 0.3)` at line 461 blocks a cooperative thread, which can exhaust the pool.

---

## MEDIUM — Window Lifecycle / Dock Icon Issues

- `openMainWindow()` (`MenuBarView.swift:184`) matches any hidden normal-level window — could show the wrong window
- When `hideDockIcon` is enabled, opening a window sets `activationPolicy(.regular)` but nothing restores `.accessory` on close — dock icon reappears permanently
- On macOS 13, if the main window is destroyed, there's no fallback to recreate it

---

## MEDIUM — TOCTOU Race Between File Read and Write

**`ObsidianService.swift`** — Every write method reads the file, modifies lines, then writes back. Between read and write, Obsidian or a sync tool (iCloud, Syncthing, Dropbox) could modify the file. The content-mismatch guard partially mitigates this but doesn't fully prevent it. There is no file locking (`flock()`, `NSFileLock`, or equivalent).

---

## LOW

| Finding | Location | Issue |
|---|---|---|
| YAML parser hand-rolled | `TaskNotesSource.swift:740` | No multi-line value support; correctness issue, not security |
| `Thread.sleep` blocks cooperative pool | `Things3Destination.swift:461` | Should use `Task.sleep` |
| `@StateObject` wraps singleton | `ObsyncApp.swift:8` | Should be `@ObservedObject` for pre-existing instances |
| FileHandle uses deprecated API | `AuditLog.swift:23`, `SyncManager.swift:22` | `seekToEndOfFile()`/`write()`/`closeFile()` silently swallow errors |
| Missing `NSCalendarsUsageDescription` | `Info.plist` | Has the entitlement but not the usage string — could crash on newer macOS |
| Hardcoded release date | `AboutView.swift:6` | `"March 2026"` will go stale |
| GraphQL string interpolation | `LinearDestination.swift:117` | Escaping present but parameterized queries would be more robust |
| AppleScript delete unescaped ID | `Things3Destination.swift:428` | `id` from Things 3 itself (low risk), but not escaped |
| `fetchTasksFromList` unescaped list name | `Things3Destination.swift:609` | Currently hardcoded list names only; risk if user data flows in later |
| Non-atomic config fallback loses state | `SyncState.swift`, `SyncConfiguration.swift`, `SyncLog.swift` | Corrupted JSON silently replaced with empty defaults |
| `@State` with `UserDefaults` at init | `ContentView.swift:40` | Fragile if SwiftUI recreates view graph |
| Status dot lacks accessible label | `MenuBarView.swift:13` | VoiceOver users can't determine sync status |
| Menu bar icon static a11y description | `ObsyncApp.swift:37` | Always "Remindian" regardless of syncing/idle state |

---

## What's Clean

- No telemetry, analytics, or crash reporting
- HTTPS enforced on all external APIs
- Vault file contents never sent externally (only parsed task metadata)
- Shell command execution in `TaskNotesSource.runMtn()` is properly single-quote escaped
- Regex patterns are safe (no injection vectors)
- Config deserialization uses concrete `Codable` types (no unsafe `NSCoding`)
- Backup-before-write pattern is consistently applied
- The update checker only does a GET to GitHub and opens the browser — never downloads or executes code
- Tag regex constrained to `[\w-]` — no injection possible
- Dataview field parsing safely ignores unknown keys
- SyncLog capped at 200 entries (bounded growth)
- OAuth redirect handler narrowly scoped to `remindian://oauth/ticktick` only
