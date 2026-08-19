-- DICK/OS safe move command
-- Version: 0.1.0-unstable

local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local invocationArguments = { ... }
local context = table.remove(invocationArguments, 1)
local arguments = invocationArguments

local function usage()
    print("Usage: mv <source> <destination>")
    print("Existing destinations are never overwritten.")
end

if arguments[1] == "--help" and #arguments == 1 then
    usage()
    return
end

if #arguments ~= 2 or
    (type(arguments[1]) == "string" and
        string.sub(arguments[1], 1, 1) == "-") then
    error("Usage: mv <source> <destination>", 0)
end

local guardProgram, guardLoadError = loadfile(GUARD_PATH)

if type(guardProgram) ~= "function" then
    error("mv: unable to load filesystem guard: " ..
        tostring(guardLoadError), 0)
end

local guard = guardProgram()

if type(guard) ~= "table" or type(guard.resolve) ~= "function" or
    type(guard.normalize) ~= "function" or
    type(guard.inspect) ~= "function" or
    type(guard.authorize) ~= "function" or
    type(guard.confirm) ~= "function" or
    type(guard.parent) ~= "function" or
    type(guard.name) ~= "function" or
    type(guard.isWithin) ~= "function" then
    error("mv: invalid filesystem guard.", 0)
end

local source, sourceError = guard.resolve(context, arguments[1])
local destination, destinationError = guard.resolve(context, arguments[2])

if source == nil then
    error("mv: " .. tostring(sourceError) .. ".", 0)
end

if destination == nil then
    error("mv: " .. tostring(destinationError) .. ".", 0)
end

if not fs.exists(source) then
    error("mv: source does not exist: " .. source, 0)
end

-- Moving the cwd, or any directory which contains it, would leave the shell's
-- lexical cwd snapshot pointing into a path removed by its own child command.
local catastrophicSource = source == "/" or source == "/dickos"

if guard.isWithin(context.cwd, source) and not catastrophicSource then
    error("mv: cannot move the current working directory or its ancestor: " ..
        source, 0)
end

local sourceIsDirectory = fs.isDir(source)
local actualDestination = destination

if fs.exists(destination) and fs.isDir(destination) then
    local sourceName = assert(guard.name(source))

    if sourceName == "" then
        error("mv: cannot move the filesystem root into a directory.", 0)
    end

    actualDestination = assert(guard.normalize(
        destination .. "/" .. sourceName
    ))
end

if fs.exists(actualDestination) then
    error("mv: destination already exists: " .. actualDestination, 0)
end

local destinationParent = assert(guard.parent(actualDestination))

if not fs.exists(destinationParent) then
    error("mv: destination parent does not exist: " ..
        destinationParent, 0)
end

if not fs.isDir(destinationParent) then
    error("mv: destination parent is not a directory: " ..
        destinationParent, 0)
end

if sourceIsDirectory and guard.isWithin(actualDestination, source) and
    not catastrophicSource then
    error("mv: cannot move a directory into itself: " ..
        actualDestination, 0)
end

-- A move mutates both sides. Classifying the source prevents an ordinary user
-- from extracting a protected system file into home, while classifying the
-- derived destination prevents the inverse write into protected DICK paths.
local sourceInspection, sourceInspectionError = guard.inspect(
    source,
    "move_source",
    context
)
local destinationInspection, destinationInspectionError = guard.inspect(
    actualDestination,
    "write",
    context
)

if sourceInspection == nil then
    error("mv: " .. tostring(sourceInspectionError) .. ".", 0)
end

if destinationInspection == nil then
    error("mv: " .. tostring(destinationInspectionError) .. ".", 0)
end

local inspections = { sourceInspection, destinationInspection }
local authorised, authorisationError = guard.authorize(inspections, context)

if not authorised then
    error("mv: " .. authorisationError .. ".", 0)
end

local confirmed = guard.confirm(inspections, "mv", context)

if not confirmed then
    return
end

if catastrophicSource then
    -- The catastrophic warning is mandatory for an installation/root move,
    -- but exact confirmation is not a hidden force flag. Both roots contain
    -- the current DICK cwd and remain unconditionally immovable in v1.
    error("mv: cannot move the current working directory or its ancestor: " ..
        source, 0)
end

local moved, moveError = pcall(fs.move, source, actualDestination)

if not moved then
    error("mv: move failed; source was not deliberately deleted: " ..
        tostring(moveError), 0)
end
