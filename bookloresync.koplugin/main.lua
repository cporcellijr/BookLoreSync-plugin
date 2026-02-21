--[[--
Booklore KOReader Plugin

Syncs reading sessions to Booklore server via REST API.

@module koplugin.BookloreSync
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local EventListener = require("ui/widget/eventlistener")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
-- Safe AsyncTask with fallback for older KOReader versions
local AsyncTask
do
    local ok, mod = pcall(require, "ui/task")
    if ok then
        AsyncTask = mod
    else
        -- Fallback that works on all KOReader versions
        AsyncTask = {
            new = function(_, background_func, callback_func)
                return {
                    submit = function(self)
                        UIManager:scheduleIn(0.01, function()
                            local results = { pcall(background_func) }
                            local ok = table.remove(results, 1)
                            if callback_func then
                                UIManager:nextTick(function()
                                    callback_func(ok, table.unpack(results))
                                end)
                            end
                        end)
                    end
                }
            end
        }
    end
end
local ButtonDialog = require("ui/widget/buttondialog")
local Settings = require("booklore_settings")
local Database = require("booklore_database")
local APIClient = require("booklore_api_client")
local FileLogger = require("booklore_file_logger")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template

local BookloreSync = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

-- Guard flag: ensure FileManager deletion hooks are only applied once per session
local booklore_fm_patched = false

--[[--
Redact URLs from log message for secure logging

@param message The log message that may contain URLs
@return string Message with URLs redacted
--]]
local function redactUrls(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    -- Match http:// or https:// URLs and replace them with [URL REDACTED]
    message = message:gsub("https?://[^%s]+", "[URL REDACTED]")
    -- Task E: Extend redactUrls to also catch data: URLs
    message = message:gsub("data:[^,%s]+base64,[^%s]+", "[DATA-URL REDACTED]")
    return message
end

-- Secure logger wrappers
function BookloreSync:logInfo(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.info(table.unpack(args))
    
    -- Write to file if enabled
    if self.log_to_file and self.file_logger then
        self.file_logger:write("INFO", table.unpack(args))
    end
end

function BookloreSync:logWarn(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.warn(table.unpack(args))
    
    -- Write to file if enabled
    if self.log_to_file and self.file_logger then
        self.file_logger:write("WARN", table.unpack(args))
    end
end

function BookloreSync:logErr(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.err(table.unpack(args))
    
    -- Write to file if enabled
    if self.log_to_file and self.file_logger then
        self.file_logger:write("ERROR", table.unpack(args))
    end
end

function BookloreSync:logDbg(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.dbg(table.unpack(args))
    
    -- Write to file if enabled
    if self.log_to_file and self.file_logger then
        self.file_logger:write("DEBUG", table.unpack(args))
    end
end

--[[--
Defensive Settings Validation
Ensures all settings have correct types and restores defaults for invalid fields.
--]]
function BookloreSync:validateSettings()
    local updated = false
    local defaults = {
        server_url = "",
        username = "",
        password = "",
        is_enabled = false,
        log_to_file = false,
        silent_messages = false,
        secure_logs = false,
        min_duration = 30,
        min_pages = 5,
        session_detection_mode = "duration",
        progress_decimal_places = 2,
        manual_sync_only = false,
        booklore_username = "",
        booklore_password = "",
        booklore_shelf_name = "KOReader",
        shelf_id = 2,
        initial_scan_done = false,
    }

    for key, default_val in pairs(defaults) do
        local current_val = self.settings:readSetting(key)
        if current_val ~= nil and type(current_val) ~= type(default_val) then
            self:logWarn("BookloreSync: Invalid type for setting", key, 
                         "(expected", type(default_val), "got", type(current_val), 
                         "). Restoring default.")
            self.settings:saveSetting(key, default_val)
            updated = true
        end
    end

    if updated then
        self.settings:flush()
    end
end

-- Constants
local BATCH_UPLOAD_SIZE = 100  -- Maximum number of sessions per batch upload

function BookloreSync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booklore.lua")
    
    -- Defensive Settings Validation
    self:validateSettings()
    
    -- Server configuration
    self.server_url = self.settings:readSetting("server_url") or ""
    self.username = self.settings:readSetting("username") or ""
    self.password = self.settings:readSetting("password") or ""
    
    -- General settings
    self.is_enabled = self.settings:readSetting("is_enabled") or false
    self.log_to_file = self.settings:readSetting("log_to_file") or false
    self.silent_messages = self.settings:readSetting("silent_messages") or false
    self.secure_logs = self.settings:readSetting("secure_logs") or false
    
    -- Session settings
    self.min_duration = self.settings:readSetting("min_duration") or 30
    self.min_pages = self.settings:readSetting("min_pages") or 5
    self.session_detection_mode = self.settings:readSetting("session_detection_mode") or "duration" -- "duration" or "pages"
    self.progress_decimal_places = self.settings:readSetting("progress_decimal_places") or 2
    
    -- Sync options
    self.manual_sync_only = self.settings:readSetting("manual_sync_only") or false
    
    -- Historical data tracking
    self.historical_sync_ack = self.settings:readSetting("historical_sync_ack") or false
    
    -- Booklore login credentials for historical data matching
    self.booklore_username = self.settings:readSetting("booklore_username") or ""
    self.booklore_password = self.settings:readSetting("booklore_password") or ""
    self.booklore_shelf_name = self.settings:readSetting("booklore_shelf_name") or "KOReader"

    -- Shelf sync settings
    self.shelf_id = self.settings:readSetting("shelf_id") or 2
    self.download_dir = self.settings:readSetting("download_dir") or self:_detectDefaultDownloadDir()

    -- Auto-sync from shelf on resume
    self.auto_sync_shelf_on_resume = self.settings:readSetting("auto_sync_shelf_on_resume")
    if self.auto_sync_shelf_on_resume == nil then
        self.auto_sync_shelf_on_resume = false  -- Default disabled
    end

    -- Delete local books when removed from shelf (bidirectional sync)
    self.delete_removed_shelf_books = self.settings:readSetting("delete_removed_shelf_books")
    if self.delete_removed_shelf_books == nil then
        self.delete_removed_shelf_books = false  -- Default disabled for safety
    end

    -- Library scan tracking
    self.initial_scan_done = self.settings:readSetting("initial_scan_done") or false
    self.scan_in_progress = false
    self.scan_progress = { current = 0, total = 0 }
    
    -- Task B: Cooldown for auto-sync
    self.last_auto_sync_time = 0

    -- Sync state machine
    self.sync_in_progress = false

    -- Current reading session tracking
    self.current_session = nil
    
    -- Initialize file logger if enabled
    if self.log_to_file then
        self.file_logger = FileLogger:new()
        local logger_ok = self.file_logger:init()
        if logger_ok then
            self:logInfo("BookloreSync: File logging initialized")
        else
            self:logErr("BookloreSync: Failed to initialize file logger")
            self.file_logger = nil
        end
    end
    
    -- Initialize SQLite database
    self.db = Database:new()
    local db_initialized = self.db:init()
    
    if not db_initialized then
        self:logErr("BookloreSync: Failed to initialize database")
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize Booklore database"),
            timeout = 3,
        })
    else
        -- Check if we need to migrate from old LuaSettings format
        local old_db_path = DataStorage:getSettingsDir() .. "/booklore_db.lua"
        local old_db_file = io.open(old_db_path, "r")
        
        if old_db_file then
            old_db_file:close()
            self:logInfo("BookloreSync: Found old database, checking if migration needed")
            
            -- Check if database is empty (needs migration)
            local stats = self.db:getBookCacheStats()
            if stats.total == 0 then
                self:logInfo("BookloreSync: Database is empty, migrating from LuaSettings")
                
                local ok, err = pcall(function()
                    local local_db = LuaSettings:open(old_db_path)
                    local success = self.db:migrateFromLuaSettings(local_db)
                    
                    if success then
                        UIManager:show(InfoMessage:new{
                            text = _("Migrated data to new database format"),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Migration completed with some errors. Check logs."),
                            timeout = 3,
                        })
                    end
                end)
                
                if not ok then
                    self:logErr("BookloreSync: Migration failed:", err)
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to migrate old data. Check logs."),
                        timeout = 3,
                    })
                end
            end
        end
    end
    
    -- Clean up expired bearer tokens
    if self.db then
        self.db:cleanupExpiredTokens()
    end
    
    -- Initialize API client
    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    -- Register menu
    self.ui.menu:registerToMainMenu(self)
    
    -- Register actions with Dispatcher for gesture manager integration
    self:registerDispatcherActions()
    
    -- Patch FileManager deletion methods to trigger shelf removal (applied once per session)
    local booklore_self = self
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and not booklore_fm_patched then
        booklore_fm_patched = true
        
        -- Path 1: Single-file deletion
        local orig_deleteFile = FileManager.deleteFile
        FileManager.deleteFile = function(fm_self, file, is_file)
            local hash, stem, book_id = nil, nil, nil
            if is_file then
                hash, stem, book_id = booklore_self:preDeleteHook(file)
            end

            local result = orig_deleteFile(fm_self, file, is_file)

            if hash and stem then
                UIManager:scheduleIn(0.5, function()
                    booklore_self:notifyBookloreOnDeletion(hash, stem, book_id)
                end)
            end
            return result
        end
        
        -- Path 2: Bulk-select deletion
        local orig_deleteSelectedFiles = FileManager.deleteSelectedFiles
        FileManager.deleteSelectedFiles = function(fm_self)
            local to_sync = {}
            for _, file in ipairs(fm_self.selected_files or {}) do
                local resolved = require("ffi/util").realpath(file)
                local hash, stem, book_id = booklore_self:preDeleteHook(resolved)
                if hash then
                    table.insert(to_sync, { hash = hash, stem = stem, book_id = book_id })
                end
            end

            local result = orig_deleteSelectedFiles(fm_self)

            local delay = 0.5
            for _, item in ipairs(to_sync) do
                UIManager:scheduleIn(delay, function()
                    booklore_self:notifyBookloreOnDeletion(item.hash, item.stem, item.book_id)
                end)
                delay = delay + 0.5
            end
            return result
        end
    end

    -- First-launch library scan prompt
    if not self.initial_scan_done
       and self.booklore_username and self.booklore_username ~= ""
       and self.booklore_password and self.booklore_password ~= "" then
        
        -- Task F: Skip initial scan dialog in silent_messages mode
        if self.silent_messages then
            self:logInfo("BookloreSync: Silent mode active, auto-running initial scan")
            self:scanLibrary(true)
            return
        end

        UIManager:scheduleIn(3, function()
            self:_showInitialScanDialog()
        end)
    end
end

function BookloreSync:onExit()
    -- Close database connection when plugin exits
    if self.db then
        self.db:close()
    end
    
    -- Close file logger if it's open
    if self.file_logger then
        self.file_logger:close()
    end
end

function BookloreSync:onSuspend()
    -- Flush and close logger handle to minimize wear and corruption risk
    if self.file_logger then
        self.file_logger:close()
    end
end

function BookloreSync:onResume()
    -- The logger will automatically re-open the handle on the next write() call
    self:logInfo("BookloreSync: Plugin resumed")
end

function BookloreSync:registerDispatcherActions()
    -- Register Toggle Sync action
    Dispatcher:registerAction("booklore_toggle_sync", {
        category = "none",
        event = "ToggleBookloreSync",
        title = _("Toggle Booklore Sync"),
        general = true,
    })
    
    -- Register Sync Pending Sessions action
    Dispatcher:registerAction("booklore_sync_pending", {
        category = "none",
        event = "SyncBooklorePending",
        title = _("Sync Booklore Pending Sessions"),
        general = true,
    })

    -- Register Manual Sync Only toggle action
    Dispatcher:registerAction("booklore_toggle_manual_sync_only", {
        category = "none",
        event = "ToggleBookloreManualSyncOnly",
        title = _("Toggle Booklore Manual Sync Only"),
        general = true,
    })
    
    -- Register Test Connection action
    Dispatcher:registerAction("booklore_test_connection", {
        category = "none",
        event = "TestBookloreConnection",
        title = _("Test Booklore Connection"),
        general = true,
    })

    -- Register Sync from Booklore Shelf action
    Dispatcher:registerAction("booklore_sync_shelf", {
        category = "none",
        event = "SyncBookloreShelf",
        title = _("Sync from Booklore Shelf"),
        general = true,
    })
end

-- Event handlers for Dispatcher actions
function BookloreSync:onToggleBookloreSync()
    self:toggleSync()
    return true
end

function BookloreSync:onSyncBooklorePending()
    local pending_count = self.db and self.db:getPendingSessionCount() or 0
    local pending_deletions = self.db and #self.db:getPendingDeletions() or 0
    if (pending_count > 0 or pending_deletions > 0) and self.is_enabled then
        self:syncPendingSessions()
        self:syncPendingDeletions()
    else
        if pending_count == 0 and pending_deletions == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No pending sessions to sync"),
                timeout = 1,
            })
        end
    end
    return true
end

function BookloreSync:onTestBookloreConnection()
    self:testConnection()
    return true
end

function BookloreSync:onToggleBookloreManualSyncOnly()
    self:toggleManualSyncOnly()
    return true
end

function BookloreSync:onSyncBookloreShelf()
    if not (self.booklore_username and self.booklore_username ~= "" and
            self.booklore_password and self.booklore_password ~= "") then
        UIManager:show(InfoMessage:new{
            text = _("Booklore credentials not configured"),
            timeout = 2,
        })
        return true
    end
    UIManager:show(InfoMessage:new{
        text = _("Syncing from Booklore shelf..."),
        timeout = 2,
    })
    UIManager:scheduleIn(0.1, function()
        local success, message = self:syncFromBookloreShelf()
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = success and 5 or 10,
        })
        if success then
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:reinit(self.download_dir)
            end
        end
    end)
    return true
end

function BookloreSync:toggleSync()
    self.is_enabled = not self.is_enabled
    self.settings:saveSetting("is_enabled", self.is_enabled)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = self.is_enabled and _("Booklore sync enabled") or _("Booklore sync disabled"),
        timeout = 1,
    })
end

