-- DICK/OS minimal persistent logger
-- Version: 0.1.0-unstable

-- This module owns the current log destinations. Keeping their paths and
-- size limits together prevents each normal component from inventing a
-- slightly different rotation policy. Authentication now has its own smaller
-- target; DickNet remains absent until that subsystem actually exists.
local LOG_TARGETS = {
    boot = {
        path = "/dickos/var/log/boot.log",
        maximumBytes = 64 * 1024,
    },
    system = {
        path = "/dickos/var/log/system.log",
        maximumBytes = 128 * 1024,
    },
    auth = {
        path = "/dickos/var/log/auth.log",
        maximumBytes = 64 * 1024,
    },
}

local VALID_LEVELS = {
    DEBUG = true,
    INFO = true,
    WARN = true,
    ERROR = true,
    CRITICAL = true,
}

-- A log record must stay on one physical line. Lua's `string.gsub` replaces
-- embedded carriage returns or newlines in diagnostics with a visible
-- separator, preserving the error text without letting it imitate additional
-- records. `tostring` also makes non-string error values safe to record.
local function sanitizeField(value)
    local text = tostring(value)

    return string.gsub(text, "[\r\n]+", " | ")
end

-- CC:T's `os.epoch("utc")` returns Unix epoch milliseconds. Dividing by 1000
-- gives the seconds accepted by `os.date`; the leading `!` requests UTC rather
-- than the Minecraft server's local timezone. The trailing Z therefore has
-- its standard meaning: this timestamp is expressed in UTC.
local function currentUTCTimestamp()
    local epochSeconds = os.epoch("utc") / 1000

    return os.date("!%Y-%m-%dT%H:%M:%SZ", epochSeconds)
end

-- Rotate one active log before an append would make it exceed its configured
-- bound. Only one previous file is retained: an existing `.1` is deleted and
-- the current active file is moved into its place. CC:T filesystem functions
-- may raise errors, but this helper is always called inside `pcall` below, so
-- a full or damaged filesystem can only lose diagnostics, never stop boot.
local function rotateIfNeeded(target, pendingBytes)
    if not fs.exists(target.path) then
        return
    end

    local currentBytes = fs.getSize(target.path)

    if currentBytes + pendingBytes <= target.maximumBytes then
        return
    end

    local rotatedPath = target.path .. ".1"

    if fs.exists(rotatedPath) then
        fs.delete(rotatedPath)
    end

    fs.move(target.path, rotatedPath)
end

-- Perform one append and report whether both writing and closing succeeded.
-- `fs.open` returns a CC:T file handle or nil plus an error. Its methods are
-- protected separately so the handle is still closed after a write error and
-- buffered data is given a chance to reach the filesystem.
local function appendRecord(target, record)
    local truncationSuffix = " [TRUNCATED]"

    -- Rotation bounds the number of files, while this check handles the rarer
    -- case where one error value is itself larger than the whole active log.
    -- Truncating only such an oversized record prevents one diagnostic from
    -- defeating the storage bound. One byte is reserved for `writeLine`'s
    -- trailing newline.
    if #record + 1 > target.maximumBytes then
        local retainedBytes =
            target.maximumBytes - #truncationSuffix - 1

        record = string.sub(record, 1, retainedBytes) .. truncationSuffix
    end

    rotateIfNeeded(target, #record + 1)

    local file = fs.open(target.path, "a")

    if file == nil then
        return false
    end

    local writeSucceeded = pcall(file.writeLine, record)
    local closeSucceeded = pcall(file.close)

    return writeSucceeded and closeSucceeded
end

-- Build and append one standard record under a final protected boundary.
-- `pcall` returns false instead of propagating any timestamp, rotation, open,
-- write, or close error. Callers may inspect the boolean for diagnostics, but
-- normal boot logic must never treat false as a boot failure.
local function writeBestEffort(target, bootID, level, component, message)
    local callSucceeded, recordWritten = pcall(function()
        local record = string.format(
            "%s [%s] [%s] [%s] %s",
            currentUTCTimestamp(),
            sanitizeField(bootID),
            level,
            sanitizeField(component),
            sanitizeField(message)
        )

        return appendRecord(target, record)
    end)

    return callSucceeded and recordWritten == true
end

local log = {}

-- Create a small logger bound to one destination and one runtime Boot ID.
--
-- `targetName` is currently `boot`, `system`, or `auth`. `runtimeContext` is the
-- explicit table owned by Stage-0. A missing or malformed context uses the
-- literal `UNKNOWN` field so init can best-effort log the compatibility error
-- before rejecting that context. The returned table contains five functions;
-- each closure remembers the selected target and Boot ID without mutable
-- module-global runtime state.
--
-- An unknown target returns nil plus a diagnostic string. Normal callers load
-- and create this logger through their own protected helper, so even a broken
-- logging module remains noncritical.
function log.create(targetName, runtimeContext)
    local target = LOG_TARGETS[targetName]

    if target == nil then
        return nil, "Unknown log target: " .. tostring(targetName)
    end

    local bootID = "UNKNOWN"

    if type(runtimeContext) == "table" and
        type(runtimeContext.bootID) == "string" then
        bootID = runtimeContext.bootID
    end

    local logger = {}

    local function writeLevel(level, component, message)
        if VALID_LEVELS[level] ~= true then
            return false
        end

        return writeBestEffort(target, bootID, level, component, message)
    end

    logger.debug = function(component, message)
        return writeLevel("DEBUG", component, message)
    end

    logger.info = function(component, message)
        return writeLevel("INFO", component, message)
    end

    logger.warn = function(component, message)
        return writeLevel("WARN", component, message)
    end

    logger.error = function(component, message)
        return writeLevel("ERROR", component, message)
    end

    logger.critical = function(component, message)
        return writeLevel("CRITICAL", component, message)
    end

    return logger, nil
end

return log
