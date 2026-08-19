-- DICK/OS safe removal command
-- Version: 0.1.0-unstable

local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local invocationArguments = { ... }
local context = table.remove(invocationArguments, 1)
local arguments = invocationArguments

local function usage()
    print("Usage: rm [-r] <path> [path...]")
    print("Directories require -r; there is no force/overwrite mode.")
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
    error("Usage: rm [-r] <path> [path...]", 0)
end

if #arguments == 0 then
    error("Usage: rm [-r] <path> [path...]", 0)
end

local guardProgram, guardLoadError = loadfile(GUARD_PATH)

if type(guardProgram) ~= "function" then
    error("rm: unable to load filesystem guard: " ..
        tostring(guardLoadError), 0)
end

local guard = guardProgram()

if type(guard) ~= "table" or type(guard.resolve) ~= "function" or
    type(guard.inspect) ~= "function" or
    type(guard.authorize) ~= "function" or
    type(guard.confirm) ~= "function" or
    type(guard.isWithin) ~= "function" then
    error("rm: invalid filesystem guard.", 0)
end

local paths = {}
local inspections = {}
local confirmedButBlockedAncestor = nil

-- Complete semantic preflight precedes every `fs.delete`. The overlap check
-- also rejects `rm -r dir dir/file`: otherwise deleting the parent first would
-- make the later, previously-valid argument fail after partial mutation.
for _, requestedPath in ipairs(arguments) do
    local path, resolveError = guard.resolve(context, requestedPath)

    if path == nil then
        error("rm: " .. tostring(resolveError) .. ".", 0)
    end

    if not fs.exists(path) then
        error("rm: path does not exist: " .. path, 0)
    end

    if fs.isDir(path) and not recursive then
        error("rm: path is a directory; use -r: " .. path, 0)
    end

    if guard.isWithin(context.cwd, path) then
        if path == "/" or path == "/dickos" then
            -- These two roots have a stronger, independently required warning.
            -- Defer the unconditional cwd-safety refusal until after that
            -- warning is cancelled or confirmed; confirmation never becomes a
            -- force bypass and no deletion will run for either root.
            confirmedButBlockedAncestor = path
        else
            error("rm: cannot remove the current working directory or its " ..
                "ancestor: " .. path, 0)
        end
    end

    for _, earlierPath in ipairs(paths) do
        if guard.isWithin(path, earlierPath) or
            guard.isWithin(earlierPath, path) then
            error("rm: overlapping targets are not allowed: " .. path, 0)
        end
    end

    local inspection, inspectionError = guard.inspect(path, "remove", context)

    if inspection == nil then
        error("rm: " .. tostring(inspectionError) .. ".", 0)
    end

    paths[#paths + 1] = path
    inspections[#inspections + 1] = inspection
end

local authorised, authorisationError = guard.authorize(inspections, context)

if not authorised then
    error("rm: " .. authorisationError .. ".", 0)
end

local confirmed = guard.confirm(inspections, "rm", context)

if not confirmed then
    return
end

if confirmedButBlockedAncestor ~= nil then
    error("rm: cannot remove the current working directory or its ancestor: " ..
        confirmedButBlockedAncestor, 0)
end

for _, path in ipairs(paths) do
    local deleted, deleteError = pcall(fs.delete, path)

    if not deleted then
        error("rm: unable to remove " .. path .. ": " ..
            tostring(deleteError), 0)
    end
end