function BookloreSync:toggleManualSyncOnly()
    self.manual_sync_only = not self.manual_sync_only
    self.settings:saveSetting("manual_sync_only", self.manual_sync_only)
    self.settings:flush()

    local message
    if self.manual_sync_only then
        message = _("Manual sync only: use 'Sync Now' to upload sessions")
    else
        message = _("Passive sync enabled: sessions sync when closing a book with WiFi connected, or when resuming with WiFi connected")
    end
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 3,
    })
end

function BookloreSync:viewSessionDetails()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end

    local stats = self.db:getBookCacheStats()
    local pending_count = self.db:getPendingSessionCount()

    -- Convert cdata to Lua numbers
    local total = tonumber(stats.total) or 0
    local matched = tonumber(stats.matched) or 0
    local unmatched = tonumber(stats.unmatched) or 0
    local pending = tonumber(pending_count) or 0

    -- Determine library scan status
    local scan_status
    if self.scan_in_progress then
        scan_status = T(_("Library scan: %1 / %2 books processed"),
            self.scan_progress.current, self.scan_progress.total)
    elseif self.initial_scan_done then
        scan_status = T(_("Library scan: complete (%1 books indexed)"), total)
    else
        scan_status = _("Library scan: not yet run")
    end

    UIManager:show(InfoMessage:new{
        text = T(_(
            "Total books: %1\n" ..
            "Matched: %2\n" ..
            "Unmatched: %3\n" ..
            "Pending sessions: %4\n" ..
            "%5"
        ), total, matched, unmatched, pending, scan_status),
        timeout = 3,
    })
end

--[[--
Sync books from Booklore shelf to KOReader device

Downloads books that are in the configured Booklore shelf but not present locally.
Uses database cache to avoid re-downloading books that are already on the device.

@return boolean success
@return string message (user-friendly result message)
--]]

--[[--
Detect a sensible default download directory based on the current device.
--]]
function BookloreSync:_detectDefaultDownloadDir()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes("/mnt/onboard", "mode") == "directory" then
        return "/mnt/onboard/Books"   -- Kobo
    elseif lfs.attributes("/sdcard", "mode") == "directory" then
        return "/sdcard/Books"         -- Android
    else
        return "/Books"                -- Generic fallback
    end
end

function BookloreSync:syncFromBookloreShelf(silent)
    if silent == nil then silent = (self.ui and self.ui.document and true or false) end

    -- Task 1: Check if a sync is already in progress
    if self.sync_in_progress then
        self:logWarn("BookloreSync: Sync already in progress, skipping duplicate call")
        return false, _("Sync already in progress")
    end

    -- Check if Booklore credentials are configured
    if not self.booklore_username or self.booklore_username == "" or
       not self.booklore_password or self.booklore_password == "" then
        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{
                text = _("Booklore credentials not configured. Please configure your Booklore account first."),
                timeout = 3,
            })
        end
        return false, _("Credentials not configured")
    end

    self.sync_in_progress = true
    local info_msg
    if not silent and not self.silent_messages then
        info_msg = InfoMessage:new{
            text = _("Syncing books from Booklore shelf..."),
            timeout = 0,
        }
        UIManager:show(info_msg)
    end

    self:logInfo("BookloreSync: syncFromBookloreShelf — starting AsyncTask sync")

    AsyncTask:new(function()
        -- Use pcall to catch any errors in the background task
        return pcall(function()
            -- Get or create shelf
            local shelf_ok, shelf_id = self.api:getOrCreateShelf(self.booklore_shelf_name, self.booklore_username, self.booklore_password)
            if not shelf_ok then error(shelf_id or "Failed to get/create shelf") end
            
            -- Update shelf_id
            if shelf_id ~= self.shelf_id then
                self.shelf_id = shelf_id
                self.settings:saveSetting("shelf_id", self.shelf_id)
                self.settings:flush()
            end

            -- Get books
            local books_ok, books = self.api:getBooksInShelf(shelf_id, self.booklore_username, self.booklore_password)
            if not books_ok then error(books or "Failed to retrieve books") end
            
            if type(books) ~= "table" or #books == 0 then
                return true, "Shelf is empty - no books to sync"
            end

            local download_dir = self.download_dir
            local lfs = require("libs/libkoreader-lfs")
            local downloaded = 0
            local skipped = 0
            local deleted = 0
            local errors = 0

            self.db:beginTransaction()
            local ok, err = pcall(function()
                -- Build set of IDs for bidirectional sync
                local shelf_book_ids = {}
                local total_books = #books
                for i, book in ipairs(books) do
                    local book_id = tonumber(book.id)
                    if book_id then
                        shelf_book_ids[book_id] = true
                        local filename = self:_generateFilename(book)
                        local filepath = download_dir .. "/" .. filename

                        -- Update UI safely from AsyncTask thread
                        UIManager:scheduleIn(0, function()
                            if info_msg then
                                if lfs.attributes(filepath, "mode") == "file" then
                                    info_msg.text = T(_("Skipping: %1 (%2 of %3)"), book.title or "Unknown", i, total_books)
                                else
                                    info_msg.text = T(_("Downloading: %1 (%2 of %3)"), book.title or "Unknown", i, total_books)
                                end
                                UIManager:forceRePaint()
                            end
                        end)

                        if lfs.attributes(filepath, "mode") == "file" then
                            -- Update cache if needed
                            local existing_book = self.db:getBookByFilePath(filepath)
                            if not existing_book then
                                local hash = self:calculateBookHash(filepath)
                                self.db:saveBookCache(filepath, hash, book_id, book.title, book.author, book.isbn10, book.isbn13)
                            end
                            skipped = skipped + 1
                        else
                            -- Download
                            local dl_ok, dl_err = self.api:downloadBook(book_id, filepath, self.booklore_username, self.booklore_password)
                            if dl_ok then
                                local hash = self:calculateBookHash(filepath)
                                self.db:saveBookCache(filepath, hash, book_id, book.title, book.author, book.isbn10, book.isbn13)
                                downloaded = downloaded + 1
                            else
                                errors = errors + 1
                                self:logWarn("BookloreSync: Failed to download book:", book.title, dl_err)
                            end
                        end
                    end
                end

                -- Bidirectional sync: Remove local books not in shelf
                if self.delete_removed_shelf_books then
                    for file in lfs.dir(download_dir) do
                        local book_id_match = file:match("^BookID_(%d+)%.epub$")
                        if book_id_match then
                            local local_book_id = tonumber(book_id_match)
                            if local_book_id and not shelf_book_ids[local_book_id] then
                                local filepath = download_dir .. "/" .. file
                                
                                -- Safe UI update for deletion
                                UIManager:scheduleIn(0, function()
                                    if info_msg then
                                        info_msg.text = T(_("Deleting removed book (ID: %1)..."), local_book_id)
                                        UIManager:forceRePaint()
                                    end
                                end)
                                
                                if os.remove(filepath) then
                                    deleted = deleted + 1
                                else
                                    errors = errors + 1
                                end
                            end
                        end
                    end
                end
            end)

            if ok then
                self.db:commit()
            else
                self.db:rollback()
                self:logErr("BookloreSync: Error during shelf sync loop, rolled back:", err)
                error(err)
            end
            
            return true, T(_("Sync complete!\n\nDownloaded: %1\nSkipped: %2\nDeleted: %3\nErrors: %4"), 
                         downloaded, skipped, deleted, errors)
        end)
    end,
    function(success, result_ok, result)
        -- Callback on UI thread
        if info_msg then UIManager:close(info_msg) end
        self.sync_in_progress = false

        local final_success = success and result_ok
        local final_msg = final_success and result or (T(_("Sync failed: %1"), result or "Unknown error"))
        
        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{ text = final_msg, timeout = 5 })
        end
        
        if final_success then
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:reinit(self.download_dir)
            end
        end
    end):submit()

    return true
end

--[[--
Generate filename for downloaded book

Creates a filename in the format "Author - Title.extension" or falls back to
"BookID_{id}.epub" if metadata is missing.

@param book Book object from Booklore API
@return string Sanitized filename
--]]
function BookloreSync:_generateFilename(book)
    local extension = book.extension or "epub"
    return "BookID_" .. book.id .. "." .. extension
end

--[[--
Recursively scan directories for EPUB files

@param dir Directory to scan
@param files Table to accumulate results
--]]
function BookloreSync:_scanDirectory(dir, files)
    local lfs = require("libs/libkoreader-lfs")

    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)

            if attr and attr.mode == "directory" then
                -- Recursively scan subdirectories
                self:_scanDirectory(path, files)
            elseif attr and attr.mode == "file" then
                -- Check if file is an EPUB
                if path:match("%.epub$") then
                    table.insert(files, path)
                end
            end
        end
    end
end

--[[--
Scan library for EPUB files and match them to Booklore IDs

Scans both download_dir and KOReader home directory for EPUB files,
calculates hashes, and looks them up on the Booklore server.
Processes files in batches to keep UI responsive.

@param silent If true, suppress completion message
--]]
function BookloreSync:scanLibrary(silent)
    if self.scan_in_progress or self.sync_in_progress then
        UIManager:show(InfoMessage:new{
            text = _("Library operation already in progress"),
            timeout = 2,
        })
        return
    end

    self:logInfo("BookloreSync: Starting library scan")
    self.scan_in_progress = true
    self.sync_in_progress = true
    self.scan_progress = { current = 0, total = 0 }

    local info_msg
    if not silent then
        info_msg = InfoMessage:new{
            text = _("Scanning Booklore library..."),
            timeout = 0,
        }
        UIManager:show(info_msg)
    end

    AsyncTask:new(function()
        return pcall(function()
            -- FIX: capture both return values: success (bool) and result (table|string)
            local success, books = self.api:getBooksInShelf(
                self.shelf_id,
                self.booklore_username,
                self.booklore_password
            )

            if not success then
                error(books or "Failed to fetch books from shelf")
            end

            if type(books) ~= "table" or #books == 0 then
                return true, 0, 0
            end

            self.scan_progress.total = #books

            -- Process books from shelf and update cache
            local matched_count = 0
            local total_books = #books
            
            self.db:beginTransaction()
            local ok_loop, err_loop = pcall(function()
                for i, book in ipairs(books) do
                    self.scan_progress.current = i
                    
                    -- Update UI safely from AsyncTask thread, throttled to every 20 books or at the end
                    if i % 20 == 0 or i == total_books then
                        UIManager:scheduleIn(0, function()
                            if info_msg then
                                info_msg.text = T(_("Scanning Booklore library: %1 / %2 books processed..."), i, total_books)
                                UIManager:forceRePaint()
                            end
                        end)
                    end
                    
                    if book.id and book.file_hash then
                        self.db:updateBookId(book.file_hash, tonumber(book.id))
                        matched_count = matched_count + 1
                    end
                end
            end)

            if ok_loop then
                self.db:commit()
            else
                self.db:rollback()
                self:logErr("BookloreSync: Error during library scan loop, rolled back:", err_loop)
                error(err_loop)
            end
            
            return true, #books, matched_count
        end)
    end,
    function(success, result_ok, total_found, matched_count)
        self.scan_in_progress = false
        self.sync_in_progress = false
        
        if info_msg then
            UIManager:close(info_msg)
        end

        local final_success = success and result_ok
        
        if not final_success then
            self:logErr("BookloreSync: scanLibrary failed:", total_found)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to retrieve books from Booklore shelf.\nPlease check your connection and credentials."),
                    timeout = 5,
                })
            end
            return
        end

        self.initial_scan_done = true
        self.settings:saveSetting("initial_scan_done", true)
        self.settings:flush()

        if total_found == 0 then
            self:logInfo("BookloreSync: scanLibrary — shelf is empty")
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("Scan complete: your Booklore shelf is empty."),
                    timeout = 3,
                })
            end
        else
            self:logInfo("BookloreSync: Library scan complete -", matched_count, "items matched")
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = T(_("Library scan complete!\n\nProcessed: %1\nMatched: %2"),
                            total_found, matched_count),
                    timeout = 5,
                })
            end
        end
    end):submit()
end

--[[--
Show dialog prompting user to scan library on first launch
--]]
function BookloreSync:_showInitialScanDialog()
    UIManager:show(ConfirmBox:new{
        text = _("This appears to be the first time Booklore Sync has run.\n\nWould you like to scan your library now so books can be linked to your Booklore server?\n\nThis runs in the background and won't interrupt your reading."),
        ok_text = _("Scan Now"),
        cancel_text = _("Later"),
        ok_callback = function()
            self:scanLibrary(false)
        end,
    })
end

