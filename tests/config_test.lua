-- Host-side tests for the DICK/OS configuration library
-- Run with: lua tests/config_test.lua

local CONFIG_SOURCE = "src/dickos/lib/config.lua"
local hostLoadfile = loadfile

local function readHostFile(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    file:close()
    return contents
end

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function copyTable(source)
    local copied = {}

    for key, value in pairs(source or {}) do
        copied[key] = value
    end

    return copied
end

-- Build a small in-memory CC:T filesystem. Each writer scenario receives a
-- fresh module environment because config.lua closes over its global `fs`
-- table when the module chunk executes.
local function createFilesystem(options)
    options = options or {}

    local state = {
        actions = {},
        files = copyTable(options.files),
        moves = {},
    }
    local directories = copyTable(options.directories)
    local fsMock = {}

    fsMock.exists = function(path)
        return state.files[path] ~= nil or directories[path] == true
    end

    fsMock.isDir = function(path)
        return directories[path] == true
    end

    fsMock.getSize = function(path)
        if options.reportedSize ~= nil then
            return options.reportedSize
        end

        return #assert(state.files[path])
    end

    fsMock.open = function(path, mode)
        state.actions[#state.actions + 1] = "open:" .. mode .. ":" .. path

        if mode == "r" then
            if options.readOpenFailure then
                return nil, "simulated unreadable file"
            end

            local contents = assert(state.files[path])

            return {
                readAll = function()
                    if options.readFailure then
                        error("simulated read failure", 0)
                    end

                    return contents
                end,
                close = function()
                    if options.readCloseFailure then
                        error("simulated read close failure", 0)
                    end
                end,
            }
        end

        assert(mode == "w")

        if options.temporaryOpenFailure and
            string.sub(path, -4) == ".tmp" then
            return nil, "simulated temporary open failure"
        end

        state.files[path] = ""

        return {
            write = function(contents)
                if options.temporaryWriteFailure and
                    string.sub(path, -4) == ".tmp" then
                    error("simulated temporary write failure", 0)
                end

                state.files[path] = contents
            end,
            close = function()
                if options.temporaryCloseFailure and
                    string.sub(path, -4) == ".tmp" then
                    error("simulated temporary close failure", 0)
                end
            end,
        }
    end

    fsMock.delete = function(path)
        state.actions[#state.actions + 1] = "delete:" .. path
        state.files[path] = nil
        directories[path] = nil
    end

    fsMock.move = function(sourcePath, targetPath)
        state.moves[#state.moves + 1] = {
            source = sourcePath,
            target = targetPath,
        }
        state.actions[#state.actions + 1] =
            "move:" .. sourcePath .. ":" .. targetPath

        if options.failReplacementMove and
            string.sub(sourcePath, -4) == ".tmp" then
            error("simulated replacement failure", 0)
        end

        if options.failRestorationMove and
            string.sub(sourcePath, -4) == ".bak" then
            error("simulated restoration failure", 0)
        end

        assert(state.files[sourcePath] ~= nil)
        assert(state.files[targetPath] == nil)
        state.files[targetPath] = state.files[sourcePath]
        state.files[sourcePath] = nil
    end

    return fsMock, state
end

local function loadConfig(options)
    local fsMock, state = createFilesystem(options)
    local environment = { fs = fsMock }

    setmetatable(environment, { __index = _G })
    environment._G = environment

    local program = assert(hostLoadfile(CONFIG_SOURCE, "t", environment))
    local module = program()

    return module, state
end

local SYSTEM_SCHEMA = {
    formatVersion = 1,
    entries = {
        ["format_version"] = {
            type = "integer",
            default = 1,
        },
        ["boot.cosmetic_delay"] = {
            type = "boolean",
            default = true,
        },
        ["shell.history_limit"] = {
            type = "integer",
            default = 64,
            min = 0,
            max = 256,
        },
        ["display.ratio"] = {
            type = "number",
            default = 0.5,
            min = 0,
            max = 1,
        },
        ["display.label"] = {
            type = "string",
            default = "DICK/OS",
        },
        ["display.mode"] = {
            type = "string",
            default = "safe",
            allowed = { "safe", "fast" },
        },
    },
}

local config = loadConfig()

-- Version-controlled templates must themselves be valid config v1 data. The
-- network/service files intentionally have only the common format marker.
for _, templatePath in ipairs({
    "src/dickos/etc/system.cfg",
    "src/dickos/etc/network.cfg",
    "src/dickos/etc/services.cfg",
}) do
    local templateValues, templateError = config.parse(
        readHostFile(templatePath),
        templatePath
    )

    assert(templateValues ~= nil, tostring(templateError))
    assert(templateValues.format_version == 1)
end

-- PARSER ------------------------------------------------------------------

local emptyValues, emptyError = config.parse(
    "\n # comment only\n\t\n",
    "empty.cfg"
)
assert(emptyValues ~= nil, tostring(emptyError))
assert(next(emptyValues) == nil)

local parsed, parseError = config.parse([[
    format_version = 1
    boot.cosmetic_delay=true
    feature.disabled = false
    shell.history_limit = 64
    display.ratio = 0.05
    display.label = "example"
]], "system.cfg")
assert(parsed ~= nil, tostring(parseError))
assert(parsed.format_version == 1)
assert(parsed["boot.cosmetic_delay"] == true)
assert(parsed["feature.disabled"] == false)
assert(parsed["shell.history_limit"] == 64)
assert(parsed["display.ratio"] == 0.05)
assert(parsed["display.label"] == "example")

local escaped, escapedError = config.parse(
    'display.label = "quote: \\" slash: \\\\ line: \\n tab: \\t"',
    "escaped.cfg"
)
assert(escaped ~= nil, tostring(escapedError))
assert(escaped["display.label"] ==
    "quote: \" slash: \\ line: \n tab: \t")

local malformedAssignment, malformedAssignmentError = config.parse(
    "format_version = 1\nthis is not valid config\n",
    "system.cfg"
)
assert(malformedAssignment == nil)
assert(contains(malformedAssignmentError, "system.cfg:2: expected '='"))

local malformedValue, malformedValueError = config.parse(
    "format_version = maybe\n",
    "system.cfg"
)
assert(malformedValue == nil)
assert(contains(malformedValueError, "system.cfg:1:"))
assert(contains(malformedValueError, "invalid value"))

local emptyValue, emptyValueError = config.parse(
    "format_version =\n",
    "system.cfg"
)
assert(emptyValue == nil)
assert(contains(emptyValueError, "expected value"))

local duplicate, duplicateError = config.parse(
    "format_version = 1\nformat_version = 1\n",
    "system.cfg"
)
assert(duplicate == nil)
assert(contains(duplicateError, "system.cfg:2: duplicate key"))
assert(contains(duplicateError, "first assigned on line 1"))

local invalidKey, invalidKeyError = config.parse(
    "Boot.delay = true\n",
    "system.cfg"
)
assert(invalidKey == nil)
assert(contains(invalidKeyError, "invalid key"))

local executable, executableError = config.parse(
    "danger = load(\"return 1\")\n",
    "system.cfg"
)
assert(executable == nil)
assert(contains(executableError, "invalid value"))

-- VALIDATION --------------------------------------------------------------

local defaults, defaultsError = config.validate(
    { format_version = 1 },
    SYSTEM_SCHEMA,
    "system.cfg"
)
assert(defaults ~= nil, tostring(defaultsError))
assert(defaults["boot.cosmetic_delay"] == true)
assert(defaults["shell.history_limit"] == 64)

local valid, validWarnings, validError = config.validate({
    format_version = 1,
    ["boot.cosmetic_delay"] = false,
    ["shell.history_limit"] = 3,
    ["display.mode"] = "fast",
}, SYSTEM_SCHEMA, "system.cfg")
assert(valid ~= nil, tostring(validError))
assert(#validWarnings == 0)
assert(valid["boot.cosmetic_delay"] == false)
assert(valid["shell.history_limit"] == 3)
assert(valid["display.mode"] == "fast")

local wrongType, wrongTypeWarnings = config.validate({
    format_version = 1,
    ["shell.history_limit"] = "many",
}, SYSTEM_SCHEMA, "system.cfg")
assert(wrongType["shell.history_limit"] == 64)
assert(#wrongTypeWarnings == 1)
assert(contains(wrongTypeWarnings[1], "expected integer"))

local belowMinimum, belowWarnings = config.validate({
    format_version = 1,
    ["shell.history_limit"] = -1,
}, SYSTEM_SCHEMA, "system.cfg")
assert(belowMinimum["shell.history_limit"] == 64)
assert(contains(belowWarnings[1], "at least 0"))

local aboveMaximum, aboveWarnings = config.validate({
    format_version = 1,
    ["shell.history_limit"] = 257,
}, SYSTEM_SCHEMA, "system.cfg")
assert(aboveMaximum["shell.history_limit"] == 64)
assert(contains(aboveWarnings[1], "at most 256"))

local unknown, unknownWarnings = config.validate({
    format_version = 1,
    ["future.setting"] = "preserved",
}, SYSTEM_SCHEMA, "system.cfg")
assert(unknown["future.setting"] == "preserved")
assert(#unknownWarnings == 1)
assert(contains(unknownWarnings[1], "unknown key"))

local unsupported, unsupportedWarnings, unsupportedError = config.validate({
    format_version = 2,
    ["shell.history_limit"] = 3,
}, SYSTEM_SCHEMA, "system.cfg")
assert(unsupported == nil)
assert(#unsupportedWarnings == 0)
assert(contains(unsupportedError, "unsupported format_version 2"))

-- WRITER ------------------------------------------------------------------

local serialValues = {
    format_version = 1,
    ["boot.cosmetic_delay"] = false,
    ["shell.history_limit"] = 3,
    ["display.ratio"] = 0.05,
    ["display.label"] = "quote \" slash \\ line\nnext\tcell",
    ["display.mode"] = "fast",
}
local serialised, serialWarnings, serialError = config.serialize(
    serialValues,
    SYSTEM_SCHEMA
)
assert(serialised ~= nil, tostring(serialError))
assert(#serialWarnings == 0)

local serialisedAgain = assert(config.serialize(serialValues, SYSTEM_SCHEMA))
assert(serialisedAgain == serialised)
assert(string.sub(serialised, 1, #"format_version = 1\n") ==
    "format_version = 1\n")

local roundTrip, roundTripError = config.parse(serialised, "round-trip.cfg")
assert(roundTrip ~= nil, tostring(roundTripError))

for key, value in pairs(serialValues) do
    assert(roundTrip[key] == value, "round-trip mismatch for " .. key)
end

local CONFIG_PATH = "/dickos/etc/system.cfg"

local failingConfig, failingState = loadConfig({
    files = { [CONFIG_PATH] = "old configuration" },
    temporaryWriteFailure = true,
})
local writeSucceeded, _, writeError = failingConfig.write(
    CONFIG_PATH,
    serialValues,
    SYSTEM_SCHEMA
)
assert(not writeSucceeded)
assert(contains(writeError, "simulated temporary write failure"))
assert(failingState.files[CONFIG_PATH] == "old configuration")
assert(failingState.files[CONFIG_PATH .. ".tmp"] == nil)
assert(failingState.files[CONFIG_PATH .. ".bak"] == nil)

local restoreConfig, restoreState = loadConfig({
    files = { [CONFIG_PATH] = "old configuration" },
    failReplacementMove = true,
})
local replaceSucceeded, _, replaceError = restoreConfig.write(
    CONFIG_PATH,
    serialValues,
    SYSTEM_SCHEMA
)
assert(not replaceSucceeded)
assert(contains(replaceError, "original configuration restored"))
assert(restoreState.files[CONFIG_PATH] == "old configuration")
assert(restoreState.files[CONFIG_PATH .. ".tmp"] == nil)
assert(restoreState.files[CONFIG_PATH .. ".bak"] == nil)
assert(#restoreState.moves == 3)
assert(restoreState.moves[3].source == CONFIG_PATH .. ".bak")
assert(restoreState.moves[3].target == CONFIG_PATH)

local retainedBackupConfig, retainedBackupState = loadConfig({
    files = { [CONFIG_PATH .. ".bak"] = "recoverable configuration" },
})
local retainedBackupSucceeded, _, retainedBackupError =
    retainedBackupConfig.write(CONFIG_PATH, serialValues, SYSTEM_SCHEMA)
assert(not retainedBackupSucceeded)
assert(contains(retainedBackupError, "backup is retained"))
assert(retainedBackupState.files[CONFIG_PATH] == nil)
assert(retainedBackupState.files[CONFIG_PATH .. ".bak"] ==
    "recoverable configuration")
assert(retainedBackupState.files[CONFIG_PATH .. ".tmp"] == nil)

local successConfig, successState = loadConfig({
    files = { [CONFIG_PATH] = "old configuration" },
})
local success, successWarnings, successError = successConfig.write(
    CONFIG_PATH,
    serialValues,
    SYSTEM_SCHEMA
)
assert(success, tostring(successError))
assert(#successWarnings == 0)
assert(successState.files[CONFIG_PATH] == serialised)
assert(successState.files[CONFIG_PATH .. ".tmp"] == nil)
assert(successState.files[CONFIG_PATH .. ".bak"] == nil)

-- LOAD --------------------------------------------------------------------

local missingConfig = loadConfig()
local missingValues, missingWarnings, missingStatus = missingConfig.load(
    CONFIG_PATH,
    SYSTEM_SCHEMA
)
assert(missingValues["shell.history_limit"] == 64)
assert(#missingWarnings == 1)
assert(not missingStatus.loaded)
assert(missingStatus.usedWholeFileDefaults)

local unreadableConfig = loadConfig({
    files = { [CONFIG_PATH] = serialised },
    readOpenFailure = true,
})
local unreadableValues, unreadableWarnings, unreadableStatus =
    unreadableConfig.load(CONFIG_PATH, SYSTEM_SCHEMA)
assert(unreadableValues["shell.history_limit"] == 64)
assert(contains(unreadableWarnings[1], "simulated unreadable file"))
assert(not unreadableStatus.loaded)

local oversizedConfig = loadConfig({
    files = { [CONFIG_PATH] = "small body" },
    reportedSize = 64 * 1024 + 1,
})
local oversizedValues, oversizedWarnings, oversizedStatus =
    oversizedConfig.load(CONFIG_PATH, SYSTEM_SCHEMA)
assert(oversizedValues["shell.history_limit"] == 64)
assert(contains(oversizedWarnings[1], "exceeds 64 KiB"))
assert(not oversizedStatus.loaded)

local malformedConfig = loadConfig({
    files = { [CONFIG_PATH] = "this is malformed\n" },
})
local malformedValues, malformedWarnings, malformedStatus =
    malformedConfig.load(CONFIG_PATH, SYSTEM_SCHEMA)
assert(malformedValues["shell.history_limit"] == 64)
assert(contains(malformedWarnings[1], "expected '='"))
assert(not malformedStatus.loaded)

local validConfig = loadConfig({
    files = { [CONFIG_PATH] = serialised },
})
local loadedValues, loadedWarnings, loadedStatus = validConfig.load(
    CONFIG_PATH,
    SYSTEM_SCHEMA
)
assert(loadedValues["boot.cosmetic_delay"] == false)
assert(loadedValues["shell.history_limit"] == 3)
assert(#loadedWarnings == 0)
assert(loadedStatus.loaded)
assert(not loadedStatus.usedWholeFileDefaults)

local unsupportedConfig = loadConfig({
    files = {
        [CONFIG_PATH] =
            "format_version = 2\nshell.history_limit = 3\n",
    },
})
local unsupportedValues, loadUnsupportedWarnings, unsupportedStatus =
    unsupportedConfig.load(CONFIG_PATH, SYSTEM_SCHEMA)
assert(unsupportedValues["shell.history_limit"] == 64)
assert(contains(
    loadUnsupportedWarnings[#loadUnsupportedWarnings],
    "unsupported format_version 2"
))
assert(not unsupportedStatus.loaded)

io.stdout:write("configuration tests: PASS\n")
