-- DICK/OS local service-supervisor client
-- Version: 0.1.0-unstable

local REQUEST_EVENT = "dickd_request"
local RESPONSE_EVENT = "dickd_response"
local REQUEST_TIMEOUT_SECONDS = 1
local requestSequence = 0

local client = {}

local VALID_ACTIONS = {
    list = true,
    status = true,
    start = true,
    stop = true,
    restart = true,
}

local function isValidServiceName(name)
    return type(name) == "string" and
        string.match(name, "^[a-z][a-z0-9_]*$") ~= nil
end

-- Request IDs need uniqueness only among short-lived local calls. Combining a
-- monotonically increasing module counter with best-effort platform metadata
-- avoids depending on a random generator and lets a client ignore stale or
-- unrelated dickd_response events. This ID is correlation data, not a secret
-- or an authentication token.
local function makeRequestID(timerID)
    requestSequence = requestSequence + 1

    local computerID = "unknown"
    local epoch = "unknown"

    if type(os.getComputerID) == "function" then
        local succeeded, value = pcall(os.getComputerID)

        if succeeded then
            computerID = tostring(value)
        end
    end

    if type(os.epoch) == "function" then
        local succeeded, value = pcall(os.epoch, "utc")

        if succeeded then
            epoch = tostring(value)
        end
    end

    return table.concat({
        "dickd",
        computerID,
        epoch,
        tostring(timerID),
        tostring(requestSequence),
    }, "-")
end

local function callerProjection(commandContext)
    if type(commandContext) ~= "table" then
        return nil
    end

    -- IPC never carries the complete shell context. Only the three effective
    -- authority fields required by dickd cross this boundary; user/home/cwd
    -- and all future session-private data remain in the command process.
    return {
        effectiveUser = commandContext.effectiveUser,
        effectiveUID = commandContext.effectiveUID,
        isElevated = commandContext.isElevated,
    }
end

function client.request(action, name, commandContext)
    if VALID_ACTIONS[action] ~= true then
        return nil, "Invalid service action."
    end

    if action ~= "list" and not isValidServiceName(name) then
        return nil, "Invalid service name."
    end

    if type(os) ~= "table" or type(os.startTimer) ~= "function" or
        type(os.queueEvent) ~= "function" or
        type(os.pullEvent) ~= "function" then
        return nil, "Service manager unavailable."
    end

    local timerSucceeded, timerID = pcall(
        os.startTimer,
        REQUEST_TIMEOUT_SECONDS
    )

    if not timerSucceeded or type(timerID) ~= "number" then
        return nil, "Service manager unavailable."
    end

    local requestID = makeRequestID(timerID)
    local request = {
        requestID = requestID,
        action = action,
        name = name,
        caller = callerProjection(commandContext),
    }
    local queued = pcall(os.queueEvent, REQUEST_EVENT, request)

    if not queued then
        if type(os.cancelTimer) == "function" then
            pcall(os.cancelTimer, timerID)
        end

        return nil, "Service manager unavailable."
    end

    -- Do not filter os.pullEvent to one event name: the matching timer and the
    -- response are different events. Unrelated responses are ignored by their
    -- request ID. os.pullEvent intentionally preserves ordinary Ctrl+T child
    -- termination; the surrounding DICK shell already owns that policy.
    while true do
        local eventName, first = os.pullEvent()

        if eventName == RESPONSE_EVENT and type(first) == "table" and
            first.requestID == requestID then
            if type(os.cancelTimer) == "function" then
                pcall(os.cancelTimer, timerID)
            end

            if type(first.ok) ~= "boolean" then
                return nil, "Service supervisor returned an invalid response."
            end

            return first, nil
        end

        if eventName == "timer" and first == timerID then
            return nil, "Service manager unavailable."
        end
    end
end

return client