function BookloreSync:addToMainMenu(menu_items)
    local base_menu = {}
    
    -- Enable Sync toggle
    table.insert(base_menu, {
        text = _("Enable Sync"),
        help_text = _("Enable or disable automatic syncing of reading sessions to Booklore server. When disabled, no sessions will be tracked or synced."),
        checked_func = function()
            return self.is_enabled
        end,
        callback = function()
            self.is_enabled = not self.is_enabled
            self.settings:saveSetting("is_enabled", self.is_enabled)
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = self.is_enabled and _("Booklore sync enabled") or _("Booklore sync disabled"),
                timeout = 2,
            })
        end,
    })

    -- Sync from Booklore Shelf submenu
    table.insert(base_menu, {
        text = _("Sync from Booklore Shelf"),
        sub_item_table = {
            {
                text = _("Sync Now"),
                help_text = _("Download books from your configured Booklore shelf to this device. Books already present locally will be skipped."),
                enabled_func = function()
                    return self.booklore_username and self.booklore_username ~= "" and
                           self.booklore_password and self.booklore_password ~= ""
                end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Syncing from Booklore shelf..."),
                        timeout = 2,
                    })

                    -- Run sync in background to avoid blocking UI
                    UIManager:scheduleIn(0.1, function()
                        local success, message = self:syncFromBookloreShelf()

                        UIManager:show(InfoMessage:new{
                            text = message,
                            timeout = success and 5 or 10,  -- Show errors longer
                        })

                        -- Refresh file browser to show newly downloaded books
                        if success then
                            local FileManager = require("apps/filemanager/filemanager")
                            if FileManager.instance then
                                FileManager.instance:reinit(self.download_dir)
                            end
                        end
                    end)
                end,
            },
            {
                text = _("Auto-Sync on Wake"),
                help_text = _("Automatically download new books from your Booklore shelf when the device wakes from sleep and WiFi is available."),
                checked_func = function()
                    return self.auto_sync_shelf_on_resume
                end,
                enabled_func = function()
                    return self.booklore_username and self.booklore_username ~= "" and
                           self.booklore_password and self.booklore_password ~= ""
                end,
                callback = function()
                    self.auto_sync_shelf_on_resume = not self.auto_sync_shelf_on_resume
                    self.settings:saveSetting("auto_sync_shelf_on_resume", self.auto_sync_shelf_on_resume)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.auto_sync_shelf_on_resume and
                               _("Auto-sync on wake enabled - books will be downloaded automatically when device wakes") or
                               _("Auto-sync on wake disabled"),
                        timeout = 3,
                    })
                end,
            },
            {
                text = _("Delete Removed Books"),
                help_text = _("When syncing from shelf, automatically delete local BookID_*.epub files that are no longer in your Booklore shelf. Use with caution!"),
                checked_func = function()
                    return self.delete_removed_shelf_books
                end,
                enabled_func = function()
                    return self.booklore_username and self.booklore_username ~= "" and
                           self.booklore_password and self.booklore_password ~= ""
                end,
                callback = function()
                    self.delete_removed_shelf_books = not self.delete_removed_shelf_books
                    self.settings:saveSetting("delete_removed_shelf_books", self.delete_removed_shelf_books)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.delete_removed_shelf_books and
                               _("Delete removed books enabled - local books not in shelf will be deleted during sync") or
                               _("Delete removed books disabled"),
                        timeout = 3,
                    })
                end,
            },
        },
    })

    -- Scan Library menu entries
    table.insert(base_menu, {
        text_func = function()
            if self.scan_in_progress then
                return T(_("Scanning... (%1/%2)"),
                    self.scan_progress.current,
                    self.scan_progress.total)
            end
            return _("Scan Library")
        end,
        help_text = _("Scan your device for EPUB files and match them to your Booklore library. Run this after adding books in bulk. Runs in the background."),
        enabled_func = function()
            return not self.scan_in_progress
                and self.booklore_username ~= ""
                and self.booklore_password ~= ""
        end,
        callback = function()
            self:scanLibrary(false)
        end,
    })

    table.insert(base_menu, {
        text = _("Reset Library Scan"),
        help_text = _("Reset the initial scan flag to force a full library rescan. Useful after adding many books or if you want to re-match your entire library."),
        callback = function()
            self.initial_scan_done = false
            self.settings:saveSetting("initial_scan_done", false)
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = _("Library scan flag reset. You can now run 'Scan Library' to rescan all books."),
                timeout = 3,
            })
        end,
    })

    -- Setup & Connection submenu
    table.insert(base_menu, Settings:buildConnectionMenu(self))
    
    -- Session Settings submenu
    table.insert(base_menu, {
        text = _("Session Settings"),
        sub_item_table = {
            {
                text = _("Detection Mode"),
                help_text = _("Choose how sessions are validated: Duration-based (minimum seconds) or Pages-based (minimum pages read). Default is duration-based."),
                sub_item_table = {
                    {
                        text = _("Duration-based"),
                        help_text = _("Sessions must last a minimum number of seconds. Good for general reading tracking."),
                        checked_func = function()
                            return self.session_detection_mode == "duration"
                        end,
                        callback = function()
                            self.session_detection_mode = "duration"
                            self.settings:saveSetting("session_detection_mode", self.session_detection_mode)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text = _("Session detection set to duration-based"),
                                timeout = 2,
                            })
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Pages-based"),
                        help_text = _("Sessions must include a minimum number of pages read. Better for avoiding accidental sessions."),
                        checked_func = function()
                            return self.session_detection_mode == "pages"
                        end,
                        callback = function()
                            self.session_detection_mode = "pages"
                            self.settings:saveSetting("session_detection_mode", self.session_detection_mode)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text = _("Session detection set to pages-based"),
                                timeout = 2,
                            })
                        end,
                        keep_menu_open = true,
                    },
                },
            },
            {
                text = _("Minimum Duration (seconds)"),
                help_text = _("Set the minimum number of seconds a reading session must last to be synced. Sessions shorter than this will be discarded. Default is 30 seconds. Only applies when using duration-based detection."),
                enabled_func = function()
                    return self.session_detection_mode == "duration"
                end,
                keep_menu_open = true,
                callback = function()
                    Settings:configureMinDuration(self)
                end,
            },
            {
                text = _("Minimum Pages Read"),
                help_text = _("Set the minimum number of pages that must be read in a session for it to be synced. Default is 1 page. Only applies when using pages-based detection."),
                enabled_func = function()
                    return self.session_detection_mode == "pages"
                end,
                keep_menu_open = true,
                callback = function()
                    Settings:configureMinPages(self)
                end,
            },
            {
                text = _("Progress Decimal Places"),
                help_text = _("Set the number of decimal places to use when reporting reading progress percentage (0-5). Higher precision may be useful for large books. Default is 2."),
                keep_menu_open = true,
                callback = function()
                    Settings:configureProgressDecimalPlaces(self)
                end,
            },
        },
    })
    
    -- Sync Behavior
    table.insert(base_menu, {
        text = _("Manual Sync Only"),
        help_text = _("When enabled, sessions are only synced when you tap 'Sync Now'. When disabled, sessions sync automatically when closing a book with WiFi connected, or when resuming with WiFi connected."),
        checked_func = function()
            return self.manual_sync_only
        end,
        callback = function()
            self:toggleManualSyncOnly()
        end,
    })
    
    -- Manage Sessions submenu
    table.insert(base_menu, {
        text = _("Manage Sessions"),
        sub_item_table = {
            {
                text_func = function()
                    local count = self.db and self.db:getPendingSessionCount() or 0
                    return T(_("Sync Pending Now (%1 sessions)"), tonumber(count) or 0)
                end,
                help_text = _("Manually sync all pending sessions. Sessions are queued when WiFi is unavailable or when 'Manual Sync Only' is enabled."),
                enabled_func = function()
                    return self.db and self.db:getPendingSessionCount() > 0
                end,
                callback = function()
                    self:syncPendingSessions()
                end,
            },
            {
                text = _("View Details"),
                help_text = _("Display statistics about the local cache: number of book hashes cached, file paths cached, and pending sessions."),
                callback = function()
                    self:viewSessionDetails()
                end,
            },
            {
                text = _("Clear Pending Sessions"),
                help_text = _("Delete all locally cached sessions that are waiting to be synced. Use this if you want to discard pending sessions instead of uploading them."),
                enabled_func = function()
                    return self.db and self.db:getPendingSessionCount() > 0
                end,
                callback = function()
                    if self.db then
                        self.db:clearPendingSessions()
                        UIManager:show(InfoMessage:new{
                            text = _("Pending sessions cleared"),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text = _("Clear Cache"),
                help_text = _("Delete all cached book hashes and file path mappings. This will not affect pending sessions. The cache will be rebuilt as you read."),
                enabled_func = function()
                    if not self.db then
                        return false
                    end
                    local stats = self.db:getBookCacheStats()
                    return stats.total > 0
                end,
                callback = function()
                    if self.db then
                        self.db:clearBookCache()
                        UIManager:show(InfoMessage:new{
                            text = _("Local book cache cleared"),
                            timeout = 2,
                        })
                    end
                end,
            },
        },
    })
    
    -- Import Reading History submenu (renamed from Historical Data)
    table.insert(base_menu, {
        text = _("Import Reading History"),
        sub_item_table = {
            {
                text = _("Configure Booklore Account"),
                help_text = _("Configure Booklore username and password for accessing the books API endpoint."),
                callback = function()
                    self:configureBookloreLogin()
                end,
            },
            {
                text = _("Extract Sessions from KOReader"),
                help_text = _("One-time extraction of reading sessions from KOReader's statistics database. This reads page statistics and groups them into sessions. Run this first before matching."),
                enabled_func = function()
                    return self.is_enabled
                end,
                callback = function()
                    self:copySessionsFromKOReader()
                end,
            },
            {
                text = _("Match Books with Booklore"),
                help_text = _("Match extracted sessions with books on Booklore server. For each unmatched book, searches by title and lets you select the correct match. Matched sessions are automatically synced."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:matchHistoricalData()
                end,
            },
            {
                text = _("View Match Statistics"),
                help_text = _("Display statistics about historical sessions: total sessions extracted, matched sessions, unmatched sessions, and synced sessions."),
                callback = function()
                    self:viewMatchStatistics()
                end,
            },
            {
                text = _("Re-sync All Historical"),
                help_text = _("Re-sync all previously synced historical sessions to the server. Sessions with invalid book IDs (404 errors) will be marked for re-matching."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:resyncHistoricalData()
                end,
            },
            {
                text = _("Sync Re-matched Sessions"),
                help_text = _("Sync sessions that were previously marked for re-matching (404 errors) and have now been matched to valid books."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:syncRematchedSessions()
                end,
            },
        },
    })
    
    -- Preferences submenu
    table.insert(base_menu, Settings:buildPreferencesMenu(self))
    
    -- About submenu
    table.insert(base_menu, {
        text = _("About"),
        sub_item_table = {
            {
                text = _("Plugin Information"),
                keep_menu_open = true,
                callback = function()
                    self:showVersionInfo()
                end,
            },
        },
    })
    
    menu_items.booklore_sync = {
        text = _("Booklore Sync"),
        sorting_hint = "tools",
        sub_item_table = base_menu,
    }
end

-- Booklore login configuration for historical data
function BookloreSync:configureBookloreLogin()
    local username_input
    username_input = InputDialog:new{
        title = _("Booklore Username"),
        input = self.booklore_username,
        input_hint = _("Enter Booklore username"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(username_input)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        self.booklore_username = username_input:getInputText()
                        UIManager:close(username_input)
                        
                        -- Now prompt for password
                        local password_input
                        password_input = InputDialog:new{
                            title = _("Booklore Password"),
                            input = self.booklore_password,
                            input_hint = _("Enter Booklore password"),
                            text_type = "password",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(password_input)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            self.booklore_password = password_input:getInputText()
                                            UIManager:close(password_input)
                                            
                                            -- Save settings
                                            self.settings:saveSetting("booklore_username", self.booklore_username)
                                            self.settings:saveSetting("booklore_password", self.booklore_password)
                                            self.settings:flush()
                                            
                                            UIManager:show(InfoMessage:new{
                                                text = _("Booklore login credentials saved"),
                                                timeout = 2,
                                            })
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(password_input)
                        password_input:onShowKeyboard()
                    end,
                },
            },
        },
    }
    UIManager:show(username_input)
    username_input:onShowKeyboard()
end

-- Connection testing
function BookloreSync:testConnection()
    UIManager:show(InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 1,
    })
    
    -- Validate configuration
    if not self.server_url or self.server_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Server URL not configured"),
            timeout = 3,
        })
        return
    end
    
    if not self.username or self.username == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Username not configured"),
            timeout = 3,
        })
        return
    end
    
    if not self.password or self.password == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Password not configured"),
            timeout = 3,
        })
        return
    end
    
    -- Update API client with current credentials
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    local info_msg = InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 0,
    }
    UIManager:show(info_msg)

    self.sync_in_progress = true
    AsyncTask:new(function()
        return pcall(function()
            return self.api:testAuth()
        end)
    end,
    function(success, result_ok, message)
        UIManager:close(info_msg)
        self.sync_in_progress = false
        
        local final_success = success and result_ok
        if final_success then
            UIManager:show(InfoMessage:new{
                text = _("✓ Connection successful!\n\nAuthentication verified."),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("✗ Connection failed\n\n%1"), message or _("Unknown error")),
                timeout = 5,
            })
        end
    end):submit()
end

--[[--
Format duration in seconds to a human-readable string

@param duration_seconds Number of seconds
@return string Formatted duration (e.g., "1h 5m 9s", "45m 30s", "15s")
--]]
function BookloreSync:formatDuration(duration_seconds)
    -- Convert to number in case it's cdata from SQLite
    duration_seconds = tonumber(duration_seconds)
    
    if not duration_seconds or duration_seconds < 0 then
        return "0s"
    end
    
    local hours = math.floor(duration_seconds / 3600)
    local minutes = math.floor((duration_seconds % 3600) / 60)
    local seconds = duration_seconds % 60
    
    local parts = {}
    
    if hours > 0 then
        table.insert(parts, string.format("%dh", hours))
    end
    
    if minutes > 0 then
        table.insert(parts, string.format("%dm", minutes))
    end
    
    if seconds > 0 or #parts == 0 then
        table.insert(parts, string.format("%ds", seconds))
    end
    
    return table.concat(parts, " ")
end

--[[--
Validate if a session should be recorded based on detection mode

@param duration_seconds Number of seconds the session lasted
@param pages_read Number of pages read during the session
@return boolean should_record
@return string reason (if should_record is false)
--]]
function BookloreSync:validateSession(duration_seconds, pages_read)
    if self.session_detection_mode == "pages" then
        -- Pages-based detection
        if pages_read < self.min_pages then
            return false, string.format("Insufficient pages read (%d < %d)", pages_read, self.min_pages)
        end
    else
        -- Duration-based detection (default)
        if duration_seconds < self.min_duration then
            return false, string.format("Session too short (%ds < %ds)", duration_seconds, self.min_duration)
        end
        
        -- Also check pages for duration mode (must have progressed)
        if pages_read <= 0 then
            return false, "No progress made"
        end
    end
    
    return true, "Session valid"
end

--[[--
Round progress to configured decimal places

@param value Progress value to round
@return number Rounded progress value
--]]
function BookloreSync:roundProgress(value)
    local multiplier = 10 ^ self.progress_decimal_places
    return math.floor(value * multiplier + 0.5) / multiplier
end

--[[--
Get current reading progress and location

Returns raw percentage with maximum precision.
Rounding is applied later during API sync based on config.

@return number progress (0-100) with maximum precision
@return string location (page number or position)
--]]
function BookloreSync:getCurrentProgress()
    if not self.ui or not self.ui.document or not self.view or not self.view.state then
        return 0, "0"
    end
    
    local current_page = self.view.state.page or 0
    local total_pages = self.ui.document:getPageCount() or 1
    local progress = 0
    
    if self.view.state.percent then
        -- Use KOReader's native percent calculation (0.0 to 1.0)
        progress = self.view.state.percent * 100
    elseif total_pages > 0 then
        progress = (current_page / total_pages) * 100
    end
    
    return progress, tostring(current_page)
