-- DICK/OS Stage-0 boot supervisor
-- Version: 0.1.0-unstable

-- Stage-0 is deliberately small. Its job is to keep control of the boot path,
-- not to implement normal operating-system features. Authentication, services,
-- networking, hardware discovery, and the future shell belong below init.
local INIT_PATH = "/dickos/system/init.lua"
local RECOVERY_PATH = "/dickos/system/recovery.lua"
local BOOT_LOG_PATH = "/dickos/var/log/boot.log"
local BOOT_LOG_MAXIMUM_BYTES = 64 * 1024
local RUNTIME_CONTEXT_API_VERSION = 1

-- This forward declaration lets the autonomous logging closure see the one
-- context table assigned after Boot ID generation. Stage-0 does not call the
-- logger before that assignment. Supervisor functions still receive the table
-- explicitly so its retry lifetime remains visible in normal control flow.
local runtimeContext

local INIT_RESTART_RESULT = "restart"
local RECOVERY_RETRY_RESULT = "retry"
local RECOVERY_RESCUE_RESULT = "rescue"

local FALLBACK_BACKGROUND = colors.red
local FALLBACK_BORDER = colors.yellow
local FALLBACK_PRIMARY_TEXT = colors.white
local FALLBACK_SECONDARY_TEXT = colors.lightGray

-- CC:T reserves byte values 128 through 159 for 2-by-3-cell drawing
-- characters. They are single terminal characters, unlike UTF-8 box glyphs
-- whose several bytes would be rendered separately as garbage. Each table
-- below gives a semantic name to one drawing character and records whether
-- its foreground and background colours must be exchanged to obtain the
-- complementary shape stored in the font.
--
-- These shapes form a clean single-line frame in CC:T's native font. Their
-- exact pixel alignment still needs visual verification in Minecraft because
-- a desktop editor cannot reproduce CC:T's terminal renderer.
local BOX_HORIZONTAL = { character = string.char(140), invertColors = false }
local BOX_VERTICAL_LEFT = { character = string.char(149), invertColors = false }
local BOX_VERTICAL_RIGHT = { character = string.char(149), invertColors = true }
local BOX_TOP_LEFT = { character = string.char(156), invertColors = false }
local BOX_TOP_RIGHT = { character = string.char(147), invertColors = true }
local BOX_BOTTOM_LEFT = { character = string.char(141), invertColors = false }
local BOX_BOTTOM_RIGHT = { character = string.char(142), invertColors = false }

-- Stage-0 deliberately does not load `/dickos/lib/log.lua`. Init, Recovery,
-- or that library may be missing or damaged, and the last-resort supervisor
-- must remain able to report the original boot failure. This small duplicate
-- append path is therefore an architectural reliability boundary, not a
-- general logging subsystem hidden inside startup.lua.

-- Replace record-breaking characters before writing a one-line event. Lua's
-- `string.gsub` returns the modified string (and also a replacement count,
-- which this assignment intentionally ignores). Preserving the remaining text
-- keeps low-level error details useful without letting one error resemble
-- several log records.
local function sanitizeLogField(value)
    local text = tostring(value)

    return string.gsub(text, "[\r\n]+", " | ")
end

-- Convert CC:T's UTC epoch milliseconds into the ISO-like timestamp used by
-- normal DICK/OS logs. `os.date` accepts seconds, so the epoch value is divided
-- by 1000. The `!` prefix explicitly selects UTC rather than server-local time.
local function currentUTCTimestamp()
    local epochSeconds = os.epoch("utc") / 1000

    return os.date("!%Y-%m-%dT%H:%M:%SZ", epochSeconds)
end

-- Append raw marker or record text to boot.log with one bounded `.1` file.
--
-- Every filesystem operation is inside `pcall`. A protected call returns a
-- boolean instead of allowing an error to escape, and that result is
-- intentionally ignored here: missing directories, a full disk, rotation
-- failure, and write failure must not change Stage-0 control flow. The active
-- log is rotated before this append would exceed 64 KiB.
local function appendStage0LogText(text)
    pcall(function()
        local contents = tostring(text)
        local truncationSuffix = "[TRUNCATED]\n"

        -- A single Lua error may contain arbitrarily long text. Limit that one
        -- append too, otherwise a record larger than 64 KiB could defeat file
        -- rotation by filling a new active log on its own.
        if #contents > BOOT_LOG_MAXIMUM_BYTES then
            local retainedBytes =
                BOOT_LOG_MAXIMUM_BYTES - #truncationSuffix

            contents = string.sub(contents, 1, retainedBytes) ..
                truncationSuffix
        end

        if fs.exists(BOOT_LOG_PATH) and
            fs.getSize(BOOT_LOG_PATH) + #contents >
                BOOT_LOG_MAXIMUM_BYTES then
            local rotatedPath = BOOT_LOG_PATH .. ".1"

            if fs.exists(rotatedPath) then
                fs.delete(rotatedPath)
            end

            fs.move(BOOT_LOG_PATH, rotatedPath)
        end

        local file = fs.open(BOOT_LOG_PATH, "a")

        if file == nil then
            return
        end

        pcall(file.write, contents)
        pcall(file.close)
    end)
