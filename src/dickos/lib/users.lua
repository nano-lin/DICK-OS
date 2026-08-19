-- DICK/OS user database semantics
-- Version: 0.1.0-unstable

local CONFIG_LIBRARY_PATH = "/dickos/lib/config.lua"
local PASSWORD_LIBRARY_PATH = "/dickos/lib/password.lua"
local USERS_DATABASE_PATH = "/dickos/etc/users.db"
local USERS_FORMAT_VERSION = 1
local FIRST_HUMAN_UID = 1000
local FIRST_AVAILABLE_UID = 1001
local MAXIMUM_USERNAME_BYTES = 16

-- A user database is security state, so its dependencies are loaded as core
-- modules rather than optional configuration. Compile/runtime/API failure is
-- raised to auth/init and ultimately reaches Stage-0 Recovery.
local function requireModule(path, requiredFunctions)
    local program, loadError = loadfile(path)

    if type(program) ~= "function" then
        error("Unable to load user database dependency " .. path .. ": " ..
            tostring(loadError), 0)
    end

    local module = program()

    if type(module) ~= "table" then
        error("User database dependency returned no module: " .. path, 0)
    end

    for _, functionName in ipairs(requiredFunctions) do
        if type(module[functionName]) ~= "function" then
            error("User database dependency " .. path .. " is missing " ..
                functionName .. ".", 0)
        end
    end

    return module
end

local config = requireModule(CONFIG_LIBRARY_PATH, {
    "parse",
    "readText",
    "serializeValues",
    "writeValues",
})
local password = requireModule(PASSWORD_LIBRARY_PATH, {
    "validateVerifier",
})

local users = {
    databasePath = USERS_DATABASE_PATH,
    formatVersion = USERS_FORMAT_VERSION,
    maximumUsernameBytes = MAXIMUM_USERNAME_BYTES,
}

local RESERVED_USERNAMES = {
    root = true,
    bootstrap = true,
}

-- The username grammar matches one config-v1 dotted-key segment exactly.
-- Names are never lowercased implicitly: callers receive a clear rejection so
-- an account's spelling cannot change between input, home path, and database.
function users.validateUsername(username, allowRoot)
    if type(username) ~= "string" then
        return false, "Username must be text."
    end

    if #username < 1 or #username > MAXIMUM_USERNAME_BYTES then
        return false, "Username must contain 1 to 16 bytes."
    end

    if string.match(username, "^[a-z][a-z0-9_]*$") == nil then
        return false,
            "Username must start with a lowercase letter and use only " ..
            "a-z, 0-9, or underscore."
    end

    if RESERVED_USERNAMES[username] and not (allowRoot and username == "root") then
        return false, "Username is reserved: " .. username
    end

    return true, nil
end

local function copyVerifier(verifier)
    return {
        algorithm = verifier.algorithm,
        iterations = verifier.iterations,
        salt = verifier.salt,
        digest = verifier.digest,
    }
end

local function copyRecord(record, includeVerifier)
    local copied = {
        name = record.name,
        uid = record.uid,
        home = record.home,
        admin = record.admin,
        loginDisabled = record.loginDisabled,
    }

    if includeVerifier then
        if record.passwordAlgorithm == "disabled" then
            copied.passwordAlgorithm = "disabled"
        else
            copied.verifier = copyVerifier(record.verifier)
        end
    end

    return copied
end

local function isWholeNumber(value)
    return type(value) == "number" and value == math.floor(value)
end

local function validateAbsoluteHome(username, home)
    if type(home) ~= "string" or string.sub(home, 1, 1) ~= "/" then
        return false, "User " .. username .. " has a non-absolute home."
    end

    if string.find(home, "..", 1, true) ~= nil or
        string.find(home, "//", 1, true) ~= nil or
        home ~= "/dickos/home/" .. username then
        return false, "User " .. username .. " has an invalid home path."
    end

    return true, nil
end

