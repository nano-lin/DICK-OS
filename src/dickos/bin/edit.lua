-- DICK/OS native text editor
-- Version: 0.1.0-unstable

local BUFFER_LIBRARY_PATH = "/dickos/lib/editor_buffer.lua"
local MAXIMUM_FILE_BYTES = 256 * 1024

-- Forty-two columns fit both shortcut labels beside useful cursor coordinates.
-- Seven rows leave three editable rows between title/status separators. The
-- normal Advanced Computer terminal exceeds both values, while smaller
-- redirected terminals receive an explicit error instead of a broken layout.
local MINIMUM_SCREEN_WIDTH = 42
local MINIMUM_SCREEN_HEIGHT = 7
local TAB_SPACES = "    "
local MOUSE_SCROLL_LINES = 3

local EDITOR_BACKGROUND = colors.black
local PRIMARY_TEXT = colors.white
local SECONDARY_TEXT = colors.lightGray
local ACCENT_TEXT = colors.lightBlue
local SUCCESS_TEXT = colors.lime
local WARNING_TEXT = colors.yellow
local ERROR_TEXT = colors.red

-- Native DICK commands receive a context table as their first argument. The
-- following values are the one-file editor command line after that context.
local context, requestedPath, extraArgument = ...

-- Convert both ordinary Lua error strings and CC:T exception tables into a
-- readable message. Some current CC:T APIs preserve an exception's text in a
-- `message` field instead of returning a plain string.
local function describeError(errorValue)
    if type(errorValue) == "table" and
        type(errorValue.message) == "string" then
        return errorValue.message
    end

    return tostring(errorValue)
end

-- The DICK command context, rather than ambient program state, is
-- authoritative for cwd
-- and home expansion. Requiring absolute cwd/home values also prevents a
-- malformed caller from silently changing the meaning of a relative path.
local function validateCommandContext(commandContext)
    if type(commandContext) ~= "table" or
        type(commandContext.cwd) ~= "string" or
        type(commandContext.home) ~= "string" or
        string.sub(commandContext.cwd, 1, 1) ~= "/" or
        string.sub(commandContext.home, 1, 1) ~= "/" then
        error("edit requires DICK command context.", 0)
    end
end

validateCommandContext(context)

if requestedPath == "--help" and extraArgument == nil then
    print("Usage: edit <file>")
    return
end

if type(requestedPath) ~= "string" or requestedPath == "" or
    extraArgument ~= nil then
    error("Usage: edit <file>", 0)
end

