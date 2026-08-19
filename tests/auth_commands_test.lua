-- Host-side tests for authenticated identity and passwd commands
-- Run with: lua tests/auth_commands_test.lua

local hostLoadfile = loadfile
local AUTH_PATH = "/dickos/lib/auth.lua"
local PASSWORD_PATH = "/dickos/lib/password.lua"
local LOG_PATH = "/dickos/lib/log.lua"

local context = {
    user = "nano",
    uid = 1000,
    effectiveUser = "nano",
    effectiveUID = 1000,
    isAdmin = true,
    isElevated = false,
    machineID = "DCK-C-11-A91F",
    bootID = "B-1234ABCD",
}

local function runSimpleCommand(path, ...)
    local output = {}
    local environment = {
        print = function(text) output[#output + 1] = tostring(text) end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    local program = assert(hostLoadfile(path, "t", environment))
    local succeeded, result = pcall(program, ...)

    return succeeded, result, output
end

local whoSucceeded, _, whoOutput = runSimpleCommand(
    "src/dickos/bin/whoami.lua",
    context
)
assert(whoSucceeded)
assert(whoOutput[1] == "nano")
local whoHelpSucceeded, _, whoHelp = runSimpleCommand(
    "src/dickos/bin/whoami.lua",
    context,
    "--help"
)
assert(whoHelpSucceeded and whoHelp[1] == "Usage: whoami")
local whoExtraSucceeded, whoExtraError = runSimpleCommand(
    "src/dickos/bin/whoami.lua",
    context,
    "extra"
)
assert(not whoExtraSucceeded and tostring(whoExtraError) == "Usage: whoami")

local idSucceeded, _, idOutput = runSimpleCommand(
    "src/dickos/bin/id.lua",
    context
)
assert(idSucceeded)
assert(idOutput[1] == "uid=1000(nano) groups=admin")
assert(string.find(idOutput[1], "DCK-", 1, true) == nil)

local elevatedContext = {}
for key, value in pairs(context) do elevatedContext[key] = value end
elevatedContext.effectiveUser = "root"
elevatedContext.effectiveUID = 0
elevatedContext.isElevated = true

local elevatedWhoSucceeded, _, elevatedWhoOutput = runSimpleCommand(
    "src/dickos/bin/whoami.lua",
    elevatedContext
)
assert(elevatedWhoSucceeded and elevatedWhoOutput[1] == "root")
local elevatedIDSuccess, _, elevatedIDOutput = runSimpleCommand(
    "src/dickos/bin/id.lua",
    elevatedContext
)
assert(elevatedIDSuccess)
assert(elevatedIDOutput[1] ==
    "uid=1000(nano) euid=0(root) groups=admin")
local idHelpSucceeded, _, idHelp = runSimpleCommand(
    "src/dickos/bin/id.lua",
    context,
    "--help"
)
assert(idHelpSucceeded and idHelp[1] == "Usage: id")
local idExtraSucceeded, idExtraError = runSimpleCommand(
    "src/dickos/bin/id.lua",
    context,
    "extra"
)
assert(not idExtraSucceeded and tostring(idExtraError) == "Usage: id")

local passwdHelpSucceeded, _, passwdHelp = runSimpleCommand(
    "src/dickos/bin/passwd.lua",
    context,
    "--help"
)
assert(passwdHelpSucceeded and passwdHelp[1] == "Usage: passwd")
local passwdArgumentSucceeded, passwdArgumentError = runSimpleCommand(
    "src/dickos/bin/passwd.lua",
    context,
    "must-not-be-a-password"
)
assert(not passwdArgumentSucceeded)
assert(tostring(passwdArgumentError) == "Usage: passwd")

local function runPasswd(inputs, changePassword)
    local state = {
        inputIndex = 0,
        masks = {},
        output = {},
        changeCalls = 0,
        logs = {},
    }
    local environment = {
        write = function(text)
            state.output[#state.output + 1] = tostring(text)
        end,
        print = function(text)
            state.output[#state.output + 1] = tostring(text)
        end,
    }

    environment.read = function(replacement)
        state.masks[#state.masks + 1] = replacement
        state.inputIndex = state.inputIndex + 1
        local value = assert(inputs[state.inputIndex], "unexpected passwd read")

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
                return {
                    changePassword = function(...)
                        state.changeCalls = state.changeCalls + 1
                        return changePassword(...)
                    end,
                }
            end
        end

        if path == PASSWORD_PATH then
            return function()
                return {
                    validatePassword = function(value)
                        if #value < 8 then
                            return false, "Password must contain at least 8 bytes."
                        end

                        return true
                    end,
                }
            end
        end

        if path == LOG_PATH then
            return function()
                return {
                    create = function()
                        local logger = {}

                        for _, level in ipairs({ "info", "warn", "error" }) do
                            logger[level] = function(_, message)
                                state.logs[#state.logs + 1] = message
                            end
                        end

                        return logger
                    end,
                }
            end
        end

        return nil, "unexpected path"
    end

    local program = assert(hostLoadfile(
        "src/dickos/bin/passwd.lua",
        "t",
        environment
    ))
    local succeeded, result = pcall(program, context)
    state.outputText = table.concat(state.output, "\n")

    return state, succeeded, result
end

local mismatchState, mismatchSucceeded = runPasswd({
    "current password", "new password", "different pass",
}, function() error("changePassword must not run", 0) end)
assert(mismatchSucceeded)
assert(mismatchState.changeCalls == 0)
assert(string.find(mismatchState.outputText, "do not match", 1, true))

local deniedState, deniedSucceeded = runPasswd({
    "wrong password", "new password", "new password",
}, function()
    return false, "denied", nil
end)
assert(deniedSucceeded)
assert(deniedState.changeCalls == 1)
assert(string.find(deniedState.outputText, "incorrect", 1, true))
assert(string.find(
    table.concat(deniedState.logs, "\n"),
    "Current password rejected",
    1,
    true
))

local policyState, policySucceeded = runPasswd({
    "current password", "short", "short",
}, function() error("changePassword must not run", 0) end)
assert(policySucceeded)
assert(policyState.changeCalls == 0)
assert(string.find(policyState.outputText, "at least 8 bytes", 1, true))
assert(string.find(
    table.concat(policyState.logs, "\n"),
    "Password policy rejected",
    1,
    true
))

local successState, successSucceeded = runPasswd({
    "current password", "new password", "new password",
}, function(username, current, replacement, saltContext)
    assert(username == "nano")
    assert(current == "current password")
    assert(replacement == "new password")
    assert(saltContext == context.machineID)
    return true
end)
assert(successSucceeded)
assert(successState.changeCalls == 1)
assert(string.find(successState.outputText, "Password changed.", 1, true))

for _, logMessage in ipairs(successState.logs) do
    assert(not string.find(logMessage, "current password", 1, true))
    assert(not string.find(logMessage, "new password", 1, true))
end

for _, replacement in ipairs(successState.masks) do
    assert(replacement == "*")
end

local terminatedState, terminatedSucceeded, terminatedError = runPasswd({
    { error = "Terminated" },
}, function() error("changePassword must not run", 0) end)
assert(not terminatedSucceeded)
assert(tostring(terminatedError) == "Terminated")
assert(terminatedState.changeCalls == 0)

-- A Ctrl+T propagated by auth during PBKDF2 remains the shell-recognised
-- termination value. passwd must not turn it into a technical failure log.
local kdfTerminatedState, kdfTerminatedSucceeded, kdfTerminatedError =
    runPasswd({
        "current password", "new password", "new password",
    }, function()
        error("Terminated", 0)
    end)
assert(not kdfTerminatedSucceeded)
assert(tostring(kdfTerminatedError) == "Terminated")
assert(kdfTerminatedState.changeCalls == 1)
assert(#kdfTerminatedState.logs == 0)

local verifierFailureState, verifierFailureSucceeded, verifierFailureError =
    runPasswd({
        "current password", "new password", "new password",
    }, function()
        return false, "backend", "verifier_generation_failed"
    end)
assert(not verifierFailureSucceeded)
assert(string.find(
    tostring(verifierFailureError),
    "password backend failure",
    1,
    true
))
assert(string.find(
    table.concat(verifierFailureState.logs, "\n"),
    "Password verifier generation failed",
    1,
    true
))

local writeFailureState, writeFailureSucceeded = runPasswd({
    "current password", "new password", "new password",
}, function()
    return false, "write", "simulated write failure"
end)
assert(not writeFailureSucceeded)
assert(string.find(
    table.concat(writeFailureState.logs, "\n"),
    "Password database write failed",
    1,
    true
))

local stateFailureState, stateFailureSucceeded = runPasswd({
    "current password", "new password", "new password",
}, function()
    return false, "state", "simulated invalid database"
end)
assert(not stateFailureSucceeded)
assert(string.find(
    table.concat(stateFailureState.logs, "\n"),
    "Authentication state invalid",
    1,
    true
))

-- passwd catches unexpected backend exceptions only to emit a safe phase
-- record. Raw exception text is excluded because a future backend might copy
-- credentials into it.
local crashState, crashSucceeded, crashError = runPasswd({
    "current password", "new password", "new password",
}, function()
    error("backend copied current password into an error", 0)
end)
assert(not crashSucceeded)
assert(string.find(
    tostring(crashError),
    "authentication backend runtime failure",
    1,
    true
))
local crashLogs = table.concat(crashState.logs, "\n")
assert(string.find(
    crashLogs,
    "Unexpected password backend runtime failure",
    1,
    true
))
assert(not string.find(crashLogs, "current password", 1, true))
assert(not string.find(crashLogs, "new password", 1, true))

io.stdout:write("auth command tests: PASS\n")
