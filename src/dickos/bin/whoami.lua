-- DICK/OS current-user command
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: whoami")
    return
end

if type(context) ~= "table" or type(context.user) ~= "string" then
    error("whoami requires authenticated DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: whoami", 0)
end

print(context.user)