end

--[[--
Get book type from file extension

@param file_path Path to the book file
@return string Book type (EPUB, PDF, etc.)
--]]
function BookloreSync:getBookType(file_path)
    if not file_path then
        return "EPUB"
    end
    
    local ext = file_path:match("^.+%.(.+)$")
    if ext then
        ext = ext:upper()
        if ext == "PDF" then
            return "PDF"
        elseif ext == "CBZ" or ext == "CBR" then
            return "CBX"
        end
    end
    
    return "EPUB"
end

--[[--
Calculate MD5 hash of a book file using sample-based fingerprinting

Uses the same algorithm as Booklore's FileFingerprint:
- Samples chunks at positions: base << (2*i) for i from -1 to 10
- Each chunk is 1024 bytes
- Concatenates all sampled chunks and calculates MD5 hash

@param file_path Path to the book file
@return string MD5 hash or nil on error
--]]
function BookloreSync:calculateBookHash(file_path)
    self:logInfo("BookloreSync: Calculating MD5 hash for:", file_path)
    
    local file = io.open(file_path, "rb")
    if not file then
        self:logWarn("BookloreSync: Could not open file for hashing")
        return nil
    end
    
    local md5 = require("ffi/sha2").md5
    local base = 1024
    local block_size = 1024
    local buffer = {}
    
    -- Get file size
    local file_size = file:seek("end")
    file:seek("set", 0)
    
    self:logInfo("BookloreSync: File size:", file_size)
    
    -- Sample file at specific positions (matching Booklore's FileFingerprint algorithm)
    -- Positions: base << (2*i) for i from -1 to 10
    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        
        if position >= file_size then
            break
        end
        
        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            table.insert(buffer, chunk)
        end
    end
    
    file:close()
    
    -- Calculate MD5 of all sampled chunks
    local combined_data = table.concat(buffer)
    local hash = md5(combined_data)
    
    self:logInfo("BookloreSync: Hash calculated:", hash)
    return hash
end

--[[--
Capture hash, stem, and book_id for a file about to be deleted (synchronous, no network).

Must be called before the file is removed from disk. Returns nil values for
non-EPUB files so that the follow-up network call is skipped. Attempts to
retrieve the book_id from the database cache to avoid unnecessary API searches.

@param filepath Absolute path to the file being deleted
@return string|nil MD5 hash of the file, or nil
@return string|nil Filename stem (no extension), or nil
@return number|nil Booklore book ID from cache, or nil
--]]
function BookloreSync:preDeleteHook(filepath)
    if not filepath then
        return nil, nil, nil
    end

    -- Only process EPUB files
    local stem = filepath:match("([^/\\]+)%.[Ee][Pp][Uu][Bb]$")
    if not stem then
        return nil, nil, nil
    end

    self:logInfo("BookloreSync: preDeleteHook for:", filepath)

    -- Try to get book_id from database cache first
    local book_id = nil
    if self.db then
        local cached_book = self.db:getBookByFilePath(filepath)
        if cached_book then
            self:logInfo("BookloreSync: preDeleteHook — found cached book, book_id:", tostring(cached_book.book_id))
            if cached_book.book_id then
                book_id = tonumber(cached_book.book_id)
                self:logInfo("BookloreSync: preDeleteHook — using cached book_id:", book_id)
            else
                self:logInfo("BookloreSync: preDeleteHook — cached book has no book_id (never synced)")
            end
        else
            self:logInfo("BookloreSync: preDeleteHook — book not found in cache")
        end
    end

    local hash = self:calculateBookHash(filepath)
    if not hash then
        self:logWarn("BookloreSync: preDeleteHook — could not compute hash for:", filepath)
        return nil, nil, nil
    end

    return hash, stem, book_id
end

--[[--
Remove a book from the configured Booklore shelf after local deletion (asynchronous).

Uses the cached book_id if available, otherwise falls back to title-based API search.
All failures are logged and swallowed so that a network issue never surfaces as a
user-visible error during deletion.

@param hash MD5 hash of the deleted file
@param stem Filename stem (no extension) used as title fallback
@param cached_book_id Booklore book ID from database cache (optional)
@param from_queue If true, skip offline check and failure re-queuing (called from sync)
--]]
function BookloreSync:notifyBookloreOnDeletion(hash, stem, cached_book_id, from_queue)
    from_queue = from_queue or false

    -- Check connectivity first (skip if called from queue sync)
    if not from_queue and not NetworkMgr:isConnected() then
        self:logWarn("BookloreSync: notifyBookloreOnDeletion — offline, queuing deletion for later sync")
        if self.db then
            self.db:savePendingDeletion(hash, stem, cached_book_id)
        end
        return
    end

    -- If this is a direct call (not from queue), we should protect it with the sync guard
    -- but notifyBookloreOnDeletion is often called multiple times in a loop (deleteSelectedFiles).
    -- So we'll let AsyncTask handle the queueing/scheduling.
    
    AsyncTask:new(function()
        return pcall(function()
            if self.booklore_username == "" or self.booklore_password == "" then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion — Booklore credentials not set, skipping")
                return true
            end

            self:logInfo("BookloreSync: notifyBookloreOnDeletion — hash:", hash, "stem:", stem, "cached_book_id:", cached_book_id)

            local book_id = cached_book_id

            -- If we don't have a cached book_id, fall back to API search
            if not book_id then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion — no cached book_id, searching via API")
                local search_ok, search_resp = self.api:searchBooksWithAuth(stem, self.booklore_username, self.booklore_password)
                if search_ok and type(search_resp) == "table" and search_resp[1] and search_resp[1].id then
                    book_id = tonumber(search_resp[1].id)
                else
                    local title_part = stem:match("^.+ %- (.+)$")
                    if title_part then
                        local title_ok, title_resp = self.api:searchBooksWithAuth(title_part, self.booklore_username, self.booklore_password)
                        if title_ok and type(title_resp) == "table" and title_resp[1] and title_resp[1].id then
                            book_id = tonumber(title_resp[1].id)
                        end
                    end
                end
            end

            if not book_id then
                self:logWarn("BookloreSync: notifyBookloreOnDeletion — book not found on server, skipping shelf removal")
                return true
            end

            local shelf_ok, shelf_id = self.api:getOrCreateShelf(self.booklore_shelf_name, self.booklore_username, self.booklore_password)
            if not shelf_ok then error(shelf_id or "Failed to get/create shelf") end

            local token_ok, token = self.api:getOrRefreshBearerToken(self.booklore_username, self.booklore_password)
            if not token_ok then error(token or "Failed to get token") end

            local payload = string.format('{"bookIds":[%d],"shelvesToUnassign":[%d],"shelvesToAssign":[]}', book_id, shelf_id)
            local remove_headers = { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }
            local remove_ok, remove_code, remove_resp = self.api:request("POST", "/api/v1/books/shelves", payload, remove_headers)
            
            if remove_ok then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion — book removed from shelf successfully")
                return true
            else
                error(tostring(remove_code) .. ": " .. tostring(remove_resp))
            end
        end)
    end,
    function(success, result_ok, err)
        if not success or not result_ok then
            self:logWarn("BookloreSync: notifyBookloreOnDeletion failed:", err)
            -- Only queue for retry if it wasn't already from the queue sync
            if not from_queue and self.db then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion — queuing for retry")
                self.db:savePendingDeletion(hash, stem, cached_book_id)
            end
        end
    end):submit()
    
    return true
end

--[[--
Look up book ID from server by file hash

Checks database cache first, then queries the server if not found.
Caches successful lookups in the database.

@param book_hash MD5 hash of the book file
@return number Book ID from server or nil if not found
--]]
function BookloreSync:getBookIdByHash(book_hash)
    if not book_hash then
        self:logWarn("BookloreSync: No book hash provided to getBookIdByHash")
        return nil, nil, nil
    end
    
    self:logInfo("BookloreSync: Looking up book ID for hash:", book_hash)
    
    -- Check database cache first
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        self:logInfo("BookloreSync: Found book ID in database cache:", cached_book.book_id)
        return cached_book.book_id, cached_book.isbn10, cached_book.isbn13
    end
    
    -- Not in cache, query server
    self:logInfo("BookloreSync: Book ID not in cache, querying server")
    
    local success, book_data = self.api:getBookByHash(book_hash)
    
    if not success then
        self:logWarn("BookloreSync: Failed to get book from server (offline or error)")
        return nil, nil, nil
    end
    
    if not book_data or not book_data.id then
        self:logInfo("BookloreSync: Book not found on server")
        return nil, nil, nil
    end
    
    -- Ensure book_id is a number (API might return string)
    local book_id = tonumber(book_data.id)
    if not book_id then
        self:logWarn("BookloreSync: Invalid book ID from server:", book_data.id)
        return nil, nil, nil
    end
    
    -- Extract ISBN fields from server response
    local isbn10 = book_data.isbn10 or nil
    local isbn13 = book_data.isbn13 or nil
    
    self:logInfo("BookloreSync: Found book ID on server:", book_id)
    self:logInfo("BookloreSync: Book data from server includes ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    -- Update cache with the book ID and ISBN fields we found
    if cached_book then
        -- We have the hash cached but didn't have the book_id
        -- Use saveBookCache to update all fields including ISBN
        self.db:saveBookCache(
            cached_book.file_path, 
            book_hash, 
            book_id, 
            book_data.title or cached_book.title, 
            book_data.author or cached_book.author,
            isbn10,
            isbn13
        )
        self:logInfo("BookloreSync: Updated database cache with book ID and ISBN")
    end
    
    -- Return both book_id and ISBN data so caller can save if needed
    return book_id, isbn10, isbn13
end

--[[--
Start tracking a reading session

Called when a document is opened
--]]
function BookloreSync:startSession()
    if not self.is_enabled then
        return
    end
    
    if not self.ui or not self.ui.document then
        self:logWarn("BookloreSync: No document available to start session")
        return
    end
    
    local file_path = self.ui.document.file
    if not file_path then
        self:logWarn("BookloreSync: No file path available")
        return
    end
    
    -- Ensure file_path is a string
    file_path = tostring(file_path)
    
    self:logInfo("BookloreSync: ========== Starting session ==========")
    self:logInfo("BookloreSync: File:", file_path)
    self:logInfo("BookloreSync: File path type:", type(file_path))
    self:logInfo("BookloreSync: File path length:", #file_path)
    
    -- Check database for this file
    self:logInfo("BookloreSync: Calling getBookByFilePath...")
    local ok, cached_book = pcall(function()
        return self.db:getBookByFilePath(file_path)
    end)
    
    if not ok then
        self:logErr("BookloreSync: Error in getBookByFilePath:", cached_book)
        self:logErr("  file_path:", file_path)
        return
    end
    
    self:logInfo("BookloreSync: getBookByFilePath completed")
    local file_hash = nil
    local book_id = nil
    
    if cached_book then
        self:logInfo("BookloreSync: Found book in cache - ID:", cached_book.book_id, "Hash:", cached_book.file_hash)
        file_hash = cached_book.file_hash
        -- Ensure book_id from cache is a number (defensive programming)
        book_id = cached_book.book_id and tonumber(cached_book.book_id) or nil
    else
        self:logInfo("BookloreSync: Book not in cache, calculating hash")
        -- Calculate hash for new book
        file_hash = self:calculateBookHash(file_path)
        
        if not file_hash then
            self:logWarn("BookloreSync: Failed to calculate book hash, continuing without hash")
        else
            self:logInfo("BookloreSync: Hash calculated:", file_hash)
            
            -- Try to look up book ID from server by hash (only if network available)
            local isbn10, isbn13
            if NetworkMgr:isConnected() then
                self:logInfo("BookloreSync: Network connected, looking up book on server")
                book_id, isbn10, isbn13 = self:getBookIdByHash(file_hash)
                
                if book_id then
                    self:logInfo("BookloreSync: Book ID found on server:", book_id)
                    if isbn10 or isbn13 then
                        self:logInfo("BookloreSync: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
                    end
                else
                    self:logInfo("BookloreSync: Book not found on server (not in library)")
                end
            else
                self:logInfo("BookloreSync: No network connection, skipping server lookup")
                self:logInfo("BookloreSync: Book will be cached locally and resolved when online")
            end
            
            -- Cache the book info in database (including ISBN if available)
            self:logInfo("BookloreSync: Calling saveBookCache with:")
            self:logInfo("  file_path:", file_path, "type:", type(file_path))
            self:logInfo("  file_hash:", file_hash, "type:", type(file_hash))
            self:logInfo("  book_id:", book_id, "type:", type(book_id))
            self:logInfo("  isbn10:", isbn10, "isbn13:", isbn13)
            
            local ok, result = pcall(function()
                return self.db:saveBookCache(file_path, file_hash, book_id, nil, nil, isbn10, isbn13)
            end)
            
            if not ok then
                self:logErr("BookloreSync: Error in saveBookCache:", result)
                self:logErr("  file_path:", file_path)
                self:logErr("  file_hash:", file_hash)
                self:logErr("  book_id:", book_id)
            else
                if result then
                    self:logInfo("BookloreSync: Book cached in database successfully")
                else
                    self:logWarn("BookloreSync: Failed to cache book in database")
                end
            end
        end
    end
    
    -- Get current reading position
    local start_progress, start_location = self:getCurrentProgress()
    
    -- Get book title and KOReader book ID from statistics database
    local koreader_book_id = nil
    local book_title = nil
    
    if file_hash then
        local koreader_book = self:_getKOReaderBookByHash(file_hash)
        if koreader_book then
            koreader_book_id = koreader_book.koreader_book_id
            book_title = koreader_book.koreader_book_title
            self:logInfo("BookloreSync: Found in KOReader stats - ID:", koreader_book_id, "Title:", book_title)
        end
    end
    
    -- Fallback: extract from filename if not found in KOReader database
    if not book_title then
        book_title = file_path:match("([^/]+)$") or file_path
        book_title = book_title:gsub("%.[^.]+$", "")  -- Remove extension
        self:logInfo("BookloreSync: Using filename as title:", book_title)
    end
    
    -- Create session tracking object
    self.current_session = {
        file_path = file_path,
        book_id = book_id,
        file_hash = file_hash,
        book_title = book_title,
        koreader_book_id = koreader_book_id,
        start_time = os.time(),
        start_progress = start_progress,
        start_location = start_location,
        book_type = self:getBookType(file_path),
    }
    
    self:logInfo("BookloreSync: Session started for '", book_title, "' at", start_progress, "% (location:", start_location, ")")
end

--[[--
End the current reading session and save to database

Called when document closes, device suspends, or returns to menu

@param options Table with options:
  - silent: Don't show UI messages
  - force_queue: Always queue instead of trying to sync
--]]
function BookloreSync:endSession(options)
    options = options or {}
    local silent = options.silent or false
    local force_queue = options.force_queue or self.manual_sync_only
    
    if not self.current_session then
        self:logInfo("BookloreSync: No active session to end")
        return
    end
    
    self:logInfo("BookloreSync: ========== Ending session ==========")
    
    -- Get current reading position
    local end_progress, end_location = self:getCurrentProgress()
    local end_time = os.time()
    local duration_seconds = end_time - self.current_session.start_time
    
    -- Calculate pages read (absolute difference in locations)
    local pages_read = 0
    local start_loc = tonumber(self.current_session.start_location) or 0
    local end_loc = tonumber(end_location) or 0
    pages_read = math.abs(end_loc - start_loc)
    
    self:logInfo("BookloreSync: Duration:", duration_seconds, "s, Pages read:", pages_read)
    self:logInfo("BookloreSync: Progress:", self.current_session.start_progress, "% ->", end_progress, "%")
    
    -- Validate session
    local valid, reason = self:validateSession(duration_seconds, pages_read)
    if not valid then
        self:logInfo("BookloreSync: Session invalid -", reason)
        self.current_session = nil
        return
    end
    
    -- Calculate progress delta (store with maximum precision)
    local progress_delta = end_progress - self.current_session.start_progress
    
    -- Format timestamp for API (ISO 8601)
    local function formatTimestamp(unix_time)
        return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_time)
    end
    
    -- Prepare session data
    local session_data = {
        bookId = self.current_session.book_id,
        bookHash = self.current_session.file_hash,
        bookTitle = self.current_session.book_title,
        koreaderBookId = self.current_session.koreader_book_id,
        bookType = self.current_session.book_type,
        startTime = formatTimestamp(self.current_session.start_time),
        endTime = formatTimestamp(end_time),
        durationSeconds = duration_seconds,
        startProgress = self.current_session.start_progress,
        endProgress = end_progress,
        progressDelta = progress_delta,
        startLocation = self.current_session.start_location,
        endLocation = end_location,
    }
    
    self:logInfo("BookloreSync: Session valid - Duration:", duration_seconds, "s, Progress delta:", progress_delta, "%")
    
    -- Save to pending sessions database
    local success = self.db:addPendingSession(session_data)
    
    if success then
        self:logInfo("BookloreSync: Session saved to pending queue")
        
        if not silent and not self.silent_messages then
            local pending_count = self.db:getPendingSessionCount()
            UIManager:show(InfoMessage:new{
                text = T(_("Session saved (%1 pending)"), tonumber(pending_count) or 0),
                timeout = 2,
            })
        end
        
        -- If not in manual-only mode and not forced to queue, try to sync
        if not force_queue and not self.manual_sync_only then
            self:logInfo("BookloreSync: Attempting automatic sync")
            self:syncPendingSessions(true) -- silent sync
        end
    else
        self:logErr("BookloreSync: Failed to save session to database")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Failed to save reading session"),
                timeout = 2,
            })
        end
    end
    
    -- Clear current session
    self.current_session = nil
end

-- Event Handlers

--[[--
Handler for when a document is opened and ready
--]]
function BookloreSync:onReaderReady()
    self:logInfo("BookloreSync: Reader ready")
    self:startSession()
    return false -- Allow other plugins to process this event
end

--[[--
Handler for when a document is closed
--]]
function BookloreSync:onCloseDocument()
    if not self.is_enabled then
        return false
    end
    
    self:logInfo("BookloreSync: Document closing")
    self:endSession({ silent = false, force_queue = false })
    return false
end

--[[--
Handler for when the device is about to suspend
--]]
function BookloreSync:onSuspend()
    if not self.is_enabled then
        return false
    end

    self:logInfo("BookloreSync: Device suspending")

    -- Queue current session
    self:endSession({ silent = true, force_queue = true })

    return false
end

--[[--
Handler for when the device resumes from suspend
--]]
function BookloreSync:onResume()
    if not self.is_enabled then
        return false
    end

    -- Task B: Add 5-minute cooldown to on-resume auto-sync
    local now = os.time()
    if self.last_auto_sync_time and (now - self.last_auto_sync_time) < 300 then
        self:logInfo("BookloreSync: Skipping resume auto-sync (cooldown active, last run", (now - self.last_auto_sync_time), "s ago)")
        return false
    end
    self.last_auto_sync_time = now

    self:logInfo("BookloreSync: Device resuming")

    -- Sync pending items if WiFi is already connected
    if NetworkMgr:isConnected() then
        self:logInfo("BookloreSync: WiFi connected, syncing pending items")
        self:syncPendingSessions(true)
        self:syncPendingDeletions(true)
        
        -- Trigger shelf sync if enabled
        if self.auto_sync_shelf_on_resume then
            self:logInfo("BookloreSync: Triggering auto-sync from shelf on resume")
            UIManager:scheduleIn(5, function()
                self:syncFromBookloreShelf()
            end)
        end
    else
        self:logInfo("BookloreSync: WiFi not connected, skipping sync")
    end

    -- If a book is currently open, start a new session
    if self.ui and self.ui.document then
        self:logInfo("BookloreSync: Book is open, starting new session")
        self:startSession()
    end

    return false
end

function BookloreSync:syncPendingSessions(silent)
    if silent == nil then silent = (self.ui and self.ui.document and true or false) end
    
    if self.sync_in_progress then
        self:logWarn("BookloreSync: Sync already in progress, skipping pending sessions sync")
        return
    end

    if not self.db then
        return
    end
    
    local pending_count = tonumber(self.db:getPendingSessionCount()) or 0
    if pending_count == 0 then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("No pending sessions to sync"), timeout = 2 })
        end
        return
    end
    
    self.sync_in_progress = true
    local info_msg
    if not silent and not self.silent_messages then
        info_msg = InfoMessage:new{
            text = T(_("Syncing %1 pending sessions..."), pending_count),
            timeout = 0,  -- Persistent progress feedback for long-running sync
        }
        UIManager:show(info_msg)
    end
    
    AsyncTask:new(function()
        -- Update API client with current credentials
        self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
        local sessions = self.db:getPendingSessions(BATCH_UPLOAD_SIZE)
        
        local synced_count = 0
        local failed_count = 0
        
        local function syncSession(i)
            if i > #sessions then
                if info_msg then UIManager:close(info_msg) end
                self.sync_in_progress = false
                if not silent and not self.silent_messages then
                    local message = ""
                    if synced_count > 0 and failed_count > 0 then
                        message = T(_("Synced %1 sessions, %2 failed"), synced_count, failed_count)
                    elseif synced_count > 0 then
                        message = T(_("All %1 sessions synced successfully!"), synced_count)
                    else
                        message = _("All sync attempts failed - check connection")
                    end
                    UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
                end
                return
            end
            local session = sessions[i]
            if not session.bookId and session.bookHash then
                self.api:getBookByHash(session.bookHash, function(success, book_data)
                    if success and book_data and book_data.id then
                        session.bookId = tonumber(book_data.id)
                        if session.bookId then self.db:updateBookId(session.bookHash, session.bookId) end
                    end
                    if session.bookId then
                        local session_data = {
                            bookId = session.bookId,
                            bookType = session.bookType,
                            startTime = session.startTime,
                            endTime = session.endTime,
                            durationSeconds = session.durationSeconds,
                            durationFormatted = self:formatDuration(session.durationSeconds),
                            startProgress = self:roundProgress(session.startProgress),
                            endProgress = self:roundProgress(session.endProgress),
                            progressDelta = self:roundProgress(session.progressDelta),
                            startLocation = session.startLocation,
                            endLocation = session.endLocation,
                        }
                        self.api:submitSession(session_data, function(success, message, code)
                            if success then
                                synced_count = synced_count + 1
                                self.db:archivePendingSession(session.id)
                                self.db:deletePendingSession(session.id)
                            else
                                failed_count = failed_count + 1
                                self.db:incrementSessionRetryCount(session.id)
                            end
                            syncSession(i + 1)
                        end)
                    else
                        failed_count = failed_count + 1
                        self.db:incrementSessionRetryCount(session.id)
                        syncSession(i + 1)
                    end
                end)
            else
                if session.bookId then
                    local session_data = {
                        bookId = session.bookId,
                        bookType = session.bookType,
                        startTime = session.startTime,
                        endTime = session.endTime,
                        durationSeconds = session.durationSeconds,
                        durationFormatted = self:formatDuration(session.durationSeconds),
                        startProgress = self:roundProgress(session.startProgress),
                        endProgress = self:roundProgress(session.endProgress),
                        progressDelta = self:roundProgress(session.progressDelta),
                        startLocation = session.startLocation,
                        endLocation = session.endLocation,
                    }
                    self.api:submitSession(session_data, function(success, message, code)
                        if success then
                            synced_count = synced_count + 1
                            self.db:archivePendingSession(session.id)
                            self.db:deletePendingSession(session.id)
                        else
                            failed_count = failed_count + 1
                            self.db:incrementSessionRetryCount(session.id)
                        end
                        syncSession(i + 1)
                    end)
                else
                    failed_count = failed_count + 1
                    self.db:incrementSessionRetryCount(session.id)
                    syncSession(i + 1)
                end
            end
        end
        syncSession(1)
    end):submit()
