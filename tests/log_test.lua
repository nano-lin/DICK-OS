-- Host-side tests for the authentication log target and viewer
-- Run with: lua tests/log_test.lua

local hostLoadfile = loadfile
local AUTH_LOG = "/dickos/var/log/auth.log"
local state = {
    files = {},
    deleted = {},
}
local fsMock = {}

fsMock.exists = function(path) return state.files[path] ~= nil end
fsMock.getSize = function(path) return #assert(state.files[path]) end
fsMock.delete = function(path)
    state.deleted[#state.deleted + 1] = path
    state.files[path] = nil
end
fsMock.move = function(sourcePath, targetPath)
    assert(state.files[sourcePath] ~= nil)
    state.files[targetPath] = state.files[sourcePath]
    state.files[sourcePath] = nil
end
fsMock.open = function(path, mode)
    if mode == "a" then
        state.files[path] = state.files[path] or ""

        return {
            writeLine = function(line)
                state.files[path] = state.files[path] .. line .. "\n"
            end,
            close = function() end,
        }
    end

    if mode == "r" then
        local contents = state.files[path]

        if contents == nil then
            return nil, "missing"
        end

        local lines = {}

        for line in string.gmatch(contents, "([^\n]*)\n") do
            lines[#lines + 1] = line
        end

        local index = 0
        return {
            readLine = function()
                index = index + 1
                return lines[index]
            end,
            close = function() end,
        }
    end

    error("unexpected mode", 0)
end

local environment = {
    fs = fsMock,
    os = {
        epoch = function(kind) assert(kind == "utc"); return 0 end,
        date = function() return "1970-01-01T00:00:00Z" end,
    },
}
setmetatable(environment, { __index = _G })
environment._G = environment

local logModule = assert(hostLoadfile(
    "src/dickos/lib/log.lua",
    "t",
    environment
))()
local logger = assert(logModule.create("auth", { bootID = "B-1234ABCD" }))
assert(logger.info("login", "Login succeeded for nano"))
assert(string.find(state.files[AUTH_LOG], "[INFO] [login]", 1, true))

state.files[AUTH_LOG] = string.rep("x", 64 * 1024)
state.files[AUTH_LOG .. ".1"] = "older"
assert(logger.warn("login", "Login rejected"))
assert(state.files[AUTH_LOG .. ".1"] == string.rep("x", 64 * 1024))
assert(string.find(state.files[AUTH_LOG], "Login rejected", 1, true))

local output = {}
environment.colors = {
    black = 1,
    white = 2,
    red = 3,
    yellow = 4,
    gray = 5,
    lightBlue = 6,
}
environment.term = {
    isColor = function() return true end,
    setTextColor = function() end,
    setBackgroundColor = function() end,
    clear = function() end,
    setCursorPos = function() end,
}
environment.print = function(value)
    output[#output + 1] = tostring(value or "")
end

local viewer = assert(hostLoadfile(
    "src/dickos/bin/dicklog.lua",
    "t",
    environment
))
local viewerSucceeded, viewerError = pcall(viewer, "auth", "20")
assert(viewerSucceeded, tostring(viewerError))
assert(string.find(table.concat(output, "\n"), "DICK/OS auth log", 1, true))

io.stdout:write("logging tests: PASS\n")
