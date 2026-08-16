-- DICK/OS Stage-0 boot supervisor
-- Version: 0.1.0-unstable

-- Stage-0 is deliberately small. Its job is to keep control of the boot path,
-- not to implement normal operating-system features. Authentication, services,
-- networking, hardware discovery, and the future shell belong below init.
local INIT_PATH = "/dickos/system/init.lua"
local RECOVERY_PATH = "/dickos/system/recovery.lua"

local INIT_RESTART_RESULT = "restart"
local RECOVERY_RETRY_RESULT = "retry"
local RECOVERY_RESCUE_RESULT = "rescue"

local FALLBACK_BACKGROUND = colors.red
local FALLBACK_BORDER = colors.yellow
local FALLBACK_PRIMARY_TEXT = colors.white
local FALLBACK_SECONDARY_TEXT = colors.lightGray

-- Emergency Fallback cannot load branding from init, Recovery, or a future UI
-- library because those components may be the reason boot failed. Its compact
-- sad mascot therefore remains inside Stage-0 as a table of strings. `ipairs`
-- later draws the entries in numeric order, one terminal row per string.
local FALLBACK_SAD_DICK = {
    "   ____",
    "  /+ + \\",
    "  \\ n  /",
    "   |  |",
    "   |  |",
    "  (_)(_)",
}

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Convert an error into readable diagnostic text.
--
-- Ordinary Lua errors are often strings. Current CraftOS versions may instead
-- preserve richer errors as exception tables with a `message` field. Reading
-- that field when present keeps useful diagnostics without making Stage-0
-- depend on the rest of the exception implementation.
local function describeError(errorValue)
    if type(errorValue) == "table" and type(errorValue.message) == "string" then
        return errorValue.message
    end

    return tostring(errorValue)
end

-- Load and execute one DICK/OS program under protected execution.
--
-- `loadfile` compiles a Lua file and returns a callable function. If the file
-- is syntactically invalid, it instead returns nil plus an error message and no
-- program is run. `pcall` then invokes a successfully loaded function. Its
-- first return value is true when the child returned normally and false when
-- the child raised an error; following return values contain either the
-- child's results or its error value.
-- CC:T supports yielding through pcall, so init may wait for events for an
-- arbitrary time while this protected call remains active.
--
-- This protection is what lets Stage-0 survive a broken init or recovery.
-- Errors inside those child programs are ordinary boot failures. An error in
-- the supervisor itself is different and is caught by the outer guard at the
-- bottom of this file.
local function runProtected(path, ...)
    local program, loadError = loadfile(path)

    if program == nil then
        return false, "Unable to load " .. path .. ": " .. tostring(loadError)
    end

    return pcall(program, ...)
end

-- Attempt one normal boot and describe what Stage-0 should do next.
--
-- State strings make the control flow explicit. In particular, an expected
-- Ctrl+T path returns `restart`, while every other normal return is considered
-- unexpected. The supervisor loop consumes these states without recursively
-- launching another startup.lua, so repeated retries cannot grow Lua's call
-- stack forever.
local function attemptNormalBoot()
    if not fs.exists(INIT_PATH) then
        return "recovery", "Required init is missing: " .. INIT_PATH
    end

    local initSucceeded, initResult = runProtected(INIT_PATH)

    if not initSucceeded then
        return "recovery", "init crashed: " .. describeError(initResult)
    end

    if initResult == INIT_RESTART_RESULT then
        return "restart", nil
    end

    return "recovery", "init returned unexpectedly without reboot or shutdown."
end

-- The helpers below deliberately duplicate a small amount of Recovery UI
-- code. Emergency Fallback exists specifically for missing or broken normal
-- components, so depending on recovery.lua, init.lua, or a shared DICK/OS
-- library would make the last-resort screen fail for the same reason. This is
-- a narrow reliability exception to DRY, not the start of a Stage-0 UI engine.

-- Write clipped text at one-based terminal coordinates. CC:T reports width and
-- height through `term.getSize`; clipping prevents diagnostics from wrapping
-- through the right border of the standard Advanced Computer display.
local function writeFallbackAt(x, y, text, color)
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

-- Draw the red fallback background and a reliable ASCII border. The interior
-- is filled when `term.clear` runs with the red background already selected;
-- only the edge characters need to be written afterwards.
local function drawFallbackBox()
    local terminalWidth, terminalHeight = term.getSize()
    local horizontalEdge = "+" ..
        string.rep("-", terminalWidth - 2) .. "+"

    term.setBackgroundColor(FALLBACK_BACKGROUND)
    term.setTextColor(FALLBACK_PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)

    writeFallbackAt(1, 1, horizontalEdge, FALLBACK_BORDER)
    writeFallbackAt(1, terminalHeight, horizontalEdge, FALLBACK_BORDER)

    for row = 2, terminalHeight - 1 do
        writeFallbackAt(1, row, "|", FALLBACK_BORDER)
        writeFallbackAt(terminalWidth, row, "|", FALLBACK_BORDER)
    end
