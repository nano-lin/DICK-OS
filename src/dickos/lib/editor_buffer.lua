-- DICK/OS native editor buffer model
-- Version: 0.1.0-unstable

-- This module owns text and cursor rules only. It deliberately knows nothing
-- about the terminal, filesystem, or CC:T event loop. Keeping those concerns
-- outside the buffer makes editing behaviour testable without drawing a TUI or
-- creating real files, and leaves a future renderer free to add syntax colour
-- without changing how text is stored.
local editorBuffer = {}

-- Keep a number inside an inclusive range. Cursor positions use this helper
-- after vertical movement because neighbouring lines may have different
-- lengths. A cursor column is an insertion position, so a line containing
-- three characters has valid columns 1 through 4.
local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(value, maximum))
end

-- Convert file text into lines which do not contain newline characters.
-- `string.find` is used with plain matching, so `\n` has no Lua-pattern
-- meaning. Adding the final substring even when it is empty preserves a file's
-- trailing newline: `"a\n"` becomes `{ "a", "" }`. An empty file similarly
-- becomes one empty editable line, maintaining the buffer invariant.
--
-- CRLF and lone carriage-return input are normalised to LF. CC:T files normally
-- use LF, and this explicit policy prevents a CR byte from becoming a hidden
-- character at the end of every line when a file came from another platform.
function editorBuffer.splitText(contents)
    local normalisedText = string.gsub(tostring(contents), "\r\n", "\n")
    normalisedText = string.gsub(normalisedText, "\r", "\n")

    local lines = {}
    local lineStart = 1

    while true do
        local newlinePosition = string.find(
            normalisedText,
            "\n",
            lineStart,
            true
        )

        if newlinePosition == nil then
            lines[#lines + 1] = string.sub(normalisedText, lineStart)
            break
        end

        lines[#lines + 1] = string.sub(
            normalisedText,
            lineStart,
            newlinePosition - 1
        )
        lineStart = newlinePosition + 1
    end

    return lines
end

-- Construct one editor state. Lua tables serve both as ordered lists
-- (`lines[1]`, `lines[2]`, ...) and as named records (`cursorLine`, `dirty`).
-- Viewport values are the one-based first visible row and column, so every
-- coordinate in the model follows the same indexing rule as Lua's strings and
-- numerically indexed tables.
function editorBuffer.new(lines, targetPath)
    if type(lines) ~= "table" or #lines == 0 then
        error("editor buffer requires at least one line", 0)
    end

    for lineIndex, line in ipairs(lines) do
        if type(line) ~= "string" then
            error("editor buffer line " .. lineIndex .. " is not text", 0)
        end
    end

    -- Each boundary between two lines serialises as one LF byte. Tracking the
    -- total incrementally lets the command enforce its memory limit without
    -- joining the whole document again after every keystroke.
    local byteLength = #lines - 1

    for _, line in ipairs(lines) do
        byteLength = byteLength + #line
    end

    return {
        lines = lines,
        cursorLine = 1,
        cursorColumn = 1,
        scrollX = 1,
        scrollY = 1,
        dirty = false,
        targetPath = targetPath,
        byteLength = byteLength,
    }
end

-- Join the internal lines with LF bytes. No unconditional newline is added:
-- a trailing newline exists only when the final buffer line is empty. This
-- makes splitText/serialize a lossless pair for LF input, including several
-- trailing empty lines.
function editorBuffer.serialize(state)
    return table.concat(state.lines, "\n")
end

-- Insert plain text at the cursor. This handles both one-character `char`
-- events and multi-line `paste` events. The old line is divided at the cursor;
-- the first pasted line receives the prefix, the last receives the suffix, and
-- any middle lines are inserted as independent buffer entries.
function editorBuffer.insertText(state, text)
    local insertedText = tostring(text or "")

    if insertedText == "" then
        return false
    end

    local insertedLines = editorBuffer.splitText(insertedText)
    local normalisedInsertedText = table.concat(insertedLines, "\n")
    local currentLine = state.lines[state.cursorLine]
    local prefix = string.sub(currentLine, 1, state.cursorColumn - 1)
    local suffix = string.sub(currentLine, state.cursorColumn)

    if #insertedLines == 1 then
        state.lines[state.cursorLine] = prefix .. insertedLines[1] .. suffix
        state.cursorColumn = state.cursorColumn + #insertedLines[1]
    else
        state.lines[state.cursorLine] = prefix .. insertedLines[1]

        for insertedIndex = 2, #insertedLines do
            table.insert(
                state.lines,
                state.cursorLine + insertedIndex - 1,
                insertedLines[insertedIndex]
            )
        end

        state.cursorLine = state.cursorLine + #insertedLines - 1
        state.cursorColumn = #insertedLines[#insertedLines] + 1
        state.lines[state.cursorLine] =
            state.lines[state.cursorLine] .. suffix
    end

    state.dirty = true
    state.byteLength = state.byteLength + #normalisedInsertedText
    return true
end

-- Enter is exactly a one-newline insertion. Reusing insertText keeps keyboard
-- and pasted-newline splitting governed by the same tested rule.
function editorBuffer.insertNewline(state)
    return editorBuffer.insertText(state, "\n")
end

-- Remove the character immediately before the cursor. At column one there is
-- no character on the current line, so the line joins its predecessor and the
-- cursor lands at the join boundary. Backspace on the first line is a no-op.
function editorBuffer.backspace(state)
    local currentLine = state.lines[state.cursorLine]

    if state.cursorColumn > 1 then
        state.lines[state.cursorLine] =
            string.sub(currentLine, 1, state.cursorColumn - 2) ..
            string.sub(currentLine, state.cursorColumn)
        state.cursorColumn = state.cursorColumn - 1
    elseif state.cursorLine > 1 then
        local previousLine = state.lines[state.cursorLine - 1]

        state.cursorColumn = #previousLine + 1
        state.lines[state.cursorLine - 1] = previousLine .. currentLine
        table.remove(state.lines, state.cursorLine)
        state.cursorLine = state.cursorLine - 1
    else
        return false
    end

    state.dirty = true
    state.byteLength = state.byteLength - 1
    return true
end

-- Delete removes the character under the cursor. When the cursor is one past
-- the final character, deleting joins the following line instead. The final
-- line at its end has nothing to delete and remains unchanged.
function editorBuffer.delete(state)
    local currentLine = state.lines[state.cursorLine]

    if state.cursorColumn <= #currentLine then
        state.lines[state.cursorLine] =
            string.sub(currentLine, 1, state.cursorColumn - 1) ..
            string.sub(currentLine, state.cursorColumn + 1)
    elseif state.cursorLine < #state.lines then
        state.lines[state.cursorLine] =
            currentLine .. state.lines[state.cursorLine + 1]
        table.remove(state.lines, state.cursorLine + 1)
    else
        return false
    end

    state.dirty = true
    state.byteLength = state.byteLength - 1
    return true
end

-- Left and Right cross line boundaries, matching the way Backspace and Delete
-- treat the document as continuous text separated by newline characters.
function editorBuffer.moveLeft(state)
    if state.cursorColumn > 1 then
        state.cursorColumn = state.cursorColumn - 1
    elseif state.cursorLine > 1 then
        state.cursorLine = state.cursorLine - 1
        state.cursorColumn = #state.lines[state.cursorLine] + 1
    end
end

function editorBuffer.moveRight(state)
    local currentLine = state.lines[state.cursorLine]

    if state.cursorColumn <= #currentLine then
        state.cursorColumn = state.cursorColumn + 1
    elseif state.cursorLine < #state.lines then
        state.cursorLine = state.cursorLine + 1
        state.cursorColumn = 1
    end
end

-- Vertical movement deliberately clamps immediately to the destination line.
-- Editor v1 does not retain a hidden preferred column; that more elaborate
-- behaviour can be added later without changing the stored text.
local function moveVertically(state, lineDelta)
    state.cursorLine = clamp(
        state.cursorLine + lineDelta,
        1,
        #state.lines
    )
    state.cursorColumn = math.min(
        state.cursorColumn,
        #state.lines[state.cursorLine] + 1
    )
end

function editorBuffer.moveUp(state)
    moveVertically(state, -1)
end

function editorBuffer.moveDown(state)
    moveVertically(state, 1)
end

function editorBuffer.moveHome(state)
    state.cursorColumn = 1
end

function editorBuffer.moveEnd(state)
    state.cursorColumn = #state.lines[state.cursorLine] + 1
end

-- Page movement uses the number of currently visible text rows supplied by
-- the renderer. The final cursor is clamped to the document and destination
-- line just like ordinary Up/Down movement.
function editorBuffer.movePage(state, lineDelta)
    moveVertically(state, lineDelta)
end

-- Adjust one-based viewport starts until the insertion cursor is visible.
-- `textWidth` and `textHeight` describe only the editable area, excluding line
-- numbers and UI bars. Long lines are clipped rather than wrapped in v1.
function editorBuffer.ensureCursorVisible(state, textWidth, textHeight)
    if textWidth < 1 or textHeight < 1 then
        error("editor viewport must have positive dimensions", 0)
    end

    if state.cursorLine < state.scrollY then
        state.scrollY = state.cursorLine
    elseif state.cursorLine > state.scrollY + textHeight - 1 then
        state.scrollY = state.cursorLine - textHeight + 1
    end

    if state.cursorColumn < state.scrollX then
        state.scrollX = state.cursorColumn
    elseif state.cursorColumn > state.scrollX + textWidth - 1 then
        state.scrollX = state.cursorColumn - textWidth + 1
    end

    -- Line deletion or a terminal resize may make an older scroll offset
    -- larger than the document now needs. Clamping avoids blank space below
    -- the final line while keeping the cursor-visible rules above intact.
    state.scrollY = clamp(
        state.scrollY,
        1,
        math.max(1, #state.lines - textHeight + 1)
    )
    state.scrollX = math.max(1, state.scrollX)
end

return editorBuffer
