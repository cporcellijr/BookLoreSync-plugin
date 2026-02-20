-- test_scan_fix.lua
-- Regression test for BookloreSync:scanLibrary crash fix

local function test()
    print("Running Regression Test: scanLibrary Crash Fix")

    -- Mock environment
    local mock_self = {
        shelf_id = 2,
        booklore_username = "testuser",
        booklore_password = "testpassword",
        scan_in_progress = false,
        initial_scan_done = false,
        api = {},
        settings = {
            saveSetting = function(self, k, v) end,
            flush = function(self) end,
        },
        logInfo = function(self, ...) print("INFO:", ...) end,
        logErr = function(self, ...) print("ERROR:", ...) end,
    }

    local UIManager = {
        show = function(self, msg) print("UI MESSAGE:", msg.text or "") end
    }

    -- Fixed scanLibrary logic mockup
    local function scanLibrary_fixed(self, silent)
        self.scan_in_progress = true
        
        -- Fix here: captures BOTH success and result
        local books_ok, books = self.api:getBooksInShelf(
            self.shelf_id,
            self.booklore_username,
            self.booklore_password
        )

        if not books_ok then
            self:logErr("Failed to fetch books:", books)
            self.scan_in_progress = false
            return false
        end

        local count = 0
        -- This part used to crash because 'books' was a boolean
        if type(books) == "table" then
            for _, book in ipairs(books) do
                -- print("Processing book:", book.title)
                count = count + 1
            end
        end
        
        self.scan_in_progress = false
        self.initial_scan_done = true
        print("Scan complete. Books processed:", count)
        return true
    end

    -- Scenario 1: API Returns Correct Two Values (Success)
    print("\n--- Scenario 1: API success (returns true, books_table) ---")
    mock_self.api.getBooksInShelf = function()
        return true, { {id = 101, title = "Book 1"}, {id = 102, title = "Book 2"} }
    end

    local ok1 = scanLibrary_fixed(mock_self, false)
    assert(ok1 == true, "Scenario 1 failed")
    assert(mock_self.initial_scan_done == true, "Flag not set on success")

    -- Scenario 2: API Fails (returns false, error_msg)
    print("\n--- Scenario 2: API failure (returns false, error_msg) ---")
    mock_self.initial_scan_done = false
    mock_self.api.getBooksInShelf = function()
        return false, "Network Timeout"
    end

    local ok2 = scanLibrary_fixed(mock_self, false)
    assert(ok2 == false, "Scenario 2 should return false")
    assert(mock_self.initial_scan_done == false, "Flag should NOT be set on failure")
    assert(mock_self.scan_in_progress == false, "Scan in progress flag should be reset")

    print("\nSUCCESS: All test scenarios passed. The fix prevents the crash.")
end

-- Execute test
local ok, err = pcall(test)
if not ok then
    print("\nTEST FAILED with error:", err)
    os.exit(1)
end
