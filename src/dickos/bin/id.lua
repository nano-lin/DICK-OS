-- DICK/OS current-identity command
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: id")
    return
end


if type(context) ~= "table" or type(context.user) ~= "string" or
    type(context.uid) ~= "number" or type(context.isAdmin) ~= "boolean" or
    type(context.effectiveUser) ~= "string" or
    type(context.effectiveUID) ~= "number" or
    type(context.isElevated) ~= "boolean" then
    error("id requires authenticated DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: id", 0)
end

local groups = context.isAdmin and "admin" or "user"

if context.isElevated then
    print(string.format(
        "uid=%d(%s) euid=%d(%s) groups=%s",
        context.uid,
        context.user,
        context.effectiveUID,
        context.effectiveUser,
        groups
    ))
else
    print(string.format(
        "uid=%d(%s) groups=%s",
        context.uid,
        context.user,
        groups
    ))
end
