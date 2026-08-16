-- DICK/OS simple directory listing
-- Version: 0.1.0-unstable

local context, requestedPath, extraArgument = ...

local function printUsage()
    print("Usage: ls [path]")
end

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

    return #segments == 0 and "/" or "/" .. table.concat(segments, "/")
end

-- Native DICK commands receive context as their first chunk argument. Path
-- expansion is repeated locally so the command never depends on CraftOS shell
-- cwd, aliases, or PATH state.
local function resolvePath(path)
    if type(context) ~= "table" or type(context.cwd) ~= "string" or
        type(context.home) ~= "string" then
        error("ls requires DICK command context.", 0)
    end

    local requested = tostring(path or context.cwd)

    if requested == "~" then
        return normalizeAbsolutePath(context.home)
    elseif string.sub(requested, 1, 2) == "~/" then
        return normalizeAbsolutePath(
            context.home .. "/" .. string.sub(requested, 3)
        )
    elseif string.sub(requested, 1, 1) == "/" then
        return normalizeAbsolutePath(requested)
    end

    return normalizeAbsolutePath(context.cwd .. "/" .. requested)
end

if requestedPath == "--help" then
    printUsage()
    return
end

if extraArgument ~= nil then
    error("Usage: ls [path]", 0)
end

local path = resolvePath(requestedPath)

if not fs.exists(path) then
    error("ls: path does not exist: " .. path, 0)
end

-- A file argument is useful during development and avoids reporting a real
-- path as though it were a directory error.
if not fs.isDir(path) then
    print(fs.getName(path))
    return
end

local entries = fs.list(path)
table.sort(entries)

for _, entryName in ipairs(entries) do
    local entryPath = fs.combine(path, entryName)

    if fs.isDir(entryPath) then
        term.setTextColor(colors.lightBlue)
        print(entryName .. "/")
    else
        term.setTextColor(colors.white)
        print(entryName)
    end
end

term.setTextColor(colors.white)
