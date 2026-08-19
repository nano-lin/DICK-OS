-- Host-side tests for safe DICK/OS filesystem coreutils
-- Run with: lua tests/coreutils_test.lua

local hostLoadfile = loadfile
local GUARD_PATH = "/dickos/lib/fs_guard.lua"

local normalContext = {
    bootID = "B-1234ABCD",
    user = "nano",
    uid = 1000,
    effectiveUser = "nano",
    effectiveUID = 1000,
    isAdmin = true,
    isElevated = false,
    home = "/dickos/home/nano",
    cwd = "/dickos/home/nano/work",
}
local elevatedContext = {
    bootID = "B-1234ABCD",
    user = "nano",
    uid = 1000,
    effectiveUser = "root",
    effectiveUID = 0,
    isAdmin = true,
    isElevated = true,
    home = normalContext.home,
    cwd = normalContext.cwd,
}

local function copyTable(source)
    local copied = {}
    for key, value in pairs(source or {}) do copied[key] = value end
    return copied
end

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function isWithin(path, boundary)
    return path == boundary or
        string.sub(path, 1, #boundary + 1) == boundary .. "/"
end

local function runCommand(commandName, context, arguments, options)
    options = options or {}

    local defaultDirectories = {
        ["/"] = true,
        ["/outside"] = true,
        ["/dickos"] = true,
        ["/dickos/bin"] = true,
        ["/dickos/etc"] = true,
        ["/dickos/home"] = true,
        ["/dickos/home/nano"] = true,
        ["/dickos/home/nano/work"] = true,
        ["/dickos/home/other"] = true,
        ["/dickos/lib"] = true,
        ["/dickos/system"] = true,
        ["/dickos/tmp"] = true,
    }
    local state = {
        confirmations = copyTable(options.confirmations),
        confirmationIndex = 0,
        copied = {},
        deleted = {},
        directories = copyTable(defaultDirectories),
        files = copyTable(options.files),
        madeDirectories = {},
        moved = {},
        mutationCount = 0,
        output = {},
        writeOpens = {},
    }

    for path, present in pairs(options.directories or {}) do
        state.directories[path] = present
    end

    local fsMock = {}
    fsMock.exists = function(path)
        return state.directories[path] == true or state.files[path] ~= nil
    end
    fsMock.isDir = function(path)
        return state.directories[path] == true
    end
    fsMock.open = function(path, mode)
        assert(mode == "w")
        state.mutationCount = state.mutationCount + 1
        state.writeOpens[#state.writeOpens + 1] = path
        state.files[path] = ""

        return {
            close = function()
                if options.closeFailure then
                    error("simulated close failure", 0)
                end
            end,
        }
    end
    fsMock.makeDir = function(path)
        state.mutationCount = state.mutationCount + 1
        state.madeDirectories[#state.madeDirectories + 1] = path
        state.directories[path] = true
    end
    fsMock.copy = function(source, destination)
        if options.copyFailure then error("simulated copy failure", 0) end

        state.mutationCount = state.mutationCount + 1
        state.copied[#state.copied + 1] = { source, destination }

        if state.directories[source] then
            state.directories[destination] = true

            for path in pairs(copyTable(state.directories)) do
                if isWithin(path, source) and path ~= source then
                    local suffix = string.sub(path, #source + 1)
                    state.directories[destination .. suffix] = true
                end
            end

            for path, contents in pairs(copyTable(state.files)) do
                if isWithin(path, source) then
                    local suffix = string.sub(path, #source + 1)
                    state.files[destination .. suffix] = contents
                end
            end
        else
            state.files[destination] = assert(state.files[source])
        end
    end
    fsMock.delete = function(path)
        state.mutationCount = state.mutationCount + 1
        state.deleted[#state.deleted + 1] = path

        for candidate in pairs(copyTable(state.files)) do
            if isWithin(candidate, path) then state.files[candidate] = nil end
        end
        for candidate in pairs(copyTable(state.directories)) do
            if isWithin(candidate, path) then
                state.directories[candidate] = nil
            end
        end
    end
    fsMock.move = function(source, destination)
        if options.moveFailure then error("simulated move failure", 0) end

        state.mutationCount = state.mutationCount + 1
        state.moved[#state.moved + 1] = { source, destination }

        if state.directories[source] then
            state.directories[destination] = true
            state.directories[source] = nil

            for path in pairs(copyTable(state.directories)) do
                if isWithin(path, source) then
                    local suffix = string.sub(path, #source + 1)
                    state.directories[destination .. suffix] = true
                    state.directories[path] = nil
                end
            end

            for path, contents in pairs(copyTable(state.files)) do
                if isWithin(path, source) then
                    local suffix = string.sub(path, #source + 1)
                    state.files[destination .. suffix] = contents
                    state.files[path] = nil
                end
            end
        else
            state.files[destination] = assert(state.files[source])
            state.files[source] = nil
        end
    end

    local environment = {
        colors = { white = 1, yellow = 2, red = 3 },
        fs = fsMock,
        term = { setTextColor = function() end },
    }
    environment.print = function(value)
        state.output[#state.output + 1] = tostring(value or "")
    end
    environment.write = function(value)
        state.output[#state.output + 1] = tostring(value or "")
    end
    environment.read = function()
        state.confirmationIndex = state.confirmationIndex + 1
        local value = state.confirmations[state.confirmationIndex]

        if type(value) == "table" and value.error ~= nil then
            error(value.error, 0)
        end

        return value
    end

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        if path == GUARD_PATH then
            return hostLoadfile("src/dickos/lib/fs_guard.lua", "t", environment)
        end

        return nil, "unexpected load path"
    end

    local program = assert(hostLoadfile(
        "src/dickos/bin/" .. commandName .. ".lua",
        "t",
        environment
    ))
    local invocation = { context }
    for _, argument in ipairs(arguments or {}) do
        invocation[#invocation + 1] = argument
    end
    local succeeded, failure = pcall(program, table.unpack(invocation))
    state.outputText = table.concat(state.output, "\n")
    return state, succeeded, failure
end

-- TOUCH -------------------------------------------------------------------

local touchState, touchSucceeded, touchError = runCommand(
    "touch",
    normalContext,
    { "new.txt", "/outside/new.txt" }
)
assert(touchSucceeded, tostring(touchError))
assert(touchState.files["/dickos/home/nano/work/new.txt"] == "")
assert(touchState.files["/outside/new.txt"] == "")

local unchangedState, unchangedSucceeded = runCommand(
    "touch",
    normalContext,
    { "existing.txt" },
    { files = { ["/dickos/home/nano/work/existing.txt"] = "keep" } }
)
assert(unchangedSucceeded)
assert(unchangedState.files["/dickos/home/nano/work/existing.txt"] == "keep")
assert(unchangedState.mutationCount == 0)

local partialTouchState, partialTouchSucceeded = runCommand(
    "touch",
    normalContext,
    { "would-create.txt", "/missing-parent/later.txt" }
)
assert(not partialTouchSucceeded)
assert(partialTouchState.mutationCount == 0)
assert(partialTouchState.files["/dickos/home/nano/work/would-create.txt"] == nil)

local _, directoryTouchSucceeded, directoryTouchError = runCommand(
    "touch",
    normalContext,
    { "." }
)
assert(not directoryTouchSucceeded)
assert(contains(directoryTouchError, "directory"))

local protectedTouchState, protectedTouchSucceeded, protectedTouchError =
    runCommand("touch", normalContext, { "/dickos/etc/new.cfg" })
assert(not protectedTouchSucceeded)
assert(protectedTouchState.mutationCount == 0)
assert(contains(protectedTouchError, "use sudo"))

local elevatedTouchState, elevatedTouchSucceeded = runCommand(
    "touch",
    elevatedContext,
    { "/dickos/etc/elevated.cfg" }
)
assert(elevatedTouchSucceeded)
assert(elevatedTouchState.files["/dickos/etc/elevated.cfg"] == "")

-- MKDIR -------------------------------------------------------------------

local mkdirState, mkdirSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "new-directory" }
)
assert(mkdirSucceeded)
assert(mkdirState.directories["/dickos/home/nano/work/new-directory"])

local existingMkdirState, existingMkdirSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "." }
)
assert(not existingMkdirSucceeded)
assert(existingMkdirState.mutationCount == 0)

local parentsState, parentsSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "-p", "one/two/three" }
)
assert(parentsSucceeded)
assert(parentsState.directories["/dickos/home/nano/work/one"])
assert(parentsState.directories["/dickos/home/nano/work/one/two"])
assert(parentsState.directories["/dickos/home/nano/work/one/two/three"])

local protectedParentsState, protectedParentsSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "-p", "/dickos/new/subdirectory" }
)
assert(not protectedParentsSucceeded)
assert(protectedParentsState.mutationCount == 0)

local fileComponentState, fileComponentSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "-p", "file/child" },
    { files = { ["/dickos/home/nano/work/file"] = "not a directory" } }
)
assert(not fileComponentSucceeded)
assert(fileComponentState.mutationCount == 0)

local partialMkdirState, partialMkdirSucceeded = runCommand(
    "mkdir",
    normalContext,
    { "first-directory", "/missing-parent/later-directory" }
)
assert(not partialMkdirSucceeded)
assert(partialMkdirState.mutationCount == 0)
assert(not partialMkdirState.directories[
    "/dickos/home/nano/work/first-directory"])

-- CP ----------------------------------------------------------------------

local cpState, cpSucceeded, cpError = runCommand(
    "cp",
    normalContext,
    { "source.txt", "copy.txt" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "contents" } }
)
assert(cpSucceeded, tostring(cpError))
assert(cpState.files["/dickos/home/nano/work/copy.txt"] == "contents")

local cpIntoDirectoryState, cpIntoDirectorySucceeded = runCommand(
    "cp",
    normalContext,
    { "source.txt", "/outside" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "contents" } }
)
assert(cpIntoDirectorySucceeded)
assert(cpIntoDirectoryState.files["/outside/source.txt"] == "contents")

local cpDirectoryState, cpDirectorySucceeded = runCommand(
    "cp",
    normalContext,
    { "-r", "tree", "tree-copy" },
    {
        directories = { ["/dickos/home/nano/work/tree"] = true },
        files = { ["/dickos/home/nano/work/tree/file"] = "contents" },
    }
)
assert(cpDirectorySucceeded)
assert(cpDirectoryState.files[
    "/dickos/home/nano/work/tree-copy/file"] == "contents")

local _, cpNeedsRecursive, cpRecursiveError = runCommand(
    "cp",
    normalContext,
    { "tree", "tree-copy" },
    { directories = { ["/dickos/home/nano/work/tree"] = true } }
)
assert(not cpNeedsRecursive and contains(cpRecursiveError, "use -r"))

local overwriteState, overwriteSucceeded = runCommand(
    "cp",
    normalContext,
    { "source.txt", "existing.txt" },
    {
        files = {
            ["/dickos/home/nano/work/source.txt"] = "source",
            ["/dickos/home/nano/work/existing.txt"] = "destination",
        },
    }
)
assert(not overwriteSucceeded)
assert(overwriteState.mutationCount == 0)
assert(overwriteState.files[
    "/dickos/home/nano/work/existing.txt"] == "destination")

local protectedReadState, protectedReadSucceeded = runCommand(
    "cp",
    normalContext,
    { "/dickos/etc/system.cfg", "read-copy.cfg" },
    { files = { ["/dickos/etc/system.cfg"] = "configuration" } }
)
assert(protectedReadSucceeded)
assert(protectedReadState.files[
    "/dickos/home/nano/work/read-copy.cfg"] == "configuration")

local protectedCopyState, protectedCopySucceeded = runCommand(
    "cp",
    normalContext,
    { "source.txt", "/dickos/etc/new.cfg" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "source" } }
)
assert(not protectedCopySucceeded)
assert(protectedCopyState.mutationCount == 0)

