-- Host-side tests for local dickd request/response correlation
-- Run with: lua tests/service_client_test.lua

local CLIENT_SOURCE = "src/dickos/lib/service_client.lua"
local hostLoadfile = loadfile

local function loadClient(options)
    options = options or {}

    local state = {
        queued = {},
        cancelled = {},
        pullCount = 0,
        externalAPICalls = 0,
    }
    local environment = {}

    local function forbiddenAPI()
        return setmetatable({}, {
            __index = function()
                state.externalAPICalls = state.externalAPICalls + 1
                error("forbidden IPC transport accessed", 0)
            end,
        })
    end

    environment.fs = forbiddenAPI()
    environment.rednet = forbiddenAPI()
    environment.peripheral = forbiddenAPI()

    environment.os = {
        getComputerID = function() return 17 end,
        epoch = function(zone)
            assert(zone == "utc")
            return 123456789
        end,
        startTimer = function(seconds)
            assert(seconds == 1)

            if options.timerFailure then
                error("timer unavailable", 0)
            end

            return 91
        end,
        cancelTimer = function(timerID)
            state.cancelled[#state.cancelled + 1] = timerID
        end,
        queueEvent = function(name, request)
            state.queued[#state.queued + 1] = { name, request }

            if options.queueFailure then
                error("queue unavailable", 0)
            end
        end,
        pullEvent = function()
            state.pullCount = state.pullCount + 1
            local request = state.queued[#state.queued] and
                state.queued[#state.queued][2]

            if options.terminate then
                error("Terminated", 0)
            end

            if options.timeout then
                return "timer", 91
            end

            if state.pullCount == 1 and options.unrelatedFirst then
                return "dickd_response", {
                    requestID = "someone-else",
                    ok = true,
                }
            end

            return "dickd_response", {
                requestID = request.requestID,
                ok = true,
                service = {
                    name = request.name,
                    state = "RUNNING",
                    autostart = false,
                },
            }
        end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    local client = assert(hostLoadfile(CLIENT_SOURCE, "t", environment))()

    return client, state
end

local elevatedContext = {
    runtimeApiVersion = 1,
    effectiveUser = "root",
    effectiveUID = 0,
    isElevated = true,
    user = "nano",
    uid = 1000,
    home = "/dickos/home/nano",
    cwd = "/dickos/home/nano/projects",
    password = "must-not-cross-ipc",
}

local client, state = loadClient({ unrelatedFirst = true })
local response, responseError = client.request(
    "start",
    "alpha",
    elevatedContext
)
assert(responseError == nil)
assert(response.ok == true)
assert(response.service.name == "alpha")
assert(state.pullCount == 2)
assert(#state.queued == 1)
assert(state.queued[1][1] == "dickd_request")
assert(state.queued[1][2].action == "start")
assert(state.queued[1][2].name == "alpha")
assert(type(state.queued[1][2].requestID) == "string")
assert(state.queued[1][2].caller.effectiveUser == "root")
assert(state.queued[1][2].caller.effectiveUID == 0)
assert(state.queued[1][2].caller.isElevated == true)
assert(state.queued[1][2].caller.user == nil)
assert(state.queued[1][2].caller.uid == nil)
assert(state.queued[1][2].caller.home == nil)
assert(state.queued[1][2].caller.cwd == nil)
assert(state.queued[1][2].caller.password == nil)
assert(#state.cancelled == 1 and state.cancelled[1] == 91)

local seenRequestIDs = {
    [state.queued[1][2].requestID] = true,
}

for _, requestCase in ipairs({
    { action = "list", name = nil },
    { action = "status", name = "alpha" },
    { action = "stop", name = "alpha" },
    { action = "restart", name = "alpha" },
}) do
    local nextResponse, nextError = client.request(
        requestCase.action,
        requestCase.name,
        elevatedContext
    )
    assert(nextError == nil)
    assert(nextResponse.ok == true)
    local queuedRequest = state.queued[#state.queued][2]
    assert(queuedRequest.action == requestCase.action)
    assert(queuedRequest.name == requestCase.name)
    assert(not seenRequestIDs[queuedRequest.requestID])
    seenRequestIDs[queuedRequest.requestID] = true
end

assert(#state.queued == 5)
assert(#state.cancelled == 5)
assert(state.externalAPICalls == 0)

local timeoutClient, timeoutState = loadClient({ timeout = true })
local timeoutResponse, timeoutError = timeoutClient.request(
    "status",
    "alpha",
    elevatedContext
)
assert(timeoutResponse == nil)
assert(timeoutError == "Service manager unavailable.")
assert(#timeoutState.queued == 1)

local invalidClient, invalidState = loadClient()
local invalidResponse, invalidError = invalidClient.request(
    "start",
    "../startup",
    elevatedContext
)
assert(invalidResponse == nil)
assert(invalidError == "Invalid service name.")
assert(#invalidState.queued == 0)

local queueClient, queueState = loadClient({ queueFailure = true })
local queueResponse, queueError = queueClient.request(
    "list",
    nil,
    elevatedContext
)
assert(queueResponse == nil)
assert(queueError == "Service manager unavailable.")
assert(#queueState.cancelled == 1)

-- os.pullEvent, rather than pullEventRaw, deliberately lets Ctrl+T terminate
-- this child command. The DICK shell's existing pcall/cleanup boundary handles
-- it without touching dickd or entering Recovery.
local terminateClient = loadClient({ terminate = true })
local terminateSucceeded, terminateError = pcall(
    terminateClient.request,
    "status",
    "alpha",
    elevatedContext
)
assert(not terminateSucceeded)
assert(string.find(terminateError, "Terminated", 1, true) ~= nil)

io.stdout:write("service client tests: PASS\n")
