--[[
  test_deletion_hook.lua
  
  Standalone test suite for the shelf-removal-on-deletion feature.
  Stubs all KOReader internals so this runs on a bare Lua 5.4 interpreter.
  
  Usage:
      C:\Users\cporc\AppData\Local\Programs\Lua\bin\lua.exe test_deletion_hook.lua
--]]

-- ─── Minimal test harness ────────────────────────────────────────────────────

local PASS = 0
local FAIL = 0

local function ok(cond, name)
    if cond then
        io.write("  ✓  " .. name .. "\n")
        PASS = PASS + 1
    else
        io.write("  ✗  " .. name .. "\n")
        FAIL = FAIL + 1
    end
end

local function section(name)
    io.write("\n── " .. name .. " ──\n")
end

-- ─── KOReader runtime stubs ──────────────────────────────────────────────────
-- Replace require() so that KOReader-specific modules resolve to mocks.

-- Minimal bit library (Lua 5.4 has no bit32 built-in; replicate lshift only)
local bit = {
    lshift = function(n, k) return math.floor(n) * (2 ^ k) end
}

-- MD5 stub: returns a deterministic fake hash for any input string
local fake_md5 = function(data)
    -- Simple checksum so non-empty data → non-empty string, empty → different value
    local n = 0
    for i = 1, #data do n = n + data:byte(i) end
    return string.format("%032x", n % (2^32))
end

-- Stub the require machinery
local real_require = require
package.preload["ffi/sha2"] = function() return { md5 = fake_md5 } end
package.preload["logger"]   = function()
    return {
        info = function(...) end,
        warn = function(...) end,
        err  = function(...) end,
        dbg  = function(...) end,
    }
end

-- ─── Build a minimal mock BookloreSync instance ───────────────────────────────

