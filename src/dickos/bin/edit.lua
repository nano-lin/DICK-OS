-- DICK/OS selected ROM editor wrapper
-- Version: 0.1.0-unstable

local ROM_EDITOR_PATH = "/rom/programs/edit.lua"
local context, requestedPath, extraArgument = ...

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
        error("edit requires DICK command context.", 0)
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
    print("Usage: edit <file>")
    return
end

if requestedPath == nil or extraArgument ~= nil then
    error("Usage: edit <file>", 0)
end

local targetPath = resolvePath(requestedPath)
local editorProgram, loadError = loadfile(ROM_EDITOR_PATH)

if editorProgram == nil then
    error("edit: unable to load ROM editor: " .. tostring(loadError), 0)
end

-- The current CC:T ROM editor accepts a filename argument and resolves it via
-- CraftOS `shell.resolve`. Supplying an already absolute DICK path makes that
-- substrate resolution deterministic. The outer DICK shell owns protection,
-- so normal editor exit returns there and a Ctrl+T error is not swallowed.
editorProgram(targetPath)
