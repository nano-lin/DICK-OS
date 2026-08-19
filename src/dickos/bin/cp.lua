-- DICK/OS safe copy command
-- Version: 0.1.0-unstable

local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local invocationArguments = { ... }
local context = table.remove(invocationArguments, 1)
local arguments = invocationArguments

local function usage()
    print("Usage: cp [-r] <source> <destination>")
    print("Existing destinations are never overwritten.")
end

if arguments[1] == "--help" and #arguments == 1 then
    usage()
    return
end

local recursive = false

if arguments[1] == "-r" then
    recursive = true
    table.remove(arguments, 1)
elseif type(arguments[1]) == "string" and
    string.sub(arguments[1], 1, 1) == "-" then
    error("Usage: cp [-r] <source> <destination>", 0)
end

if #arguments ~= 2 then
    error("Usage: cp [-r] <source> <destination>", 0)
end

local guardProgram, guardLoadError = loadfile(GUARD_PATH)

if type(guardProgram) ~= "function" then
    error("cp: unable to load filesystem guard: " ..
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
    error("cp: invalid filesystem guard.", 0)
end

local source, sourceError = guard.resolve(context, arguments[1])
local destination, destinationError = guard.resolve(context, arguments[2])

if source == nil then
    error("cp: " .. tostring(sourceError) .. ".", 0)
end

if destination == nil then
    error("cp: " .. tostring(destinationError) .. ".", 0)
end

-- Phase one determines the actual target before authorization. When the typed
-- destination is a directory, CC:T/Unix-style command semantics append the
-- source basename; policy therefore applies to that derived path, not merely
-- to the directory token the user entered.
if not fs.exists(source) then
    error("cp: source does not exist: " .. source, 0)
end

local sourceIsDirectory = fs.isDir(source)

if sourceIsDirectory and not recursive then
    error("cp: source is a directory; use -r: " .. source, 0)
end

local actualDestination = destination

if fs.exists(destination) and fs.isDir(destination) then
    local sourceName = assert(guard.name(source))

    if sourceName == "" then
        error("cp: cannot copy the filesystem root into a directory.", 0)
    end

    actualDestination = assert(guard.normalize(
        destination .. "/" .. sourceName
    ))
end

if fs.exists(actualDestination) then
    error("cp: destination already exists: " .. actualDestination, 0)
end

local destinationParent = assert(guard.parent(actualDestination))

if not fs.exists(destinationParent) then
    error("cp: destination parent does not exist: " .. destinationParent, 0)
end

if not fs.isDir(destinationParent) then
    error("cp: destination parent is not a directory: " ..
        destinationParent, 0)
end

if sourceIsDirectory and guard.isWithin(actualDestination, source) then
    error("cp: cannot copy a directory into itself: " ..
        actualDestination, 0)
end

local inspection, inspectionError = guard.inspect(
    actualDestination,
    "write",
    context
)

if inspection == nil then
    error("cp: " .. tostring(inspectionError) .. ".", 0)
end

local inspections = { inspection }
local authorised, authorisationError = guard.authorize(inspections, context)

if not authorised then
    error("cp: " .. authorisationError .. ".", 0)
end

local confirmed = guard.confirm(inspections, "cp", context)

if not confirmed then
    return
end

-- `fs.copy` is invoked only after all source semantics, destination semantics,
-- authorization, and confirmations have completed. Its runtime failure remains
-- a child-command error; it cannot make a later invalid argument appear.
local copied, copyError = pcall(fs.copy, source, actualDestination)

if not copied then
    error("cp: copy failed: " .. tostring(copyError), 0)
end
