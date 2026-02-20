# BRANCH STATUS: Fix AsyncTask Fallback

## 1. BRANCH CONTEXT / DEEP DIVE

*(Generated at branch start. Source of truth for architectural context.)*

### 1.1 Architecture & Core Components

- **Entry Points**: `main.lua` and `booklore_api_client.lua`
- **Dependencies**: KOReader `ui/task` module

### 1.2 Database & Data Structure

- **Key Tables/Models**: None for this fix.
- **Critical Fields**: None for this fix.

### 1.3 Key Workflows

- **AsyncTask Execution**: Replaces the synchronous UI fallback with a correctly formatted fallback that exposes a `submit` method, ensuring all `AsyncTask:new()` calls are chainable with `:submit()`.

### 1.4 Known Issues

- **AsyncTask Crashes**: Falling back to `{}` breaks `submit()` calls in older KOReader setups.

## 2. CURRENT OBJECTIVE

- [x] Main Goal: Replace broken `AsyncTask` fallback in `main.lua` and `booklore_api_client.lua`.
- [x] Context: Plugin crashed on the first library scan attempt due to `attempt to call method 'submit' (a nil value)`.
- [x] Main Goal: Refactor `BookloreSync:onSyncBookloreShelf()` to prevent UI freezes.
- [x] Context: The wrapper was causing redundant credential checks and callbacks that broke the async flow.

## 3. CRITICAL FILE MAP

*(The AI must maintain this list. Add files here before editing them.)*

- `bookloresync.koplugin/main.lua`
- `bookloresync.koplugin/booklore_api_client.lua`

## 4. CHANGE LOG (Newest Top)

- **2026-02-20**: Refactored `BookloreSync:onSyncBookloreShelf()` in `main.lua` to exclusively call `self:syncFromBookloreShelf()` and remove redundant UI/credential checks that were breaking the async UI flow.
- **2026-02-20**: Fixed `AsyncTask` fallback implementation and appended `:submit()` to all `AsyncTask:new` instantiations in `main.lua` and `booklore_api_client.lua`.
