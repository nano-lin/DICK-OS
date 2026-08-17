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

-- Build the deliberately narrow CraftOS compatibility surface needed by the
-- ROM editor. A Lua environment is a table used for a program's global names.
-- Its metatable falls back to the ordinary CC:T globals, so APIs such as `fs`,
-- `term`, and `settings` keep working, while the explicit `shell` field masks
-- any CraftOS shell which might exist outside DICK/OS.
--
-- `shell.resolve` closes over the one DICK-resolved target path. A closure is a
-- function which remembers surrounding local values after this helper returns.
-- Rejecting any different request keeps DICK path resolution authoritative.
-- No `openTab` or `switchTab` methods are supplied, so the ROM editor does not
-- advertise its Run menu before DICK/OS has a scheduler or job control.
local function createEditorEnvironment(targetPath)
    local compatibilityShell = {}

    compatibilityShell.resolve = function(requestedEditorPath)
        if requestedEditorPath ~= targetPath then
            error(
                "edit: ROM editor requested an unexpected path: " ..
                    tostring(requestedEditorPath),
                0
            )
        end

        return targetPath
    end

    local editorEnvironment = {
        shell = compatibilityShell,
    }

    setmetatable(editorEnvironment, { __index = _G })

    -- Programs commonly use `_G` to inspect their own global environment. Point
    -- it back to this compatibility table instead of exposing the parent table
    -- and a possible full CraftOS shell through `_G.shell`.
    editorEnvironment._G = editorEnvironment
    return editorEnvironment
end

if requestedPath == "--help" then
    print("Usage: edit <file>")
    return
end

if requestedPath == nil or extraArgument ~= nil then
    error("Usage: edit <file>", 0)
end

local targetPath = resolvePath(requestedPath)
local editorEnvironment = createEditorEnvironment(targetPath)

-- `os.run` supports an explicit environment and exact program path, but it
-- prints runtime errors itself and returns false. In particular, that would
-- consume the editor's `Terminated` error before the outer DICK shell could
-- classify Ctrl+T. Loading the exact ROM path with an explicit text-only Lua
-- environment provides the same compatibility boundary while allowing editor
-- failures to reach the shell's existing protected child-command call.
local editorProgram, loadError = loadfile(
    ROM_EDITOR_PATH,
    "t",
    editorEnvironment
)

if editorProgram == nil then
    error("edit: unable to load ROM editor: " .. tostring(loadError), 0)
end

-- The ROM editor receives only the already absolute path. Normal return and
-- every runtime error therefore go directly back to the DICK shell call site;
-- this wrapper never starts or enters a CraftOS command prompt.
editorProgram(targetPath)