-- Normalise an absolute path with the same rules as the DICK shell. Empty and
-- `.` segments disappear, while `..` removes one segment but clamps at `/`.
-- This is lexical normalisation; DICK/OS does not invent Unix mounts,
-- permissions, or symbolic-link semantics here.
local function normalizeAbsolutePath(path)
    local segments = {}

    for segment in string.gmatch(tostring(path), "[^/]+") do
        if segment == ".." then
            if #segments > 0 then
                table.remove(segments)
            end
        elseif segment ~= "." and segment ~= "" then
            segments[#segments + 1] = segment
        end
    end

    if #segments == 0 then
        return "/"
    end

    return "/" .. table.concat(segments, "/")
end

-- Expand only the documented `~` and `~/...` forms. Every other relative path
-- starts at the cwd snapshot supplied for this one command invocation.
local function resolvePath(path)
    if path == "~" then
        return normalizeAbsolutePath(context.home)
    end

    if string.sub(path, 1, 2) == "~/" then
        return normalizeAbsolutePath(
            context.home .. "/" .. string.sub(path, 3)
        )
    end

    if string.sub(path, 1, 1) == "/" then
        return normalizeAbsolutePath(path)
    end

    return normalizeAbsolutePath(context.cwd .. "/" .. path)
end

-- Shorten the exact home directory and its descendants for the title bar.
-- Checking the slash-terminated prefix avoids treating a neighbour such as
-- `/home/nano-old` as if it were inside `/home/nano`.
local function displayPath(path)
    local home = normalizeAbsolutePath(context.home)

    if path == home then
        return "~"
    end

    local homePrefix = home .. "/"

    if string.sub(path, 1, #homePrefix) == homePrefix then
        return "~/" .. string.sub(path, #homePrefix + 1)
    end

    return path
end

local targetPath = resolvePath(requestedPath)
local displayedTargetPath = displayPath(targetPath)

-- Load the small DICK-owned buffer model explicitly. The DICK shell does not
-- expose CraftOS's program-specific `require`/`package` environment, and the
-- native editor has no reason to recreate it. `loadfile` is a public Lua/CC:T
-- mechanism and preserves the ordinary child-command failure boundary.
local function loadBufferLibrary()
    local loadSucceeded, programOrError, compileError = pcall(
        loadfile,
        BUFFER_LIBRARY_PATH
    )

    if not loadSucceeded then
        error(
            "edit: unable to load buffer library: " ..
                describeError(programOrError),
            0
        )
    end

    if type(programOrError) ~= "function" then
        error(
            "edit: unable to load buffer library: " ..
                describeError(compileError),
            0
        )
    end

    local runSucceeded, libraryOrError = pcall(programOrError)

    if not runSucceeded or type(libraryOrError) ~= "table" then
        error(
            "edit: invalid buffer library: " ..
                describeError(libraryOrError),
            0
        )
    end

    local requiredFunctions = {
        "splitText",
        "new",
        "serialize",
        "insertText",
        "insertNewline",
        "backspace",
        "delete",
        "moveLeft",
        "moveRight",
        "moveUp",
        "moveDown",
        "moveHome",
        "moveEnd",
        "movePage",
        "scrollVertically",
        "ensureCursorVisible",
    }

    for _, functionName in ipairs(requiredFunctions) do
        if type(libraryOrError[functionName]) ~= "function" then
            error(
                "edit: buffer library is missing " .. functionName .. ".",
                0
            )
        end
    end

    return libraryOrError
end

local buffer = loadBufferLibrary()

-- Read an existing file completely before constructing the buffer. A missing
-- file is not opened at all and therefore is not created until Ctrl+S. The
-- defensive 256 KiB limit reflects CC:T's small Lua memory/filesystem setting;
-- rejecting first guarantees that an oversized file is never truncated.
local function loadDocument(path)
    local inspectionSucceeded, existsOrError, isDirectory, size = pcall(
        function()
            if not fs.exists(path) then
                return false, false, 0
            end

            local directory = fs.isDir(path)
            local fileSize = directory and 0 or fs.getSize(path)

            return true, directory, fileSize
        end
    )

    if not inspectionSucceeded then
        error(
            "edit: unable to inspect " .. path .. ": " ..
                describeError(existsOrError),
            0
        )
    end

    if not existsOrError then
        return buffer.new({ "" }, path)
    end

    if isDirectory then
        error("edit: cannot edit a directory: " .. path, 0)
    end

    if type(size) ~= "number" then
        error("edit: file size is unavailable: " .. path, 0)
    end

    if size > MAXIMUM_FILE_BYTES then
        error("File is too large for DICK EDIT.", 0)
    end

    -- `fs.open` returns a handle, not file contents. Opening, reading, and
    -- closing are protected separately so each CC:T failure gets a useful
    -- child-command diagnostic and the handle is still closed after read error.
    local openSucceeded, fileOrError, openError = pcall(fs.open, path, "r")

    if not openSucceeded then
        error(
            "edit: unable to read " .. path .. ": " ..
                describeError(fileOrError),
            0
        )
    end

    if fileOrError == nil then
        error(
            "edit: unable to read " .. path .. ": " ..
                describeError(openError),
            0
        )
    end

    local file = fileOrError
    local readSucceeded, contentsOrError = pcall(file.readAll)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        error(
            "edit: unable to read " .. path .. ": " ..
                describeError(contentsOrError),
            0
        )
    end

    if not closeSucceeded then
        error(
            "edit: unable to close " .. path .. ": " ..
                describeError(closeError),
            0
        )
    end

    if type(contentsOrError) ~= "string" then
        error("edit: file did not contain readable text: " .. path, 0)
    end

    return buffer.new(buffer.splitText(contentsOrError), path)
end

local document = loadDocument(targetPath)

-- The editor uses two plain ASCII separators instead of raw UTF-8 box glyphs.
-- CC:T terminal cells are byte-oriented, so this remains portable while the
-- normal boot/Recovery semigraphics can keep their specialised glyph mapping.
local function calculateLayout()
    local screenWidth, screenHeight = term.getSize()
    local lineNumberWidth = #tostring(#document.lines)
    local gutterWidth = lineNumberWidth + 3

    return {
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        lineNumberWidth = lineNumberWidth,
        gutterWidth = gutterWidth,
        textWidth = screenWidth - gutterWidth,
        textHeight = screenHeight - 4,
        textStartRow = 3,
        bottomSeparatorRow = screenHeight - 1,
        statusRow = screenHeight,
    }
end

local function screenIsUsable(layout)
    return layout.screenWidth >= MINIMUM_SCREEN_WIDTH and
        layout.screenHeight >= MINIMUM_SCREEN_HEIGHT and
        layout.textWidth > 0 and layout.textHeight > 0
end

-- Clip a title/status fragment to one terminal row. An ellipsis is ASCII and
-- therefore consumes exactly three CC:T cells. Very narrow widths use a plain
-- prefix rather than attempting a negative substring length.
local function clipText(text, width)
    if width <= 0 then
        return ""
    end

    if #text <= width then
        return text
    end

    if width <= 3 then
        return string.sub(text, 1, width)
    end

    return string.sub(text, 1, width - 3) .. "..."
end

-- Clear and draw one complete UI row. Explicitly setting the black background
-- on every render prevents a child or earlier program's colour state from
-- leaking into DICK EDIT.
local function drawRow(row, text, textColor, screenWidth)
    term.setBackgroundColor(EDITOR_BACKGROUND)
    term.setTextColor(textColor)
    term.setCursorPos(1, row)
    term.clearLine()
    term.write(clipText(text, screenWidth))
end

local discardConfirmationArmed = false
local transientStatus = nil
local transientStatusColor = SECONDARY_TEXT

local function setTransientStatus(message, color)
    transientStatus = message
    transientStatusColor = color
end

local function clearTransientStatus()
    transientStatus = nil
    transientStatusColor = SECONDARY_TEXT
end

-- Build the title so the dirty marker, when present, remains visible at the
-- right edge even if the target path must be shortened.
local function drawTitle(layout)
    local prefix = "DICK EDIT  "
    local dirtyMarker = document.dirty and " *" or ""
    local pathWidth = layout.screenWidth - #prefix - #dirtyMarker
    local title = prefix .. clipText(displayedTargetPath, pathWidth)
    local padding = layout.screenWidth - #title - #dirtyMarker

    if padding > 0 then
        title = title .. string.rep(" ", padding)
    end

    drawRow(
        1,
        title .. dirtyMarker,
        document.dirty and WARNING_TEXT or ACCENT_TEXT,
        layout.screenWidth
    )
end

-- The normal status keeps shortcuts right-aligned and cursor coordinates on
-- the left. Confirmation and I/O messages temporarily replace that row, while
-- title and buffer contents remain visible so the editor never becomes a
-- separate prompt or modal shell.
local function drawStatus(layout)
    if transientStatus ~= nil then
        drawRow(
            layout.statusRow,
            transientStatus,
            transientStatusColor,
            layout.screenWidth
        )
        return
    end

    local positionText = string.format(
        "Ln %d, Col %d",
        document.cursorLine,
        document.cursorColumn
    )
    local shortcutText = "Ctrl+S Save  Ctrl+Q Quit"
    local availablePositionWidth =
        layout.screenWidth - #shortcutText - 1

    if #positionText > availablePositionWidth then
        -- The compact form still displays both required coordinates when a
        -- very large line/column number meets the minimum supported width.
        positionText = string.format(
            "L%d C%d",
            document.cursorLine,
            document.cursorColumn
        )
    end

    positionText = clipText(positionText, availablePositionWidth)

    local spacing = math.max(
        1,
        layout.screenWidth - #positionText - #shortcutText
    )

    drawRow(
        layout.statusRow,
        positionText .. string.rep(" ", spacing) .. shortcutText,
        SECONDARY_TEXT,
        layout.screenWidth
    )
end

-- Draw visible lines only. The renderer asks the independent buffer model to
-- keep the cursor inside its viewport, then clips each source line from the
-- current horizontal offset. There is intentionally no wrapping in editor v1.
local function render(layout)
    buffer.ensureCursorVisible(
        document,
        layout.textWidth,
        layout.textHeight
    )

    term.setBackgroundColor(EDITOR_BACKGROUND)
    term.setCursorBlink(false)

    drawTitle(layout)
    drawRow(
        2,
        string.rep("-", layout.screenWidth),
        SECONDARY_TEXT,
        layout.screenWidth
    )

    for visibleRow = 1, layout.textHeight do
        local terminalRow = layout.textStartRow + visibleRow - 1
        local lineIndex = document.scrollY + visibleRow - 1

        drawRow(terminalRow, "", PRIMARY_TEXT, layout.screenWidth)

        if lineIndex <= #document.lines then
            local lineNumber = string.format(
                "%" .. layout.lineNumberWidth .. "d",
                lineIndex
            )
            local sourceLine = document.lines[lineIndex]
            local visibleText = string.sub(
                sourceLine,
                document.scrollX,
                document.scrollX + layout.textWidth - 1
            )

            term.setCursorPos(1, terminalRow)
            term.setTextColor(SECONDARY_TEXT)
            term.write(lineNumber .. " | ")
            term.setTextColor(PRIMARY_TEXT)
            term.write(visibleText)
        end
    end

    drawRow(
        layout.bottomSeparatorRow,
        string.rep("-", layout.screenWidth),
        SECONDARY_TEXT,
        layout.screenWidth
    )
    drawStatus(layout)

    local cursorX = layout.gutterWidth +
        document.cursorColumn - document.scrollX + 1
    local cursorY = layout.textStartRow +
        document.cursorLine - document.scrollY

    term.setTextColor(PRIMARY_TEXT)
    term.setBackgroundColor(EDITOR_BACKGROUND)
    term.setCursorPos(cursorX, cursorY)
    term.setCursorBlink(true)
end

-- Leave a full-screen child in a predictable state before a normal return.
-- The DICK shell still performs its own final restoration after every child,
-- which remains the safety boundary for crashes and Ctrl+T termination.
local function restoreTerminalForShell()
    term.setBackgroundColor(EDITOR_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(true)
    term.clear()
    term.setCursorPos(1, 1)
end

local function reportSmallScreen()
    restoreTerminalForShell()
    print(string.format(
        "edit: terminal is too small (minimum %dx%d).",
        MINIMUM_SCREEN_WIDTH,
        MINIMUM_SCREEN_HEIGHT
    ))
end

-- Serialize and write the complete document. CC:T opens a writable handle
-- before any call to `write`; editor v1 uses that direct and well-understood
-- path instead of adding a temporary-file transaction. Dirty state is cleared
-- only when open, write, and close all succeed. Any failure stays in-editor.
local function saveDocument()
    local contents = buffer.serialize(document)

    if #contents > MAXIMUM_FILE_BYTES then
        setTransientStatus(
            "Save failed: document exceeds the 256 KiB editor limit.",
            ERROR_TEXT
        )
        return false
    end

    local openSucceeded, fileOrError, openError = pcall(
        fs.open,
        document.targetPath,
        "w"
    )

    if not openSucceeded then
        setTransientStatus(
            "Save failed: " .. describeError(fileOrError),
            ERROR_TEXT
        )
        return false
    end

    if fileOrError == nil then
        setTransientStatus(
            "Save failed: " .. describeError(openError),
            ERROR_TEXT
        )
        return false
    end

    local file = fileOrError
    local writeSucceeded, writeError = pcall(file.write, contents)
    local closeSucceeded, closeError = pcall(file.close)

    if not writeSucceeded then
        setTransientStatus(
            "Save failed: " .. describeError(writeError),
            ERROR_TEXT
        )
        return false
    end

    if not closeSucceeded then
        setTransientStatus(
            "Save failed while closing: " .. describeError(closeError),
            ERROR_TEXT
        )
        return false
    end

    document.dirty = false
    discardConfirmationArmed = false
    setTransientStatus("Saved " .. displayedTargetPath, SUCCESS_TEXT)
    return true
end

-- An editing key cancels a pending discard decision before changing text. The
-- second Ctrl+Q must therefore follow an explicit first Ctrl+Q, not an older
-- confirmation which survived subsequent typing.
local function beginEditingAction()
    discardConfirmationArmed = false
    clearTransientStatus()
end

-- Keep both loaded and newly-created documents within the same memory bound.
-- The candidate string length is an upper bound for paste because CRLF
-- normalisation may make the actual insertion smaller. Rejecting before
-- mutation avoids having to copy and roll back a potentially large buffer.
local function insertTextWithinLimit(text)
    beginEditingAction()

    if document.byteLength + #text > MAXIMUM_FILE_BYTES then
        setTransientStatus(
            "Edit limit reached: maximum file size is 256 KiB.",
            ERROR_TEXT
        )
        return false
    end

    return buffer.insertText(document, text)
end

local controlKeyDown = false

local function isControlKey(keyCode)
    return keyCode == keys.leftCtrl or keyCode == keys.rightCtrl
end

-- Process one key event and return true only when the editor should exit.
-- Ctrl+S/Q are recognised from normal `key`/`key_up` state; no ROM command
-- bindings or scheduler are involved.
local function handleKey(keyCode, keyIsHeld, textHeight)
    if isControlKey(keyCode) then
        controlKeyDown = true
        return false
    end

    -- CC:T marks automatically repeated key events with `isHeld = true`.
    -- Ignoring repeats for shortcuts prevents one held Ctrl+Q from acting as
    -- both the warning and the destructive second confirmation.
    if controlKeyDown and keyIsHeld and
        (keyCode == keys.s or keyCode == keys.q) then
        return false
    end

    if controlKeyDown and keyCode == keys.s then
        saveDocument()
        return false
    end

    if controlKeyDown and keyCode == keys.q then
        if not document.dirty then
            return true
        end

        if discardConfirmationArmed then
            return true
        end

        discardConfirmationArmed = true
        setTransientStatus(
            "Unsaved changes. Ctrl+S save, Ctrl+Q again discard, Esc cancel.",
            WARNING_TEXT
        )
        return false
    end

    if keyCode == keys.escape and discardConfirmationArmed then
        discardConfirmationArmed = false
        clearTransientStatus()
        return false
    end

    -- Any other navigation/editing key makes a previous confirmation stale.
    -- Save-success notices are short-lived in the same way and disappear on
    -- the next meaningful key action.
    if discardConfirmationArmed or transientStatus ~= nil then
        discardConfirmationArmed = false
        clearTransientStatus()
    end

    if keyCode == keys.left then
        buffer.moveLeft(document)
    elseif keyCode == keys.right then
        buffer.moveRight(document)
    elseif keyCode == keys.up then
        buffer.moveUp(document)
    elseif keyCode == keys.down then
        buffer.moveDown(document)
    elseif keyCode == keys.home then
        buffer.moveHome(document)
    elseif keyCode == keys["end"] then
        buffer.moveEnd(document)
    elseif keyCode == keys.pageUp then
        buffer.movePage(document, -textHeight)
    elseif keyCode == keys.pageDown then
        buffer.movePage(document, textHeight)
    elseif keyCode == keys.enter then
        insertTextWithinLimit("\n")
    elseif keyCode == keys.backspace then
        beginEditingAction()
        buffer.backspace(document)
    elseif keyCode == keys.delete then
        beginEditingAction()
        buffer.delete(document)
    elseif keyCode == keys.tab then
        insertTextWithinLimit(TAB_SPACES)
    end

    return false
end

local layout = calculateLayout()

if not screenIsUsable(layout) then
    reportSmallScreen()
    return
end

term.setBackgroundColor(EDITOR_BACKGROUND)
term.clear()
render(layout)

local shouldQuit = false

while not shouldQuit do
    -- `os.pullEvent`, unlike `os.pullEventRaw`, raises `Terminated` for Ctrl+T.
    -- We intentionally do not protect this call: the DICK shell catches that
    -- child error, prints `Command terminated.`, and restores its own terminal.
    -- Unsaved changes cannot be confirmed on this external termination path.
    local event, first, second = os.pullEvent()

    if event == "key" then
        shouldQuit = handleKey(first, second == true, layout.textHeight)
    elseif event == "key_up" and isControlKey(first) then
        controlKeyDown = false
    elseif event == "char" and not controlKeyDown then
        insertTextWithinLimit(first)
    elseif event == "paste" then
        -- A paste event is the authoritative text-insertion signal. CC:T emits
        -- it as a consequence of Ctrl+V, so the control key may legitimately
        -- still be down when this event arrives. The normal insertion helper
        -- preserves multi-line splitting, size limits, dirty state, and
        -- cancellation of an armed discard confirmation.
        insertTextWithinLimit(first)
    elseif event == "mouse_scroll" then
        -- Official CC:T direction values are -1 for up and 1 for down. Move a
        -- small fixed number of document rows and let the pure buffer helper
        -- clamp both viewport and, only when necessary, the visible cursor.
        discardConfirmationArmed = false
        clearTransientStatus()
        buffer.scrollVertically(
            document,
            first * MOUSE_SCROLL_LINES,
            layout.textHeight
        )
    elseif event == "term_resize" then
        -- The common redraw below recomputes all dimensions. Keeping resize as
        -- an explicit recognised event documents that no old layout is reused.
    end

    if not shouldQuit then
        -- Recompute on every redraw, not only terminal resize. Adding/removing
        -- the tenth, hundredth, and later lines changes the dynamic gutter and
        -- therefore the width available to horizontally scrolled text.
        layout = calculateLayout()

        if not screenIsUsable(layout) then
            reportSmallScreen()
            return
        end

        render(layout)
    end
end

restoreTerminalForShell()
