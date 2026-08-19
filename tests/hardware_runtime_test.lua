-- Host-side tests for the small DICK/OS hotplug watcher
-- Run with: lua tests/hardware_runtime_test.lua

local HARDWARE_SOURCE = "src/dickos/lib/hardware.lua"
local TEST_STOP = "__DICK_HARDWARE_RUNTIME_EVENTS_COMPLETE__"
local hostLoadfile = loadfile

local deviceDefinitions = {
    left = { types = { "modem" }, wireless = true },
    monitor_0 = { types = { "monitor" } },
    addon_0 = { types = { "directgpu" } },
}
local attached = {}
local events = {
    { "key", 30, false },
    { "peripheral", "left" },
    { "terminate" },
    { "peripheral_detach", "left" },
    { "peripheral", "monitor_0" },
    { "peripheral_detach", "monitor_0" },
    { "peripheral", "addon_0" },
}
local state = {
    eventIndex = 0,
    eventRecords = {},
    filesystemMutations = 0,
    queries = {},
}

local function recordQuery(name)
    state.queries[name] = (state.queries[name] or 0) + 1
end

local environment = {
    peripheral = {
        getNames = function()
            local names = {}
            for name in pairs(attached) do names[#names + 1] = name end
            return names
        end,
        isPresent = function(name)
            recordQuery(name)
            return attached[name] ~= nil
        end,
        getType = function(name)
            recordQuery(name)
            return table.unpack(assert(attached[name]).types)
        end,
        call = function(name, method)
            recordQuery(name)
            assert(method == "isWireless")
            return assert(attached[name]).wireless
        end,
    },
    fs = {
        open = function()
            state.filesystemMutations = state.filesystemMutations + 1
            error("hardware watcher attempted a filesystem write", 0)
        end,
        delete = function()
            state.filesystemMutations = state.filesystemMutations + 1
        end,
        move = function()
            state.filesystemMutations = state.filesystemMutations + 1
        end,
        makeDir = function()
            state.filesystemMutations = state.filesystemMutations + 1
        end,
    },
    os = {},
}

environment.os.pullEventRaw = function()
    state.eventIndex = state.eventIndex + 1
    local event = events[state.eventIndex]

    if event == nil then
        error(TEST_STOP, 0)
    end

    local eventName = event[1]
    local name = event[2]

    -- CC:T queues attach after the device becomes visible and detach after it
    -- is unavailable. Updating this mock before returning the event reproduces
    -- the important query timing without implementing a scheduler.
    if eventName == "peripheral" then
        attached[name] = assert(deviceDefinitions[name])
    elseif eventName == "peripheral_detach" then
        attached[name] = nil
    end

    return table.unpack(event)
end

setmetatable(environment, { __index = _G })
environment._G = environment

local hardware = assert(hostLoadfile(
    HARDWARE_SOURCE,
    "t",
    environment
))()

local watcherSucceeded, watcherFailure = pcall(
    hardware.watch,
    function(eventRecord, warnings, eventError)
        assert(type(warnings) == "table")
        assert(eventError == nil)
        state.eventRecords[#state.eventRecords + 1] = eventRecord
    end
)

assert(not watcherSucceeded)
assert(tostring(watcherFailure) == TEST_STOP)
assert(state.eventIndex == #events + 1)
assert(#state.eventRecords == 5)

assert(state.eventRecords[1].kind == "attached")
assert(state.eventRecords[1].name == "left")
assert(state.eventRecords[1].descriptor.state == "wireless")
assert(state.eventRecords[1].level == "info")

assert(state.eventRecords[2].kind == "detached")
assert(state.eventRecords[2].message == "Peripheral detached: left")
assert(state.eventRecords[3].name == "monitor_0")
assert(state.eventRecords[3].descriptor.support == "supported")
assert(state.eventRecords[4].kind == "detached")
assert(state.eventRecords[5].name == "addon_0")
assert(state.eventRecords[5].descriptor.support == "unsupported")
assert(state.eventRecords[5].level == "warn")

-- A detach never queries the already-removed device. `left` has exactly three
-- attach queries: presence, types, and modem state. The terminate/key events
-- generated no callback and did not stop the watcher.
assert(state.queries.left == 3)
assert(state.queries.monitor_0 == 2)
assert(state.filesystemMutations == 0)

io.stdout:write("hardware runtime watcher tests: PASS\n")
