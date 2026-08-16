-- DICK/OS root filesystem space report
-- Version: 0.1.0-unstable

local _, firstArgument = ...

if firstArgument == "--help" then
    print("Usage: df")
    return
end

if firstArgument ~= nil then
    error("Usage: df", 0)
end

local function formatBytes(bytes)
    local units = { "B", "KiB", "MiB", "GiB" }
    local value = tonumber(bytes) or 0
    local unitIndex = 1

    while value >= 1024 and unitIndex < #units do
        value = value / 1024
        unitIndex = unitIndex + 1
    end

    if unitIndex == 1 then
        return string.format("%d %s", value, units[unitIndex])
    end

    return string.format("%.1f %s", value, units[unitIndex])
end

-- CC:T exposes capacity and free bytes for a concrete path. Reporting only
-- `/` avoids suggesting a Unix mount table which DICK/OS does not implement.
local capacity = fs.getCapacity("/")
local free = fs.getFreeSpace("/")

if type(capacity) ~= "number" or type(free) ~= "number" then
    error("df: filesystem capacity information is unavailable.", 0)
end

local used = math.max(0, capacity - free)
print("Filesystem: /")
print("Capacity:   " .. formatBytes(capacity))
print("Used:       " .. formatBytes(used))
print("Free:       " .. formatBytes(free))
