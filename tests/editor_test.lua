-- Host-side tests for the native DICK/OS editor
-- Run with: lua tests/editor_test.lua

local EDITOR_SOURCE = "src/dickos/bin/edit.lua"
local BUFFER_SOURCE = "src/dickos/lib/editor_buffer.lua"
local INSTALLED_BUFFER_PATH = "/dickos/lib/editor_buffer.lua"
local GUARD_SOURCE = "src/dickos/lib/fs_guard.lua"
local INSTALLED_GUARD_PATH = "/dickos/lib/fs_guard.lua"
local TEST_STOP = "__DICK_EDITOR_TEST_EVENT_QUEUE_EMPTY__"

local hostLoadfile = loadfile
local buffer = assert(hostLoadfile(BUFFER_SOURCE))()

local function readHostFile(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    file:close()
    return contents
end

-- The old compatibility boundary must not linger in the native command. This
-- source-level guard complements behavioural tests and catches an accidental
-- reintroduction before Minecraft runtime testing.
local editorSource = readHostFile(EDITOR_SOURCE)
local forbiddenDependencies = {
    "/rom/programs/edit.lua",
    "cc.internal.menu",
    "cc.internal.syntax",
    "CraftOS shell",
    "multishell",
}

for _, forbiddenDependency in ipairs(forbiddenDependencies) do
    assert(string.find(
        editorSource,
        forbiddenDependency,
        1,
        true
    ) == nil, "native editor references " .. forbiddenDependency)
end

local function assertContains(text, fragment)
    assert(
        string.find(tostring(text), fragment, 1, true) ~= nil,
        "expected text to contain: " .. fragment .. "\nactual: " ..
            tostring(text)
    )
end

local function assertNotContains(text, fragment)
    assert(
        string.find(tostring(text), fragment, 1, true) == nil,
        "expected text not to contain: " .. fragment .. "\nactual: " ..
            tostring(text)
    )
end

local function assertLines(state, expectedLines)
    assert(#state.lines == #expectedLines)

    for lineIndex, expectedLine in ipairs(expectedLines) do
        assert(state.lines[lineIndex] == expectedLine)
    end

    assert(state.byteLength == #buffer.serialize(state))
end

local function newBuffer(text)
    return buffer.new(buffer.splitText(text), "/test.txt")
end

-- FILE/NEWLINE MODEL -------------------------------------------------------

local newlineCases = {
    { contents = "", lines = { "" } },
    { contents = "one line", lines = { "one line" } },
    { contents = "one\ntwo", lines = { "one", "two" } },
    { contents = "one\n", lines = { "one", "" } },
    { contents = "one\n\n", lines = { "one", "", "" } },
}

for _, newlineCase in ipairs(newlineCases) do
    local state = newBuffer(newlineCase.contents)

    assertLines(state, newlineCase.lines)
    assert(buffer.serialize(state) == newlineCase.contents)
end

-- Cross-platform input is deliberately normalised to the editor's LF policy.
local carriageReturnState = newBuffer("one\r\ntwo\rthree")
assertLines(carriageReturnState, { "one", "two", "three" })
assert(buffer.serialize(carriageReturnState) == "one\ntwo\nthree")

-- BUFFER EDITING -----------------------------------------------------------

local insertState = newBuffer("")
assert(buffer.insertText(insertState, "a"))
assertLines(insertState, { "a" })
assert(insertState.cursorColumn == 2)
assert(insertState.dirty)
assert(insertState.byteLength == 1)

local middleInsertState = newBuffer("ac")
middleInsertState.cursorColumn = 2
buffer.insertText(middleInsertState, "b")
assertLines(middleInsertState, { "abc" })
assert(middleInsertState.cursorColumn == 3)

local splitState = newBuffer("abcdef")
splitState.cursorColumn = 4
buffer.insertNewline(splitState)
assertLines(splitState, { "abc", "def" })
assert(splitState.cursorLine == 2)
assert(splitState.cursorColumn == 1)

local backspaceState = newBuffer("abc")
backspaceState.cursorColumn = 3
assert(buffer.backspace(backspaceState))
assertLines(backspaceState, { "ac" })
assert(backspaceState.cursorColumn == 2)
assert(backspaceState.byteLength == 2)

local backspaceJoinState = newBuffer("abc\ndef")
backspaceJoinState.cursorLine = 2
backspaceJoinState.cursorColumn = 1
assert(buffer.backspace(backspaceJoinState))
assertLines(backspaceJoinState, { "abcdef" })
assert(backspaceJoinState.cursorLine == 1)
assert(backspaceJoinState.cursorColumn == 4)
assert(backspaceJoinState.byteLength == 6)

local deleteState = newBuffer("abc")
deleteState.cursorColumn = 2
assert(buffer.delete(deleteState))
assertLines(deleteState, { "ac" })
assert(deleteState.cursorColumn == 2)
assert(deleteState.byteLength == 2)

local deleteJoinState = newBuffer("abc\ndef")
deleteJoinState.cursorColumn = 4
assert(buffer.delete(deleteJoinState))
assertLines(deleteJoinState, { "abcdef" })
assert(deleteJoinState.cursorColumn == 4)
assert(deleteJoinState.byteLength == 6)

local movementState = newBuffer("long\nx")
movementState.cursorColumn = 5
buffer.moveDown(movementState)
assert(movementState.cursorLine == 2)
assert(movementState.cursorColumn == 2)
buffer.moveUp(movementState)
assert(movementState.cursorLine == 1)
assert(movementState.cursorColumn == 2)
buffer.moveEnd(movementState)
assert(movementState.cursorColumn == 5)
buffer.moveHome(movementState)
assert(movementState.cursorColumn == 1)
buffer.moveLeft(movementState)
assert(movementState.cursorColumn == 1)
buffer.moveRight(movementState)
assert(movementState.cursorColumn == 2)

movementState.cursorLine = 2
movementState.cursorColumn = 2
buffer.moveRight(movementState)
assert(movementState.cursorLine == 2)
assert(movementState.cursorColumn == 2)
buffer.movePage(movementState, -20)
assert(movementState.cursorLine == 1)
buffer.movePage(movementState, 20)
assert(movementState.cursorLine == 2)

local pasteState = newBuffer("ab")
pasteState.cursorColumn = 2
buffer.insertText(pasteState, "X\nY\n")
assertLines(pasteState, { "aX", "Y", "b" })
assert(pasteState.cursorLine == 3)
assert(pasteState.cursorColumn == 1)

-- VIEWPORT -----------------------------------------------------------------

local manyLines = {}

for lineIndex = 1, 30 do
    manyLines[lineIndex] = "line " .. lineIndex
end

local verticalViewportState = buffer.new(manyLines, "/many.txt")
verticalViewportState.cursorLine = 30
verticalViewportState.cursorColumn = 1
buffer.ensureCursorVisible(verticalViewportState, 20, 5)
assert(verticalViewportState.scrollY == 26)
assert(verticalViewportState.cursorLine >= verticalViewportState.scrollY)
assert(verticalViewportState.cursorLine <=
    verticalViewportState.scrollY + 4)

verticalViewportState.cursorLine = 1
buffer.ensureCursorVisible(verticalViewportState, 20, 5)
assert(verticalViewportState.scrollY == 1)

local horizontalViewportState = newBuffer(string.rep("x", 80))
horizontalViewportState.cursorColumn = 81
buffer.ensureCursorVisible(horizontalViewportState, 12, 4)
assert(horizontalViewportState.scrollX == 70)
assert(horizontalViewportState.cursorColumn >=
    horizontalViewportState.scrollX)
assert(horizontalViewportState.cursorColumn <=
    horizontalViewportState.scrollX + 11)

buffer.moveHome(horizontalViewportState)
buffer.ensureCursorVisible(horizontalViewportState, 12, 4)
assert(horizontalViewportState.scrollX == 1)

local mouseViewportState = buffer.new(manyLines, "/mouse.txt")
local mouseTextBefore = buffer.serialize(mouseViewportState)

buffer.scrollVertically(mouseViewportState, 3, 5)
assert(mouseViewportState.scrollY == 4)
assert(mouseViewportState.cursorLine == 4)
assert(not mouseViewportState.dirty)
assert(buffer.serialize(mouseViewportState) == mouseTextBefore)

buffer.scrollVertically(mouseViewportState, 100, 5)
assert(mouseViewportState.scrollY == 26)
assert(mouseViewportState.cursorLine == 26)

-- The cursor remains unchanged because line 26 is still visible after this
-- upward wheel movement (the new viewport covers lines 23 through 27).
buffer.scrollVertically(mouseViewportState, -3, 5)
assert(mouseViewportState.scrollY == 23)
assert(mouseViewportState.cursorLine == 26)

buffer.scrollVertically(mouseViewportState, -100, 5)
assert(mouseViewportState.scrollY == 1)
assert(mouseViewportState.cursorLine == 5)
assert(not mouseViewportState.dirty)
assert(buffer.serialize(mouseViewportState) == mouseTextBefore)

-- Page movement still moves the cursor first, after which the existing
-- cursor-visibility rule advances or restores the keyboard viewport.
local keyboardViewportState = buffer.new(manyLines, "/keyboard-scroll.txt")
buffer.movePage(keyboardViewportState, 5)
buffer.ensureCursorVisible(keyboardViewportState, 20, 5)
assert(keyboardViewportState.cursorLine == 6)
assert(keyboardViewportState.scrollY == 2)
buffer.movePage(keyboardViewportState, -5)
buffer.ensureCursorVisible(keyboardViewportState, 20, 5)
assert(keyboardViewportState.cursorLine == 1)
assert(keyboardViewportState.scrollY == 1)

-- EDITOR PROGRAM HARNESS ---------------------------------------------------

local keysMock = {
    leftCtrl = 1,
    rightCtrl = 2,
    s = 3,
    q = 4,
    escape = 5,
    left = 6,
    right = 7,
    up = 8,
    down = 9,
    home = 10,
    ["end"] = 11,
    pageUp = 12,
    pageDown = 13,
    enter = 14,
    backspace = 15,
    delete = 16,
    tab = 17,
}

local colorsMock = {
    black = 1,
    white = 2,
    lightGray = 3,
    lightBlue = 4,
    lime = 5,
    yellow = 6,
    red = 7,
}

local function appendControlKey(events, keyCode, repeated)
    events[#events + 1] = { "key", keysMock.leftCtrl, false }
    events[#events + 1] = { "key", keyCode, repeated == true }
    events[#events + 1] = { "key_up", keysMock.leftCtrl }
end

local function copyTable(source)
    local copied = {}

    for key, value in pairs(source or {}) do
        copied[key] = value
    end

    return copied
end

local function runEditor(options)
    options = options or {}

    local state = {
        background = nil,
        blink = nil,
        cursorX = 1,
        cursorY = 1,
        confirmationIndex = 0,
        confirmationReads = 0,
        eventIndex = 0,
        files = copyTable(options.files),
        frames = {},
        inspectedPaths = {},
        output = {},
        screen = {},
        textColor = nil,
        width = options.width or 51,
        height = options.height or 19,
        writeCloseCalls = 0,
        writePaths = {},
    }
    local directories = copyTable(options.directories)

    local function blankRow()
        return string.rep(" ", state.width)
    end

    local function clearScreen()
        state.screen = {}

        for row = 1, state.height do
            state.screen[row] = blankRow()
        end
    end

    local function replaceAt(text, position, replacement)
        local prefix = string.sub(text, 1, position - 1)
        local suffixStart = position + #replacement
        local suffix = string.sub(text, suffixStart)

        return prefix .. replacement .. suffix
    end

    local termMock = {}

    termMock.getSize = function()
        return state.width, state.height
    end

    termMock.setBackgroundColor = function(color)
        state.background = color
    end

    termMock.setTextColor = function(color)
        state.textColor = color
    end

    termMock.setCursorBlink = function(blink)
        state.blink = blink
    end

    termMock.setCursorPos = function(x, y)
        assert(x >= 1 and x <= state.width)
        assert(y >= 1 and y <= state.height)
        state.cursorX = x
        state.cursorY = y
    end

    termMock.getCursorPos = function()
        return state.cursorX, state.cursorY
    end

    termMock.clear = function()
        clearScreen()
    end

    termMock.clearLine = function()
        state.screen[state.cursorY] = blankRow()
        state.cursorX = 1
    end

    termMock.write = function(value)
        local text = tostring(value)

        assert(state.cursorX + #text - 1 <= state.width)
        state.screen[state.cursorY] = replaceAt(
            state.screen[state.cursorY],
            state.cursorX,
            text
        )
        state.cursorX = state.cursorX + #text
    end

    clearScreen()

    local fsMock = {}

    fsMock.exists = function(path)
        state.inspectedPaths[#state.inspectedPaths + 1] = path
        return state.files[path] ~= nil or directories[path] == true
    end

    fsMock.isDir = function(path)
        return directories[path] == true
    end

    fsMock.getSize = function(path)
        if options.reportedSize ~= nil then
            return options.reportedSize
        end

        return #assert(state.files[path])
    end

    fsMock.open = function(path, mode)
        if mode == "r" then
            if options.readOpenFailure then
                return nil, "simulated read open failure"
            end

            local contents = assert(state.files[path])

            return {
                readAll = function()
                    if options.readFailure then
                        error("simulated read failure", 0)
                    end

                    return contents
                end,
                close = function()
                    if options.readCloseFailure then
                        error("simulated read close failure", 0)
                    end
                end,
            }
        end

        assert(mode == "w")
        state.writePaths[#state.writePaths + 1] = path

        if options.writeOpenFailure then
            return nil, "simulated write open failure"
        end

        -- CC:T creates/truncates only after a writable handle is obtained.
        state.files[path] = ""

        return {
            write = function(contents)
                if options.writeFailure then
                    error("simulated write failure", 0)
                end

                state.files[path] = contents
            end,
            close = function()
                state.writeCloseCalls = state.writeCloseCalls + 1

                if options.writeCloseFailure then
                    error("simulated write close failure", 0)
                end
            end,
        }
    end

    local environment = {
        colors = colorsMock,
        fs = fsMock,
        keys = keysMock,
        term = termMock,
    }

    environment.print = function(...)
        local values = { ... }

        for valueIndex, value in ipairs(values) do
            values[valueIndex] = tostring(value)
        end

        state.output[#state.output + 1] = table.concat(values, "\t")
    end

    environment.write = function(value)
        state.output[#state.output + 1] = tostring(value or "")
    end

    environment.read = function()
        state.confirmationReads = state.confirmationReads + 1
        state.confirmationIndex = state.confirmationIndex + 1
        local value = (options.confirmations or {})[state.confirmationIndex]

        if type(value) == "table" and value.error ~= nil then
            error(value.error, 0)
        end

        return value
    end

    environment.os = {
        pullEvent = function()
            state.frames[#state.frames + 1] =
                table.concat(state.screen, "\n")
            state.eventIndex = state.eventIndex + 1

            local event = (options.events or {})[state.eventIndex]

            if event == nil then
                error(TEST_STOP, 0)
            end

            if event[1] == "__terminate" then
                error("Terminated", 0)
            end

            if event[1] == "__resize" then
                state.width = event[2]
                state.height = event[3]
                clearScreen()
                return "term_resize"
            end

            return table.unpack(event)
        end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        if path == INSTALLED_BUFFER_PATH then
            return hostLoadfile(BUFFER_SOURCE, "t", environment)
        end

        if path == INSTALLED_GUARD_PATH then
            return hostLoadfile(GUARD_SOURCE, "t", environment)
        end

        error("unexpected editor load path: " .. tostring(path), 0)
    end

    local editorProgram = assert(hostLoadfile(
        EDITOR_SOURCE,
        "t",
        environment
    ))
    local commandContext = options.context or {
        cwd = "/dickos/home/bootstrap/projects",
        home = "/dickos/home/bootstrap",
        effectiveUser = "bootstrap",
        effectiveUID = 1000,
        isAdmin = true,
        isElevated = false,
    }
    local succeeded, failure

    if options.extraArgument ~= nil then
        succeeded, failure = pcall(
            editorProgram,
            commandContext,
            options.requestedPath or "test.txt",
            options.extraArgument
        )
    else
        succeeded, failure = pcall(
            editorProgram,
            commandContext,
            options.requestedPath or "test.txt"
        )
    end

    state.outputText = table.concat(state.output, "\n")
    state.framesText = table.concat(state.frames, "\n--- FRAME ---\n")

    return state, succeeded, failure
end

local function cleanQuitEvents()
    local events = {}
    appendControlKey(events, keysMock.q)
    return events
end

-- PATH ---------------------------------------------------------------------

local pathCases = {
    { "file.txt", "/dickos/home/bootstrap/projects/file.txt" },
    { "./file.txt", "/dickos/home/bootstrap/projects/file.txt" },
    { "../file.txt", "/dickos/home/bootstrap/file.txt" },
    { "/absolute/file.txt", "/absolute/file.txt" },
    { "~/file.txt", "/dickos/home/bootstrap/file.txt" },
    { "../../../../root.txt", "/root.txt" },
}

for _, pathCase in ipairs(pathCases) do
    local state, succeeded, failure = runEditor({
        requestedPath = pathCase[1],
        events = cleanQuitEvents(),
    })

    assert(succeeded, tostring(failure))
    assert(state.inspectedPaths[1] == pathCase[2])
end

local protectedState, protectedSucceeded, protectedFailure = runEditor({
    requestedPath = "/dickos/etc/system.cfg",
})
assert(not protectedSucceeded)
assertContains(protectedFailure, "use sudo")
assert(protectedState.inspectedPaths[1] == "/dickos/etc/system.cfg")
assert(protectedState.confirmationReads == 0)

local elevatedEditorContext = {
    cwd = "/dickos/home/bootstrap/projects",
    home = "/dickos/home/bootstrap",
    effectiveUser = "root",
    effectiveUID = 0,
    isAdmin = true,
    isElevated = true,
}
local elevatedProtectedState, elevatedProtectedSucceeded,
    elevatedProtectedFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = "/dickos/etc/system.cfg",
        events = cleanQuitEvents(),
    })
assert(elevatedProtectedSucceeded, tostring(elevatedProtectedFailure))
assert(elevatedProtectedState.confirmationReads == 0)

local criticalCancelledState, criticalCancelledSucceeded,
    criticalCancelledFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = "/startup.lua",
        confirmations = { "/startup.lua-wrong" },
    })
assert(criticalCancelledSucceeded, tostring(criticalCancelledFailure))
assert(criticalCancelledState.confirmationReads == 1)
assert(criticalCancelledState.inspectedPaths[1] == "/startup.lua")
assertContains(criticalCancelledState.outputText, "Operation cancelled.")

local criticalTerminatedState, criticalTerminatedSucceeded,
    criticalTerminatedFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = "/startup.lua",
        confirmations = { { error = "Terminated" } },
    })
assert(criticalTerminatedSucceeded, tostring(criticalTerminatedFailure))
assert(criticalTerminatedState.confirmationReads == 1)
assert(criticalTerminatedState.inspectedPaths[1] == "/startup.lua")

local criticalOpenedState, criticalOpenedSucceeded, criticalOpenedFailure =
    runEditor({
        context = elevatedEditorContext,
        requestedPath = "/startup.lua",
        confirmations = { "/startup.lua" },
        files = { ["/startup.lua"] = "boot" },
        events = cleanQuitEvents(),
    })
assert(criticalOpenedSucceeded, tostring(criticalOpenedFailure))
assert(criticalOpenedState.confirmationReads == 1)
assert(criticalOpenedState.inspectedPaths[1] == "/startup.lua")

local criticalSaveEvents = { { "char", "x" } }
appendControlKey(criticalSaveEvents, keysMock.s)
appendControlKey(criticalSaveEvents, keysMock.s)
appendControlKey(criticalSaveEvents, keysMock.q)
local criticalSaveState, criticalSaveSucceeded, criticalSaveFailure =
    runEditor({
        context = elevatedEditorContext,
        requestedPath = "/startup.lua",
        confirmations = { "/startup.lua" },
        files = { ["/startup.lua"] = "boot" },
        events = criticalSaveEvents,
    })
assert(criticalSaveSucceeded, tostring(criticalSaveFailure))
assert(criticalSaveState.confirmationReads == 1)
assert(criticalSaveState.files["/startup.lua"] == "xboot")

-- Exact `/startup` and every descendant are CraftOS startup paths. Normal
-- editing is denied before the full-screen UI, while an elevated invocation
-- must type the particular target before even a missing document is opened.
for _, startupPath in ipairs({ "/startup", "/startup/test.lua" }) do
    local deniedState, deniedSucceeded, deniedFailure = runEditor({
        requestedPath = startupPath,
    })
    assert(not deniedSucceeded)
    assertContains(deniedFailure, "use sudo")
    assert(deniedState.confirmationReads == 0)
    assert(#deniedState.frames == 0)
    assert(#deniedState.writePaths == 0)

    local wrongState, wrongSucceeded, wrongFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = startupPath,
        confirmations = { startupPath .. "-wrong" },
    })
    assert(wrongSucceeded, tostring(wrongFailure))
    assert(wrongState.confirmationReads == 1)
    assert(#wrongState.frames == 0)
    assert(#wrongState.writePaths == 0)
    assert(wrongState.files[startupPath] == nil)

    local terminatedState, terminatedSucceeded, terminatedFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = startupPath,
        confirmations = { { error = "Terminated" } },
    })
    assert(terminatedSucceeded, tostring(terminatedFailure))
    assert(terminatedState.confirmationReads == 1)
    assert(#terminatedState.frames == 0)
    assert(#terminatedState.writePaths == 0)
    assert(terminatedState.files[startupPath] == nil)

    local openedState, openedSucceeded, openedFailure = runEditor({
        context = elevatedEditorContext,
        requestedPath = startupPath,
        confirmations = { startupPath },
        events = cleanQuitEvents(),
    })
    assert(openedSucceeded, tostring(openedFailure))
    assert(openedState.confirmationReads == 1)
    assert(#openedState.frames > 0)
    assert(#openedState.writePaths == 0)
end

local homeState, homeSucceeded, homeFailure = runEditor({
    requestedPath = "~",
    directories = { ["/dickos/home/bootstrap"] = true },
})
assert(not homeSucceeded)
assert(homeState.inspectedPaths[1] == "/dickos/home/bootstrap")
assertContains(homeFailure, "cannot edit a directory")

local _, invalidContextSucceeded, invalidContextFailure = runEditor({
    context = {},
})
assert(not invalidContextSucceeded)
assert(tostring(invalidContextFailure) ==
    "edit requires DICK command context.")

local helpState, helpSucceeded, helpFailure = runEditor({
    requestedPath = "--help",
})
assert(helpSucceeded, tostring(helpFailure))
assert(helpState.outputText == "Usage: edit <file>")

local _, extraSucceeded, extraFailure = runEditor({
    requestedPath = "one.txt",
    extraArgument = "two.txt",
})
assert(not extraSucceeded)
assert(tostring(extraFailure) == "Usage: edit <file>")

-- FILE I/O -----------------------------------------------------------------

local fileCases = {
    "",
    "one line",
    "one\ntwo",
    "one\n",
    "one\n\n",
}

for caseIndex, contents in ipairs(fileCases) do
    local target = "/round-trip-" .. caseIndex .. ".txt"
    local events = {}

    appendControlKey(events, keysMock.s)
    appendControlKey(events, keysMock.q)

    local state, succeeded, failure = runEditor({
        requestedPath = target,
        files = { [target] = contents },
        events = events,
    })

    assert(succeeded, tostring(failure))
    assert(state.files[target] == contents)
end

local missingPath = "/dickos/home/bootstrap/projects/new.txt"
local unopenedState, unopenedSucceeded, unopenedFailure = runEditor({
    requestedPath = "new.txt",
    events = cleanQuitEvents(),
})
assert(unopenedSucceeded, tostring(unopenedFailure))
assert(unopenedState.files[missingPath] == nil)
assert(#unopenedState.writePaths == 0)

local createEvents = {}
appendControlKey(createEvents, keysMock.s)
appendControlKey(createEvents, keysMock.q)
local createdState, createdSucceeded, createdFailure = runEditor({
    requestedPath = "new.txt",
    events = createEvents,
})
assert(createdSucceeded, tostring(createdFailure))
assert(createdState.files[missingPath] == "")

local keyboardSaveEvents = {
    { "char", "a" },
    { "key", keysMock.enter, false },
    { "char", "b" },
    { "key", keysMock.tab, false },
    { "char", "c" },
}
appendControlKey(keyboardSaveEvents, keysMock.s)
appendControlKey(keyboardSaveEvents, keysMock.q)
local keyboardPath = "/keyboard.txt"
local keyboardState, keyboardSucceeded, keyboardFailure = runEditor({
    requestedPath = keyboardPath,
    events = keyboardSaveEvents,
})
assert(keyboardSucceeded, tostring(keyboardFailure))
assert(keyboardState.files[keyboardPath] == "a\nb    c")

-- Ctrl may still be down when CC:T delivers the authoritative paste event.
-- Saving afterwards proves that the event reached the real editor event loop,
-- not merely the pure buffer helper.
local controlPasteEvents = {
    { "key", keysMock.leftCtrl, false },
    { "paste", "pasted-word" },
    { "key_up", keysMock.leftCtrl },
}
appendControlKey(controlPasteEvents, keysMock.s)
appendControlKey(controlPasteEvents, keysMock.q)
local controlPastePath = "/control-paste.txt"
local controlPasteState, controlPasteSucceeded, controlPasteFailure =
    runEditor({
        requestedPath = controlPastePath,
        events = controlPasteEvents,
    })
assert(controlPasteSucceeded, tostring(controlPasteFailure))
assert(controlPasteState.files[controlPastePath] == "pasted-word")

-- This deliberately injects a newline-containing paste event. It verifies the
-- editor's internal event/buffer handling, not normal Minecraft Ctrl+V: the
-- standard CC:T client clipboard path only delivers the first clipboard line.
local multilinePasteEvents = {
    { "key", keysMock.leftCtrl, false },
    { "paste", "first\nsecond\n" },
    { "key_up", keysMock.leftCtrl },
}
appendControlKey(multilinePasteEvents, keysMock.s)
appendControlKey(multilinePasteEvents, keysMock.q)
local multilinePastePath = "/multiline-paste.txt"
local multilinePasteState, multilinePasteSucceeded, multilinePasteFailure =
    runEditor({
        requestedPath = multilinePastePath,
        events = multilinePasteEvents,
    })
assert(multilinePasteSucceeded, tostring(multilinePasteFailure))
assert(multilinePasteState.files[multilinePastePath] ==
    "first\nsecond\n")

local directoryPath = "/dickos/home/bootstrap/projects/folder"
local _, directorySucceeded, directoryFailure = runEditor({
    requestedPath = "folder",
    directories = { [directoryPath] = true },
})
assert(not directorySucceeded)
assertContains(directoryFailure, "cannot edit a directory")

local readPath = "/read-failure.txt"
local _, readSucceeded, readFailure = runEditor({
    requestedPath = readPath,
    files = { [readPath] = "contents" },
    readFailure = true,
})
assert(not readSucceeded)
assertContains(readFailure, "simulated read failure")

local largePath = "/large.txt"
local _, largeSucceeded, largeFailure = runEditor({
    requestedPath = largePath,
    files = { [largePath] = "small mock body" },
    reportedSize = 256 * 1024 + 1,
})
assert(not largeSucceeded)
assert(tostring(largeFailure) == "File is too large for DICK EDIT.")

local limitPath = "/at-limit.txt"
local limitState, limitSucceeded, limitFailure = runEditor({
    requestedPath = limitPath,
    files = { [limitPath] = string.rep("x", 256 * 1024) },
    events = {
        { "key", keysMock.leftCtrl, false },
        { "paste", "y" },
        { "key_up", keysMock.leftCtrl },
        { "key", keysMock.leftCtrl, false },
        { "key", keysMock.q, false },
    },
})
assert(limitSucceeded, tostring(limitFailure))
assertContains(limitState.framesText, "Edit limit reached:")
assert(#limitState.writePaths == 0)

-- SAVE FAILURE / QUIT ------------------------------------------------------

local failedSaveEvents = { { "char", "x" } }
appendControlKey(failedSaveEvents, keysMock.s)
appendControlKey(failedSaveEvents, keysMock.q)
appendControlKey(failedSaveEvents, keysMock.q)

local failedSavePath = "/failed-save.txt"
local failedSaveState, failedSaveSucceeded, failedSaveFailure = runEditor({
    requestedPath = failedSavePath,
    files = { [failedSavePath] = "old" },
    events = failedSaveEvents,
    writeOpenFailure = true,
})
assert(failedSaveSucceeded, tostring(failedSaveFailure))
assert(failedSaveState.files[failedSavePath] == "old")
assertContains(failedSaveState.framesText, "Save failed:")
assertContains(failedSaveState.framesText, "Unsaved changes.")

local failedWriteEvents = { { "char", "x" } }
appendControlKey(failedWriteEvents, keysMock.s)
appendControlKey(failedWriteEvents, keysMock.q)
appendControlKey(failedWriteEvents, keysMock.q)
local failedWritePath = "/failed-write.txt"
local failedWriteState, failedWriteSucceeded, failedWriteFailure = runEditor({
    requestedPath = failedWritePath,
    files = { [failedWritePath] = "old" },
    events = failedWriteEvents,
    writeFailure = true,
})
assert(failedWriteSucceeded, tostring(failedWriteFailure))
assert(failedWriteState.writeCloseCalls == 1)
assertContains(failedWriteState.framesText, "simulated write failure")
assertContains(failedWriteState.framesText, "Unsaved changes.")

local cleanState, cleanSucceeded, cleanFailure = runEditor({
    events = cleanQuitEvents(),
})
assert(cleanSucceeded, tostring(cleanFailure))
assert(cleanState.background == colorsMock.black)
assert(cleanState.textColor == colorsMock.white)
assert(cleanState.blink == true)
assertContains(cleanState.frames[1], "DICK EDIT")
assertContains(cleanState.frames[1], "1 | ")
assertContains(cleanState.frames[1], "Ctrl+S Save  Ctrl+Q Quit")

local scrollContents = table.concat(manyLines, "\n")
local mouseScrollEvents = {
    { "mouse_scroll", 1, 10, 10 },
    { "mouse_scroll", 1, 10, 10 },
    { "mouse_scroll", -1, 10, 10 },
}
appendControlKey(mouseScrollEvents, keysMock.q)
local mouseScrollPath = "/mouse-scroll.txt"
local mouseScrollState, mouseScrollSucceeded, mouseScrollFailure = runEditor({
    requestedPath = mouseScrollPath,
    files = { [mouseScrollPath] = scrollContents },
    events = mouseScrollEvents,
})
assert(mouseScrollSucceeded, tostring(mouseScrollFailure))
assertContains(mouseScrollState.frames[1], " 1 | line 1")
assertContains(mouseScrollState.frames[2], " 4 | line 4")
assertNotContains(mouseScrollState.frames[2], " 1 | line 1")
assertContains(mouseScrollState.frames[3], " 7 | line 7")
assertContains(mouseScrollState.frames[4], " 4 | line 4")
assert(mouseScrollState.files[mouseScrollPath] == scrollContents)
assert(#mouseScrollState.writePaths == 0)

local keyboardScrollEvents = {
    { "key", keysMock.pageDown, false },
    { "key", keysMock.pageUp, false },
}
appendControlKey(keyboardScrollEvents, keysMock.q)
local keyboardScrollState, keyboardScrollSucceeded, keyboardScrollFailure =
    runEditor({
        requestedPath = mouseScrollPath,
        files = { [mouseScrollPath] = scrollContents },
        events = keyboardScrollEvents,
    })
assert(keyboardScrollSucceeded, tostring(keyboardScrollFailure))
assertContains(keyboardScrollState.frames[2], " 2 | line 2")
assertContains(keyboardScrollState.frames[2], "16 | line 16")
assertContains(keyboardScrollState.frames[3], " 1 | line 1")

local expandingGutterEvents = { { "key", keysMock.enter, false } }
appendControlKey(expandingGutterEvents, keysMock.q)
appendControlKey(expandingGutterEvents, keysMock.q)
local gutterPath = "/nine-lines.txt"
local expandingGutterState, gutterSucceeded, gutterFailure = runEditor({
    requestedPath = gutterPath,
    files = { [gutterPath] = string.rep("\n", 8) },
    events = expandingGutterEvents,
})
assert(gutterSucceeded, tostring(gutterFailure))
assertContains(expandingGutterState.framesText, " 1 | ")
assertContains(expandingGutterState.framesText, "10 | ")

local discardEvents = { { "char", "x" } }
appendControlKey(discardEvents, keysMock.q)
appendControlKey(discardEvents, keysMock.q)
local discardState, discardSucceeded, discardFailure = runEditor({
    events = discardEvents,
})
assert(discardSucceeded, tostring(discardFailure))
assertContains(discardState.framesText, "Unsaved changes.")
assert(#discardState.writePaths == 0)

local cancelEvents = { { "char", "x" } }
appendControlKey(cancelEvents, keysMock.q)
cancelEvents[#cancelEvents + 1] = { "key", keysMock.escape, false }
appendControlKey(cancelEvents, keysMock.q)
appendControlKey(cancelEvents, keysMock.q)
local cancelState, cancelSucceeded, cancelFailure = runEditor({
    events = cancelEvents,
})
assert(cancelSucceeded, tostring(cancelFailure))
assertContains(cancelState.framesText, "Unsaved changes.")
assertContains(cancelState.framesText, "Ctrl+S Save  Ctrl+Q Quit")

-- Pasting is an editing action, so it cancels an older discard confirmation.
-- If the confirmation remained armed, the first Ctrl+Q after paste would exit
-- at event 9 instead of arming a fresh warning and reaching event 12.
local pasteCancelEvents = { { "char", "x" } }
appendControlKey(pasteCancelEvents, keysMock.q)
pasteCancelEvents[#pasteCancelEvents + 1] = {
    "key",
    keysMock.leftCtrl,
    false,
}
pasteCancelEvents[#pasteCancelEvents + 1] = { "paste", "y" }
pasteCancelEvents[#pasteCancelEvents + 1] = {
    "key_up",
    keysMock.leftCtrl,
}
appendControlKey(pasteCancelEvents, keysMock.q)
appendControlKey(pasteCancelEvents, keysMock.q)
local pasteCancelState, pasteCancelSucceeded, pasteCancelFailure = runEditor({
    events = pasteCancelEvents,
})
assert(pasteCancelSucceeded, tostring(pasteCancelFailure))
assert(pasteCancelState.eventIndex == 12)

-- A repeated Q key must not satisfy discard confirmation by itself. The next
-- Escape proves the editor remained alive after the repeat event.
local repeatEvents = { { "char", "x" } }
appendControlKey(repeatEvents, keysMock.q)
repeatEvents[#repeatEvents + 1] = { "key", keysMock.leftCtrl, false }
repeatEvents[#repeatEvents + 1] = { "key", keysMock.q, true }
repeatEvents[#repeatEvents + 1] = { "key_up", keysMock.leftCtrl }
repeatEvents[#repeatEvents + 1] = { "key", keysMock.escape, false }
appendControlKey(repeatEvents, keysMock.q)
appendControlKey(repeatEvents, keysMock.q)
local _, repeatSucceeded, repeatFailure = runEditor({ events = repeatEvents })
assert(repeatSucceeded, tostring(repeatFailure))

local smallState, smallSucceeded, smallFailure = runEditor({
    width = 30,
    height = 6,
})
assert(smallSucceeded, tostring(smallFailure))
assertContains(smallState.outputText, "terminal is too small")

local resizedState, resizedSucceeded, resizedFailure = runEditor({
    events = { { "__resize", 30, 6 } },
})
assert(resizedSucceeded, tostring(resizedFailure))
assertContains(resizedState.outputText, "terminal is too small")

-- `os.pullEvent` termination must escape the editor unchanged. The existing
-- DICK shell child boundary is then responsible for `Command terminated.` and
-- terminal cleanup; the editor never converts this into normal Quit/Recovery.
local _, terminateSucceeded, terminateFailure = runEditor({
    events = { { "__terminate" } },
})
assert(not terminateSucceeded)
assert(tostring(terminateFailure) == "Terminated")

io.stdout:write("native editor tests: PASS\n")
