-- DICK/OS shared configuration library
-- Version: 0.1.0-unstable

-- Configuration files are intentionally small. The limit prevents a damaged
-- or accidentally copied large file from consuming most of a CC:T computer's
-- Lua memory during `readAll`. Exceeding it is a data-file failure: callers may
-- keep booting with schema defaults, but the original file is not truncated.
local MAXIMUM_CONFIG_BYTES = 64 * 1024
local TEMPORARY_SUFFIX = ".tmp"
local BACKUP_SUFFIX = ".bak"

local config = {
    maximumBytes = MAXIMUM_CONFIG_BYTES,
}

-- Remove surrounding whitespace while preserving whitespace inside quoted
-- string values. `string.gsub` returns both the changed text and a replacement
-- count; the parentheses keep only the text as this function's result.
local function trim(text)
    local withoutLeading = string.gsub(tostring(text), "^%s+", "")

    return (string.gsub(withoutLeading, "%s+$", ""))
end

local function diagnostic(sourceName, lineNumber, message)
    local source = sourceName or "<config>"

    if lineNumber == nil then
        return source .. ": " .. message
    end

    return source .. ":" .. tostring(lineNumber) .. ": " .. message
end

-- Config v1 keys contain lowercase identifier segments separated by dots.
-- Checking each segment separately makes leading, trailing, and doubled dots
-- invalid without relying on a difficult-to-read all-in-one Lua pattern.
local function isValidKey(key)
    if type(key) ~= "string" or key == "" or
        string.sub(key, 1, 1) == "." or string.sub(key, -1) == "." or
        string.find(key, "..", 1, true) ~= nil then
        return false
    end

    for segment in string.gmatch(key, "[^.]+") do
        if string.match(segment, "^[a-z][a-z0-9_]*$") == nil then
            return false
        end
    end

    return true
end

