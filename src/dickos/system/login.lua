-- DICK/OS native login screen
-- Version: 0.1.0-unstable

local AUTH_LIBRARY_PATH = "/dickos/lib/auth.lua"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"

local context = ...

if type(context) ~= "table" or type(context.hostname) ~= "string" or
    type(context.bootID) ~= "string" then
    error("Login runtime context is missing.", 0)
end

local function describeError(value)
    if type(value) == "table" and type(value.message) == "string" then
        return value.message
    end

    return tostring(value)
end

local function isTerminationError(value)
    local message = describeError(value)

    return message == "Terminated" or string.match(message, ": Terminated$") ~= nil
end

local function requireAuthenticationCore()
    local program, loadError = loadfile(AUTH_LIBRARY_PATH)

    if type(program) ~= "function" then
        error("Unable to load authentication core: " .. tostring(loadError), 0)
    end

    local module = program()

    if type(module) ~= "table" or type(module.authenticate) ~= "function" then
        error("Authentication core returned an invalid module.", 0)
    end

    return module
end

local auth = requireAuthenticationCore()

-- Authentication logging is best effort. Its construction and every append
-- remain outside the policy decision: a full log cannot deny a valid login,
-- while a broken users.db still remains a fatal state error below.
local function createAuthLogger()
    local succeeded, logger = pcall(function()
        local program = assert(loadfile(LOG_LIBRARY_PATH))
        local module = program()

        return module.create("auth", context)
    end)

    if succeeded and type(logger) == "table" then
        return logger
    end

    return nil
end

local authLogger = createAuthLogger()

local function logBestEffort(level, message)
    if authLogger == nil then
        return
    end

    pcall(function()
        local method = authLogger[level]

        if type(method) == "function" then
            method("login", message)
        end
    end)
end

-- auth.authenticate returns a private rejection category for trusted logging.
-- This map contains no user input and no verifier data. Every category still
-- produces the same UI notice below, so the screen does not reveal whether an
-- account exists or permits direct login.
local REJECTION_LOG_MESSAGES = {
    unknown_user = "Login rejected: unknown user",
    incorrect_password = "Login rejected: incorrect password",
    direct_login_disabled = "Login rejected: direct login disabled",
}

-- Backend detail values are also fixed auth.lua codes, never exception text.
-- Mapping rather than concatenating them keeps auth.log diagnostic while a
-- future backend cannot smuggle credential material through this boundary.
local BACKEND_LOG_MESSAGES = {
    login_password_verification_failed =
        "Login password verification backend failed",
}

local function drawLogin(notice)
    local width = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(3, 2)
    term.setTextColor(colors.lightBlue)
    term.write("DICK/OS")
    term.setCursorPos(3, 3)
    term.setTextColor(colors.lightGray)
    term.write(string.sub("Host: " .. context.hostname, 1, width - 4))
    term.setCursorPos(3, 5)
    term.setTextColor(colors.white)
    term.write("AUTHENTICATION REQUIRED")

    if notice ~= nil then
        term.setCursorPos(3, 7)
        term.setTextColor(colors.red)
        term.write(string.sub(notice, 1, width - 4))
    end

    term.setTextColor(colors.white)
end

-- `read("*")` masks display only; the returned Lua string still contains the
-- plaintext password. Variables are set to nil as soon as practical. Lua uses
-- immutable garbage-collected strings, so this is lifetime hygiene and is not
-- claimed to securely wipe memory.
while true do
    drawLogin()
    term.setCursorPos(3, 9)
    term.write("Login: ")
    term.setCursorBlink(true)
    local usernameSucceeded, usernameOrError = pcall(read)

    if not usernameSucceeded then
        if not isTerminationError(usernameOrError) then
            error("Login input failed: " .. describeError(usernameOrError), 0)
        end
    else
        local username = tostring(usernameOrError)

        term.setCursorPos(3, 10)
        term.write("Password: ")
        local passwordSucceeded, passwordOrError = pcall(read, "*")

        if not passwordSucceeded then
            username = nil

            if not isTerminationError(passwordOrError) then
                error("Login input failed: " .. describeError(passwordOrError), 0)
            end
        else
            local plainPassword = tostring(passwordOrError)
            -- Authentication can now yield while PBKDF2 runs. Protecting this
            -- boundary lets Ctrl+T redraw login instead of escaping into init,
            -- while unexpected backend errors receive a secret-free auth.log
            -- record. `pcall` places the normal return values after its leading
            -- success boolean.
            local authSucceeded, user, resultKind, detail = pcall(
                auth.authenticate,
                username,
                plainPassword
            )

            plainPassword = nil
            passwordOrError = nil

            if not authSucceeded then
                username = nil

                if not isTerminationError(user) then
                    logBestEffort(
                        "error",
                        "Unexpected authentication backend runtime failure"
                    )
                    error("Authentication backend runtime failure.", 0)
                end
            elseif user ~= nil then
                logBestEffort(
                    "info",
                    "Login succeeded for " .. user.name ..
                        " uid=" .. tostring(user.uid)
                )
                term.setCursorBlink(false)
                return user
            elseif resultKind == "state" then
                logBestEffort("error", "Authentication state failure")
                error("Authentication state failure: " .. tostring(detail), 0)
            elseif resultKind == "backend" then
                logBestEffort(
                    "error",
                    BACKEND_LOG_MESSAGES[detail] or
                        "Authentication backend runtime failure"
                )
                error("Authentication backend runtime failure.", 0)
            elseif resultKind == "denied" then
                local rejectionMessage = REJECTION_LOG_MESSAGES[detail] or
                    "Login rejected: credential denial"

                logBestEffort("warn", rejectionMessage)
                username = nil
                drawLogin("Incorrect username or password.")
                local delaySucceeded, delayError = pcall(sleep, 0.5)

                if not delaySucceeded and not isTerminationError(delayError) then
                    error(
                        "Login delay failed: " .. describeError(delayError),
                        0
                    )
                end
            else
                logBestEffort(
                    "error",
                    "Authentication backend returned an invalid result"
                )
                error("Authentication backend returned an invalid result.", 0)
            end
        end
    end
end
