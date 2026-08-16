-- DICK/OS minimal init
-- Version: 0.1.0-unstable

local VERSION_PATH = "/dickos/etc/version"
local HOSTNAME_PATH = "/dickos/etc/hostname"
local MACHINE_ID_PATH = "/dickos/etc/machine-id"
local STAGE0_RESTART_RESULT = "restart"

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

local BOOT_FRAMES_PER_STAGE = 4
local BOOT_FRAME_DELAY = 0.05

-- ASCII art is stored as a numerically indexed table of strings. `ipairs`
-- visits those strings from first to last, which lets drawMascot render one
-- terminal row at a time without embedding cursor movement inside the art.
-- The mascot is intentionally only eight columns wide so it fits beside system
-- information on the standard Advanced Computer terminal.
local HAPPY_DICK = {
    "   ____",
    "  /+ + \\",
    "  \\ U  /",
    "   |  |",
    "   |  |",
    "  (_)(_)",
}

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

local function drawHorizontalRule(row)
    local terminalWidth = term.getSize()

    writeAt(1, row, string.rep("-", terminalWidth), SEPARATOR_COLOR)
end

-- Draw a mascot by placing each table entry on the next terminal row.
-- Keeping this helper unaware of the art itself allows the same ready-screen
-- layout to use a different mascot state later without changing coordinates.
local function drawMascot(art, x, y, color)
    for rowOffset, line in ipairs(art) do
        writeAt(x, y + rowOffset - 1, line, color)
    end
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

local function drawBootHeader(version)
    prepareTerminal()

    writeAt(2, 1, "DICK/OS", PRIMARY_TEXT)
    writeAt(10, 1, version, SECONDARY_TEXT)
    drawHorizontalRule(2)
    writeAt(
        2,
        3,
        "Distributed Infrastructure & Computer Kit",
        INFORMATION_COLOR
    )
    drawHorizontalRule(4)
    writeAt(2, 6, "BOOTSTRAP SEQUENCE", PRIMARY_TEXT)
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
        drawBootStage(stage, 6 + stageIndex)
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

local function drawReadyScreen(version, hostname, machineID)
    prepareTerminal()

    writeAt(14, 2, "DICK/OS", INFORMATION_COLOR)
    writeAt(14, 3, version, SECONDARY_TEXT)

    drawMascot(HAPPY_DICK, 3, 4, SUCCESS_COLOR)
    drawInformationField(14, 5, "Hostname:", hostname)
    drawInformationField(14, 6, "Machine ID:", machineID)
    writeAt(14, 9, "SYSTEM READY", SUCCESS_COLOR)

    drawHorizontalRule(12)
    writeAt(2, 14, "Bootstrap environment active.", INFORMATION_COLOR)
    writeAt(
        2,
        16,
        "Future DICK shell handoff is not installed yet.",
        SECONDARY_TEXT
    )
end

prepareTerminal()

local version = requireValue(VERSION_PATH, "DICK/OS version")
local hostname = requireValue(HOSTNAME_PATH, "hostname")
local machineID = requireValue(MACHINE_ID_PATH, "machine ID")

drawBootHeader(version)

if not animateBootProgress() then
    return STAGE0_RESTART_RESULT
end

drawReadyScreen(version, hostname, machineID)

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
        return STAGE0_RESTART_RESULT
    end
end