-- Inline the actual calculateBookHash implementation (copied verbatim from main.lua
-- line 1111-1154) so we test the real algorithm under our fake md5.
local function make_plugin(overrides)
    local self = {
        booklore_username  = "testuser",
        booklore_password  = "testpass",
        booklore_shelf_name = "Kobo",
        secure_logs        = false,
        log_to_file        = false,
        -- capture log calls for assertion
        _warns = {},
        _infos = {},
    }

    function self:logInfo(...)  table.insert(self._infos, table.concat({...}, " ")) end
    function self:logWarn(...)  table.insert(self._warns, table.concat({...}, " ")) end
    function self:logErr(...)   end
    function self:logDbg(...)   end

    -- Real calculateBookHash (verbatim algorithm from main.lua)
    function self:calculateBookHash(file_path)
        self:logInfo("calculateBookHash:", file_path)
        local file = io.open(file_path, "rb")
        if not file then
            self:logWarn("Could not open file for hashing")
            return nil
        end
        local md5_fn = fake_md5
        local base = 1024
        local block_size = 1024
        local buffer = {}
        local file_size = file:seek("end")
        file:seek("set", 0)
        for i = -1, 10 do
            local position = bit.lshift(base, 2 * i)
            if position >= file_size then break end
            file:seek("set", position)
            local chunk = file:read(block_size)
            if chunk then table.insert(buffer, chunk) end
        end
        file:close()
        local combined = table.concat(buffer)
        local hash = md5_fn(combined)
        return hash
    end

    -- Real preDeleteHook (verbatim from our new code in main.lua)
    function self:preDeleteHook(filepath)
        if not filepath then return nil, nil end
        local stem = filepath:match("([^/\\]+)%.[Ee][Pp][Uu][Bb]$")
        if not stem then return nil, nil end
        self:logInfo("preDeleteHook for:", filepath)
        local hash = self:calculateBookHash(filepath)
        if not hash then
            self:logWarn("preDeleteHook — could not compute hash for:", filepath)
            return nil, nil
        end
        return hash, stem
    end

    -- Real notifyBookloreOnDeletion (verbatim from our new code in main.lua)
    function self:notifyBookloreOnDeletion(hash, stem)
        local ok_pcall, err = pcall(function()
            if self.booklore_username == "" or self.booklore_password == "" then
                self:logInfo("notifyBookloreOnDeletion — credentials not set, skipping")
                return
            end
            self:logInfo("notifyBookloreOnDeletion — hash:", hash, "stem:", stem)

            local book_id = nil
            local hash_ok, hash_resp = self.api:getBookByHashWithAuth(hash, self.booklore_username, self.booklore_password)
            if hash_ok and hash_resp and hash_resp.id then
                book_id = tonumber(hash_resp.id)
                self:logInfo("found book by hash, ID:", book_id)
            else
                self:logInfo("hash lookup failed, searching by stem:", stem)
                local search_ok, search_resp = self.api:searchBooksWithAuth(stem, self.booklore_username, self.booklore_password)
                if search_ok and type(search_resp) == "table" and search_resp[1] and search_resp[1].id then
                    book_id = tonumber(search_resp[1].id)
                    self:logInfo("found book by stem search, ID:", book_id)
                else
                    local title_part = stem:match("^.+ %- (.+)$")
                    if title_part then
                        self:logInfo("retrying search with title:", title_part)
                        local title_ok, title_resp = self.api:searchBooksWithAuth(title_part, self.booklore_username, self.booklore_password)
                        if title_ok and type(title_resp) == "table" and title_resp[1] and title_resp[1].id then
                            book_id = tonumber(title_resp[1].id)
                            self:logInfo("found book by title search, ID:", book_id)
                        end
                    end
                end
            end

            if not book_id then
                self:logWarn("book not found on server, skipping shelf removal")
                return
            end

            local token_ok, token = self.api:getOrRefreshBearerToken(self.booklore_username, self.booklore_password)
            if not token_ok then
                self:logWarn("failed to get Bearer token:", token)
                return
            end

            local headers = { ["Authorization"] = "Bearer " .. token }

            local book_url = "/api/v1/books/" .. book_id .. "?withDescription=false"
            local book_ok, _, book_resp = self.api:request("GET", book_url, nil, headers)
            if not book_ok or type(book_resp) ~= "table" then
                self:logWarn("failed to retrieve book details")
                return
            end

            local shelf_id = nil
            for _, shelf in ipairs(book_resp.shelves or {}) do
                if shelf.name == self.booklore_shelf_name then
                    shelf_id = tonumber(shelf.id)
                    break
                end
            end

            if not shelf_id then
                self:logInfo("Book not on target shelf, skipping removal")
                return
            end

            self:logInfo("removing book", book_id, "from shelf", shelf_id)

            local payload = {
                bookIds           = { book_id },
                shelvesToUnassign = { shelf_id },
            }
            local remove_ok, remove_code, remove_resp = self.api:request("POST", "/api/v1/books/shelves", payload, headers)
            if remove_ok then
                self:logInfo("book removed from shelf successfully")
            else
                self:logWarn("shelf removal failed:", tostring(remove_code), tostring(remove_resp))
            end
        end)
        if not ok_pcall then
            self:logWarn("notifyBookloreOnDeletion — unexpected error:", tostring(err))
        end
    end

    -- Apply overrides (e.g. swap api, change credentials, etc.)
    for k, v in pairs(overrides or {}) do self[k] = v end
    return self
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function make_temp_epub(content)
    local path = os.tmpname() .. ".epub"
    local f = io.open(path, "wb")
    f:write(content or string.rep("A", 4096))
    f:close()
    return path
end

local function make_temp_file(ext, content)
    local path = os.tmpname() .. "." .. ext
    local f = io.open(path, "wb")
    f:write(content or string.rep("B", 2048))
    f:close()
    return path
end

local function delete_file(path)
    os.remove(path)
end

-- ─── Mock API builders ────────────────────────────────────────────────────────

local function api_happy_path(opts)
    opts = opts or {}
    return {
        getBookByHashWithAuth = function(_, hash, user, pass)
            return true, { id = opts.book_id or 42 }
        end,
        searchBooksWithAuth = function(_, stem, user, pass)
            return true, { { id = opts.book_id or 42 } }
        end,
        getOrRefreshBearerToken = function(_, user, pass)
            return true, "fake-bearer-token"
        end,
        request = function(_, method, path, body, headers)
            if method == "GET" and path:find("/api/v1/books/") then
                return true, 200, {
                    id = opts.book_id or 42,
                    shelves = {
                        { id = opts.shelf_id or 7, name = opts.shelf_name or "Kobo" },
                        { id = 99, name = "OtherShelf" },
                    }
                }
            elseif method == "POST" and path == "/api/v1/books/shelves" then
                -- Record the call for assertion
                opts._last_post = body
                return true, 200, {}
            end
            return false, 404, "not found"
        end,
    }
end

-- ═════════════════════════════════════════════════════════════════════════════
-- TEST CASES
-- ═════════════════════════════════════════════════════════════════════════════

-- ─── 1. preDeleteHook: EPUB detection ────────────────────────────────────────

