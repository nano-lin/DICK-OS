-- DICK/OS shutdown command
-- Version: 0.1.0-unstable

local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local context, firstArgument = ...

if context == "--help" or firstArgument == "--help" then
    print("Usage: shutdown")
    return
end

if type(context) ~= "table" then
    error("shutdown requires DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: shutdown", 0)
end

-- Shutdown remains real system control even if the best-effort diagnostic
-- cannot be written. No command arguments are included in the log record.
pcall(function()
    local loggerProgram = assert(loadfile(LOG_LIBRARY_PATH))
    local logModule = loggerProgram()
    local logger = logModule.create("system", context)

    if type(logger) == "table" and type(logger.info) == "function" then
        logger.info("power", "Shutdown requested from DICK shell")
    end
end)

os.shutdown()