end

--[[--
Sync pending deletions that were queued while offline

Processes the pending_deletions queue and attempts to remove books from the shelf.
Removes successful deletions from queue, increments retry count for failures.
Skips items with retry_count > 10 to prevent infinite accumulation.

@param silent boolean Don't show UI messages if true
--]]
function BookloreSync:syncPendingDeletions(silent)
    if silent == nil then silent = (self.ui and self.ui.document and true or false) end
    
    if self.sync_in_progress then
        self:logWarn("BookloreSync: Sync already in progress, skipping pending deletions sync")
        return
    end

    if not self.db then
        return
    end

    local deletions = self.db:getPendingDeletions()
    if #deletions == 0 then
        return
    end

    self.sync_in_progress = true
    self:logInfo("BookloreSync: Syncing", #deletions, "pending deletions")
    
    local info_msg
    if not silent then
        info_msg = InfoMessage:new{
            text = T(_("Syncing %1 pending deletions..."), #deletions),
            timeout = 0,  -- Persistent progress feedback for long-running sync
        }
        UIManager:show(info_msg)
    end
    
    AsyncTask:new(function()
        return pcall(function()
            -- Update API client with current credentials
            self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
            
            -- Cache shelf and token outside loop to avoid repeated synchronous calls
            local shelf_ok, shelf_id = self.api:getOrCreateShelf(self.booklore_shelf_name, self.booklore_username, self.booklore_password)
            local token_ok, token = self.api:getOrRefreshBearerToken(self.booklore_username, self.booklore_password)
            
            local synced_count = 0
            local failed_count = 0
            local skipped_count = 0

            for i, deletion in ipairs(deletions) do
                if deletion.retry_count > 10 then
                    self.db:removePendingDeletion(deletion.id)
                    skipped_count = skipped_count + 1
                    goto continue
                end

                local book_id = deletion.book_id
                if not book_id and deletion.file_hash then
                    local success, book_data = self.api:getBookByHash(deletion.file_hash)
                    if success and book_data and book_data.id then
                        book_id = tonumber(book_data.id)
                    end
                end

                if book_id then
                    -- Use cached shelf and token
                    if shelf_ok and token_ok then
                        local payload = string.format('{"bookIds":[%d],"shelvesToUnassign":[%d],"shelvesToAssign":[]}', book_id, shelf_id)
                        local headers = { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }
                        local ok, code, resp = self.api:request("POST", "/api/v1/books/shelves", payload, headers)
                        if ok then
                            self.db:removePendingDeletion(deletion.id)
                            synced_count = synced_count + 1
                        else
                            self.db:incrementDeletionRetry(deletion.id)
                            failed_count = failed_count + 1
                        end
                    else
                        self.db:incrementDeletionRetry(deletion.id)
                        failed_count = failed_count + 1
                    end
                else
                    self.db:removePendingDeletion(deletion.id)
                    synced_count = synced_count + 1
                end

                ::continue::
            end
            return true, synced_count, failed_count, skipped_count
        end)
    end,
    function(success, result_ok, synced_count, failed_count, skipped_count)
        self.sync_in_progress = false
        if info_msg then UIManager:close(info_msg) end
        if not success or not result_ok then
            self:logErr("BookloreSync: syncPendingDeletions failed")
            return
        end
        self:logInfo("BookloreSync: Deletion sync complete - synced:", synced_count, "failed:", failed_count)
        if not silent and synced_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Synced %1 shelf removals"), synced_count),
                timeout = 2,
            })
        end
    end):submit()
end