local elevatedCopyState, elevatedCopySucceeded = runCommand(
    "cp",
    elevatedContext,
    { "source.txt", "/dickos/etc/copied.cfg" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "source" } }
)
assert(elevatedCopySucceeded)
assert(elevatedCopyState.files["/dickos/etc/copied.cfg"] == "source")

local _, selfCopySucceeded, selfCopyError = runCommand(
    "cp",
    normalContext,
    { "-r", "tree", "tree/child" },
    { directories = { ["/dickos/home/nano/work/tree"] = true } }
)
assert(not selfCopySucceeded and contains(selfCopyError, "into itself"))

-- MV ----------------------------------------------------------------------

local mvState, mvSucceeded = runCommand(
    "mv",
    normalContext,
    { "source.txt", "moved.txt" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "contents" } }
)
assert(mvSucceeded)
assert(mvState.files["/dickos/home/nano/work/source.txt"] == nil)
assert(mvState.files["/dickos/home/nano/work/moved.txt"] == "contents")

local overwriteMoveState, overwriteMoveSucceeded = runCommand(
    "mv",
    normalContext,
    { "source.txt", "existing.txt" },
    {
        files = {
            ["/dickos/home/nano/work/source.txt"] = "source",
            ["/dickos/home/nano/work/existing.txt"] = "destination",
        },
    }
)
assert(not overwriteMoveSucceeded)
assert(overwriteMoveState.files[
    "/dickos/home/nano/work/source.txt"] == "source")
