-- Host-side integration tests for init configuration and shell history
-- Run with: lua tests/config_integration_test.lua

local INIT_SOURCE = "src/dickos/system/init.lua"
local SHELL_SOURCE = "src/dickos/system/shell.lua"
local CONFIG_SOURCE = "src/dickos/lib/config.lua"

local CONFIG_PATH = "/dickos/lib/config.lua"
local SYSTEM_CONFIG_PATH = "/dickos/etc/system.cfg"
local LOG_PATH = "/dickos/lib/log.lua"
local DICKFETCH_PATH = "/dickos/bin/dickfetch.lua"
local INSTALLED_SHELL_PATH = "/dickos/system/shell.lua"
local AUTH_PATH = "/dickos/lib/auth.lua"
local LOGIN_PATH = "/dickos/system/login.lua"
local HARDWARE_PATH = "/dickos/lib/hardware.lua"
local DICKD_PATH = "/dickos/system/dickd.lua"

local SHELL_TEST_STOP = "__DICK_CONFIG_INTEGRATION_SHELL_REACHED__"
local INPUT_TEST_STOP = "__DICK_CONFIG_INTEGRATION_INPUT_STOP__"
local hostLoadfile = loadfile

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local colorsMock = {
    black = 1,
    white = 2,
    lightGray = 3,
    gray = 4,
    lightBlue = 5,
    lime = 6,
    yellow = 7,
    red = 8,
}

