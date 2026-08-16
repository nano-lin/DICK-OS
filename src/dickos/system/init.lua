-- DICK/OS minimal init
-- Version: 0.1.0-unstable

local VERSION_PATH = "/dickos/etc/version"
local HOSTNAME_PATH = "/dickos/etc/hostname"
local MACHINE_ID_PATH = "/dickos/etc/machine-id"
local DICKFETCH_PATH = "/dickos/bin/dickfetch.lua"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local STAGE0_RESTART_RESULT = "restart"
local EXPECTED_RUNTIME_API_VERSION = 1

-- Full DICK/OS supports the Advanced Computer, so its colour terminal is a
-- platform baseline rather than an optional skin. These constants begin a
-- shared visual vocabulary: black for normal operation, cyan for activity,
-- lime for success, white for primary text, and gray for secondary structure.
local BOOT_BACKGROUND = colors.black
local PRIMARY_TEXT = colors.white
local SECONDARY_TEXT = colors.lightGray
local SEPARATOR_COLOR = colors.gray
local INFORMATION_COLOR = colors.lightBlue
local SUCCESS_COLOR = colors.lime
local WARNING_COLOR = colors.yellow

-- CC:T's bytes 128 through 159 are native 2-by-3-cell drawing characters.
-- `string.char` creates one such byte, while pasted UTF-8 box characters would
-- become several unrelated terminal glyphs. Some entries use colour inversion
-- because CC:T stores one shape from each foreground/background complement.
local BOX_HORIZONTAL = { character = string.char(140), invertColors = false }
local BOX_VERTICAL_LEFT = { character = string.char(149), invertColors = false }
local BOX_VERTICAL_RIGHT = { character = string.char(149), invertColors = true }
local BOX_TOP_LEFT = { character = string.char(156), invertColors = false }
local BOX_TOP_RIGHT = { character = string.char(147), invertColors = true }
local BOX_BOTTOM_LEFT = { character = string.char(141), invertColors = false }
local BOX_BOTTOM_RIGHT = { character = string.char(142), invertColors = false }
local BOX_LEFT_T = { character = string.char(157), invertColors = false }
local BOX_RIGHT_T = { character = string.char(145), invertColors = true }

local BOOT_FRAMES_PER_STAGE = 4
local BOOT_FRAME_DELAY = 0.05

-- A top-level Lua chunk receives arguments through `...`. Stage-0 passes the
-- same small table on every init attempt made during one supervisor execution.
-- Init reads its Boot ID but does not turn that table into a general state
-- manager and never persists it.
local runtimeContext = ...

-- Load the normal logger behind one complete protected boundary. `loadfile`
-- compiles the module, its returned function executes the module, and
-- `logModule.create` makes the context-bound logger. All three steps, including
-- table access on a malformed replacement module, remain inside `pcall`.
-- Returning nil on any problem turns every later log request into a no-op:
-- diagnostics must never be the reason init enters Recovery.
local function createBestEffortLogger(targetName, context)
    local constructionSucceeded, logger = pcall(function()
        local loggerProgram = loadfile(LOG_LIBRARY_PATH)

        if type(loggerProgram) ~= "function" then
            return nil
        end

        local logModule = loggerProgram()

        if type(logModule) ~= "table" or
            type(logModule.create) ~= "function" then
            return nil
        end

        local createdLogger = logModule.create(targetName, context)

        if type(createdLogger) ~= "table" then
            return nil
        end

        return createdLogger
    end)

    if not constructionSucceeded then
        return nil
    end

    return logger
end

-- Call one level method without trusting either the module or the filesystem.
-- Indexing and invoking the logger happen inside `pcall`, so even a malformed
-- replacement module cannot turn a best-effort diagnostic into boot failure.
local function logBestEffort(logger, level, component, message)
    if logger == nil then
        return
    end

    pcall(function()
        local levelMethod = logger[level]

        if type(levelMethod) == "function" then
            levelMethod(component, message)
        end
    end)
