-- DICK/OS compact runtime status
-- Version: 0.1.0-unstable

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: status")
    return
end

if firstArgument ~= nil then
    error("Usage: status", 0)
end

if type(context) ~= "table" then
    error("status requires DICK command context.", 0)
end

local requiredFields = {
    "version",
    "hostname",
    "machineID",
    "bootID",
    "runtimeApiVersion",
    "user",
}

for _, fieldName in ipairs(requiredFields) do
    if context[fieldName] == nil or tostring(context[fieldName]) == "" then
        error("status context is missing " .. fieldName .. ".", 0)
    end
end

print("DICK/OS " .. context.version)
print("Hostname:    " .. context.hostname)
print("Machine ID:  " .. context.machineID)
print("Boot ID:     " .. context.bootID)
print("Runtime API: " .. tostring(context.runtimeApiVersion))
print("User:        " .. context.user)
