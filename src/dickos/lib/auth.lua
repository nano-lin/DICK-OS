-- DICK/OS authentication policy
-- Version: 0.1.0-unstable

local USERS_LIBRARY_PATH = "/dickos/lib/users.lua"
local PASSWORD_LIBRARY_PATH = "/dickos/lib/password.lua"

local function requireModule(path, requiredFunctions)
    local program, loadError = loadfile(path)

    if type(program) ~= "function" then
        error("Unable to load authentication dependency " .. path .. ": " ..
            tostring(loadError), 0)
    end

    local module = program()

    if type(module) ~= "table" then
        error("Authentication dependency returned no module: " .. path, 0)
    end

    for _, functionName in ipairs(requiredFunctions) do
        if type(module[functionName]) ~= "function" then
            error("Authentication dependency " .. path .. " is missing " ..
                functionName .. ".", 0)
        end
    end

    return module
end

local users = requireModule(USERS_LIBRARY_PATH, {
    "load",
    "getByName",
    "replacePassword",
    "write",
})
local password = requireModule(PASSWORD_LIBRARY_PATH, {
    "createVerifier",
    "verify",
    "validatePassword",
})

local auth = {}

-- CC:T reports Ctrl+T from interruptible APIs as a `Terminated` error. Some
-- runtime versions preserve errors in a table with a readable `message`
-- field, while ordinary Lua commonly uses a string. Authentication may catch
-- backend crashes to classify them, but it must immediately re-raise this one
-- control-flow error so login or the protected DICK shell keeps ownership.
local function isTerminationError(errorValue)
    local message = errorValue

    if type(errorValue) == "table" and
        type(errorValue.message) == "string" then
        message = errorValue.message
    end

    message = tostring(message)
    return message == "Terminated" or
        string.match(message, ": Terminated$") ~= nil
end

-- Run one password-backend operation behind a narrow failure boundary. Lua's
-- `pcall` returns a boolean followed by the called function's normal multiple
-- return values. Unexpected backend errors become a safe phase code which
-- trusted callers may log without copying a password, salt, or digest. Ctrl+T
-- remains exceptional and is deliberately re-raised unchanged.
local function callPasswordBackend(operation, ...)
    local callSucceeded, firstResult, secondResult = pcall(operation, ...)

    if not callSucceeded then
        if isTerminationError(firstResult) then
            error(firstResult, 0)
        end

        return false, nil, nil
    end

    return true, firstResult, secondResult
end

-- Loading is deliberately repeated for authentication and password changes.
-- users.db is small, and reading current on-disk state avoids hidden mutable
-- module state or silently continuing after an administrator repairs/replaces
-- the database from Recovery.
function auth.validateState()
    local database, loadError = users.load()

    if database == nil then
        return false, loadError
    end

    return true, nil
end

-- Unknown users, wrong passwords, and direct-login-disabled accounts share the
-- external `denied` result. Its third value is a trusted, secret-free category
-- for auth.log; login still renders one generic credential message. Database,
-- dependency, verifier, and backend failures use non-denial kinds so broken
-- security state is never presented as an incorrect current password.
function auth.authenticate(username, plainPassword)
    local database, loadError = users.load()

    if database == nil then
        return nil, "state", loadError
    end

    local record, lookupError = users.getByName(database, username, true)

    if lookupError ~= nil then
        return nil, "state", lookupError
    end

    if record == nil then
        return nil, "denied", "unknown_user"
    end

    if record.loginDisabled then
        return nil, "denied", "direct_login_disabled"
    end

    if record.verifier == nil then
        return nil, "state", "Enabled account has no password verifier."
    end

    local backendSucceeded, matches, verifyError = callPasswordBackend(
        password.verify,
        plainPassword,
        record.verifier
    )

    if not backendSucceeded then
        return nil, "backend", "login_password_verification_failed"
    end

    if type(matches) ~= "boolean" then
        return nil, "backend", "login_password_verification_failed"
    end

    if verifyError ~= nil then
        return nil, "state", verifyError
    end

    if not matches then
        return nil, "denied", "incorrect_password"
    end

    -- The returned session identity deliberately excludes verifier material.
    -- Shell and commands need identity/role fields, not password database data.
    return {
        name = record.name,
        uid = record.uid,
        home = record.home,
        admin = record.admin,
    }, nil, nil
end

function auth.changePassword(username, currentPassword, newPassword, context)
    local database, loadError = users.load()

    if database == nil then
        return false, "state", loadError
    end

    local record, lookupError = users.getByName(database, username, true)

    if lookupError ~= nil then
        return false, "state", lookupError
    end

    if record == nil or record.loginDisabled or record.verifier == nil then
        return false, "denied", nil
    end

    local backendSucceeded, currentMatches, verifyError = callPasswordBackend(
        password.verify,
        currentPassword,
        record.verifier
    )

    if not backendSucceeded then
        return false, "backend", "current_password_verification_failed"
    end

    if type(currentMatches) ~= "boolean" then
        return false, "backend", "current_password_verification_failed"
    end

    if verifyError ~= nil then
        return false, "state", verifyError
    end

    if not currentMatches then
        return false, "denied", nil
    end

    local policyBackendSucceeded, newPasswordIsValid, validationError =
        callPasswordBackend(password.validatePassword, newPassword)

    if not policyBackendSucceeded then
        return false, "backend", "password_policy_evaluation_failed"
    end

    if type(newPasswordIsValid) ~= "boolean" then
        return false, "backend", "password_policy_evaluation_failed"
    end

    if not newPasswordIsValid then
        return false, "policy", validationError
    end

    local saltContext = tostring(context or "") .. ":" .. username
    local verifierBackendSucceeded, verifier =
        callPasswordBackend(
            password.createVerifier,
            newPassword,
            saltContext
        )

    if not verifierBackendSucceeded then
        return false, "backend", "verifier_generation_failed"
    end

    if verifier == nil then
        -- Do not forward a backend-provided string: a future replacement
        -- backend might include sensitive input in its diagnostics. The phase
        -- code is sufficient for passwd's trusted, secret-free auth.log entry.
        return false, "backend", "verifier_generation_failed"
    end

    local replacement, replacementError = users.replacePassword(
        database,
        username,
        verifier
    )

    if replacement == nil then
        return false, "state", replacementError
    end

    -- The config/users transaction normally reports false plus a diagnostic,
    -- but a damaged dependency may raise instead. Keep that exception inside
    -- the users.db write phase and return only a fixed safe code; a raw error
    -- could contain data supplied by a future backend.
    local writeCallSucceeded, written, writeError = pcall(
        users.write,
        replacement
    )

    if not writeCallSucceeded then
        if isTerminationError(written) then
            error(written, 0)
        end

        return false, "write", "users_database_write_runtime_failed"
    end

    if not written then
        return false, "write", writeError
    end

    return true, nil, nil
end

return auth