end

local function drawFallbackMascot(x, y)
    for rowOffset, line in ipairs(FALLBACK_SAD_DICK) do
        writeFallbackAt(
            x,
            y + rowOffset - 1,
            line,
            FALLBACK_BORDER
        )
    end
end

-- Wrap on a nearby space when possible, or split by character when one token
-- is wider than the diagnostic area. Newlines start a new paragraph. Limiting
-- the returned table to `maximumLines` keeps the fixed menu visible, and an
-- ellipsis makes truncation explicit.
local function wrapFallbackText(text, lineWidth, maximumLines)
    local wrappedLines = {}
    local paragraphs = tostring(text) .. "\n"

    for paragraph in string.gmatch(paragraphs, "(.-)\n") do
        paragraph = string.gsub(paragraph, "^%s+", "")

        while #paragraph > lineWidth do
            local candidate = string.sub(paragraph, 1, lineWidth)
            local splitPosition = string.match(candidate, "^.*()%s")

            if splitPosition == nil or splitPosition < 2 then
                splitPosition = lineWidth + 1
            end

            local line = string.sub(paragraph, 1, splitPosition - 1)
            line = string.gsub(line, "%s+$", "")
            wrappedLines[#wrappedLines + 1] = line

            paragraph = string.sub(paragraph, splitPosition)
            paragraph = string.gsub(paragraph, "^%s+", "")
        end

        wrappedLines[#wrappedLines + 1] = paragraph
    end

    if #wrappedLines > maximumLines then
        while #wrappedLines > maximumLines do
            table.remove(wrappedLines)
        end

        local lastLine = wrappedLines[maximumLines]
        wrappedLines[maximumLines] =
            string.sub(lastLine, 1, lineWidth - 3) .. "..."
    end

    return wrappedLines
end

local function drawFallbackWrappedText(x, y, text, width, maximumLines)
    local lines = wrapFallbackText(text, width, maximumLines)

    for lineIndex, line in ipairs(lines) do
        writeFallbackAt(
            x,
            y + lineIndex - 1,
            line,
            FALLBACK_PRIMARY_TEXT
        )
    end
end

local function drawFallbackMenuItem(row, number, label)
    writeFallbackAt(3, row, tostring(number) .. ".", FALLBACK_BORDER)
    writeFallbackAt(6, row, label, FALLBACK_PRIMARY_TEXT)
end

-- Draw both failure levels separately: the Recovery failure explains why this
-- last-resort UI is active, while the original boot failure explains why init
-- could not continue. The menu remains at fixed rows near the bottom.
local function drawEmergencyFallbackScreen(
    recoveryFailureReason,
    originalBootFailureReason,
    notice
)
    local terminalWidth, terminalHeight = term.getSize()
    local diagnosticWidth = math.max(10, terminalWidth - 13)
    local menuStart = terminalHeight - 8
    local mascotX = math.max(3, terminalWidth - 9)

    drawFallbackBox()
    writeFallbackAt(3, 2, "DICK/OS EMERGENCY FALLBACK", FALLBACK_PRIMARY_TEXT)
    writeFallbackAt(3, 3, "CRITICAL BOOT FAILURE", FALLBACK_BORDER)
    drawFallbackMascot(mascotX, 2)

    writeFallbackAt(3, 5, "Recovery failure:", FALLBACK_BORDER)
    drawFallbackWrappedText(
        3,
        6,
        recoveryFailureReason,
        diagnosticWidth,
        2
    )

    writeFallbackAt(3, 8, "Original boot failure:", FALLBACK_BORDER)
    drawFallbackWrappedText(
        3,
        9,
        originalBootFailureReason or
            "Unavailable because Stage-0 itself failed.",
        diagnosticWidth,
        2
    )

    drawFallbackMenuItem(menuStart, 1, "Retry normal boot")
    drawFallbackMenuItem(menuStart + 1, 2, "Enter CraftOS rescue shell")
    drawFallbackMenuItem(menuStart + 2, 3, "Reboot")
    drawFallbackMenuItem(menuStart + 3, 4, "Shutdown")

    if notice ~= nil then
        writeFallbackAt(
            3,
            terminalHeight - 4,
            notice,
            FALLBACK_SECONDARY_TEXT
        )
    end
end

-- Read fallback input without allowing Ctrl+T to escape Stage-0.
-- CraftOS `read` normally raises an error when it receives a terminate event.
-- `pcall` converts that error into false plus the error value, so the fallback
-- loop can redraw instead of accidentally returning to the CraftOS prompt.
local function readFallbackInput(promptText)
    local _, terminalHeight = term.getSize()

    writeFallbackAt(
        3,
        terminalHeight - 2,
        promptText,
        FALLBACK_PRIMARY_TEXT
    )
    term.setCursorBlink(true)
    local inputSucceeded, inputOrError = pcall(read)
    term.setCursorBlink(false)

    if inputSucceeded then
        return inputOrError, nil
    end

    return nil, inputOrError
end

-- Provide the smallest viable recovery path when recovery.lua cannot run.
-- Result strings and power actions are unchanged from the tested Milestone 2
-- control flow; only the presentation and separate diagnostic arguments differ.
local function runEmergencyFallback(
    recoveryFailureReason,
    originalBootFailureReason
)
    local notice = nil

    while true do
        drawEmergencyFallbackScreen(
            recoveryFailureReason,
            originalBootFailureReason,
            notice
        )

        local choice, inputError = readFallbackInput("Select: ")

        if choice == "1" then
            return RECOVERY_RETRY_RESULT
        elseif choice == "2" then
            drawEmergencyFallbackScreen(
                recoveryFailureReason,
                originalBootFailureReason,
                "Explicit rescue leaves DICK/OS supervision."
            )

            local confirmation, confirmationError = readFallbackInput(
                "Enter CraftOS rescue shell? [y/N]: "
            )

            if confirmation ~= nil then
                confirmation = string.lower(confirmation)

                if confirmation == "y" or confirmation == "yes" then
                    return RECOVERY_RESCUE_RESULT
                end

                notice = "CraftOS rescue cancelled."
            else
                notice = "Input interrupted; Stage-0 remains active: " ..
                    describeError(confirmationError)
            end
        elseif choice == "3" then
            os.reboot()
        elseif choice == "4" then
            os.shutdown()
        elseif choice ~= nil then
            notice = "Unknown selection. Choose 1, 2, 3, or 4."
        else
            notice = "Input interrupted; Stage-0 remains active: " ..
                describeError(inputError)
        end
    end
end

-- Run Recovery under the same protection as init.
-- Missing, crashing, or unexpectedly returning recovery code cannot make
-- startup.lua finish. Those paths enter the built-in emergency fallback.
local function requestRecovery(bootFailureReason)
    if not fs.exists(RECOVERY_PATH) then
        return runEmergencyFallback(
            "Required recovery program is missing: " .. RECOVERY_PATH,
            bootFailureReason
        )
    end

    local recoverySucceeded, recoveryResult = runProtected(
        RECOVERY_PATH,
        bootFailureReason
    )

    if not recoverySucceeded then
        return runEmergencyFallback(
            "recovery.lua crashed: " .. describeError(recoveryResult),
            bootFailureReason
        )
    end

    if recoveryResult == RECOVERY_RETRY_RESULT or
        recoveryResult == RECOVERY_RESCUE_RESULT then
        return recoveryResult
    end

    return runEmergencyFallback(
        "recovery.lua returned an invalid result: " ..
            describeError(recoveryResult),
        bootFailureReason
    )
end

-- Supervise normal boot for as long as DICK/OS owns the machine.
-- Each pass through this loop is a fresh init attempt. A retry changes loop
-- state; it does not call Stage-0 again and therefore is not recursive.
local function superviseBoot()
    while true do
        local bootState, bootFailureReason = attemptNormalBoot()

        if bootState ~= "restart" then
            prepareTerminal()
            print("DICK/OS Stage-0")
            print()
            print("[FAIL] init terminated unexpectedly")
            print(bootFailureReason)
            print()
            print("Entering recovery...")

            local recoveryResult = requestRecovery(bootFailureReason)

            if recoveryResult == RECOVERY_RESCUE_RESULT then
                -- This return is intentional. The user explicitly selected the
                -- CraftOS rescue environment, so Stage-0 may now finish and let
                -- the underlying CraftOS startup sequence reach its shell.
                return
            end
        end
    end
end

-- Guard Stage-0's own supervisor loop separately from child execution. A bug
-- in Stage-0 must still lead to an emergency screen instead of an accidental
-- CraftOS prompt. Selecting retry starts a new loop iteration, not recursion.
while true do
    local supervisorSucceeded, supervisorError = pcall(superviseBoot)

    if supervisorSucceeded then
        -- `superviseBoot` returns normally only after explicit rescue choice.
        return
    end

    local fallbackResult = runEmergencyFallback(
        "Stage-0 internal failure: " .. describeError(supervisorError)
    )

    if fallbackResult == RECOVERY_RESCUE_RESULT then
        -- As above, this is the one deliberate path back to CraftOS.
        return
    end
end