local function validateRecord(record)
    if type(record) ~= "table" then
        return false, "User record must be a table."
    end

    local usernameIsValid, usernameError = users.validateUsername(
        record.name,
        record.name == "root"
    )

    if not usernameIsValid then
        return false, usernameError
    end

    if not isWholeNumber(record.uid) or record.uid < 0 then
        return false, "User " .. record.name .. " has an invalid UID."
    end

    local homeIsValid, homeError = validateAbsoluteHome(record.name, record.home)

    if not homeIsValid then
        return false, homeError
    end

    if type(record.admin) ~= "boolean" or
        type(record.loginDisabled) ~= "boolean" then
        return false, "User " .. record.name ..
            " has invalid boolean account flags."
    end

    if record.passwordAlgorithm == "disabled" then
        if not record.loginDisabled or record.verifier ~= nil then
            return false, "Disabled password record is internally inconsistent."
        end
    else
        if type(record.verifier) ~= "table" then
            return false, "User " .. record.name ..
                " has no password verifier."
        end

        local verifierIsValid, verifierError =
            password.validateVerifier(record.verifier)

        if not verifierIsValid then
            return false, "User " .. record.name .. ": " .. verifierError
        end

        if record.passwordAlgorithm ~= nil and
            record.passwordAlgorithm ~= record.verifier.algorithm then
            return false, "User " .. record.name ..
                " has conflicting password algorithms."
        end
    end

    return true, nil
end

-- Validate the complete database before any lookup or write. UID uniqueness,
-- the exact root contract, and the initial owner contract are checked together
-- so a syntactically valid but ambiguous security state never boots.
function users.validate(database)
    if type(database) ~= "table" or type(database.records) ~= "table" then
        return false, "User database must contain records."
    end

    if database.formatVersion ~= USERS_FORMAT_VERSION then
        return false, "Unsupported users.db format_version."
    end

    if not isWholeNumber(database.nextUID) or
        database.nextUID < FIRST_AVAILABLE_UID then
        return false, "users.db next_uid is invalid."
    end

    local seenUIDs = {}
    local ownerRecord = nil
    local highestUID = 0

    for username, record in pairs(database.records) do
        if username ~= record.name then
            return false, "User record name does not match its database key."
        end

        local recordIsValid, recordError = validateRecord(record)

        if not recordIsValid then
            return false, recordError
        end

        if seenUIDs[record.uid] ~= nil then
            return false, "Duplicate UID shared by " .. seenUIDs[record.uid] ..
                " and " .. username .. "."
        end

        seenUIDs[record.uid] = username
        highestUID = math.max(highestUID, record.uid)

        if record.uid == FIRST_HUMAN_UID then
            ownerRecord = record
        end
    end

    local root = database.records.root

    if root == nil or root.uid ~= 0 or root.home ~= "/dickos/home/root" or
        root.admin ~= true or root.loginDisabled ~= true or
        root.passwordAlgorithm ~= "disabled" or root.verifier ~= nil then
        return false, "users.db root account contract is invalid."
    end

    if ownerRecord == nil or ownerRecord.name == "root" or
        ownerRecord.admin ~= true or ownerRecord.loginDisabled ~= false or
        ownerRecord.passwordAlgorithm == "disabled" or
        ownerRecord.home ~= "/dickos/home/" .. ownerRecord.name then
        return false, "users.db owner UID 1000 contract is invalid."
    end

    if database.nextUID <= highestUID then
        return false, "users.db next_uid does not exceed assigned UIDs."
    end

    database.ownerName = ownerRecord.name
    return true, nil
end

local SIMPLE_FIELDS = {
    uid = true,
    home = true,
    admin = true,
    login_disabled = true,
    ["password.algorithm"] = true,
    ["password.iterations"] = true,
    ["password.salt"] = true,
    ["password.digest"] = true,
}

-- Convert parsed flat config-v1 keys into records while rejecting every
-- unknown or missing field. Optional-config forward compatibility is not
-- appropriate here: silently ignoring security-state fields could reinterpret
-- a newer database under older authentication rules.
local function fromValues(values)
    if values.format_version == nil or values.next_uid == nil then
        return nil, "users.db is missing format_version or next_uid."
    end

    local database = {
        formatVersion = values.format_version,
        nextUID = values.next_uid,
        records = {},
    }

    for key, value in pairs(values) do
        if key ~= "format_version" and key ~= "next_uid" then
            local username, field = string.match(key, "^user%.([^.]+)%.(.+)$")

            if username == nil or SIMPLE_FIELDS[field] ~= true then
                return nil, "users.db contains unknown field '" .. key .. "'."
            end

            local record = database.records[username]

            if record == nil then
                record = { name = username }
                database.records[username] = record
            end

            if field == "uid" then
                record.uid = value
            elseif field == "home" then
                record.home = value
            elseif field == "admin" then
                record.admin = value
            elseif field == "login_disabled" then
                record.loginDisabled = value
            elseif field == "password.algorithm" then
                record.passwordAlgorithm = value
            else
                record.verifier = record.verifier or {}

                if field == "password.iterations" then
                    record.verifier.iterations = value
                elseif field == "password.salt" then
                    record.verifier.salt = value
                elseif field == "password.digest" then
                    record.verifier.digest = value
                end
            end
        end
    end

    for _, record in pairs(database.records) do
        if record.passwordAlgorithm ~= "disabled" then
            record.verifier = record.verifier or {}
            record.verifier.algorithm = record.passwordAlgorithm
        end
    end

    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    return database, nil
