-- DICK/OS Installer
-- Version: 0.1.0-unstable

local VERSION = "0.1.0-unstable"

local MiB = 1024 * 1024
local MIN_STORAGE = 4 * MiB
local RECOMMENDED_STORAGE = 16 * MiB

local function setColor(color)
    if term.isColor() then
        term.setTextColor(color)
    end
end

local function resetColor()
    if term.isColor() then
        term.setTextColor(colors.white)
    end
end

local function ok(message)
    setColor(colors.lime)
    write("[ OK ] ")
    resetColor()
    print(message)
end

local function info(message)
    setColor(colors.lightBlue)
    write("[ .. ] ")
    resetColor()
    print(message)
end

local function fail(message)
    setColor(colors.red)
    write("[FAIL] ")
    resetColor()
    print(message)
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

print("DICK/OS " .. VERSION)
print("Distributed Infrastructure & Computer Kit")
print()
print("Installer preflight")
print("-------------------")
print()

-- Device type checks

if turtle ~= nil then
    fail("Turtles are not supported by DICK/OS.")
    return
end

if pocket ~= nil then
    fail("Pocket Computers are not supported by DICK/OS.")
    return
end

if commands ~= nil then
    fail("Command Computers are not supported by DICK/OS.")
    return
end

-- Advanced Computer check

if not term.isColor() then
    fail("Advanced Computer required.")
    return
end

ok("Advanced Computer detected")

-- CC:T identity

local ccID = os.getComputerID()
ok("CC ID: " .. tostring(ccID))

-- Storage

local capacity = fs.getCapacity("/")
local free = fs.getFreeSpace("/")

if type(capacity) ~= "number" then
    fail("Unable to determine storage capacity.")
    return
end

if type(free) ~= "number" then
    fail("Unable to determine free storage.")
    return
end

info(string.format(
    "Storage: %.2f MiB total, %.2f MiB free",
    capacity / MiB,
    free / MiB
))

if capacity < MIN_STORAGE then
    fail("DICK/OS requires at least 4 MiB of storage.")
    return
end

ok("Minimum storage requirement satisfied")

if capacity >= RECOMMENDED_STORAGE then
    ok("Recommended 16 MiB storage available")
else
    info("16 MiB storage is recommended")
end

print()
setColor(colors.lime)
print("Hardware validation PASSED")
resetColor()

print()
print("This device is compatible with DICK/OS.")