local function makeLoggerModule(state)
    return {
        create = function(targetName)
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
                        target = targetName,
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

local function hasLog(state, level, fragment)
    for _, record in ipairs(state.logs) do
        if record.level == level and contains(record.message, fragment) then
            return true
        end
    end

    return false
end

-- Execute the real init with only its platform edges mocked. The mock shell
-- records the final context and raises a sentinel because a healthy real shell
-- is intentionally non-returning. Reaching that sentinel proves configuration
-- data failures continued to the protected DICK shell handoff.
local function runInitScenario(options)
    options = options or {}

    local configText = options.configText

    if configText == nil then
        configText = table.concat({
            "format_version = 1",
            "boot.cosmetic_delay = true",
            "shell.history_limit = 64",
            "",
        }, "\n")
    end

    local state = {
        logs = {},
        shellContext = nil,
        shellContexts = {},
        loginCount = 0,
        dickfetchCount = 0,
        lifecycle = {},
        timerCount = 0,
        hardwareScanCount = 0,
        watcherStarts = 0,
        dickdStarts = 0,
        dickdContexts = {},
        parallelCalls = 0,
        inBackgroundTask = false,
    }
    local metadata = {
        ["/dickos/etc/version"] = "0.1.0-unstable",
        ["/dickos/etc/hostname"] = "test-01",
        ["/dickos/etc/machine-id"] = "DCK-C-11-A91F",
    }
    local environment = {
        colors = colorsMock,
        print = function() end,
    }

    environment.term = {
        setBackgroundColor = function() end,
        setTextColor = function() end,
        setCursorBlink = function() end,
        clear = function() end,
        setCursorPos = function() end,
        write = function() end,
        getSize = function() return 51, 19 end,
    }

    environment.os = {
        startTimer = function(delay)
            assert(delay == 0.05)
            state.timerCount = state.timerCount + 1
            return state.timerCount
        end,
        pullEventRaw = function()
            if state.inBackgroundTask then
                return coroutine.yield("degraded-runtime-ready")
            end

            return "timer", state.timerCount
        end,
    }

    local dickdAvailable = options.dickdAvailable ~= false

    -- This intentionally small scheduler mock exercises init's ownership
    -- boundary, not CC:T's scheduler implementation. Every background sibling
    -- is started once and suspended, then the complete login/logout lifecycle
    -- runs as task one. Dedicated hardware/dickd tests cover event dispatch.
    if options.hardwareAvailable or dickdAvailable then
        environment.parallel = {
            waitForAny = function(...)
                state.parallelCalls = state.parallelCalls + 1
                local tasks = { ... }

                for index = 2, #tasks do
                    local backgroundCoroutine = coroutine.create(tasks[index])
                    state.inBackgroundTask = true
                    local backgroundStarted, marker = coroutine.resume(
                        backgroundCoroutine
                    )
                    state.inBackgroundTask = false

                    assert(backgroundStarted, tostring(marker))
                    assert(marker == "hardware-watcher-ready" or
                        marker == "dickd-ready" or
                        marker == "degraded-runtime-ready")
                    assert(coroutine.status(backgroundCoroutine) == "suspended")
                end

                tasks[1]()
                return 1
            end,
        }
    end

    environment.fs = {
        exists = function(path)
            if path == SYSTEM_CONFIG_PATH then
                return not options.missingConfigFile
            end

            return metadata[path] ~= nil
        end,
        isDir = function()
            return false
        end,
        getSize = function(path)
            assert(path == SYSTEM_CONFIG_PATH)
            return #configText
        end,
        open = function(path, mode)
            assert(mode == "r")

            if path == SYSTEM_CONFIG_PATH then
                if options.unreadableConfigFile then
                    return nil, "simulated unreadable system.cfg"
                end

                return {
                    readAll = function() return configText end,
                    close = function() end,
                }
            end

            local value = metadata[path]

            if value == nil then
                return nil, "not found"
            end

            return {
                readLine = function() return value end,
                close = function() end,
            }
        end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        if path == CONFIG_PATH then
            if options.missingConfigLibrary then
                return nil, "simulated missing config.lua"
            end

            if options.brokenConfigLibrary then
                return function()
                    error("simulated broken config.lua", 0)
                end
            end

            return hostLoadfile(CONFIG_SOURCE, "t", environment)
        end

        if path == LOG_PATH then
            return function() return makeLoggerModule(state) end
        end

        if path == DICKFETCH_PATH then
            return function()
                state.dickfetchCount = state.dickfetchCount + 1
                state.lifecycle[#state.lifecycle + 1] = "dickfetch"

                if options.brokenDickfetch then
                    error("simulated dickfetch failure", 0)
                end
            end
        end

        if path == AUTH_PATH then
            if options.missingAuthCore then
                return nil, "simulated missing auth.lua"
            end

            return function()
                return {
                    validateState = function()
                        if options.invalidAuthenticationState then
                            return false, "simulated invalid users.db"
                        end

                        return true
                    end,
                }
            end
        end

        if path == LOGIN_PATH then
            if options.missingLoginModule then
                return nil, "simulated missing login.lua"
            end

            return function()
                state.loginCount = state.loginCount + 1
                state.lifecycle[#state.lifecycle + 1] = "login"
                return {
                    name = "nano",
                    uid = 1000,
                    home = "/dickos/home/nano",
                    admin = true,
                }
            end
        end

        if path == HARDWARE_PATH then
            if not options.hardwareAvailable then
                return nil, "simulated missing hardware.lua"
            end

            if options.invalidHardwareAPI then
                return function() return {} end
            end

            return function()
                return {
                    scan = function()
                        state.hardwareScanCount =
                            state.hardwareScanCount + 1

                        if options.hardwareScanFailure then
                            error("simulated hardware scan failure", 0)
                        end

                        return options.hardwareDescriptors or {},
                            options.hardwareWarnings or {}, nil
                    end,
                    watch = function(callback)
                        state.watcherStarts = state.watcherStarts + 1
                        callback({
                            level = "info",
                            message = "Peripheral attached: left " ..
                                "type=modem state=wireless " ..
                                "support=supported",
                        }, {}, nil)
                        callback({
                            level = "info",
                            message = "Peripheral detached: left",
                        }, {}, nil)
                        coroutine.yield("hardware-watcher-ready")
                        error("hardware watcher resumed after session", 0)
                    end,
                }
            end
        end

        if path == DICKD_PATH then
            if not dickdAvailable then
                return nil, "simulated missing dickd.lua"
            end

            if options.invalidDICKDAPI then
                return function() return {} end
            end

            if options.throwingDICKDAPI then
                return function()
                    return setmetatable({}, {
                        __index = function()
                            error("simulated throwing dickd API", 0)
                        end,
                    })
                end
            end

            return function()
                return {
                    run = function(context)
                        state.dickdStarts = state.dickdStarts + 1
                        state.dickdContexts[#state.dickdContexts + 1] = context

                        if options.dickdRuntimeFailure then
                            error("simulated dickd runtime failure", 0)
                        end

                        coroutine.yield("dickd-ready")
                        error("dickd resumed after session", 0)
                    end,
                }
            end
        end

        if path == INSTALLED_SHELL_PATH then
            return function(context)
                state.lifecycle[#state.lifecycle + 1] = "shell"
                state.shellContext = context
                state.shellContexts[#state.shellContexts + 1] = context

                if options.logoutOnce and #state.shellContexts == 1 then
                    return "logout"
                end

                if options.invalidShellReturn then
                    return "unexpected"
                end

                error(SHELL_TEST_STOP, 0)
            end
        end

        return nil, "unexpected load path: " .. tostring(path)
    end

    local initProgram = assert(hostLoadfile(INIT_SOURCE, "t", environment))
    local succeeded, failure = pcall(initProgram, {
        apiVersion = 1,
        bootID = "B-1234ABCD",
    })

    return state, succeeded, failure
end

local delayedState, delayedSucceeded, delayedFailure = runInitScenario({
    hardwareAvailable = true,
})
assert(not delayedSucceeded)
assert(contains(delayedFailure, SHELL_TEST_STOP))
assert(delayedState.shellContext ~= nil)
assert(delayedState.shellContext.shellHistoryLimit == 64)
assert(delayedState.shellContext.user == "nano")
assert(delayedState.shellContext.uid == 1000)
assert(delayedState.shellContext.home == "/dickos/home/nano")
assert(delayedState.shellContext.isAdmin == true)
assert(delayedState.shellContext.password == nil)
assert(delayedState.shellContext.verifier == nil)
assert(delayedState.shellContext.users == nil)
assert(delayedState.shellContext.auth == nil)
assert(delayedState.timerCount == 24)
assert(table.concat(delayedState.lifecycle, ",") ==
    "login,dickfetch,shell")
assert(hasLog(delayedState, "info", "Configuration library loaded"))
assert(hasLog(delayedState, "info", "System configuration loaded"))
assert(hasLog(delayedState, "info", "Initial hardware discovery completed: 0"))
assert(delayedState.hardwareScanCount == 1)
assert(delayedState.watcherStarts == 1)
assert(delayedState.dickdStarts == 1)
assert(delayedState.parallelCalls == 1)
assert(#delayedState.dickdContexts == 1)
assert(delayedState.dickdContexts[1].runtimeApiVersion == 1)
assert(delayedState.dickdContexts[1].bootID == "B-1234ABCD")
assert(delayedState.dickdContexts[1].version == "0.1.0-unstable")
assert(delayedState.dickdContexts[1].hostname == "test-01")
assert(delayedState.dickdContexts[1].machineID == "DCK-C-11-A91F")
assert(delayedState.dickdContexts[1].user == nil)
assert(delayedState.dickdContexts[1].uid == nil)
assert(delayedState.dickdContexts[1].isAdmin == nil)
assert(delayedState.dickdContexts[1].cwd == nil)
assert(hasLog(delayedState, "info", "Peripheral attached: left"))
assert(hasLog(delayedState, "info", "Peripheral detached: left"))

local immediateState, immediateSucceeded, immediateFailure = runInitScenario({
    configText = table.concat({
        "format_version = 1",
        "boot.cosmetic_delay = false",
        "shell.history_limit = 3",
        "",
    }, "\n"),
})
assert(not immediateSucceeded)
assert(contains(immediateFailure, SHELL_TEST_STOP))
assert(immediateState.shellContext.shellHistoryLimit == 3)
assert(immediateState.timerCount == 0)

local invalidValueState, invalidValueSucceeded, invalidValueFailure =
    runInitScenario({
        configText = table.concat({
            "format_version = 1",
            "boot.cosmetic_delay = false",
            'shell.history_limit = "many"',
            "",
        }, "\n"),
    })
assert(not invalidValueSucceeded)
assert(contains(invalidValueFailure, SHELL_TEST_STOP))
assert(invalidValueState.shellContext.shellHistoryLimit == 64)
assert(invalidValueState.timerCount == 0)
assert(hasLog(invalidValueState, "warn", "shell.history_limit"))

for _, record in ipairs(invalidValueState.logs) do
    assert(not contains(record.message, "many"))
end

local malformedState, malformedSucceeded, malformedFailure = runInitScenario({
    configText = "this is not valid config\n",
})
assert(not malformedSucceeded)
assert(contains(malformedFailure, SHELL_TEST_STOP))
assert(malformedState.shellContext.shellHistoryLimit == 64)
assert(malformedState.timerCount == 24)
assert(hasLog(malformedState, "warn", "expected '='"))
assert(hasLog(malformedState, "warn", "defaults active"))

local missingFileState, missingFileSucceeded, missingFileFailure =
    runInitScenario({ missingConfigFile = true })
assert(not missingFileSucceeded)
assert(contains(missingFileFailure, SHELL_TEST_STOP))
assert(missingFileState.shellContext.shellHistoryLimit == 64)
assert(hasLog(missingFileState, "warn", "Configuration file is missing"))

local missingCoreState, missingCoreSucceeded, missingCoreFailure =
    runInitScenario({ missingConfigLibrary = true })
assert(not missingCoreSucceeded)
assert(missingCoreState.shellContext == nil)
assert(contains(missingCoreFailure, "Unable to load configuration core"))

local brokenCoreState, brokenCoreSucceeded, brokenCoreFailure =
    runInitScenario({ brokenConfigLibrary = true })
assert(not brokenCoreSucceeded)
assert(brokenCoreState.shellContext == nil)
assert(contains(brokenCoreFailure, "Unable to start configuration core"))

local missingAuthState, missingAuthSucceeded, missingAuthFailure =
    runInitScenario({ missingAuthCore = true })
assert(not missingAuthSucceeded)
assert(missingAuthState.shellContext == nil)
assert(contains(missingAuthFailure, "Unable to load authentication core"))

local invalidAuthState, invalidAuthSucceeded, invalidAuthFailure =
    runInitScenario({ invalidAuthenticationState = true })
assert(not invalidAuthSucceeded)
assert(invalidAuthState.shellContext == nil)
assert(contains(invalidAuthFailure, "Authentication state is invalid"))

local missingLoginState, missingLoginSucceeded, missingLoginFailure =
    runInitScenario({ missingLoginModule = true })
assert(not missingLoginSucceeded)
assert(missingLoginState.shellContext == nil)
assert(missingLoginState.dickfetchCount == 0)
assert(contains(missingLoginFailure, "Unable to load DICK login"))

local brokenDickfetchState, brokenDickfetchSucceeded, brokenDickfetchFailure =
    runInitScenario({ brokenDickfetch = true })
assert(not brokenDickfetchSucceeded)
assert(contains(brokenDickfetchFailure, SHELL_TEST_STOP))
assert(brokenDickfetchState.shellContext ~= nil)
assert(table.concat(brokenDickfetchState.lifecycle, ",") ==
    "login,dickfetch,shell")
assert(hasLog(brokenDickfetchState, "warn", "Presentation failure"))

local logoutState, logoutSucceeded, logoutFailure = runInitScenario({
    logoutOnce = true,
    hardwareAvailable = true,
    configText = table.concat({
        "format_version = 1",
        "boot.cosmetic_delay = false",
        "shell.history_limit = 64",
        "",
    }, "\n"),
})
assert(not logoutSucceeded)
assert(contains(logoutFailure, SHELL_TEST_STOP))
assert(logoutState.loginCount == 2)
assert(logoutState.dickfetchCount == 2)
assert(#logoutState.shellContexts == 2)
assert(table.concat(logoutState.lifecycle, ",") ==
    "login,dickfetch,shell,login,dickfetch,shell")
assert(logoutState.shellContexts[1].bootID == "B-1234ABCD")
assert(logoutState.shellContexts[2].bootID == "B-1234ABCD")
assert(logoutState.shellContexts[1].uid == 1000)
assert(logoutState.shellContexts[1].isAdmin == true)
assert(logoutState.hardwareScanCount == 1)
assert(logoutState.watcherStarts == 1)
assert(logoutState.dickdStarts == 1)
assert(logoutState.parallelCalls == 1)

local unavailableHardwareState, unavailableHardwareSucceeded,
    unavailableHardwareFailure = runInitScenario({})
assert(not unavailableHardwareSucceeded)
assert(contains(unavailableHardwareFailure, SHELL_TEST_STOP))
assert(unavailableHardwareState.shellContext ~= nil)
assert(hasLog(
    unavailableHardwareState,
    "error",
    "Hardware discovery unavailable"
))

local failedHardwareState, failedHardwareSucceeded, failedHardwareFailure =
    runInitScenario({
        hardwareAvailable = true,
        hardwareScanFailure = true,
    })
assert(not failedHardwareSucceeded)
assert(contains(failedHardwareFailure, SHELL_TEST_STOP))
assert(failedHardwareState.shellContext ~= nil)
assert(hasLog(failedHardwareState, "error", "hardware scan failure"))
assert(failedHardwareState.watcherStarts == 1)

local unavailableDICKDState, unavailableDICKDSucceeded,
    unavailableDICKDFailure = runInitScenario({ dickdAvailable = false })
assert(not unavailableDICKDSucceeded)
assert(contains(unavailableDICKDFailure, SHELL_TEST_STOP))
assert(unavailableDICKDState.shellContext ~= nil)
assert(unavailableDICKDState.dickdStarts == 0)
assert(hasLog(
    unavailableDICKDState,
    "error",
    "Service supervisor unavailable"
))

local failedDICKDState, failedDICKDSucceeded, failedDICKDFailure =
    runInitScenario({ dickdRuntimeFailure = true })
assert(not failedDICKDSucceeded)
assert(contains(failedDICKDFailure, SHELL_TEST_STOP))
assert(failedDICKDState.shellContext ~= nil)
assert(failedDICKDState.dickdStarts == 1)
assert(failedDICKDState.parallelCalls == 1)
assert(hasLog(failedDICKDState, "error", "Service supervisor failed"))

local throwingDICKDState, throwingDICKDSucceeded, throwingDICKDFailure =
    runInitScenario({ throwingDICKDAPI = true })
assert(not throwingDICKDSucceeded)
assert(contains(throwingDICKDFailure, SHELL_TEST_STOP))
assert(throwingDICKDState.shellContext ~= nil)
assert(throwingDICKDState.dickdStarts == 0)
assert(hasLog(
    throwingDICKDState,
    "error",
    "Service supervisor unavailable"
))

local invalidReturnState, invalidReturnSucceeded, invalidReturnFailure =
    runInitScenario({ invalidShellReturn = true })
assert(not invalidReturnSucceeded)
assert(invalidReturnState.loginCount == 1)
assert(contains(invalidReturnFailure, "invalid result"))

-- SHELL HISTORY -----------------------------------------------------------

local function copyList(list)
    local copied = {}

    for index, value in ipairs(list) do
        copied[index] = value
    end

    return copied
end

local function runShellHistoryScenario(historyLimit, inputLines, expectedReturn)
    local state = {
        cursorX = 1,
        cursorY = 1,
        histories = {},
        inputIndex = 0,
        logs = {},
    }
    local environment = {
        colors = colorsMock,
        print = function()
            state.cursorX = 1
            state.cursorY = state.cursorY + 1
        end,
    }

    environment.term = {
        setBackgroundColor = function() end,
        setTextColor = function() end,
        setCursorBlink = function() end,
        clear = function()
            state.cursorX = 1
            state.cursorY = 1
        end,
        setCursorPos = function(x, y)
            state.cursorX = x
            state.cursorY = y
        end,
        getCursorPos = function()
            return state.cursorX, state.cursorY
        end,
        write = function(value)
            state.cursorX = state.cursorX + #tostring(value)
        end,
    }

    environment.fs = {
        exists = function(path)
            return path == "/dickos/home/nano"
        end,
        isDir = function(path)
            return path == "/dickos/home/nano"
        end,
        makeDir = function() end,
        list = function() return {} end,
    }

    environment.read = function(_, history)
        state.histories[#state.histories + 1] = copyList(history)
        state.inputIndex = state.inputIndex + 1
        local line = inputLines[state.inputIndex]

        if line == nil then
            error(INPUT_TEST_STOP, 0)
        end

        state.cursorX = 1
        state.cursorY = state.cursorY + 1
        return line
    end

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        assert(path == LOG_PATH)
        return function() return makeLoggerModule(state) end
    end

    local shellProgram = assert(hostLoadfile(
        SHELL_SOURCE,
        "t",
        environment
    ))
    local succeeded, failure = pcall(shellProgram, {
        runtimeApiVersion = 1,
        bootID = "B-1234ABCD",
        version = "0.1.0-unstable",
        hostname = "test-01",
        machineID = "DCK-C-11-A91F",
        user = "nano",
        uid = 1000,
        home = "/dickos/home/nano",
        isAdmin = true,
        shellHistoryLimit = historyLimit,
    })

    if expectedReturn ~= nil then
        assert(succeeded)
        assert(failure == expectedReturn)
    else
        assert(not succeeded)
        assert(contains(failure, INPUT_TEST_STOP))
    end

    return state
end

local limitedHistoryState = runShellHistoryScenario(3, {
    "unknown-one",
    "unknown-two",
    "unknown-three",
    "unknown-four",
})
local retainedHistory = limitedHistoryState.histories[5]
assert(#retainedHistory == 3)
assert(retainedHistory[1] == "unknown-two")
assert(retainedHistory[2] == "unknown-three")
assert(retainedHistory[3] == "unknown-four")

local disabledHistoryState = runShellHistoryScenario(0, {
    "unknown-one",
    "unknown-two",
})

for _, history in ipairs(disabledHistoryState.histories) do
    assert(#history == 0)
end

local logoutShellState = runShellHistoryScenario(64, { "logout" }, "logout")
assert(#logoutShellState.histories == 1)
local logoutHelpState = runShellHistoryScenario(
    64,
    { "logout --help", "logout" },
    "logout"
)
assert(#logoutHelpState.histories == 2)

io.stdout:write("configuration integration tests: PASS\n")
