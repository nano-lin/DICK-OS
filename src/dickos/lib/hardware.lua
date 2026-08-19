-- DICK/OS hardware discovery and hotplug foundation
-- Version: 0.1.0-unstable

-- This module deliberately describes hardware without wrapping peripherals.
-- Wrapped objects contain callable functions and runtime state, while a DICK/OS
-- descriptor must remain ordinary serializable data suitable for diagnostics,
-- future services, and eventual DickNet reporting.
local hardware = {}

local SUPPORTED_TYPES = {
    modem = true,
    monitor = true,
    speaker = true,
    printer = true,
    drive = true,
}

local ATTACH_EVENT = "peripheral"
local DETACH_EVENT = "peripheral_detach"

local function warningFor(name, message)
    return "Peripheral " .. tostring(name) .. ": " .. message
end

local function containsType(types, expectedType)
    for _, peripheralType in ipairs(types or {}) do
        if peripheralType == expectedType then
            return true
        end
    end

    return false
end

-- Classify one complete reported type set. A multi-type peripheral is
-- supported when at least one of its capabilities has an explicit DICK/OS v1
-- policy. Enumerability alone is not treated as driver support.
function hardware.classifySupport(types)
    if type(types) ~= "table" then
        return "unsupported"
    end

    for _, peripheralType in ipairs(types) do
        if SUPPORTED_TYPES[peripheralType] then
            return "supported"
        end
    end

    return "unsupported"
end

-- Query the small display state associated with a type set.
--
-- Modems are the only v1 device with a meaningful subtype: their public
-- `isWireless` method distinguishes wireless from wired. `peripheral.call`
-- crosses into external/modded code, so only that exact boundary is protected
-- with `pcall`. Other attached devices are simply online.
function hardware.describeState(name, types)
    if type(name) ~= "string" or type(types) ~= "table" then
        return "unknown", "invalid device name or type set"
    end

    if containsType(types, "modem") then
        if type(peripheral) ~= "table" or
            type(peripheral.call) ~= "function" then
            return "unknown", "peripheral.call is unavailable"
        end

        local callSucceeded, wirelessOrError = pcall(
            peripheral.call,
            name,
            "isWireless"
        )

        if not callSucceeded then
            return "unknown", "modem state query failed: " ..
                tostring(wirelessOrError)
        end

        if type(wirelessOrError) ~= "boolean" then
            return "unknown", "modem state query returned a non-boolean value"
        end

        return wirelessOrError and "wireless" or "wired", nil
    end

    if #types == 0 then
        return "unknown", "peripheral reported no usable type"
    end

    return "online", nil
end

