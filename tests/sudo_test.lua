-- Host-side tests for the DICK shell sudo builtin
-- Run with: lua tests/sudo_test.lua

local SHELL_SOURCE = "src/dickos/system/shell.lua"
local LOG_PATH = "/dickos/lib/log.lua"
local AUTH_PATH = "/dickos/lib/auth.lua"
local GUARD_PATH = "/dickos/lib/fs_guard.lua"
local hostLoadfile = loadfile

local colorsMock = {
    black = 1,
    white = 2,
    red = 3,
    lime = 4,
    lightBlue = 5,
    lightGray = 6,
}

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function copyList(values)
    local copied = {}
    for index, value in ipairs(values or {}) do copied[index] = value end
    return copied
end

local function runScenario(options)
    options = options or {}

    local state = {
        authCalls = 0,
        awaitingConfirmation = false,
        childCalls = {},
        clock = 0,
        cursorX = 1,
        cursorY = 1,
        histories = {},
        files = {},
        lineIndex = 0,
        logs = {},
        output = {},
        passwordIndex = 0,
        passwordReads = 0,
        confirmationIndex = 0,
        confirmationReads = 0,
    }
    local environment = { colors = colorsMock }

    environment.print = function(value)
        state.output[#state.output + 1] = tostring(value or "")
        state.cursorX = 1
        state.cursorY = state.cursorY + 1
    end
    environment.write = function(value)
        local text = tostring(value or "")
        state.output[#state.output + 1] = text
        state.cursorX = state.cursorX + #text

        if text == "> " then
            state.awaitingConfirmation = true
        end
    end
    environment.term = {
        setBackgroundColor = function() end,
        setTextColor = function() end,
        setCursorBlink = function() end,
        clear = function() state.cursorX = 1; state.cursorY = 1 end,
        setCursorPos = function(x, y) state.cursorX = x; state.cursorY = y end,
        getCursorPos = function() return state.cursorX, state.cursorY end,
        write = environment.write,
    }

    local nativeNames = {
        probe = true,
        fail = true,
        whoami = true,
        id = true,
        touch = true,
    }
    environment.fs = {
        exists = function(path)
            return path == "/" or path == "/dickos/home/nano" or
                path == "/dickos/bin" or
                state.files[path] ~= nil or
                nativeNames[string.match(path, "^/dickos/bin/(.+)%.lua$") or ""] == true or
                path == "/dickos/home/nano/script.lua"
        end,
        isDir = function(path)
            return path == "/" or path == "/dickos/home/nano" or
                path == "/dickos/bin"
        end,
        makeDir = function() end,
        open = function(path, mode)
            assert(mode == "w")
            state.files[path] = ""
            return { close = function() end }
        end,
        list = function(path)
            assert(path == "/dickos/bin")
            return {
                "probe.lua", "fail.lua", "whoami.lua", "id.lua", "touch.lua",
            }
        end,
    }

    environment.os = {
        clock = function() return state.clock end,
    }

    environment.read = function(replacement, history)
        if replacement == "*" then
            state.passwordReads = state.passwordReads + 1
            state.passwordIndex = state.passwordIndex + 1
            local value = assert(
                (options.passwords or {})[state.passwordIndex],
                "unexpected sudo password read"
            )

            if type(value) == "table" and value.error ~= nil then
                error(value.error, 0)
            end

            return value
        end

        if state.awaitingConfirmation then
            state.awaitingConfirmation = false
            state.confirmationReads = state.confirmationReads + 1
            state.confirmationIndex = state.confirmationIndex + 1
            return assert(
                (options.confirmations or {})[state.confirmationIndex],
                "unexpected critical-path confirmation"
            )
        end

        state.histories[#state.histories + 1] = copyList(history)
        state.lineIndex = state.lineIndex + 1
        local entry = assert(options.lines[state.lineIndex],
            "unexpected shell input read")

        if type(entry) == "table" then
            state.clock = entry.clock or state.clock
            return entry.line
        end

        return entry
    end

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        if path == LOG_PATH then
            return function()
                return {
                    create = function(target)
                        local logger = {}

                        for _, level in ipairs({ "info", "warn", "error" }) do
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

        if path == AUTH_PATH then
            if options.authUnavailable then
                return nil, "simulated missing auth"
            end

            return function()
                return {
                    authenticate = function(username, password)
                        state.authCalls = state.authCalls + 1

                        if type(options.authenticate) == "function" then
                            return options.authenticate(username, password)
                        end

                        if password ~= "correct password" then
                            return nil, "denied", "incorrect_password"
                        end

                        return {
                            name = "nano",
                            uid = 1000,
                            home = "/dickos/home/nano",
                            admin = true,
                        }
                    end,
                }
            end
        end

        if path == "/dickos/bin/probe.lua" then
            return function(context, ...)
                state.childCalls[#state.childCalls + 1] = {
                    context = context,
                    arguments = { ... },
                }
            end
        end

        if path == "/dickos/bin/fail.lua" then
            return function()
                state.childCalls[#state.childCalls + 1] = { failed = true }
                error(options.childError or "simulated child failure", 0)
            end
        end

        if path == "/dickos/bin/whoami.lua" then
            return hostLoadfile("src/dickos/bin/whoami.lua", "t", environment)
        end

        if path == "/dickos/bin/id.lua" then
            return hostLoadfile("src/dickos/bin/id.lua", "t", environment)
        end

        if path == "/dickos/bin/touch.lua" then
            return hostLoadfile("src/dickos/bin/touch.lua", "t", environment)
        end

        if path == GUARD_PATH then
            return hostLoadfile("src/dickos/lib/fs_guard.lua", "t", environment)
        end

        if path == "/dickos/home/nano/script.lua" then
            return function()
                state.childCalls[#state.childCalls + 1] = { userScript = true }
            end
        end

        return nil, "unexpected load path: " .. tostring(path)
    end

    local shellProgram = assert(hostLoadfile(SHELL_SOURCE, "t", environment))
    local succeeded, result = pcall(shellProgram, {
        runtimeApiVersion = 1,
        bootID = "B-1234ABCD",
        version = "0.1.0-unstable",
        hostname = "test-01",
        machineID = "DCK-C-11-A91F",
        user = "nano",
        uid = 1000,
        home = "/dickos/home/nano",
        isAdmin = options.isAdmin ~= false,
        shellHistoryLimit = 64,
    })

    assert(succeeded, tostring(result))
    assert(result == "logout")
    state.outputText = table.concat(state.output, "\n")
    return state
end

local identityState = runScenario({
    lines = {
        "probe normal",
        "sudo probe elevated argument",
        "sudo whoami",
        "id",
        "logout",
    },
    passwords = { "correct password" },
})
assert(identityState.authCalls == 1)
assert(identityState.passwordReads == 1)
assert(#identityState.childCalls == 2)
local normalContext = identityState.childCalls[1].context
assert(normalContext.user == "nano" and normalContext.uid == 1000)
assert(normalContext.effectiveUser == "nano")
assert(normalContext.effectiveUID == 1000)
assert(normalContext.isAdmin and not normalContext.isElevated)
local elevatedContext = identityState.childCalls[2].context
assert(elevatedContext.user == "nano" and elevatedContext.uid == 1000)
assert(elevatedContext.effectiveUser == "root")
assert(elevatedContext.effectiveUID == 0)
assert(elevatedContext.isAdmin and elevatedContext.isElevated)
assert(elevatedContext.home == "/dickos/home/nano")
assert(elevatedContext.cwd == "/dickos/home/nano")
assert(elevatedContext.password == nil and elevatedContext.auth == nil)
assert(elevatedContext.sudoCache == nil and elevatedContext.verifier == nil)
assert(elevatedContext.arguments == nil)
assert(identityState.childCalls[2].arguments[1] == "elevated")
assert(identityState.childCalls[2].arguments[2] == "argument")
assert(contains(identityState.outputText, "root"))
assert(contains(identityState.outputText, "uid=1000(nano) groups=admin"))
assert(not contains(identityState.outputText, "root@"))

local nonAdminState = runScenario({
    isAdmin = false,
    lines = { "sudo probe", "logout" },
    passwords = {},
})
assert(nonAdminState.authCalls == 0)
assert(nonAdminState.passwordReads == 0)
assert(#nonAdminState.childCalls == 0)
assert(contains(nonAdminState.outputText, "not an administrator"))

local deniedState = runScenario({
    lines = { "sudo probe", "sudo probe", "logout" },
    passwords = { "wrong password", "correct password" },
})
assert(deniedState.authCalls == 2)
assert(#deniedState.childCalls == 1)
assert(contains(deniedState.outputText, "authentication failed"))

local cacheState = runScenario({
    lines = {
        { line = "sudo probe first", clock = 0 },
        { line = "sudo probe cached", clock = 100 },
        { line = "sudo probe expired", clock = 121 },
        "logout",
    },
    passwords = { "correct password", "correct password" },
})
assert(cacheState.authCalls == 2)
assert(#cacheState.childCalls == 3)

local cachedCriticalState = runScenario({
    lines = {
        "sudo probe establish-cache",
        "sudo touch /startup",
        "logout",
    },
    passwords = { "correct password" },
    confirmations = { "/startup" },
})
assert(cachedCriticalState.authCalls == 1)
assert(cachedCriticalState.passwordReads == 1)
assert(cachedCriticalState.confirmationReads == 1)
assert(cachedCriticalState.files["/startup"] == "")
local sawCriticalConfirmation = false
for _, record in ipairs(cachedCriticalState.logs) do
    if record.target == "system" and
        record.message == "Critical mutation confirmed: touch /startup" then
        sawCriticalConfirmation = true
    end
end
assert(sawCriticalConfirmation)

local validationState = runScenario({
    lines = { "sudo probe", "sudo -v", "logout" },
    passwords = { "correct password", "correct password" },
})
assert(validationState.authCalls == 2)
assert(#validationState.childCalls == 1)

local cancelledValidationState = runScenario({
    lines = {
        "sudo probe first",
        "sudo -v",
        "sudo probe after-cancel",
        "logout",
    },
    passwords = {
        "correct password",
        { error = "Terminated" },
        "correct password",
    },
})
assert(cancelledValidationState.authCalls == 2)
assert(cancelledValidationState.passwordReads == 3)
assert(#cancelledValidationState.childCalls == 2)

local invalidationState = runScenario({
    lines = { "sudo probe", "sudo -k", "sudo probe", "logout" },
    passwords = { "correct password", "correct password" },
})
assert(invalidationState.authCalls == 2)
assert(#invalidationState.childCalls == 2)
local sawCacheInvalidation = false
for _, record in ipairs(invalidationState.logs) do
    if record.target == "auth" and
        contains(record.message, "cache invalidated") then
        sawCacheInvalidation = true
    end
end
assert(sawCacheInvalidation)

local rejectedTargetsState = runScenario({
    lines = {
        "sudo cd /",
        "sudo sudo probe",
        "sudo ./script.lua",
        "sudo /dickos/bin/probe.lua",
        "logout",
    },
    passwords = {},
})
assert(rejectedTargetsState.authCalls == 0)
assert(rejectedTargetsState.passwordReads == 0)
assert(#rejectedTargetsState.childCalls == 0)
assert(contains(rejectedTargetsState.outputText, "nested sudo"))
assert(contains(rejectedTargetsState.outputText, "explicit program paths"))

local readCancelledState = runScenario({
    lines = { "sudo probe", "sudo probe", "logout" },
    passwords = { { error = "Terminated" }, "correct password" },
})
assert(readCancelledState.authCalls == 1)
assert(readCancelledState.passwordReads == 2)
assert(#readCancelledState.childCalls == 1)
assert(contains(readCancelledState.outputText, "sudo: cancelled."))

local kdfAttempts = 0
local kdfCancelledState = runScenario({
    lines = { "sudo probe", "sudo probe", "logout" },
    passwords = { "private password", "correct password" },
    authenticate = function()
        kdfAttempts = kdfAttempts + 1

        if kdfAttempts == 1 then
            error("Terminated", 0)
        end

        return {
            name = "nano",
            uid = 1000,
            home = "/dickos/home/nano",
            admin = true,
        }
    end,
})
assert(kdfCancelledState.authCalls == 2)
assert(kdfCancelledState.passwordReads == 2)
assert(#kdfCancelledState.childCalls == 1)
assert(contains(kdfCancelledState.outputText, "sudo: cancelled."))
for _, cancelledState in ipairs({ readCancelledState, kdfCancelledState }) do
    for _, record in ipairs(cancelledState.logs) do
        assert(not contains(record.message, "denied"))
    end
end

local backendState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = {},
    authUnavailable = true,
})
assert(#backendState.childCalls == 0)
assert(contains(backendState.outputText, "authentication unavailable"))

local stateFailureState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = { "private password" },
    authenticate = function()
        return nil, "state", "simulated invalid users.db"
    end,
})
assert(#stateFailureState.childCalls == 0)
assert(contains(stateFailureState.outputText, "authentication unavailable"))

local runtimeFailureState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = { "private password" },
    authenticate = function()
        error("simulated auth runtime failure containing private password", 0)
    end,
})
assert(#runtimeFailureState.childCalls == 0)
assert(contains(runtimeFailureState.outputText, "authentication unavailable"))
for _, record in ipairs(runtimeFailureState.logs) do
    assert(not contains(record.message, "private password"))
end

local malformedIdentityState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = { "private password" },
    authenticate = function()
        return 42, nil, nil
    end,
})
assert(#malformedIdentityState.childCalls == 0)
assert(contains(malformedIdentityState.outputText, "authentication unavailable"))

local childFailureState = runScenario({
    lines = { "sudo fail", "logout" },
    passwords = { "correct password" },
})
assert(#childFailureState.childCalls == 1)
assert(contains(childFailureState.outputText, "Command failed:"))
assert(contains(childFailureState.outputText, "simulated child failure"))

local childTerminationState = runScenario({
    lines = { "sudo fail", "logout" },
    passwords = { "correct password" },
    childError = "Terminated",
})
assert(#childTerminationState.childCalls == 1)
assert(contains(childTerminationState.outputText, "Command terminated."))

local helpState = runScenario({
    lines = { "help sudo", "sudo --help", "sudo", "logout" },
    passwords = {},
})
assert(helpState.authCalls == 0)
assert(contains(helpState.outputText, "sudo -v"))
assert(contains(helpState.outputText, "Usage: sudo"))

local firstSessionState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = { "correct password" },
})
local secondSessionState = runScenario({
    lines = { "sudo probe", "logout" },
    passwords = { "correct password" },
})
assert(firstSessionState.authCalls == 1)
assert(secondSessionState.authCalls == 1)

-- Passwords are read only through masked input and never join shell history,
-- logs, command arguments, or user-visible diagnostics.
for _, state in ipairs({
    identityState,
    deniedState,
    cacheState,
    validationState,
    invalidationState,
    kdfCancelledState,
}) do
    local logText = ""
    for _, record in ipairs(state.logs) do
        logText = logText .. record.message .. "\n"
        assert(not contains(record.message, "correct password"))
        assert(not contains(record.message, "wrong password"))
        assert(not contains(record.message, "private password"))
    end
    assert(not contains(state.outputText, "correct password"))
    assert(not contains(logText, "private password"))

    for _, history in ipairs(state.histories) do
        local historyText = table.concat(history, "\n")
        assert(not contains(historyText, "correct password"))
        assert(not contains(historyText, "wrong password"))
        assert(not contains(historyText, "private password"))
    end
end

local sawElevatedStart = false
local sawAuthGrant = false
for _, record in ipairs(identityState.logs) do
    if record.target == "system" and
        record.message == "Elevated command started: probe" then
        sawElevatedStart = true
    end
    if record.target == "auth" and contains(record.message, "granted") then
        sawAuthGrant = true
    end
end
assert(sawElevatedStart and sawAuthGrant)

io.stdout:write("sudo tests: PASS\n")
