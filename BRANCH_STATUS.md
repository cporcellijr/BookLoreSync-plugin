# BRANCH STATUS: Beta Release Fixes

## 1. BRANCH CONTEXT / DEEP DIVE

### 1.1 Architecture & Core Components

- **Entry Points**: `main.lua` — `BookloreSync:init()` initializes settings & registers menu; `BookloreSync:calculateBookHash(file_path)` (line 1111) computes the server-compatible MD5 fingerprint.
- **Dependencies**: `booklore_api_client.lua` — all HTTP; `booklore_settings.lua` — all UI config dialogs & menus; `booklore_database.lua` — SQLite cache.

### 1.2 Database & Data Structure

- No schema changes required for this feature.
- Bearer tokens are cached via `db:saveBearerToken()` / `db:getBearerToken()`.

### 1.3 Key Workflows

- **Normal Sync**: `init()` → `startSession()` → `calculateBookHash()` → `getBookIdByHash()` → `syncSession()`.
- **New: Delete Shelf-Removal**: `FileManager.deleteFile` (patched) → `preDeleteHook()` → `UIManager:scheduleIn(0.5, notifyBookloreOnDeletion)`.
- **Fix: Library Scan**: `scanLibrary()` now fetches shelf books FIRST and updates cache using captured `(success, result)` return values.
- **2026-02-20 13:25**: Antigravity — Implemented plugin improvements (Tasks A–F):
  - Defensive API handling for `getBooksInShelf`.
  - 5-minute cooldown for on-resume auto-sync and unmatched books check.
  - Enhanced user feedback on login/connection failures.
  - Real-time progress UI for library scanning.
  - Extended URL redaction to include `data:` URLs.
  - Silent mode polish: auto-run scan if `silent_messages` is true.
- **2026-02-20 13:15**: Antigravity — Fixed `scanLibrary()` crash:

### 1.4 Known Issues

- KOReader has no native plugin file-deletion event — must wrap `FileManager` methods safely.

## 2. CURRENT OBJECTIVE

- [x] Main Goal: Add shelf-removal when a book EPUB is deleted from KOReader's file manager.
- [x] Add `booklore_shelf_name` setting to `init()` and `booklore_settings.lua`.
- [x] Add `preDeleteHook()` and `notifyBookloreOnDeletion()` to `main.lua`.
- [x] Safely patch `FileManager.deleteFile` and `FileManager.deleteSelectedFiles` in `init()`.
- [x] Fix `scanLibrary()` crash on initial scan (Correct return value handling).
- [x] Ensure `initial_scan_done` flag is only set on success.
- [x] Task A: Implement Async Network Calls to prevent UI freezes.
- [x] Task B: Add Logger size caps (1MB) and line buffering (15 lines).
- [x] Task C: Modernize DB migrations using `PRAGMA user_version`.

## 3. CRITICAL FILE MAP

- `bookloresync.koplugin/main.lua`
- `bookloresync.koplugin/booklore_settings.lua`
- `bookloresync.koplugin/booklore_file_logger.lua`
- `bookloresync.koplugin/booklore_database.lua`
- `plugin_tests.lua`

## 4. CHANGE LOG (Newest Top)

- **2026-02-20 08:55**: Antigravity — Implemented High-Priority Beta Fixes:
  - `main.lua`: Wrapped all blocking API/network calls in `UIManager:scheduleIn`.
  - `booklore_file_logger.lua`: Added 1MB size cap and 15-line write buffer.
  - `booklore_database.lua`: Switched migration tracking to `PRAGMA user_version`.
  - `plugin_tests.lua`: Expanded suite to verify logger and DB fixes.
- **2026-02-19 06:32**: Antigravity — Implemented shelf-removal feature:
  - `main.lua`: Added module-level `booklore_fm_patched` guard, `booklore_shelf_name` setting load, FileManager patch (single + bulk delete), `BookloreSync:preDeleteHook()`, `BookloreSync:notifyBookloreOnDeletion()`.
  - `booklore_settings.lua`: Added `Settings:configureShelfName()` dialog and `Shelf Name for Deletion` menu entry in `buildConnectionMenu()`.
- **2026-02-19 06:30**: Antigravity — Initialized branch with Deep Dive.
