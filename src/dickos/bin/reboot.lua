-- DICK/OS reboot command
-- Version: 0.1.0-unstable

local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local context, firstArgument = ...

if context == "--help" or firstArgument == "--help" then
    print("Usage: reboot")
    return
end

if type(context) ~= "table" then
    error("reboot requires DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: reboot", 0)
end

-- A reboot must not depend on diagnostics. Module load, logger creation, and
-- record append share a protected boundary; the real reboot follows even when
-- logging is unavailable.
pcall(function()
    local loggerProgram = assert(loadfile(LOG_LIBRARY_PATH))
    local logModule = loggerProgram()
    local logger = logModule.create("system", context)

    if type(logger) == "table" and type(logger.info) == "function" then
        logger.info("power", "Reboot requested from DICK shell")
    end
end)

os.reboot()