-- Read every type reported for one named peripheral.
--
-- Since CC:T 1.99, `peripheral.getType` returns multiple Lua values. Storing
-- the complete `pcall` result in a numerically indexed table preserves all of
-- them after the leading success boolean. The first valid value remains the
-- display/primary type, while the public `types` list is sorted and de-duplicated
-- so repeated scans are deterministic.
local function queryTypes(name)
    if type(peripheral) ~= "table" or
        type(peripheral.getType) ~= "function" then
        return {}, "unknown", "peripheral.getType is unavailable"
    end

    local results = table.pack(pcall(peripheral.getType, name))

    if results[1] ~= true then
        return {}, "unknown", "type query failed: " .. tostring(results[2])
    end

    local primaryType = nil
    local seenTypes = {}
    local types = {}

    for resultIndex = 2, results.n do
        local peripheralType = results[resultIndex]

        if type(peripheralType) == "string" and peripheralType ~= "" then
            if primaryType == nil then
                primaryType = peripheralType
            end

            if not seenTypes[peripheralType] then
                seenTypes[peripheralType] = true
                types[#types + 1] = peripheralType
            end
        end
    end

    table.sort(types)

    if primaryType == nil then
        return types, "unknown", "peripheral reported no usable type"
    end

    return types, primaryType, nil
end

-- Describe one opaque peripheral name using only public CC:T calls.
--
-- Returns a descriptor, a warning list, and an optional fatal argument/API
-- error. A device which disappears after enumeration returns no descriptor;
-- a device whose type or modem query fails remains visible with safe
-- `unknown` fields so one broken addon cannot hide healthy hardware.
function hardware.describe(name)
    if type(name) ~= "string" or name == "" then
        return nil, {}, "device name must be a non-empty string"
    end

    local warnings = {}

    if type(peripheral) ~= "table" or
        type(peripheral.isPresent) ~= "function" then
        return nil, warnings, "peripheral.isPresent is unavailable"
    end

    local presenceSucceeded, presentOrError = pcall(
        peripheral.isPresent,
        name
    )

    if not presenceSucceeded then
        warnings[#warnings + 1] = warningFor(
            name,
            "presence query failed: " .. tostring(presentOrError)
        )
    elseif presentOrError == false then
        return nil, warnings, nil
    elseif presentOrError ~= true then
        warnings[#warnings + 1] = warningFor(
            name,
            "presence query returned a non-boolean value"
        )
    end

    local types, primaryType, typeWarning = queryTypes(name)

    if typeWarning ~= nil then
        warnings[#warnings + 1] = warningFor(name, typeWarning)
    end

    local state, stateWarning = hardware.describeState(name, types)

    if stateWarning ~= nil and stateWarning ~= typeWarning then
        warnings[#warnings + 1] = warningFor(name, stateWarning)
    end

    return {
        descriptorVersion = 1,
        name = name,
        types = types,
        primaryType = primaryType,
        state = state,
        support = hardware.classifySupport(types),
    }, warnings, nil
end

-- Enumerate the live topology and return name-sorted descriptor data.
--
-- `peripheral.getNames` includes both local sides and names visible through a
-- wired modem network. Names are never interpreted as sides. A complete API
-- failure returns nil plus a clear error, which is different from a successful
-- empty descriptor list.
function hardware.scan()
    if type(peripheral) ~= "table" or
        type(peripheral.getNames) ~= "function" then
        return nil, {}, "peripheral.getNames is unavailable"
    end

    local namesSucceeded, namesOrError = pcall(peripheral.getNames)

    if not namesSucceeded then
        return nil, {}, "peripheral enumeration failed: " ..
            tostring(namesOrError)
    end

    if type(namesOrError) ~= "table" then
        return nil, {}, "peripheral enumeration returned a non-table value"
    end

    local names = {}
    local seenNames = {}
    local warnings = {}

    for _, name in ipairs(namesOrError) do
        if type(name) == "string" and name ~= "" then
            if not seenNames[name] then
                seenNames[name] = true
                names[#names + 1] = name
            end
        else
            warnings[#warnings + 1] =
                "Peripheral enumeration returned an invalid device name"
        end
    end

    table.sort(names)

    local descriptors = {}

    for _, name in ipairs(names) do
        local descriptor, deviceWarnings, describeError =
            hardware.describe(name)

        for _, warning in ipairs(deviceWarnings) do
            warnings[#warnings + 1] = warning
        end

        if describeError ~= nil then
            warnings[#warnings + 1] = warningFor(name, describeError)
        elseif descriptor ~= nil then
            descriptors[#descriptors + 1] = descriptor
        end
    end

    return descriptors, warnings, nil
end

local function descriptorSummary(descriptor)
    return string.format(
        "%s type=%s state=%s support=%s",
        descriptor.name,
        descriptor.primaryType,
        descriptor.state,
        descriptor.support
    )
end

-- Convert a CC:T hotplug event into a small data record for runtime logging.
-- Detach deliberately performs no peripheral query: CC:T fires that event
-- after the device may already be unavailable.
function hardware.describeEvent(eventName, name)
    if type(name) ~= "string" or name == "" then
        return nil, {}, "hotplug event has an invalid device name"
    end

    if eventName == DETACH_EVENT then
        return {
            kind = "detached",
            name = name,
            level = "info",
            message = "Peripheral detached: " .. name,
        }, {}, nil
    end

    if eventName ~= ATTACH_EVENT then
        return nil, {}, nil
    end

    local descriptor, warnings, describeError = hardware.describe(name)

    if describeError ~= nil then
        return nil, warnings, describeError
    end

    if descriptor == nil then
        return {
            kind = "attached",
            name = name,
            level = "warn",
            message = "Peripheral attach could not be described: " .. name,
        }, warnings, nil
    end

    return {
        kind = "attached",
        name = name,
        level = descriptor.support == "supported" and
            descriptor.state ~= "unknown" and "info" or "warn",
        message = "Peripheral attached: " .. descriptorSummary(descriptor),
        descriptor = descriptor,
    }, warnings, nil
end

-- Watch only CC:T attach/detach events and forward data records to a callback.
--
-- `os.pullEventRaw` is intentional here: Ctrl+T arrives as an ordinary
-- `terminate` event and is ignored by this watcher. The session coroutine sees
-- its own copy through CC:T's `parallel` scheduler and keeps the established
-- shell/login/editor termination policy. Callback failure is isolated at that
-- small external boundary so a broken best-effort logger cannot stop watching.
function hardware.watch(callback)
    if type(callback) ~= "function" then
        error("hardware watcher requires an event callback", 0)
    end

    if type(os) ~= "table" or type(os.pullEventRaw) ~= "function" then
        error("hardware watcher requires os.pullEventRaw", 0)
    end

    while true do
        local eventName, name = os.pullEventRaw()

        if eventName == ATTACH_EVENT or eventName == DETACH_EVENT then
            local eventRecord, warnings, eventError =
                hardware.describeEvent(eventName, name)

            pcall(callback, eventRecord, warnings, eventError)
        end
    end
end

return hardware