assert(overwriteMoveState.files[
    "/dickos/home/nano/work/existing.txt"] == "destination")

local protectedSourceState, protectedSourceSucceeded = runCommand(
    "mv",
    normalContext,
    { "/dickos/etc/system.cfg", "stolen.cfg" },
    { files = { ["/dickos/etc/system.cfg"] = "configuration" } }
)
assert(not protectedSourceSucceeded)
assert(protectedSourceState.files["/dickos/etc/system.cfg"] == "configuration")
assert(protectedSourceState.mutationCount == 0)

local protectedDestinationState, protectedDestinationSucceeded = runCommand(
    "mv",
    normalContext,
    { "source.txt", "/dickos/etc/moved.cfg" },
    { files = { ["/dickos/home/nano/work/source.txt"] = "contents" } }
)
assert(not protectedDestinationSucceeded)
assert(protectedDestinationState.files[
    "/dickos/home/nano/work/source.txt"] == "contents")
assert(protectedDestinationState.mutationCount == 0)

local elevatedSourceState, elevatedSourceSucceeded = runCommand(
    "mv",
    elevatedContext,
    { "/dickos/etc/system.cfg", "moved-out.cfg" },
    { files = { ["/dickos/etc/system.cfg"] = "configuration" } }
)
assert(elevatedSourceSucceeded)
assert(elevatedSourceState.files["/dickos/etc/system.cfg"] == nil)
assert(elevatedSourceState.files[
    "/dickos/home/nano/work/moved-out.cfg"] == "configuration")

