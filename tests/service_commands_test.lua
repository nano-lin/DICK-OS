-- Host-side tests for DICK/OS services/service command policy
-- Run with: lua tests/service_commands_test.lua

local SERVICES_SOURCE = "src/dickos/bin/services.lua"
local SERVICE_SOURCE = "src/dickos/bin/service.lua"
local CLIENT_PATH = "/dickos/lib/service_client.lua"
local hostLoadfile = loadfile

local function containsLine(lines, fragment)
    for _, line in ipairs(lines) do
        if string.find(line, fragment, 1, true) ~= nil then
            return true
        end
    end

    return false
end

local function makeContext(elevated)
    return {
        runtimeApiVersion = 1,
        bootID = "B-CMD0001",
        version = "0.1.0-unstable",
        hostname = "command-test",
        machineID = "DCK-C-33-C0DE",
        user = "nano",
        uid = 1000,
        effectiveUser = elevated and "root" or "nano",
        effectiveUID = elevated and 0 or 1000,
        isAdmin = true,
        isElevated = elevated == true,
        home = "/dickos/home/nano",
        cwd = "/dickos/home/nano",
    }
end

local function runCommand(sourcePath, context, arguments, response, errorText)
    local state = {
        output = {},
        requests = {},
        clientLoads = 0,
    }
    local environment = {
        print = function(value)
            state.output[#state.output + 1] = tostring(value or "")
        end,
        term = {
            getSize = function() return 51, 19 end,
        },
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        assert(path == CLIENT_PATH)
        state.clientLoads = state.clientLoads + 1

        return function()
            return {
                request = function(action, name, passedContext)
                    state.requests[#state.requests + 1] = {
                        action = action,
                        name = name,
                        context = passedContext,
                    }

                    if errorText ~= nil then
                        return nil, errorText
                    end

                    return response, nil
                end,
            }
        end
    end

    local program = assert(hostLoadfile(sourcePath, "t", environment))
    local succeeded, failure = pcall(
        program,
        context,
        table.unpack(arguments or {})
    )

    return state, succeeded, failure
end

local inventoryState, inventorySucceeded = runCommand(
    SERVICES_SOURCE,
    makeContext(false),
    {},
    {
        ok = true,
        services = {
            { name = "zeta", state = "STOPPED", autostart = false },
            { name = "alpha", state = "RUNNING", autostart = true },
        },
    }
)
assert(inventorySucceeded)
assert(#inventoryState.requests == 1)
assert(inventoryState.requests[1].action == "list")
assert(inventoryState.output[1] ==
    "SERVICE" .. string.rep(" ", 24) .. "STATE" ..
        string.rep(" ", 5) .. "AUTOSTART")
assert(string.find(inventoryState.output[2], "alpha", 1, true) == 1)
assert(containsLine(inventoryState.output, "RUNNING"))
assert(containsLine(inventoryState.output, "yes"))
assert(string.find(inventoryState.output[3], "zeta", 1, true) == 1)

local emptyState, emptySucceeded = runCommand(
    SERVICES_SOURCE,
    makeContext(false),
    {},
    { ok = true, services = {} }
)
assert(emptySucceeded)
assert(#emptyState.requests == 1)
assert(#emptyState.output == 1)
assert(emptyState.output[1] == "No services installed.")

local helpState, helpSucceeded = runCommand(
    SERVICES_SOURCE,
    makeContext(false),
    { "--help" },
    nil
)
assert(helpSucceeded)
assert(helpState.clientLoads == 0)
assert(containsLine(helpState.output, "Usage: services"))

local unavailableState, unavailableSucceeded = runCommand(
    SERVICES_SOURCE,
    makeContext(false),
    {},
    nil,
    "Service manager unavailable."
)
assert(unavailableSucceeded)
assert(containsLine(
    unavailableState.output,
    "Service manager unavailable."
))

local statusState, statusSucceeded = runCommand(
    SERVICE_SOURCE,
    makeContext(false),
    { "status", "alpha" },
    {
        ok = true,
        service = {
            name = "alpha",
            state = "FAILED",
            autostart = false,
            failure = "runtime error",
        },
    }
)
assert(statusSucceeded)
assert(#statusState.requests == 1)
assert(statusState.requests[1].action == "status")
assert(statusState.output[1] == "Service: alpha")
assert(statusState.output[2] == "State: FAILED")
assert(statusState.output[3] == "Autostart: no")
assert(statusState.output[4] == "Failure: runtime error")

-- Normal and partially forged contexts are rejected before client load, so no
-- dickd_request is emitted. Only the exact sudo-created root tuple proceeds.
for _, deniedContext in ipairs({
    makeContext(false),
    {
        runtimeApiVersion = 1,
        effectiveUser = "root",
        effectiveUID = 0,
        isElevated = false,
    },
    {
        runtimeApiVersion = 1,
        effectiveUser = "nano",
        effectiveUID = 0,
        isElevated = true,
    },
}) do
    local deniedState, deniedSucceeded = runCommand(
        SERVICE_SOURCE,
        deniedContext,
        { "start", "alpha" },
        nil
    )
    assert(deniedSucceeded)
    assert(deniedState.clientLoads == 0)
    assert(#deniedState.requests == 0)
    assert(containsLine(
        deniedState.output,
        "administrative privileges are required"
    ))
end

for _, action in ipairs({ "start", "stop", "restart" }) do
    local elevatedState, elevatedSucceeded = runCommand(
        SERVICE_SOURCE,
        makeContext(true),
        { action, "alpha" },
        {
            ok = true,
            service = {
                name = "alpha",
                state = action == "stop" and "STOPPED" or "RUNNING",
                autostart = false,
            },
        }
    )
    assert(elevatedSucceeded)
    assert(#elevatedState.requests == 1)
    assert(elevatedState.requests[1].action == action)
    assert(elevatedState.requests[1].name == "alpha")
    assert(elevatedState.requests[1].context.isElevated == true)
end

local invalidState, invalidSucceeded, invalidFailure = runCommand(
    SERVICE_SOURCE,
    makeContext(true),
    { "start", "../startup" },
    nil
)
assert(not invalidSucceeded)
assert(string.find(invalidFailure, "Usage:", 1, true) ~= nil)
assert(invalidState.clientLoads == 0)

local serviceHelpState, serviceHelpSucceeded = runCommand(
    SERVICE_SOURCE,
    makeContext(false),
    { "--help" },
    nil
)
assert(serviceHelpSucceeded)
assert(serviceHelpState.clientLoads == 0)
assert(containsLine(serviceHelpState.output, "sudo service restart"))

io.stdout:write("service command tests: PASS\n")
