-- DICK/OS read-only hostname command
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: hostname")
    return
end

if firstArgument ~= nil then
    error("Usage: hostname", 0)
end

if type(context) ~= "table" or type(context.hostname) ~= "string" then
    error("hostname requires DICK command context.", 0)
end

print(context.hostname)
