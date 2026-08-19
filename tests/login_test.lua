-- Host-side tests for the native DICK/OS login UI
-- Run with: lua tests/login_test.lua

local LOGIN_SOURCE = "src/dickos/system/login.lua"
local AUTH_PATH = "/dickos/lib/auth.lua"
local LOG_PATH = "/dickos/lib/log.lua"
local hostLoadfile = loadfile

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local colorsMock = {
    black = 1,
    white = 2,
    lightBlue = 3,
    lightGray = 4,
    red = 5,
}

local function runScenario(inputs, authenticate)
    local state = {
        inputIndex = 0,
        maskedReads = 0,
        output = {},
        logs = {},
    }
    local environment = {
        colors = colorsMock,
        sleep = function() end,
    }

    environment.term = {
        setBackgroundColor = function() end,
        setTextColor = function() end,
        setCursorBlink = function() end,
        clear = function() end,
        setCursorPos = function() end,
        getSize = function() return 51, 19 end,
        write = function(text)
            state.output[#state.output + 1] = tostring(text)
        end,
    }

    environment.read = function(replacement)
        state.inputIndex = state.inputIndex + 1
        local value = assert(inputs[state.inputIndex], "unexpected login read")

        if replacement == "*" then
            state.maskedReads = state.maskedReads + 1
        end

        if type(value) == "table" and value.error ~= nil then
            error(value.error, 0)
        end

        return value
    end

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        if path == AUTH_PATH then
            return function()
                return { authenticate = authenticate }
            end
        end

        if path == LOG_PATH then
            return function()
                return {
                    create = function()
                        return {
                            info = function(_, message)
                                state.logs[#state.logs + 1] = "INFO:" .. message
                            end,
                            warn = function(_, message)
                                state.logs[#state.logs + 1] = "WARN:" .. message
                            end,
                            error = function(_, message)
                                state.logs[#state.logs + 1] = "ERROR:" .. message
                            end,
                        }
                    end,
                }
            end
        end

        return nil, "unexpected path"
    end

    local loginProgram = assert(hostLoadfile(LOGIN_SOURCE, "t", environment))
    local succeeded, result = pcall(loginProgram, {
        hostname = "test-01",
        bootID = "B-1234ABCD",
    })

    state.outputText = table.concat(state.output, "\n")
    return state, succeeded, result
end

local attempts = 0
local rejectedState, rejectedSucceeded, rejectedUser = runScenario({
    "nobody", "unknown credential input",
    "root", "disabled credential input",
    "nano", "bad credential input",
    "nano", "accepted credential input",
}, function(username, plainPassword)
    attempts = attempts + 1

    if username == "nano" and plainPassword == "accepted credential input" then
        return {
            name = "nano",
            uid = 1000,
            home = "/dickos/home/nano",
            admin = true,
        }
    end

    if username == "nobody" then
        return nil, "denied", "unknown_user"
    end

    if username == "root" then
        return nil, "denied", "direct_login_disabled"
    end

    return nil, "denied", "incorrect_password"
end)
assert(rejectedSucceeded)
assert(rejectedUser.name == "nano")
assert(rejectedUser.verifier == nil)
assert(attempts == 4)
assert(rejectedState.maskedReads == 4)
assert(contains(
    rejectedState.outputText,
    "Incorrect username or password."
))
assert(not contains(rejectedState.outputText, "Login incorrect."))
local _, genericNoticeCount = string.gsub(
    rejectedState.outputText,
    "Incorrect username or password%.",
    ""
)
assert(genericNoticeCount == 3)
local rejectionLogs = table.concat(rejectedState.logs, "\n")
assert(contains(rejectionLogs, "Login rejected: unknown user"))
assert(contains(rejectionLogs, "Login rejected: incorrect password"))
assert(contains(rejectionLogs, "Login rejected: direct login disabled"))
assert(not contains(rejectionLogs, "unknown credential input"))
assert(not contains(rejectionLogs, "disabled credential input"))
assert(not contains(rejectionLogs, "bad credential input"))
assert(not contains(rejectionLogs, "accepted credential input"))

local terminatedState, terminatedSucceeded, terminatedUser = runScenario({
    { error = "Terminated" },
    "nano",
    "correct password",
}, function()
    return {
        name = "nano",
        uid = 1000,
        home = "/dickos/home/nano",
        admin = true,
    }
end)
assert(terminatedSucceeded)
assert(terminatedUser.name == "nano")
assert(terminatedState.maskedReads == 1)

-- PBKDF2 now yields during authentication. A Ctrl+T propagated from that
-- phase redraws login and is not logged as a rejected credential attempt.
local authenticationCalls = 0
local kdfTerminatedState, kdfTerminatedSucceeded, kdfTerminatedUser =
    runScenario({
        "nano", "first password",
        "nano", "correct password",
    }, function()
        authenticationCalls = authenticationCalls + 1

        if authenticationCalls == 1 then
            error("Terminated", 0)
        end

        return {
            name = "nano",
            uid = 1000,
            home = "/dickos/home/nano",
            admin = true,
        }
    end)
assert(kdfTerminatedSucceeded)
assert(kdfTerminatedUser.name == "nano")
assert(kdfTerminatedState.maskedReads == 2)
assert(not contains(
    table.concat(kdfTerminatedState.logs, "\n"),
    "Login rejected"
))

local stateFailure, stateSucceeded, stateError = runScenario({
    "nano", "correct password",
}, function()
    return nil, "state", "malformed users.db"
end)
assert(not stateSucceeded)
assert(contains(stateError, "Authentication state failure"))
assert(not contains(stateError, "correct password"))

local backendFailure, backendSucceeded, backendError = runScenario({
    "nano", "private password",
}, function()
    error("backend diagnostic containing private password", 0)
end)
assert(not backendSucceeded)
assert(contains(backendError, "Authentication backend runtime failure"))
local backendLogs = table.concat(backendFailure.logs, "\n")
assert(contains(
    backendLogs,
    "Unexpected authentication backend runtime failure"
))
assert(not contains(backendLogs, "private password"))

local classifiedBackend, classifiedSucceeded, classifiedError = runScenario({
    "nano", "another private password",
}, function()
    return nil, "backend", "login_password_verification_failed"
end)
assert(not classifiedSucceeded)
assert(contains(classifiedError, "Authentication backend runtime failure"))
local classifiedLogs = table.concat(classifiedBackend.logs, "\n")
assert(contains(
    classifiedLogs,
    "Login password verification backend failed"
))
assert(not contains(classifiedLogs, "another private password"))

io.stdout:write("login tests: PASS\n")
