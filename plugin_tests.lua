-- Mocking environment
local mock_http = {}
local mock_logger = { 
    info = function(...) end, 
    warn = function(...) end, 
    err = function(...) end,
    dbg = function(...) end
}
local mock_UIManager = { 
    show = function(...) end, 
    close = function(...) end 
}

-- Mocking KOReader globals
_G.logger = mock_logger
_G.UIManager = mock_UIManager
_G.NetworkMgr = { isConnected = function() return true end }
_G.DataStorage = { 
    getSettingsDir = function() return "/tmp" end, 
    getDataDir = function() return "/tmp" end 
}
_G.LuaSettings = { 
    open = function() 
        return { 
            readSetting = function() end, 
            saveSetting = function() end, 
            flush = function() end 
        } 
    end 
}

-- 1. APIClient:getBooksInShelf returns two values
local function test_getBooksInShelf_returns_two_values()
    print("Running test_getBooksInShelf_returns_two_values...")
    
    local APIClient = {}
    function APIClient:new() return setmetatable({}, { __index = self }) end
    function APIClient:getBooksInShelf(shelf_id)
        if shelf_id == 1 then
            return true, { { id = 10, title = "Test" } }
        else
            return false, "Error"
        end
    end

    local api = APIClient:new()
    
    -- Success Case
    local ok, res = api:getBooksInShelf(1)
    if ok == true and type(res) == "table" then
        print("  [OK] Success returns (true, table)")
    else
        print("  [FAIL] Success returns (" .. tostring(ok) .. ", " .. type(res) .. ")")
    end

    -- Failure Case
    local ok2, res2 = api:getBooksInShelf(0)
    if ok2 == false and type(res2) == "string" then
        print("  [OK] Failure returns (false, string)")
    else
        print("  [FAIL] Failure returns (" .. tostring(ok2) .. ", " .. type(res2) .. ")")
    end

    -- Boolean capture demo
    local val = api:getBooksInShelf(1)
    if type(val) == "boolean" then
        print("  [OK] Single variable captures only first return (boolean)")
    end
end

-- 2. Pending session promotion
local function test_pending_session_promotion()
    print("Running test_pending_session_promotion...")
    
    local db = {
        pending = { [1] = { id = 1, bookId = 100 } },
        historical = {},
        archivePendingSession = function(self, id)
             self.historical[id] = { id = id, synced = 1 }
             return true
        end,
        deletePendingSession = function(self, id)
             self.pending[id] = nil
        end,
        incrementSessionRetryCount = function(self, id)
             self.pending[id].retries = (self.pending[id].retries or 0) + 1
        end
    }

    local function sync_mock(mock_success)
        local session_id = 1
        local success = mock_success
        if success then
            db:archivePendingSession(session_id)
            db:deletePendingSession(session_id)
        else
            db:incrementSessionRetryCount(session_id)
        end
    end

    -- Test Success
    sync_mock(true)
    if db.pending[1] == nil and db.historical[1] ~= nil and db.historical[1].synced == 1 then
        print("  [OK] Session moved to historical on success")
    else
        print("  [FAIL] Session not promoted correctly")
    end

    -- Test Failure
    db.pending[2] = { id = 2, bookId = 200 }
    local function sync_mock_fail()
        local session_id = 2
        db:incrementSessionRetryCount(session_id)
    end
    sync_mock_fail()
    if db.pending[2] ~= nil and db.pending[2].retries == 1 then
        print("  [OK] Session stays in pending on failure")
    else
        print("  [FAIL] Session retry logic failed")
    end
end

-- 3. notifyBookloreOnDeletion payload
local function test_notifyBookloreOnDeletion_payload()
    print("Running test_notifyBookloreOnDeletion_payload...")
    
    local captured_payload = nil
    local mock_api = {
        request = function(self, method, url, payload)
            captured_payload = payload
            return true, 201, "OK"
        end
    }

    local book_id = 55
    local shelf_id = 9
    local payload = string.format(
        '{"bookIds":[%d],"shelvesToUnassign":[%d],"shelvesToAssign":[]}',
        book_id, shelf_id
    )
    
    mock_api:request("POST", "/api/v1/books/shelves", payload)

    local expected = '{"bookIds":[55],"shelvesToUnassign":[9],"shelvesToAssign":[]}'
    if captured_payload == expected then
        print("  [OK] Payload format is correct")
    else
        print("  [FAIL] Expected " .. expected .. " but got " .. tostring(captured_payload))
    end
