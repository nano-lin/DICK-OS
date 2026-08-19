-- Host-side tests for users.db and authentication policy
-- Run with: lua tests/auth_test.lua

local hostLoadfile = loadfile
local USERS_PATH = "/dickos/etc/users.db"
local SOURCE_BY_INSTALLED_PATH = {
    ["/dickos/lib/config.lua"] = "src/dickos/lib/config.lua",
    ["/dickos/lib/password.lua"] = "src/dickos/lib/password.lua",
    ["/dickos/lib/users.lua"] = "src/dickos/lib/users.lua",
    ["/dickos/lib/auth.lua"] = "src/dickos/lib/auth.lua",
}

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local state = {
    files = {},
    failReplacementMove = false,
    failRestorationMove = false,
    failBackupDelete = false,
    temporaryWriteFailure = false,
    reportedSize = nil,
    readOpenFailure = false,
}

local fsMock = {}

fsMock.exists = function(path)
    return state.files[path] ~= nil
end

fsMock.isDir = function()
    return false
end

fsMock.getSize = function(path)
    return state.reportedSize or #assert(state.files[path])
end

fsMock.open = function(path, mode)
    if mode == "r" then
        if state.readOpenFailure then
            return nil, "simulated unreadable users.db"
        end

        local contents = state.files[path]

        if contents == nil then
            return nil, "missing"
        end

        return {
            readAll = function() return contents end,
            close = function() end,
        }
    end

    assert(mode == "w")
    state.files[path] = ""

    return {
        write = function(contents)
            if state.temporaryWriteFailure and
                string.sub(path, -4) == ".tmp" then
                error("simulated temporary write failure", 0)
            end

            state.files[path] = contents
        end,
        close = function() end,
    }
end

fsMock.delete = function(path)
    if state.failBackupDelete and string.sub(path, -4) == ".bak" then
        error("simulated backup cleanup failure", 0)
    end

    state.files[path] = nil
end

fsMock.move = function(sourcePath, targetPath)
    if state.failReplacementMove and string.sub(sourcePath, -4) == ".tmp" then
        error("simulated replacement failure", 0)
    end

    if state.failRestorationMove and string.sub(sourcePath, -4) == ".bak" then
        error("simulated restoration failure", 0)
    end

    assert(state.files[sourcePath] ~= nil)
    assert(state.files[targetPath] == nil)
    state.files[targetPath] = state.files[sourcePath]
    state.files[sourcePath] = nil
end

local epoch = 100000
local missingInstalledPath = nil
local environment = {
    fs = fsMock,
    os = {
        epoch = function(kind)
            assert(kind == "utc")
            epoch = epoch + 1
            return epoch
        end,
        getComputerID = function() return 11 end,
        clock = function() return epoch / 1000 end,
    },
}

setmetatable(environment, { __index = _G })
environment._G = environment
environment.loadfile = function(path)
    if path == missingInstalledPath then
        return nil, "simulated missing core file"
    end

    local source = SOURCE_BY_INSTALLED_PATH[path] or path

    return hostLoadfile(source, "t", environment)
end

local password = assert(environment.loadfile(
    "/dickos/lib/password.lua"
))()
local users = assert(environment.loadfile("/dickos/lib/users.lua"))()

for _, missingPath in ipairs({
    "/dickos/lib/users.lua",
    "/dickos/lib/password.lua",
}) do
    missingInstalledPath = missingPath
    local authProgram = assert(environment.loadfile("/dickos/lib/auth.lua"))
    local loaded, loadError = pcall(authProgram)

    assert(not loaded)
    assert(contains(loadError, "simulated missing core file"))
end

missingInstalledPath = nil

assert(users.validateUsername("nano_1"))
assert(not users.validateUsername("Nano"))
assert(not users.validateUsername("nano-user"))
assert(not users.validateUsername("root"))
assert(not users.validateUsername("bootstrap"))

