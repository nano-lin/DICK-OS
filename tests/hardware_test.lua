-- Host-side tests for DICK/OS hardware discovery descriptors
-- Run with: lua tests/hardware_test.lua

local HARDWARE_SOURCE = "src/dickos/lib/hardware.lua"
local hostLoadfile = loadfile

local topology = {}
local enumerationOrder = {}
local state = {
    callCount = 0,
    typeCount = 0,
}

local peripheralMock = {}

peripheralMock.getNames = function()
    if state.enumerationError ~= nil then
        error(state.enumerationError, 0)
    end

    local names = {}

    for index, name in ipairs(enumerationOrder) do
        names[index] = name
    end

    return names
end

peripheralMock.isPresent = function(name)
    local device = topology[name]

    if device ~= nil and device.presenceError ~= nil then
        error(device.presenceError, 0)
    end

    return device ~= nil and device.present ~= false
end

peripheralMock.getType = function(name)
    state.typeCount = state.typeCount + 1
    local device = assert(topology[name], "unknown mocked peripheral")

    if device.typeError ~= nil then
        error(device.typeError, 0)
    end

    return table.unpack(device.types or {})
end

peripheralMock.call = function(name, method)
    state.callCount = state.callCount + 1
    assert(method == "isWireless")
    local device = assert(topology[name], "unknown mocked peripheral")

    if device.stateError ~= nil then
        error(device.stateError, 0)
    end

    return device.wireless
end

local environment = {
    peripheral = peripheralMock,
}
setmetatable(environment, { __index = _G })
environment._G = environment

local hardware = assert(hostLoadfile(
    HARDWARE_SOURCE,
    "t",
    environment
))()

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function findDescriptor(descriptors, name)
    for _, descriptor in ipairs(descriptors) do
        if descriptor.name == name then
            return descriptor
        end
    end

    return nil
end

-- Recursively reject functions, userdata, threads, wrapped objects, and
-- metatables. Descriptor v1 is deliberately plain serializable Lua data.
local function assertDataOnly(value)
    local valueType = type(value)

    assert(valueType == "table" or valueType == "string" or
        valueType == "number" or valueType == "boolean" or
        valueType == "nil")

    if valueType == "table" then
        assert(getmetatable(value) == nil)

        for key, nestedValue in pairs(value) do
            assertDataOnly(key)
            assertDataOnly(nestedValue)
        end
    end
end

local descriptors, warnings, scanError = hardware.scan()
assert(type(descriptors) == "table" and #descriptors == 0)
assert(type(warnings) == "table" and #warnings == 0)
assert(scanError == nil)

topology = {
    left = { types = { "modem" }, wireless = true },
    right = { types = { "modem" }, wireless = false },
    monitor_0 = { types = { "monitor" } },
    speaker_0 = { types = { "speaker" } },
    speaker_1 = { types = { "speaker" } },
    printer_7 = { types = { "printer" } },
    drive_2 = { types = { "drive" } },
    some_addon_12 = { types = { "directgpu" } },
    chest_4 = { types = { "minecraft:chest", "inventory" } },
}
enumerationOrder = {
    "speaker_1",
    "left",
    "some_addon_12",
    "monitor_0",
    "right",
    "printer_7",
    "speaker_0",
    "drive_2",
    "chest_4",
}

descriptors, warnings, scanError = hardware.scan()
assert(scanError == nil)
assert(#warnings == 0)
assert(#descriptors == #enumerationOrder)

for descriptorIndex = 2, #descriptors do
    assert(descriptors[descriptorIndex - 1].name <
        descriptors[descriptorIndex].name)
end

local wirelessModem = assert(findDescriptor(descriptors, "left"))
assert(wirelessModem.descriptorVersion == 1)
assert(wirelessModem.primaryType == "modem")
assert(wirelessModem.state == "wireless")
assert(wirelessModem.support == "supported")

local wiredModem = assert(findDescriptor(descriptors, "right"))
assert(wiredModem.state == "wired")
assert(wiredModem.support == "supported")

for _, standardName in ipairs({
    "monitor_0",
    "speaker_0",
    "speaker_1",
    "printer_7",
    "drive_2",
}) do
    local descriptor = assert(findDescriptor(descriptors, standardName))
    assert(descriptor.state == "online")
    assert(descriptor.support == "supported")
end

local addon = assert(findDescriptor(descriptors, "some_addon_12"))
assert(addon.primaryType == "directgpu")
assert(addon.state == "online")
assert(addon.support == "unsupported")

local multiType = assert(findDescriptor(descriptors, "chest_4"))
assert(multiType.primaryType == "minecraft:chest")
assert(#multiType.types == 2)
assert(multiType.types[1] == "inventory")
assert(multiType.types[2] == "minecraft:chest")
assert(multiType.support == "unsupported")

for _, descriptor in ipairs(descriptors) do
    assertDataOnly(descriptor)
end

-- Scanning the unchanged topology produces byte-for-byte equivalent summary
-- data even though getNames supplied a deliberately non-sorted list.
local function snapshot(items)
    local lines = {}

    for _, descriptor in ipairs(items) do
        lines[#lines + 1] = table.concat({
            descriptor.name,
            descriptor.primaryType,
            table.concat(descriptor.types, ","),
            descriptor.state,
            descriptor.support,
        }, "|")
    end

    return table.concat(lines, "\n")
end

local repeatedDescriptors = assert(hardware.scan())
assert(snapshot(repeatedDescriptors) == snapshot(descriptors))

assert(hardware.classifySupport({ "monitor" }) == "supported")
assert(hardware.classifySupport({ "directgpu" }) == "unsupported")
assert(hardware.classifySupport({ "inventory", "speaker" }) == "supported")

-- Per-device failures degrade only that descriptor. A getType failure keeps
-- the opaque name with unknown fields; a modem-method failure preserves its
-- known supported type while reporting unknown state.
topology.broken_type = {
    types = { "ignored" },
    typeError = "simulated getType failure",
}
topology.broken_modem = {
    types = { "modem" },
    wireless = false,
    stateError = "simulated isWireless failure",
}
enumerationOrder[#enumerationOrder + 1] = "broken_type"
enumerationOrder[#enumerationOrder + 1] = "broken_modem"

local degradedDescriptors, degradedWarnings, degradedError = hardware.scan()
assert(degradedError == nil)
assert(#degradedDescriptors == #enumerationOrder)
assert(findDescriptor(degradedDescriptors, "monitor_0") ~= nil)

local brokenType = assert(findDescriptor(degradedDescriptors, "broken_type"))
assert(#brokenType.types == 0)
assert(brokenType.primaryType == "unknown")
assert(brokenType.state == "unknown")
assert(brokenType.support == "unsupported")

local brokenModem = assert(findDescriptor(
    degradedDescriptors,
    "broken_modem"
))
assert(brokenModem.primaryType == "modem")
assert(brokenModem.state == "unknown")
assert(brokenModem.support == "supported")

local warningText = table.concat(degradedWarnings, "\n")
assert(contains(warningText, "simulated getType failure"))
assert(contains(warningText, "simulated isWireless failure"))

state.enumerationError = "simulated getNames failure"
local unavailableDescriptors, _, unavailableError = hardware.scan()
assert(unavailableDescriptors == nil)
assert(contains(unavailableError, "simulated getNames failure"))

io.stdout:write("hardware discovery tests: PASS\n")
