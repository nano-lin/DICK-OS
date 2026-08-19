-- Host-side tests for dickd event scheduling and request isolation
-- Run with: lua tests/service_scheduler_test.lua

local DICKD_SOURCE = "src/dickos/system/dickd.lua"
local CONFIG_PATH = "/dickos/lib/config.lua"
local LOG_PATH = "/dickos/lib/log.lua"
local SERVICES_DIRECTORY = "/dickos/services"
local hostLoadfile = loadfile
local hostLoad = load

local files = {
    [SERVICES_DIRECTORY .. "/all_events.lua"] = [[
return {
    run = function()
        while true do
            local event = coroutine.yield()
            _TEST_STATE.all[#_TEST_STATE.all + 1] = event
        end
    end,
}
]],
    [SERVICES_DIRECTORY .. "/timer_waiter.lua"] = [[
return {
    run = function()
        while true do
            local event, value = coroutine.yield("timer")
            _TEST_STATE.timers[#_TEST_STATE.timers + 1] = {
                event,
                value,
            }
        end
    end,
}
]],
    [SERVICES_DIRECTORY .. "/modem_waiter.lua"] = [[
return {
    run = function()
        while true do
            local event, side, channel = coroutine.yield("modem_message")
            _TEST_STATE.modem[#_TEST_STATE.modem + 1] = {
                event,
                side,
                channel,
            }
        end
    end,
}
]],
    [SERVICES_DIRECTORY .. "/crasher.lua"] = [[
return {
    run = function()
        coroutine.yield("explode")
        error("MODEM_SECRET_PAYLOAD", 0)
    end,
}
]],
}

local state = {
    all = {},
    timers = {},
    modem = {},
    queued = {},
    logs = {},
}
local environment = {
    _TEST_STATE = state,
}

environment.fs = {
    exists = function(path)
        return path == SERVICES_DIRECTORY or files[path] ~= nil
    end,
    isDir = function(path)
        return path == SERVICES_DIRECTORY
    end,
    list = function(path)
        assert(path == SERVICES_DIRECTORY)
        return {
            "timer_waiter.lua",
            "modem_waiter.lua",
            "crasher.lua",
            "all_events.lua",
        }
    end,
}

environment.os = {
    queueEvent = function(name, value)
        state.queued[#state.queued + 1] = { name, value }
    end,
}

setmetatable(environment, { __index = _G })
environment._G = environment
environment.loadfile = function(path, mode, requestedEnvironment)
    if path == CONFIG_PATH then
        return function()
            return {
                readText = function() return "format_version = 1\n" end,
                parse = function()
                    return { format_version = 1 }
                end,
            }
        end
    end

    if path == LOG_PATH then
        return function()
            return {
                create = function()
                    local logger = {}

                    for _, level in ipairs({
                        "debug",
                        "info",
                        "warn",
                        "error",
                        "critical",
                    }) do
                        logger[level] = function(_, message)
                            state.logs[#state.logs + 1] = tostring(message)
                        end
                    end

                    return logger
                end,
            }
        end
    end

    if files[path] ~= nil then
        return hostLoad(
            files[path],
            "@" .. path,
            mode or "t",
            requestedEnvironment or environment
        )
    end

    return nil, "not found"
end

local dickd = assert(hostLoadfile(DICKD_SOURCE, "t", environment))()
local manager = dickd.create({
    runtimeApiVersion = 1,
    bootID = "B-SCHED001",
    version = "0.1.0-unstable",
    hostname = "scheduler-test",
    machineID = "DCK-C-22-BEEF",
})

assert(manager:start("all_events"))
assert(manager:start("timer_waiter"))
assert(manager:start("modem_waiter"))
assert(manager:start("crasher"))

manager:handleEvent("ignored", 1)
assert(#state.all == 1 and state.all[1] == "ignored")
assert(#state.timers == 0)
assert(#state.modem == 0)

manager:handleEvent("timer", 42)
assert(#state.all == 2 and state.all[2] == "timer")
assert(#state.timers == 1)
assert(state.timers[1][1] == "timer")
assert(state.timers[1][2] == 42)
assert(#state.modem == 0)

manager:handleEvent("key", 16)
assert(#state.all == 3 and state.all[3] == "key")
assert(#state.timers == 1)
assert(#state.modem == 0)

manager:handleEvent("modem_message", "left", 65535, 1, "payload")
assert(#state.all == 4 and state.all[4] == "modem_message")
assert(#state.timers == 1)
assert(#state.modem == 1)
assert(state.modem[1][1] == "modem_message")
assert(state.modem[1][2] == "left")
assert(state.modem[1][3] == 65535)

-- Supervisor IPC and Ctrl+T are never delivered, even to an unfiltered
-- service. A request itself still produces one correlated response event.
manager:handleEvent("terminate")
manager:handleEvent("dickd_response", {
    requestID = "unrelated",
    ok = true,
})
assert(#state.all == 4)

manager:handleEvent("dickd_request", {
    requestID = "list-1",
    action = "list",
})
assert(#state.all == 4)
assert(#state.queued == 1)
assert(state.queued[1][1] == "dickd_response")
assert(state.queued[1][2].requestID == "list-1")
assert(state.queued[1][2].ok == true)
assert(#state.queued[1][2].services == 4)

-- One crashing service becomes FAILED without stopping its healthy siblings,
-- and no arbitrary runtime error/payload is copied into logs or responses.
manager:handleEvent("explode", "MODEM_SECRET_PAYLOAD")
assert(manager.records.crasher.state == "FAILED")
assert(manager.records.crasher.failure == "runtime error")
assert(manager.records.all_events.state == "RUNNING")
assert(manager.records.timer_waiter.state == "RUNNING")
assert(manager.records.modem_waiter.state == "RUNNING")

for _, message in ipairs(state.logs) do
    assert(string.find(message, "MODEM_SECRET_PAYLOAD", 1, true) == nil)
end

-- The supervisor repeats privilege validation at the IPC boundary. Partial or
-- normal tuples cannot mutate state; the exact sudo-created root tuple can.
manager:handleEvent("dickd_request", {
    requestID = "denied-1",
    action = "stop",
    name = "all_events",
    caller = {
        effectiveUser = "root",
        effectiveUID = 0,
        isElevated = false,
    },
})
local denied = state.queued[#state.queued][2]
assert(denied.requestID == "denied-1")
assert(denied.ok == false)
assert(string.find(denied.error, "requires sudo", 1, true) ~= nil)
assert(manager.records.all_events.state == "RUNNING")

manager:handleEvent("dickd_request", {
    requestID = "stop-1",
    action = "stop",
    name = "all_events",
    caller = {
        effectiveUser = "root",
        effectiveUID = 0,
        isElevated = true,
    },
})
local stopped = state.queued[#state.queued][2]
assert(stopped.requestID == "stop-1")
assert(stopped.ok == true)
assert(stopped.service.state == "STOPPED")
assert(manager.records.all_events.state == "STOPPED")

-- Invalid/malformed request data is ignored rather than crashing dickd or
-- creating an unmatchable response.
local queuedBeforeInvalid = #state.queued
manager:handleEvent("dickd_request", { action = "list" })
manager:handleEvent("dickd_request", "not a request")
assert(#state.queued == queuedBeforeInvalid)

io.stdout:write("service scheduler tests: PASS\n")
