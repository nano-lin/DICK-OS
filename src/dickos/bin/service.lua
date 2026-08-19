-- DICK/OS service control command
-- Version: 0.1.0-unstable

local SERVICE_CLIENT_PATH = "/dickos/lib/service_client.lua"

local context, action, serviceName, extraArgument = ...

local function usage()
    print("service - inspect or control one DICK/OS service")
    print("Usage: service status <name>")
    print("       sudo service start <name>")
    print("       sudo service stop <name>")
    print("       sudo service restart <name>")
end

if action == "--help" and serviceName == nil then
    usage()
    return
end

if type(context) ~= "table" or
    type(context.runtimeApiVersion) ~= "number" then
    error("service requires DICK command context.", 0)
end

local validAction = action == "status" or action == "start" or
    action == "stop" or action == "restart"
local validName = type(serviceName) == "string" and
    string.match(serviceName, "^[a-z][a-z0-9_]*$") ~= nil

if not validAction or not validName or extraArgument ~= nil then
    error("Usage: service <status|start|stop|restart> <name>", 0)
end

local mutatesState = action ~= "status"

-- Refuse before loading the IPC client or queueing any event. dickd repeats
-- the same exact tuple validation because command-side checks are usability,
-- while the supervisor remains the owner of the state transition.
if mutatesState and not (
    context.isElevated == true and
    context.effectiveUID == 0 and
    context.effectiveUser == "root"
) then
    print("service: administrative privileges are required.")
    return
end

local clientSucceeded, serviceRequest = pcall(function()
    local program = assert(loadfile(SERVICE_CLIENT_PATH))
    local module = program()

    if type(module) ~= "table" or type(module.request) ~= "function" then
        return nil
    end

    return module.request
end)

if not clientSucceeded or type(serviceRequest) ~= "function" then
    print("Service manager unavailable.")
    return
end

local response, requestError = serviceRequest(
    action,
    serviceName,
    context
)

if response == nil then
    print(requestError or "Service manager unavailable.")
    return
end

if not response.ok then
    print(response.error or "Service request failed.")
    return
end

local service = response.service

if type(service) ~= "table" then
    print("Service supervisor returned an invalid response.")
    return
end

print("Service: " .. tostring(service.name))
print("State: " .. tostring(service.state))
print("Autostart: " .. (service.autostart == true and "yes" or "no"))

if service.state == "FAILED" and type(service.failure) == "string" then
    print("Failure: " .. service.failure)
end

if type(service.warning) == "string" then
    print("Warning: " .. service.warning)
end
