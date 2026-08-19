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
    "nobody", "wrong password",
    "root", "wrong password",
    "nano", "correct password",
}, function(username, plainPassword)
    attempts = attempts + 1

    if username == "nano" and plainPassword == "correct password" then
        return {
            name = "nano",
            uid = 1000,
            home = "/dickos/home/nano",
            admin = true,
        }
    end

    return nil, "denied", nil
end)
assert(rejectedSucceeded)
assert(rejectedUser.name == "nano")
assert(rejectedUser.verifier == nil)
assert(attempts == 3)
assert(rejectedState.maskedReads == 3)
assert(contains(rejectedState.outputText, "Login incorrect."))
assert(contains(table.concat(rejectedState.logs, "\n"), "Login rejected"))

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

local stateFailure, stateSucceeded, stateError = runScenario({
    "nano", "correct password",
}, function()
    return nil, "state", "malformed users.db"
end)
assert(not stateSucceeded)
assert(contains(stateError, "Authentication state failure"))
assert(not contains(stateError, "correct password"))

io.stdout:write("login tests: PASS\n")