local initialVerifier = assert(password.createVerifier(
    "initial password",
    "machine:nano",
    password.minimumIterations
))
local database = assert(users.createInitial("nano", initialVerifier))
assert(database.nextUID == 1001)
assert(database.records.root.uid == 0)
assert(database.records.root.admin)
assert(database.records.root.loginDisabled)
assert(database.records.root.passwordAlgorithm == "disabled")
assert(database.records.nano.uid == 1000)
assert(database.records.nano.admin)
assert(not database.records.nano.loginDisabled)
assert(database.records.nano.home == "/dickos/home/nano")

local written, writeError = users.write(database)
assert(written, tostring(writeError))
local originalDatabaseText = state.files[USERS_PATH]
assert(type(originalDatabaseText) == "string")
assert(not contains(originalDatabaseText, "initial password"))
assert(contains(originalDatabaseText, "user.root.password.algorithm = \"disabled\""))
assert(contains(originalDatabaseText, "user.nano.uid = 1000"))

local loaded = assert(users.load())
assert(loaded.ownerName == "nano")
local publicNano = assert(users.getByName(loaded, "nano"))
assert(publicNano.uid == 1000)
assert(publicNano.verifier == nil)
local privateNano = assert(users.getByUID(loaded, 1000, true))
assert(privateNano.verifier.digest == initialVerifier.digest)

local cleanupVerifier = assert(password.createVerifier(
    "cleanup password",
    "machine:nano",
    password.minimumIterations
))
local cleanupDatabase = assert(users.replacePassword(
    loaded,
    "nano",
    cleanupVerifier
))

state.temporaryWriteFailure = true
local temporaryFailed, temporaryError = users.write(cleanupDatabase)
state.temporaryWriteFailure = false
assert(not temporaryFailed)
assert(contains(temporaryError, "simulated temporary write failure"))
assert(state.files[USERS_PATH] == originalDatabaseText)

state.failReplacementMove = true
state.failRestorationMove = true
local restorationFailed, restorationError = users.write(cleanupDatabase)
state.failReplacementMove = false
state.failRestorationMove = false
assert(not restorationFailed)
assert(contains(restorationError, "backup retained"))
assert(state.files[USERS_PATH] == nil)
assert(state.files[USERS_PATH .. ".bak"] == originalDatabaseText)
state.files[USERS_PATH] = state.files[USERS_PATH .. ".bak"]
state.files[USERS_PATH .. ".bak"] = nil

state.failBackupDelete = true
local cleanupCommitted, cleanupError = users.write(cleanupDatabase)
state.failBackupDelete = false
assert(cleanupCommitted, tostring(cleanupError))
local cleanupLoaded = assert(users.load())
assert(assert(users.getByName(cleanupLoaded, "nano", true)).verifier.digest ==
    cleanupVerifier.digest)
assert(users.write(database))
assert(state.files[USERS_PATH] == originalDatabaseText)

local missingText = state.files[USERS_PATH]
state.files[USERS_PATH] = nil
local missing, missingError = users.load()
assert(missing == nil)
assert(contains(missingError, "missing"))
state.files[USERS_PATH] = missingText

state.readOpenFailure = true
local unreadable, unreadableError = users.load()
assert(unreadable == nil)
assert(contains(unreadableError, "simulated unreadable users.db"))
state.readOpenFailure = false

state.reportedSize = 64 * 1024 + 1
local oversized, oversizedError = users.load()
assert(oversized == nil)
assert(contains(oversizedError, "exceeds 64 KiB"))
state.reportedSize = nil

