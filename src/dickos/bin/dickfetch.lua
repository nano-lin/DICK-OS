-- DICK/OS compact system-information presentation
-- Version: 0.1.0-unstable

local BACKGROUND = colors.black
local PRIMARY_TEXT = colors.white
local SECONDARY_TEXT = colors.lightGray
local INFORMATION_COLOR = colors.lightBlue
local SUCCESS_COLOR = colors.lime

-- The happy mascot is canonical project artwork. A numerically indexed Lua
-- table keeps each terminal row separate, and `ipairs` later visits the rows
-- from first to last without embedding cursor movement inside the art.
local HAPPY_DICK = {
    "   ____",
    "  /+ + \\",
    "  \\ U  /",
    "   |  |",
    "   |  |",
    "  (_)(_)",
}

-- A top-level Lua program receives arguments through `...`. Init supplies one
-- explicit context table so this utility does not need to read a temporary
-- Boot ID from disk. The DICK shell invokes the same program with its current
-- command context instead of duplicating this presentation.
local context, firstArgument = ...

-- Init and the DICK shell both supply a context table. A direct CraftOS
-- rescue invocation may still request usage without fabricating runtime
-- identity, while ordinary rendering continues to require the real context.
if context == "--help" or firstArgument == "--help" then
    print("Usage: dickfetch")
    return
end

-- Require a non-empty string field from the explicit interface. Raising a
-- clear Lua error is appropriate for direct callers; init protects dickfetch
-- with pcall and treats this utility's rendering failures as noncritical.
local function requireContextValue(fieldName)
    if type(context) ~= "table" then
        error("dickfetch requires a runtime context table.", 0)
    end

    local value = context[fieldName]

    if type(value) ~= "string" or value == "" then
        error("dickfetch context is missing " .. fieldName .. ".", 0)
    end

    return value
end

local version = requireContextValue("version")
local hostname = requireContextValue("hostname")
local machineID = requireContextValue("machineID")
local bootID = requireContextValue("bootID")

local function prepareTerminal()
    term.setBackgroundColor(BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Write clipped text at one-based CC:T terminal coordinates. Clipping avoids
-- wrapping a long identity value into another information row on the standard
-- Advanced Computer display.
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

local function drawMascot(x, y)
    for rowOffset, line in ipairs(HAPPY_DICK) do
        writeAt(x, y + rowOffset - 1, line, SUCCESS_COLOR)
    end
end

local function drawInformationField(x, y, label, value)
    writeAt(x, y, label, SECONDARY_TEXT)
    writeAt(x + 12, y, value, PRIMARY_TEXT)
end

prepareTerminal()

-- Mascot and title share row 2, making the two columns begin at the same
-- vertical level. Blank rows after the version and identity fields preserve
-- the requested information hierarchy without a frame or giant underline.
drawMascot(3, 2)
writeAt(14, 2, "DICK/OS", INFORMATION_COLOR)
writeAt(14, 3, version, SECONDARY_TEXT)
drawInformationField(14, 5, "Hostname:", hostname)
drawInformationField(14, 6, "Machine ID:", machineID)
drawInformationField(14, 7, "Boot ID:", bootID)
writeAt(14, 9, "SYSTEM READY", SUCCESS_COLOR)
