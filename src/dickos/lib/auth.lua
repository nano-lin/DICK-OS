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
-- external `denied` result. Database/dependency/verifier failures use `state`
-- so init/login can treat broken security state as a core boot failure without
-- revealing account-existence details at the login screen.
function auth.authenticate(username, plainPassword)
    local database, loadError = users.load()

    if database == nil then
        return nil, "state", loadError
    end

    local record, lookupError = users.getByName(database, username, true)

    if lookupError ~= nil then
        return nil, "state", lookupError
    end

    if record == nil or record.loginDisabled or record.verifier == nil then
        return nil, "denied", nil
    end

    local matches, verifyError = password.verify(plainPassword, record.verifier)

    if verifyError ~= nil then
        return nil, "state", verifyError
    end

    if not matches then
        return nil, "denied", nil
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

    local currentMatches, verifyError = password.verify(
        currentPassword,
        record.verifier
    )

    if verifyError ~= nil then
        return false, "state", verifyError
    end

    if not currentMatches then
        return false, "denied", nil
    end

    local newPasswordIsValid, validationError =
        password.validatePassword(newPassword)

    if not newPasswordIsValid then
        return false, "policy", validationError
    end

    local saltContext = tostring(context or "") .. ":" .. username
    local verifier, verifierError = password.createVerifier(
        newPassword,
        saltContext
    )

    if verifier == nil then
        return false, "state", verifierError
    end

    local replacement, replacementError = users.replacePassword(
        database,
        username,
        verifier
    )

    if replacement == nil then
        return false, "state", replacementError
    end

    local written, writeError = users.write(replacement)

    if not written then
        return false, "write", writeError
    end

    return true, nil, nil
end

return auth
