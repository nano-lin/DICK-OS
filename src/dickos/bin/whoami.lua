-- DICK/OS current-user command
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: whoami")
    return
end

if type(context) ~= "table" or type(context.user) ~= "string" or
    type(context.effectiveUser) ~= "string" then
    error("whoami requires authenticated DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: whoami", 0)
end

-- `whoami` reports the identity under which this one command executes. The
-- real session identity remains separately available as `context.user` and is
-- restored automatically when the child returns to the shell.
print(context.effectiveUser)
