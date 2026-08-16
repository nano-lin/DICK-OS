-- DICK/OS text file viewer
-- Version: 0.1.0-unstable

local context, requestedPath, extraArgument = ...

local function printUsage()
    print("Usage: cat <file>")
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

local function resolvePath(path)
    if type(context) ~= "table" or type(context.cwd) ~= "string" or
        type(context.home) ~= "string" then
        error("cat requires DICK command context.", 0)
    end

    if path == "~" then
        return normalizeAbsolutePath(context.home)
    elseif string.sub(path, 1, 2) == "~/" then
        return normalizeAbsolutePath(context.home .. "/" .. string.sub(path, 3))
    elseif string.sub(path, 1, 1) == "/" then
        return normalizeAbsolutePath(path)
    end

    return normalizeAbsolutePath(context.cwd .. "/" .. path)
end

if requestedPath == "--help" then
    printUsage()
    return
end

if requestedPath == nil or extraArgument ~= nil then
    error("Usage: cat <file>", 0)
end

local path = resolvePath(requestedPath)

if not fs.exists(path) then
    error("cat: file does not exist: " .. path, 0)
end

if fs.isDir(path) then
    error("cat: path is a directory: " .. path, 0)
end

local file, openError = fs.open(path, "r")

if file == nil then
    error("cat: unable to open " .. path .. ": " .. tostring(openError), 0)
end

-- Protect both handle operations so the file still gets a close attempt after
-- a read failure and the original filesystem diagnostic remains visible.
local readSucceeded, contentsOrError = pcall(file.readAll)
local closeSucceeded, closeError = pcall(file.close)

if not readSucceeded then
    error("cat: unable to read " .. path .. ": " .. tostring(contentsOrError), 0)
end

if not closeSucceeded then
    error("cat: unable to close " .. path .. ": " .. tostring(closeError), 0)
end

local contents = contentsOrError or ""
write(contents)

if contents == "" or string.sub(contents, -1) ~= "\n" then
    print()
end
