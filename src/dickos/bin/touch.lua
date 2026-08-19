-- DICK/OS safe file creation command
-- Version: 0.1.0-unstable

local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local invocationArguments = { ... }
local context = table.remove(invocationArguments, 1)
local arguments = invocationArguments

local function usage()
    print("Usage: touch <file> [file...]")
    print("Creates missing empty files; existing files are left unchanged.")
end

if arguments[1] == "--help" and #arguments == 1 then
    usage()
    return
end

if #arguments == 0 then
    error("Usage: touch <file> [file...]", 0)
end

local guardProgram, guardLoadError = loadfile(GUARD_PATH)

if type(guardProgram) ~= "function" then
    error("touch: unable to load filesystem guard: " ..
        tostring(guardLoadError), 0)
end

local guard = guardProgram()

if type(guard) ~= "table" or type(guard.resolve) ~= "function" or
    type(guard.inspect) ~= "function" or
    type(guard.authorize) ~= "function" or
    type(guard.confirm) ~= "function" or
    type(guard.parent) ~= "function" then
    error("touch: invalid filesystem guard.", 0)
end

local paths = {}
local inspections = {}
local seen = {}

-- Phase one resolves and validates every target. In particular, no writable
-- handle is opened while a later argument might still prove invalid.
for _, requestedPath in ipairs(arguments) do
    local path, resolveError = guard.resolve(context, requestedPath)

    if path == nil then
        error("touch: " .. tostring(resolveError) .. ".", 0)
    end

    if seen[path] then
        error("touch: duplicate target: " .. path, 0)
    end

    seen[path] = true

    if fs.exists(path) then
        if fs.isDir(path) then
            error("touch: path is a directory: " .. path, 0)
        end
    else
        local parent = assert(guard.parent(path))

        if not fs.exists(parent) then
            error("touch: parent directory does not exist: " .. parent, 0)
        end

        if not fs.isDir(parent) then
            error("touch: parent path is not a directory: " .. parent, 0)
        end
    end

    local inspection, inspectionError = guard.inspect(path, "write", context)

    if inspection == nil then
        error("touch: " .. tostring(inspectionError) .. ".", 0)
    end

    paths[#paths + 1] = path
    inspections[#inspections + 1] = inspection
end

local authorised, authorisationError = guard.authorize(inspections, context)

if not authorised then
    error("touch: " .. authorisationError .. ".", 0)
end

local confirmed = guard.confirm(inspections, "touch", context)

if not confirmed then
    return
end

-- Phase two performs only the already-approved creations. Unlike Unix touch,
-- editor milestone v1 has no timestamp API contract, so existing files are a
-- deliberate no-op and are never truncated through mode `w`.
for _, path in ipairs(paths) do
    if not fs.exists(path) then
        local file, openError = fs.open(path, "w")

        if file == nil then
            error("touch: unable to create " .. path .. ": " ..
                tostring(openError), 0)
        end

        local closeSucceeded, closeError = pcall(file.close)

        if not closeSucceeded then
            error("touch: unable to close " .. path .. ": " ..
                tostring(closeError), 0)
        end
    end
end
