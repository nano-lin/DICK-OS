-- DICK/OS current-identity command
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: id")
    return
end


if type(context) ~= "table" or type(context.user) ~= "string" or
    type(context.uid) ~= "number" or type(context.isAdmin) ~= "boolean" then
    error("id requires authenticated DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: id", 0)
end

local groups = context.isAdmin and "admin" or "user"

print(string.format("uid=%d(%s) groups=%s", context.uid, context.user, groups))