end

-- Write one standard Stage-0 event. This function is protected separately
-- from the append helper because timestamp or string formatting can also fail;
-- logging remains disposable while boot supervision remains authoritative.
local function stage0Log(level, component, message)
    pcall(function()
        local record = string.format(
            "%s [%s] [%s] [%s] %s\n",
            currentUTCTimestamp(),
            sanitizeLogField(runtimeContext and runtimeContext.bootID or
                "UNKNOWN"),
            sanitizeLogField(level),
            sanitizeLogField(component),
            sanitizeLogField(message)
        )

        appendStage0LogText(record)
    end)
end

-- A marker is emitted once per execution of startup.lua, outside every retry
-- loop. Init restarts and Recovery retries therefore add records beneath the
-- same marker and keep the same Boot ID. A fresh CraftOS startup executes this
-- chunk again and appends a new marker.
local function appendBootMarker(bootID)
    pcall(function()
        local marker = table.concat({
            "==================================================",
            "BOOT START",
            "Boot ID: " .. sanitizeLogField(bootID),
            "CC ID: " .. sanitizeLogField(os.getComputerID()),
            "==================================================",
            "",
        }, "\n")

        appendStage0LogText(marker)
    end)
end

-- Generate one temporary identity for this execution of Stage-0.
--
-- A seed is the starting value from which Lua's pseudo-random number generator
-- produces a repeatable sequence. `math.randomseed` explicitly resets that
-- global generator, so Boot ID generation does not depend on an unknown
-- sequence left behind by CraftOS or another startup program. UTC epoch time
-- changes between ordinary starts, while the CC computer ID helps separate
-- computers which start at nearly the same moment.
--
-- Calling `math.randomseed` also changes Lua's process-wide random sequence.
-- Lua does not expose a separate standard generator object which could be
-- seeded locally. No current Stage-0 or init behaviour depends on preserving
-- the earlier sequence, so this known side effect is retained rather than
-- adding a custom pseudo-random generator during a narrow regression fix.
--
-- This is not cryptographic protection: the inputs are observable, the
-- generator is predictable, and collisions remain possible. A Boot ID is only
-- a best-effort label for one live installation execution, not a password,
-- authentication token, or permanent identity. That level of uniqueness is
-- sufficient for the current runtime identifier and can be replaced later
-- without changing the Stage-0 supervisor contract.
local function generateBootID()
    local hexadecimalDigits = "0123456789ABCDEF"
    local identifierCharacters = {}
    local ccID = os.getComputerID()
    local seed = os.epoch("utc") + ccID * 65537

    math.randomseed(seed)

    for position = 1, 8 do
        local digitIndex = math.random(1, #hexadecimalDigits)
        identifierCharacters[position] = string.sub(
            hexadecimalDigits,
            digitIndex,
            digitIndex
        )
    end

    return "B-" .. table.concat(identifierCharacters)
end

-- This table is created once when CraftOS executes startup.lua. The same table
-- is passed to every init attempt made by this supervisor execution, so retry
-- and Ctrl+T restart preserve the Boot ID. It is deliberately never written
-- to the filesystem or settings; a fresh Stage-0 execution creates a new one.
runtimeContext = {
    apiVersion = RUNTIME_CONTEXT_API_VERSION,
    bootID = generateBootID(),
}

appendBootMarker(runtimeContext.bootID)
stage0Log("INFO", "stage0", "Stage-0 started")
stage0Log(
    "INFO",
    "stage0",
    "Generated Boot ID " .. runtimeContext.bootID
)

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
-- stack forever. `runtimeContext` is the table received from the supervisor;
-- this function forwards that exact table to init without copying or changing
-- its Boot ID.
local function attemptNormalBoot(runtimeContext, attemptNumber)
    stage0Log(
        "INFO",
        "stage0",
        "Loading init for normal boot attempt " ..
            tostring(attemptNumber) .. ": " .. INIT_PATH
    )

    if not fs.exists(INIT_PATH) then
        local failureReason = "Required init is missing: " .. INIT_PATH

        stage0Log("ERROR", "stage0", failureReason)
        return "recovery", failureReason
    end

    local initSucceeded, initResult = runProtected(INIT_PATH, runtimeContext)

    if not initSucceeded then
        local failureReason = "init crashed: " .. describeError(initResult)

        stage0Log("ERROR", "stage0", failureReason)
        return "recovery", failureReason
    end

    if initResult == INIT_RESTART_RESULT then
        stage0Log("INFO", "stage0", "init returned restart")
        return "restart", nil
    end

    local failureReason =
        "init returned unexpectedly without reboot or shutdown."

    stage0Log("ERROR", "stage0", failureReason)
    return "recovery", failureReason
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

-- Draw one native CC:T drawing character, optionally repeated.
--
-- Some of CC:T's drawing shapes are stored as the colour-inverse of the shape
-- we need. For those entries, exchanging text and background colours reveals
-- the complementary pixels. The background is restored afterwards so normal
-- fallback text still appears on red.
local function writeFallbackBoxGlyphAt(x, y, glyph, count)
    local terminalWidth, terminalHeight = term.getSize()

    if x < 1 or x > terminalWidth or y < 1 or y > terminalHeight then
        return
    end

    local repeatCount = math.min(count or 1, terminalWidth - x + 1)
    local textColor = FALLBACK_BORDER
    local backgroundColor = FALLBACK_BACKGROUND

    if glyph.invertColors then
        textColor, backgroundColor = backgroundColor, textColor
    end

    term.setTextColor(textColor)
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(x, y)
    term.write(string.rep(glyph.character, repeatCount))
    term.setBackgroundColor(FALLBACK_BACKGROUND)
end

-- Draw the red fallback background and its native semigraphics border. The
-- interior is filled when `term.clear` runs with red already selected; only
-- the edge characters need to be written afterwards.
local function drawFallbackBox()
    local terminalWidth, terminalHeight = term.getSize()

    term.setBackgroundColor(FALLBACK_BACKGROUND)
    term.setTextColor(FALLBACK_PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)

    writeFallbackBoxGlyphAt(1, 1, BOX_TOP_LEFT)
    writeFallbackBoxGlyphAt(2, 1, BOX_HORIZONTAL, terminalWidth - 2)
    writeFallbackBoxGlyphAt(terminalWidth, 1, BOX_TOP_RIGHT)
    writeFallbackBoxGlyphAt(1, terminalHeight, BOX_BOTTOM_LEFT)
    writeFallbackBoxGlyphAt(
        2,
        terminalHeight,
        BOX_HORIZONTAL,
        terminalWidth - 2
    )
    writeFallbackBoxGlyphAt(
        terminalWidth,
        terminalHeight,
        BOX_BOTTOM_RIGHT
    )

    for row = 2, terminalHeight - 1 do
        writeFallbackBoxGlyphAt(1, row, BOX_VERTICAL_LEFT)
        writeFallbackBoxGlyphAt(terminalWidth, row, BOX_VERTICAL_RIGHT)
    end
end

local function drawFallbackSeparator(x, row, width)
    writeFallbackBoxGlyphAt(x, row, BOX_HORIZONTAL, width)
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
    local menuStart = terminalHeight - 7
    local mascotX = math.max(3, terminalWidth - 9)

    drawFallbackBox()
    writeFallbackAt(3, 2, "DICK/OS EMERGENCY FALLBACK", FALLBACK_PRIMARY_TEXT)
    writeFallbackAt(3, 4, "CRITICAL BOOT FAILURE", FALLBACK_BORDER)
    drawFallbackMascot(mascotX, 2)
    drawFallbackSeparator(3, 5, diagnosticWidth)

    writeFallbackAt(3, 6, "Recovery failure:", FALLBACK_BORDER)
    drawFallbackWrappedText(
        3,
        7,
        recoveryFailureReason,
        diagnosticWidth,
        2
    )

    writeFallbackAt(3, 9, "Original boot failure:", FALLBACK_BORDER)
    drawFallbackWrappedText(
        3,
        10,
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
            terminalHeight - 3,
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
            stage0Log("WARN", "fallback", "Emergency Fallback retry selected")
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
                    stage0Log(
                        "WARN",
                        "fallback",
                        "Emergency Fallback CraftOS rescue selected"
                    )
                    return RECOVERY_RESCUE_RESULT
                end

                notice = "CraftOS rescue cancelled."
            else
                notice = "Input interrupted; Stage-0 remains active: " ..
                    describeError(confirmationError)
            end
        elseif choice == "3" then
            stage0Log("WARN", "fallback", "Reboot requested")
            os.reboot()
        elseif choice == "4" then
            stage0Log("WARN", "fallback", "Shutdown requested")
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
local function requestRecovery(bootFailureReason, runtimeContext)
    if not fs.exists(RECOVERY_PATH) then
        local recoveryFailureReason =
            "Required recovery program is missing: " .. RECOVERY_PATH

        stage0Log("ERROR", "stage0", recoveryFailureReason)
        stage0Log(
            "CRITICAL",
            "stage0",
            "Transitioning to Emergency Fallback"
        )
        return runEmergencyFallback(
            recoveryFailureReason,
            bootFailureReason
        )
    end

    local recoverySucceeded, recoveryResult = runProtected(
        RECOVERY_PATH,
        bootFailureReason,
        runtimeContext
    )

    if not recoverySucceeded then
        local recoveryFailureReason =
            "recovery.lua crashed: " .. describeError(recoveryResult)

        stage0Log("ERROR", "stage0", recoveryFailureReason)
        stage0Log(
            "CRITICAL",
            "stage0",
            "Transitioning to Emergency Fallback"
        )
        return runEmergencyFallback(
            recoveryFailureReason,
            bootFailureReason
        )
    end

    if recoveryResult == RECOVERY_RETRY_RESULT then
        stage0Log("WARN", "stage0", "Recovery requested normal boot retry")
        return recoveryResult
    end

    if recoveryResult == RECOVERY_RESCUE_RESULT then
        stage0Log("WARN", "stage0", "Recovery requested CraftOS rescue")
        return recoveryResult
    end

    local recoveryFailureReason =
        "recovery.lua returned an invalid result: " ..
            describeError(recoveryResult)

    stage0Log("ERROR", "stage0", recoveryFailureReason)
    stage0Log(
        "CRITICAL",
        "stage0",
        "Transitioning to Emergency Fallback"
    )
    return runEmergencyFallback(
        recoveryFailureReason,
        bootFailureReason
    )
end

-- Supervise normal boot for as long as DICK/OS owns the machine.
-- Each pass through this loop is a fresh init attempt. A retry changes loop
-- state; it does not call Stage-0 again and therefore is not recursive. The
-- context argument is the one table created above; passing it explicitly
-- makes its lifetime visible through every supervisor call instead of relying
-- on a hidden closure over Stage-0 state.
local function superviseBoot(runtimeContext)
    local normalBootAttempt = 0

    while true do
        normalBootAttempt = normalBootAttempt + 1
        stage0Log(
            "INFO",
            "stage0",
            "Normal boot attempt " .. tostring(normalBootAttempt)
        )

        local bootState, bootFailureReason = attemptNormalBoot(
            runtimeContext,
            normalBootAttempt
        )

        if bootState ~= "restart" then
            stage0Log(
                "WARN",
                "stage0",
                "Transitioning to Recovery: " .. tostring(bootFailureReason)
            )
            prepareTerminal()
            print("DICK/OS Stage-0")
            print()
            print("[FAIL] init terminated unexpectedly")
            print(bootFailureReason)
            print()
            print("Entering recovery...")

            local recoveryResult = requestRecovery(
                bootFailureReason,
                runtimeContext
            )

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
    local supervisorSucceeded, supervisorError = pcall(
        superviseBoot,
        runtimeContext
    )

    if supervisorSucceeded then
        -- `superviseBoot` returns normally only after explicit rescue choice.
        return
    end

    local supervisorFailureReason =
        "Stage-0 internal failure: " .. describeError(supervisorError)

    stage0Log("CRITICAL", "stage0", supervisorFailureReason)
    stage0Log(
        "CRITICAL",
        "stage0",
        "Transitioning to Emergency Fallback"
    )
    local fallbackResult = runEmergencyFallback(
        supervisorFailureReason
    )

    if fallbackResult == RECOVERY_RESCUE_RESULT then
        -- As above, this is the one deliberate path back to CraftOS.
        return
    end
end
