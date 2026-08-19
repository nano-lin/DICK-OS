-- Host-side tests for DICK/OS service discovery, lifecycle, and autostart
-- Run with: lua tests/service_manager_test.lua

local DICKD_SOURCE = "src/dickos/system/dickd.lua"
local CONFIG_SOURCE = "src/dickos/lib/config.lua"
local CONFIG_PATH = "/dickos/lib/config.lua"
local LOG_PATH = "/dickos/lib/log.lua"
local SERVICES_DIRECTORY = "/dickos/services"
local SERVICES_CONFIG_PATH = "/dickos/etc/services.cfg"
local hostLoadfile = loadfile
local hostLoad = load

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function defaultContext()
    return {
        runtimeApiVersion = 1,
        bootID = "B-DICKD001",
        version = "0.1.0-unstable",
        hostname = "test-01",
        machineID = "DCK-C-11-A91F",
        -- These fields must never reach a service context.
        user = "nano",
        uid = 1000,
        isAdmin = true,
        cwd = "/dickos/home/nano",
    }
end

local function makeHarness(options)
    options = options or {}

    local state = {
        files = options.files or {},
        directories = options.directories or {},
        directoryExists = options.directoryExists ~= false,
        configText = options.configText or "format_version = 1\n",
        logs = {},
        queued = {},
        serviceState = {},
        terminalCalls = 0,
    }
    local environment = {
        _TEST_STATE = state.serviceState,
        print = function()
            state.terminalCalls = state.terminalCalls + 1
        end,
        write = function()
            state.terminalCalls = state.terminalCalls + 1
        end,
        read = function()
            state.terminalCalls = state.terminalCalls + 1
        end,
        term = {
            write = function()
                state.terminalCalls = state.terminalCalls + 1
            end,
        },
    }

    environment.os = {
        queueEvent = function(name, value)
            state.queued[#state.queued + 1] = { name, value }
        end,
    }

    environment.fs = {
        exists = function(path)
            if path == SERVICES_DIRECTORY then
                return state.directoryExists
            end

            if path == SERVICES_CONFIG_PATH then
                return not options.missingConfig
            end

            return state.files[path] ~= nil or
                state.directories[path] == true
        end,
        isDir = function(path)
            if path == SERVICES_DIRECTORY then
                return state.directoryExists
            end

            return state.directories[path] == true
        end,
        list = function(path)
            assert(path == SERVICES_DIRECTORY)

            if options.listFailure then
                error("simulated list failure", 0)
            end

            local entries = {}
            local prefix = SERVICES_DIRECTORY .. "/"

            for filePath in pairs(state.files) do
                if string.sub(filePath, 1, #prefix) == prefix then
                    entries[#entries + 1] = string.sub(filePath, #prefix + 1)
                end
            end

            for directoryPath in pairs(state.directories) do
                if string.sub(directoryPath, 1, #prefix) == prefix then
                    entries[#entries + 1] =
                        string.sub(directoryPath, #prefix + 1)
                end
            end

            table.sort(entries)
            return entries
        end,
        getSize = function(path)
            assert(path == SERVICES_CONFIG_PATH)
            return #state.configText
        end,
        open = function(path, mode)
            assert(path == SERVICES_CONFIG_PATH)
            assert(mode == "r")

            if options.unreadableConfig then
                return nil, "simulated unreadable services.cfg"
            end

            return {
                readAll = function() return state.configText end,
                close = function() end,
            }
        end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path, mode, requestedEnvironment)
        if path == CONFIG_PATH then
            if options.missingConfigLibrary then
                return nil, "simulated missing config library"
            end

            return hostLoadfile(CONFIG_SOURCE, "t", environment)
        end

        if path == LOG_PATH then
            return function()
                return {
                    create = function(target)
                        local logger = {}

                        for _, level in ipairs({
                            "debug",
                            "info",
                            "warn",
                            "error",
                            "critical",
                        }) do
                            logger[level] = function(component, message)
                                state.logs[#state.logs + 1] = {
                                    target = target,
                                    level = level,
                                    component = component,
                                    message = tostring(message),
                                }
                            end
                        end

                        return logger
                    end,
                }
            end
        end

        local source = state.files[path]

        if source ~= nil then
            return hostLoad(
                source,
                "@" .. path,
                mode or "t",
                requestedEnvironment or environment
            )
        end

        return nil, "not found"
    end

    local program = assert(hostLoadfile(DICKD_SOURCE, "t", environment))
    local module = program()
    local manager = module.create(defaultContext())

    return module, manager, state
end

local function findLog(state, level, fragment)
    for _, record in ipairs(state.logs) do
        if record.level == level and record.component == "dickd" and
            contains(record.message, fragment) then
            return true
        end
    end

    return false
end

local lifecycleService = [[
_TEST_STATE.loads = (_TEST_STATE.loads or 0) + 1
return {
    run = function(context)
        _TEST_STATE.context = context
        _TEST_STATE.runCount = (_TEST_STATE.runCount or 0) + 1
        if _TEST_STATE.manager ~= nil then
            _TEST_STATE.startState = _TEST_STATE.manager.records.alpha.state
        end
        while true do
            local event, value = coroutine.yield("service_tick")
            _TEST_STATE.lastEvent = event
            _TEST_STATE.lastValue = value
            _TEST_STATE.eventCount = (_TEST_STATE.eventCount or 0) + 1
        end
    end,
    stop = function(context)
        assert(context.name == "alpha")
        _TEST_STATE.stopCount = (_TEST_STATE.stopCount or 0) + 1
    end,
}
]]

-- Discovery accepts only lowercase service IDs backed by ordinary .lua files.
local _, discoveryManager = makeHarness({
    files = {
        [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
        [SERVICES_DIRECTORY .. "/b2_worker.lua"] =
            "return { run = function() coroutine.yield() end }",
        [SERVICES_DIRECTORY .. "/Bad.lua"] = "return {}",
        [SERVICES_DIRECTORY .. "/bad-name.lua"] = "return {}",
        [SERVICES_DIRECTORY .. "/notes.txt"] = "not lua",
    },
    directories = {
        [SERVICES_DIRECTORY .. "/directory.lua"] = true,
    },
})
local listed, services = discoveryManager:list()
assert(listed)
assert(#services == 2)
assert(services[1].name == "alpha")
assert(services[2].name == "b2_worker")
assert(services[1].state == "STOPPED")
assert(services[1].autostart == false)

local _, emptyManager = makeHarness({ directoryExists = false })
local emptyListed, emptyServices = emptyManager:list()
assert(emptyListed)
assert(#emptyServices == 0)

local _, presentEmptyManager = makeHarness({ files = {} })
local presentEmptyListed, presentEmptyServices = presentEmptyManager:list()
assert(presentEmptyListed)
assert(#presentEmptyServices == 0)

local _, dynamicManager, dynamicState = makeHarness({ files = {} })
assert(select(2, dynamicManager:list())[1] == nil)
dynamicState.files[SERVICES_DIRECTORY .. "/new_service.lua"] =
    "return { run = function() coroutine.yield() end }"
local dynamicListed, dynamicServices = dynamicManager:list()
assert(dynamicListed)
assert(#dynamicServices == 1)
assert(dynamicServices[1].name == "new_service")

-- Start resumes exactly once, exposes only the data-only service context, and
-- event delivery honours the yielded filter without changing lifecycle state.
local _, manager, state = makeHarness({
    files = {
        [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
    },
})
state.serviceState.manager = manager
local started, startedService = manager:start("alpha")
assert(started)
assert(startedService.state == "RUNNING")
assert(state.serviceState.loads == 1)
assert(state.serviceState.runCount == 1)
assert(state.serviceState.startState == "STARTING")
assert(state.serviceState.context.serviceApiVersion == 1)
assert(state.serviceState.context.name == "alpha")
assert(state.serviceState.context.runtimeApiVersion == 1)
assert(state.serviceState.context.bootID == "B-DICKD001")
assert(state.serviceState.context.version == "0.1.0-unstable")
assert(state.serviceState.context.hostname == "test-01")
assert(state.serviceState.context.machineID == "DCK-C-11-A91F")
assert(state.serviceState.context.user == nil)
assert(state.serviceState.context.uid == nil)
assert(state.serviceState.context.isAdmin == nil)
assert(state.serviceState.context.cwd == nil)

manager:handleEvent("other_event", "ignored")
assert(state.serviceState.eventCount == nil)
manager:handleEvent("service_tick", "delivered")
assert(state.serviceState.eventCount == 1)
assert(state.serviceState.lastEvent == "service_tick")
assert(state.serviceState.lastValue == "delivered")

local duplicateStarted, duplicateError = manager:start("alpha")
assert(not duplicateStarted)
assert(contains(duplicateError, "already running"))

local stopped, stoppedService = manager:stop("alpha")
assert(stopped)
assert(stoppedService.state == "STOPPED")
assert(state.serviceState.stopCount == 1)

local restarted, restartedService = manager:restart("alpha")
assert(restarted)
assert(restartedService.state == "RUNNING")
assert(state.serviceState.loads == 2)
assert(state.serviceState.runCount == 2)

-- Removing source before restart stops the old instance, reports one safe
-- source classification, and never executes a cached module.
state.files[SERVICES_DIRECTORY .. "/alpha.lua"] = nil
local removedRestarted, removedError = manager:restart("alpha")
assert(not removedRestarted)
assert(contains(removedError, "source unavailable"))
assert(manager.records.alpha.state == "FAILED")
assert(manager.records.alpha.failure == "source unavailable")
assert(state.serviceState.loads == 2)

-- Each load/runtime failure is contained in the affected service and exposed
-- only through a stable classification, never its arbitrary raw error text.
local failureCases = {
    {
        name = "syntax_error",
        source = "this is not lua !!! SECRET_SYNTAX",
        classification = "source load error",
    },
    {
        name = "load_error",
        source = "error('SECRET_LOAD', 0)",
        classification = "module load error",
    },
    {
        name = "wrong_type",
        source = "return 'not a module'",
        classification = "invalid service module",
    },
    {
        name = "hostile_index",
        source = "return setmetatable({}, { __index = function() " ..
            "error('SECRET_INDEX', 0) end })",
        classification = "invalid service module",
    },
    {
        name = "invalid_module",
        source = "return { stop = function() end }",
        classification = "invalid service module",
    },
    {
        name = "runtime_error",
        source = "return { run = function() error('SECRET_RUN', 0) end }",
        classification = "runtime error",
    },
    {
        name = "returns",
        source = "return { run = function() return 'done' end }",
        classification = "unexpected return",
    },
    {
        name = "bad_filter",
        source = "return { run = function() coroutine.yield({}) end }",
        classification = "invalid event filter",
    },
}

for _, failureCase in ipairs(failureCases) do
    local path = SERVICES_DIRECTORY .. "/" .. failureCase.name .. ".lua"
    local _, failureManager, failureState = makeHarness({
        files = { [path] = failureCase.source },
    })
    local failureStarted, failureMessage =
        failureManager:start(failureCase.name)

    assert(not failureStarted)
    assert(contains(failureMessage, failureCase.classification))
    assert(failureManager.records[failureCase.name].state == "FAILED")
    assert(failureManager.records[failureCase.name].failure ==
        failureCase.classification)
    local statusSucceeded, failedStatus =
        failureManager:status(failureCase.name)
    assert(statusSucceeded)
    assert(failedStatus.state == "FAILED")
    assert(failedStatus.failure == failureCase.classification)

    for _, record in ipairs(failureState.logs) do
        assert(not contains(record.message, "SECRET_"))
    end
end

local _, absentManager = makeHarness({ files = {} })
local absentStarted, absentError = absentManager:start("missing_service")
assert(not absentStarted)
assert(absentError == "Service not found.")

-- FAILED restart also recompiles the current source rather than retaining the
-- failed module/coroutine instance.
local failedRestartPath = SERVICES_DIRECTORY .. "/repairable.lua"
local _, failedRestartManager, failedRestartState = makeHarness({
    files = {
        [failedRestartPath] =
            "_TEST_STATE.failedLoads = (_TEST_STATE.failedLoads or 0) + 1; " ..
            "return { run = function() error('first failure') end }",
    },
})
assert(not failedRestartManager:start("repairable"))
assert(failedRestartManager.records.repairable.state == "FAILED")
failedRestartState.files[failedRestartPath] =
    "_TEST_STATE.failedLoads = (_TEST_STATE.failedLoads or 0) + 1; " ..
    "return { run = function() coroutine.yield() end }"
local repaired, repairedService = failedRestartManager:restart("repairable")
assert(repaired)
assert(repairedService.state == "RUNNING")
assert(failedRestartState.serviceState.failedLoads == 2)

-- Terminal functions are blocked inside the inherited service environment.
for name, source in pairs({
    prints = "return { run = function() print('no') end }",
    writes = "return { run = function() write('no') end }",
    reads = "return { run = function() read() end }",
    terms = "return { run = function() term.write('no') end }",
}) do
    local _, terminalManager, terminalState = makeHarness({
        files = {
            [SERVICES_DIRECTORY .. "/" .. name .. ".lua"] = source,
        },
    })
    local terminalStarted = terminalManager:start(name)

    assert(not terminalStarted)
    assert(terminalManager.records[name].failure == "runtime error")
    assert(terminalState.terminalCalls == 0)
end

-- A yielding or failing stop hook cannot suspend dickd and still discards the
-- service runtime into STOPPED.
for name, stopBody in pairs({
    yield_stop = "coroutine.yield('never_resume')",
    fail_stop = "error('SECRET_STOP', 0)",
}) do
    local source = "return { run = function() coroutine.yield() end, " ..
        "stop = function() " .. stopBody .. " end }"
    local _, stopManager, stopState = makeHarness({
        files = {
            [SERVICES_DIRECTORY .. "/" .. name .. ".lua"] = source,
        },
    })

    assert(stopManager:start(name))
    local hookStopped, hookSnapshot = stopManager:stop(name)
    assert(hookStopped)
    assert(type(hookSnapshot.warning) == "string")
    assert(stopManager.records[name].state == "STOPPED")
    assert(stopManager.records[name].coroutine == nil)
    assert(findLog(stopState, "warn", "stop hook"))
end

-- Dynamic config autostarts valid services independently. A failing neighbour
-- cannot prevent a healthy service, and a wrong-type entry is isolated.
local autostartConfig = table.concat({
    "format_version = 1",
    "service.alpha.autostart = true",
    "service.broken.autostart = true",
    'service.wrong.autostart = "yes"',
    "service.disabled.autostart = false",
    "",
}, "\n")
local _, autostartManager, autostartState = makeHarness({
    configText = autostartConfig,
    files = {
        [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
        [SERVICES_DIRECTORY .. "/broken.lua"] =
            "return { run = function() error('broken') end }",
        [SERVICES_DIRECTORY .. "/disabled.lua"] =
            "return { run = function() coroutine.yield() end }",
    },
})
autostartManager:initialize()
assert(autostartManager.records.alpha.state == "RUNNING")
assert(autostartManager.records.broken.state == "FAILED")
assert(autostartManager.records.disabled.state == "STOPPED")
assert(autostartManager.records.alpha.autostart == true)
assert(findLog(autostartState, "warn", "service.wrong.autostart"))

for _, badConfig in ipairs({
    "not config\n",
    "format_version = 2\nservice.alpha.autostart = true\n",
}) do
    local _, badConfigManager, badConfigState = makeHarness({
        configText = badConfig,
        files = {
            [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
        },
    })
    badConfigManager:initialize()
    assert(badConfigManager.records.alpha.state == "STOPPED")
    assert(findLog(badConfigState, "warn", "no autostarts selected"))
end


-- Config contents are parsed as scalar data. Text which would mutate a Lua
-- global if executed is merely malformed config and leaves the marker unset.
local _, dataOnlyManager, dataOnlyState = makeHarness({
    configText = table.concat({
        "format_version = 1",
        "_TEST_STATE.configExecuted = true",
        "",
    }, "\n"),
    files = {
        [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
    },
})
dataOnlyManager:initialize()
assert(dataOnlyState.serviceState.configExecuted == nil)
assert(dataOnlyManager.records.alpha.state == "STOPPED")
assert(findLog(dataOnlyState, "warn", "no autostarts selected"))

local _, zeroAutostartManager = makeHarness({
    files = {
        [SERVICES_DIRECTORY .. "/alpha.lua"] = lifecycleService,
    },
})
zeroAutostartManager:initialize()
assert(zeroAutostartManager.records.alpha.state == "STOPPED")

io.stdout:write("service manager tests: PASS\n")