end

local function toValues(database)
    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    local values = {
        format_version = database.formatVersion,
        next_uid = database.nextUID,
    }

    for username, record in pairs(database.records) do
        local prefix = "user." .. username .. "."

        values[prefix .. "uid"] = record.uid
        values[prefix .. "home"] = record.home
        values[prefix .. "admin"] = record.admin
        values[prefix .. "login_disabled"] = record.loginDisabled

        if record.passwordAlgorithm == "disabled" then
            values[prefix .. "password.algorithm"] = "disabled"
        else
            values[prefix .. "password.algorithm"] = record.verifier.algorithm
            values[prefix .. "password.iterations"] =
                record.verifier.iterations
            values[prefix .. "password.salt"] = record.verifier.salt
            values[prefix .. "password.digest"] = record.verifier.digest
        end
    end

    return values, nil
end

function users.load(path)
    local databasePath = path or USERS_DATABASE_PATH
    local text, readError = config.readText(databasePath)

    if text == nil then
        return nil, readError
    end

    local values, parseError = config.parse(text, databasePath)

    if values == nil then
        return nil, parseError
    end

    return fromValues(values)
end

function users.createInitial(ownerUsername, ownerVerifier)
    local usernameIsValid, usernameError =
        users.validateUsername(ownerUsername, false)

    if not usernameIsValid then
        return nil, usernameError
    end

    local verifierIsValid, verifierError =
        password.validateVerifier(ownerVerifier)

    if not verifierIsValid then
        return nil, verifierError
    end

    local database = {
        formatVersion = USERS_FORMAT_VERSION,
        nextUID = FIRST_AVAILABLE_UID,
        records = {
            root = {
                name = "root",
                uid = 0,
                home = "/dickos/home/root",
                admin = true,
                loginDisabled = true,
                passwordAlgorithm = "disabled",
            },
            [ownerUsername] = {
                name = ownerUsername,
                uid = FIRST_HUMAN_UID,
                home = "/dickos/home/" .. ownerUsername,
                admin = true,
                loginDisabled = false,
                verifier = copyVerifier(ownerVerifier),
            },
        },
    }

    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    return database, nil
end

function users.getByName(database, username, includeVerifier)
    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    local record = database.records[username]

    if record == nil then
        return nil, nil
    end

    return copyRecord(record, includeVerifier == true), nil
end

function users.getByUID(database, uid, includeVerifier)
    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    for _, record in pairs(database.records) do
        if record.uid == uid then
            return copyRecord(record, includeVerifier == true), nil
        end
    end

    return nil, nil
end

function users.replacePassword(database, username, verifier)
    local verifierIsValid, verifierError = password.validateVerifier(verifier)

    if not verifierIsValid then
        return nil, verifierError
    end

    local databaseIsValid, validationError = users.validate(database)

    if not databaseIsValid then
        return nil, validationError
    end

    local replacement = {
        formatVersion = database.formatVersion,
        nextUID = database.nextUID,
        records = {},
    }

    for recordName, record in pairs(database.records) do
        replacement.records[recordName] = copyRecord(record, true)
    end

    local record = replacement.records[username]

    if record == nil or record.loginDisabled then
        return nil, "Password cannot be changed for this account."
    end

    record.passwordAlgorithm = nil
    record.verifier = copyVerifier(verifier)

    local replacementIsValid, replacementError = users.validate(replacement)

    if not replacementIsValid then
        return nil, replacementError
    end

    return replacement, nil
end

function users.write(database, path)
    local values, valuesError = toValues(database)

    if values == nil then
        return false, valuesError
    end

    local databasePath = path or USERS_DATABASE_PATH
    local written, writeError = config.writeValues(databasePath, values)

    if written then
        return true, nil
    end

    -- A replacement may commit successfully and then fail while cleaning its
    -- `.bak` artifact. Re-read and compare canonical semantic values before
    -- reporting failure, so passwd never tells the user the old password is
    -- active when the new verifier actually reached users.db. Earlier failures
    -- still leave the old/missing target and therefore do not match.
    local installed = users.load(databasePath)

    if installed ~= nil then
        local installedValues = toValues(installed)
        local expectedText = config.serializeValues(values)
        local installedText = config.serializeValues(installedValues)

        if expectedText ~= nil and installedText == expectedText then
            return true, nil
        end
    end

    return false, writeError
end

return users
