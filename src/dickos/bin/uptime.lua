-- DICK/OS uptime command
-- Version: 0.1.0-unstable

local _, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: uptime")
    return
end

if firstArgument ~= nil then
    error("Usage: uptime", 0)
end

-- CC:T defines `os.clock()` as seconds since this computer was turned on, so
-- it measures the current computer/runtime uptime without inventing a boot
-- timestamp or persisting transient state.
local totalSeconds = math.floor(os.clock())
local days = math.floor(totalSeconds / 86400)
local hours = math.floor((totalSeconds % 86400) / 3600)
local minutes = math.floor((totalSeconds % 3600) / 60)
local seconds = totalSeconds % 60

if days > 0 then
    print(string.format(
        "up %d day%s, %02d:%02d:%02d",
        days,
        days == 1 and "" or "s",
        hours,
        minutes,
        seconds
    ))
else
    print(string.format("up %02d:%02d:%02d", hours, minutes, seconds))
end