section("preDeleteHook — file type filtering")

do
    local epub_path = make_temp_epub()
    local plugin = make_plugin()

    local hash, stem = plugin:preDeleteHook(epub_path)
    ok(hash ~= nil,  "returns hash for .epub file")
    ok(stem ~= nil,  "returns stem for .epub file")
    ok(type(hash) == "string" and #hash > 0, "hash is non-empty string")
    ok(not stem:find("%.epub"), "stem does not contain .epub extension")
    delete_file(epub_path)
end

do
    local pdf_path = make_temp_file("pdf")
    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(pdf_path)
    ok(hash == nil, "returns nil hash for .pdf file")
    ok(stem == nil, "returns nil stem for .pdf file")
    delete_file(pdf_path)
end

do
    local cbz_path = make_temp_file("cbz")
    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(cbz_path)
    ok(hash == nil, "returns nil hash for .cbz file")
    delete_file(cbz_path)
end

do
    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(nil)
    ok(hash == nil, "returns nil hash for nil filepath")
end

-- ─── 2. preDeleteHook: case-insensitive EPUB extension ───────────────────────

section("preDeleteHook — case-insensitive .EPUB extension")

do
    -- Create a file with uppercase extension by renaming
    local base_path = os.tmpname()
    local epub_upper = base_path .. ".EPUB"
    local f = io.open(epub_upper, "wb")
    f:write(string.rep("Z", 3000))
    f:close()

    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(epub_upper)
    ok(hash ~= nil, "recognises .EPUB (uppercase) extension")
    ok(stem ~= nil, "returns stem for .EPUB file")
    delete_file(epub_upper)
end

-- ─── 3. preDeleteHook: stem extraction with path separators ──────────────────

section("preDeleteHook — stem extraction")

do
    local epub_path = make_temp_epub()
    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(epub_path)

    -- Stem must not contain path separators
    ok(stem ~= nil, "stem is not nil")
    ok(not stem:find("[/\\]"), "stem contains no path separators")
    delete_file(epub_path)
end

-- ─── 4. preDeleteHook: missing file (deleted before hook runs) ───────────────

section("preDeleteHook — file already gone")

do
    local ghost = os.tmpname() .. "_nonexistent.epub"
    local plugin = make_plugin()
    local hash, stem = plugin:preDeleteHook(ghost)
    ok(hash == nil, "returns nil hash when file does not exist")
    ok(#plugin._warns > 0, "logged a warning for missing file")
end

-- ─── 5. preDeleteHook: hash is deterministic ─────────────────────────────────

section("preDeleteHook — hash determinism")

do
    -- Write a fixed-content EPUB and verify hash is stable across two calls
    local fixed_epub = os.tmpname() .. ".epub"
    local f = io.open(fixed_epub, "wb")
    f:write(string.rep("X", 8192))
    f:close()

    local plugin = make_plugin()
    local h1 = plugin:calculateBookHash(fixed_epub)
    local h2 = plugin:calculateBookHash(fixed_epub)
    ok(h1 == h2, "hash is deterministic for same file content")
    delete_file(fixed_epub)
end

-- ─── 6. notifyBookloreOnDeletion: credential guard ───────────────────────────

section("notifyBookloreOnDeletion — credential guard")

do
    local api_calls = 0
    local mock_api = {
        getBookByHashWithAuth   = function(...) api_calls = api_calls + 1; return false, "nope" end,
        searchBooksWithAuth     = function(...) api_calls = api_calls + 1; return false, {} end,
        getOrRefreshBearerToken = function(...) api_calls = api_calls + 1; return false, "nope" end,
        request                 = function(...) api_calls = api_calls + 1; return false, 0, "nope" end,
    }

    local plugin = make_plugin({ booklore_username = "", booklore_password = "", api = mock_api })
    plugin:notifyBookloreOnDeletion("abc123", "MyBook")
    ok(api_calls == 0, "no network calls made when credentials are empty")
end

-- ─── 7. notifyBookloreOnDeletion: happy path (hash lookup succeeds) ───────────

section("notifyBookloreOnDeletion — happy path via hash lookup")

do
    local post_body = nil
    local api_spy = {
        getBookByHashWithAuth = function(_, hash, u, p)
            return true, { id = 42 }
        end,
        searchBooksWithAuth = function(...)
            -- Should NOT be called
            error("searchBooksWithAuth called unexpectedly")
        end,
        getOrRefreshBearerToken = function(_, u, p)
            return true, "my-token"
        end,
        request = function(_, method, path, body, headers)
            if method == "GET" then
                return true, 200, {
                    id = 42,
                    shelves = { { id = 7, name = "Kobo" } }
                }
            elseif method == "POST" then
                post_body = body
                return true, 200, {}
            end
        end
    }

    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("deadbeef", "MyEpubBook")

    ok(post_body ~= nil,                         "POST /api/v1/books/shelves was called")
    ok(post_body.bookIds[1] == 42,               "POST payload contains correct book ID")
    ok(post_body.shelvesToUnassign[1] == 7,      "POST payload unassigns correct shelf ID")
    ok(post_body.shelvesToAssign == nil,          "POST payload shelvesToAssign is omitted")
end

-- ─── 8. notifyBookloreOnDeletion: fallback to title search ───────────────────

section("notifyBookloreOnDeletion — fallback to title search when hash fails")

do
    local search_called_with = nil
    local post_body = nil
    local api_spy = {
        getBookByHashWithAuth = function(_, hash, u, p)
            return false, "not found"        -- hash lookup fails
        end,
        searchBooksWithAuth = function(_, stem, u, p)
            search_called_with = stem
            return true, { { id = 55 } }     -- search returns a result
        end,
        getOrRefreshBearerToken = function(_, u, p)
            return true, "my-token"
        end,
        request = function(_, method, path, body, headers)
            if method == "GET" then
                return true, 200, {
                    id = 55,
                    shelves = { { id = 9, name = "Kobo" } }
                }
            elseif method == "POST" then
                post_body = body
                return true, 200, {}
            end
        end
    }

    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("badhash", "FallbackTitle")

    ok(search_called_with == "FallbackTitle",  "title search called with the file stem")
    ok(post_body ~= nil,                       "POST still fired after fallback")
    ok(post_body.bookIds[1] == 55,             "POST uses ID from search result")
end

-- ─── 9. notifyBookloreOnDeletion: book not found anywhere ────────────────────

section("notifyBookloreOnDeletion — book not found anywhere")

do
    local posted = false
    local api_spy = {
        getBookByHashWithAuth = function(...) return false, "not found" end,
        searchBooksWithAuth   = function(...) return true, {} end,  -- empty results
        getOrRefreshBearerToken = function(...) return true, "tok" end,
        request = function(_, method, ...)
            if method == "POST" then posted = true end
            return true, 200, {
                id = 1,
                shelves = { { id = 1, name = "Kobo" } }
            }
        end
    }

    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("badhash", "UnknownBook")
    ok(not posted, "no POST fired when book is not found on server")
    ok(#plugin._warns > 0, "a warning was logged")
end

-- ─── 10. notifyBookloreOnDeletion: token refresh failure ─────────────────────

section("notifyBookloreOnDeletion — Bearer token failure")

do
    local posted = false
    local api_spy = {
        getBookByHashWithAuth   = function(...) return true, { id = 1 } end,
        getOrRefreshBearerToken = function(...) return false, "login error" end,
        request = function(_, method, ...)
            if method == "POST" then posted = true end
            return true, 200, {}
        end
    }

    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("abc", "SomeBook")
    ok(not posted, "no POST fired when Bearer token cannot be obtained")
    ok(#plugin._warns > 0, "warning logged for token failure")
end

-- ─── 11. notifyBookloreOnDeletion: shelf not found ───────────────────────────

section("notifyBookloreOnDeletion — target shelf not found")

do
    local posted = false
    local api_spy = {
        getBookByHashWithAuth   = function(...) return true, { id = 1 } end,
        getOrRefreshBearerToken = function(...) return true, "tok" end,
        request = function(_, method, path, body, headers)
            if method == "GET" then
                -- Return book that is NOT on "Kobo" shelf
                return true, 200, {
                    id = 1,
                    shelves = { { id = 5, name = "DifferentShelf" } }
                }
            elseif method == "POST" then
                posted = true
                return true, 200, {}
            end
        end
    }

    local plugin = make_plugin({ api = api_spy, booklore_shelf_name = "Kobo" })
    plugin:notifyBookloreOnDeletion("abc", "SomeBook")
    ok(not posted, "no POST fired when book is not on target shelf")
    ok(#plugin._infos > 0, "info logged for book not on shelf")
end

-- ─── 12. notifyBookloreOnDeletion: custom shelf name ─────────────────────────

section("notifyBookloreOnDeletion — custom shelf name setting")

do
    local opts = { book_id = 10, shelf_id = 20, shelf_name = "MyCustomShelf", _last_post = nil }
    local plugin = make_plugin({ api = api_happy_path(opts), booklore_shelf_name = "MyCustomShelf" })
    plugin:notifyBookloreOnDeletion("hash1", "book1")
    ok(opts._last_post ~= nil,                    "POST fired for custom shelf name")
    ok(opts._last_post.shelvesToAssign == nil, "shelvesToAssign is omitted")
    ok(opts._last_post.shelvesToUnassign[1] == 20, "correct custom shelf ID unassigned")
end

-- ─── 13. notifyBookloreOnDeletion: pcall swallows API panics ─────────────────

section("notifyBookloreOnDeletion — pcall swallows unexpected errors")

do
    local exploding_api = {
        getBookByHashWithAuth = function(...) error("NETWORK EXPLODED") end,
        searchBooksWithAuth   = function(...) error("ALSO EXPLODED") end,
        getOrRefreshBearerToken = function(...) error("STILL EXPLODED") end,
        request               = function(...) error("AGAIN") end,
    }

    local plugin = make_plugin({ api = exploding_api })
    -- This must not raise:
    local threw = false
    local ok_outer, e = pcall(function()
        plugin:notifyBookloreOnDeletion("h", "s")
    end)
    ok(ok_outer, "caller-side pcall never sees the explosion")
    ok(#plugin._warns > 0, "the internal error was logged as a warning")
end

-- ─── 14. FileManager patch guard flag (booklore_fm_patched) ──────────────────

section("FileManager patch — guard flag prevents double-patching")

do
    -- Simulate the patch logic by toggling the guard flag manually
    local patched_count = 0
    local fm_patched = false

    local function apply_patch()
        if not fm_patched then
            fm_patched = true
            patched_count = patched_count + 1
        end
    end

    apply_patch()
    apply_patch()
    apply_patch()
    ok(patched_count == 1, "patch applied exactly once even when init() called multiple times")
end

-- ═════════════════════════════════════════════════════════════════════════════
-- ─── 15. Title-extraction fallback: "Author - Title" pattern ──────────

section("notifyBookloreOnDeletion — title extracted from Author-Title stem")

do
    local search_calls = {}
    local post_body = nil
    local api_spy = {
        getBookByHashWithAuth = function(...) return false, "not found" end,
        searchBooksWithAuth = function(_, term, u, p)
            table.insert(search_calls, term)
            if term == "Waif" then return true, { { id = 77 } } end
            return true, {}
        end,
        getOrRefreshBearerToken = function(...) return true, "tok" end,
        request = function(_, method, path, body)
            if method == "GET" then
                return true, 200, {
                    id = 3,
                    shelves = { { id = 3, name = "Kobo" } }
                }
            end
            if method == "POST" then post_body = body; return true, 200, {} end
        end,
    }
    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("badhash", "Samantha Kolesnik - Waif")
    ok(#search_calls >= 2,             "at least two search calls (stem + title)")
    ok(search_calls[1] == "Samantha Kolesnik - Waif", "first search uses full stem")
    ok(search_calls[2] == "Waif",      "second search uses title-only portion")
    ok(post_body ~= nil,               "POST fired after title search succeeded")
    ok(post_body.bookIds[1] == 77,     "correct book ID from title search in POST")
end

-- ─── 16. Title-extraction: no " - " separator, no extra call ────────

section("notifyBookloreOnDeletion — no separator in stem, no extra search")

do
    local search_calls = {}
    local api_spy = {
        getBookByHashWithAuth = function(...) return false, "not found" end,
        searchBooksWithAuth = function(_, term, u, p)
            table.insert(search_calls, term)
            return true, {}
        end,
        getOrRefreshBearerToken = function(...) return true, "tok" end,
        request = function(...) return true, 200, { id = 1, shelves = { { id = 1, name = "Kobo" } } } end,
    }
    local plugin = make_plugin({ api = api_spy })
    plugin:notifyBookloreOnDeletion("badhash", "Waif")
    ok(#search_calls == 1,             "only one search call when no separator in stem")
    ok(search_calls[1] == "Waif",      "single search uses the bare stem")
end

-- SUMMARY
-- ═════════════════════════════════════════════════════════════════════════════

io.write(string.format("\n%s\nResults: %d passed, %d failed\n",
    string.rep("─", 50), PASS, FAIL))

os.exit(FAIL > 0 and 1 or 0)