--[[--
Resolve book IDs for cached books that don't have them yet
Queries the server for books cached while offline
@param silent boolean Don't show UI messages if true
--]]
function BookloreSync:resolveUnmatchedBooks(silent)
    if silent == nil then silent = (self.ui and self.ui.document and true or false) end
    
    if self.sync_in_progress then
        self:logWarn("BookloreSync: Sync already in progress, skipping resolveUnmatchedBooks")
        return
    end

    if not self.db then
        return
    end

    local unmatched_books = self.db:getAllUnmatchedBooks()
    if #unmatched_books == 0 then
        return
    end

    self.sync_in_progress = true
    self:logInfo("BookloreSync: resolveUnmatchedBooks — starting resolution task")

    local info_msg
    if not silent then
        info_msg = InfoMessage:new{
            text = _("Resolving unmatched books..."),
            timeout = 0,
        }
        UIManager:show(info_msg)
    end

    AsyncTask:new(function()
        return pcall(function()
            -- Update API client with current credentials
            self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
            
            local resolved_count = 0
            for i, book in ipairs(unmatched_books) do
                if book.file_hash and book.file_hash ~= "" then
                    local book_id, isbn10, isbn13 = self:getBookIdByHash(book.file_hash)
                    if book_id then
                        self.db:saveBookCache(
                            book.file_path,
                            book.file_hash,
                            book_id,
                            book.title,
                            book.author,
                            isbn10,
                            isbn13
                        )
                        resolved_count = resolved_count + 1
                    end
                end
            end
            return true, resolved_count
        end)
    end,
    function(success, result_ok, resolved_count)
        self.sync_in_progress = false
        if info_msg then UIManager:close(info_msg) end

        if not success or not result_ok then
            self:logErr("BookloreSync: resolveUnmatchedBooks failed")
            return
        end

        self:logInfo("BookloreSync: resolveUnmatchedBooks complete, resolved:", resolved_count)
        if not silent and resolved_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Resolved %1 unmatched books"), resolved_count),
                timeout = 3,
            })
        end
    end):submit()
end

