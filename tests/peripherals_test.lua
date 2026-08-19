-- Host-side tests for the DICK/OS peripherals command
-- Run with: lua tests/peripherals_test.lua

local COMMAND_SOURCE = "src/dickos/bin/peripherals.lua"
local HARDWARE_SOURCE = "src/dickos/lib/hardware.lua"
local INSTALLED_HARDWARE_PATH = "/dickos/lib/hardware.lua"
local hostLoadfile = loadfile

local function contains(text, fragment)
    return string.find(tostring(text), fragment, 1, true) ~= nil
end

local function runCommand(options)
    options = options or {}

    local topology = options.topology or {}
    local enumerationOrder = options.enumerationOrder or {}
    local state = {
        output = {},
        scanLoads = 0,
        filesystemMutations = 0,
    }
    local environment = {
        peripheral = {},
        print = function(value)
            state.output[#state.output + 1] = tostring(value or "")
        end,
        write = function(value)
            state.output[#state.output + 1] = tostring(value or "")
        end,
        read = function()
            error("peripherals command requested interactive input", 0)
        end,
        fs = {
            open = function()
                state.filesystemMutations = state.filesystemMutations + 1
            end,
            delete = function()
                state.filesystemMutations = state.filesystemMutations + 1
            end,
            move = function()
                state.filesystemMutations = state.filesystemMutations + 1
            end,
            makeDir = function()
                state.filesystemMutations = state.filesystemMutations + 1
            end,
        },
        term = {
            getSize = function() return options.width or 51, 19 end,
        },
    }

    if not options.withoutColors then
        environment.colors = {
            white = 1,
            yellow = 2,
        }
        environment.term.setTextColor = function() end
    end

    environment.peripheral.getNames = function()
        local copied = {}
        for index, name in ipairs(enumerationOrder) do copied[index] = name end
        return copied
    end
    environment.peripheral.isPresent = function(name)
        return topology[name] ~= nil
    end
    environment.peripheral.getType = function(name)
        return table.unpack(assert(topology[name]).types)
    end
    environment.peripheral.call = function(name, method)
        assert(method == "isWireless")
        return assert(topology[name]).wireless
    end

    setmetatable(environment, { __index = _G })
    environment._G = environment
    environment.loadfile = function(path)
        assert(path == INSTALLED_HARDWARE_PATH)
        state.scanLoads = state.scanLoads + 1

        if options.missingHardware then
            return nil, "simulated missing hardware.lua"
        end

        if options.invalidHardwareAPI then
            return function() return {} end
        end

        if options.scanFailure then
            return function()
                return {
                    scan = function()
                        error("simulated scan runtime failure", 0)
                    end,
                }
            end
        end

        return hostLoadfile(HARDWARE_SOURCE, "t", environment)
    end

    local program = assert(hostLoadfile(COMMAND_SOURCE, "t", environment))
    local context = options.context or {
        runtimeApiVersion = 1,
        bootID = "B-1234ABCD",
        user = "nano",
        uid = 1000,
        effectiveUser = "nano",
        effectiveUID = 1000,
        isAdmin = true,
        isElevated = false,
    }
    local succeeded, failure = pcall(
        program,
        context,
        table.unpack(options.arguments or {})
    )

    state.outputText = table.concat(state.output, "\n")
    return state, succeeded, failure
end

local helpState, helpSucceeded, helpFailure = runCommand({
    arguments = { "--help" },
})
assert(helpSucceeded, tostring(helpFailure))
assert(contains(helpState.outputText, "Usage: peripherals"))
assert(helpState.filesystemMutations == 0)

local zeroState, zeroSucceeded, zeroFailure = runCommand({
    withoutColors = true,
})
assert(zeroSucceeded, tostring(zeroFailure))
assert(zeroState.outputText == "No peripherals detected.")
assert(zeroState.filesystemMutations == 0)

local standardTopology = {
    left = { types = { "modem" }, wireless = true },
    monitor_0 = { types = { "monitor" } },
    speaker_3 = { types = { "speaker" } },
    gpu_0 = { types = { "directgpu" } },
    ["very_long_wired_peripheral_name_123456789"] = {
        types = { "printer" },
    },
}
local standardOrder = {
    "speaker_3",
    "very_long_wired_peripheral_name_123456789",
    "left",
    "gpu_0",
    "monitor_0",
}
local standardState, standardSucceeded, standardFailure = runCommand({
    topology = standardTopology,
    enumerationOrder = standardOrder,
})
assert(standardSucceeded, tostring(standardFailure))
assert(contains(standardState.outputText, "DEVICE"))
assert(contains(standardState.outputText, "TYPE"))
assert(contains(standardState.outputText, "STATE"))
assert(contains(standardState.outputText, "SUPPORT"))
assert(contains(standardState.outputText, "wireless"))
assert(contains(standardState.outputText, "directgpu"))
assert(contains(standardState.outputText, "unsupported"))
assert(string.find(standardState.outputText, "gpu_0", 1, true) <
    string.find(standardState.outputText, "left", 1, true))
assert(string.find(standardState.outputText, "left", 1, true) <
    string.find(standardState.outputText, "monitor_0", 1, true))

for _, line in ipairs(standardState.output) do
    assert(#line <= 51, "table row wrapped: " .. line)
end

assert(contains(standardState.outputText, "very_long_wired_..."))
assert(standardState.filesystemMutations == 0)

local narrowState, narrowSucceeded, narrowFailure = runCommand({
    topology = standardTopology,
    enumerationOrder = standardOrder,
    width = 30,
    withoutColors = true,
})
assert(narrowSucceeded, tostring(narrowFailure))
for _, line in ipairs(narrowState.output) do
    assert(#line <= 30, "compact row wrapped: " .. line)
end

local missingState, missingSucceeded, missingFailure = runCommand({
    missingHardware = true,
})
assert(missingSucceeded, tostring(missingFailure))
assert(contains(missingState.outputText, "Hardware discovery unavailable."))
assert(contains(missingState.outputText, "unable to load hardware library"))

local invalidState, invalidSucceeded, invalidFailure = runCommand({
    invalidHardwareAPI = true,
})
assert(invalidSucceeded, tostring(invalidFailure))
assert(contains(invalidState.outputText, "invalid API"))

local failedState, failedSucceeded, failedFailure = runCommand({
    scanFailure = true,
})
assert(failedSucceeded, tostring(failedFailure))
assert(contains(failedState.outputText, "Hardware discovery unavailable."))
assert(contains(failedState.outputText, "hardware scan failed"))
assert(failedState.filesystemMutations == 0)

local elevatedState, elevatedSucceeded, elevatedFailure = runCommand({
    context = {
        runtimeApiVersion = 1,
        effectiveUser = "root",
        effectiveUID = 0,
        isElevated = true,
    },
})
assert(elevatedSucceeded, tostring(elevatedFailure))
assert(elevatedState.outputText == "No peripherals detected.")

local _, argumentSucceeded, argumentFailure = runCommand({
    arguments = { "unexpected" },
})
assert(not argumentSucceeded)
assert(tostring(argumentFailure) == "Usage: peripherals")

io.stdout:write("peripherals command tests: PASS\n")
