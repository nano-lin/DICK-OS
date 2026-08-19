-- DICK/OS current-user password command
-- Version: 0.1.0-unstable

local AUTH_LIBRARY_PATH = "/dickos/lib/auth.lua"
local PASSWORD_LIBRARY_PATH = "/dickos/lib/password.lua"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"

local context, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: passwd")
    print("Changes the current user's password using masked prompts.")
    return
end

if type(context) ~= "table" or type(context.user) ~= "string" or
    type(context.machineID) ~= "string" then
    error("passwd requires authenticated DICK command context.", 0)
end

if firstArgument ~= nil then
    error("Usage: passwd", 0)
end

local function requireModule(path, functionNames)
    local program, loadError = loadfile(path)

    if type(program) ~= "function" then
        error("passwd cannot load " .. path .. ": " .. tostring(loadError), 0)
    end

    local module = program()

    if type(module) ~= "table" then
        error("passwd received an invalid module from " .. path .. ".", 0)
    end

    for _, functionName in ipairs(functionNames) do
        if type(module[functionName]) ~= "function" then
            error("passwd dependency is missing " .. functionName .. ".", 0)
        end
    end

    return module
end

local auth = requireModule(AUTH_LIBRARY_PATH, { "changePassword" })
local password = requireModule(PASSWORD_LIBRARY_PATH, { "validatePassword" })

local function createAuthLogger()
    local succeeded, logger = pcall(function()
        local program = assert(loadfile(LOG_LIBRARY_PATH))
        local module = program()

        return module.create("auth", context)
    end)

    return succeeded and type(logger) == "table" and logger or nil
end

local authLogger = createAuthLogger()

local function logBestEffort(level, message)
    if authLogger == nil then
        return
    end

    pcall(function()
        local method = authLogger[level]

        if type(method) == "function" then
            method("passwd", message)
        end
    end)
end

-- Do not wrap these reads in pcall. Ctrl+T must become the existing shell's
-- ordinary child-command termination, which returns to this authenticated
-- session without writing users.db.
write("Current password: ")
local currentPassword = read("*")
write("New password: ")
local newPassword = read("*")
write("Retype new password: ")
local confirmation = read("*")

if newPassword ~= confirmation then
    currentPassword = nil
    newPassword = nil
    confirmation = nil
    print("Passwords do not match.")
    return
end

confirmation = nil

local passwordIsValid, validationError = password.validatePassword(newPassword)

if not passwordIsValid then
    currentPassword = nil
    newPassword = nil
    print(validationError)
    return
end

local changed, resultKind, detail = auth.changePassword(
    context.user,
    currentPassword,
    newPassword,
    context.machineID
)

-- Lua strings cannot be securely overwritten. Clearing references only keeps
-- their useful lifetime short and must not be mistaken for guaranteed memory
-- erasure in a garbage-collected VM.
currentPassword = nil
newPassword = nil

if changed then
    logBestEffort("info", "Password changed for " .. context.user)
    print("Password changed.")
    return
end

if resultKind == "denied" then
    logBestEffort("warn", "Password change rejected for " .. context.user)
    print("Current password is incorrect.")
    return
end

if resultKind == "policy" then
    print(tostring(detail))
    return
end

if resultKind == "write" then
    logBestEffort("error", "Password database write failed")
    error("passwd: unable to update password database: " .. tostring(detail), 0)
end

logBestEffort("error", "Password authentication state failure")
error("passwd: authentication state failure: " .. tostring(detail), 0)
