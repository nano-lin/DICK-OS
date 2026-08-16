-- DICK/OS minimal recovery bootstrap
-- Version: 0.1.0-unstable

local RETRY_RESULT = "retry"
local RESCUE_RESULT = "rescue"

local RECOVERY_BACKGROUND = colors.blue
local RECOVERY_BORDER = colors.lightBlue
local PRIMARY_TEXT = colors.white
local WARNING_TEXT = colors.yellow

-- The sad mascot mirrors the happy ready-screen mascot while changing only
-- the face. A table of strings keeps the ASCII art compact and lets the draw
-- helper place it one terminal row at a time with `ipairs`.
local SAD_DICK = {
    "   ____",
    "  /+ + \\",
    "  \\ n  /",
    "   |  |",
    "   |  |",
    "  (_)(_)",
}

-- A top-level Lua program receives arguments through `...`. Stage-0 passes the
-- boot-failure reason as the first argument when it calls this file's compiled
-- chunk. nil means no value was supplied; converting that case into explicit
-- text keeps the recovery screen useful instead of causing a concatenation
-- error.
local bootFailureReason = ...

if bootFailureReason == nil then
    bootFailureReason = "No boot-failure reason was supplied."
else
    bootFailureReason = tostring(bootFailureReason)
end

local function prepareTerminal()
    term.setBackgroundColor(RECOVERY_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Terminal coordinates are one-based: (1, 1) is the top-left character cell.
-- The terminal width and height are queried for every complete redraw so this
-- boxed TUI stays within the standard Advanced Computer display. Text is
-- clipped rather than allowed to wrap through the right-hand border.
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

-- Draw a reliable ASCII border around the whole terminal. Clearing after the
-- blue background is selected fills the interior, while `+`, `-`, and `|`
-- mark corners and edges using characters available on every CC:T terminal.
local function drawBox()
    local terminalWidth, terminalHeight = term.getSize()
    local horizontalEdge = "+" ..
        string.rep("-", terminalWidth - 2) .. "+"

    prepareTerminal()
    writeAt(1, 1, horizontalEdge, RECOVERY_BORDER)
    writeAt(1, terminalHeight, horizontalEdge, RECOVERY_BORDER)

    for row = 2, terminalHeight - 1 do
        writeAt(1, row, "|", RECOVERY_BORDER)
        writeAt(terminalWidth, row, "|", RECOVERY_BORDER)
    end
end

local function drawMascot(art, x, y, color)
    for rowOffset, line in ipairs(art) do
        writeAt(x, y + rowOffset - 1, line, color)
    end
end

-- Wrap diagnostic text without depending on a future DICK/OS UI library.
-- Words are kept together when they fit. A single word longer than the line
-- width is split by character so even a long path or Lua token cannot cross
-- the border. If the available rows are exhausted, the final line ends in an
-- ellipsis instead of letting later menu rows scroll away.
local function wrapText(text, lineWidth, maximumLines)
    local wrappedLines = {}
    local paragraphs = tostring(text) .. "\n"

    for paragraph in string.gmatch(paragraphs, "(.-)\n") do
        local currentLine = ""
        local paragraphHadWords = false

        for word in string.gmatch(paragraph, "%S+") do
            paragraphHadWords = true

            while #word > lineWidth do
                if currentLine ~= "" then
                    wrappedLines[#wrappedLines + 1] = currentLine
                    currentLine = ""
                end

                wrappedLines[#wrappedLines + 1] = string.sub(
                    word,
                    1,
                    lineWidth
                )
                word = string.sub(word, lineWidth + 1)
            end

            if word ~= "" then
                if currentLine == "" then
                    currentLine = word
                elseif #currentLine + #word + 1 <= lineWidth then
                    currentLine = currentLine .. " " .. word
                else
                    wrappedLines[#wrappedLines + 1] = currentLine
                    currentLine = word
                end
            end
        end

        if currentLine ~= "" then
            wrappedLines[#wrappedLines + 1] = currentLine
        elseif not paragraphHadWords then
            wrappedLines[#wrappedLines + 1] = ""
        end
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

local function drawWrappedText(x, y, text, width, maximumLines, color)
    local lines = wrapText(text, width, maximumLines)

    for lineIndex, line in ipairs(lines) do
        writeAt(x, y + lineIndex - 1, line, color)
    end
end

local function drawMenuItem(row, number, label)
    writeAt(3, row, tostring(number) .. ".", RECOVERY_BORDER)
    writeAt(6, row, label, PRIMARY_TEXT)
end

-- Redraw the complete Recovery screen before every prompt. Fixed regions keep
-- a long failure message away from the menu: title and mascot occupy the top,
-- wrapped diagnostics occupy the middle, and actions stay near the bottom.
local function drawRecoveryScreen(notice)
    local terminalWidth, terminalHeight = term.getSize()
    local diagnosticWidth = math.max(10, terminalWidth - 13)
    local menuStart = terminalHeight - 9
    local diagnosticLines = math.max(1, menuStart - 6)
    local mascotX = math.max(3, terminalWidth - 9)

    drawBox()
    writeAt(3, 2, "DICK/OS RECOVERY", PRIMARY_TEXT)
    drawMascot(SAD_DICK, mascotX, 2, WARNING_TEXT)

    writeAt(3, 4, "Boot failure", WARNING_TEXT)
    writeAt(3, 5, string.rep("-", diagnosticWidth), RECOVERY_BORDER)
    drawWrappedText(
        3,
        6,
        bootFailureReason,
        diagnosticWidth,
        diagnosticLines,
        PRIMARY_TEXT
    )

    drawMenuItem(menuStart, 1, "Retry normal boot")
    drawMenuItem(menuStart + 1, 2, "Enter CraftOS rescue shell")
    drawMenuItem(menuStart + 2, 3, "Reboot")
    drawMenuItem(menuStart + 3, 4, "Shutdown")

    if notice ~= nil then
        writeAt(3, terminalHeight - 4, notice, WARNING_TEXT)
    end
end

local function readRecoveryInput(promptText)
    local _, terminalHeight = term.getSize()

    writeAt(3, terminalHeight - 2, promptText, PRIMARY_TEXT)
    term.setCursorBlink(true)
    local answer = read()
    term.setCursorBlink(false)

    return answer
end

local function confirmCraftOSRescue()
    drawRecoveryScreen("Explicit rescue leaves DICK/OS supervision.")
    local answer = string.lower(readRecoveryInput(
        "Enter CraftOS rescue shell? [y/N]: "
    ))

    return answer == "y" or answer == "yes"
end

-- Recovery communicates with Stage-0 through small result strings. Returning
-- `retry` asks the existing supervisor loop for another init attempt; it does
-- not execute startup.lua recursively. Returning `rescue` is accepted only
-- after explicit confirmation and tells Stage-0 that ending startup is now an
-- intentional request to reach the underlying CraftOS shell.
--
-- `read()` waits on CC:T's event system instead of busy-polling. Ctrl+T causes
-- it to raise the normal terminate error. Stage-0 executes this whole recovery
-- chunk with pcall, so that error leads to its emergency fallback rather than
-- accidentally exposing CraftOS.
local notice = nil

while true do
    drawRecoveryScreen(notice)
    local choice = readRecoveryInput("Select: ")

    if choice == "1" then
        return RETRY_RESULT
    elseif choice == "2" then
        if confirmCraftOSRescue() then
            return RESCUE_RESULT
        end

        notice = "CraftOS rescue cancelled."
    elseif choice == "3" then
        -- These CC:T calls immediately change the computer's power state.
        -- Stage-0 does not intercept them. A reboot starts again at startup.lua;
        -- a shutdown executes no more Lua until the computer is powered on.
        os.reboot()
    elseif choice == "4" then
        os.shutdown()
    else
        notice = "Unknown selection. Choose 1, 2, 3, or 4."
    end
end