end

local bootLogger = createBestEffortLogger("boot", runtimeContext)
local systemLogger = createBestEffortLogger("system", runtimeContext)

-- Each stage is a small Lua table containing the text shown to the user and
-- its current visual state. This is enough structure for later init work to
-- add real bootstrap stages without creating a generic boot framework now.
-- Every label below describes work which this minimal bootstrap really does.
local BOOT_STAGES = {
    { label = "Stage-0 supervisor", state = "pending" },
    { label = "Version metadata", state = "pending" },
    { label = "Machine identity", state = "pending" },
    { label = "Hostname metadata", state = "pending" },
    { label = "Bootstrap session", state = "pending" },
}

local function prepareTerminal()
    term.setBackgroundColor(BOOT_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Write text at an explicit terminal coordinate.
--
-- CC:T terminal coordinates begin at column 1, row 1. `term.getSize` returns
-- the current width and height, so clipping here prevents a long value from
-- wrapping onto the next row and damaging the surrounding boot layout.
local function writeAt(x, y, text, color)
    local terminalWidth, terminalHeight = term.getSize()

    if x < 1 or x > terminalWidth or y < 1 or y > terminalHeight then
        return
    end

    local availableWidth = terminalWidth - x + 1
    local clippedText = string.sub(tostring(text), 1, availableWidth)

    term.setTextColor(color)
    term.setCursorPos(x, y)
    term.write(clippedText)
end

-- Write one native CC:T drawing character, optionally repeated.
--
-- The drawing-character table records when foreground and background colours
-- must be exchanged to reveal a complementary shape. Restoring the black
-- background afterwards prevents an inverted corner from affecting later
-- ordinary text.
local function writeBoxGlyphAt(x, y, glyph, count)
    local terminalWidth, terminalHeight = term.getSize()

    if x < 1 or x > terminalWidth or y < 1 or y > terminalHeight then
        return
    end

    local repeatCount = math.min(count or 1, terminalWidth - x + 1)
    local textColor = SEPARATOR_COLOR
    local backgroundColor = BOOT_BACKGROUND

    if glyph.invertColors then
        textColor, backgroundColor = backgroundColor, textColor
    end

    term.setTextColor(textColor)
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(x, y)
    term.write(string.rep(glyph.character, repeatCount))
    term.setBackgroundColor(BOOT_BACKGROUND)
end

-- Centre a string between the two vertical frame edges. Lua's `#` operator
-- returns the byte length of these ASCII headings, which is also their CC:T
-- terminal width. `math.floor` places any unavoidable odd spare cell on the
-- right side.
local function writeCenteredInside(row, text, color)
    local terminalWidth = term.getSize()
    local innerWidth = terminalWidth - 2
    local clippedText = string.sub(tostring(text), 1, innerWidth)
    local x = 2 + math.floor((innerWidth - #clippedText) / 2)

    writeAt(x, row, clippedText, color)
end

local function drawBootBox()
    local terminalWidth, terminalHeight = term.getSize()

    prepareTerminal()
    writeBoxGlyphAt(1, 1, BOX_TOP_LEFT)
    writeBoxGlyphAt(2, 1, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, 1, BOX_TOP_RIGHT)
    writeBoxGlyphAt(1, terminalHeight, BOX_BOTTOM_LEFT)
    writeBoxGlyphAt(2, terminalHeight, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, terminalHeight, BOX_BOTTOM_RIGHT)

    for row = 2, terminalHeight - 1 do
        writeBoxGlyphAt(1, row, BOX_VERTICAL_LEFT)
        writeBoxGlyphAt(terminalWidth, row, BOX_VERTICAL_RIGHT)
    end
end

local function drawBootSeparator(row)
    local terminalWidth = term.getSize()

    writeBoxGlyphAt(1, row, BOX_LEFT_T)
    writeBoxGlyphAt(2, row, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, row, BOX_RIGHT_T)
end

-- Read one required metadata line from the installed filesystem.
--
-- `fs.open` is a CC:Tweaked API and returns a file handle rather than the file
-- contents. A failed open returns nil plus a diagnostic message. File-handle
-- operations may raise Lua errors, so read and close are protected separately;
-- the helper then returns either the string value or nil plus an explanation.
-- These are Lua multiple return values, allowing the caller to distinguish an
-- empty result from a failure without relying on global error state.
local function readRequiredValue(path)
    local file, openError = fs.open(path, "r")

    if file == nil then
        return nil, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local readSucceeded, valueOrError = pcall(file.readLine)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        return nil, "Unable to read " .. path .. ": " .. tostring(valueOrError)
    end

    if not closeSucceeded then
        return nil, "Unable to close " .. path .. ": " .. tostring(closeError)
    end

    if valueOrError == nil or valueOrError == "" then
        return nil, "Required metadata is empty: " .. path
    end

    return valueOrError, nil
end

-- Turn a metadata failure into an init failure. Stage-0 runs this entire file
-- through pcall, so propagating an error here does not expose CraftOS: it sends
-- the diagnostic back to Stage-0, which enters Recovery.
local function requireValue(path, description)
    local value, readError = readRequiredValue(path)

    if value == nil then
        error("Unable to load " .. description .. ": " .. readError, 0)
    end

    return value
end

-- Validate the small runtime API supplied by Stage-0.
--
-- `apiVersion` is a compatibility marker, not a negotiation protocol. Init
-- accepts exactly the interface it understands and reports both expected and
-- received values when they differ. The Boot ID pattern then requires `B-`
-- followed by eight uppercase hexadecimal characters. Neither value can be
-- reconstructed from disk, so an invalid context is a real init failure.
-- Every rejection is logged before `error` returns it to Stage-0, but the
-- protected logging wrapper means a logger failure cannot hide that real error.
local function requireRuntimeContext(context)
    if type(context) ~= "table" then
        local contextError =
            "Runtime context missing. Expected Stage-0 runtime API 1."

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    logBestEffort(
        bootLogger,
        "info",
        "init",
        "Runtime context received"
    )

    if context.apiVersion ~= EXPECTED_RUNTIME_API_VERSION then
        local contextError = string.format(
            "Unsupported Stage-0 runtime API. Expected: %d Received: %s",
            EXPECTED_RUNTIME_API_VERSION,
            tostring(context.apiVersion)
        )

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    local bootID = context.bootID

    if type(bootID) ~= "string" or not string.match(
        bootID,
        "^B%-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" ..
            "[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$"
    ) then
        local contextError =
            "Stage-0 runtime context contains an invalid Boot ID."

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    logBestEffort(bootLogger, "info", "init", "Boot ID validated")
    return bootID
end

local function drawBootHeader(version)
    drawBootBox()
    writeCenteredInside(3, "DICK/OS " .. version, PRIMARY_TEXT)
    writeCenteredInside(
        4,
        "Distributed Infrastructure & Computer Kit",
        INFORMATION_COLOR
    )
    drawBootSeparator(6)
    writeAt(3, 8, "BOOTSTRAP SEQUENCE", PRIMARY_TEXT)
end

local function drawBootStage(stage, row)
    local marker = "[    ]"
    local markerColor = SEPARATOR_COLOR
    local labelColor = SECONDARY_TEXT

    if stage.state == "active" then
        marker = "[ .. ]"
        markerColor = INFORMATION_COLOR
        labelColor = PRIMARY_TEXT
    elseif stage.state == "ok" then
        marker = "[ OK ]"
        markerColor = SUCCESS_COLOR
        labelColor = PRIMARY_TEXT
    end

    writeAt(2, row, marker, markerColor)
    writeAt(9, row, stage.label, labelColor)
end

local function drawAllBootStages()
    for stageIndex, stage in ipairs(BOOT_STAGES) do
        drawBootStage(stage, 8 + stageIndex)
    end
end

-- Draw a progress bar sized from the current terminal width.
--
-- `percent / 100` converts the integer percentage into a fraction. Multiplying
-- that fraction by the available bar width tells us how many `#` cells should
-- be filled. The remaining cells use `-`, preserving a package-manager-like
-- sense of activity without copying another project's exact presentation.
local function drawProgressBar(percent, activityLabel)
    local terminalWidth, terminalHeight = term.getSize()
    local labelRow = terminalHeight - 4
    local progressRow = terminalHeight - 3
    local barWidth = math.max(8, terminalWidth - 10)
    local filledWidth = math.floor((percent / 100) * barWidth + 0.5)
    local emptyWidth = barWidth - filledWidth

    writeAt(2, labelRow, string.rep(" ", terminalWidth - 2), PRIMARY_TEXT)
    writeAt(2, labelRow, "Activity: " .. activityLabel, INFORMATION_COLOR)

    writeAt(2, progressRow, "[", SECONDARY_TEXT)
    writeAt(3, progressRow, string.rep("#", filledWidth), INFORMATION_COLOR)
    writeAt(
        3 + filledWidth,
        progressRow,
        string.rep("-", emptyWidth),
        SEPARATOR_COLOR
    )
    writeAt(3 + barWidth, progressRow, "]", SECONDARY_TEXT)
    writeAt(
        5 + barWidth,
        progressRow,
        string.format("%3d%%", percent),
        PRIMARY_TEXT
    )
end

-- Wait for one cosmetic animation frame without losing terminate handling.
--
-- `os.startTimer` queues a future timer event. `os.pullEventRaw` waits without
-- converting Ctrl+T into an immediate Lua error, allowing this helper to return
-- false when it sees `terminate`. Init can then return Stage-0's established
-- `restart` result even when Ctrl+T occurs during the animation rather than the
-- later bootstrap wait-loop. Other events are intentionally ignored here.
local function waitForBootFrame()
    local timerID = os.startTimer(BOOT_FRAME_DELAY)

    while true do
        local eventName, eventID = os.pullEventRaw()

        if eventName == "terminate" then
            return false
        end

        if eventName == "timer" and eventID == timerID then
            return true
        end
    end
end

-- Animate only the visual representation of the already validated bootstrap.
-- Five stages with four short frames each produce roughly one second of visual
-- motion on CC:T's tick-based timer. No fake subsystem work is hidden behind
-- this delay, and a later milestone can replace each stage with real work.
local function animateBootProgress()
    local totalFrames = #BOOT_STAGES * BOOT_FRAMES_PER_STAGE

    drawAllBootStages()

    for stageIndex, stage in ipairs(BOOT_STAGES) do
        stage.state = "active"
        drawAllBootStages()

        for frameIndex = 1, BOOT_FRAMES_PER_STAGE do
            local completedFrames =
                (stageIndex - 1) * BOOT_FRAMES_PER_STAGE + frameIndex
            local percent = math.floor((completedFrames / totalFrames) * 100)

            drawProgressBar(percent, stage.label)

            if not waitForBootFrame() then
                return false
            end
        end

        stage.state = "ok"
        drawAllBootStages()
    end

    drawProgressBar(100, "Bootstrap complete")
    return true
end

local function drawInformationField(x, y, label, value)
    writeAt(x, y, label, SECONDARY_TEXT)
    writeAt(x + 12, y, value, PRIMARY_TEXT)
end

-- Load the post-boot presentation as a separate utility.
--
-- `loadfile` returns nil plus a compile diagnostic when dickfetch is missing or
-- syntactically invalid. `pcall` then converts a runtime rendering error into a
-- false result. Unlike metadata failures, either presentation failure is
-- noncritical: the caller can draw a minimal status view and keep init alive.
local function runDickfetch(context)
    local dickfetchProgram, loadError = loadfile(DICKFETCH_PATH)

    if dickfetchProgram == nil then
        return false, "Unable to load dickfetch: " .. tostring(loadError)
    end

    local runSucceeded, runError = pcall(dickfetchProgram, context)

    if not runSucceeded then
        return false, "dickfetch failed: " .. tostring(runError)
    end

    return true, nil
end

-- Show required identity values even when the richer dickfetch presentation
-- cannot run. This keeps a cosmetic utility failure visibly degraded but does
-- not misreport healthy metadata as a catastrophic boot failure.
local function drawDickfetchFallback(context, presentationError)
    prepareTerminal()

    writeAt(3, 2, "DICK/OS", INFORMATION_COLOR)
    writeAt(3, 3, context.version, SECONDARY_TEXT)
    drawInformationField(3, 5, "Hostname:", context.hostname)
    drawInformationField(3, 6, "Machine ID:", context.machineID)
    drawInformationField(3, 7, "Boot ID:", context.bootID)
    writeAt(3, 9, "SYSTEM READY", SUCCESS_COLOR)
    writeAt(3, 11, "[WARN] dickfetch presentation unavailable", WARNING_COLOR)
    writeAt(
        3,
        12,
        presentationError,
        SECONDARY_TEXT
    )
end

prepareTerminal()
logBestEffort(bootLogger, "info", "init", "init started")

local bootID = requireRuntimeContext(runtimeContext)
local version = requireValue(VERSION_PATH, "DICK/OS version")
logBestEffort(bootLogger, "info", "init", "Version metadata loaded")
local hostname = requireValue(HOSTNAME_PATH, "hostname")
logBestEffort(bootLogger, "info", "init", "Hostname metadata loaded")
local machineID = requireValue(MACHINE_ID_PATH, "machine ID")
logBestEffort(bootLogger, "info", "init", "Machine ID metadata loaded")

logBestEffort(bootLogger, "info", "init", "Normal boot UI starting")
drawBootHeader(version)

if not animateBootProgress() then
    logBestEffort(
        bootLogger,
        "warn",
        "init",
        "Terminate event received during boot UI; requesting init restart"
    )
    return STAGE0_RESTART_RESULT
end

-- Init adds persistent installation metadata to Stage-0's runtime-only Boot ID
-- and passes one explicit presentation interface to dickfetch. The table is
-- not saved and is intentionally smaller than a general session-state object.
local dickfetchContext = {
    version = version,
    hostname = hostname,
    machineID = machineID,
    bootID = bootID,
}
logBestEffort(bootLogger, "info", "init", "dickfetch starting")
local presentationSucceeded, presentationError = runDickfetch(dickfetchContext)

if not presentationSucceeded then
    logBestEffort(
        bootLogger,
        "warn",
        "dickfetch",
        "Presentation failure: " .. tostring(presentationError)
    )
    drawDickfetchFallback(dickfetchContext, presentationError)
end

logBestEffort(bootLogger, "info", "init", "Bootstrap session ready")
logBestEffort(systemLogger, "info", "init", "Bootstrap session ready")

-- This point is the deliberate future session handoff. A later milestone may
-- replace the bootstrap wait-loop below with a real DICK shell/session entry
-- function. Until that subsystem exists, init remains active without offering
-- fake commands or returning control to CraftOS.
--
-- CC:T programs cooperate through an event queue. `os.pullEventRaw` pauses this
-- process until the next event arrives, so init does not burn CPU while idle.
-- Unlike `os.pullEvent`, the Raw variant returns the `terminate` event produced
-- by Ctrl+T instead of immediately raising the "Terminated" error.
while true do
    local eventName = os.pullEventRaw()

    if eventName == "terminate" then
        local restartMessage =
            "Terminate event received; requesting init restart"

        logBestEffort(bootLogger, "warn", "init", restartMessage)
        logBestEffort(systemLogger, "warn", "init", restartMessage)
        return STAGE0_RESTART_RESULT
    end
end
