-- DICK/OS system name command
-- Version: 0.1.0-unstable

local context, firstArgument, extraArgument = ...

if firstArgument == "--help" then
    print("Usage: uname [-a]")
    return
end

if type(context) ~= "table" or type(context.version) ~= "string" then
    error("uname requires DICK command context.", 0)
end

if extraArgument ~= nil or
    (firstArgument ~= nil and firstArgument ~= "-a") then
    error("Usage: uname [-a]", 0)
end

if firstArgument == "-a" then
    print("DICK/OS " .. context.version .. " " .. context.hostname)
else
    print("DICK/OS " .. context.version)
end