local _, descendantMoveSucceeded, descendantMoveError = runCommand(
    "mv",
    normalContext,
    { "tree", "tree/child" },
    { directories = { ["/dickos/home/nano/work/tree"] = true } }
)
assert(not descendantMoveSucceeded)
assert(contains(descendantMoveError, "into itself"))

local failedMoveState, failedMoveSucceeded = runCommand(
    "mv",
    normalContext,
    { "source.txt", "moved.txt" },
    {
        files = { ["/dickos/home/nano/work/source.txt"] = "contents" },
        moveFailure = true,
    }
)
assert(not failedMoveSucceeded)
assert(failedMoveState.files["/dickos/home/nano/work/source.txt"] == "contents")
assert(failedMoveState.files["/dickos/home/nano/work/moved.txt"] == nil)

local cwdMoveState, cwdMoveSucceeded = runCommand(
    "mv",
    elevatedContext,
    { ".", "/outside/work" }
)
assert(not cwdMoveSucceeded and cwdMoveState.mutationCount == 0)

-- RM / CONFIRMATION -------------------------------------------------------

local rmState, rmSucceeded = runCommand(
    "rm",
    normalContext,
    { "file.txt" },
    { files = { ["/dickos/home/nano/work/file.txt"] = "contents" } }
)
assert(rmSucceeded)
assert(rmState.files["/dickos/home/nano/work/file.txt"] == nil)

local _, rmDirectorySucceeded, rmDirectoryError = runCommand(
    "rm",
    normalContext,
    { "directory" },
    { directories = { ["/dickos/home/nano/work/directory"] = true } }
)
assert(not rmDirectorySucceeded and contains(rmDirectoryError, "use -r"))

local recursiveState, recursiveSucceeded = runCommand(
    "rm",
    normalContext,
    { "-r", "directory" },
    {
        directories = { ["/dickos/home/nano/work/directory"] = true },
        files = { ["/dickos/home/nano/work/directory/file"] = "contents" },
    }
)
assert(recursiveSucceeded)
assert(not recursiveState.directories[
    "/dickos/home/nano/work/directory"])