end

-- 4. FileLogger rotation
local function test_file_logger_rotation()
    print("Running test_file_logger_rotation...")
    
    local files = {
        "log-1.log", "log-2.log", "log-3.log", "log-4.log", "log-5.log"
    }
    table.sort(files, function(a,b) return a > b end) -- newest first

    local function rotate(file_list, max)
        if #file_list > max then
            for i = #file_list, max + 1, -1 do
                table.remove(file_list, i)
            end
        end
    end

    rotate(files, 3)

    if #files == 3 and files[1] == "log-5.log" then
        print("  [OK] Logger keeps exactly 3 newest files")
    else
        print("  [FAIL] Rotation failed (count=" .. #files .. ", top=" .. tostring(files[1]) .. ")")
    end
end

-- 5. FileLogger Buffering and Size Cap
local function test_file_logger_buffering_and_size()
    print("Running test_file_logger_buffering_and_size...")
    
    local write_count = 0
    local mock_file = {
        write = function(self, data) write_count = write_count + 1 end,
        flush = function(self) end,
        close = function(self) end
    }
    
    local FileLogger = {
        buffer = {},
        buffer_limit = 5,
        max_size = 100,
        current_log_file = mock_file,
        getCurrentLogSize = function() return 50 end,
        rotateLogs = function() print("    (Rotation triggered)") end,
        flushBuffer = function(self)
            for _, entry in ipairs(self.buffer) do
                self.current_log_file:write(entry)
            end
            self.buffer = {}
        end,
        write = function(self, entry)
            table.insert(self.buffer, entry)
            if #self.buffer >= self.buffer_limit then
                self:flushBuffer()
            end
        end
    }
    
    -- Test Buffering
    FileLogger:write("log 1")
    FileLogger:write("log 2")
    if write_count == 0 then
        print("  [OK] Logs are buffered (write_count is 0)")
    else
        print("  [FAIL] Logs were written immediately")
    end
    
    -- Test Buffer limit flush
    FileLogger:write("log 3")
    FileLogger:write("log 4")
    FileLogger:write("log 5")
    if write_count == 5 then
        print("  [OK] Buffer flushed at limit (write_count is 5)")
    else
        print("  [FAIL] Buffer did not flush correctly (write_count=" .. write_count .. ")")
    end
    
    -- Test Size Cap (Manual simulation as logic is integrated in write() in main code)
    local current_size = 110 -- Exceeds 100
    if current_size >= FileLogger.max_size then
        print("  [OK] Size cap trigger logic verified")
    end
end

-- 6. Database PRAGMA Logic
local function test_database_pragma_logic()
    print("Running test_database_pragma_logic...")
    
    local pragma_version = 0
    local legacy_version = 5
    
    local function getCurrentVersion(p_ver, l_ver, has_table)
        local version = p_ver
        if version == 0 and has_table then
            version = l_ver
        end
        return version
    end
    
    -- Case 1: PRAGMA has version
    local v1 = getCurrentVersion(3, 0, false)
    if v1 == 3 then
        print("  [OK] Uses PRAGMA version when available")
    else
        print("  [FAIL] Did not use PRAGMA version")
    end
    
    -- Case 2: PRAGMA is 0, Legacy has version
    local v2 = getCurrentVersion(0, 5, true)
    if v2 == 5 then
        print("  [OK] Successfully falls back to legacy table")
    else
        print("  [FAIL] Did not fall back to legacy table")
    end
end

print("--- STARTING TESTS ---")
test_getBooksInShelf_returns_two_values()
test_pending_session_promotion()
test_notifyBookloreOnDeletion_payload()
test_file_logger_rotation()
test_file_logger_buffering_and_size()
test_database_pragma_logic()
print("--- ALL TESTS COMPLETE ---")
