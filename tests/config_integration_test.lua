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
        timerCount = 0,
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
            return "timer", state.timerCount
        end,
    }

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
            return function() end
        end

        if path == INSTALLED_SHELL_PATH then
            return function(context)
                state.shellContext = context
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

local delayedState, delayedSucceeded, delayedFailure = runInitScenario({})
assert(not delayedSucceeded)
assert(contains(delayedFailure, SHELL_TEST_STOP))
assert(delayedState.shellContext ~= nil)
assert(delayedState.shellContext.shellHistoryLimit == 64)
assert(delayedState.timerCount == 24)
assert(hasLog(delayedState, "info", "Configuration library loaded"))
assert(hasLog(delayedState, "info", "System configuration loaded"))

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

-- SHELL HISTORY -----------------------------------------------------------

local function copyList(list)
    local copied = {}

    for index, value in ipairs(list) do
        copied[index] = value
    end

    return copied
end

local function runShellHistoryScenario(historyLimit, inputLines)
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
            return path == "/dickos/home/bootstrap"
        end,
        isDir = function(path)
            return path == "/dickos/home/bootstrap"
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
        user = "bootstrap",
        home = "/dickos/home/bootstrap",
        shellHistoryLimit = historyLimit,
    })

    assert(not succeeded)
    assert(contains(failure, INPUT_TEST_STOP))
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

io.stdout:write("configuration integration tests: PASS\n")