local partialRmState, partialRmSucceeded = runCommand(
    "rm",
    normalContext,
    { "first.txt", "missing.txt" },
    { files = { ["/dickos/home/nano/work/first.txt"] = "contents" } }
)
assert(not partialRmSucceeded)
assert(partialRmState.mutationCount == 0)
assert(partialRmState.files[
    "/dickos/home/nano/work/first.txt"] == "contents")

local cwdRmState, cwdRmSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "-r", "/dickos/home/nano" }
)
assert(not cwdRmSucceeded and cwdRmState.mutationCount == 0)

local protectedRmState, protectedRmSucceeded = runCommand(
    "rm",
    normalContext,
    { "/dickos/etc/disposable.cfg" },
    { files = { ["/dickos/etc/disposable.cfg"] = "contents" } }
)
assert(not protectedRmSucceeded)
assert(protectedRmState.files["/dickos/etc/disposable.cfg"] == "contents")
assert(protectedRmState.mutationCount == 0)

local elevatedRmState, elevatedRmSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "/dickos/etc/disposable.cfg" },
    { files = { ["/dickos/etc/disposable.cfg"] = "contents" } }
)
assert(elevatedRmSucceeded)
assert(elevatedRmState.files["/dickos/etc/disposable.cfg"] == nil)

local wrongConfirmState, wrongConfirmSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "/startup.lua" },
    {
        files = { ["/startup.lua"] = "boot" },
        confirmations = { "/startup.lua-wrong" },
    }
)
assert(wrongConfirmSucceeded)
assert(wrongConfirmState.files["/startup.lua"] == "boot")
assert(wrongConfirmState.mutationCount == 0)
assert(contains(wrongConfirmState.outputText, "cancelled"))

local terminatedConfirmState, terminatedConfirmSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "/startup.lua" },
    {
        files = { ["/startup.lua"] = "boot" },
        confirmations = { { error = "Terminated" } },
    }
)
assert(terminatedConfirmSucceeded)
assert(terminatedConfirmState.files["/startup.lua"] == "boot")
assert(terminatedConfirmState.mutationCount == 0)

local confirmedState, confirmedSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "/startup.lua" },
    {
        files = { ["/startup.lua"] = "boot" },
        confirmations = { "/startup.lua" },
    }
)
assert(confirmedSucceeded)
assert(confirmedState.files["/startup.lua"] == nil)

local catastrophicState, catastrophicSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "-r", "/dickos" },
    { confirmations = { "/dickos" } }
)
-- `/dickos` contains the cwd, so the independent cwd-safety rule rejects it
-- even before catastrophic confirmation or mutation.
assert(not catastrophicSucceeded)
assert(catastrophicState.mutationCount == 0)
assert(contains(catastrophicState.outputText, "CATASTROPHIC"))

local rootCatastrophicState, rootCatastrophicSucceeded = runCommand(
    "rm",
    elevatedContext,
    { "-r", "/" },
    { confirmations = { "/" } }
)
assert(not rootCatastrophicSucceeded)
assert(rootCatastrophicState.mutationCount == 0)
assert(contains(rootCatastrophicState.outputText, "filesystem root"))

local catastrophicMoveState, catastrophicMoveSucceeded = runCommand(
    "mv",
    elevatedContext,
    { "/dickos", "/outside/dickos-backup" },
    { confirmations = { "/dickos" } }
)
assert(not catastrophicMoveSucceeded)
assert(catastrophicMoveState.mutationCount == 0)
assert(contains(catastrophicMoveState.outputText, "CATASTROPHIC"))

local forged = copyTable(normalContext)
forged.effectiveUser = "root"
forged.effectiveUID = 0
local forgedState, forgedSucceeded = runCommand(
    "touch",
    forged,
    { "/dickos/etc/forged.cfg" }
)
assert(not forgedSucceeded)
assert(forgedState.mutationCount == 0)

for _, commandName in ipairs({ "touch", "mkdir", "cp", "mv", "rm" }) do
    local helpState, helpSucceeded = runCommand(
        commandName,
        normalContext,
        { "--help" }
    )
    assert(helpSucceeded, commandName)
    assert(contains(helpState.outputText, "Usage:"))
    assert(helpState.mutationCount == 0)
end

io.stdout:write("filesystem coreutils tests: PASS\n")