-- `pairs` does not promise an order. Sorting keys before warnings or writes
-- gives deterministic results across boots and makes generated files easy to
-- compare in tests or future integrity tooling.
local function sortedStringKeys(values)
    local keys = {}

    for key in pairs(values) do
        if type(key) ~= "string" then
            return nil, "configuration tables must use string keys"
        end

        keys[#keys + 1] = key
    end

    table.sort(keys)
    return keys, nil
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

-- Recognise a deliberately small decimal-number grammar without executing
-- the text as Lua. Scientific notation is accepted because Lua's deterministic
-- `tostring(number)` may use it for very large or small finite values.
local function parseNumber(text)
    local isNumber =
        string.match(text, "^[+-]?%d+$") ~= nil or
        string.match(text, "^[+-]?%d+%.%d+$") ~= nil or
        string.match(text, "^[+-]?%d+[eE][+-]?%d+$") ~= nil or
        string.match(text, "^[+-]?%d+%.%d+[eE][+-]?%d+$") ~= nil

    if not isNumber then
        return nil
    end

    local number = tonumber(text)

    if not isFiniteNumber(number) then
        return nil
    end

    return number
end

-- Decode the only escapes supported by config v1 quoted strings. This manual
-- loop is intentionally data-only: it never calls `load` or `loadstring`, so a
-- configuration value cannot become executable Lua code.
local function parseQuotedString(text)
    local characters = {}
    local position = 2
    local escapes = {
        ['"'] = '"',
        ["\\"] = "\\",
        n = "\n",
        r = "\r",
        t = "\t",
    }

    while position <= #text do
        local character = string.sub(text, position, position)

        if character == '"' then
            if position ~= #text then
                return nil, "unexpected text after quoted string"
            end

            return table.concat(characters), nil
        end

        if character == "\\" then
            position = position + 1
            local escapedCharacter = string.sub(text, position, position)
            local decoded = escapes[escapedCharacter]

            if decoded == nil then
                if escapedCharacter == "" then
                    return nil, "unterminated escape sequence"
                end

                return nil, "unsupported escape \\" .. escapedCharacter
            end

            characters[#characters + 1] = decoded
        else
            local byte = string.byte(character)

            if byte ~= nil and (byte < 32 or byte == 127) then
                return nil, "control characters must use an escape"
            end

            characters[#characters + 1] = character
        end

        position = position + 1
    end

    return nil, "unterminated quoted string"
end

local function parseScalar(text)
    if text == "true" then
        return true, nil
    end

    if text == "false" then
        return false, nil
    end

    if string.sub(text, 1, 1) == '"' then
        return parseQuotedString(text)
    end

    local number = parseNumber(text)

    if number ~= nil then
        return number, nil
    end

    return nil, "expected true, false, a number, or a quoted string"
end

-- Parse config v1 text into a flat table of scalar values.
--
-- Blank lines and full-line `#` comments are ignored. Every other line must
-- contain one assignment. On success the function returns the value table and
-- nil; malformed input returns nil plus a source-and-line diagnostic. Parsing
-- performs no schema validation and never executes configuration text.
function config.parse(text, sourceName)
    if type(text) ~= "string" then
        return nil, diagnostic(
            sourceName,
            nil,
            "configuration contents must be text"
        )
    end

    local values = {}
    local keyLines = {}
    local normalisedText = string.gsub(text, "\r\n", "\n")
    normalisedText = string.gsub(normalisedText, "\r", "\n")
    local lineNumber = 0

    -- Appending one newline makes `gmatch` visit the final line even when the
    -- source did not end with a newline. Each capture excludes the delimiter.
    for rawLine in string.gmatch(normalisedText .. "\n", "(.-)\n") do
        lineNumber = lineNumber + 1
        local line = trim(rawLine)

        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local equalsPosition = string.find(line, "=", 1, true)

            if equalsPosition == nil then
                return nil, diagnostic(
                    sourceName,
                    lineNumber,
                    "expected '='"
                )
            end

            local key = trim(string.sub(line, 1, equalsPosition - 1))
            local valueText = trim(string.sub(line, equalsPosition + 1))

            if not isValidKey(key) then
                return nil, diagnostic(
                    sourceName,
                    lineNumber,
                    "invalid key '" .. key .. "'"
                )
            end

            if valueText == "" then
                return nil, diagnostic(
                    sourceName,
                    lineNumber,
                    "expected value for '" .. key .. "'"
                )
            end

            if keyLines[key] ~= nil then
                return nil, diagnostic(
                    sourceName,
                    lineNumber,
                    "duplicate key '" .. key ..
                        "' (first assigned on line " ..
                        tostring(keyLines[key]) .. ")"
                )
            end

            local value, valueError = parseScalar(valueText)

            if valueError ~= nil then
                return nil, diagnostic(
                    sourceName,
                    lineNumber,
                    "invalid value for '" .. key .. "': " .. valueError
                )
            end

            values[key] = value
            keyLines[key] = lineNumber
        end
    end

    return values, nil
end

local VALID_SCHEMA_TYPES = {
    boolean = true,
    integer = true,
    number = true,
    string = true,
}

local function valueMatchesRule(value, rule)
    local expectedType = rule.type
    local typeMatches = false

    if expectedType == "integer" then
        typeMatches = isFiniteNumber(value) and
            value == math.floor(value)
    elseif expectedType == "number" then
        typeMatches = isFiniteNumber(value)
    else
        typeMatches = type(value) == expectedType
    end

    if not typeMatches then
        return false, "expected " .. expectedType
    end

    if (expectedType == "integer" or expectedType == "number") and
        rule.min ~= nil and value < rule.min then
        return false, "must be at least " .. tostring(rule.min)
    end

    if (expectedType == "integer" or expectedType == "number") and
        rule.max ~= nil and value > rule.max then
        return false, "must be at most " .. tostring(rule.max)
    end

    if rule.allowed ~= nil then
        local allowed = false

        for _, allowedValue in ipairs(rule.allowed) do
            if value == allowedValue then
                allowed = true
                break
            end
        end

        if not allowed then
            return false, "is not an allowed value"
        end
    end

    return true, nil
end

-- Schemas are ordinary Lua tables with `formatVersion` plus an `entries`
-- table. Verifying the schema once prevents a programmer mistake in a default
-- from being misreported later as a user's configuration error.
local function validateSchema(schema)
    if type(schema) ~= "table" or
        type(schema.entries) ~= "table" or
        type(schema.formatVersion) ~= "number" or
        schema.formatVersion ~= math.floor(schema.formatVersion) then
        return "schema must contain integer formatVersion and entries"
    end

    local formatRule = schema.entries.format_version

    if type(formatRule) ~= "table" or formatRule.type ~= "integer" or
        formatRule.default ~= schema.formatVersion then
        return "schema format_version must default to formatVersion"
    end

    for key, rule in pairs(schema.entries) do
        if not isValidKey(key) then
            return "schema contains invalid key '" .. tostring(key) .. "'"
        end

        if type(rule) ~= "table" or VALID_SCHEMA_TYPES[rule.type] ~= true then
            return "schema key '" .. key .. "' has an invalid type"
        end

        if rule.default == nil then
            return "schema key '" .. key .. "' has no default"
        end

        if rule.min ~= nil and not isFiniteNumber(rule.min) then
            return "schema key '" .. key .. "' has an invalid minimum"
        end

        if rule.max ~= nil and not isFiniteNumber(rule.max) then
            return "schema key '" .. key .. "' has an invalid maximum"
        end

        if rule.min ~= nil and rule.max ~= nil and rule.min > rule.max then
            return "schema key '" .. key .. "' has minimum above maximum"
        end

        if rule.allowed ~= nil and type(rule.allowed) ~= "table" then
            return "schema key '" .. key .. "' has invalid allowed values"
        end

        local defaultIsValid, defaultError = valueMatchesRule(
            rule.default,
            rule
        )

        if not defaultIsValid then
            return "schema default for '" .. key .. "' " .. defaultError
        end
    end

    return nil
end

local function buildDefaults(schema)
    local defaults = {}

    for key, rule in pairs(schema.entries) do
        defaults[key] = rule.default
    end

    return defaults
end

-- Return a fresh defaults table. Config v1 values are scalars, so copying each
-- value is sufficient; callers cannot mutate a nested default through it.
function config.defaults(schema)
    local schemaError = validateSchema(schema)

    if schemaError ~= nil then
        return nil, "Invalid configuration schema: " .. schemaError
    end

    return buildDefaults(schema), nil
end

-- Validate parsed values separately from syntax parsing.
--
-- Missing known keys receive defaults. Invalid known values receive defaults
-- plus warnings. Unknown keys are retained for forward compatibility and also
-- warned about. A supported type but different `format_version` rejects the
-- whole source instead of partially interpreting an unknown format.
function config.validate(values, schema, sourceName)
    local schemaError = validateSchema(schema)

    if schemaError ~= nil then
        return nil, {}, "Invalid configuration schema: " .. schemaError
    end

    if type(values) ~= "table" then
        return nil, {}, diagnostic(
            sourceName,
            nil,
            "parsed configuration must be a table"
        )
    end

    local valueKeys, keyError = sortedStringKeys(values)

    if valueKeys == nil then
        return nil, {}, diagnostic(sourceName, nil, keyError)
    end

    local resolved = {}
    local warnings = {}

    for _, key in ipairs(valueKeys) do
        if schema.entries[key] == nil then
            resolved[key] = values[key]
            warnings[#warnings + 1] = diagnostic(
                sourceName,
                nil,
                "unknown key '" .. key .. "' retained"
            )
        end
    end

    local schemaKeys = assert(sortedStringKeys(schema.entries))

    for _, key in ipairs(schemaKeys) do
        local rule = schema.entries[key]
        local value = values[key]

        if value == nil then
            resolved[key] = rule.default
        else
            local valueIsValid, validationError = valueMatchesRule(
                value,
                rule
            )

            if valueIsValid then
                resolved[key] = value
            else
                resolved[key] = rule.default
                warnings[#warnings + 1] = diagnostic(
                    sourceName,
                    nil,
                    "invalid '" .. key .. "' (" .. validationError ..
                        "); using schema default"
                )
            end
        end
    end

    if resolved.format_version ~= schema.formatVersion then
        return nil, warnings, diagnostic(
            sourceName,
            nil,
            "unsupported format_version " ..
                tostring(resolved.format_version) .. "; expected " ..
                tostring(schema.formatVersion)
        )
    end

    return resolved, warnings, nil
end

function config.get(values, key)
    if type(values) ~= "table" then
        return nil
    end

    return values[key]
end

local function encodeString(value)
    local encoded = { '"' }

    for position = 1, #value do
        local character = string.sub(value, position, position)

        if character == "\\" then
            encoded[#encoded + 1] = "\\\\"
        elseif character == '"' then
            encoded[#encoded + 1] = '\\"'
        elseif character == "\n" then
            encoded[#encoded + 1] = "\\n"
        elseif character == "\r" then
            encoded[#encoded + 1] = "\\r"
        elseif character == "\t" then
            encoded[#encoded + 1] = "\\t"
        else
            local byte = string.byte(character)

            if byte ~= nil and (byte < 32 or byte == 127) then
                return nil, "unsupported control character in string value"
            end

            encoded[#encoded + 1] = character
        end
    end

    encoded[#encoded + 1] = '"'
    return table.concat(encoded), nil
end

local function encodeScalar(value)
    if type(value) == "boolean" then
        return value and "true" or "false", nil
    end

    if isFiniteNumber(value) then
        return tostring(value), nil
    end

    if type(value) == "string" then
        return encodeString(value)
    end

    return nil, "writer supports only boolean, number, and string values"
end

-- Serialise an already validated flat scalar table without applying a fixed
-- schema. This is the narrow extension needed by machine-generated databases
-- whose dotted keys contain dynamic identifiers such as usernames. It still
-- enforces config-v1 key grammar and scalar encoding; the owning subsystem is
-- responsible for its stronger semantic validation before calling this API.
-- `format_version` remains first so generated data is immediately recognisable
-- to a human inspecting it from Recovery.
function config.serializeValues(values)
    if type(values) ~= "table" then
        return nil, "Writer values must be a table."
    end

    local keys, keyError = sortedStringKeys(values)

    if keys == nil then
        return nil, keyError
    end

    if values.format_version == nil then
        return nil, "Writer values must contain format_version."
    end

    local orderedKeys = { "format_version" }

    for _, key in ipairs(keys) do
        if key ~= "format_version" then
            orderedKeys[#orderedKeys + 1] = key
        end
    end

    local lines = {}

    for _, key in ipairs(orderedKeys) do
        if not isValidKey(key) then
            return nil, "Writer received invalid key '" .. key .. "'"
        end

        local encoded, encodeError = encodeScalar(values[key])

        if encoded == nil then
            return nil, "Unable to encode '" .. key .. "': " .. encodeError
        end

        lines[#lines + 1] = key .. " = " .. encoded
    end

    return table.concat(lines, "\n") .. "\n", nil
end

-- Produce canonical config v1 text. `format_version` is written first, then
-- all remaining keys alphabetically. Programmatic writes therefore preserve
-- values, not comments or the user's original spacing/order.
function config.serialize(values, schema)
    local validated, warnings, validationError = config.validate(
        values,
        schema,
        "<writer>"
    )

    if validated == nil then
        return nil, warnings, validationError
    end

    local keys, keyError = sortedStringKeys(validated)

    if keys == nil then
        return nil, warnings, keyError
    end

    local orderedKeys = { "format_version" }

    for _, key in ipairs(keys) do
        if key ~= "format_version" then
            orderedKeys[#orderedKeys + 1] = key
        end
    end

    local lines = {}

    for _, key in ipairs(orderedKeys) do
        if not isValidKey(key) then
            return nil, warnings, "Writer received invalid key '" .. key .. "'"
        end

        local encoded, encodeError = encodeScalar(validated[key])

        if encoded == nil then
            return nil, warnings,
                "Unable to encode '" .. key .. "': " .. encodeError
        end

        lines[#lines + 1] = key .. " = " .. encoded
    end

    return table.concat(lines, "\n") .. "\n", warnings, nil
end

local function pathExists(path)
    local callSucceeded, existsOrError = pcall(fs.exists, path)

    if not callSucceeded then
        return nil, "Unable to inspect " .. path .. ": " ..
            tostring(existsOrError)
    end

    if type(existsOrError) ~= "boolean" then
        return nil, "Filesystem returned invalid existence state for " .. path
    end

    return existsOrError, nil
end

local function pathIsDirectory(path)
    local callSucceeded, isDirectoryOrError = pcall(fs.isDir, path)

    if not callSucceeded then
        return nil, "Unable to inspect " .. path .. ": " ..
            tostring(isDirectoryOrError)
    end

    if type(isDirectoryOrError) ~= "boolean" then
        return nil, "Filesystem returned invalid directory state for " .. path
    end

    return isDirectoryOrError, nil
end

local function deletePathIfPresent(path)
    local exists, existsError = pathExists(path)

    if exists == nil then
        return false, existsError
    end

    if not exists then
        return true, nil
    end

    local deleteSucceeded, deleteError = pcall(fs.delete, path)

    if not deleteSucceeded then
        return false, "Unable to delete " .. path .. ": " ..
            tostring(deleteError)
    end

    local remains, verifyError = pathExists(path)

    if remains == nil then
        return false, verifyError
    end

    if remains then
        return false, "Path still exists after deletion: " .. path
    end

    return true, nil
end

local function movePath(sourcePath, targetPath)
    local moveSucceeded, moveError = pcall(
        fs.move,
        sourcePath,
        targetPath
    )

    if not moveSucceeded then
        return false, "Unable to move " .. sourcePath .. " to " ..
            targetPath .. ": " .. tostring(moveError)
    end

    local sourceRemains, sourceError = pathExists(sourcePath)

    if sourceRemains == nil then
        return false, sourceError
    end

    local targetExists, targetError = pathExists(targetPath)

    if targetExists == nil then
        return false, targetError
    end

    if sourceRemains or not targetExists then
        return false, "Filesystem did not complete move from " .. sourcePath ..
            " to " .. targetPath
    end

    return true, nil
end

-- Read a small configuration file completely and close its CC:T file handle.
-- Each method call is protected so unreadable user data becomes a normal load
-- failure rather than an uncontrolled boot exception.
local function readConfigText(path)
    local exists, existsError = pathExists(path)

    if exists == nil then
        return nil, existsError
    end

    if not exists then
        return nil, "Configuration file is missing: " .. path
    end

    local isDirectory, directoryError = pathIsDirectory(path)

    if isDirectory == nil then
        return nil, directoryError
    end

    if isDirectory then
        return nil, "Configuration path is a directory: " .. path
    end

    local sizeSucceeded, sizeOrError = pcall(fs.getSize, path)

    if not sizeSucceeded or type(sizeOrError) ~= "number" then
        return nil, "Unable to determine configuration size for " .. path ..
            ": " .. tostring(sizeOrError)
    end

    if sizeOrError > MAXIMUM_CONFIG_BYTES then
        return nil, "Configuration file exceeds 64 KiB: " .. path
    end

    local openSucceeded, fileOrError, openError = pcall(fs.open, path, "r")

    if not openSucceeded then
        return nil, "Unable to open " .. path .. ": " ..
            tostring(fileOrError)
    end

    if fileOrError == nil then
        return nil, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local file = fileOrError
    local readSucceeded, textOrError = pcall(file.readAll)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        return nil, "Unable to read " .. path .. ": " ..
            tostring(textOrError)
    end

    if not closeSucceeded then
        return nil, "Unable to close " .. path .. ": " ..
            tostring(closeError)
    end

    if type(textOrError) ~= "string" then
        return nil, "Configuration file did not contain text: " .. path
    end

    if #textOrError > MAXIMUM_CONFIG_BYTES then
        return nil, "Configuration file exceeds 64 KiB: " .. path
    end

    return textOrError, nil
end

-- Expose strict bounded reading for security-sensitive config-v1 consumers.
-- Unlike `config.load`, this function never substitutes defaults: a missing,
-- unreadable, oversized, or non-text file returns nil and its exact diagnostic.
-- The caller still parses and validates the returned text according to the
-- database contract it owns.
function config.readText(path)
    if type(path) ~= "string" or path == "" then
        return nil, "Configuration path must be a non-empty string."
    end

    return readConfigText(path)
end

local function defaultsForFailedLoad(path, schema, reason, warnings)
    local defaults, defaultsError = config.defaults(schema)

    if defaults == nil then
        error(defaultsError, 0)
    end

    local loadWarnings = warnings or {}
    loadWarnings[#loadWarnings + 1] = reason

    return defaults, loadWarnings, {
        source = path,
        loaded = false,
        usedWholeFileDefaults = true,
    }
end

-- Load and validate one user-editable configuration file.
--
-- Missing, unreadable, oversized, malformed, and unsupported-format files all
-- return safe schema defaults with warnings. Invalid individual known values
-- are replaced during validation while other usable values remain active. A
-- broken schema is a programmer/core error and is raised deliberately.
function config.load(path, schema)
    if type(path) ~= "string" or path == "" then
        error("Configuration path must be a non-empty string.", 0)
    end

    local defaults, schemaError = config.defaults(schema)

    if defaults == nil then
        error(schemaError, 0)
    end

    local text, readError = readConfigText(path)

    if text == nil then
        return defaultsForFailedLoad(path, schema, readError)
    end

    local parsed, parseError = config.parse(text, path)

    if parsed == nil then
        return defaultsForFailedLoad(path, schema, parseError)
    end

    local validated, warnings, validationError = config.validate(
        parsed,
        schema,
        path
    )

    if validated == nil then
        return defaultsForFailedLoad(
            path,
            schema,
            validationError,
            warnings
        )
    end

    return validated, warnings, {
        source = path,
        loaded = true,
        usedWholeFileDefaults = false,
    }
end

local function writeCompleteTemporaryFile(path, contents)
    local openSucceeded, fileOrError, openError = pcall(fs.open, path, "w")

    if not openSucceeded then
        return false, "Unable to open temporary file " .. path .. ": " ..
            tostring(fileOrError)
    end

    if fileOrError == nil then
        return false, "Unable to open temporary file " .. path .. ": " ..
            tostring(openError)
    end

    local file = fileOrError
    local writeSucceeded, writeError = pcall(file.write, contents)
    local closeSucceeded, closeError = pcall(file.close)

    if not writeSucceeded then
        return false, "Unable to write temporary file " .. path .. ": " ..
            tostring(writeError)
    end

    if not closeSucceeded then
        return false, "Unable to close temporary file " .. path .. ": " ..
            tostring(closeError)
    end

    return true, nil
end

-- Restore a moved original after installing the completed temporary file
-- fails. If a partial target appeared, it is removed first. Even when restore
-- cannot finish, the backup is retained instead of deleting the user's data.
local function restoreBackup(targetPath, backupPath)
    local targetExists, targetError = pathExists(targetPath)

    if targetExists == nil then
        return false, targetError
    end

    if targetExists then
        local deleted, deleteError = deletePathIfPresent(targetPath)

        if not deleted then
            return false, deleteError
        end
    end

    return movePath(backupPath, targetPath)
end

-- Canonically write configuration through a best-effort replacement
-- transaction. The complete `.tmp` file is written and closed before the old
-- target moves to `.bak`. A failed final move attempts to restore that backup;
-- successful replacement removes both reserved artifacts.
--
-- Returns `true, warnings, nil` on success, or `false, warnings, reason` on
-- failure. Filesystem exceptions are converted into those return values.
local function writeSerialized(path, contents, warnings)
    if type(path) ~= "string" or path == "" then
        return false, warnings, "Configuration path must be a non-empty string."
    end

    if #contents > MAXIMUM_CONFIG_BYTES then
        return false, warnings, "Generated configuration exceeds 64 KiB."
    end

    local temporaryPath = path .. TEMPORARY_SUFFIX
    local backupPath = path .. BACKUP_SUFFIX
    local targetExists, targetError = pathExists(path)

    if targetExists == nil then
        return false, warnings, targetError
    end

    if targetExists then
        local targetIsDirectory, directoryError = pathIsDirectory(path)

        if targetIsDirectory == nil then
            return false, warnings, directoryError
        end

        if targetIsDirectory then
            return false, warnings,
                "Configuration target is a directory: " .. path
        end
    end

    local temporaryRemoved, temporaryRemoveError =
        deletePathIfPresent(temporaryPath)

    if not temporaryRemoved then
        return false, warnings, temporaryRemoveError
    end

    local temporaryWritten, temporaryWriteError =
        writeCompleteTemporaryFile(temporaryPath, contents)

    if not temporaryWritten then
        deletePathIfPresent(temporaryPath)
        return false, warnings, temporaryWriteError
    end

    local backupExists, backupInspectError = pathExists(backupPath)

    if backupExists == nil then
        deletePathIfPresent(temporaryPath)
        return false, warnings, backupInspectError
    end

    -- If a previous failed transaction left only a backup, it may be the last
    -- copy of the user's configuration. Refuse to erase it automatically.
    if backupExists and not targetExists then
        deletePathIfPresent(temporaryPath)
        return false, warnings,
            "Configuration target is missing while backup is retained at " ..
                backupPath
    end

    local backupRemoved, backupRemoveError = deletePathIfPresent(backupPath)

    if not backupRemoved then
        deletePathIfPresent(temporaryPath)
        return false, warnings, backupRemoveError
    end

    local originalMoved = false

    if targetExists then
        local moved, moveError = movePath(path, backupPath)

        if not moved then
            -- A filesystem implementation could move the original and then
            -- fail while reporting/verifying the operation. If the backup is
            -- visibly present and the target absent, restoration is still
            -- practical and must be attempted before returning the failure.
            local backupExists = pathExists(backupPath)
            local targetStillExists = pathExists(path)

            if backupExists == true and targetStillExists == false then
                local restored, restoreError = restoreBackup(path, backupPath)

                if restored then
                    moveError = moveError ..
                        "; original configuration restored"
                else
                    moveError = moveError ..
                        "; unable to restore original: " ..
                        tostring(restoreError) ..
                        "; backup retained at " .. backupPath
                end
            end

            deletePathIfPresent(temporaryPath)
            return false, warnings, moveError
        end

        originalMoved = true
    end

    local installed, installError = movePath(temporaryPath, path)

    if not installed then
        local failure = installError

        if originalMoved then
            local restored, restoreError = restoreBackup(path, backupPath)

            if restored then
                failure = failure .. "; original configuration restored"
            else
                failure = failure .. "; unable to restore original: " ..
                    tostring(restoreError) .. "; backup retained at " ..
                    backupPath
            end
        end

        deletePathIfPresent(temporaryPath)
        return false, warnings, failure
    end

    local temporaryCleaned, temporaryCleanupError =
        deletePathIfPresent(temporaryPath)

    if not temporaryCleaned then
        return false, warnings, temporaryCleanupError
    end

    if originalMoved then
        local backupCleaned, backupCleanupError =
            deletePathIfPresent(backupPath)

        if not backupCleaned then
            return false, warnings, backupCleanupError
        end
    end

    return true, warnings, nil
end


function config.write(path, values, schema)
    local contents, warnings, serializeError = config.serialize(values, schema)

    if contents == nil then
        return false, warnings, serializeError
    end

    return writeSerialized(path, contents, warnings)
end

-- Write a semantically pre-validated dynamic config-v1 table through the same
-- `.tmp`/`.bak` replacement transaction used by ordinary configuration. This
-- avoids duplicating recovery-sensitive filesystem logic in users.lua.
function config.writeValues(path, values)
    local contents, serializeError = config.serializeValues(values)

    if contents == nil then
        return false, serializeError
    end

    local succeeded, _, writeError = writeSerialized(path, contents, {})

    return succeeded, writeError
end

return config