function BookloreSync:copySessionsFromKOReader()
    -- Check if already run
    if self.db:hasHistoricalSessions() then
        UIManager:show(ConfirmBox:new{
            text = _("Historical sessions already extracted. Re-running will add duplicate sessions. Continue?"),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:_extractHistoricalSessions()
            end,
        })
        return
    end
    
    -- Show initial warning
    UIManager:show(ConfirmBox:new{
        text = _("This will extract reading sessions from KOReader's statistics database.\n\nThis should only be done once to avoid duplicates.\n\nContinue?"),
        ok_text = _("Extract Sessions"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_extractHistoricalSessions()
        end,
    })
end

function BookloreSync:_extractHistoricalSessions()
    -- Show processing message
    UIManager:show(InfoMessage:new{
        text = _("Extracting sessions from KOReader database..."),
        timeout = 1,
    })
    
    -- 1. Find statistics.sqlite3
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        UIManager:show(InfoMessage:new{
            text = _("KOReader statistics database not found"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Found statistics database at:", stats_db_path)
    
    -- 2. Open statistics database
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        UIManager:show(InfoMessage:new{
            text = _("Failed to open statistics database"),
            timeout = 3,
        })
        return
    end
    
    -- 3. Get all books
    local books = self:_getKOReaderBooks(stats_conn)
    self:logInfo("BookloreSync: Found", #books, "books in statistics")
    
    -- 4. Calculate sessions for each book
    local all_sessions = {}
    local books_with_sessions = 0
    
    for i, book in ipairs(books) do
        local page_stats = self:_getPageStats(stats_conn, book.id)
        
        if #page_stats > 0 then
            local sessions = self:_calculateSessionsFromPageStats(page_stats, book)
            
            -- Filter out 0% progress sessions
            local valid_sessions = {}
            for _, session in ipairs(sessions) do
                if session.progress_delta > 0 then
                    table.insert(valid_sessions, session)
                end
            end
            
            if #valid_sessions > 0 then
                for _, session in ipairs(valid_sessions) do
                    table.insert(all_sessions, session)
                end
                books_with_sessions = books_with_sessions + 1
            end
        end
    end
    
    stats_conn:close()
    
    -- 5. Store in database
    if #all_sessions > 0 then
        local success = self.db:addHistoricalSessions(all_sessions)
        
        if success then
            UIManager:show(InfoMessage:new{
                text = T(_("Found %1 reading sessions from %2 books\n\nStored in database"), 
                         #all_sessions, books_with_sessions),
                timeout = 4,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to store sessions in database"),
                timeout = 3,
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = _("No reading sessions found in KOReader database"),
            timeout = 3,
        })
    end
end

function BookloreSync:_calculateSessionsFromPageStats(page_stats, book)
    -- Implements 5-minute gap logic to group page reads into sessions
    -- Based on bookloresessionmigration.py lines 61-131
    
    if not page_stats or #page_stats == 0 then
        return {}
    end
    
    local sessions = {}
    local current_session = nil
    local SESSION_GAP_SECONDS = 300  -- 5 minutes
    
    for _, stat in ipairs(page_stats) do
        -- KOReader stores timestamps as Unix epoch integers (may be cdata)
        -- Strip "LL" suffix from cdata string representation if present
        local timestamp_str = tostring(stat.start_time):gsub("LL$", "")
        local timestamp = tonumber(timestamp_str)
        if not timestamp then
            self:logWarn("BookloreSync: Failed to parse timestamp:", stat.start_time)
            goto continue
        end
        
        -- Convert to ISO 8601 for Booklore API
        local iso_time = self:_unixToISO8601(timestamp)
        
        -- Calculate progress as 0-100 percentage (consistent with live sessions)
        local progress = (stat.total_pages and stat.total_pages > 0) 
            and ((stat.page / stat.total_pages) * 100) or 0
        
        if not current_session then
            -- Start first session
            current_session = {
                start_time = iso_time,
                end_time = iso_time,
                start_timestamp = timestamp,
                end_timestamp = timestamp,
                start_progress = progress,
                end_progress = progress,
                start_page = stat.page,
                end_page = stat.page,
                duration_seconds = stat.duration or 0,
            }
        else
            local gap = timestamp - current_session.end_timestamp
            
            if gap > SESSION_GAP_SECONDS then
                -- Save current session if progress increased
                local start_progress = current_session.start_progress or 0
                local end_progress = current_session.end_progress or 0
                local progress_delta = end_progress - start_progress
                if progress_delta > 0 then
                    table.insert(sessions, {
                        start_time = current_session.start_time,
                        end_time = current_session.end_time,
                        duration_seconds = current_session.duration_seconds,
                        start_progress = current_session.start_progress,
                        end_progress = current_session.end_progress,
                        progress_delta = progress_delta,
                        start_location = tostring(current_session.start_page),
                        end_location = tostring(current_session.end_page),
                    })
                end
                
                -- Start new session
                current_session = {
                    start_time = iso_time,
                    end_time = iso_time,
                    start_timestamp = timestamp,
                    end_timestamp = timestamp,
                    start_progress = progress,
                    end_progress = progress,
                    start_page = stat.page,
                    end_page = stat.page,
                    duration_seconds = stat.duration or 0,
                }
            else
                -- Continue current session
                current_session.end_time = iso_time
                current_session.end_timestamp = timestamp
                current_session.end_progress = progress
                current_session.end_page = stat.page
                current_session.duration_seconds = current_session.duration_seconds + (stat.duration or 0)
            end
        end
        
        ::continue::
    end
    
    -- Save final session
    if current_session then
        local start_progress = current_session.start_progress or 0
        local end_progress = current_session.end_progress or 0
        local progress_delta = end_progress - start_progress
        if progress_delta > 0 then
            table.insert(sessions, {
                start_time = current_session.start_time,
                end_time = current_session.end_time,
                duration_seconds = current_session.duration_seconds,
                start_progress = current_session.start_progress,
                end_progress = current_session.end_progress,
                progress_delta = progress_delta,
                start_location = tostring(current_session.start_page),
                end_location = tostring(current_session.end_page),
            })
        end
    end
    
    -- Try auto-matching with priority: Hash → ISBN → File Path
    local book_id = nil
    local matched = 0
    
    if book.md5 and book.md5 ~= "" then
        -- Priority 1: Check by hash
        local cached_book = self.db:getBookByHash(book.md5)
        if cached_book and cached_book.book_id then
            book_id = cached_book.book_id
            matched = 1
            self:logInfo("BookloreSync: Auto-matched historical book by hash:", book.title, "→ ID:", book_id)
        else
            -- Priority 2: Check by ISBN (if we have cached ISBN for this hash)
            if cached_book and (cached_book.isbn13 or cached_book.isbn10) then
                local isbn_match = self.db:findBookIdByIsbn(cached_book.isbn10, cached_book.isbn13)
                if isbn_match and isbn_match.book_id then
                    book_id = isbn_match.book_id
                    matched = 1
                    self:logInfo("BookloreSync: Auto-matched historical book by ISBN:", book.title, "→ ID:", book_id)
                end
            end
        end
    end
    
    -- Priority 3: Check by file path (if book file exists)
    if not book_id and book.file and book.file ~= "" then
        local file_cached = self.db:getBookByFilePath(book.file)
        if file_cached and file_cached.book_id then
            book_id = file_cached.book_id
            matched = 1
            self:logInfo("BookloreSync: Auto-matched historical book by file path:", book.title, "→ ID:", book_id)
        end
    end
    
    -- Add book metadata to each session
    for _, session in ipairs(sessions) do
        session.koreader_book_id = book.id
        session.koreader_book_title = book.title
        session.book_id = book_id
        session.book_hash = book.md5
        session.book_type = self:_detectBookType(book)
        session.matched = matched
    end
    
    return sessions
end

function BookloreSync:_findKOReaderStatisticsDB()
    -- The statistics database is in the KOReader settings directory
    local stats_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    
    local f = io.open(stats_path, "r")
    if f then
        f:close()
        return stats_path
    end
    
    return nil
end

function BookloreSync:_getKOReaderBooks(conn)
    -- Query all books from KOReader statistics database
    local books = {}
    
    local stmt = conn:prepare("SELECT id, title, authors, md5 FROM book")
    
    if not stmt then
        self:logErr("BookloreSync: Failed to prepare statement:", conn:errmsg())
        return books
    end
    
    for row in stmt:rows() do
        table.insert(books, {
            id = tonumber(row[1]),
            title = tostring(row[2] or ""),
            authors = tostring(row[3] or ""),
            md5 = tostring(row[4] or ""),
        })
    end
    
    stmt:close()
    return books
end

function BookloreSync:_getKOReaderBookByHash(file_hash)
    -- Query KOReader statistics database to get book ID and title by hash
    if not file_hash or file_hash == "" then
        return nil
    end
    
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        self:logDbg("BookloreSync: Statistics database not found")
        return nil
    end
    
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        self:logWarn("BookloreSync: Failed to open statistics database")
        return nil
    end
    
    local stmt = stats_conn:prepare("SELECT id, title FROM book WHERE md5 = ?")
    if not stmt then
        self:logWarn("BookloreSync: Failed to prepare statement:", stats_conn:errmsg())
        stats_conn:close()
        return nil
    end
    
    stmt:bind(file_hash)
    
    local book_info = nil
    for row in stmt:rows() do
        book_info = {
            koreader_book_id = tonumber(row[1]),
            koreader_book_title = tostring(row[2] or "Unknown"),
        }
        break
    end
    
    stmt:close()
    stats_conn:close()
    
    return book_info
end

function BookloreSync:_getPageStats(conn, book_id)
    -- Query page statistics for a specific book
    local stats = {}
    
    local stmt = conn:prepare([[
        SELECT start_time, duration, total_pages, page 
        FROM page_stat_data 
        WHERE id_book = ? 
        ORDER BY start_time
    ]])
    
    if not stmt then
        self:logErr("BookloreSync: Failed to prepare statement:", conn:errmsg())
        return stats
    end
    
    stmt:bind(book_id)
    
    for row in stmt:rows() do
        table.insert(stats, {
            start_time = tostring(row[1] or ""),
            duration = tonumber(row[2]) or 0,
            total_pages = tonumber(row[3]) or 0,
            page = tonumber(row[4]) or 0,
        })
    end
    
    stmt:close()
    return stats
end

function BookloreSync:_unixToISO8601(timestamp)
    -- Convert Unix timestamp to ISO 8601 string
    -- Example: 1707648600 -> "2024-02-11T10:30:00Z"
    local date_table = os.date("!*t", timestamp)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        date_table.year, date_table.month, date_table.day,
        date_table.hour, date_table.min, date_table.sec)
end

function BookloreSync:_parseISO8601(iso_string)
    -- Convert ISO 8601 timestamp to Unix time
    -- Example: "2024-02-11T10:30:00Z" -> 1707648600
    
    if not iso_string then return nil end
    
    local year, month, day, hour, min, sec = iso_string:match(
        "(%d+)-(%d+)-(%d+)%a(%d+):(%d+):(%d+)"
    )
    
    if not year then return nil end
    
    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
        isdst = false,
    })
end

function BookloreSync:_detectBookType(book)
    -- Detect book format from title extension
    local title = book.title or ""
    local lower_title = title:lower()
    
    if lower_title:match("%.pdf$") then
        return "PDF"
    elseif lower_title:match("%.cbz$") then
        return "CBZ"
    elseif lower_title:match("%.cbr$") then
        return "CBR"
    elseif lower_title:match("%.djvu$") then
        return "DJVU"
    else
        return "EPUB"
    end
end

function BookloreSync:_formatDuration(seconds)
    -- Format duration like: "5m 9s", "1h 23m 45s", "45s"
    -- Only include non-zero parts
    local parts = {}
    
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    if hours > 0 then
        table.insert(parts, string.format("%dh", hours))
    end
    if mins > 0 then
        table.insert(parts, string.format("%dm", mins))
    end
    if secs > 0 or #parts == 0 then  -- Always show seconds if duration is 0
        table.insert(parts, string.format("%ds", secs))
    end
    
    return table.concat(parts, " ")
end

--[[--
Group sessions by book_id for batch upload

@param sessions Array of session objects
@return table Grouped sessions { book_id = {book_type = ..., sessions = {...}} }
--]]
function BookloreSync:_groupSessionsByBook(sessions)
    local grouped = {}
    
    for _, session in ipairs(sessions) do
        local book_id = session.book_id
        if book_id then
            if not grouped[book_id] then
                grouped[book_id] = {
                    book_type = session.book_type,
                    sessions = {}
                }
            end
            table.insert(grouped[book_id].sessions, session)
        end
    end
    
    return grouped
end

--[[--
Submit a single session to the server

@param session Session object with all required fields
@return boolean success
@return string message
@return number|nil code
--]]
function BookloreSync:_submitSingleSession(session)
    local start_progress = session.start_progress or 0
    local end_progress = session.end_progress or 0
    local progress_delta = session.progress_delta or (end_progress - start_progress)
    
    local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
    
    return self.api:submitSession({
        bookId = session.book_id,
        bookType = session.book_type,
        startTime = session.start_time,
        endTime = session.end_time,
        durationSeconds = session.duration_seconds,
        durationFormatted = duration_formatted,
        startProgress = self:roundProgress(start_progress),
        endProgress = self:roundProgress(end_progress),
        progressDelta = self:roundProgress(progress_delta),
        startLocation = session.start_location,
        endLocation = session.end_location,
    })
end

--[[--
Upload sessions with intelligent batching

Uses batch upload for 2+ sessions, individual for single session.
Automatically splits large batches into chunks of BATCH_UPLOAD_SIZE.
Falls back to individual upload if batch endpoint returns 404.

@param book_id Booklore book ID
@param book_type Book type (EPUB, PDF, etc.)
@param sessions Array of session objects to upload
@return number synced_count Number of successfully synced sessions
@return number failed_count Number of failed sessions
@return number not_found_count Number of 404 errors (book not found)
--]]
function BookloreSync:_uploadSessionsWithBatching(book_id, book_type, sessions)
    local synced_count = 0
    local failed_count = 0
    local not_found_count = 0
    
    -- Handle empty input
    if not sessions or #sessions == 0 then
        return synced_count, failed_count, not_found_count
    end
    
    -- Single session: use individual upload
    if #sessions == 1 then
        local session = sessions[1]
        local success, message, code = self:_submitSingleSession(session)
        
        if success then
            self.db:markHistoricalSessionSynced(session.id)
            synced_count = 1
        elseif code == 404 then
            self:logWarn("BookloreSync: Book ID", book_id, "not found on server (404), marking session for re-matching")
            self.db:markHistoricalSessionUnmatched(session.id)
            not_found_count = 1
        else
            failed_count = 1
        end
        
        return synced_count, failed_count, not_found_count
    end
    
    -- Multiple sessions: use batch upload with chunking
    local batch_size = BATCH_UPLOAD_SIZE
    local total_sessions = #sessions
    local batch_count = math.ceil(total_sessions / batch_size)
    
    self:logInfo("BookloreSync: Uploading", total_sessions, "sessions in", batch_count, "batch(es) for book:", book_id)
    
    for batch_num = 1, batch_count do
        local start_idx = (batch_num - 1) * batch_size + 1
        local end_idx = math.min(batch_num * batch_size, total_sessions)
        local batch_sessions = {}
        
        -- Build batch payload array
        for i = start_idx, end_idx do
            local session = sessions[i]
            local start_progress = session.start_progress or 0
            local end_progress = session.end_progress or 0
            local progress_delta = session.progress_delta or (end_progress - start_progress)
            
            table.insert(batch_sessions, {
                startTime = session.start_time,
                endTime = session.end_time,
                durationSeconds = session.duration_seconds,
                durationFormatted = self:_formatDuration(session.duration_seconds or 0),
                startProgress = self:roundProgress(start_progress),
                endProgress = self:roundProgress(end_progress),
                progressDelta = self:roundProgress(progress_delta),
                startLocation = session.start_location,
                endLocation = session.end_location,
            })
        end
        
        -- Try batch upload
        self:logInfo("BookloreSync: Attempting batch", batch_num, "of", batch_count, "with", (end_idx - start_idx + 1), "sessions")
        local success, message, code = self.api:submitSessionBatch(book_id, book_type, batch_sessions)
        self:logInfo("BookloreSync: Batch", batch_num, "result - success:", tostring(success), "code:", tostring(code or "nil"), "message:", tostring(message or "nil"))

        if success then
            -- Mark all sessions in batch as synced
            for i = start_idx, end_idx do
                self.db:markHistoricalSessionSynced(sessions[i].id)
                synced_count = synced_count + 1
            end
            self:logInfo("BookloreSync: Batch", batch_num, "of", batch_count, "uploaded successfully (" .. (end_idx - start_idx + 1) .. " sessions)")
        elseif code == 404 then
            -- Server doesn't have batch endpoint (404) OR book not found (404)
            -- Fallback to individual upload to determine which
            self:logWarn("BookloreSync: Batch returned 404 - falling back to individual upload for batch", batch_num)

            for i = start_idx, end_idx do
                local session = sessions[i]
                self:logInfo("BookloreSync: Attempting individual upload for session", session.id, "(" .. (i - start_idx + 1) .. " of " .. (end_idx - start_idx + 1) .. ")")
                local single_success, single_message, single_code = self:_submitSingleSession(session)
                self:logInfo("BookloreSync: Session", session.id, "result - success:", tostring(single_success), "code:", tostring(single_code or "nil"), "message:", tostring(single_message or "nil"))

                if single_success then
                    self.db:markHistoricalSessionSynced(session.id)
                    synced_count = synced_count + 1
                elseif single_code == 404 then
                    self:logWarn("BookloreSync: Book ID", book_id, "not found on server (404), marking session", session.id, "for re-matching")
                    self.db:markHistoricalSessionUnmatched(session.id)
                    not_found_count = not_found_count + 1
                else
                    self:logWarn("BookloreSync: Session", session.id, "failed - code:", tostring(single_code or "nil"), "message:", tostring(single_message or "nil"))
                    failed_count = failed_count + 1
                end
            end
        elseif code == 403 then
            -- Authentication/permission error - cannot be fixed by retrying individually
            self:logErr("BookloreSync: Batch upload failed with 403 Forbidden - authentication or permission error")
            self:logErr("BookloreSync: Please check your Booklore credentials and server permissions")
            self:logErr("BookloreSync: All", (end_idx - start_idx + 1), "sessions in batch", batch_num, "marked as failed")
            failed_count = failed_count + (end_idx - start_idx + 1)
        else
            -- Other error: all sessions in batch failed
            self:logErr("BookloreSync: Batch upload failed for batch", batch_num, "of", batch_count,
                       "(" .. (end_idx - start_idx + 1) .. " sessions) - Error:", message, "Code:", tostring(code or "nil"))
            failed_count = failed_count + (end_idx - start_idx + 1)
        end
    end
    
    return synced_count, failed_count, not_found_count
end

function BookloreSync:matchHistoricalData()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    if not self.db:hasHistoricalSessions() then
        UIManager:show(InfoMessage:new{
            text = _("No historical sessions found. Please copy sessions from KOReader first."),
            timeout = 3,
        })
        return
    end
    
    -- PHASE 1: Auto-sync sessions that were matched during extraction
    local matched_unsynced_books = self.db:getMatchedUnsyncedBooks()
    
    if matched_unsynced_books and #matched_unsynced_books > 0 then
        self:logInfo("BookloreSync: Found", #matched_unsynced_books, 
                   "books with auto-matched but unsynced sessions")
        self:_autoSyncMatchedSessions(matched_unsynced_books)
        return
    end
    
    -- PHASE 2: Manual matching for truly unmatched books (no book_id)
    self:_startManualMatching()
end

function BookloreSync:_autoSyncMatchedSessions(books)
    -- Auto-sync sessions for books that were matched during extraction
    -- Shows progress indicator similar to re-sync feature
    
    if not books or #books == 0 then
        self:_startManualMatching()
        return
    end
    
    local total_books = #books
    local total_sessions = 0
    for _, book in ipairs(books) do
        total_sessions = total_sessions + book.unsynced_session_count
    end
    
    self:logInfo("BookloreSync: Auto-syncing", total_sessions, "sessions from", total_books, "matched books")
    
    -- Initialize progress indicator
    local progress_msg = InfoMessage:new{
        text = T(_("Auto-syncing matched sessions...\n\n0 / %1 books\n0 / %2 sessions\n\nSynced: 0\nFailed: 0"),
            total_books, total_sessions),
    }
    UIManager:show(progress_msg)
    
    -- Initialize sync state
    self.autosync_books = books
    self.autosync_index = 1
    self.autosync_total_synced = 0
    self.autosync_total_failed = 0
    self.autosync_total_not_found = 0
    self.autosync_total_books = total_books
    self.autosync_total_sessions = total_sessions
    self.autosync_progress_msg = progress_msg
    
    -- Start syncing
    self:_syncNextMatchedBook()
end

function BookloreSync:_syncNextMatchedBook()
    if not self.autosync_books or self.autosync_index > #self.autosync_books then
        -- Auto-sync phase complete
        UIManager:close(self.autosync_progress_msg)
        
        local result_text = T(_("Auto-sync complete!\n\nBooks processed: %1\nSessions synced: %2\nFailed: %3"), 
                             #self.autosync_books,
                             self.autosync_total_synced, 
                             self.autosync_total_failed)
        
        -- Add not found count if any
        if self.autosync_total_not_found and self.autosync_total_not_found > 0 then
            result_text = result_text .. T(_("\nMarked for re-matching (404): %1"), self.autosync_total_not_found)
        end
        
        UIManager:show(InfoMessage:new{
            text = result_text,
            timeout = 4,
        })
        
        self:logInfo("BookloreSync: Auto-sync complete - synced:", self.autosync_total_synced,
                   "failed:", self.autosync_total_failed, "not found:", self.autosync_total_not_found or 0)
        
        -- Clean up state
        self.autosync_books = nil
        self.autosync_index = nil
        self.autosync_total_synced = nil
        self.autosync_total_failed = nil
        self.autosync_total_not_found = nil
        self.autosync_total_books = nil
        self.autosync_total_sessions = nil
        self.autosync_progress_msg = nil
        
        -- Proceed to Phase 2: Manual matching
        self:_startManualMatching()
        return
    end
    
    local book = self.autosync_books[self.autosync_index]
    
    -- Update progress indicator
    UIManager:close(self.autosync_progress_msg)
    self.autosync_progress_msg = InfoMessage:new{
        text = T(_("Auto-syncing matched sessions...\n\n%1 / %2 books\n%3 / %4 sessions\n\nSynced: %5\nFailed: %6\n\nCurrent: %7"),
            self.autosync_index, 
            self.autosync_total_books,
            self.autosync_total_synced + self.autosync_total_failed,
            self.autosync_total_sessions,
            self.autosync_total_synced,
            self.autosync_total_failed,
            book.koreader_book_title),
    }
    UIManager:show(self.autosync_progress_msg)
    UIManager:forceRePaint()
    
    -- Get unsynced sessions for this book
    local sessions = self.db:getHistoricalSessionsForBookUnsynced(book.koreader_book_id)
    
    if not sessions or #sessions == 0 then
        self:logWarn("BookloreSync: No unsynced sessions found for book:", book.koreader_book_title)
        self.autosync_index = self.autosync_index + 1
        self:_syncNextMatchedBook()
        return
    end
    
    -- Sync sessions for this book using batch upload
    local synced_count, failed_count, not_found_count = 
        self:_uploadSessionsWithBatching(
            sessions[1].book_id,
            sessions[1].book_type,
            sessions
        )
    
    -- Update totals
    self.autosync_total_synced = self.autosync_total_synced + synced_count
    self.autosync_total_failed = self.autosync_total_failed + failed_count
    self.autosync_total_not_found = (self.autosync_total_not_found or 0) + not_found_count
    
    self:logInfo("BookloreSync: Auto-synced", synced_count, "sessions for:", book.koreader_book_title,
               "(", failed_count, "failed,", not_found_count, "not found)")
    
    -- Move to next book
    self.autosync_index = self.autosync_index + 1
    self:_syncNextMatchedBook()
end

function BookloreSync:_startManualMatching()
    -- Phase 2: Manual matching for books without book_id
    local unmatched = self.db:getUnmatchedHistoricalBooks()
    
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All historical sessions are matched and synced!"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Starting manual matching for", #unmatched, "books")
    
    -- Start matching process with first unmatched book
    self.matching_index = 1
    self.unmatched_books = unmatched
    self:_showNextBookMatch()
end

function BookloreSync:_showNextBookMatch()
    if not self.unmatched_books or self.matching_index > #self.unmatched_books then
        UIManager:show(InfoMessage:new{
            text = _("Matching complete!"),
            timeout = 2,
        })
        return
    end
    
    local book = self.unmatched_books[self.matching_index]
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- PRIORITY 0: Check if book already has book_id cached (auto-sync without confirmation)
    -- This happens when sessions were extracted with enhanced auto-matching enabled
    if book.book_hash and book.book_hash ~= "" then
        local cached_book = self.db:getBookByHash(book.book_hash)
        
        if cached_book and cached_book.book_id then
            self:logInfo("BookloreSync: Found cached book_id for unmatched book, auto-syncing:", book.koreader_book_title)
            
            -- Mark sessions as matched
            local match_success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, cached_book.book_id)
            
            if not match_success then
                self:logErr("BookloreSync: Failed to mark sessions as matched for auto-sync")
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
                return
            end
            
            -- Get sessions and sync directly using the helper function
            local sessions = self.db:getHistoricalSessionsForBook(book.koreader_book_id)
            
            if sessions and #sessions > 0 then
                self:_syncHistoricalSessions(book, sessions, progress_text)
            else
                self:logWarn("BookloreSync: No sessions found for auto-matched book")
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end
            return
        end
    end
    
    -- PRIORITY 1: Check for ISBN in cache and search by ISBN
    if book.book_hash and book.book_hash ~= "" then
        local cached_book = self.db:getBookByHash(book.book_hash)
        
        if cached_book then
            -- Check if we have ISBN data for this book
            if (cached_book.isbn13 and cached_book.isbn13 ~= "") or 
               (cached_book.isbn10 and cached_book.isbn10 ~= "") then
                
                if self.booklore_username and self.booklore_password then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Looking up by ISBN: %1\n\n%2"), 
                            book.koreader_book_title, progress_text),
                        timeout = 1,
                    })
                    
                    -- Prefer ISBN-13, fall back to ISBN-10
                    local search_isbn = cached_book.isbn13 or cached_book.isbn10
                    local isbn_type = cached_book.isbn13 and "isbn13" or "isbn10"
                    
                    local success, results = self.api:searchBooksByIsbn(
                        search_isbn,
                        self.booklore_username,
                        self.booklore_password
                    )
                    
                    if success and results and #results > 0 then
                        -- Take first result (should be exact match)
                        self:_confirmIsbnMatch(book, results[1], isbn_type)
                        return
                    end
                    
                    self:logInfo("BookloreSync: ISBN search failed or no results, continuing to hash lookup")
                end
            end
            
            -- PRIORITY 2: Check if book_id already cached (local hash match)
            if cached_book.book_id then
                self:_confirmAutoMatch(book, cached_book.book_id)
                return
            end
        end
    end
    
    -- PRIORITY 3: Check server by hash
    if book.book_hash and book.book_hash ~= "" then
        if self.booklore_username and self.booklore_password then
            UIManager:show(InfoMessage:new{
                text = T(_("Looking up by hash: %1\n\n%2"), 
                    book.koreader_book_title, progress_text),
                timeout = 1,
            })
            
            local success, server_book = self.api:getBookByHashWithAuth(
                book.book_hash, 
                self.booklore_username, 
                self.booklore_password
            )
            
            if success and server_book then
                self:_confirmHashMatch(book, server_book)
                return
            end
        end
    end
    
    -- PRIORITY 4: Fall back to title search
    self:_performManualSearch(book)
