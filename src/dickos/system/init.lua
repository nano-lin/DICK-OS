-- DICK/OS minimal init
-- Version: 0.1.0-unstable

local VERSION_PATH = "/dickos/etc/version"
local HOSTNAME_PATH = "/dickos/etc/hostname"
local MACHINE_ID_PATH = "/dickos/etc/machine-id"
local STAGE0_RESTART_RESULT = "restart"

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function ok(message)
    if term.isColor() then
        term.setTextColor(colors.lime)
    end

    write("[ OK ] ")
    term.setTextColor(colors.white)
    print(message)
end

-- Read one required metadata line from the installed filesystem.
--
-- `fs.open` is a CC:Tweaked API and returns a file handle rather than the file
-- contents. A failed open returns nil plus a diagnostic message. File-handle
-- operations may raise Lua errors, so read and close are protected separately;
-- the helper then returns either the string value or nil plus an explanation.
-- These are Lua multiple return values, allowing the caller to distinguish an
-- empty result from a failure without relying on global error state.
local function readRequiredValue(path)
    local file, openError = fs.open(path, "r")

    if file == nil then
        return nil, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local readSucceeded, valueOrError = pcall(file.readLine)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        return nil, "Unable to read " .. path .. ": " .. tostring(valueOrError)
    end

    if not closeSucceeded then
        return nil, "Unable to close " .. path .. ": " .. tostring(closeError)
    end

    if valueOrError == nil or valueOrError == "" then
        return nil, "Required metadata is empty: " .. path
    end

    return valueOrError, nil
end

-- Turn a metadata failure into an init failure. Stage-0 runs this entire file
-- through pcall, so propagating an error here does not expose CraftOS: it sends
-- the diagnostic back to Stage-0, which enters Recovery.
local function requireValue(path, description)
    local value, readError = readRequiredValue(path)

    if value == nil then
        error("Unable to load " .. description .. ": " .. readError, 0)
    end

    return value
end

prepareTerminal()

local version = requireValue(VERSION_PATH, "DICK/OS version")
local hostname = requireValue(HOSTNAME_PATH, "hostname")
local machineID = requireValue(MACHINE_ID_PATH, "machine ID")

print("DICK/OS " .. version)
print("Distributed Infrastructure & Computer Kit")
print()
ok("Stage-0 control active")
ok("Machine identity loaded")
ok("Minimal init active")
print()
print("Hostname:   " .. hostname)
print("Machine ID: " .. machineID)
print()
print("Bootstrap environment active.")
print()
print("Authentication, shell, services, and networking are not installed yet.")

-- CC:T programs cooperate through an event queue. `os.pullEventRaw` pauses
-- this process until the next event arrives, so init remains alive without a
-- CPU-burning polling loop. Unlike `os.pullEvent`, the Raw variant returns the
-- `terminate` event produced by Ctrl+T instead of immediately raising the
-- "Terminated" error.
--
-- Returning the explicit `restart` state lets Stage-0 distinguish ordinary
-- user termination from an unexpected normal return or a real Lua crash. All
-- unrelated events are deliberately ignored by this minimal init; later
-- milestones will dispatch them to real subsystems.
while true do
    local eventName = os.pullEventRaw()

    if eventName == "terminate" then
        return STAGE0_RESTART_RESULT
    end
end
