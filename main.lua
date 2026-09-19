--[[
    ReadingOS — a reading-first dashboard for KOReader.

    One screen answers "what should I know, do or continue right now": the book
    on top, then only what falls inside the horizon (past due, today, tomorrow),
    then The Dig — an idle world that grows out of real life.

    Design rules this file has to keep. They are the whole point on e-ink, where
    there is no hover, no cursor and no colour:

      1. Long-press is never the only way to do anything. Everything essential
         is reachable by tap; long-press only duplicates something a tap reaches.
      2. Three shapes, three meanings, never mixed:
           [ BOX ]   does something now
           NAME   >  opens another screen
           sym row   tap completes this row
      3. Every tap gets a receipt before the network is touched, so a tap is
         never silent on a slow radio.
      4. Anything not tappable carries no marker and reacts to nothing.
      5. One rotating hint line, retired after the counter runs out.
      6. No invented gestures. Back is KOReader's own swipe-right.

    HTTP, cache and token-file handling follow tasksss.koplugin, which is proven
    on this device — same idioms on purpose.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local QRMessage = require("ui/widget/qrmessage")
local GestureRange = require("ui/gesturerange")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local DEFAULTS = {
    -- LAN address of apps-lxc, which is DHCP: check `hostname -I` there if the
    -- Kindle stops syncing. Overridable in the plugin menu ("Adres serwera").
    readingos_url = "http://192.168.100.142:8098",
    readingos_token = "",
    readingos_cache_max_age = 21600, -- 6 h; anything older renders as stale
    readingos_hints_left = 10,
    readingos_update_checked = 0,    -- unix time of the last update check
    readingos_ss_refresh_rtc = 900,  -- sleep-screen redraw on an RTC wake, 15 min
    readingos_ss_min_battery = 20,   -- below this the device just sleeps
    readingos_ss_lab = true,         -- planes + ISS band under the tasks
    readingos_ss_light_off = true,   -- keep the frontlight dark across a redraw
    readingos_lock_minutes = 30,     -- on-demand lock screen auto-unlocks after
    readingos_ss_landscape = true,   -- three categories side by side need the width
    readingos_device_id = "",        -- generated once on first "Telefon" open, never regenerated
}

local CACHE_FILE = DataStorage:getDataDir() .. "/cache/readingos.json"
local TELEMETRY_FILE = DataStorage:getDataDir() .. "/cache/readingos-telemetry.json"
local TOKEN_FILE = DataStorage:getDataDir() .. "/readingos-token.txt"
local TELEMETRY_MAX = 500

local HINTS = {
    "dotknij zadania, żeby wybrać co z nim zrobić",
    "dotknij nazwy sekcji, żeby zobaczyć całą listę",
    "przesuń w prawo, żeby wrócić",
    "czytanie odsuwa ciemność",
}

-- The Kindle's C locale has no Polish month names, so os.date("%b") would put
-- "Aug" on a screen that is otherwise entirely Polish.
local DAYS = { "nd", "pn", "wt", "śr", "cz", "pt", "sb" }
local MONTHS = { "sty", "lut", "mar", "kwi", "maj", "cze",
                 "lip", "sie", "wrz", "paź", "lis", "gru" }

local function plDate(t)
    local d = os.date("*t", t)
    return string.format("%s %d %s", DAYS[d.wday], d.day, MONTHS[d.month])
end

--- "1180.41" -> "1 180,41 zł" — space thousands separator, comma decimal,
--- the Polish convention every other Moneeey surface already uses.
local function formatPln(n)
    local neg = n < 0
    n = math.abs(n)
    local whole = math.floor(n)
    local cents = math.floor((n - whole) * 100 + 0.5)
    local grouped = tostring(whole):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", "")
    return (neg and "-" or "") .. grouped .. string.format(",%02d zł", cents)
end

local function isoDay(offset)
    return os.date("%Y-%m-%d", os.time() + (offset or 0) * 86400)
end

-- Notatki/Artykuły read local files directly — no server round trip, no new
-- token, no touching Minifolio or the Readeck sync themselves. These are the
-- same default directories both already use on this device (confirmed: no
-- config.lua override for Minifolio, so it still reads /mnt/us/notes).
local NOTES_DIR = "/mnt/us/notes"
local ARTICLES_DIR = "/mnt/us/ARTICLES"

--- Every `.md` file directly in NOTES_DIR, newest mtime first. No recursion,
--- no index, no metadata beyond what the filesystem already gives for free —
--- exactly what a "notes" concept means when the source is plain Markdown.
local function notesList()
    local items = {}
    if lfs.attributes(NOTES_DIR, "mode") ~= "directory" then return items end
    for entry in lfs.dir(NOTES_DIR) do
        if entry:match("%.md$") then
            local mtime = lfs.attributes(NOTES_DIR .. "/" .. entry, "modification") or 0
            items[#items + 1] = { name = (entry:gsub("%.md$", "")), mtime = mtime }
        end
    end
    table.sort(items, function(a, b) return a.mtime > b.mtime end)
    return items
end

--- Read status from KOReader's own per-book sidecar, never a second source.
--- `summary.status == "complete"` is the one value this device has actually
--- shown (confirmed on a real .sdr this session) — trust only that. No
--- sidecar at all means the book was never opened, which is equally certain.
--- Anything else (a "reading" value was never actually observed, only
--- assumed possible) gets a deliberately generic label rather than a guess.
local function articleStatus(epub_path)
    local sdr = epub_path:gsub("%.epub$", "") .. ".sdr/metadata.epub.lua"
    local ok, chunk = pcall(dofile, sdr)
    if not ok or type(chunk) ~= "table" or type(chunk.summary) ~= "table" then
        return "nieprzeczytany"
    end
    if chunk.summary.status == "complete" then return "przeczytany" end
    return "otwarty" -- touched, but the exact progress isn't something this file confirms
end

--- Title = the text before the first " - <feed>" — Readeck's export names
--- every file "<title> - <feed name> [rd-id_...].epub"; this stops before
--- both the feed name and the bookmark id without needing to parse the id
--- out separately. Falls back to the bare filename if a title has no dash.
local function articlesList()
    local items = {}
    if lfs.attributes(ARTICLES_DIR, "mode") ~= "directory" then return items end
    for entry in lfs.dir(ARTICLES_DIR) do
        if entry:match("%.epub$") then
            local path = ARTICLES_DIR .. "/" .. entry
            local mtime = lfs.attributes(path, "modification") or 0
            local title = entry:match("^(.-) %- ") or (entry:gsub("%.epub$", ""))
            items[#items + 1] = { title = title, mtime = mtime, status = articleStatus(path) }
        end
    end
    table.sort(items, function(a, b) return a.mtime > b.mtime end)
    return items
end

--- Unread first (mirrors the same "mine first" preview rule the dashboard's
--- own task list already uses), newest within each group, capped at 3 —
--- this is the whole screen, not a paginated browser.
local function articlesPreview(items)
    local unread, read = {}, {}
    for _i, it in ipairs(items) do
        if it.status == "przeczytany" then
            read[#read + 1] = it
        else
            unread[#unread + 1] = it
        end
    end
    local preview = {}
    for i = 1, math.min(3, #unread) do preview[#preview + 1] = unread[i] end
    for i = 1, #read do
        if #preview >= 3 then break end
        preview[#preview + 1] = read[i]
    end
    return preview
end

--- plDate() only ever formats "now" (see its callers above) — Task Detail
--- needs to format an arbitrary server-supplied "YYYY-MM-DD" the same way,
--- so this reuses it via a timestamp instead of duplicating DAYS/MONTHS.
local function isoToPl(iso)
    local y, m, d = tostring(iso):match("^(%d+)-(%d+)-(%d+)")
    if not y then return tostring(iso or "") end
    return plDate(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
end

local ReadingOS = WidgetContainer:extend {
    name = "readingos",
    session_start = nil,
    -- sleep screen: RTC bookkeeping and the frontlight level to put back
    wakeup_mgr = nil,
    rtc_scheduled = false,
    rtcRefreshCallback = nil,
    simulated_wakeup = false,
    saved_frontlight = nil,
}

-- ---------------------------------------------------------------- settings

local function get(key)
    local v = G_reader_settings:readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

local function set(key, value)
    G_reader_settings:saveSetting(key, value)
    G_reader_settings:flush()
end

-- Typing a 48-character token on a Kindle keyboard is miserable, so a token
-- dropped in <koreader>/readingos-token.txt over USB wins when the setting is
-- empty. Same trick as tasksss.koplugin.
local function getToken()
    local token = tostring(get("readingos_token") or "")
    if token ~= "" then return token end
    local f = io.open(TOKEN_FILE, "r")
    if not f then return "" end
    local content = f:read("*line") or ""
    f:close()
    return (content:gsub("%s+", ""))
end

local function baseUrl()
    return (tostring(get("readingos_url")):gsub("/+$", ""))
end

-- ---------------------------------------------------------- phone companion
--
-- V1 (pairing only) — see TODO.md "ReadingOS Phone Companion / Remote".
-- Not a secret: it only ever identifies which Kindle a heartbeat/pairing
-- request came from, so math.random is fine — no crypto module needed on
-- device for this. Persisted, never regenerated, so it survives restarts.
local function deviceId()
    local id = tostring(get("readingos_device_id") or "")
    if id ~= "" then return id end
    math.randomseed(os.time() + (os.clock() * 1000000))
    id = string.format("kindle-%08x%08x", math.random(0, 0xffffffff), math.random(0, 0xffffffff))
    set("readingos_device_id", id)
    return id
end

-- ------------------------------------------------------------------- http

local function request(method, url, body)
    local ltn12 = require("ltn12")
    local sink = {}
    local headers = { ["Authorization"] = "Bearer " .. getToken() }
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local req = {
        url = url,
        method = method,
        sink = ltn12.sink.table(sink),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
    }

    -- A stalled socket freezes the UI mid-tap, which on e-ink reads as a dead
    -- device. Cap it hard: an honest failure beats a late answer.
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil then socketutil:set_timeout(5, 15) end

    local code
    local ok_ssl, https = pcall(require, "ssl.https")
    if ok_ssl and https and https.request and url:match("^https") then
        local _r, c = https.request(req)
        code = c
    else
        local ok_sock, http = pcall(require, "socket.http")
        if not ok_sock or not http then
            if ok_su and socketutil then socketutil:reset_timeout() end
            return nil, "no http client"
        end
        local _r, c = http.request(req)
        code = c
    end
    if ok_su and socketutil then socketutil:reset_timeout() end

    if type(code) ~= "number" then return nil, tostring(code), nil end
    if code ~= 200 then return nil, "HTTP " .. code, code end
    return table.concat(sink), nil, code
end

--- Maps a GET Task Detail failure to what the screen should say: a real 404
--- means the task is gone, everything else (5xx, an unrecognised code, or no
--- code at all because the socket never got a response) is transient upstream
--- trouble — the two must never share a screen. Pure so it can be checked
--- without booting the KOReader environment.
local function reasonForCode(code)
    if code == 404 then return "not_found" end
    return "unavailable"
end

local function decode(body)
    if not body then return nil end
    local json = require("json")
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

local function encode(tbl)
    local json = require("json")
    local ok, out = pcall(json.encode, tbl)
    return ok and out or nil
end

-- ------------------------------------------------------------------ cache

local function saveCache(data)
    util.makePath(DataStorage:getDataDir() .. "/cache/")
    local encoded = encode({ timestamp = os.time(), data = data })
    if not encoded then return end
    local f = io.open(CACHE_FILE, "w")
    if not f then return end
    f:write(encoded)
    f:close()
end

--- @return table|nil data, number|nil age_seconds
local function loadCache()
    local f = io.open(CACHE_FILE, "r")
    if not f then return nil, nil end
    local content = f:read("*all")
    f:close()
    local cached = decode(content)
    if not cached or not cached.data then return nil, nil end
    return cached.data, os.time() - (cached.timestamp or 0)
end

-- -------------------------------------------------------------- telemetry
--
-- Every screen opened and every row tapped is queued here and shipped with the
-- next fetch, so the radio wakes once rather than once per tap. This is what
-- the readingos skill reads later to say which sections earn their place and
-- which are dead weight.

-- ------------------------------------------------- craft cache + tick journal
--
-- Two small stores, both in the cache dir next to the dashboard's own, so a
-- crochet session survives what a PW3 actually does: the radio drops on
-- suspend, and Wi-Fi is off most of the time while you work.
--
--   * the pattern, one file per send id — reopening offline shows the rows
--     instead of "nie udało się pobrać wzoru";
--   * the ticks that could not reach the server, replayed on the next call.
--
-- The tick API is idempotent by construction (the server sets is_done to the
-- value sent, never toggles — see the craft_row branch of /act), so replaying
-- a tick can never double-apply it. That is why the journal stores the
-- server's own row id and the wanted state and nothing else: no new
-- identifier, no client-side clock, nothing to reconcile.
local CRAFT_JOURNAL_FILE = DataStorage:getDataDir() .. "/cache/readingos-craft-ticks.json"
local CRAFT_JOURNAL_MAX = 400 -- a session is tens of rows; this is the runaway guard

local function craftCacheFile(send_id)
    return DataStorage:getDataDir() .. "/cache/readingos-craft-" .. tostring(send_id) .. ".json"
end

--- A payload is only worth caching (or trusting on the way back) if it is the
--- shape CraftView draws from. A half-written file must never replace a good
--- pattern on screen.
local function craftPayloadOk(p)
    return type(p) == "table" and type(p.rows) == "table" and #p.rows > 0
end

local function craftCacheSave(send_id, payload)
    if not craftPayloadOk(payload) then return end
    util.makePath(DataStorage:getDataDir() .. "/cache/")
    local encoded = encode({ timestamp = os.time(), data = payload })
    if not encoded then return end
    -- Write beside it and rename: a power cut mid-write leaves the previous
    -- good pattern in place rather than a truncated one.
    local tmp = craftCacheFile(send_id) .. ".new"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(encoded)
    f:close()
    os.remove(craftCacheFile(send_id))
    os.rename(tmp, craftCacheFile(send_id))
end

--- @return table|nil payload, number|nil age_seconds
local function craftCacheLoad(send_id)
    local f = io.open(craftCacheFile(send_id), "r")
    if not f then return nil, nil end
    local content = f:read("*all")
    f:close()
    local cached = decode(content)
    if type(cached) ~= "table" or not craftPayloadOk(cached.data) then return nil, nil end
    return cached.data, os.time() - (cached.timestamp or 0)
end

local function craftJournal()
    local f = io.open(CRAFT_JOURNAL_FILE, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    local j = decode(content)
    if type(j) == "table" and type(j.ticks) == "table" then return j.ticks end
    return {}
end

local function craftJournalSave(ticks)
    util.makePath(DataStorage:getDataDir() .. "/cache/")
    local f = io.open(CRAFT_JOURNAL_FILE, "w")
    if not f then return end
    f:write(encode({ ticks = ticks }) or '{"ticks":[]}')
    f:close()
end

--- Record a tick the server did not take. One entry per row: ticking and
--- un-ticking the same row offline leaves the last intention, which is also
--- what the row shows on screen.
local function craftJournalAdd(row_id, done)
    if not row_id then return end
    local ticks = craftJournal()
    for _i, t in ipairs(ticks) do
        if t.id == row_id then t.done = done and true or false; craftJournalSave(ticks); return end
    end
    if #ticks >= CRAFT_JOURNAL_MAX then table.remove(ticks, 1) end
    ticks[#ticks + 1] = { id = row_id, done = done and true or false }
    craftJournalSave(ticks)
end

local function telemetryQueue()
    local f = io.open(TELEMETRY_FILE, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    local q = decode(content)
    if type(q) == "table" and type(q.events) == "table" then return q.events end
    return {}
end

local function telemetrySave(events)
    util.makePath(DataStorage:getDataDir() .. "/cache/")
    local f = io.open(TELEMETRY_FILE, "w")
    if not f then return end
    f:write(encode({ events = events }) or '{"events":[]}')
    f:close()
end

local function track(screen, action, detail, dwell_ms)
    local q = telemetryQueue()
    -- Bounded: a device offline for a month must not grow an unbounded file.
    while #q >= TELEMETRY_MAX do table.remove(q, 1) end
    q[#q + 1] = {
        at = os.time(), screen = screen, action = action,
        detail = detail, dwell_ms = dwell_ms,
    }
    telemetrySave(q)
end

local function flushTelemetry()
    local q = telemetryQueue()
    if #q == 0 then return end
    local body = encode({ events = q })
    if not body then telemetrySave({}) return end
    -- Kept on failure, never dropped: a lost week of usage is a lost week of
    -- evidence for tuning the game.
    if request("POST", baseUrl() .. "/api/readingos/telemetry", body) then
        telemetrySave({})
    end
end

-- ------------------------------------------------------------------- data

--- @return table|nil data, number|nil age_seconds, string|nil err
function ReadingOS:fetch()
    local body, err = request("GET", baseUrl() .. "/api/readingos/dashboard")
    if body then
        local data = decode(body)
        if data then
            saveCache(data)
            flushTelemetry()
            return data, nil, nil
        end
        err = "bad JSON"
    end
    logger.warn("ReadingOS: fetch failed:", err)
    local cached, age = loadCache()
    if cached and age and age <= (tonumber(get("readingos_cache_max_age")) or 0) then
        return cached, age, err
    end
    return nil, nil, err
end

--- The server's change cursor (tasksss2's, proxied by hooome). A string
--- that moves whenever a task/note/list changed anywhere — phone, browser,
--- Telegram. nil when unreachable; callers treat that as "unknown", never
--- as "changed".
--- Replay ticks the network ate. Each is removed only once the server has
--- taken it; the first failure stops the run and the rest stay for next time,
--- so nothing is dropped on a flaky connection. Safe to call at any moment:
--- replaying a tick the server already has is a no-op there.
--- @return number flushed, number remaining
function ReadingOS:flushCraftTicks()
    local ticks = craftJournal()
    if #ticks == 0 then return 0, 0 end
    local flushed = 0
    while ticks[1] do
        local t = ticks[1]
        local res = self:act("craft_row", t.id, { done = t.done })
        if not (res and res.ok ~= false) then break end
        table.remove(ticks, 1)
        flushed = flushed + 1
    end
    craftJournalSave(ticks)
    if flushed > 0 then track("craft", "ticks_flushed", tostring(flushed)) end
    return flushed, #ticks
end

function ReadingOS:fetchRev()
    local body = request("GET", baseUrl() .. "/api/readingos/rev")
    local data = body and decode(body)
    local rev = type(data) == "table" and data.rev
    if type(rev) == "string" and rev ~= "" then return rev end
    return nil
end

--- @return table|nil result, string|nil err — the reason matters: "has open
--- steps" and "offline" need different words on screen, and collapsing both to
--- nil is how the device ended up blaming the radio for a refused write.
function ReadingOS:act(kind, id, extra)
    local payload = { kind = kind, id = id }
    for k, v in pairs(extra or {}) do payload[k] = v end
    local body = encode(payload)
    if not body then return nil, "encode failed" end
    local res, err = request("POST", baseUrl() .. "/api/readingos/act", body)
    if not res then return nil, err end
    return decode(res), nil
end

--- Task Detail's data: everything the dashboard row deliberately drops
--- (description, subtask labels, project, the raw priority/fixed bits) for
--- radio cost. nil on any failure — the screen still opens and works off the
--- row it already has, just without opis/subtaski/GDZIE.
function ReadingOS:fetchTaskDetail(id)
    local body, err, code = request("GET", baseUrl() .. "/api/readingos/task/" .. tostring(id))
    if not body then
        logger.warn("ReadingOS: task detail fetch failed:", err)
        return nil, reasonForCode(code)
    end
    return decode(body), nil
end

-- ------------------------------------------------------------------- view

-- One knob for the whole dashboard. Every size below is relative to it, so
-- retuning the density is a one-line change rather than four numbers that
-- drift apart.
-- 0.5 put four size tokens inside two rendered pixels of each other: labels and
-- meta both landed at 6 px, which is where COLOR_GRAY_5 stops being gray and
-- starts being a smudge on this panel. 0.72 keeps the same density (tappable
-- rows are floored by MIN_TAP, not by the font) and gives the hierarchy back.
local FONT_SCALE = 0.72

local SIZE_TITLE = 21
local SIZE_HEAD = 15  -- section headers: caps + a rule, one step under a row
local SIZE_ROW = 16
local SIZE_META = 13
local SIZE_LABEL = 12

-- Smallest a tappable row may become, whatever FONT_SCALE says. Roughly a
-- fingertip; below this the wrong task gets completed.
local MIN_TAP = Screen:scaleBySize(34)

local function face(size)
    -- max(1, floor(...)) rather than the raw product: scaleBySize on a zero or
    -- fractional size yields an unusable face, and a dashboard of invisible
    -- text looks exactly like the plugin failing to load.
    return Font:getFace("cfont", Screen:scaleBySize(math.max(1, math.floor(size * FONT_SCALE))))
end

--- The dashboard's type scale. face() above pre-scales with Screen:scaleBySize
--- and Font:getFace then scales by DPI again (font.lua: `size =
--- Screen:scaleBySize(size)`), so on the PW3 a SIZE_ROW face is a 36 px font
--- with a 58 px line — twice what the reference mock is drawn at, and the
--- reason a three-line day ran past the bottom of the screen. This passes
--- the token straight through: 16 → 29 px, the same "24 = 43 px" convention
--- KOReader's own UI uses. Dashboard only — TaskDetail/LearnView/CraftView
--- keep face(), they were tuned by eye at that size and are not part of the
--- redesign.
local function dashFace(size)
    return Font:getFace("cfont", math.max(1, math.floor(size)))
end

--- Ignores FONT_SCALE. For the pattern screen, which is read at arm's length
--- with both hands busy — the one place where small text defeats the purpose.
local function faceFull(size)
    return Font:getFace("cfont", Screen:scaleBySize(size))
end

local function rule(width, dashed)
    return LineWidget:new {
        dimen = Geom:new { w = width, h = Screen:scaleBySize(dashed and 1 or 2) },
        background = dashed and Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_BLACK,
    }
end

--- A left/right line: the workhorse of every section.
---
--- The right-hand text is measured first and the left is then given only the
--- room actually left over. A flat percentage does not work — "expires 08-05"
--- and "rations · restock" are wildly different widths, and on the first device
--- run the long ones ran straight underneath the left-hand text.
local function lrRow(width, height, left, right, left_face, right_face, right_gray)
    local group = OverlapGroup:new { dimen = { w = width, h = height } }
    local gap = Screen:scaleBySize(10)

    if right and right ~= "" then
        local right_widget = TextWidget:new {
            text = right,
            face = right_face or left_face,
            fgcolor = right_gray and Blitbuffer.COLOR_GRAY_5 or nil,
            max_width = math.floor(width * 0.55), -- truncate rather than collide
        }
        local rw = right_widget:getSize().w
        local left_room = math.max(Screen:scaleBySize(40), width - rw - gap)
        table.insert(group, LeftContainer:new {
            dimen = { w = width, h = height },
            TextWidget:new { text = left, face = left_face, max_width = left_room },
        })
        table.insert(group, RightContainer:new {
            dimen = { w = width, h = height },
            right_widget,
        })
    else
        table.insert(group, LeftContainer:new {
            dimen = { w = width, h = height },
            TextWidget:new { text = left, face = left_face, max_width = width },
        })
    end
    return group
end

--- What a row says, in the order the list is sorted in: kind, priority, clock,
--- title. Reading the row therefore explains why it sits where it does — and a
--- glance down the left edge finds the urgent ones without reading any titles.
local function rowText(it)
    local parts = { it.sym or "·" }
    if it.pmark and it.pmark ~= "" then parts[#parts + 1] = it.pmark end
    if it.time and it.time ~= "" then parts[#parts + 1] = it.time end
    parts[#parts + 1] = it.text or "?"
    return table.concat(parts, "  ")
end

-- ------------------------------------------------------------------ icons
--
-- No icon font, no emoji: the dashboard's icons are KOReader's own SVG set
-- (resources/icons/mdlight — the files every KOReader menu bar on this device
-- already renders through NanoSVG), so nothing here depends on a glyph the UI
-- font may lack. The five shapes that set has no equivalent for (cart, yarn,
-- wallet, task list, more) are tiny inline SVGs written once to the plugin
-- cache and rendered through the very same NanoSVG file path. Inline rather
-- than shipped as files because OTA delivers main.lua alone (PLUGIN_FILES on
-- the server) — a separate icon file would never reach the device.
--
-- Everything degrades to an empty box of the same size: a missing renderer
-- must never shift the layout, and never crash the dashboard.
local ok_iconw, IconWidget = pcall(require, "ui/widget/iconwidget")
if not ok_iconw then IconWidget = nil end
local ok_imagew, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_imagew then ImageWidget = nil end

local ICON_SVG = {
    cart = [[<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><g fill="none" stroke="#000000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h6l5 22h21l4-14H12"/><circle cx="18" cy="38" r="3"/><circle cx="33" cy="38" r="3"/></g></svg>]],
    yarn = [[<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><g fill="none" stroke="#000000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><circle cx="22" cy="26" r="17"/><path d="M6 22q16-2 32 8"/><path d="M8 34q14 0 28-12"/><path d="M16 11q4 16 14 31"/><path d="M32 6l12 12"/></g></svg>]],
    wallet = [[<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><g fill="none" stroke="#000000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="12" width="38" height="26" rx="3"/><path d="M5 19h38"/><rect x="29" y="24" width="14" height="8" rx="2"/></g><circle cx="35" cy="28" r="1.8" fill="#000000"/></svg>]],
    tasks = [[<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><g fill="none" stroke="#000000" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12h25M19 24h25M19 36h25"/><path d="M5 12l3 3 6-6M5 24l3 3 6-6M5 36l3 3 6-6"/></g></svg>]],
    more = [[<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><g fill="#000000"><circle cx="11" cy="24" r="4"/><circle cx="24" cy="24" r="4"/><circle cx="37" cy="24" r="4"/></g></svg>]],
}
local ICON_DIR = DataStorage:getDataDir() .. "/cache/readingos-icons"

--- Path of the cached SVG for an inline icon, written on first use (or when
--- the shape changed size, i.e. after an update). nil when the cache dir is
--- not writable — the caller then draws the empty box instead.
local function iconFile(name, svg)
    local path = ICON_DIR .. "/" .. name .. ".svg"
    local ok, size = pcall(function() return lfs.attributes(path, "size") end)
    if ok and size == #svg then return path end
    pcall(function() lfs.mkdir(ICON_DIR) end)
    local fh = io.open(path, "w")
    if not fh then return nil end
    fh:write(svg)
    fh:close()
    return path
end

--- A square icon `size` px wide: a KOReader icon by name, or one of ICON_SVG.
local function icon(name, size)
    local ok, w = pcall(function()
        local svg = ICON_SVG[name]
        if svg then
            local file = iconFile(name, svg)
            if not (file and IconWidget) then return nil end
            return IconWidget:new { file = file, width = size, height = size }
        end
        if not IconWidget then return nil end
        return IconWidget:new { icon = name, width = size, height = size }
    end)
    if ok and w then return w end
    return CenterContainer:new { dimen = Geom:new { w = size, h = size }, HorizontalSpan:new { width = size } }
end

--- The battery glance: a body filled to the charge level plus the nub. Drawn
--- from ProgressWidget + LineWidget rather than a glyph — nothing to verify
--- on the panel, and it reads at a glance the way the phone's does.
local function batteryIcon(fraction, h)
    local body_w = math.floor(h * 2)
    return HorizontalGroup:new {
        ProgressWidget:new {
            width = body_w, height = h, percentage = fraction,
            margin_h = 0, margin_v = 0, radius = Screen:scaleBySize(1),
            bordersize = Screen:scaleBySize(1), fillcolor = Blitbuffer.COLOR_BLACK,
        },
        LineWidget:new {
            dimen = Geom:new { w = Screen:scaleBySize(2), h = math.floor(h / 2) },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
end

--[[ The dashboard.

     Rows register their screen-space y range as they are laid out, so a tap is
     resolved by position. Giving every row its own InputContainer would mean
     hundreds of gesture ranges on a 1 GHz CPU — exactly the thing that makes a
     Kindle feel broken. ]]
local Dashboard = InputContainer:extend {
    data = nil,
    age = nil,
    plugin = nil,
    hit = nil,       -- ordered { y1, y2, kind, id, screen, label }
    opened_at = nil,
}

function Dashboard:init()
    self.hit = {}
    self.opened_at = os.time()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.readingos_screen = "dashboard" -- Phone Companion V2: identifies this widget to executeRemoteCommand

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            Hold = { GestureRange:new { ges = "hold", range = self.dimen } },
            SwipeBack = { GestureRange:new { ges = "swipe", range = self.dimen } },
        }
    end
    -- Kindles with a physical Back key should honour it too; on a PW3 this is
    -- inert, and costs nothing.
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
    self:scheduleRevPoll()
end

-- Live refresh: while the dashboard is on screen, ask the server once a
-- minute whether anything changed (a ~40-byte cursor, not the dashboard)
-- and rebuild only when it did — so a task ticked off on the phone or via
-- Telegram shows up here within a minute, with no e-ink redraw otherwise.
-- Skipped when the radio is down (request() blocks for its socket timeout
-- and would freeze the UI), and when another ReadingOS screen sits on top
-- (a rebuild under it would swap the hit map out from under the user).
-- The first cursor the poll sees becomes the baseline, so the first poll
-- can never fire a rebuild on unchanged data.
-- Asleep, the poll stays quiet. UIManager schedules on CLOCK_MONOTONIC,
-- which does not tick in suspend, so every wake finds this task overdue and
-- runs it immediately — including the 15-minute RTC bounce that redraws the
-- sleep screen (rtcRefreshCallback → toggleSuspend → onResume, which clears
-- `simulated_wakeup` and goes straight back down). Fetching there would cost
-- a radio round trip and a full e-ink redraw on a device about to sleep
-- again, every quarter of an hour, for as long as the dashboard was left
-- open. `Device.screen_saver_mode` (set by patchScreensaver) and the
-- plugin's own `simulated_wakeup` are the two states that say so; a skipped
-- tick consumes nothing and re-arms as usual, so the change is picked up on
-- the first genuinely awake poll.
local REV_POLL_SECONDS = 60

function Dashboard:scheduleRevPoll()
    if self.rev_poll then return end
    self.rev_poll = function()
        self.rev_poll_pending = false
        if self.closed then return end
        local asleep = Device.screen_saver_mode or self.plugin.simulated_wakeup
        local ok, connected = pcall(function() return NetworkMgr:isConnected() end)
        if not asleep and ok and connected and UIManager:getTopmostVisibleWidget() == self then
            local ok_rev, rev = pcall(function() return self.plugin:fetchRev() end)
            rev = ok_rev and rev or nil
            if rev and self.rev == nil then
                self.rev = rev
            elseif rev and rev ~= self.rev then
                self.rev = rev
                track("home", "live_refresh")
                self.plugin:refreshInto(self)
            end
        end
        if not self.closed then
            self.rev_poll_pending = true
            UIManager:scheduleIn(REV_POLL_SECONDS, self.rev_poll)
        end
    end
    -- No baseline request at open: the first poll a minute later takes the
    -- first cursor it sees as the baseline (see the nil-check above), so a
    -- change lands one poll later than it could and opening the dashboard
    -- stays a single round trip.
    self.rev = nil
    self.rev_poll_pending = true
    UIManager:scheduleIn(REV_POLL_SECONDS, self.rev_poll)
end

function Dashboard:cancelRevPoll()
    self.closed = true
    if self.rev_poll and self.rev_poll_pending then
        UIManager:unschedule(self.rev_poll)
        self.rev_poll_pending = false
    end
end

--- Register a tap target covering the next `height` pixels.
function Dashboard:claim(y, height, target)
    target.y1 = y
    target.y2 = y + height
    self.hit[#self.hit + 1] = target
    return y + height
end

--- HEADER (one bordered strip: clock | date | weather | Wi-Fi icon + SSID +
--- dot | version | battery — vertical rules between, the SSID the only part
--- that may truncate), then ZADANIA as one bordered card (attention row,
--- summary, three rows, chevron), then DOM / CO CZYTAM / ZAKUPY / CRAFTSSS
--- as full-width bordered cards with an icon column (the current book's real
--- cover for CO CZYTAM), then a six-item icon BOTTOM NAV pinned to the
--- bottom, ZAMKNIJ first (2026-09-18 redesign, reference mock). NAUKA/DIG/
--- Help/Notatki/Artykuły live in WIĘCEJ — the screens themselves (openScreen
--- "learn"/"dig"/"help") are untouched, only their entry point relocated.
--- Rachunki/Notatki/Artykuły have no data source yet (Phase 1), so their
--- bottom-nav/menu entries are a plain "soon" message — never a fake preview.
---
--- The screen never scrolls, so the cards are laid out against a measured
--- budget (everything above them + the pinned nav) and, when a busy day does
--- not fit, re-laid with fewer preview lines — content cards first, task
--- rows last. One line of everything always fits, so the nav always does.
function Dashboard:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(18)
    local cw = W - 2 * pad
    local d = self.data or {}
    local rows = {}
    local y = pad -- running screen-space offset used for hit registration

    -- Text scales; fingers do not. Rows that can be tapped keep a floor of
    -- MIN_TAP so shrinking the font makes the dashboard denser rather than
    -- unusable — at 50 % an unclamped row would be a ~16 px target.
    local h_label = Screen:scaleBySize(SIZE_LABEL * 2 * FONT_SCALE)
    local h_row = math.max(MIN_TAP, Screen:scaleBySize(SIZE_ROW * 2 * FONT_SCALE))
    local h_meta = Screen:scaleBySize(SIZE_META * 1.7 * FONT_SCALE)

    local bord = Screen:scaleBySize(1)
    local card_pad = Screen:scaleBySize(9)
    local iw = cw - 2 * (bord + card_pad) -- width inside any card
    local gray = Blitbuffer.COLOR_GRAY_5

    local function size(widget, fallback)
        local ok, s = pcall(function() return widget:getSize() end)
        return (ok and s and s.h and s.h > 0) and s or { w = fallback or 0, h = fallback or 0 }
    end

    -- The height passed in is what the row was *asked* for; what a widget then
    -- renders can differ (a FrameContainer adds its own border and padding, a
    -- TextWidget rounds to its font metrics). Registering the asked-for height
    -- made every row below a mismatch drift a few pixels further down the
    -- screen, and the drift accumulates — which is why the bottom rows used
    -- to swallow each other's taps. Measure the widget instead and the whole
    -- column stays honest, top to bottom.
    local function add(widget, height, target)
        rows[#rows + 1] = widget
        local real = size(widget, height).h
        if target then y = self:claim(y, real, target) else y = y + real end
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        rows[#rows + 1] = VerticalSpan:new { width = h }
        y = y + h
    end
    local function vline(h)
        return LineWidget:new { dimen = Geom:new { w = bord, h = h }, background = Blitbuffer.COLOR_BLACK }
    end
    local function hline(w)
        return LineWidget:new { dimen = Geom:new { w = w, h = bord }, background = Blitbuffer.COLOR_BLACK }
    end
    local function text(s, f, opts)
        opts = opts or {}
        return TextWidget:new { text = s, face = f, bold = opts.bold, max_width = opts.max_width,
            fgcolor = opts.gray and gray or nil }
    end
    --- One row of a card: left text, optional right widget, fixed height.
    local function cardRow(h, left, right)
        local group = OverlapGroup:new { dimen = Geom:new { w = iw, h = h } }
        table.insert(group, LeftContainer:new { dimen = Geom:new { w = iw, h = h }, left })
        if right then
            table.insert(group, RightContainer:new { dimen = Geom:new { w = iw, h = h }, right })
        end
        return group
    end

    --- A bordered card built from rows, each row optionally its own tap
    --- target. Hit regions come from each row's measured height at its real
    --- offset inside the frame (border + padding) — the same measure-don't-
    --- guess rule add() follows for the column as a whole. Rows register
    --- before the card-wide target, so a row wins over the card's padding.
    local function addCard(items, whole_target)
        local group = VerticalGroup:new { align = "left" }
        for _i, it in ipairs(items) do table.insert(group, it.widget) end
        local frame = FrameContainer:new { bordersize = bord, padding = card_pad, width = cw, radius = 0, group }
        rows[#rows + 1] = frame
        local real = size(frame).h
        local top = y
        local ry = top + bord + card_pad
        for _i, it in ipairs(items) do
            local h = size(it.widget).h
            if it.target then self:claim(ry, h, it.target) end
            ry = ry + h
        end
        if whole_target then self:claim(top, real, whole_target) end
        y = top + real
    end

    -- ---- header. Rule 4 (inert glance, no marker, no reaction): device data
    -- (Wi-Fi, version, battery) comes from KOReader's own APIs, never a
    -- network round trip — pcall'd because a hardware quirk must degrade to
    -- "—", not crash the whole dashboard. ZAMKNIJ is no longer up here: the
    -- close action is the first, largest bottom-nav target instead.
    local weather = d.weather
    local weather_text = ""
    if type(weather) == "table" and weather.temp then
        weather_text = string.format("%d°C", weather.temp)
        if weather.stale then weather_text = weather_text .. " ·" end
    end

    -- Wi-Fi: KOReader's own wifi icon, the SSID when connected (the word
    -- "Wi-Fi" otherwise — off and disconnected read the same at a glance
    -- here, on purpose; either way is "not connected") and a filled/empty
    -- dot (●/○, already proven on this panel). Every call here is local
    -- (sysfs read / getifaddrs / lipc to wifid), never a network round trip.
    -- Deliberately NOT using NetworkMgr:isOnline(), which resolves an
    -- external hostname with no Lua-side timeout: exactly the kind of thing
    -- that could hang the whole dashboard on a bad network.
    local ok_wifi_on, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    local wifi_name, wifi_dot = "Wi-Fi", "○"
    if not ok_wifi_on then
        wifi_name, wifi_dot = "—", ""
    elseif wifi_on then
        local ok_conn, connected = pcall(function() return NetworkMgr:isConnected() end)
        if not ok_conn then
            wifi_name, wifi_dot = "—", ""
        elseif connected then
            local ok_net, net = pcall(function() return NetworkMgr:getCurrentNetwork() end)
            local ssid = (ok_net and type(net) == "table" and net.ssid and net.ssid ~= "") and net.ssid or nil
            wifi_name, wifi_dot = ssid or "Wi-Fi", "●"
        end
    end

    -- Version + update: what used to only live in the WIĘCEJ menu and the
    -- separate AKTUALIZACJA banner (kept below, unchanged, for the actual
    -- install action) — here it's just the glance answer to "am I current".
    -- ASCII ">" rather than "→": that arrow glyph already exists elsewhere in
    -- this file but was never physically confirmed on PW3 (TODO.md flags it
    -- UNKNOWN) — this line renders far more often than either of its other
    -- two spots, so it doesn't get to be the one that finds out.
    local ok_ver, local_version = pcall(function() return self.plugin:localVersion() end)
    local version_text = "v" .. (ok_ver and local_version or "?")
    if self.plugin.update_ready then
        version_text = version_text .. " > v" .. tostring(self.plugin.update_ready)
    end

    local ok_batt, capacity = pcall(function() return Device:getPowerDevice():getCapacity() end)
    local has_batt = ok_batt and type(capacity) == "number"
    local batt_text = has_batt and (capacity .. "%") or "—"

    -- Fixed segments are measured first and reserve their own width; the
    -- Wi-Fi segment gets whatever is left and truncates the SSID inside it.
    -- So a long SSID (or "v2.2.5 > v2.2.6") can shorten only the SSID —
    -- never push version or battery off the right edge. And if even that
    -- leaves the SSID no room (a very long update string on a narrow
    -- screen), the glance-only segments give way first — weather, then the
    -- date — so the strip itself is always exactly cw wide.
    local hdr_h = Screen:scaleBySize(40)
    local seg_pad = Screen:scaleBySize(9)
    local hdr_ico = Screen:scaleBySize(20)
    local hdr_gap = Screen:scaleBySize(6)
    local f_hdr = dashFace(SIZE_META)
    local batt_widget = HorizontalGroup:new { text(batt_text, f_hdr) }
    if has_batt then
        table.insert(batt_widget, HorizontalSpan:new { width = hdr_gap })
        table.insert(batt_widget, batteryIcon(math.max(0, math.min(capacity, 100)) / 100, Screen:scaleBySize(11)))
    end
    local wifi_min = Screen:scaleBySize(20) -- the SSID's own minimum
        + 2 * seg_pad + hdr_ico + 2 * hdr_gap + size(text(wifi_dot, f_hdr)).w
    local segs = {
        { widget = text(os.date("%H:%M"), dashFace(SIZE_TITLE), { bold = true }) },
        { widget = text(plDate(), f_hdr), optional = 2 },
    }
    if weather_text ~= "" then segs[#segs + 1] = { widget = text(weather_text, f_hdr), optional = 1 } end
    segs[#segs + 1] = { flex = true }
    segs[#segs + 1] = { widget = text(version_text, f_hdr) }
    segs[#segs + 1] = { widget = batt_widget }
    for _i, s in ipairs(segs) do
        if not s.flex then s.w = size(s.widget).w + 2 * seg_pad end
    end
    local hdr_inner = cw - 2 * bord
    local function usedWidth()
        local used = (#segs - 1) * bord
        for _i, s in ipairs(segs) do used = used + (s.w or 0) end
        return used
    end
    for drop = 1, 2 do
        if hdr_inner - usedWidth() >= wifi_min then break end
        for i, s in ipairs(segs) do
            if s.optional == drop then table.remove(segs, i); break end
        end
    end
    local wifi_w = math.max(wifi_min, hdr_inner - usedWidth())
    local ssid_room = wifi_w - 2 * seg_pad - hdr_ico - 2 * hdr_gap - size(text(wifi_dot, f_hdr)).w
    local wifi_widget = HorizontalGroup:new {
        icon("wifi", hdr_ico),
        HorizontalSpan:new { width = hdr_gap },
        text(wifi_name, f_hdr, { max_width = ssid_room }),
        HorizontalSpan:new { width = hdr_gap },
        text(wifi_dot, f_hdr),
    }
    local header = HorizontalGroup:new {}
    for i, s in ipairs(segs) do
        if i > 1 then table.insert(header, vline(hdr_h)) end
        local w = s.flex and wifi_w or s.w
        table.insert(header, CenterContainer:new {
            dimen = Geom:new { w = w, h = hdr_h }, s.flex and wifi_widget or s.widget })
    end
    add(FrameContainer:new { bordersize = bord, padding = 0, width = cw, radius = 0, header }, hdr_h)
    gap(8)

    -- ---- undo. A tap on e-ink lands a row off more often than on a phone, so
    -- the way back has to be visible, not a hidden gesture.
    local undo = d.undo
    if type(undo) == "table" and undo.label then
        add(FrameContainer:new {
            bordersize = bord, padding = Screen:scaleBySize(5), width = cw, radius = 0,
            text("COFNIJ: " .. tostring(undo.label), dashFace(SIZE_META), { max_width = cw - Screen:scaleBySize(20) }),
        }, h_meta + Screen:scaleBySize(12), { kind = "undo", label = tostring(undo.label) })
        gap(8)
    end

    -- ---- update banner. Announces itself on the dashboard rather than in a
    -- popup: you came here to read, and a modal on arrival would be an ambush.
    if self.plugin.update_ready then
        add(lrRow(cw, h_row, "AKTUALIZACJA  v" .. tostring(self.plugin.update_ready),
            "zainstaluj  >", dashFace(SIZE_LABEL), dashFace(SIZE_META), true),
            h_row, { kind = "update", label = "update" })
        gap(8)
    end

    -- ---- footer text, decided once (it spends a hint) and drawn inside the
    -- budgeted block below.
    local foot = ""
    if self.age then
        foot = string.format("offline · dane sprzed %d h", math.floor(self.age / 3600))
    else
        local left = tonumber(get("readingos_hints_left")) or 0
        if left > 0 then
            foot = "· " .. HINTS[(left % #HINTS) + 1] .. " ·"
            set("readingos_hints_left", left - 1)
        end
    end

    -- ---- what the cards must fit above: the pinned nav.
    local nav_ico = Screen:scaleBySize(24)
    local nav_h = math.max(MIN_TAP, nav_ico + Screen:scaleBySize(4) + h_label + Screen:scaleBySize(12))
    local nav_rule = Screen:scaleBySize(2)
    local limit = H - pad - nav_rule - nav_h

    local chev = Screen:scaleBySize(18)
    local f_head = dashFace(SIZE_HEAD)
    local ico = Screen:scaleBySize(34)
    local ico_col = Screen:scaleBySize(56)
    local chev_col = chev + Screen:scaleBySize(6)
    local text_w = iw - ico_col - chev_col

    local overdue, out = 0, 0
    for _i, t in ipairs(d.tasks or {}) do if t.sym == "▲" then overdue = overdue + 1 end end
    for _i, hh in ipairs(d.house or {}) do if hh.state == "out" then out = out + 1 end end

    local totals = d.totals or {}
    local tb = totals.task_buckets or {}
    local tparts = {}
    if (tb.past or 0) > 0 then tparts[#tparts + 1] = tb.past .. " zaległe" end
    if (tb.today or 0) > 0 then tparts[#tparts + 1] = tb.today .. " dziś" end
    if (tb.tmrw or 0) > 0 then tparts[#tparts + 1] = tb.tmrw .. " jutro" end
    local summary = table.concat(tparts, " · ")
    if summary == "" and totals.tasks and totals.tasks > 0 then summary = tostring(totals.tasks) end
    local tasks = d.preview_tasks or d.tasks or {}
    local house = d.house or {}
    local crafts = d.crafts or {}
    local shopping = d.shopping or { total = 0, preview = {} }
    local shop_items = {}
    for _i, name in ipairs(shopping.preview or {}) do
        shop_items[#shop_items + 1] = { sym = "·", text = name }
    end

    -- CO CZYTAM's lead column: the book's real cover where the other cards
    -- have an icon. No cover on this device (not in the cover browser's
    -- cache, no open document) → KOReader's own book icon, same column,
    -- nothing broken. Built once, outside the re-layout loop: an ImageWidget
    -- scales its BlitBuffer on first measure, and that work is not repeated.
    local book = self.plugin:currentBook(d)
    local cover_w, cover_h = Screen:scaleBySize(60), Screen:scaleBySize(82)
    local ok_cov, cover_bb = pcall(function() return self.plugin:bookCover(book.title) end)
    local lead, lead_w = icon("book.opened", ico), ico_col
    if ok_cov and cover_bb and ImageWidget then
        local ok_img, img = pcall(function()
            return ImageWidget:new { image = cover_bb, image_disposable = false,
                width = cover_w, height = cover_h, scale_factor = 0 }
        end)
        if ok_img and img then
            lead = FrameContainer:new { bordersize = bord, padding = 0, radius = 0, img }
            lead_w = cover_w + 2 * bord + Screen:scaleBySize(14)
        end
    end

    local function cardTitle(label, count)
        local g = HorizontalGroup:new { text(label, f_head, { bold = true }) }
        if count and count ~= "" then
            table.insert(g, HorizontalSpan:new { width = Screen:scaleBySize(12) })
            table.insert(g, text(count, f_head))
        end
        return g
    end
    --- icon column | body | chevron, the body as tall as it needs to be and
    --- the icon centred beside it. `lead` is the icon column's widget
    --- (an icon, or the book cover) and sets the column's width.
    local function addContentCard(lead_widget, lead_width, body, target)
        local body_h = math.max(size(lead_widget).h, size(body).h)
        local row = OverlapGroup:new { dimen = Geom:new { w = iw, h = body_h } }
        table.insert(row, LeftContainer:new { dimen = Geom:new { w = iw, h = body_h },
            HorizontalGroup:new {
                CenterContainer:new { dimen = Geom:new { w = lead_width, h = body_h }, lead_widget },
                body,
            } })
        table.insert(row, RightContainer:new { dimen = Geom:new { w = iw, h = body_h },
            icon("chevron.right", chev) })
        addCard({ { widget = row } }, target)
        gap(10)
    end
    local function lines(items, quiet_text, width, max_lines)
        local g = VerticalGroup:new { align = "left" }
        if #items == 0 then
            table.insert(g, text(quiet_text, dashFace(SIZE_ROW), { max_width = width }))
        else
            for i = 1, math.min(max_lines, #items) do
                table.insert(g, text(rowText(items[i]), dashFace(SIZE_ROW), { max_width = width }))
            end
        end
        return g
    end
    local function body(label, count, content)
        return VerticalGroup:new { align = "left",
            cardTitle(label, count),
            VerticalSpan:new { width = Screen:scaleBySize(2) },
            content,
        }
    end

    --- Everything between the header block and the nav, at a given density.
    local function layoutCards(max_tasks, max_lines)
        -- ZADANIA card: attention row (only when something is genuinely
        -- late), the horizon summary, then the rows — one border around
        -- all of it. The chevron sits on the top row, whichever that is.
        -- The card itself is a target too, so a tap on its padding still
        -- opens the list; rows are registered first and win.
        local task_items = {}
        local chevron_used = false
        local function chevron()
            if chevron_used then return nil end
            chevron_used = true
            return icon("chevron.right", chev)
        end
        if overdue > 0 or out > 0 then
            local parts = {}
            if overdue > 0 then parts[#parts + 1] = overdue .. " PO TERMINIE" end
            if out > 0 then parts[#parts + 1] = out .. " BRAK" end
            task_items[#task_items + 1] = {
                widget = cardRow(h_row, text("▲  " .. table.concat(parts, " · "), f_head, { bold = true, max_width = iw - chev - hdr_gap }), chevron()),
                target = { screen = overdue > 0 and "tasks" or "house", label = "attention" },
            }
            task_items[#task_items + 1] = { widget = hline(iw) }
        end
        local summary_widget = HorizontalGroup:new { text("ZADANIA", f_head, { bold = true }) }
        if summary ~= "" then
            table.insert(summary_widget, HorizontalSpan:new { width = Screen:scaleBySize(14) })
            table.insert(summary_widget, text(summary, f_head, { max_width = iw - chev - Screen:scaleBySize(90) }))
        end
        task_items[#task_items + 1] = {
            widget = cardRow(h_row, summary_widget, chevron()),
            target = { screen = "tasks", label = "tasks" },
        }
        if #tasks == 0 then
            task_items[#task_items + 1] = { widget = cardRow(h_row, text("nic na mnie", dashFace(SIZE_META), { gray = true })) }
        else
            task_items[#task_items + 1] = { widget = hline(iw) }
            for i = 1, math.min(max_tasks, #tasks) do
                local it = tasks[i]
                task_items[#task_items + 1] = {
                    widget = lrRow(iw, h_row, rowText(it), it.meta, dashFace(SIZE_ROW), dashFace(SIZE_META), false),
                    target = { kind = it.kind, id = it.id, screen = "tasks", label = it.text, row = it },
                }
            end
        end
        addCard(task_items, { screen = "tasks", label = "tasks-card" })
        gap(10)

        -- section cards. DOM / CO CZYTAM / ZAKUPY / CRAFTSSS: icon column,
        -- title + count, lines, chevron — one border each, one under the other.
        addContentCard(icon("home", ico), ico_col,
            body("DOM", totals.house and totals.house > 0 and tostring(totals.house) or nil,
                lines(house, "wszystko jest ogarnięte", text_w, max_lines)),
            { screen = "house", label = "house" })

        do
            local bw = iw - lead_w - chev_col
            local content = VerticalGroup:new { align = "left",
                text(book.title, dashFace(SIZE_ROW), { max_width = bw }) }
            if book.author ~= "" or book.percent ~= "" then
                local meta = HorizontalGroup:new {}
                if book.author ~= "" then
                    table.insert(meta, text(book.author, dashFace(SIZE_META), { gray = true, max_width = math.floor(bw * 0.7) }))
                    table.insert(meta, HorizontalSpan:new { width = Screen:scaleBySize(14) })
                end
                if book.percent ~= "" then table.insert(meta, text(book.percent, dashFace(SIZE_META))) end
                table.insert(content, meta)
            end
            table.insert(content, VerticalSpan:new { width = Screen:scaleBySize(6) })
            table.insert(content, ProgressWidget:new {
                width = bw, height = Screen:scaleBySize(5), percentage = book.fraction or 0,
                margin_h = 0, margin_v = 0, bordersize = bord, radius = Screen:scaleBySize(2),
                fillcolor = Blitbuffer.COLOR_BLACK,
            })
            addContentCard(lead, lead_w, body("CO CZYTAM", nil, content), { kind = "continue", label = "continue" })
        end

        addContentCard(icon("cart", ico), ico_col,
            body("ZAKUPY", (shopping.total or 0) > 0 and tostring(shopping.total) or nil,
                lines(shop_items, "lista pusta", text_w, max_lines)),
            { screen = "shopping", label = "shopping" })

        addContentCard(icon("yarn", ico), ico_col,
            body("CRAFTSSS", #crafts > 0 and tostring(#crafts) or nil,
                lines(crafts, "nic w budowie", text_w, max_lines)),
            { screen = "crafts", label = "crafts" })

        -- footer: staleness / one rotating hint, inert, glance-only.
        if foot ~= "" then
            local ft = text(foot, dashFace(SIZE_META), { gray = true })
            local fh = size(ft, h_meta).h
            add(CenterContainer:new { dimen = Geom:new { w = cw, h = fh }, ft }, fh)
        end
    end

    -- Densest first; each retry drops preview lines, content cards before
    -- task rows. The last attempt (one line of everything) always fits.
    local attempts = { { 3, 3 }, { 3, 2 }, { 3, 1 }, { 2, 1 }, { 1, 1 } }
    for i, a in ipairs(attempts) do
        local rows_n, hit_n, y0 = #rows, #self.hit, y
        layoutCards(a[1], a[2])
        if y <= limit or i == #attempts then break end
        for k = #rows, rows_n + 1, -1 do rows[k] = nil end
        for k = #self.hit, hit_n + 1, -1 do self.hit[k] = nil end
        y = y0
    end

    -- ---- bottom nav: six equal icon+label targets pinned to the very bottom
    -- of the screen, ZAMKNIJ first — the one way out of the whole screen, and
    -- now a full-height tile rather than a small glyph in the corner. The
    -- spacer below is computed from `y`, the REAL running offset every add()
    -- above already measured via getSize() — never an assumed content height.
    local spacer = limit - y
    if spacer > 0 then
        rows[#rows + 1] = VerticalSpan:new { width = spacer }
        y = y + spacer
    end

    add(rule(cw), nav_rule)
    local nav_items = {
        { icon = "close", label = "ZAMKNIJ", target = { kind = "close", label = "close" } },
        { icon = "tasks", label = "ZADANIA", target = { screen = "tasks", label = "tasks" } },
        { icon = "home", label = "DOM", target = { screen = "house", label = "house" } },
        { icon = "cart", label = "ZAKUPY", target = { screen = "shopping", label = "shopping" } },
        { icon = "wallet", label = "RACHUNKI", target = { screen = "bills", label = "bills" } },
        { icon = "more", label = "WIĘCEJ", target = { kind = "more", label = "more" } },
    }
    local seg_w = math.floor(cw / #nav_items)
    local nav_group = HorizontalGroup:new {}
    for i, it in ipairs(nav_items) do
        if i > 1 then table.insert(nav_group, vline(nav_h)) end
        table.insert(nav_group, CenterContainer:new {
            dimen = Geom:new { w = seg_w - bord, h = nav_h },
            VerticalGroup:new { align = "center",
                icon(it.icon, nav_ico),
                VerticalSpan:new { width = Screen:scaleBySize(4) },
                text(it.label, dashFace(SIZE_LABEL), { max_width = seg_w - 2 * bord }),
            },
        })
    end
    local nav_ty = y
    add(nav_group, nav_h)
    for i, it in ipairs(nav_items) do
        local x1 = pad + (i - 1) * seg_w
        local x2 = (i == #nav_items) and (pad + cw) or (pad + i * seg_w)
        local target = { screen = it.target.screen, kind = it.target.kind, label = it.target.label }
        target.y1, target.y2, target.x1, target.x2 = nav_ty, y, x1, x2
        self.hit[#self.hit + 1] = target
    end

    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = pad,
        width = W,
        height = Screen:getHeight(),
        VerticalGroup:new { align = "left", unpack(rows) },
    }
end

-- x is optional on purpose: every full-width row registers without one, and
-- only the side-by-side tiles at the bottom care which half was hit.
function Dashboard:targetAt(x, y)
    for _i, t in ipairs(self.hit) do
        if y >= t.y1 and y < t.y2
            and (not t.x1 or x >= t.x1)
            and (not t.x2 or x < t.x2) then
            return t
        end
    end
    return nil
end

function Dashboard:onTap(_arg, ges)
    local t = self:targetAt(ges.pos.x, ges.pos.y)
    if not t then return true end -- taps on inert areas do nothing, by design
    self.plugin:handle(self, t, false)
    return true
end

-- Rule 1: a long press only ever duplicates something a tap can already reach.
function Dashboard:onHold(_arg, ges)
    local t = self:targetAt(ges.pos.x, ges.pos.y)
    if not t then return true end
    self.plugin:handle(self, t, true)
    return true
end

function Dashboard:onSwipeBack(_arg, ges)
    if ges.direction == "east" then self:onClose() end
    return true
end

function Dashboard:onClose()
    track("home", "close", nil, (os.time() - (self.opened_at or os.time())) * 1000)
    UIManager:close(self)
    return true
end

function Dashboard:onCloseWidget()
    self:cancelRevPoll()
    UIManager:setDirty(nil, "full")
end

-- ------------------------------------------------------------------ screens

--- The hero book.
---
--- What the reading board in tasksss shows wins over whatever file happens to
--- be open here (leo, 2026-08-20): the board is the record of what is being
--- read, and it is right even when the last thing opened on the Kindle was a
--- leaflet. The open document still decides whether CZYTAJ DALEJ has anywhere
--- to go, because only KOReader knows that.
--- @param d table|nil the dashboard payload
function ReadingOS:currentBook(d)
    local ui = self.ui
    local doc = ui and ui.document
    local server = d and d.book
    if type(server) == "table" and server.title and server.title ~= "" then
        return {
            title = server.title,
            author = server.author or "",
            fraction = tonumber(server.fraction) or 0,
            percent = server.percent or "",
            open = doc ~= nil,
        }
    end
    if not doc then
        return { title = "nie ma otwartej książki", author = "", fraction = 0, percent = "", open = false }
    end
    local ok, info = pcall(function()
        local props = (doc.getProps and doc:getProps()) or {}
        local title = props.title
        if not title or title == "" then
            local _dir, name = util.splitFilePathName(doc.file or "")
            title = (name or "book"):gsub("%.%w+$", "")
        end
        local percent
        if doc.info and doc.info.has_pages then
            percent = ui.paging and ui.paging:getLastPercent()
        else
            percent = ui.rolling and ui.rolling:getLastPercent()
        end
        percent = math.max(0, math.min(tonumber(percent) or 0, 1))
        return {
            title = title,
            author = props.authors or "",
            fraction = percent,
            percent = string.format("%d%%", math.floor(percent * 100 + 0.5)),
            open = true,
        }
    end)
    if not ok or not info then
        return { title = "książka", author = "", fraction = 0, percent = "", open = true }
    end
    return info
end


--- Title as a comparison key: case-folded, punctuation and spacing dropped.
local function titleKey(s)
    return (tostring(s or ""):lower():gsub("[%s%p]", ""))
end

local function titleMatches(key, other)
    local o = titleKey(other)
    if key == "" or o == "" then return false end
    if key == o then return true end
    -- "Gadka" vs "Gadka. W sześćdziesiąt języków…": the board and the file's
    -- metadata do not always agree on the subtitle. Eight characters so a
    -- one-word title cannot claim every book that starts the same way.
    local short = #key < #o and key or o
    return #short >= 8 and (key:sub(1, #short) == o:sub(1, #short))
end

--- The hero book's cover, looked up on the device — never fetched.
---
--- The dashboard's book is the reading board's (see currentBook), which may
--- not be the file open in KOReader, so the cover is found by title: the open
--- document first, then the reading history, each looked up in the cover
--- browser's own cache (settings/bookinfo_cache.sqlite3 — a read of what the
--- file browser already extracted, no document is opened here). The open
--- document's own cover is the one fallback, because KOReader has it decoded
--- already. Nothing else: opening a second book just to read its cover is a
--- second engine instance on a 256 MB device, and no cover is the correct
--- answer far more often than a stall would be.
---
--- Cached per title so a refresh does not re-read the blob; the BlitBuffer
--- stays owned here (image_disposable = false on the widget), so re-building
--- the dashboard never paints from freed memory.
--- @return BlitBuffer|nil
function ReadingOS:bookCover(title)
    local key = titleKey(title)
    if key == "" then return nil end
    if self.cover_cache and self.cover_cache.key == key then return self.cover_cache.bb end

    local bb
    pcall(function()
        local doc = self.ui and self.ui.document
        local files = {}
        if doc and doc.file then files[#files + 1] = doc.file end
        local ok_h, ReadHistory = pcall(require, "readhistory")
        if ok_h and type(ReadHistory) == "table" and type(ReadHistory.hist) == "table" then
            for i, it in ipairs(ReadHistory.hist) do
                if i > 25 then break end
                if type(it) == "table" and it.file then files[#files + 1] = it.file end
            end
        end
        local ok_b, BookInfoManager = pcall(require, "bookinfomanager")
        if not (ok_b and type(BookInfoManager) == "table") then BookInfoManager = nil end
        for _i, file in ipairs(files) do
            local info = BookInfoManager and BookInfoManager:getBookInfo(file, false)
            local matched = type(info) == "table" and titleMatches(key, info.title)
            if matched and info.has_cover then
                local full = BookInfoManager:getBookInfo(file, true)
                bb = type(full) == "table" and full.cover_bb or nil
            end
            if not bb and doc and doc.file == file and doc.getCoverPageImage then
                local props = doc.getProps and doc:getProps() or {}
                if matched or titleMatches(key, props.title) then bb = doc:getCoverPageImage() end
            end
            if bb then return end
        end
    end)
    if bb then self.cover_cache = { key = key, bb = bb } end
    return bb
end

--- Detail screens reuse KOReader's Menu: it already handles paging, tap
--- feedback and back on e-ink, and re-implementing that would be worse.
function ReadingOS:showList(title, items, on_pick)
    local menu
    menu = Menu:new {
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- Phone Companion V2: only a Menu tagged this way is offered Next/Prev
        -- by executeRemoteCommand — KOReader's Menu is the only ReadingOS
        -- screen with real page navigation (onNextPage/onPrevPage).
        readingos_screen = "menu",
        -- `inert` and `dim` are deliberately different things. KOReader renders
        -- a dim item in COLOR_DARK_GRAY, which is right for a row that has been
        -- spent and wrong for the manual — that is why the help text came out
        -- barely readable on e-ink. Prose that simply cannot be tapped is
        -- `inert`: full black, no reaction.
        onMenuSelect = function(_self, item)
            if item.inert or item.dim then return true end
            if on_pick then on_pick(item, menu) end
            return true
        end,
        close_callback = function() track(title:lower(), "back") end,
    }
    track(title:lower(), "open")
    UIManager:show(menu)
    return menu
end

--- @return boolean true if a fetch actually succeeded (fresh or acceptably-
--- cached, self:fetch()'s own definition of "worked") and got applied to the
--- widget; false if it didn't touch anything. executeRemoteCommand's
--- "refresh" reports done/failed off this — the real signal fetch() already
--- has, not a guess.
function ReadingOS:refreshInto(dashboard)
    local data, age = self:fetch()
    if not data then return false end
    dashboard.data = data
    dashboard.age = age
    dashboard.hit = {}
    -- Release the tree being replaced before dropping the reference: a
    -- rebuild is routine now (the live-refresh poll), and each one allocates
    -- a fresh scaled cover BlitBuffer. free() is KOReader's own recursive
    -- release (WidgetContainer:free walks its children); pcall'd because a
    -- widget that refuses to free must not cost us the refresh, and the old
    -- root is dropped either way. The new tree is built after this line, so
    -- it can never be the one freed, and `dashboard[1]` is nil'd so a second
    -- refresh cannot free the same tree twice.
    local stale_root = dashboard[1]
    dashboard[1] = nil
    if stale_root and stale_root.free then
        local ok_free, err = pcall(function() stale_root:free() end)
        if not ok_free then logger.warn("ReadingOS: dashboard free failed:", err) end
    end
    dashboard[1] = dashboard:build()
    UIManager:setDirty(dashboard, "full")
    return true
end

--- ODŚWIEŻ from the WIĘCEJ menu: a visible receipt either way, and the
--- cursor is re-read so the poll does not immediately refresh again.
function ReadingOS:refreshNow(dashboard)
    track("home", "refresh")
    if self:refreshInto(dashboard) then
        local ok_rev, rev = pcall(function() return self:fetchRev() end)
        if ok_rev and rev then dashboard.rev = rev end
        self:receipt(_("Odświeżono."))
    else
        UIManager:show(InfoMessage:new { text = _("Brak połączenia — pokazuję ostatnie dane.") })
    end
end

--- Rule 3: the receipt lands before the network is touched.
function ReadingOS:receipt(label)
    UIManager:show(InfoMessage:new { text = label, timeout = 1 })
end

-- ------------------------------------------------------------- task actions
--
-- A tap used to complete the row it landed on. On e-ink a tap lands a row off
-- often enough that this was, in practice, a way to silently finish the wrong
-- task — and "done" is not even the usual answer. What is usually true is that
-- the thing has moved, or belongs to someone else, or is not happening today.
-- So a tap now asks, and every answer here is one request and one undo record.

--- Run one action against a task and refresh whatever is on screen.
--- @param after function|nil called on success, for a list that must redraw
function ReadingOS:taskAct(dashboard, row, op, extra, receipt, after)
    local payload = { op = op, label = row.text }
    for k, v in pairs(extra or {}) do payload[k] = v end
    track("task", op, tostring(row.id))
    self:receipt(receipt)
    local res, err = self:act("task", row.id, payload)
    if not res then
        local msg = _("Nie zapisano — brak połączenia.")
        if err == "HTTP 409" then
            msg = _("Zadanie ma otwarte kroki. Dokończ je w tasksss.")
        elseif err == "HTTP 400" then
            msg = _("Tego zadania nie da się pominąć — nie jest cykliczne.")
        elseif err == "HTTP 404" then
            msg = _("Zadania już nie ma. Odśwież ekran.")
        end
        UIManager:show(InfoMessage:new { text = msg })
        return false
    end
    if after then after() end
    self:refreshInto(dashboard)
    return true
end

--- Set a time today, or a date, with KOReader's own picker. Typing "14:30" on a
--- Kindle keyboard is a worse answer than three taps on a spinner.
function ReadingOS:askWhen(dashboard, row, what, after)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local now = os.date("*t")

    if what == "time" then
        local hh, mm = tostring(row.time or ""):match("^(%d+):(%d+)$")
        UIManager:show(DateTimeWidget:new {
            hour = tonumber(hh) or now.hour,
            min = tonumber(mm) or 0,
            ok_text = _("Ustaw"),
            title_text = _("Godzina na dziś"),
            callback = function(t)
                local time = string.format("%02d:%02d", t.hour, t.min)
                self:taskAct(dashboard, row, "move",
                    { date = isoDay(0), time = time },
                    _("Na dziś ") .. time, after)
            end,
        })
    else
        UIManager:show(DateTimeWidget:new {
            year = now.year, month = now.month, day = now.day,
            ok_text = _("Ustaw"),
            title_text = _("Data zadania"),
            callback = function(t)
                local date = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
                self:taskAct(dashboard, row, "move", { date = date },
                    _("Przeniesiono na ") .. date, after)
            end,
        })
    end
end

--- The house has one action, but it still gets a confirmation: the row sits
--- inside a finger's width of the task rows above it, and "restocked" is just
--- as wrong to record by accident.
function ReadingOS:restockMenu(dashboard, row, after)
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    dialog = ButtonDialogTitle:new {
        title = (row.text or "?") .. "\n" .. (row.meta or ""),
        title_align = "left",
        buttons = { {
            { text = _("Uzupełnione"), callback = function()
                UIManager:close(dialog)
                track("home", "restock", tostring(row.id))
                self:receipt(_("Uzupełnione: ") .. (row.text or ""))
                local res = self:act("restock", row.id, { label = row.text })
                if not res then
                    UIManager:show(InfoMessage:new { text = _("Nie zapisano — brak połączenia.") })
                    return
                end
                if after then after() end
                self:refreshInto(dashboard)
            end },
            { text = _("Anuluj"), callback = function() UIManager:close(dialog) end },
        } },
    }
    UIManager:show(dialog)
end

-- ------------------------------------------------------------- task detail
--
-- Wireframe v0.3. Tapping a task never used to complete it (taskMenu above
-- already made every action its own explicit button) — what this adds is the
-- persistent detail screen (CO/KTO/GDZIE/KIEDY + opis + subtaski) and a real
-- second confirmation step before anything is written, per spec.
--
-- No icon font exists in this codebase for E-Ink glyphs — icons here are
-- plain mono/emoji characters already proven to render on this device
-- (✓ ⚡ 🔒 ✈ elsewhere in this file). Decisions: priority reuses "!" (already
-- the convention for priority everywhere else — pmark, web's bang());
-- fixed-hour is "\u{23F0}" (⏰), new, chosen to be visually unlike ▲●○.

--- Human "when" line: dashboard's ▲●○ convention, plus a real calendar date
--- beyond tomorrow (which the one-line dashboard row never had to print).
local function whenLabel(d)
    if not d.date or d.date == "" then return "" end
    local parts = {}
    if d.sym then parts[#parts + 1] = d.sym end
    if d.date == isoDay(0) then parts[#parts + 1] = _("dziś")
    elseif d.date == isoDay(1) then parts[#parts + 1] = _("jutro")
    else parts[#parts + 1] = isoToPl(d.date) end
    if d.time and d.time ~= "" then parts[#parts + 1] = d.time end
    return table.concat(parts, "  ")
end

local TaskDetail = InputContainer:extend {
    plugin = nil,
    dashboard = nil, -- the real Home screen underneath — taskAct refreshes it
    row = nil,       -- the tapped row: always available, even if detail below is nil
    detail = nil,    -- GET /api/readingos/task/:id payload, or nil on failure
    reason = nil,    -- set whenever detail is nil: "not_found" or "unavailable"
    after = nil,     -- optional: the caller's own optimistic-UI callback (e.g. ZADANIA list)
    opened_at = nil,
}

function TaskDetail:init()
    self.opened_at = os.time()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.readingos_screen = "detail" -- Phone Companion V2: identifies this widget to executeRemoteCommand
    self.hit = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            SwipeBack = { GestureRange:new { ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
end

function TaskDetail:claim(y, height, target)
    target.y1, target.y2 = y, y + height
    self.hit[#self.hit + 1] = target
    return y + height
end

function TaskDetail:targetAt(x, y)
    for _i, t in ipairs(self.hit) do
        if y >= t.y1 and y < t.y2
            and (not t.x1 or x >= t.x1)
            and (not t.x2 or x < t.x2) then
            return t
        end
    end
    return nil
end

--- Whether the task repeats — from the fetched detail when it landed, else
--- from the row the dashboard already had (so the screen still gates
--- "Zrobione i zmień osobę"/"Pomiń" correctly even fully offline).
function TaskDetail:repeats()
    if self.detail then return not not self.detail.repeats end
    return not not (self.row and self.row.repeats)
end

function TaskDetail:build()
    local Blitbuffer = require("ffi/blitbuffer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(18)
    local cw = W - 2 * pad
    local rows, y = {}, pad
    local d = self.detail

    local h_meta = Screen:scaleBySize(SIZE_META * 1.7 * FONT_SCALE)
    local h_row = math.max(MIN_TAP, Screen:scaleBySize(SIZE_ROW * 2 * FONT_SCALE))
    local h_title = Screen:scaleBySize(SIZE_TITLE * 1.8 * FONT_SCALE)

    -- Measure the widget instead of trusting the height it was asked for —
    -- same fix as Dashboard:build(), same reason (a wrapped/wrapping widget's
    -- real render height can differ from the request, and hit-tests drift
    -- from there down).
    local function add(w, h, target)
        rows[#rows + 1] = w
        local ok, size = pcall(function() return w:getSize() end)
        local real = (ok and size and size.h and size.h > 0) and size.h or h
        if target then y = self:claim(y, real, target) else y = y + real end
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        rows[#rows + 1] = VerticalSpan:new { width = h }
        y = y + h
    end

    add(lrRow(cw, h_meta, "‹  " .. _("Zadanie"), "", faceFull(SIZE_META), faceFull(SIZE_META), true),
        h_meta, { kind = "back" })
    add(rule(cw), Screen:scaleBySize(2))
    gap(8)

    if self.reason then
        -- A real 404 and a transient upstream failure must never share the
        -- old "offline" row fallback: that showed the tapped row's own text
        -- and still offered ZROBIONE/POMIŃ/Więcej, which is wrong on both
        -- counts here — a deleted task has nothing to complete, and a
        -- network hiccup should say so rather than pretend the screen works.
        local msg = self.reason == "not_found"
            and _("Zadanie nie istnieje lub zostało usunięte.")
            or _("Nie można pobrać szczegółów. Sprawdź połączenie.")
        add(TextBoxWidget:new {
            text = msg, face = faceFull(SIZE_ROW), width = cw, alignment = "left",
        }, h_row)
    else
        -- CO: title, priority ("!") ahead of it, never an empty/off marker.
        local title = (self.row and self.row.text) or (d and d.title) or "?"
        local prio = (d and d.priority) or (self.row and (self.row.priority or 0) > 0)
        add(TextBoxWidget:new {
            text = (prio and "!  " or "") .. title,
            face = faceFull(SIZE_TITLE), width = cw, alignment = "left",
        }, h_title)
        gap(6)

        -- KTO: never a raw CSV — one name, or a joined readable list.
        if #d.assignees > 0 then
            add(TextWidget:new { text = table.concat(d.assignees, ", "), face = faceFull(SIZE_ROW), max_width = cw }, h_meta)
        end
        -- GDZIE: only if tasksss actually has one — no invented empty section.
        if d.project and d.project ~= "" then
            add(TextWidget:new { text = d.project, face = faceFull(SIZE_ROW), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = cw }, h_meta)
        end
        -- KIEDY: ▲●○ + calendar date + godzina, ⏰ only when fixed=true.
        local when = whenLabel(d)
        if d.fixed and when ~= "" then when = when .. "  \u{23F0}" end
        if when ~= "" then
            add(TextWidget:new { text = when, face = faceFull(SIZE_ROW), max_width = cw }, h_meta)
        end

        gap(10)
        add(rule(cw, true), Screen:scaleBySize(1))
        gap(8)

        -- OPIS: full text is never inlined here — a real one in this DB runs past
        -- 1500 characters, and this canvas has no scroll. The row previews and
        -- taps through to TextViewer, which paginates any length natively.
        if d.description and d.description ~= "" then
            local preview = d.description:sub(1, 90)
            if #d.description > 90 then preview = preview .. "…" end
            add(lrRow(cw, h_row, _("Opis"), preview, faceFull(SIZE_ROW), faceFull(SIZE_META), true),
                h_row, { kind = "opis" })
            gap(8)
            add(rule(cw, true), Screen:scaleBySize(1))
            gap(8)
        end

        -- SUBTASKI: the cycle's checklist, always shown fresh (0 done) on a new
        -- occurrence — server-side (spawnNext), nothing to do here but display it.
        if #d.subtasks > 0 then
            local doneN = 0
            for _i, s in ipairs(d.subtasks) do if s.done then doneN = doneN + 1 end end
            add(lrRow(cw, h_meta, string.upper(_("Subtaski")), string.format("%d/%d", doneN, #d.subtasks),
                faceFull(SIZE_HEAD), faceFull(SIZE_HEAD), true), h_meta)
            gap(4)
            -- ponytail: many subtasks + a long opis preview can push the action
            -- stack below the fold — this screen does not scroll. Raise if a real
            -- task ever has more than a handful.
            for _i, s in ipairs(d.subtasks) do
                add(TextWidget:new {
                    text = (s.done and "\u{2611}  " or "\u{2610}  ") .. s.label,
                    face = faceFull(SIZE_ROW), max_width = cw,
                }, h_row)
            end
            gap(8)
            add(rule(cw, true), Screen:scaleBySize(1))
            gap(8)
        end

        -- ACTIONS: fixed wireframe v0.3 order. Every one of these opens a
        -- confirmation, per spec — nothing here writes on this tap.
        local function actionRow(label, target, bold)
            add(FrameContainer:new {
                bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(8),
                width = cw, radius = 0, background = bold and Blitbuffer.COLOR_BLACK or nil,
                CenterContainer:new { dimen = { w = cw - Screen:scaleBySize(16), h = h_row },
                    TextWidget:new { text = label, face = faceFull(SIZE_ROW), fgcolor = bold and Blitbuffer.COLOR_WHITE or nil } },
            }, h_row + Screen:scaleBySize(14), target)
            gap(8)
        end

        actionRow(_("ZROBIONE"), { kind = "act_done" }, true)
        if self:repeats() then
            actionRow(_("ZROBIONE I ZMIEŃ OSOBĘ"), { kind = "act_reassign" })
            actionRow(_("POMIŃ"), { kind = "act_skip" })
        end
        actionRow(_("Więcej"), { kind = "act_more" })
    end

    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = pad,
        width = W,
        height = Screen:getHeight(),
        VerticalGroup:new { align = "left", unpack(rows) },
    }
end

--- One line naming the operation, plus the task's title+termin — spec forbids
--- a bare "Na jutro?"; every confirmation names its own variant explicitly.
function TaskDetail:confirm(opLabel, op, extra)
    local title = (self.row and self.row.text) or (self.detail and self.detail.title) or "?"
    local whenTxt = self.detail and whenLabel(self.detail) or (self.row and self.row.meta) or ""
    UIManager:show(ConfirmBox:new {
        text = opLabel .. "\n\n" .. title .. (whenTxt ~= "" and ("\n" .. whenTxt) or ""),
        ok_text = _("Potwierdź"),
        cancel_text = _("Anuluj"),
        ok_callback = function()
            self.plugin:taskAct(self.dashboard, self.row, op, extra, opLabel, function()
                if self.after then self.after() end
                self:onClose()
            end)
        end,
    })
end

function TaskDetail:reassignMenu()
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    local buttons = {}
    for _i, who in ipairs((self.dashboard.data or {}).people or {}) do
        buttons[#buttons + 1] = { { text = who, callback = function()
            UIManager:close(dialog)
            self:confirm(_("Zrobione i zmień osobę → ") .. who, "done", { assign = who })
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Anuluj"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialogTitle:new { title = _("Zmień osobę na:"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--- Section 14: one-time gets [Na jutro, Archiwizuj]; cyclic gets the two
--- Na-jutro variants + Archiwizuj. "Godzina…/Data…" (free date/time editing,
--- pre-existing) live here too rather than being dropped — see task report.
function TaskDetail:moreMenu()
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    local buttons = {}
    if self:repeats() then
        buttons[#buttons + 1] = { { text = _("Na jutro — zachowaj cykl"), callback = function()
            UIManager:close(dialog)
            self:confirm(_("Na jutro — zachowaj cykl"), "move", { date = isoDay(1), keep_cycle = true })
        end } }
        buttons[#buttons + 1] = { { text = _("Na jutro — przesuń cykl"), callback = function()
            UIManager:close(dialog)
            self:confirm(_("Na jutro — przesuń cykl"), "move", { date = isoDay(1) })
        end } }
    else
        buttons[#buttons + 1] = { { text = _("Na jutro"), callback = function()
            UIManager:close(dialog)
            self:confirm(_("Na jutro"), "move", { date = isoDay(1) })
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Archiwizuj"), callback = function()
        UIManager:close(dialog)
        self:confirm(_("Archiwizuj"), "archive", nil)
    end } }
    buttons[#buttons + 1] = {
        { text = _("Godzina…"), callback = function()
            UIManager:close(dialog)
            self.plugin:askWhen(self.dashboard, self.row, "time", self.after)
            self:onClose()
        end },
        { text = _("Data…"), callback = function()
            UIManager:close(dialog)
            self.plugin:askWhen(self.dashboard, self.row, "date", self.after)
            self:onClose()
        end },
    }
    buttons[#buttons + 1] = { { text = _("Anuluj"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialogTitle:new { title = _("Więcej"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function TaskDetail:onTap(_arg, ges)
    local t = self:targetAt(ges.pos.x, ges.pos.y)
    if not t then return true end

    if t.kind == "back" then return self:onClose() end

    if t.kind == "opis" then
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new {
            title = _("Opis"),
            text = (self.detail and self.detail.description) or "",
        })
        return true
    end

    if t.kind == "act_done" then
        self:confirm(_("Zrobione: ") .. ((self.row and self.row.text) or "?"), "done", nil)
        return true
    end

    if t.kind == "act_skip" then
        self:confirm(_("Pomiń to wystąpienie"), "skip", nil)
        return true
    end

    if t.kind == "act_reassign" then
        self:reassignMenu()
        return true
    end

    if t.kind == "act_more" then
        self:moreMenu()
        return true
    end

    return true
end

function TaskDetail:onSwipeBack(_arg, ges)
    if ges.direction == "east" then self:onClose() end
    return true
end

function TaskDetail:onClose()
    track("task", "detail_close", tostring(self.row and self.row.id), (os.time() - (self.opened_at or os.time())) * 1000)
    UIManager:close(self)
    return true
end

function TaskDetail:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

--- Entry point for every tap on a task, wherever the row is shown (Home,
--- ZADANIA list). Fetches detail synchronously, same blocking-call contract
--- as every other network action in this file (checkForUpdate, restockMenu,
--- taskAct) — a 5-15s socket timeout, never a silent hang.
function ReadingOS:openTaskDetail(dashboard, row, after)
    track("task", "open_detail", tostring(row.id))
    local detail, reason = self:fetchTaskDetail(row.id)
    UIManager:show(TaskDetail:new { plugin = self, dashboard = dashboard, row = row, detail = detail, reason = reason, after = after }, "full")
end

function ReadingOS:handle(dashboard, target, is_hold)
    -- A long press opens the detail screen a tap can also reach.
    if is_hold and target.screen then
        return self:openScreen(dashboard, target.screen)
    end

    if target.kind == "continue" then
        track("home", "continue")
        dashboard:onClose()
        if not (self.ui and self.ui.document) then
            UIManager:show(InfoMessage:new { text = _("Najpierw otwórz książkę w menedżerze plików.") })
        end
        return
    end

    if target.kind == "close" then
        return dashboard:onClose()
    end

    if target.kind == "update" then
        return self:checkForUpdate(false)
    end

    if target.kind == "undo" then
        track("home", "undo", target.label)
        self:receipt(_("Cofam…"))
        local res = self:act("undo")
        if not (res and res.ok) then
            UIManager:show(InfoMessage:new { text = _("Nie da się cofnąć. Za stare, już cofnięte gdzie indziej, albo brak połączenia.") })
        end
        return self:refreshInto(dashboard)
    end

    -- Rule: nothing on the home screen completes on touch. The whole screen is
    -- read at a glance and tapped without looking twice, so every write it can
    -- start has to be confirmed on a second screen first.
    if target.kind == "task" then
        return self:openTaskDetail(dashboard, target.row or { id = target.id, text = target.label })
    end

    if target.kind == "restock" then
        return self:restockMenu(dashboard, target.row or { id = target.id, text = target.label })
    end

    -- One honest placeholder, reused everywhere a section has no data source
    -- yet (Zakupy's full list, Rachunki, and — from the WIĘCEJ menu —
    -- Notatki/Artykuły). Never a fake screen, never fake rows.
    if target.kind == "soon" then
        UIManager:show(InfoMessage:new { text = _(target.label or "Jeszcze niedostępne.") })
        return
    end

    if target.kind == "more" then
        return self:openMore(dashboard)
    end

    if target.screen then return self:openScreen(dashboard, target.screen) end
end

--- WIĘCEJ: three groups, most-used first, one screen (ADHD rule: as few
--- taps as possible between intent and action). Działania are things you
--- do now; Ekrany are the surfaces that left the dashboard; Ustawienia
--- opens KOReader's own ReadingOS submenu (the one under Narzędzia) rather
--- than duplicating its toggles here — one definition, one place to fix.
--- Group headers are `inert` rows (full black, not tappable, not dimmed).
function ReadingOS:openMore(dashboard)
    local items = {
        { text = "— DZIAŁANIA —", inert = true },
        { text = "ODŚWIEŻ", action = "refresh" },
        { text = "TELEFON", action = "phone" },
        { text = "ZABLOKUJ EKRAN", action = "lock" },
        { text = "— EKRANY —", inert = true },
        { text = "CRAFTSSS", screen = "crafts" },
        { text = "NAUKA", screen = "learn" },
        { text = "DIG", screen = "dig" },
        { text = "NOTATKI", screen = "notes" },
        { text = "ARTYKUŁY", screen = "articles" },
        { text = "— USTAWIENIA —", inert = true },
        { text = "USTAWIENIA", action = "settings" },
        { text = "SPRAWDŹ AKTUALIZACJE  (v" .. self:localVersion() .. ")", action = "update" },
        { text = "JAK TO DZIAŁA", screen = "help" },
    }
    self:showList("WIĘCEJ", items, function(item, menu)
        UIManager:close(menu)
        if item.action == "refresh" then
            self:refreshNow(dashboard)
        elseif item.action == "phone" then
            self:showPhone()
        elseif item.action == "lock" then
            self:showLockScreen()
        elseif item.action == "settings" then
            self:openSettings()
        elseif item.action == "update" then
            self:checkForUpdate(false)
        elseif item.screen then
            self:openScreen(dashboard, item.screen)
        end
    end)
end

--- The KOReader ReadingOS submenu, opened as its own screen. Same
--- `sub_item_table` addToMainMenu registers under Narzędzia — built once,
--- shown here through KOReader's own TouchMenu so every toggle, spinner and
--- text editor behaves exactly as it does there.
function ReadingOS:openSettings()
    local ok, err = pcall(function()
        local TouchMenu = require("ui/widget/touchmenu")
        local items = {}
        self:addToMainMenu(items)
        local entry = items.readingos
        if not (entry and entry.sub_item_table) then error("no menu entry") end
        -- TouchMenu's tab_item_table[n] IS that tab's item list, carrying
        -- its own .text/.icon (readermenu.lua does the same with the
        -- registered tables).
        local tab = entry.sub_item_table
        tab.text = entry.text
        tab.icon = "appbar.settings"
        local container = CenterContainer:new {
            covers_header = true,
            ignore = "height",
            dimen = Screen:getSize(),
        }
        local menu = TouchMenu:new {
            width = Screen:getWidth(),
            tab_item_table = { tab },
            show_parent = container,
        }
        menu.close_callback = function()
            track("settings", "back")
            UIManager:close(container)
        end
        container[1] = menu
        track("settings", "open")
        UIManager:show(container)
    end)
    if not ok then
        logger.warn("ReadingOS: openSettings failed:", err)
        UIManager:show(InfoMessage:new {
            text = _("Ustawienia: Narzędzia → ReadingOS w menu KOReadera."),
        })
    end
end

function ReadingOS:openScreen(dashboard, screen)
    local d = dashboard.data or {}

    if screen == "help" then
        return self:showHelp()

    elseif screen == "tasks" or screen == "house" then
        local src = screen == "tasks" and (d.tasks or {}) or (d.house or {})
        local items = {}
        -- One flat run of thirty rows is why the full list was unpleasant to
        -- open: nothing told you where "overdue" stopped and "tomorrow" began,
        -- so the whole thing had to be read to find the part you wanted. The
        -- server already sorts by bucket, so a header per change of bucket is
        -- the entire fix.
        local BUCKETS = { past = "ZALEGŁE", today = "DZIŚ", tmrw = "JUTRO" }
        local bucket = nil
        for _i, it in ipairs(src) do
            if it.bucket and it.bucket ~= bucket then
                bucket = it.bucket
                if #items > 0 then items[#items + 1] = { text = "", inert = true } end
                items[#items + 1] = { text = BUCKETS[bucket] or bucket, bold = true, inert = true }
            end
            -- Title on the left, why-it-is-here on the right. Menu's
            -- `mandatory` column keeps the two from colliding for free.
            local extra = it.meta or ""
            if it.detail and it.detail ~= "" then extra = extra .. "  ·  " .. it.detail end
            items[#items + 1] = { text = rowText(it), mandatory = extra, row = it }
        end
        if #items == 0 then
            items = { { text = _("Pusto. To jest dobry wynik."), inert = true } }
        end
        self:showList(screen == "tasks" and "ZADANIA" or "DOM", items, function(item, menu)
            if not item.row then return end
            -- Same menu as the dashboard: there is one way to act on a task,
            -- and it is the same one wherever the row is shown.
            local function mark()
                item.text = "✓  " .. rowText(item.row)
                item.dim = true          -- genuinely spent, so genuinely greyed
                item.row = nil
                menu:updateItems()
            end
            if screen == "tasks" then
                self:openTaskDetail(dashboard, item.row, mark)
            else
                self:restockMenu(dashboard, item.row, mark)
            end
        end)

    elseif screen == "shopping" then
        -- Read-only: ReadingOS has no toggle/mutation for shopping items (that
        -- stays in Foood's own UI), so every row is inert — Rule 4, no marker
        -- on a row that reacts to nothing.
        local names = (d.shopping or {}).items or {}
        local items = {}
        for _i, name in ipairs(names) do
            items[#items + 1] = { text = name, inert = true }
        end
        if #items == 0 then
            items = { { text = _("Lista pusta."), inert = true } }
        end
        self:showList("ZAKUPY", items, nil)

    elseif screen == "bills" then
        -- Read-only, same reason as Zakupy: no mutation from ReadingOS, so
        -- both rows are inert.
        local bills = d.bills or {}
        local items = {}
        if (bills.count or 0) == 0 then
            items = { { text = _("Brak rachunków w tym miesiącu."), inert = true } }
        else
            local mnum = tonumber(tostring(bills.month or ""):match("%-(%d+)$"))
            items = {
                { text = formatPln(bills.spent or 0), inert = true },
                { text = string.format("%d płatności · %s", bills.count,
                    (mnum and MONTHS[mnum]) or ""), inert = true },
            }
        end
        self:showList("RACHUNKI", items, nil)

    elseif screen == "notes" then
        -- Read-only glance, not a browser: capped at 3, same as the design
        -- calls for everywhere else. No tap action — Minifolio is where a
        -- note is actually opened/edited, not here.
        local notes = notesList()
        local items = {}
        for i = 1, math.min(3, #notes) do
            items[#items + 1] = { text = notes[i].name, inert = true }
        end
        if #items == 0 then
            items = { { text = _("Brak notatek."), inert = true } }
        end
        self:showList("NOTATKI", items, nil)

    elseif screen == "articles" then
        local articles = articlesList()
        local preview = articlesPreview(articles)
        local items = {}
        for _i, a in ipairs(preview) do
            items[#items + 1] = { text = a.title, mandatory = a.status, inert = true }
        end
        if #items == 0 then
            items = { { text = _("Brak artykułów."), inert = true } }
        end
        local title = #articles > 0 and string.format("ARTYKUŁY   %d", #articles) or "ARTYKUŁY"
        self:showList(title, items, nil)

    elseif screen == "crafts" then
        local items = {}
        for _i, it in ipairs(d.crafts or {}) do
            items[#items + 1] = { text = it.sym .. "  " .. it.text, mandatory = it.meta or "", craft = it }
        end
        if #items == 0 then
            items = { { text = _("Nic nie wysłane. Wyślij wzór z Craftsss w przeglądarce."), inert = true } }
        end
        self:showList("ROBÓTKI", items, function(item, menu)
            if not item.craft then return end
            UIManager:close(menu)
            self:openPattern(item.craft.id)
        end)

    elseif screen == "learn" then
        self:showCard(dashboard)

    elseif screen == "dig" then
        self:showDig(dashboard)
    end
end

-- ------------------------------------------------------------------- learn
--
-- One screen for a whole session. The queue arrives with the dashboard, so
-- grading a card never waits for the radio — the POST is fired and forgotten
-- while the next card is already on screen.

local LearnView = InputContainer:extend {
    plugin = nil,
    dashboard = nil,
    learn = nil,     -- the summary block from the payload
    queue = nil,     -- { {id, front, back} }
    cursor = 1,
    shown = false,   -- is the answer revealed
    graded = 0,      -- cards graded in this sitting
    again = nil,     -- cards answered "nie umiem", replayed at the end
    opened_at = nil,
}

function LearnView:init()
    self.opened_at = os.time()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.readingos_screen = "learn" -- Phone Companion V2: identifies this widget to executeRemoteCommand
    self.hit = {}
    self.again = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            SwipeBack = { GestureRange:new { ges = "swipe", range = self.dimen } },
        }
    end
    self[1] = self:build()
end

function LearnView:claim(y, height, target)
    target.y1, target.y2 = y, y + height
    self.hit[#self.hit + 1] = target
    return y + height
end

function LearnView:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(18)
    local cw = W - 2 * pad
    local rows, y = {}, pad
    -- Like the craft screen and unlike the dashboard, this is read at a glance
    -- from a distance, so the density setting does not shrink it.
    local h_meta = Screen:scaleBySize(SIZE_META * 1.7)
    local h_row = Screen:scaleBySize(SIZE_ROW * 1.8)
    local h_big = Screen:scaleBySize(SIZE_TITLE * 2.2)

    local function add(w, h, target)
        rows[#rows + 1] = w
        local ok, size = pcall(function() return w:getSize() end)
        local real = (ok and size and size.h and size.h > 0) and size.h or h
        if target then y = self:claim(y, real, target) else y = y + real end
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        rows[#rows + 1] = VerticalSpan:new { width = h }
        y = y + h
    end
    local function button(label, height, target, filled)
        local bh = height + Screen:scaleBySize(20)
        add(FrameContainer:new {
            bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(10),
            width = cw, radius = 0,
            background = filled and Blitbuffer.COLOR_BLACK or nil,
            CenterContainer:new { dimen = { w = cw - Screen:scaleBySize(22), h = height },
                TextWidget:new { text = label, face = faceFull(SIZE_ROW),
                    fgcolor = filled and Blitbuffer.COLOR_WHITE or nil } },
        }, bh, target)
    end

    local card = self.queue[self.cursor]
    local left = #self.queue - self.cursor + 1 + #self.again

    -- header: where you are, and everything the start screen would have said
    add(lrRow(cw, h_meta, "‹  NAUKA",
        card and string.format("%d / %d", self.cursor, #self.queue) or "koniec",
        faceFull(SIZE_META), faceFull(SIZE_META), true), h_meta, { kind = "back" })
    local l = self.learn or {}
    add(LeftContainer:new { dimen = { w = cw, h = h_meta },
        TextWidget:new {
            text = string.format("%d na dziś · %d min · seria %d dni",
                l.due or 0, l.minutes or 1, l.streak or 0),
            face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = cw,
        } }, h_meta)
    add(rule(cw), Screen:scaleBySize(2))

    if not card then
        -- end of the sitting: what was done, and one way onward each
        gap(40)
        add(CenterContainer:new { dimen = { w = cw, h = h_big },
            TextWidget:new { text = _("Koniec na dziś"), face = faceFull(SIZE_TITLE), max_width = cw } }, h_big)
        gap(10)
        add(CenterContainer:new { dimen = { w = cw, h = h_meta },
            TextWidget:new {
                text = string.format(_("powtórzone: %d"), self.graded),
                face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } }, h_meta)
        gap(30)
        if (l.due or 0) > #self.queue then
            button(_("NASTĘPNE ") .. tostring((l.due or 0) - #self.queue), h_row, { kind = "more" })
            gap(10)
        end
        button(_("WRÓĆ"), h_row, { kind = "back" })
    else
        -- the card itself: front always, back only once asked for
        gap(60)
        add(CenterContainer:new { dimen = { w = cw, h = h_big },
            TextWidget:new { text = card.front, face = faceFull(SIZE_TITLE), max_width = cw } },
            h_big, { kind = "reveal" }) -- the word itself flips it, not only the button
        gap(20)

        if self.shown then
            add(rule(cw, true), Screen:scaleBySize(1))
            gap(20)
            add(CenterContainer:new { dimen = { w = cw, h = h_big },
                TextWidget:new { text = card.back or "", face = faceFull(SIZE_TITLE), max_width = cw } }, h_big)
            gap(40)
            button(_("UMIEM"), h_row, { kind = "grade", grade = "good" }, true)
            gap(10)
            button(_("PRAWIE UMIEM"), h_row, { kind = "grade", grade = "hard" })
            gap(10)
            button(_("NIE UMIEM"), h_row, { kind = "grade", grade = "again" })
        else
            gap(60)
            button(_("POKAŻ ODPOWIEDŹ"), h_row, { kind = "reveal" })
            gap(20)
            add(CenterContainer:new { dimen = { w = cw, h = h_meta },
                TextWidget:new {
                    text = string.format(_("zostało %d · zrobione %d"), left, self.graded),
                    face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } }, h_meta)
        end
    end

    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = pad,
        width = W, height = H,
        VerticalGroup:new { align = "left", unpack(rows) },
    }
end

function LearnView:targetAt(y)
    for _i, t in ipairs(self.hit) do
        if y >= t.y1 and y < t.y2 then return t end
    end
    return nil
end

function LearnView:redraw()
    self.hit = {}
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

function LearnView:onTap(_arg, ges)
    local t = self:targetAt(ges.pos.y)
    if not t then return true end

    if t.kind == "back" then
        return self:onClose()

    elseif t.kind == "reveal" then
        if not self.shown then
            self.shown = true
            self:redraw()
        end
        return true

    elseif t.kind == "grade" then
        local card = self.queue[self.cursor]
        if not card then return true end
        track("learn", "grade", t.grade)
        -- "Nie umiem" comes back before the sitting ends: the server will also
        -- schedule it for today, but that only helps on the next fetch.
        if t.grade == "again" then self.again[#self.again + 1] = card end
        self.graded = self.graded + 1
        self.cursor = self.cursor + 1
        if self.cursor > #self.queue and #self.again > 0 then
            self.queue = self.again
            self.again = {}
            self.cursor = 1
        end
        self.shown = false
        self:redraw() -- optimistic: the answer is already known, the POST can lag
        self.plugin:act("card", card.id, { grade = t.grade, label = card.front })
        return true

    elseif t.kind == "more" then
        -- a fresh fetch brings the next queue of 20
        self.plugin:refreshInto(self.dashboard)
        return self:onClose()
    end
    return true
end

function LearnView:onSwipeBack(_arg, ges)
    if ges.direction == "east" then return self:onClose() end
    return true
end

function LearnView:onClose()
    track("learn", "close", nil, (os.time() - (self.opened_at or os.time())) * 1000)
    UIManager:close(self)
    if self.graded > 0 then self.plugin:refreshInto(self.dashboard) end
    return true
end

function LearnView:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

--- Open the session. A tap on NAUKA lands on the first card, not on a start
--- screen: every screen between the intent and the first card is a place to
--- decide not to bother. The numbers that would have filled a start screen ride
--- along in the session's own header instead.
function ReadingOS:showCard(dashboard)
    local learn = (dashboard.data or {}).learn or {}
    local queue = type(learn.queue) == "table" and learn.queue or {}
    -- A JSON null decodes to a truthy sentinel here, not nil, so `not card` was
    -- false when no card was due and the next line crashed the whole reader.
    -- The server no longer sends null; this guard means it cannot recur.
    if #queue == 0 or type(queue[1]) ~= "table" or type(queue[1].front) ~= "string" then
        track("learn", "open", "none due")
        UIManager:show(InfoMessage:new { text = _("Nie ma fiszek na dziś. Następne jutro.") })
        return
    end
    track("learn", "open")
    UIManager:show(LearnView:new { plugin = self, dashboard = dashboard, learn = learn, queue = queue })
end

function ReadingOS:showDig(dashboard)
    local dig = (dashboard.data or {}).dig or {}
    local lines = {
        tostring(dig.stratum or "I · TOPSOIL"),
        string.format("głębokość    %.1f m", dig.depth or 0),
        string.format("dziś         +%.1f m  (%d XP)", dig.today_depth or 0, dig.today_xp or 0),
        "",
        string.format("światło      %.1f m", dig.lamplight or 0),
        string.format("zapasy       %d dni", dig.supplies or 0),
        string.format("narzędzia    %d", dig.tools or 0),
        string.format("plotki       %d", dig.rumors or 0),
        string.format("wiedza       %d", dig.knowledge or 0),
        "",
        string.format("kolekcja     %d / %d", dig.collected or 0, dig.collection_total or 42),
    }
    if dig.next then
        if dig.next.revealed and dig.next.name then
            lines[#lines + 1] = string.format("następne     %s na %.1f m", dig.next.name, dig.next.depth)
        else
            lines[#lines + 1] = string.format("następne     %.1f m", dig.next.depth)
        end
    else
        lines[#lines + 1] = "skała macierzysta. niżej nic nie ma."
    end
    if dig.stall then
        lines[#lines + 1] = ""
        lines[#lines + 1] = dig.stall
    end

    local items = {}
    for _i, l in ipairs(lines) do items[#items + 1] = { text = l, inert = true } end
    items[#items + 1] = { text = "", inert = true }
    items[#items + 1] = { text = _("KOLEKCJA  >"), collection = true }
    items[#items + 1] = { text = _("CO TO WŁAŚCIWIE JEST?  >"), help = true }

    self:showList("DIG", items, function(item, menu)
        if item.collection then
            self:showCollection()
        elseif item.help then
            UIManager:close(menu)
            self:showHelp()
        end
    end)
end

-- ------------------------------------------------------------------ crafts
--
-- Working a pattern with both hands busy. Everything here follows from that:
-- one enormous button instead of a list to aim at, the current row in a frame
-- so the eye finds it without reading, and the screen kept awake because
-- stopping mid-round to wake a Kindle is how you lose your place.

local CraftView = InputContainer:extend {
    plugin = nil,
    send_id = nil,   -- which send this is, so its cache can be refreshed on a tick
    stale = nil,     -- hours old when the rows came from disk instead of the server
    pattern = nil,   -- { id, title, size, rows = { {id, key, n, label, section, text, count, kind, flags, done, repeat} } }
    cursor = 1,      -- 1-based index of the row being worked
    awake_until = nil,
    awake_task = nil,
    opened_at = nil,
}

function CraftView:init()
    self.opened_at = os.time()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.readingos_screen = "craft" -- Phone Companion V2: identifies this widget to executeRemoteCommand
    self.hit = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            SwipeBack = { GestureRange:new { ges = "swipe", range = self.dimen } },
        }
    end
    -- Resume where the work actually stopped, not at row 1.
    self.cursor = 1
    for i, r in ipairs(self.pattern.rows or {}) do
        if not r.done then self.cursor = i break end
        self.cursor = math.min(i + 1, #self.pattern.rows)
    end
    self[1] = self:build()
end

function CraftView:claim(y, height, target)
    target.y1, target.y2 = y, y + height
    self.hit[#self.hit + 1] = target
    return y + height
end

-- Polish plural for stitches: 1 oczko, 2–4 oczka, the rest oczek (12–14 too).
local function oczka(n)
    local t, u = n % 100, n % 10
    if n == 1 then return "1 oczko" end
    if u >= 2 and u <= 4 and not (t >= 12 and t <= 14) then return n .. " oczka" end
    return n .. " oczek"
end

local function rowFlag(r, name)
    for _i, f in ipairs(r.flags or {}) do if f == name then return true end end
    return false
end

--- One context line: "Round 12  Ch-1, turn, sc…" — label, then the start of
--- the instruction. Context is allowed to truncate; the current row never is.
local function contextText(r)
    local head, body = r.label or "", r.text or ""
    if head ~= "" and body ~= "" then return head .. "  " .. body end
    return head ~= "" and head or body
end

function CraftView:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(18)
    local cw = W - 2 * pad
    local rows, y = {}, pad
    -- Deliberately NOT scaled by FONT_SCALE. The dashboard is scanned up close;
    -- this screen is read at arm's length with a hook in both hands, so it
    -- stays large no matter how dense the dashboard is set.
    local h_meta = Screen:scaleBySize(SIZE_META * 1.7)
    local h_row = Screen:scaleBySize(SIZE_ROW * 1.8)
    local h_big = Screen:scaleBySize(SIZE_TITLE * 1.5)
    local TextBoxWidget = require("ui/widget/textboxwidget")

    -- Every hit region is claimed from the widget's MEASURED height, never
    -- from the height it was asked for: a wrapped instruction is taller than
    -- any guess, and guessed heights drift the tap targets below it.
    local function add(w, target)
        rows[#rows + 1] = w
        local h = w:getSize().h
        if target then y = self:claim(y, h, target) else y = y + h end
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        rows[#rows + 1] = VerticalSpan:new { width = h }
        y = y + h
    end

    local list = self.pattern.rows or {}
    local total = #list
    local doneCount = 0
    for _i, r in ipairs(list) do if r.done then doneCount = doneCount + 1 end end
    local cur = list[self.cursor]

    -- header: what this is, and the count that answers "how much is left"
    local head = "‹  " .. self.pattern.title
    if self.pattern.size then head = head .. " · " .. tostring(self.pattern.size) end
    -- Rows from disk, not from the server: say so once, in the header, where
    -- the dashboard already says it. Nothing else changes — an offline
    -- pattern is fully usable, and the ticks are journalled.
    if self.stale then head = head .. " · offline" end
    add(lrRow(cw, h_meta, head,
        string.format("%d / %d", math.min(self.cursor, total), total),
        faceFull(SIZE_META), faceFull(SIZE_META), true), { kind = "back" })
    add(ProgressWidget:new {
        width = cw, height = Screen:scaleBySize(7),
        percentage = total > 0 and (doneCount / total) or 0,
        margin_h = 0, margin_v = 0, bordersize = Screen:scaleBySize(1),
    })
    gap(6)

    -- where am I: the section and my place inside it
    if cur and cur.section then
        local i_in, n_in = 0, 0
        for i, r in ipairs(list) do
            if r.section == cur.section then
                n_in = n_in + 1
                if i <= self.cursor then i_in = i_in + 1 end
            end
        end
        add(lrRow(cw, h_meta, string.upper(tostring(cur.section)), string.format("%d / %d", i_in, n_in),
            faceFull(SIZE_META), faceFull(SIZE_META), true))
        add(rule(cw))
    end
    gap(6)

    -- The current row is the only thing on the screen meant to be read from a
    -- distance while your hands are working. It is built first so that the
    -- context around it can yield to it, never the other way round.
    local iw = cw - Screen:scaleBySize(26)
    local function currentBox(face, maxh)
        if not cur then
            return CenterContainer:new { dimen = { w = cw, h = h_big },
                TextWidget:new { text = "gotowe — cały wzór zrobiony", face = faceFull(SIZE_ROW) } }
        end
        local inner = {}
        local title = cur.label or string.format("krok %d", cur.n or self.cursor)
        if cur.kind == "note" then title = title .. " · notatka" end
        if cur.repeat_of then
            title = title .. string.format(" · powtórzenie %d z %d", cur.repeat_i, cur.repeat_of)
        end
        inner[#inner + 1] = LeftContainer:new { dimen = { w = iw, h = h_meta },
            TextWidget:new { text = title, face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = iw } }
        inner[#inner + 1] = VerticalSpan:new { width = Screen:scaleBySize(6) }
        -- Long instructions wrap instead of being cut: a truncated round is a
        -- ruined round. `maxh` is only ever set as a last resort (see below).
        inner[#inner + 1] = TextBoxWidget:new {
            text = cur.text or "", face = face, width = iw, alignment = "left",
            height = maxh, height_overflow_show_ellipsis = maxh ~= nil,
        }
        if cur.count then
            inner[#inner + 1] = VerticalSpan:new { width = Screen:scaleBySize(8) }
            inner[#inner + 1] = RightContainer:new { dimen = { w = iw, h = h_meta },
                TextWidget:new { text = "→ " .. oczka(cur.count), face = faceFull(SIZE_ROW) } }
        end
        if rowFlag(cur, "size_unresolved") then
            inner[#inner + 1] = VerticalSpan:new { width = Screen:scaleBySize(8) }
            inner[#inner + 1] = LeftContainer:new { dimen = { w = iw, h = h_meta },
                TextWidget:new { text = "UWAGA: rozmiar nierozstrzygnięty — popraw w Craftsss",
                    face = faceFull(SIZE_META), max_width = iw } }
        end
        return FrameContainer:new {
            bordersize = Screen:scaleBySize(2), padding = Screen:scaleBySize(11),
            width = cw, radius = 0,
            VerticalGroup:new { align = "left", unpack(inner) },
        }
    end

    -- Budget: what the fixed chrome below the box will take, so the buttons
    -- always land on screen. Then shrink the context before the instruction,
    -- and the instruction's face before its text.
    local h_buttons = h_row + Screen:scaleBySize(22)
    local reserved = Screen:scaleBySize(10) + h_buttons + Screen:scaleBySize(8)
        + Screen:scaleBySize(2) + h_meta + pad
    local avail = H - y - reserved

    local box = currentBox(faceFull(SIZE_TITLE))
    local n_behind = math.min(2, self.cursor - 1)
    local n_ahead = math.min(3, total - self.cursor)
    local function fits()
        return box:getSize().h + (n_behind + n_ahead) * h_row + Screen:scaleBySize(18) <= avail
    end
    while not fits() and (n_behind + n_ahead) > 0 do
        -- Ahead goes first; the row just finished stays longest, because "did
        -- my tap register?" is answered by seeing it marked OK.
        if n_ahead >= n_behind and n_ahead > 0 then n_ahead = n_ahead - 1 else n_behind = n_behind - 1 end
    end
    if not fits() then box = currentBox(faceFull(SIZE_ROW)) end
    if not fits() then
        -- A single row longer than the screen. Clip with an ellipsis rather
        -- than push ZROBIONE off the panel — and flag it for craftsss (P2).
        box = currentBox(faceFull(SIZE_ROW), math.max(h_row, avail - 4 * h_meta - Screen:scaleBySize(60)))
    end

    -- behind: enough to know where you are, greyed, tappable to jump back
    for i = self.cursor - n_behind, self.cursor - 1 do
        local r = list[i]
        if r then
            add(lrRow(cw, h_row, "  " .. contextText(r), r.done and "OK" or "",
                faceFull(SIZE_META), faceFull(SIZE_META), true), { kind = "goto", index = i })
        end
    end

    add(box)

    -- ahead: what is coming, inert
    gap(8)
    for i = self.cursor + 1, self.cursor + n_ahead do
        local r = list[i]
        if r then
            add(LeftContainer:new { dimen = { w = cw, h = h_row },
                TextWidget:new { text = "  " .. contextText(r), face = faceFull(SIZE_META),
                    fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = cw } })
        end
    end

    -- Anchor the buttons to the bottom: a layout that floats reads as
    -- unresolved, and a thumb learns one place for ZROBIONE.
    local slack = H - y - reserved
    if slack > 0 then
        rows[#rows + 1] = VerticalSpan:new { width = slack }
        y = y + slack
    end
    gap(10)
    local bw = math.floor((cw - Screen:scaleBySize(10)) / 2)
    local buttons = OverlapGroup:new { dimen = { w = cw, h = h_buttons } }
    table.insert(buttons, LeftContainer:new { dimen = { w = cw, h = h_buttons },
        FrameContainer:new { bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(10),
            width = bw, radius = 0, background = Blitbuffer.COLOR_BLACK,
            CenterContainer:new { dimen = { w = bw - Screen:scaleBySize(22), h = h_row },
                TextWidget:new { text = "ZROBIONE", face = faceFull(SIZE_ROW), fgcolor = Blitbuffer.COLOR_WHITE } } } })
    -- COFNIJ dims when there is nothing to undo; it never disappears, so the
    -- layout holds still and the thumb keeps its map of the screen.
    table.insert(buttons, RightContainer:new { dimen = { w = cw, h = h_buttons },
        FrameContainer:new { bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(10),
            width = bw, radius = 0,
            CenterContainer:new { dimen = { w = bw - Screen:scaleBySize(22), h = h_row },
                TextWidget:new { text = "COFNIJ", face = faceFull(SIZE_ROW),
                    fgcolor = self.cursor > 1 and nil or Blitbuffer.COLOR_GRAY_5 } } } })
    -- One tap target per half, split down the middle.
    local by = y
    add(buttons)
    self.hit[#self.hit + 1] = { y1 = by, y2 = y, x2 = pad + bw, kind = "done" }
    self.hit[#self.hit + 1] = { y1 = by, y2 = y, x1 = pad + bw, kind = "undo_row" }

    -- how long the screen will stay awake, so it is never a mystery
    gap(8)
    add(rule(cw))
    local awake = "ekran gaśnie normalnie · dotknij, by zmienić"
    if self.awake_until then
        local left = math.max(0, math.floor((self.awake_until - os.time()) / 60))
        awake = string.format("ekran nie gaśnie · %d min", left)
    end
    add(CenterContainer:new { dimen = { w = cw, h = h_meta },
        TextWidget:new { text = awake, face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } },
        { kind = "awake" })

    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = pad,
        width = W, height = H,
        VerticalGroup:new { align = "left", unpack(rows) },
    }
end

function CraftView:targetAt(x, y)
    for _i, t in ipairs(self.hit) do
        if y >= t.y1 and y < t.y2
            and (not t.x1 or x >= t.x1)
            and (not t.x2 or x < t.x2) then
            return t
        end
    end
    return nil
end

function CraftView:redraw()
    self.hit = {}
    -- Same rule as the dashboard's refreshInto: release the tree being
    -- replaced before dropping it. This one redraws on every tick — 54 times
    -- in a Jewelry Saver session — and each tree holds a TextBoxWidget, whose
    -- free() releases C-allocated XText and blitbuffers and cancels any
    -- scheduled image update. Reference nil'd first so nothing can be freed
    -- twice, pcall'd so a stubborn widget costs a log line, not the redraw.
    local stale_root = self[1]
    self[1] = nil
    if stale_root and stale_root.free then
        local ok_free, err = pcall(function() stale_root:free() end)
        if not ok_free then logger.warn("ReadingOS: craft view free failed:", err) end
    end
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

--- Send a tick, and never lose it. The screen has already moved on (the
--- hands are busy; an e-ink round trip before the redraw would be felt), so
--- this runs after the redraw and its only job is that the intention
--- survives: the server takes it now, or the journal holds it until the next
--- call succeeds. The local cache is updated either way, so reopening
--- offline resumes where the work actually stopped rather than where the
--- server last heard about.
function CraftView:commit(row, done)
    local res = self.plugin:act("craft_row", row.id, { done = done })
    if not (res and res.ok ~= false) then
        craftJournalAdd(row.id, done)
    end
    if self.send_id then craftCacheSave(self.send_id, self.pattern) end
end

function CraftView:onTap(_arg, ges)
    local t = self:targetAt(ges.pos.x, ges.pos.y)
    if not t then return true end

    if t.kind == "back" then
        return self:onClose()

    elseif t.kind == "awake" then
        return self:askAwake()

    elseif t.kind == "goto" then
        self.cursor = t.index
        self:redraw()
        return true

    elseif t.kind == "done" then
        local row = self.pattern.rows[self.cursor]
        if not row then return true end
        track("craft", "row_done", tostring(row.n))
        row.done = true
        self.cursor = math.min(self.cursor + 1, #self.pattern.rows + 1)
        self:redraw() -- optimistic: the hands are busy, the network can catch up
        self:commit(row, true)
        return true

    elseif t.kind == "undo_row" then
        local i = math.max(1, self.cursor - 1)
        local row = self.pattern.rows[i]
        if not row then return true end
        track("craft", "row_undo", tostring(row.n))
        row.done = false
        self.cursor = i
        self:redraw()
        self:commit(row, false)
        return true
    end
    return true
end

function CraftView:onSwipeBack(_arg, ges)
    if ges.direction == "east" then self:onClose() end
    return true
end

--- Keep the screen on for a bounded time. Bounded because a pattern left open
--- overnight would otherwise drain the battery to nothing by morning.
function CraftView:askAwake()
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    local function pick(minutes)
        return function()
            UIManager:close(dialog)
            self:setAwake(minutes)
        end
    end
    dialog = ButtonDialogTitle:new {
        title = _("Nie gaś ekranu przez:"),
        title_align = "center",
        buttons = {
            { { text = "30 min", callback = pick(30) }, { text = "1 h", callback = pick(60) } },
            { { text = "2 h", callback = pick(120) }, { text = _("wyłącz"), callback = pick(0) } },
        },
    }
    UIManager:show(dialog)
    return true
end

function CraftView:setAwake(minutes)
    self:releaseAwake()
    if minutes and minutes > 0 then
        self.awake_until = os.time() + minutes * 60
        UIManager:preventStandby()
        self.awake_task = function()
            if not self.awake_until then return end
            if os.time() >= self.awake_until then
                self:releaseAwake()
                self:redraw()
            else
                UIManager:scheduleIn(60, self.awake_task)
                self:redraw() -- the countdown on screen has to move
            end
        end
        UIManager:scheduleIn(60, self.awake_task)
        track("craft", "awake", tostring(minutes))
    end
    self:redraw()
end

function CraftView:releaseAwake()
    if self.awake_task then
        UIManager:unschedule(self.awake_task)
        self.awake_task = nil
    end
    if self.awake_until then
        self.awake_until = nil
        UIManager:allowStandby()
    end
end

function CraftView:onClose()
    -- Releasing the wake lock on every exit path is the whole reason this is a
    -- method: a forgotten lock is a flat battery.
    self:releaseAwake()
    track("craft", "close", self.pattern.title, (os.time() - (self.opened_at or os.time())) * 1000)
    UIManager:close(self)
    return true
end

function CraftView:onCloseWidget()
    self:releaseAwake()
    UIManager:setDirty(nil, "full")
end

--- Open a sent pattern. Fresh from the server when it answers, otherwise the
--- last copy of that same pattern from disk — the radio is off most of the
--- time while you crochet, and a pattern you already received is not a good
--- reason to refuse to show it. Any ticks the network ate earlier go out
--- first, so the server's `done` flags (which decide where you resume) are
--- current before they are read back.
function ReadingOS:openPattern(id)
    pcall(function() self:flushCraftTicks() end)
    local data = decode(request("GET", baseUrl() .. "/api/readingos/crafts/" .. tostring(id)))
    local from_cache, cache_age = false, nil
    if not craftPayloadOk(data) then
        data, cache_age = craftCacheLoad(id)
        from_cache = data ~= nil
    end
    if not craftPayloadOk(data) then
        UIManager:show(InfoMessage:new { text = _("Nie udało się pobrać wzoru.") })
        return
    end
    -- Anything the flush above could not deliver is still true here: the row
    -- was crocheted, the server just has not heard yet. Lay those intentions
    -- over whatever arrived, so a half-failed flush can never drag the
    -- resume point back over work already done.
    local pending = craftJournal()
    if #pending > 0 then
        local by_id = {}
        for _i, t in ipairs(pending) do by_id[t.id] = t.done end
        for _i, r in ipairs(data.rows) do
            if by_id[r.id] ~= nil then r.done = by_id[r.id] end
        end
    end
    if not from_cache then craftCacheSave(id, data) end
    -- Flatten the repeat marker: nested tables in a hot redraw path are a
    -- needless indirection on a 1 GHz CPU.
    for _i, r in ipairs(data.rows) do
        if type(r.repeat_) == "table" then r.repeat_i, r.repeat_of = r.repeat_.i, r.repeat_.of end
        if type(r["repeat"]) == "table" then r.repeat_i, r.repeat_of = r["repeat"].i, r["repeat"].of end
        -- A row is never blank on screen: an older server sends title-only
        -- rows, and the label is then the only thing there is to show.
        if (r.text == nil or r.text == "") then r.text = r.label or "" end
    end
    track("craft", "open", from_cache and "cached" or data.title)
    UIManager:show(CraftView:new {
        plugin = self, pattern = data, send_id = id,
        stale = from_cache and math.floor((cache_age or 0) / 3600) or nil,
    }, "full")
end

--- The manual. Generated server-side from the same constants the game runs on,
--- so it cannot drift out of date the way a hand-written help file would.
function ReadingOS:showHelp()
    track("help", "open")
    local data = decode(request("GET", baseUrl() .. "/api/readingos/help"))
    if type(data) ~= "table" or type(data.sections) ~= "table" then
        UIManager:show(InfoMessage:new { text = _("Offline — instrukcja jest na serwerze.") })
        return
    end
    -- Every line here is `inert`, never `dim`: this screen is prose to be read,
    -- and grey 34-point text on e-ink under a reading light is not.
    local items = {}
    for _i, sec in ipairs(data.sections) do
        if #items > 0 then items[#items + 1] = { text = "", inert = true } end
        items[#items + 1] = { text = tostring(sec.title), bold = true, inert = true }
        items[#items + 1] = { text = string.rep("-", 34), inert = true }
        for _j, line in ipairs(sec.lines or {}) do
            items[#items + 1] = { text = tostring(line), inert = true }
        end
    end
    self:showList("JAK TO DZIAŁA", items, nil)
end

function ReadingOS:showCollection()
    local data = decode(request("GET", baseUrl() .. "/api/readingos/collection"))
    if not data then
        UIManager:show(InfoMessage:new { text = _("Offline — kolekcja jest na serwerze.") })
        return
    end
    local cost = data.identify_cost or 2
    local items = {}
    for _i, s in ipairs(data.strata or {}) do
        if s.unlocked then
            items[#items + 1] = {
                text = string.format("%s · %s      %d/%d", s.n, s.name, s.foundCount, s.total),
                bold = true, inert = true,
            }
            for _j, slot in ipairs(s.slots or {}) do
                local text, actionable
                if not slot.found then
                    text = string.format("   ?                    %.1f m", slot.depth)
                    actionable = false
                elseif slot.identified then
                    text = "   " .. tostring(slot.name)
                    actionable = false
                else
                    text = string.format("   [?] nierozpoznane      %d wiedzy", cost)
                    actionable = true
                end
                items[#items + 1] = { text = text, slot = slot, inert = not actionable }
            end
        else
            items[#items + 1] = { text = string.format("%s · --------        zamknięta", s.n), inert = true }
        end
    end
    self:showList("KOLEKCJA", items, function(item, menu)
        if not (item.slot and item.slot.found and not item.slot.identified) then return end
        track("collection", "identify", item.slot.key)
        local res = self:act("identify", item.slot.key)
        if res and res.ok then
            UIManager:close(menu)
            self:showCollection()
        else
            UIManager:show(InfoMessage:new { text = _("Za mało wiedzy. Powtórz kilka fiszek.") })
        end
    end)
end

-- ------------------------------------------------------------- self-update
--
-- Updating over Wi-Fi instead of over a USB cable. The plugin overwrites its
-- own source, so the whole design is about never leaving a half-written file
-- behind: a truncated main.lua would stop KOReader loading the plugin at all,
-- and the only way back would be the very cable this feature exists to avoid.
--
-- Hence the order: download everything, prove every file both arrived whole
-- and COMPILES, and only then move any of them into place. If anything fails,
-- the staged files are dropped and nothing has changed.

--- Compare "0.6" against "0.10" numerically. As strings, "0.10" sorts first.
local function versionNewer(remote, local_v)
    local function parts(v)
        local out = {}
        for n in tostring(v or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local a, b = parts(remote), parts(local_v)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
ReadingOS._versionNewer = versionNewer -- exercised by test_version.lua

function ReadingOS:localVersion()
    local f = io.open((self.path or "") .. "/VERSION", "r")
    if not f then return "0.0" end
    local v = f:read("*line") or "0.0"
    f:close()
    return (v:gsub("%s+", ""))
end

--- @return table|nil manifest {version, files}, string|nil err
function ReadingOS:updateManifest()
    local data = decode(request("GET", baseUrl() .. "/api/readingos/plugin/manifest"))
    if type(data) ~= "table" or type(data.files) ~= "table" or not data.version then
        return nil, "no manifest"
    end
    return data
end

function ReadingOS:performUpdate(manifest)
    local dir = self.path
    if not dir or dir == "" then return false, "plugin path unknown" end

    -- Phase 1: fetch and validate everything. Nothing is installed yet.
    local staged = {}
    for _i, f in ipairs(manifest.files) do
        local body = request("GET", baseUrl() .. "/api/readingos/plugin/file/" .. f.name)
        if not body then return false, "download failed: " .. f.name end
        if f.size and #body ~= f.size then
            return false, string.format("%s truncated (%d of %d bytes)", f.name, #body, f.size)
        end
        -- The real check. A Lua file that does not compile would break the
        -- plugin on next start, and a size match alone cannot catch that.
        if f.name:match("%.lua$") then
            local loader = loadstring or load
            local chunk, err = loader(body)
            if not chunk then
                return false, "would not compile: " .. f.name .. " (" .. tostring(err) .. ")"
            end
        end
        staged[#staged + 1] = { name = f.name, body = body }
    end
    if #staged == 0 then return false, "manifest listed no files" end

    -- Phase 2: write the staged copies. Still nothing live has changed.
    for _i, s in ipairs(staged) do
        local fh = io.open(dir .. "/" .. s.name .. ".new", "w")
        if not fh then return false, "cannot write in " .. dir end
        fh:write(s.body)
        fh:close()
    end

    -- Phase 3: swap. Keeping a .bak of each file is what makes a bad release
    -- recoverable from the device itself rather than from a cable.
    for _i, s in ipairs(staged) do
        os.remove(dir .. "/" .. s.name .. ".bak")
        os.rename(dir .. "/" .. s.name, dir .. "/" .. s.name .. ".bak")
        local ok = os.rename(dir .. "/" .. s.name .. ".new", dir .. "/" .. s.name)
        if not ok then
            os.rename(dir .. "/" .. s.name .. ".bak", dir .. "/" .. s.name) -- put it back
            return false, "install failed: " .. s.name
        end
    end
    return true, manifest.version
end

--- @param silent true when called on dashboard open — say nothing when there
--- is nothing to say, because an unasked-for popup on e-ink is an interruption.
function ReadingOS:checkForUpdate(silent)
    local manifest, err = self:updateManifest()
    if not manifest then
        if not silent then
            UIManager:show(InfoMessage:new { text = _("Sprawdzanie aktualizacji nie powiodło się: ") .. tostring(err or "?") })
        end
        return
    end

    local here = self:localVersion()
    if not versionNewer(manifest.version, here) then
        if not silent then
            UIManager:show(InfoMessage:new { text = string.format(_("Wszystko aktualne (v%s)."), here) })
        end
        return
    end

    track("update", "offered", manifest.version)
    UIManager:show(ConfirmBox:new {
        text = string.format(_("Jest ReadingOS v%s.\nMasz v%s.\n\nZainstalować teraz?"),
            manifest.version, here),
        ok_text = _("Zainstaluj"),
        cancel_text = _("Później"),
        ok_callback = function()
            local ok, result = self:performUpdate(manifest)
            if not ok then
                track("update", "failed", tostring(result))
                UIManager:show(InfoMessage:new {
                    text = _("Aktualizacja nie powiodła się, nic nie zmieniono:\n") .. tostring(result),
                })
                return
            end
            track("update", "installed", tostring(result))
            -- The new code is on disk but the old one is still in memory, so a
            -- restart is not cosmetic — it is when the update takes effect.
            local restarted = pcall(function() UIManager:askForRestart() end)
            if not restarted then
                UIManager:show(InfoMessage:new {
                    text = string.format(_("Zainstalowano v%s. Zrestartuj KOReader, żeby zadziałało."), tostring(result)),
                })
            end
        end,
    })
end

-- ------------------------------------------------------------ screensaver
--
-- The sleep screen: what is on us today, grouped by category and then by who
-- owns it, with a horizontal rule between owners, plus a lab band (traffic
-- overhead and the next visible ISS passes).
--
-- Every line measures itself before it is placed. The old tasksss lockscreen
-- sized its rows from the font size it *asked for*, which is not the height the
-- face renders at, so its rows ran into each other on the device. Nothing here
-- may reintroduce a guessed height.

local SS_TYPE = "readingos"
local SS_CACHE_FILE = DataStorage:getDataDir() .. "/cache/readingos-screensaver.json"

-- One knob for the whole sleep screen, in KOReader font units (DPI scaling
-- happens inside ssFace). Far smaller than the dashboard: nothing here is a tap
-- target, so density costs nothing and buys a whole day on one page.
-- 7 put every right-hand column at floor(7 * 0.85) = 5 px, in GRAY_5, on a
-- panel being read from across the room — the meta column was the part that
-- could not be read at all. 9 costs a couple of rows on a busy day, and the
-- "drop a whole category, count it in the footer" rule already handles that.
local SS_FONT = 9

local function ssFace(mult)
    return Font:getFace("cfont", Screen:scaleBySize(math.max(1, math.floor(SS_FONT * (mult or 1)))))
end

local function ssText(text, f, gray, max_width)
    return TextWidget:new {
        text = text,
        face = f,
        fgcolor = gray and Blitbuffer.COLOR_GRAY_5 or nil,
        max_width = max_width,
    }
end

--- One line, left and right, sized to what the two widgets actually render as.
--- @return table widget, number height
local function ssLine(width, left, right, lface, rface, rgray)
    local gap = Screen:scaleBySize(8)
    local right_widget, rw = nil, 0
    if right and right ~= "" then
        right_widget = ssText(right, rface or lface, rgray, math.floor(width * 0.5))
        rw = right_widget:getSize().w
    end
    local left_widget = ssText(left, lface, false,
        math.max(Screen:scaleBySize(40), width - rw - gap))
    local h = left_widget:getSize().h
    if right_widget then h = math.max(h, right_widget:getSize().h) end

    local group = OverlapGroup:new { dimen = { w = width, h = h } }
    table.insert(group, LeftContainer:new { dimen = { w = width, h = h }, left_widget })
    if right_widget then
        table.insert(group, RightContainer:new { dimen = { w = width, h = h }, right_widget })
    end
    return group, h
end

--- @return table|nil data, boolean stale
function ReadingOS:ssFetch()
    local body = request("GET", baseUrl() .. "/api/readingos/screensaver")
    if body then
        local data = decode(body)
        if data then
            local encoded = encode({ timestamp = os.time(), data = data })
            if encoded then
                util.makePath(DataStorage:getDataDir() .. "/cache/")
                local f = io.open(SS_CACHE_FILE, "w")
                if f then f:write(encoded) f:close() end
            end
            return data, false
        end
    end
    -- Sleeping out of Wi-Fi range is the normal case, not an error: yesterday's
    -- duties with a stale marker beat a blank screen.
    local f = io.open(SS_CACHE_FILE, "r")
    if not f then return nil, false end
    local cached = decode(f:read("*all"))
    f:close()
    if not cached or not cached.data then return nil, false end
    if os.time() - (cached.timestamp or 0) > (tonumber(get("readingos_cache_max_age")) or 0) then
        return nil, false
    end
    return cached.data, true
end

--- Rows for the lab band, built first so the task list knows what space is left.
local function ssLabRows(cw, lab)
    local out = {}
    if type(lab) ~= "table" then return out end
    local f_cat, f_row, f_meta = ssFace(1), ssFace(1), ssFace(0.85)
    local planes = type(lab.planes) == "table" and lab.planes or {}
    local iss = type(lab.iss) == "table" and lab.iss or {}
    if #planes == 0 and #iss == 0 then return out end

    out[#out + 1] = { rule(cw), Screen:scaleBySize(2) }
    out[#out + 1] = { VerticalSpan:new { width = Screen:scaleBySize(5) }, Screen:scaleBySize(5) }
    local w, h = ssLine(cw, "LAB",
        (tonumber(lab.overhead) or #planes) .. " \u{2708}  60 NM", f_cat, f_meta, true)
    out[#out + 1] = { w, h }

    for _, p in ipairs(planes) do
        local left = string.format("  %s  %s", tostring(p.flight or "?"), tostring(p.route or ""))
        local right = string.format("%s  %s", tostring(p.dist or ""), tostring(p.alt or ""))
        local pw, ph = ssLine(cw, left, right, f_row, f_meta, true)
        out[#out + 1] = { pw, ph }
    end

    for _, s in ipairs(iss) do
        local left = string.format("  ISS  %s %s", tostring(s.day or ""), tostring(s.time or ""))
        local right = string.format("%s  %s  %s%s", tostring(s.dur or ""), tostring(s.el or ""),
            tostring(s.az or ""), (s.mag and s.mag ~= "") and ("  " .. s.mag) or "")
        local iw, ih = ssLine(cw, left, right, f_row, f_meta, true)
        out[#out + 1] = { iw, ih }
    end
    return out
end

--- Turn the screen sideways for the sleep/lock screen, remembering what it was.
---
--- The restore path is KOReader's own: ScreenSaverWidget:onCloseWidget puts
--- Device.orig_rotation_mode back on wake, so a redraw on an RTC wake (which
--- re-enters this while already sideways) must not overwrite it — hence the
--- "only when currently upright" test. LockView restores it by hand.
--- @return boolean rotated
local function ssEnterLandscape()
    if not get("readingos_ss_landscape") then return false end
    local ok, rotated = pcall(function()
        local mode = Screen:getRotationMode()
        if mode % 2 == 1 then return false end -- already in some landscape
        Device.orig_rotation_mode = mode
        Screen:setRotationMode(Screen.DEVICE_ROTATED_CLOCKWISE)
        return true
    end)
    return ok and rotated or false
end

local function ssRestoreRotation()
    if not Device.orig_rotation_mode then return end
    pcall(function() Screen:setRotationMode(Device.orig_rotation_mode) end)
    Device.orig_rotation_mode = nil
end

--- One category column: OBOWIĄZKI / PORZĄDKI / PRADA at the top, owner
--- sub-sections below it separated by a dashed rule. Leo picked design A's
--- boxes with design C's split, so the box is the page's own frame and the
--- vertical rules between columns — not a card floating per category.
--- @return table[] rows { widget, height }, number height
local function ssColumn(width, g, f)
    local out, h = {}, 0
    local function put(widget, height)
        out[#out + 1] = { widget, height }
        h = h + height
    end

    put(ssLine(width, tostring(g.cat or "?"), tostring(g.total or ""), f.cat, f.meta, true))
    put(rule(width), Screen:scaleBySize(2))
    put(VerticalSpan:new { width = Screen:scaleBySize(5) }, Screen:scaleBySize(5))

    for i, person in ipairs(g.people or {}) do
        -- A blank line between owners, not a dashed rule. The name is already a
        -- heading; the rule was a second separator drawn over the first one.
        if i > 1 then
            put(VerticalSpan:new { width = Screen:scaleBySize(9) }, Screen:scaleBySize(9))
        end
        -- No per-owner "(2)": the category total is in the column head, and a
        -- count of the rows printed directly underneath it is not information.
        put(ssLine(width, tostring(person.who or ""), "", f.who))
        for _, r in ipairs(person.rows or {}) do
            local left = string.format("  %s %s %s", tostring(r.sym or "\u{00B7}"),
                (r.time and r.time ~= "") and r.time or "     ", tostring(r.text or "?"))
            -- Meta in black: this column says "2 dni po terminie", which is the
            -- reason the row is on the screen at all.
            put(ssLine(width, left, tostring(r.meta or ""), f.row, f.meta, false))
        end
    end
    return out, h
end

--- @param lock_label string|nil replaces the footer's right-hand text when the
---   screen is being held open on purpose (see LockView).
function ReadingOS:ssWidget(d, stale, lock_label)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    local box = Screen:scaleBySize(2)      -- the page's own frame, design A
    local cw = W - 2 * (pad + box)
    local f_head, f_cat, f_who = ssFace(1.3), ssFace(1.1), ssFace(1)
    local f_row, f_meta = ssFace(1), ssFace(0.8)

    local rows, used = {}, 0
    local function add(widget, height)
        rows[#rows + 1] = widget
        used = used + height
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        add(VerticalSpan:new { width = h }, h)
    end

    -- ---- header. Clock and battery: the two things a sleeping device is asked.
    local clock = os.date("%H:%M")
    local batt = ""
    local ok_b, cap = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok_b and type(cap) == "number" then batt = string.format("\u{26A1} %d%%", cap) end
    add(ssLine(cw, plDate():upper() .. "   " .. clock, batt, f_head, f_meta, true))
    add(rule(cw), Screen:scaleBySize(2))
    gap(6)

    local totals = (d and d.totals) or {}
    local head = string.format("DZIŚ  %d %s", tonumber(totals.tasks) or 0,
        (tonumber(totals.tasks) or 0) == 1 and "zadanie" or "zadań")
    if (tonumber(totals.past) or 0) > 0 then
        head = head .. string.format(" \u{00B7} %d po terminie", totals.past)
    end
    add(ssLine(cw, head, stale and "z cache" or "", f_who, f_meta, true))
    gap(6)

    -- The lab band is measured up front and its height reserved, so a long task
    -- list pushes rows out of itself rather than pushing the lab off the screen.
    local lab_rows = get("readingos_ss_lab") and ssLabRows(cw, d and d.lab) or {}
    local lab_h = 0
    for _, r in ipairs(lab_rows) do lab_h = lab_h + r[2] end

    local footer_h = Screen:scaleBySize(24)
    local budget = H - 2 * (pad + box) - used - lab_h - footer_h
    local skipped = 0

    -- One column per category, side by side, the way both mockups read it. On a
    -- portrait screen there is no room for that, so the categories stack and the
    -- page is the old single column.
    local groups = (d and d.groups) or {}
    local ncols = W > H and math.max(1, math.min(3, #groups)) or 1
    local col_gap = Screen:scaleBySize(14)
    local sep_w = Screen:scaleBySize(1)
    local cat_gap = Screen:scaleBySize(10)
    local colw = math.floor((cw - (ncols - 1) * (2 * col_gap + sep_w)) / ncols)
    local cols, col_h = {}, {}
    for i = 1, ncols do cols[i] = {}; col_h[i] = 0 end
    local faces = { cat = f_cat, who = f_who, row = f_row, meta = f_meta }

    for gi, g in ipairs(groups) do
        local widgets, ch = ssColumn(colw, g, faces)
        -- Category i goes to column i, so the page reads left-to-right in the
        -- order the server sent. Past the third (there are three categories by
        -- design) they stack under the shortest column.
        local pick = gi <= ncols and gi or 1
        for i = 2, ncols do
            if gi > ncols and col_h[i] < col_h[pick] then pick = i end
        end
        local lead = #cols[pick] > 0 and cat_gap or 0
        -- Whole categories in or out: half a category on a screen that cannot
        -- scroll reads as data loss, not as a cut.
        if col_h[pick] + lead + ch <= budget then
            if lead > 0 then table.insert(cols[pick], VerticalSpan:new { width = lead }) end
            for _, w in ipairs(widgets) do table.insert(cols[pick], w[1]) end
            col_h[pick] = col_h[pick] + lead + ch
        else
            skipped = skipped + (tonumber(g.total) or 0)
        end
    end

    local tallest = 0
    for i = 1, ncols do tallest = math.max(tallest, col_h[i]) end

    if #groups == 0 then
        add(ssLine(cw, "nic na dziś", "", f_cat))
        gap(6)
    elseif tallest > 0 then
        local row = HorizontalGroup:new { align = "top" }
        for i = 1, ncols do
            if i > 1 then
                table.insert(row, HorizontalSpan:new { width = col_gap })
                -- The rule runs the full height of the tallest column, so the
                -- three categories read as one table and not as three lists
                -- that happen to be next to each other.
                table.insert(row, LineWidget:new {
                    dimen = Geom:new { w = sep_w, h = tallest },
                    background = Blitbuffer.COLOR_GRAY_5,
                })
                table.insert(row, HorizontalSpan:new { width = col_gap })
            end
            table.insert(row, VerticalGroup:new { align = "left", unpack(cols[i]) })
        end
        add(row, tallest)
        gap(6)
    end

    for _, r in ipairs(lab_rows) do add(r[1], r[2]) end

    -- ---- footer, pinned to the bottom by whatever space is left over.
    local slack = H - 2 * (pad + box) - used - footer_h
    if slack > 0 then add(VerticalSpan:new { width = slack }, slack) end
    add(rule(cw, true), Screen:scaleBySize(1))
    gap(4)
    local left = "readingos \u{00B7} " .. clock
    if skipped > 0 then left = left .. string.format("  \u{00B7} +%d dalej", skipped) end
    local rtc = tonumber(get("readingos_ss_refresh_rtc")) or 0
    local right = rtc > 0 and ("odśwież za " .. math.floor(rtc / 60) .. " min") or ""
    if lock_label then right = lock_label end
    add(ssLine(cw, left, right, f_meta, lock_label and f_who or f_meta, not lock_label))

    -- The page is one box: header band, ruled columns, LAB band, all inside a
    -- single frame (design A). Margin, not padding, keeps the border off the
    -- very edge of the panel, where a Kindle bezel eats a hairline.
    return FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = box,
        margin = 0,
        radius = 0,
        padding = pad,
        width = W,
        height = H,
        VerticalGroup:new { align = "left", unpack(rows) },
    }
end

--- Take over KOReader's sleep screen when it is set to ours. Screensaver and
--- RTC-wakeup plumbing follows tasksss.koplugin, which is proven on this device.
function ReadingOS:patchScreensaver()
    local plugin = self
    local Screensaver = require("ui/screensaver")
    if Screensaver._orig_show_before_readingos then return end
    Screensaver._orig_show_before_readingos = Screensaver.show

    Screensaver.show = function(ss)
        if G_reader_settings:readSetting("screensaver_type") ~= SS_TYPE then
            return Screensaver._orig_show_before_readingos(ss)
        end
        ss.screensaver_type = SS_TYPE
        plugin:scheduleScreensaverRefresh()

        if ss.screensaver_widget then
            UIManager:close(ss.screensaver_widget)
            ss.screensaver_widget = nil
        end
        Device.screen_saver_mode = true

        local function draw()
            local data, is_stale = plugin:ssFetch()
            if not data then
                -- Nothing to say is not a reason to leave a half-drawn page:
                -- hand the screen back to KOReader's own cover screensaver.
                logger.warn("ReadingOS: no screensaver data, falling back to cover")
                Device.screen_saver_mode = false
                G_reader_settings:saveSetting("screensaver_type", "cover")
                Screensaver:setup()
                Screensaver._orig_show_before_readingos(ss)
                G_reader_settings:saveSetting("screensaver_type", SS_TYPE)
                return
            end
            -- Sideways before the widget is built: every row measures itself
            -- against Screen:getWidth(), which is only 1448 once we are turned.
            ssEnterLandscape()
            local ScreenSaverWidget = require("ui/widget/screensaverwidget")
            ss.screensaver_widget = ScreenSaverWidget:new {
                widget = plugin:ssWidget(data, is_stale),
                background = Blitbuffer.COLOR_WHITE,
                covers_fullscreen = true,
            }
            ss.screensaver_widget.modal = true
            ss.screensaver_widget.dithered = true
            UIManager:show(ss.screensaver_widget, "full")
        end

        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isOnline() then
            draw()
        elseif (G_reader_settings:readSetting("wifi_enable_action") or "prompt") == "turn_on" then
            local ok = pcall(function() NetworkMgr:goOnlineToRun(draw) end)
            if not ok then draw() end
        else
            draw() -- cache path
        end
    end
end

--- Inject "Ekran ReadingOS podczas snu" into KOReader's wallpaper submenu.
function ReadingOS:patchDofile()
    if _G._orig_dofile_before_readingos then return end
    local orig_dofile = dofile
    _G._orig_dofile_before_readingos = orig_dofile

    _G.dofile = function(filepath)
        local result = orig_dofile(filepath)
        if filepath and filepath:match("screensaver_menu%.lua$") then
            if result and result[1] and result[1].sub_item_table then
                table.insert(result[1].sub_item_table, 6, {
                    text = _("Ekran ReadingOS podczas snu"),
                    checked_func = function()
                        return G_reader_settings:readSetting("screensaver_type") == SS_TYPE
                    end,
                    callback = function()
                        G_reader_settings:saveSetting("screensaver_type", SS_TYPE)
                    end,
                    radio = true,
                })
            end
            _G.dofile = orig_dofile
            _G._orig_dofile_before_readingos = nil
        end
        return result
    end
end

-- ------------------------------------------------------------ lock screen
--
-- The sleep screen on demand: the same widget, awake, with every gesture
-- swallowed except the padlock in the bottom-right corner.
--
-- Leo's hard condition is that it must be impossible to lock yourself out of
-- the device, so all four escape hatches stay open:
--   1. the padlock unlocks with one tap,
--   2. the lock auto-expires (readingos_lock_minutes),
--   3. the state is never persisted — a reboot always comes up unlocked,
--   4. the physical power button is untouched (hardware suspend).

local LockView = InputContainer:extend {
    plugin = nil,
    data = nil,
    stale = nil,
    until_ts = nil,   -- runtime only, deliberately never written to settings
    tick = nil,
}

function LockView:init()
    ssEnterLandscape() -- before dimen: the hit region is measured off the turned screen
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.modal = true
    -- Phone Companion V2: tagged "lock", not a generic screen — executeRemoteCommand
    -- refuses every command outright while this is on top. The lock screen exists to
    -- hide content until an on-device unlock; a remote command bypassing it from a
    -- merely-paired phone (no on-device proof at command time) would defeat that.
    self.readingos_screen = "lock"
    self.opened_at = os.time()
    local minutes = math.max(1, tonumber(get("readingos_lock_minutes")) or 30)
    self.until_ts = os.time() + minutes * 60

    if Device:isTouchDevice() then
        -- Every gesture is caught and dropped; only onTap looks at where it
        -- landed. Nothing here ever returns false, so nothing reaches the
        -- reader underneath.
        self.ges_events = {
            Tap = { GestureRange:new { ges = "tap", range = self.dimen } },
            Hold = { GestureRange:new { ges = "hold", range = self.dimen } },
            Swipe = { GestureRange:new { ges = "swipe", range = self.dimen } },
            Pan = { GestureRange:new { ges = "pan", range = self.dimen } },
            MultiSwipe = { GestureRange:new { ges = "multiswipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        -- A hardware Back unlocks rather than being swallowed: on a device that
        -- has the key, "cannot lock yourself out" outranks a tighter lock. On a
        -- PW3 this branch is inert anyway.
        self.key_events = { Close = { { Device.input.group.Back } } }
    end

    self:keepAwake()
    self:schedule()
    self[1] = self.plugin:ssWidget(self.data, self.stale, "\u{1F512}  ODBLOKUJ")
end

--- The padlock's hit region: the bottom-right corner, where the footer draws
--- it. Generous on purpose — nothing else on this screen is tappable, so a
--- sloppy tap costs nothing and a missed unlock costs trust.
function LockView:onTap(_arg, ges)
    if ges.pos.x >= self.dimen.w * 0.6 and ges.pos.y >= self.dimen.h * 0.9 then
        return self:onClose()
    end
    return true
end

function LockView:onHold() return true end
function LockView:onSwipe() return true end
function LockView:onPan() return true end
function LockView:onMultiSwipe() return true end

--- Kindle's t1 timer keeps the frontlight on as long as we are not suspending,
--- so blocking auto-suspend is all the "stay lit" this needs.
function LockView:keepAwake()
    if self.awake then return end
    self.awake = true
    local ok, PluginShare = pcall(require, "pluginshare")
    if ok and type(PluginShare) == "table" then
        self.prev_auto_suspend = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
    end
    UIManager:preventStandby()
end

function LockView:releaseAwake()
    if not self.awake then return end
    self.awake = false
    local ok, PluginShare = pcall(require, "pluginshare")
    if ok and type(PluginShare) == "table" then
        PluginShare.pause_auto_suspend = self.prev_auto_suspend
    end
    UIManager:allowStandby()
end

--- One minute tick: expire the lock, and refresh the content every fifth pass.
--- Fifth, not every pass — a radio wake a minute would cost more battery than
--- the lit screen it is drawn on.
function LockView:schedule()
    self.ticks = 0
    self.tick = function()
        if not self.awake then return end -- already closed
        if os.time() >= (self.until_ts or 0) then
            self:onClose()
            return
        end
        self.ticks = self.ticks + 1
        if self.ticks % 5 == 0 then
            local data, stale = self.plugin:ssFetch()
            if data then self.data, self.stale = data, stale end
        end
        self[1] = self.plugin:ssWidget(self.data, self.stale, "\u{1F512}  ODBLOKUJ")
        UIManager:setDirty(self, "ui")
        UIManager:scheduleIn(60, self.tick)
    end
    UIManager:scheduleIn(60, self.tick)
end

function LockView:onClose()
    if self.tick then UIManager:unschedule(self.tick) end
    self:releaseAwake()
    track("lock", "close", nil, (os.time() - (self.opened_at or os.time())) * 1000)
    UIManager:close(self)
    return true
end

function LockView:onCloseWidget()
    if self.tick then UIManager:unschedule(self.tick) end
    self:releaseAwake()
    ssRestoreRotation() -- the book goes back to the orientation it was read in
    UIManager:setDirty(nil, "full")
end

function ReadingOS:showLockScreen()
    local data, stale = self:ssFetch()
    if not data then
        UIManager:show(InfoMessage:new {
            text = _("Brak danych na ekran blokady — sprawdź połączenie z serwerem."),
        })
        return
    end
    track("lock", "open", stale and "cached" or "fresh")
    UIManager:show(LockView:new { plugin = self, data = data, stale = stale }, "full")
end

-- Heartbeat: tells the backend this device is still alive, so the phone's
-- "connected" dot means something. Piggybacks on showPhone()'s existing 8s
-- tick rather than a loop of its own — nothing schedules this outside that
-- tick. request() already no-ops on failure (returns nil, err) instead of
-- throwing, so a dropped network here can never take the tick down with it.
local function heartbeat(id)
    request("POST", baseUrl() .. "/api/readingos/phone/heartbeat", encode({ device_id = id }))
end

-- ------------------------------------------------------ V2: BASIC REMOTE
--
-- Peek-then-ack-then-execute, one command at a time — see hooome's
-- src/readingos/remoteCommands.js for the server side of this same state
-- machine (queued -> acked -> done|failed, or queued -> expired).

local function fetchNextCommand(id)
    local res = request("GET", baseUrl() .. "/api/readingos/phone/command/next?device=" .. id)
    local data = res and decode(res)
    return data and data.command or nil
end

--- @return boolean won true only if this tick is the one that gets to execute
--- the command — a 409 (already acked/expired by a retried poll, or owned by
--- a different device) means no. `deviceId` lets the server verify this
--- command actually belongs to the caller, not just that the caller holds
--- the shared bearer token.
local function ackCommand(cmdId, deviceId)
    local res = request("POST", baseUrl() .. "/api/readingos/phone/command/" .. tostring(cmdId) .. "/ack?device=" .. deviceId)
    return res ~= nil
end

local function postCommandResult(cmdId, deviceId, status, result)
    request("POST", baseUrl() .. "/api/readingos/phone/command/" .. tostring(cmdId) .. "/result?device=" .. deviceId,
        encode({ status = status, result = result }))
end

-- Fixed six-command allowlist, mirrored by hooome's own ALLOWED_COMMANDS in
-- src/readingos/remoteCommands.js — keep both in sync if this ever changes.
-- Open and Scroll were deliberately cut for V2 (no safe mapping exists for
-- Open on a touch-only PW3 — KOReader's Menu never tracks a selected item
-- outside a real tap there; no scroll primitive exists anywhere in this
-- file's screens) — never re-add either under another name.
local REMOTE_BLOCKED_SCREENS = {
    -- LockView exists to hide content until an on-device unlock. A remote
    -- command only proves the phone still holds a paired session, not that
    -- anything happened on the device just now — so every command refuses
    -- outright here rather than opening a way to bypass the lock remotely.
    lock = true,
}

--- Runs one remote command against whatever ReadingOS screen is currently on
--- top of the UIManager stack. Only ever touches widgets tagged
--- `readingos_screen` (set in each screen's :init(), see Dashboard/TaskDetail/
--- LearnView/CraftView/LockView/showList's Menu above) — the book reader,
--- KOReader's own dialogs, and anything else underneath are never reached.
--- "done" means: the operation this command maps to actually happened, by
--- whatever signal that operation already exposes — not merely "the dispatch
--- call didn't throw". back/close/next/prev are synchronous, in-memory,
--- KOReader UI-stack operations with no network step and no failure mode
--- this codebase exposes, so a non-throwing call already IS the strongest
--- available proof they ran. home/refresh both go through self:fetch()'s
--- network call, which already has a real success/failure signal (fresh or
--- acceptably-cached data vs nil) — that signal is what decides done/failed
--- for them, never assumed.
--- @return string status "done" or "failed"
--- @return string|nil result short label, nil on a plain success
local function executeRemoteCommand(plugin, cmd)
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.readingos_screen and REMOTE_BLOCKED_SCREENS[top.readingos_screen] then
        return "failed", "locked"
    end

    if cmd == "home" then
        -- Unwind every ReadingOS widget stacked above (Dashboard -> WIĘCEJ ->
        -- CraftView is a real depth this codebase reaches), reusing each
        -- screen's own :onClose() so telemetry/cleanup still runs exactly as
        -- it would for a real swipe-back. Idempotent: already-on-Dashboard is
        -- a no-op, never a redundant refetch+redraw.
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 20 then return "failed", "error" end -- stack never settled; give up rather than loop forever
            local w = UIManager:getTopmostVisibleWidget()
            -- Defensive: no current call site ever nests LockView beneath
            -- another ReadingOS screen (it's only ever opened standalone),
            -- but if that ever changed, Home must stop and refuse right
            -- here — never fall through to showDashboard() below, which
            -- would otherwise paint Dashboard over/instead of a screen this
            -- loop deliberately didn't close.
            if w and w.readingos_screen and REMOTE_BLOCKED_SCREENS[w.readingos_screen] then
                return "failed", "locked"
            end
            if not w or not w.readingos_screen then break end
            if w.readingos_screen == "dashboard" then return "done", "noop" end
            if w.onClose then w:onClose() else UIManager:close(w) end
        end
        -- showDashboard() returns false without showing anything when its
        -- own fetch fails — that's a real failure, not a thrown error, so
        -- pcall alone would never have caught it.
        if not plugin:showDashboard() then return "failed", "network_error" end
        return "done", nil
    end

    if cmd == "back" or cmd == "close" then
        -- Same one-level unwind for both — Close never falls back to Home's
        -- multi-level behavior, per the V2 spec.
        if not top or not top.readingos_screen then return "done", "noop" end -- nothing of ours on screen: safe result, not an error
        if top.onClose then top:onClose() else UIManager:close(top) end
        return "done", nil
    end

    if cmd == "next" or cmd == "prev" then
        -- Only a real KOReader Menu (showList/showCollection) has page
        -- navigation. Dashboard/TaskDetail/LearnView/CraftView/LockView have
        -- no pagination or scroll of any kind — confirmed by reading this
        -- file, not assumed — so every other screen is unsupported_on_screen.
        if not top or top.readingos_screen ~= "menu" then return "failed", "unsupported_on_screen" end
        if cmd == "next" then top:onNextPage() else top:onPrevPage() end
        return "done", nil
    end

    if cmd == "refresh" then
        -- V2 scope: Dashboard only, via its own existing refreshInto().
        if not top or top.readingos_screen ~= "dashboard" then return "failed", "unsupported_on_screen" end
        -- Same real signal as home above: refreshInto() returns false
        -- without touching the widget when its own fetch fails.
        if not plugin:refreshInto(top) then return "failed", "network_error" end
        return "done", nil
    end

    return "failed", "unknown_command" -- unreachable in practice: hooome validates against this same allowlist first
end

-- Shows a QR the phone scans, then polls whether it's been consumed while the
-- QR is on screen. V2 adds BASIC REMOTE (home/back/next/prev/close/refresh)
-- on top of the same post-pair tick — still no state mirror, no screenshots,
-- no content bridge, no arbitrary item selection.
--
-- Poll cadence: every 8s, same "only while this specific view is open"
-- shape as LockView's tick — never a background loop, unscheduled on close.
-- The same tick also heartbeats and (once paired) polls/executes at most one
-- remote command per tick: while the QR is up AND while the "✓ Telefon
-- sparowany" confirmation stays on screen afterwards (an InfoMessage the
-- user hasn't tapped away yet — same as InfoMessage always behaves
-- elsewhere in this file, nothing new). Tapping it closed is what ends the
-- heartbeat/command polling; nothing runs once "Telefon" is no longer on
-- screen. 8s was kept as-is rather than tightened for V2 — untested whether
-- that reads as responsive enough on a real PW3; revisit after physical
-- testing if it feels sluggish.
function ReadingOS:showPhone()
    local id = deviceId()
    local body = encode({ device_id = id, name = "Kindle" })
    local res, err = request("POST", baseUrl() .. "/api/readingos/phone/pair", body)
    if not res then
        track("phone", "pair_request_failed", err)
        UIManager:show(InfoMessage:new {
            text = _("Brak połączenia z serwerem — spróbuj ponownie."),
        })
        return
    end
    local pairing = decode(res)
    if not pairing or not pairing.pair_url or not pairing.token then
        UIManager:show(InfoMessage:new { text = _("Nieprawidłowa odpowiedź serwera.") })
        return
    end
    track("phone", "pair_request", nil)

    -- Wake lock, same shape as CraftView:setAwake/releaseAwake above (this
    -- file's own established pattern — not a new mechanism): the heartbeat
    -- above only runs because poll_task keeps re-scheduling itself via
    -- UIManager:scheduleIn, and this device's own idle power management
    -- (auto-standby/auto-suspend) freezes that scheduling once the Kindle
    -- goes untouched — exactly the case here, since the whole point of
    -- Phone Companion is that every tap happens on the *phone*, never on
    -- the Kindle. Confirmed on a real PW3: heartbeat landed a few times
    -- then silently stopped while the screen kept showing "sparowany" (the
    -- E-Ink frame doesn't care whether the CPU is still running).
    --
    -- `preventStandby`/`allowStandby` are a refcounted pair — an unmatched
    -- allowStandby() is a hard assert crash in UIManager, so `locked` guards
    -- against ever releasing twice or releasing without having acquired.
    -- Held only for as long as a Phone Companion screen (QR, or the
    -- post-pair confirmation) is actually up; released on every exit path
    -- below, never left standing once "Telefon" is off screen.
    local locked = false
    local function lockStandby()
        if locked then return end
        locked = true
        UIManager:preventStandby()
    end
    local function releaseStandby()
        if not locked then return end
        locked = false
        UIManager:allowStandby()
    end

    local token = pairing.token
    local poll_task
    local qr = QRMessage:new {
        text = pairing.pair_url,
        width = Screen:scaleBySize(420),
        height = Screen:scaleBySize(420),
        timeout = 90,
        dismiss_callback = function()
            if poll_task then UIManager:unschedule(poll_task) end
            -- Fires on user-dismiss, the QR's own 90s timeout, AND our own
            -- programmatic UIManager:close(qr) below on pairing success —
            -- in that last case the lock is re-taken immediately after for
            -- the paired-confirmation phase (see below), so the session
            -- never actually goes unlocked in between; every other case
            -- means the session is genuinely over.
            releaseStandby()
        end,
    }

    poll_task = function()
        heartbeat(id)
        local status_res = request("GET", baseUrl() .. "/api/readingos/phone/pair/" .. token .. "/status")
        local status = status_res and decode(status_res)
        if status and status.consumed then
            track("phone", "paired", nil)
            UIManager:close(qr) -- releases the QR-phase lock via dismiss_callback above
            lockStandby() -- re-acquire for the confirmation phase below — same tick, no gap

            -- Kept alive by the InfoMessage staying open (dismissable, no
            -- timeout): each tick from here just heartbeats, no more
            -- pairing status to check. Tapping it away unschedules AND
            -- releases the lock — the last exit path of this session.
            local paired_msg
            paired_msg = InfoMessage:new {
                text = _("✓ Telefon sparowany."),
                dismiss_callback = function()
                    UIManager:unschedule(poll_task)
                    releaseStandby()
                end,
            }
            poll_task = function()
                heartbeat(id)

                -- At most one command per tick, never a batch — e-ink
                -- execution is strictly serial. Ack first: only the tick that
                -- wins the ack (not a 409 from an already-acked/expired row)
                -- ever calls executeRemoteCommand, so a retried/duplicate
                -- poll can never double-execute the same command.
                local cmd = fetchNextCommand(id)
                if cmd and cmd.id and cmd.cmd and ackCommand(cmd.id, id) then
                    -- pcall: a bad/unexpected screen state inside dispatch
                    -- must never take the heartbeat/pairing tick down with
                    -- it. Result is posted via scheduleIn(0, ...) rather than
                    -- immediately after dispatch returns — the closest thing
                    -- to "after the render settled" KOReader's APIs expose to
                    -- plugin code: setDirty only *enqueues* a repaint, it
                    -- never blocks or calls back, so this yields one tick to
                    -- let that repaint run first rather than reporting DONE
                    -- in the same instant the command was merely dispatched.
                    local ok, status, result = pcall(executeRemoteCommand, self, cmd.cmd)
                    local cmd_id = cmd.id
                    UIManager:scheduleIn(0, function()
                        if ok then
                            postCommandResult(cmd_id, id, status, result)
                        else
                            postCommandResult(cmd_id, id, "failed", "error")
                        end
                    end)
                end

                UIManager:scheduleIn(8, poll_task)
            end
            UIManager:show(paired_msg)
            UIManager:scheduleIn(8, poll_task)
            return
        end
        if status and status.expired then
            return -- let the QR's own timeout close it; that release path already covers this
        end
        UIManager:scheduleIn(8, poll_task)
    end

    lockStandby() -- acquired right before the timed loop actually starts
    UIManager:show(qr)
    UIManager:scheduleIn(8, poll_task)
end

-- ----------------------------------------------------------- active sleep

local function toggleSuspend()
    local powerd = Device:getPowerDevice()
    if powerd and powerd.toggleSuspend then
        powerd:toggleSuspend()
    elseif Device.suspend then
        Device:suspend()
    end
end

--- Wake on the RTC, redraw, sleep again. Skipped on a low battery: a lock
--- screen is not worth the last 20 % of a charge.
function ReadingOS:scheduleScreensaverRefresh()
    if self.rtc_scheduled and self.wakeup_mgr then
        self.wakeup_mgr:removeTasks(nil, self.rtcRefreshCallback)
        self.rtc_scheduled = false
    end
    local interval = tonumber(get("readingos_ss_refresh_rtc")) or 0
    if interval <= 0 or not self.wakeup_mgr then return end

    local min_batt = tonumber(get("readingos_ss_min_battery")) or 0
    if min_batt > 0 then
        local ok, capacity = pcall(function() return Device:getPowerDevice():getCapacity() end)
        if ok and type(capacity) == "number" and capacity < min_batt then
            logger.info("ReadingOS: skipping active sleep, battery", capacity)
            return
        end
    end
    self.wakeup_mgr:addTask(interval, self.rtcRefreshCallback)
    self.rtc_scheduled = true
end

-- ------------------------------------------------------------------- entry

--- @return boolean true only if Dashboard was actually shown (a real fetch
--- succeeded, per self:fetch()'s own fresh-or-acceptably-cached definition).
--- executeRemoteCommand's "home" reports done/failed off this — every
--- existing caller (menu callback, onShowReadingOS, the Dispatcher action)
--- already discards the return value, so this is not a behavior change for
--- any of them.
function ReadingOS:showDashboard()
    if getToken() == "" then
        UIManager:show(InfoMessage:new {
            text = _("Brak tokenu API. Wrzuć readingos-token.txt do folderu koreader albo ustaw go w Narzędzia → ReadingOS."),
        })
        return false
    end

    local data, age, err = self:fetch()
    if not data then
        UIManager:show(InfoMessage:new { text = _("ReadingOS nieosiągalny: ") .. tostring(err or "?") })
        return false
    end

    -- The radio is already up from the fetch above, so noticing a new version
    -- here is free. Checked once a day: this is a reading device, not a
    -- package manager.
    if not age then
        local last = tonumber(get("readingos_update_checked")) or 0
        if os.time() - last > 86400 then
            set("readingos_update_checked", os.time())
            local manifest = self:updateManifest()
            if manifest and versionNewer(manifest.version, self:localVersion()) then
                self.update_ready = manifest.version
            else
                self.update_ready = nil
            end
        end
    end

    track("home", "open", age and "cached" or "fresh")
    UIManager:show(Dashboard:new { data = data, age = age, plugin = self }, "full")
    return true
end

function ReadingOS:onShowReadingOS()
    self:showDashboard()
    return true
end

-- ------------------------------------------------------ reading session time
--
-- Minutes buy lamplight, and lamplight is the only hard gate in the game, so
-- this has to be honest. The clock runs from opening a book to closing or
-- suspending it — never from page turns, which would cost a radio wake each.

function ReadingOS:onReaderReady()
    self.session_start = os.time()
end

function ReadingOS:endSession()
    if not self.session_start then return end
    local minutes = math.floor((os.time() - self.session_start) / 60)
    self.session_start = nil
    if minutes < 1 then return end
    track("reader", "session", nil, minutes * 60000)
    self:act("read", nil, { minutes = minutes })
end

function ReadingOS:onCloseDocument() self:endSession() end

-- Going to sleep. The frontlight is dropped to 0 *before* the sleep screen is
-- drawn and stays there across every RTC redraw — a device that lights itself
-- up every 15 minutes on a bedside table is worse than no lock screen at all.
-- The level is put back on a real, human resume (onResume below).
function ReadingOS:onSuspend()
    self:endSession()
    if get("readingos_ss_light_off") and Device:hasFrontlight() and not self.saved_frontlight then
        local ok, level = pcall(function() return Device:getPowerDevice():frontlightIntensity() end)
        if ok and type(level) == "number" then
            self.saved_frontlight = level
            pcall(function() Device:getPowerDevice():setIntensity(0) end)
        end
    end
end

-- An RTC wake is not a resume: it redraws and goes straight back to sleep, so
-- the light stays off and the RTC task is left in place for the next one.
function ReadingOS:onResume()
    if self.simulated_wakeup then
        self.simulated_wakeup = false
        logger.info("ReadingOS: RTC wake, re-suspending in 10 s")
        UIManager:scheduleIn(10, toggleSuspend)
        return
    end
    if self.rtc_scheduled and self.wakeup_mgr then
        self.wakeup_mgr:removeTasks(nil, self.rtcRefreshCallback)
        self.rtc_scheduled = false
    end
    if self.saved_frontlight then
        pcall(function() Device:getPowerDevice():setIntensity(self.saved_frontlight) end)
        self.saved_frontlight = nil
    end
end

function ReadingOS:onCloseWidget()
    if self.rtc_scheduled and self.wakeup_mgr then
        self.wakeup_mgr:removeTasks(nil, self.rtcRefreshCallback)
        self.rtc_scheduled = false
    end
end

-- -------------------------------------------------------------------- menu

function ReadingOS:editText(key, title, touchmenu)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = tostring(get(key)),
        buttons = { {
            { text = _("Anuluj"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Zapisz"),
                is_enter_default = true,
                callback = function()
                    set(key, dialog:getInputText())
                    UIManager:close(dialog)
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ReadingOS:addToMainMenu(menu_items)
    menu_items.readingos = {
        text = _("ReadingOS"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Otwórz pulpit"),
                callback = function() self:showDashboard() end,
            },
            {
                text = _("Zablokuj ekran"),
                callback = function() self:showLockScreen() end,
            },
            {
                text = _("Telefon"),
                callback = function() self:showPhone() end,
            },
            {
                text = _("Jak to działa"),
                callback = function() self:showHelp() end,
                separator = true,
            },
            {
                text_func = function() return "Serwer: " .. get("readingos_url") end,
                keep_menu_open = true,
                callback = function(touchmenu) self:editText("readingos_url", _("Adres serwera"), touchmenu) end,
            },
            {
                text_func = function()
                    return "Token API: " .. (getToken() ~= "" and "ustawiony" or "BRAK")
                end,
                keep_menu_open = true,
                callback = function(touchmenu) self:editText("readingos_token", _("Token API"), touchmenu) end,
            },
            {
                text_func = function()
                    local left = tonumber(get("readingos_hints_left")) or 0
                    return "Podpowiedzi: " .. (left > 0 and ("jeszcze " .. left) or "wyłączone")
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    set("readingos_hints_left", (tonumber(get("readingos_hints_left")) or 0) > 0 and 0 or 10)
                    if touchmenu then touchmenu:updateItems() end
                end,
                separator = true,
            },
            {
                text_func = function()
                    return "Ekran snu: " ..
                        (G_reader_settings:readSetting("screensaver_type") == SS_TYPE and "ReadingOS" or "inny")
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local on = G_reader_settings:readSetting("screensaver_type") == SS_TYPE
                    G_reader_settings:saveSetting("screensaver_type", on and "cover" or SS_TYPE)
                    G_reader_settings:flush()
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
            {
                text_func = function()
                    local s = tonumber(get("readingos_ss_refresh_rtc")) or 0
                    return "Odświeżanie we śnie: " .. (s <= 0 and "wyłączone" or (math.floor(s / 60) .. " min"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new {
                        title_text = _("Odświeżaj co (minut, 0 = nigdy)"),
                        value = math.floor((tonumber(get("readingos_ss_refresh_rtc")) or 0) / 60),
                        value_min = 0,
                        value_max = 120,
                        value_step = 5,
                        callback = function(spin)
                            set("readingos_ss_refresh_rtc", spin.value * 60)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return "Podświetlenie przy odświeżaniu: " ..
                        (get("readingos_ss_light_off") and "gaś" or "bez zmian")
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    set("readingos_ss_light_off", not get("readingos_ss_light_off"))
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
            {
                text_func = function()
                    return "Ekran snu poziomo: " .. (get("readingos_ss_landscape") and "tak" or "nie")
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    set("readingos_ss_landscape", not get("readingos_ss_landscape"))
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
            {
                text_func = function()
                    return "Blokada odblokuje się sama po: " ..
                        (math.max(1, tonumber(get("readingos_lock_minutes")) or 30)) .. " min"
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new {
                        title_text = _("Odblokuj sam po (minut)"),
                        value = math.max(1, tonumber(get("readingos_lock_minutes")) or 30),
                        value_min = 5,
                        value_max = 120,
                        value_step = 5,
                        callback = function(spin)
                            set("readingos_lock_minutes", spin.value)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return "Pasek LAB (samoloty, ISS): " .. (get("readingos_ss_lab") and "tak" or "nie")
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    set("readingos_ss_lab", not get("readingos_ss_lab"))
                    if touchmenu then touchmenu:updateItems() end
                end,
                separator = true,
            },
            {
                text_func = function() return _("Sprawdź aktualizacje") .. "  (v" .. self:localVersion() .. ")" end,
                keep_menu_open = true,
                callback = function() self:checkForUpdate(false) end,
            },
            {
                text = _("Testuj połączenie"),
                keep_menu_open = true,
                callback = function()
                    local data, age, err = self:fetch()
                    local msg
                    if not data then
                        msg = "BŁĄD: " .. tostring(err or "?")
                    else
                        local dg = data.dig or {}
                        msg = string.format("OK%s\n%d zadań · %d dom · %.1f m głębokości",
                            age and " (z cache)" or "",
                            #(data.tasks or {}), #(data.house or {}), dg.depth or 0)
                    end
                    UIManager:show(InfoMessage:new { text = msg })
                end,
            },
        },
    }
end

-- -------------------------------------------------------------------- init

function ReadingOS:onDispatcherRegisterActions()
    Dispatcher:registerAction("readingos_dashboard", {
        category = "none",
        event = "ShowReadingOS",
        title = _("Pulpit ReadingOS"),
        general = true,
    })
end

function ReadingOS:init()
    local changed = false
    for k, v in pairs(DEFAULTS) do
        if G_reader_settings:readSetting(k) == nil then
            G_reader_settings:saveSetting(k, v)
            changed = true
        end
    end
    if changed then G_reader_settings:flush() end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self:patchDofile()
    self:patchScreensaver()
    self.wakeup_mgr = Device.wakeup_mgr
    if not self.wakeup_mgr then
        logger.info("ReadingOS: no WakeupMgr, sleep-screen refresh unavailable")
    end
    self.rtcRefreshCallback = function()
        if Device:isKobo() then
            UIManager:scheduleIn(0, function()
                local Screensaver = require("ui/screensaver")
                if Device.screen_saver_mode
                    and G_reader_settings:readSetting("screensaver_type") == SS_TYPE then
                    Screensaver:show()
                end
            end)
        else
            -- Kindle: bounce out of suspend so the screensaver redraws, then
            -- straight back down (see onResume).
            toggleSuspend()
            self.simulated_wakeup = true
        end
    end
end

-- Exposed for test_dash_layout.lua only. The dashboard's vertical budget is the
-- one piece of layout arithmetic here that can silently push ZAMKNIJ off the
-- bottom of a screen that cannot scroll, so it gets a check.
ReadingOS._Dashboard = Dashboard
ReadingOS._CraftView = CraftView

return ReadingOS