state.files[USERS_PATH] = "format_version = 1\nthis is malformed\n"
local malformed, malformedError = users.load()
assert(malformed == nil)
assert(contains(malformedError, "expected '='"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "format_version = 1",
    "format_version = 2",
    1
)
local unsupported, unsupportedError = users.load()
assert(unsupported == nil)
assert(contains(unsupportedError, "Unsupported users.db format_version"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.nano%.uid = 1000",
    "user.nano.uid = 0"
)
local duplicateUID, duplicateUIDError = users.load()
assert(duplicateUID == nil)
assert(contains(duplicateUIDError, "Duplicate UID"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.root%.[^\n]+\n",
    ""
)
local missingRoot, missingRootError = users.load()
assert(missingRoot == nil)
assert(contains(missingRootError, "root account contract"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.root%.uid = 0",
    "user.root.uid = 9"
)
local wrongRootUID, wrongRootUIDError = users.load()
assert(wrongRootUID == nil)
assert(contains(wrongRootUIDError, "root account contract"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.nano%.[^\n]+\n",
    ""
)
local missingOwner, missingOwnerError = users.load()
assert(missingOwner == nil)
assert(contains(missingOwnerError, "owner UID 1000 contract"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    'user%.nano%.password%.digest = "[^"]+"',
    'user.nano.password.digest = "bad"'
)
local malformedVerifier, malformedVerifierError = users.load()
assert(malformedVerifier == nil)
assert(contains(malformedVerifierError, "digest is malformed"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.nano%.admin = true\n",
    ""
)
local missingField, missingFieldError = users.load()
assert(missingField == nil)
assert(contains(missingFieldError, "invalid boolean account flags"))

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    "user%.root%.login_disabled = true",
    "user.root.login_disabled = false"
)
local invalidRoot, invalidRootError = users.load()
assert(invalidRoot == nil)
assert(contains(invalidRootError, "inconsistent") or
    contains(invalidRootError, "root account contract"))

state.files[USERS_PATH] = originalDatabaseText .. "future.security = true\n"
local unknownField, unknownFieldError = users.load()
assert(unknownField == nil)
assert(contains(unknownFieldError, "unknown field"))
state.files[USERS_PATH] = originalDatabaseText

local auth = assert(environment.loadfile("/dickos/lib/auth.lua"))()
assert(auth.validateState())

local authenticated, resultKind = auth.authenticate("nano", "initial password")
assert(authenticated ~= nil, tostring(resultKind))
assert(authenticated.name == "nano")
assert(authenticated.uid == 1000)
assert(authenticated.admin)
assert(authenticated.home == "/dickos/home/nano")
assert(authenticated.verifier == nil)

local unknownUser, unknownKind = auth.authenticate("nobody", "initial password")
assert(unknownUser == nil and unknownKind == "denied")
local wrongPassword, wrongKind = auth.authenticate("nano", "wrong password")
assert(wrongPassword == nil and wrongKind == "denied")
local rootLogin, rootKind = auth.authenticate("root", "initial password")
assert(rootLogin == nil and rootKind == "denied")

state.files[USERS_PATH] = string.gsub(
    originalDatabaseText,
    'user%.nano%.password%.digest = "[^"]+"',
    'user.nano.password.digest = "bad"'
)
local corruptLogin, corruptKind = auth.authenticate("nano", "initial password")
assert(corruptLogin == nil and corruptKind == "state")
state.files[USERS_PATH] = originalDatabaseText

local wrongChange, wrongChangeKind = auth.changePassword(
    "nano",
    "wrong password",
    "replacement password",
    "machine"
)
assert(not wrongChange and wrongChangeKind == "denied")
assert(state.files[USERS_PATH] == originalDatabaseText)

local changed, changeKind, changeError = auth.changePassword(
    "nano",
    "initial password",
    "replacement password",
    "machine"
)
assert(changed, tostring(changeKind) .. ": " .. tostring(changeError))
assert(state.files[USERS_PATH] ~= originalDatabaseText)
assert(not contains(state.files[USERS_PATH], "replacement password"))
local changedDatabase = assert(users.load())
local changedNano = assert(users.getByName(changedDatabase, "nano", true))
assert(changedNano.verifier.salt ~= initialVerifier.salt)
assert(auth.authenticate("nano", "replacement password"))
local oldLogin, oldKind = auth.authenticate("nano", "initial password")
assert(oldLogin == nil and oldKind == "denied")

local beforeFailedWrite = state.files[USERS_PATH]
state.failReplacementMove = true
local failedWrite, failedWriteKind = auth.changePassword(
    "nano",
    "replacement password",
    "third password",
    "machine"
)
state.failReplacementMove = false
assert(not failedWrite and failedWriteKind == "write")
assert(state.files[USERS_PATH] == beforeFailedWrite)
assert(auth.authenticate("nano", "replacement password"))

state.files[USERS_PATH] = nil
local stateUser, stateKind = auth.authenticate("nano", "replacement password")
assert(stateUser == nil and stateKind == "state")

io.stdout:write("users/auth tests: PASS\n")
