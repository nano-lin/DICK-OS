-- DICK/OS safe directory creation command
-- Version: 0.1.0-unstable

local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local invocationArguments = { ... }
local context = table.remove(invocationArguments, 1)
local arguments = invocationArguments

local function usage()
    print("Usage: mkdir [-p] <directory> [directory...]")
    print("-p creates missing parent directories after full preflight.")
end

if arguments[1] == "--help" and #arguments == 1 then
    usage()
    return
end

local createParents = false

if arguments[1] == "-p" then
    createParents = true
    table.remove(arguments, 1)
elseif type(arguments[1]) == "string" and
    string.sub(arguments[1], 1, 1) == "-" then
    error("Usage: mkdir [-p] <directory> [directory...]", 0)
end

if #arguments == 0 then
    error("Usage: mkdir [-p] <directory> [directory...]", 0)
end

local guardProgram, guardLoadError = loadfile(GUARD_PATH)

if type(guardProgram) ~= "function" then
    error("mkdir: unable to load filesystem guard: " ..
        tostring(guardLoadError), 0)
end

local guard = guardProgram()

if type(guard) ~= "table" or type(guard.resolve) ~= "function" or
    type(guard.inspect) ~= "function" or
    type(guard.authorize) ~= "function" or
    type(guard.confirm) ~= "function" or
    type(guard.parent) ~= "function" then
    error("mkdir: invalid filesystem guard.", 0)
end

local creationPaths = {}
local plannedDirectories = {}
local inspections = {}
local finalTargets = {}

local function planCreation(path)
    if plannedDirectories[path] then
        return
    end

    local inspection, inspectionError = guard.inspect(path, "write", context)

    if inspection == nil then
        error("mkdir: " .. tostring(inspectionError) .. ".", 0)
    end

    plannedDirectories[path] = true
    creationPaths[#creationPaths + 1] = path
    inspections[#inspections + 1] = inspection
end

-- With `-p`, every missing component is classified independently. This is
-- essential because CC:T `fs.makeDir` creates parents automatically: checking
-- only the final path could otherwise smuggle a protected intermediate into an
-- apparently ordinary request.
local function preflightParents(path)
    local current = ""

    for segment in string.gmatch(path, "[^/]+") do
        current = current .. "/" .. segment

        if fs.exists(current) then
            if not fs.isDir(current) then
                error("mkdir: path component is not a directory: " ..
                    current, 0)
            end
        elseif not plannedDirectories[current] then
            planCreation(current)
        end
    end
end

for _, requestedPath in ipairs(arguments) do
    local path, resolveError = guard.resolve(context, requestedPath)

    if path == nil then
        error("mkdir: " .. tostring(resolveError) .. ".", 0)
    end

    if finalTargets[path] and not createParents then
        error("mkdir: duplicate target: " .. path, 0)
    end

    finalTargets[path] = true

    if createParents then
        preflightParents(path)
    else
        if fs.exists(path) then
            error("mkdir: path already exists: " .. path, 0)
        end

        local parent = assert(guard.parent(path))

        if not fs.exists(parent) then
            error("mkdir: parent directory does not exist: " .. parent, 0)
        end

        if not fs.isDir(parent) then
            error("mkdir: parent path is not a directory: " .. parent, 0)
        end

        planCreation(path)
    end
end

local authorised, authorisationError = guard.authorize(inspections, context)

if not authorised then
    error("mkdir: " .. authorisationError .. ".", 0)
end

local confirmed = guard.confirm(inspections, "mkdir", context)

if not confirmed then
    return
end

-- Parent components were appended before their descendants, so phase two is
-- deterministic even though `fs.makeDir` itself could also create parents.
for _, path in ipairs(creationPaths) do
    local succeeded, mutationError = pcall(fs.makeDir, path)

    if not succeeded then
        error("mkdir: unable to create " .. path .. ": " ..
            tostring(mutationError), 0)
    end
end
