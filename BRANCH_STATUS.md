# BRANCH STATUS: Shelf-Removal on Book Deletion

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

### 1.4 Known Issues

- KOReader has no native plugin file-deletion event — must wrap `FileManager` methods safely.

## 2. CURRENT OBJECTIVE

- [x] Main Goal: Add shelf-removal when a book EPUB is deleted from KOReader's file manager.
- [x] Add `booklore_shelf_name` setting to `init()` and `booklore_settings.lua`.
- [x] Add `preDeleteHook()` and `notifyBookloreOnDeletion()` to `main.lua`.
- [x] Safely patch `FileManager.deleteFile` and `FileManager.deleteSelectedFiles` in `init()`.

## 3. CRITICAL FILE MAP

- `bookloresync.koplugin/main.lua`
- `bookloresync.koplugin/booklore_settings.lua`

## 4. CHANGE LOG (Newest Top)

- **2026-02-19 06:32**: Antigravity — Implemented shelf-removal feature:
  - `main.lua`: Added module-level `booklore_fm_patched` guard, `booklore_shelf_name` setting load, FileManager patch (single + bulk delete), `BookloreSync:preDeleteHook()`, `BookloreSync:notifyBookloreOnDeletion()`.
  - `booklore_settings.lua`: Added `Settings:configureShelfName()` dialog and `Shelf Name for Deletion` menu entry in `buildConnectionMenu()`.
- **2026-02-19 06:30**: Antigravity — Initialized branch with Deep Dive.
