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
local GestureRange = require("ui/gesturerange")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
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

local function isoDay(offset)
    return os.date("%Y-%m-%d", os.time() + (offset or 0) * 86400)
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
end

--- Register a tap target covering the next `height` pixels.
function Dashboard:claim(y, height, target)
    target.y1 = y
    target.y2 = y + height
    self.hit[#self.hit + 1] = target
    return y + height
end

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
    local h_head = Screen:scaleBySize(SIZE_HEAD * 2 * FONT_SCALE)
    local h_row = math.max(MIN_TAP, Screen:scaleBySize(SIZE_ROW * 2 * FONT_SCALE))
    local h_title = Screen:scaleBySize(SIZE_TITLE * 1.7 * FONT_SCALE)
    local h_meta = Screen:scaleBySize(SIZE_META * 1.7 * FONT_SCALE)

    -- The height passed in is what the row was *asked* for; what a widget then
    -- renders can differ (a FrameContainer adds its own border and padding, a
    -- TextWidget rounds to its font metrics). Registering the asked-for height
    -- made every row below a mismatch drift a few pixels further down the
    -- screen, and the drift accumulates — which is why the bottom rows, NAUKA
    -- and DIG, were the ones that swallowed each other's taps. Measure the
    -- widget instead and the whole column stays honest, top to bottom.
    local function add(widget, height, target)
        rows[#rows + 1] = widget
        local ok, size = pcall(function() return widget:getSize() end)
        local real = (ok and size and size.h and size.h > 0) and size.h or height
        if target then y = self:claim(y, real, target) else y = y + real end
    end
    local function gap(px)
        local h = Screen:scaleBySize(px)
        rows[#rows + 1] = VerticalSpan:new { width = h }
        y = y + h
    end

    -- ---- status bar. Inert: no marker, no reaction. Rule 4.
    local dig = d.dig or {}
    -- The top line is the way into the manual. Nothing else on the screen has
    -- room for a help affordance without stealing space from the book.
    add(lrRow(cw, h_label, plDate():upper(),
        string.format("%.1f m · %d/%d   ?", dig.depth or 0, dig.collected or 0, dig.collection_total or 42),
        face(SIZE_LABEL), face(SIZE_LABEL), true), h_label, { screen = "help", label = "help" })
    add(rule(cw), Screen:scaleBySize(2))
    gap(8)

    -- ---- undo. A tap on e-ink lands a row off more often than on a phone, so
    -- the way back has to be visible, not a hidden gesture.
    local undo = d.undo
    if type(undo) == "table" and undo.label then
        add(FrameContainer:new {
            bordersize = Screen:scaleBySize(1),
            padding = Screen:scaleBySize(5),
            width = cw,
            radius = 0,
            TextWidget:new {
                text = "COFNIJ: " .. tostring(undo.label),
                face = face(SIZE_META),
                max_width = cw - Screen:scaleBySize(20),
            },
        }, h_meta + Screen:scaleBySize(12), { kind = "undo", label = tostring(undo.label) })
        gap(8)
    end

    -- ---- attention band, only when something is genuinely late
    local overdue, out = 0, 0
    for _i, t in ipairs(d.tasks or {}) do if t.sym == "▲" then overdue = overdue + 1 end end
    for _i, hh in ipairs(d.house or {}) do if hh.state == "out" then out = out + 1 end end
    if overdue > 0 or out > 0 then
        local parts = {}
        if overdue > 0 then parts[#parts + 1] = overdue .. " PO TERMINIE" end
        if out > 0 then parts[#parts + 1] = out .. " BRAK" end
        add(FrameContainer:new {
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = Screen:scaleBySize(4),
            width = cw,
            TextWidget:new {
                text = "▲ " .. table.concat(parts, " · "),
                face = face(SIZE_META),
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        }, h_meta, { screen = overdue > 0 and "tasks" or "house", label = "attention" })
        gap(8)
    end

    -- ---- hero. The book always wins the top of the screen.
    -- No "CZYTASZ" label any more: a title this size, at the top, under a
    -- progress bar, is not mistakable for anything else — the label was one
    -- more 6 px gray line explaining what the screen already showed.
    local book = self.plugin:currentBook(d)
    add(LeftContainer:new { dimen = { w = cw, h = h_title },
        TextWidget:new { text = book.title, face = face(SIZE_TITLE), max_width = cw } }, h_title)
    if book.author ~= "" or book.percent ~= "" then
        add(lrRow(cw, h_meta, book.author, book.percent, face(SIZE_META), face(SIZE_META), true), h_meta)
    end
    -- A real ProgressWidget, not block characters: the Kindle font has no
    -- ▓/░ glyphs and rendered the first version as diagonal hatching. Full
    -- width now that the percentage sits on the line above it.
    if (book.fraction or 0) > 0 then
        add(ProgressWidget:new {
            width = cw,
            height = Screen:scaleBySize(7),
            percentage = book.fraction,
            margin_h = 0,
            margin_v = 0,
            bordersize = Screen:scaleBySize(1),
        }, Screen:scaleBySize(9))
    end
    gap(8)

    -- [ BOX ] = does something now. Rule 2.
    add(FrameContainer:new {
        bordersize = Screen:scaleBySize(1),
        padding = Screen:scaleBySize(8),
        width = cw,
        radius = 0,
        CenterContainer:new {
            dimen = { w = cw - Screen:scaleBySize(18), h = h_row },
            TextWidget:new { text = book.open and "CZYTAJ DALEJ" or "NIE MA OTWARTEJ KSIĄŻKI", face = face(SIZE_ROW) },
        },
    }, h_row + Screen:scaleBySize(18), { kind = "continue", label = "continue" })
    gap(10)

    -- ---- sections. A quiet section collapses to one line: that is the entire
    -- adaptive-density rule, and why an empty day is an almost empty screen.
    -- What the header says about a section has to be information, not an
    -- implementation detail. "(30 of 153)" described the row cap and read as
    -- 153 things needing attention; "34 today · 119 tomorrow" describes the
    -- day, which is the only thing worth a glance.
    local function section(key, label, items, quiet_text, total, summary)
        gap(6)
        local head = label
        if summary and summary ~= "" then
            head = label .. "   " .. summary
        elseif total and total > #items then
            head = label .. "   " .. total
        end
        if #items == 0 then
            add(lrRow(cw, h_row, head, quiet_text .. "   >", face(SIZE_HEAD), face(SIZE_META), true),
                h_row, { screen = key, label = key })
        else
            -- Header, then a hairline directly under it. The rule marks where a
            -- section *starts*; the old dashed rule after every section marked
            -- where one ended, which is the same information drawn five times.
            add(lrRow(cw, h_head, head, ">", face(SIZE_HEAD), face(SIZE_HEAD)),
                h_head, { screen = key, label = key })
            add(rule(cw, true), Screen:scaleBySize(1))
            gap(4)
            for i = 1, math.min(3, #items) do
                -- What the bottom of the screen owes: two tiles, the manual row,
                -- the footer and ZAMKNIJ. A section that would eat into that
                -- stops early — the header already carries the total, and the
                -- way out of the screen must never be the thing that falls off
                -- it. On a day with a craft waiting this used to overflow in
                -- silence, and the type sizes only made the drop worse.
                if y + h_row > H - Screen:scaleBySize(210) then break end
                local it = items[i]
                -- The row carries the whole item, because tapping it now opens a
                -- menu that needs to know whether the task repeats and who it
                -- belongs to — not just its id.
                add(lrRow(cw, h_row, "  " .. rowText(it), it.meta,
                    face(SIZE_ROW), face(SIZE_META), true),
                    h_row, { kind = it.kind, id = it.id, screen = key, label = it.text, row = it })
            end
        end
        gap(10)
    end

    local totals = d.totals or {}
    -- CRAFTS only appears when a pattern is actually waiting. A section that is
    -- empty most weeks must not cost a line most weeks.
    if #(d.crafts or {}) > 0 then
        section("crafts", "ROBÓTKI", d.crafts, "nic nie wysłane")
    end
    local tb = totals.task_buckets or {}
    local tparts = {}
    if (tb.past or 0) > 0 then tparts[#tparts + 1] = tb.past .. " zaległe" end
    if (tb.today or 0) > 0 then tparts[#tparts + 1] = tb.today .. " dziś" end
    if (tb.tmrw or 0) > 0 then tparts[#tparts + 1] = tb.tmrw .. " jutro" end
    -- The three rows are mine: duty categories, me or both of us. Everything
    -- else in the horizon is still counted in the header and still one tap
    -- away in the full list — it is just not what the home screen argues about.
    section("tasks", "ZADANIA", d.preview_tasks or d.tasks or {}, "nic na mnie",
        totals.tasks, table.concat(tparts, " · "))
    section("house", "DOM", d.house or {}, "wszystko jest", totals.house)

    -- ---- NAUKA and DIG as two tiles, not two more thin rows. These are the two
    -- that a finger kept swapping: they sit lowest, where the thumb reaches
    -- worst, and missing by one row swapped a whole screen for another. Half the
    -- width and three lines tall each, they are hard to confuse and hard to miss.
    gap(10)
    local learn = d.learn or {}
    local tpad = Screen:scaleBySize(10)
    local bw = math.floor((cw - Screen:scaleBySize(12)) / 2)
    local inner = bw - 2 * tpad
    local tile_h = h_label + h_title + h_meta + 2 * tpad + Screen:scaleBySize(2)

    -- The number is the tile. It was set in the same 6 px as its own caption,
    -- so both tiles read as three grey lines and neither said anything from
    -- across the room.
    local function tile(title, number, caption)
        local function centred(text, size, height, gray)
            return CenterContainer:new {
                dimen = { w = inner, h = height },
                TextWidget:new {
                    text = text, face = face(size), max_width = inner,
                    fgcolor = gray and Blitbuffer.COLOR_GRAY_5 or nil,
                },
            }
        end
        return FrameContainer:new {
            bordersize = Screen:scaleBySize(1), padding = tpad, width = bw, radius = 0,
            VerticalGroup:new { align = "left",
                centred(title, SIZE_LABEL, h_label, true),
                centred(number, SIZE_TITLE, h_title),
                centred(caption, SIZE_META, h_meta, true) },
        }
    end

    local ldue = learn.due or 0
    local tiles = OverlapGroup:new { dimen = { w = cw, h = tile_h } }
    table.insert(tiles, LeftContainer:new { dimen = { w = cw, h = tile_h },
        tile("NAUKA",
            ldue > 0 and tostring(ldue) or "✓",
            ldue > 0 and ("fiszek · " .. (learn.minutes or 1) .. " min")
                or ((learn.streak or 0) .. " dni z rzędu")) })
    table.insert(tiles, RightContainer:new { dimen = { w = cw, h = tile_h },
        tile("DIG",
            string.format("%.1f m", dig.depth or 0),
            dig.stall or string.format("%d/%d", dig.collected or 0, dig.collection_total or 42)) })

    -- One target per half, split down the middle — the same trick the craft
    -- screen's two buttons use.
    local ty = y
    add(tiles, tile_h)
    self.hit[#self.hit + 1] = { y1 = ty, y2 = y, x2 = pad + bw, screen = "learn", label = "learn" }
    self.hit[#self.hit + 1] = { y1 = ty, y2 = y, x1 = pad + bw, screen = "dig", label = "dig" }

    -- A "?" tucked on the end of the status line was too quiet to find, which
    -- made the game look like unexplained noise. The manual gets its own row.
    gap(6)
    add(lrRow(cw, h_row, "JAK TO DZIAŁA", ">", face(SIZE_LABEL), face(SIZE_LABEL)),
        h_row, { screen = "help", label = "help" })

    -- An update announces itself on the dashboard rather than in a popup: you
    -- came here to read, and a modal on arrival would be an ambush.
    if self.plugin.update_ready then
        add(lrRow(cw, h_row, "AKTUALIZACJA  v" .. tostring(self.plugin.update_ready),
            "zainstaluj  >", face(SIZE_LABEL), face(SIZE_META), true),
            h_row, { kind = "update", label = "update" })
    end

    -- ---- footer: staleness, one rotating hint, and the way out.
    -- The way out has to be visible. Swipe-right alone was a gesture with no
    -- sign on the screen that it existed, which is the same mistake as hiding
    -- an action behind a long press.
    gap(10)
    add(rule(cw), Screen:scaleBySize(2))
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
    if foot ~= "" then
        add(CenterContainer:new { dimen = { w = cw, h = h_meta },
            TextWidget:new { text = foot, face = face(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } }, h_meta)
    end
    gap(4)
    add(FrameContainer:new {
        bordersize = Screen:scaleBySize(1),
        padding = Screen:scaleBySize(7),
        width = cw,
        radius = 0,
        CenterContainer:new {
            dimen = { w = cw - Screen:scaleBySize(16), h = h_row },
            TextWidget:new { text = "ZAMKNIJ", face = face(SIZE_ROW) },
        },
    }, h_row + Screen:scaleBySize(16), { kind = "close", label = "close" })

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

function ReadingOS:refreshInto(dashboard)
    local data, age = self:fetch()
    if not data then return end
    dashboard.data = data
    dashboard.age = age
    dashboard.hit = {}
    dashboard[1] = dashboard:build()
    UIManager:setDirty(dashboard, "full")
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

    if target.screen then return self:openScreen(dashboard, target.screen) end
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
    pattern = nil,   -- { id, title, rows = { {id, n, text, done, repeat} } }
    cursor = 1,      -- 1-based index of the row being worked
    awake_until = nil,
    awake_task = nil,
    opened_at = nil,
}

function CraftView:init()
    self.opened_at = os.time()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
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

    local function add(w, h, target)
        rows[#rows + 1] = w
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

    -- header: title, and the count that answers "how much is left"
    add(lrRow(cw, h_meta, "‹  " .. self.pattern.title,
        string.format("%d / %d", math.min(self.cursor, total), total),
        faceFull(SIZE_META), faceFull(SIZE_META), true), h_meta, { kind = "back" })
    add(ProgressWidget:new {
        width = cw, height = Screen:scaleBySize(7),
        percentage = total > 0 and (doneCount / total) or 0,
        margin_h = 0, margin_v = 0, bordersize = Screen:scaleBySize(1),
    }, Screen:scaleBySize(12))
    gap(10)

    -- two rows behind: enough context to know where you are, greyed and
    -- tappable only for jumping back when you lose count.
    for i = math.max(1, self.cursor - 2), self.cursor - 1 do
        local r = list[i]
        if r then
            add(lrRow(cw, h_row, string.format("  %d  %s", r.n, r.text), r.done and "done" or "",
                faceFull(SIZE_META), faceFull(SIZE_META), true), h_row, { kind = "goto", index = i })
        end
    end

    -- the current row, framed and large. This is the only thing on the screen
    -- meant to be read from a distance while your hands are working.
    local cur = list[self.cursor]
    if cur then
        local inner = {}
        inner[#inner + 1] = LeftContainer:new { dimen = { w = cw - Screen:scaleBySize(26), h = h_meta },
            TextWidget:new { text = tostring(cur.n), face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } }
        inner[#inner + 1] = VerticalSpan:new { width = Screen:scaleBySize(6) }
        -- Long instructions wrap instead of being cut: a truncated round is a
        -- ruined round.
        local TextBoxWidget = require("ui/widget/textboxwidget")
        inner[#inner + 1] = TextBoxWidget:new {
            text = cur.text,
            face = faceFull(SIZE_TITLE),
            width = cw - Screen:scaleBySize(26),
            alignment = "left",
        }
        if cur.repeat_of then
            inner[#inner + 1] = VerticalSpan:new { width = Screen:scaleBySize(8) }
            inner[#inner + 1] = RightContainer:new { dimen = { w = cw - Screen:scaleBySize(26), h = h_meta },
                TextWidget:new {
                    text = string.format("powtórzenie %d z %d", cur.repeat_i, cur.repeat_of),
                    face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5,
                } }
        end
        add(FrameContainer:new {
            bordersize = Screen:scaleBySize(2), padding = Screen:scaleBySize(11),
            width = cw, radius = 0,
            VerticalGroup:new { align = "left", unpack(inner) },
        }, h_big * 2)
    else
        add(CenterContainer:new { dimen = { w = cw, h = h_big },
            TextWidget:new { text = "gotowe — cały wzór zrobiony", face = faceFull(SIZE_ROW) } }, h_big)
    end

    -- three rows ahead: what is coming, inert.
    gap(8)
    for i = self.cursor + 1, math.min(total, self.cursor + 3) do
        local r = list[i]
        if r then
            add(LeftContainer:new { dimen = { w = cw, h = h_row },
                TextWidget:new {
                    text = string.format("  %d  %s", r.n, r.text),
                    face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = cw,
                } }, h_row)
        end
    end

    -- the two buttons, side by side and as large as the screen allows
    gap(10)
    local bw = math.floor((cw - Screen:scaleBySize(10)) / 2)
    local buttons = OverlapGroup:new { dimen = { w = cw, h = h_row + Screen:scaleBySize(22) } }
    table.insert(buttons, LeftContainer:new { dimen = { w = cw, h = h_row + Screen:scaleBySize(22) },
        FrameContainer:new { bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(10),
            width = bw, radius = 0, background = Blitbuffer.COLOR_BLACK,
            CenterContainer:new { dimen = { w = bw - Screen:scaleBySize(22), h = h_row },
                TextWidget:new { text = "ZROBIONE", face = faceFull(SIZE_ROW), fgcolor = Blitbuffer.COLOR_WHITE } } } })
    table.insert(buttons, RightContainer:new { dimen = { w = cw, h = h_row + Screen:scaleBySize(22) },
        FrameContainer:new { bordersize = Screen:scaleBySize(1), padding = Screen:scaleBySize(10),
            width = bw, radius = 0,
            CenterContainer:new { dimen = { w = bw - Screen:scaleBySize(22), h = h_row },
                TextWidget:new { text = "COFNIJ", face = faceFull(SIZE_ROW) } } } })
    -- One tap target per half, split down the middle.
    local by = y
    add(buttons, h_row + Screen:scaleBySize(22))
    self.hit[#self.hit + 1] = { y1 = by, y2 = y, x2 = pad + bw, kind = "done" }
    self.hit[#self.hit + 1] = { y1 = by, y2 = y, x1 = pad + bw, kind = "undo_row" }

    -- how long the screen will stay awake, so it is never a mystery
    gap(8)
    add(rule(cw), Screen:scaleBySize(2))
    local awake = "ekran gaśnie normalnie · dotknij, by zmienić"
    if self.awake_until then
        local left = math.max(0, math.floor((self.awake_until - os.time()) / 60))
        awake = string.format("ekran nie gaśnie · %d min", left)
    end
    add(CenterContainer:new { dimen = { w = cw, h = h_meta },
        TextWidget:new { text = awake, face = faceFull(SIZE_META), fgcolor = Blitbuffer.COLOR_GRAY_5 } },
        h_meta, { kind = "awake" })

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
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
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
        self.plugin:act("craft_row", row.id, { done = true })
        return true

    elseif t.kind == "undo_row" then
        local i = math.max(1, self.cursor - 1)
        local row = self.pattern.rows[i]
        if not row then return true end
        track("craft", "row_undo", tostring(row.n))
        row.done = false
        self.cursor = i
        self:redraw()
        self.plugin:act("craft_row", row.id, { done = false })
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

function ReadingOS:openPattern(id)
    local data = decode(request("GET", baseUrl() .. "/api/readingos/crafts/" .. tostring(id)))
    if type(data) ~= "table" or type(data.rows) ~= "table" or #data.rows == 0 then
        UIManager:show(InfoMessage:new { text = _("Nie udało się pobrać wzoru.") })
        return
    end
    -- Flatten the repeat marker: nested tables in a hot redraw path are a
    -- needless indirection on a 1 GHz CPU.
    for _i, r in ipairs(data.rows) do
        if type(r.repeat_) == "table" then r.repeat_i, r.repeat_of = r.repeat_.i, r.repeat_.of end
        if type(r["repeat"]) == "table" then r.repeat_i, r.repeat_of = r["repeat"].i, r["repeat"].of end
    end
    track("craft", "open", data.title)
    UIManager:show(CraftView:new { plugin = self, pattern = data }, "full")
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

function ReadingOS:showDashboard()
    if getToken() == "" then
        UIManager:show(InfoMessage:new {
            text = _("Brak tokenu API. Wrzuć readingos-token.txt do folderu koreader albo ustaw go w Narzędzia → ReadingOS."),
        })
        return
    end

    local data, age, err = self:fetch()
    if not data then
        UIManager:show(InfoMessage:new { text = _("ReadingOS nieosiągalny: ") .. tostring(err or "?") })
        return
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

return ReadingOS