end

function BookloreSync:_confirmAutoMatch(book, book_id)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Get book title from cache
    local book_title = "Unknown Book"
    local cached_book = self.db:getBookByBookId(book_id)
    if cached_book then
        book_title = cached_book.title
    end
    
    UIManager:show(ConfirmBox:new{
        text = T(_("Auto-matched by MD5 hash:\n\nKOReader: %1\n\nBooklore: %2\n\n%3\n\nAccept this match?"),
            book.koreader_book_title, book_title, progress_text),
        ok_text = _("Accept"),
        cancel_text = _("Skip"),
        ok_callback = function()
            self:_saveMatchAndSync(book, book_id)
        end,
        cancel_callback = function()
            self.matching_index = self.matching_index + 1
            self:_showNextBookMatch()
        end,
    })
end

function BookloreSync:_confirmHashMatch(book, server_book)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    local ButtonDialog = require("ui/widget/buttondialog")
    
    self.hash_match_dialog = ButtonDialog:new{
        title = T(_("Found by hash:\n\n%1\n\n%2"), server_book.title or "Unknown", progress_text),
        buttons = {
            {
                {
                    text = _("Proceed"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self:_saveMatchAndSync(book, server_book)
                    end,
                },
            },
            {
                {
                    text = _("Manual Match"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self:_performManualSearch(book)
                    end,
                },
            },
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self.matching_index = self.matching_index + 1
                        self:_showNextBookMatch()
                    end,
                },
            },
        },
    }
    
    UIManager:show(self.hash_match_dialog)
end

function BookloreSync:_confirmIsbnMatch(book, server_book, matched_isbn_type)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    local ButtonDialog = require("ui/widget/buttondialog")
    
    -- Show which ISBN type matched (ISBN-10 or ISBN-13)
    local isbn_indicator = matched_isbn_type == "isbn13" and "📚 ISBN-13" or "📖 ISBN-10"
    
    self.isbn_match_dialog = ButtonDialog:new{
        title = T(_("%1\n\nFound: %2\n\n%3"), 
            isbn_indicator,
            server_book.title or "Unknown", 
            progress_text),
        buttons = {
            {
                {
                    text = _("Proceed"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self:_saveMatchAndSync(book, server_book)
                    end,
                },
            },
            {
                {
                    text = _("Manual Match"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self:_performManualSearch(book)
                    end,
                },
            },
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self.matching_index = self.matching_index + 1
                        self:_showNextBookMatch()
                    end,
                },
            },
        },
    }
    
    UIManager:show(self.isbn_match_dialog)
end

function BookloreSync:_performManualSearch(book)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Search by title
    UIManager:show(InfoMessage:new{
        text = T(_("Searching for: %1\n\n%2"), book.koreader_book_title, progress_text),
        timeout = 1,
    })
    
    local success, results = self.api:searchBooksWithAuth(book.koreader_book_title, self.booklore_username, self.booklore_password)
    
    if not success then
        -- Get error message (results contains error message on failure)
        local error_msg = type(results) == "string" and results or "Unknown error"
        
        UIManager:show(ConfirmBox:new{
            text = T(_("Search failed for:\n%1\n\nError: %2\n\n%3\n\nSkip this book?"), 
                book.koreader_book_title, error_msg, progress_text),
            ok_text = _("Skip"),
            cancel_text = _("Retry"),
            ok_callback = function()
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end,
            cancel_callback = function()
                -- Retry the same book
                self:_showNextBookMatch()
            end,
        })
        return
    end
    
    if not results or #results == 0 then
        UIManager:show(ConfirmBox:new{
            text = T(_("No matches found for:\n%1\n\n%2\n\nSkip this book?"), 
                book.koreader_book_title, progress_text),
            ok_callback = function()
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end,
        })
        return
    end
    
    self:_showMatchSelectionDialog(book, results)
end

function BookloreSync:_showMatchSelectionDialog(book, results)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Limit to top 5 results
    local top_results = {}
    for i = 1, math.min(5, #results) do
        table.insert(top_results, results[i])
    end
    
    local buttons = {}
    
    -- Add match options
    for i, result in ipairs(top_results) do
        table.insert(buttons, {{
            text = T(_("%1. %2 (Score: %3)"), i, result.title, 
                string.format("%.0f%%", (result.matchScore or 0) * 100)),
            callback = function()
                UIManager:close(self.match_dialog)
                self:_saveMatchAndSync(book, result)
            end,
        }})
    end
    
    -- Add skip button
    table.insert(buttons, {{
        text = _("Skip this book"),
        callback = function()
            UIManager:close(self.match_dialog)
            self.matching_index = self.matching_index + 1
            self:_showNextBookMatch()
        end,
    }})
    
    -- Add cancel button
    table.insert(buttons, {{
        text = _("Cancel matching"),
        callback = function()
            UIManager:close(self.match_dialog)
        end,
    }})
    
    self.match_dialog = ButtonDialog:new{
        title = T(_("Select match for:\n%1\n\n%2 sessions found\n\n%3"), 
            book.koreader_book_title, book.session_count, progress_text),
        buttons = buttons,
    }
    
    UIManager:show(self.match_dialog)
end

function BookloreSync:_saveMatchAndSync(book, selected_result)
    -- Extract book_id from selected_result (can be object or just ID for auto-match)
    local book_id = type(selected_result) == "table" and selected_result.id or selected_result
    local book_title = type(selected_result) == "table" and selected_result.title or book.koreader_book_title
    local isbn10 = type(selected_result) == "table" and selected_result.isbn10 or nil
    local isbn13 = type(selected_result) == "table" and selected_result.isbn13 or nil
    
    self:logInfo("BookloreSync: Saving match with ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    -- Mark sessions as matched
    local success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, book_id)
    
    if not success then
        UIManager:show(InfoMessage:new{
            text = _("Failed to save match to database"),
            timeout = 3,
        })
        return
    end
    
    -- Store matched book in book_cache for future syncs
    -- Use the hash from the book record (from historical_sessions)
    if book.book_hash and book.book_hash ~= "" then
        -- Use the hash as a pseudo file path for historical books
        local cache_path = "historical://" .. book.book_hash
        self.db:saveBookCache(cache_path, book.book_hash, book_id, book_title, nil, isbn10, isbn13)
        self:logInfo("BookloreSync: Cached matched book:", book_title, "with ID:", book_id)
    end
    
    -- Get matched sessions
    local sessions = self.db:getHistoricalSessionsForBook(book.koreader_book_id)
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No sessions found to sync"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    -- Use the helper function to sync sessions
    self:_syncHistoricalSessions(book, sessions, nil)
end

function BookloreSync:_syncHistoricalSessions(book, sessions, progress_text)
    -- Helper function to sync historical sessions for a matched book
    -- Used by both _saveMatchAndSync and auto-sync in _showNextBookMatch
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No sessions found to sync"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    -- Filter out already-synced sessions
    local unsynced_sessions = {}
    for _, session in ipairs(sessions) do
        if not session.synced or session.synced == 0 then
            table.insert(unsynced_sessions, session)
        end
    end
    
    if #unsynced_sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All sessions already synced"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    -- Use batch upload helper
    local synced_count, failed_count, not_found_count = 
        self:_uploadSessionsWithBatching(
            unsynced_sessions[1].book_id,
            unsynced_sessions[1].book_type,
            unsynced_sessions
        )
    
    -- Show results
    local result_text = T(_("Synced %1 sessions for:\n%2"), synced_count, book.koreader_book_title)
    if progress_text then
        result_text = result_text .. "\n\n" .. progress_text
    end
    if failed_count > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions failed to sync"), failed_count)
    end
    if not_found_count > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions marked for re-matching (404)"), not_found_count)
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 2,
    })
    
    -- Move to next book
    self.matching_index = self.matching_index + 1
    self:_showNextBookMatch()
end

function BookloreSync:viewMatchStatistics()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    local stats = self.db:getHistoricalSessionStats()
    
    if not stats then
        UIManager:show(InfoMessage:new{
            text = _("Failed to retrieve statistics"),
            timeout = 2,
        })
        return
    end
    
    -- Convert cdata to Lua numbers for template function
    local total = tonumber(stats.total_sessions) or 0
    local matched = tonumber(stats.matched_sessions) or 0
    local unmatched = tonumber(stats.unmatched_sessions) or 0
    local synced = tonumber(stats.synced_sessions) or 0
    
    if total == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No historical sessions found.\n\nPlease copy sessions from KOReader first."),
            timeout = 3,
        })
        return
    end
    
    UIManager:show(InfoMessage:new{
        text = T(_("Historical Session Statistics:\n\nTotal sessions: %1\nMatched sessions: %2\nUnmatched sessions: %3\nSynced to server: %4"), 
            total, matched, unmatched, synced),
        timeout = 5,
    })
end

function BookloreSync:resyncHistoricalData()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = _("This will re-sync all previously synced historical sessions to the server.\n\nSessions with invalid book IDs (404 errors) will be marked for re-matching.\n\nContinue?"),
        ok_text = _("Re-sync"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_performResyncHistoricalData()
        end,
    })
end

function BookloreSync:_performResyncHistoricalData()
    -- Get all synced historical sessions
    local sessions = self.db:getAllSyncedHistoricalSessions()
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No synced historical sessions found to re-sync"),
            timeout = 3,
        })
        return
    end
    
    -- Group sessions by book_id
    local grouped = self:_groupSessionsByBook(sessions)
    
    -- Count total books and sessions
    local total_books = 0
    local total_sessions = #sessions
    for _ in pairs(grouped) do
        total_books = total_books + 1
    end
    
    self:logInfo("BookloreSync: Re-syncing", total_sessions, "sessions from", total_books, "books")
    
    -- Show initial progress
    local progress_msg = InfoMessage:new{
        text = T(_("Re-syncing historical sessions...\n\n0 / %1 books (0 sessions)"), total_books),
        timeout = 0,  -- Persistent progress feedback
    }
    UIManager:show(progress_msg)
    
    AsyncTask:new(function()
        return pcall(function()
            local books_completed = 0
            local total_synced = 0
            local total_failed = 0
            local total_not_found = 0
            
            -- Upload each book's sessions as batch
            for book_id, book_data in pairs(grouped) do
                books_completed = books_completed + 1
                
                -- Batch upload sessions for this book
                local synced, failed, not_found = 
                    self:_uploadSessionsWithBatching(book_id, book_data.book_type, book_data.sessions)
                
                total_synced = total_synced + synced
                total_failed = total_failed + failed
                total_not_found = total_not_found + not_found
                
                self:logInfo("BookloreSync: Book", book_id, "- synced:", synced, 
                            "failed:", failed, "not found:", not_found)
            end
            
            return true, total_books, total_synced, total_failed, total_not_found
        end)
    end,
    function(success, result_ok, total_books, total_synced, total_failed, total_not_found)
        UIManager:close(progress_msg)
        
        if not success or not result_ok then
            self:logErr("BookloreSync: resyncHistoricalData failed")
            UIManager:show(InfoMessage:new{
                text = _("Re-sync failed: unknown error"),
                timeout = 5,
            })
            return
        end
        
        local result_text = T(_("Re-sync complete!\n\nSuccessfully synced: %1\nFailed: %2\nMarked for re-matching (404): %3"), 
            total_synced, total_failed, total_not_found)
        
        if total_not_found > 0 then
            result_text = result_text .. _("\n\nUse 'Match Historical Data' to re-match sessions with 404 errors.")
        end
        
        UIManager:show(InfoMessage:new{
            text = result_text,
            timeout = 5,
        })
        
        self:logInfo("BookloreSync: Re-sync complete - synced:", total_synced, 
                    "failed:", total_failed, "not found:", total_not_found)
    end):submit()
end

function BookloreSync:syncRematchedSessions()
    -- Sync sessions that were previously marked for re-matching (404 errors)
    -- and have now been matched to valid books
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    -- Get matched but unsynced sessions
    local sessions = self.db:getMatchedUnsyncedHistoricalSessions()
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No re-matched sessions found to sync"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Syncing", #sessions, "re-matched sessions")
    
    -- Group by book and batch upload
    local grouped = self:_groupSessionsByBook(sessions)
    
    local total_synced = 0
    local total_failed = 0
    local total_not_found = 0
    
    for book_id, book_data in pairs(grouped) do
        local synced, failed, not_found = 
            self:_uploadSessionsWithBatching(book_id, book_data.book_type, book_data.sessions)
        
        total_synced = total_synced + synced
        total_failed = total_failed + failed
        total_not_found = total_not_found + not_found
    end
    
    -- Show results
    local result_text = T(_("Successfully synced %1 re-matched session(s)"), total_synced)
    if total_failed > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions failed"), total_failed)
    end
    if total_not_found > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions marked for re-matching (404)"), total_not_found)
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 3,
    })
    
    self:logInfo("BookloreSync: Re-matched sync complete - synced:", total_synced,
                "failed:", total_failed, "not found:", total_not_found)
end

--[[--
Show version information dialog
--]]
function BookloreSync:showVersionInfo()
    Settings:showVersion(self)
end

return BookloreSync
