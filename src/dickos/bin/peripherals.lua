-- DICK/OS live peripheral inventory command
-- Version: 0.1.0-unstable

local HARDWARE_LIBRARY_PATH = "/dickos/lib/hardware.lua"
local DEFAULT_TERMINAL_WIDTH = 51
local MINIMUM_TABLE_WIDTH = 42

local context, firstArgument, extraArgument = ...

local function usage()
    print("peripherals - list currently attached CC:T peripherals")
    print("Usage: peripherals")
end

if firstArgument == "--help" and extraArgument == nil then
    usage()
    return
end

if firstArgument ~= nil then
    error("Usage: peripherals", 0)
end

-- Native commands receive their authenticated DICK context first. Discovery
-- is read-only and deliberately does not inspect elevation fields or require
-- sudo, but rejecting a missing context catches accidental CraftOS-style use.
if type(context) ~= "table" or
    type(context.runtimeApiVersion) ~= "number" then
    error("peripherals requires DICK command context.", 0)
end

local function setTextColorBestEffort(color)
    if type(term) == "table" and type(term.setTextColor) == "function" and
        color ~= nil then
        pcall(term.setTextColor, color)
    end
end

local function readTerminalWidth()
    if type(term) ~= "table" or type(term.getSize) ~= "function" then
        return DEFAULT_TERMINAL_WIDTH
    end

    local succeeded, width = pcall(term.getSize)

    if succeeded and type(width) == "number" and width >= 1 then
        return math.floor(width)
    end

    return DEFAULT_TERMINAL_WIDTH
end

-- Clip one field before composing a row. The ellipsis consumes three ordinary
-- ASCII terminal cells, so even opaque wired/addon names cannot wrap and make
-- the remaining descriptor columns unreadable.
local function clip(text, width)
    local value = tostring(text or "")

    if #value <= width then
        return value
    end

    if width <= 3 then
        return string.sub(value, 1, width)
    end

    return string.sub(value, 1, width - 3) .. "..."
end

local function padded(text, width)
    local clipped = clip(text, width)

    return clipped .. string.rep(" ", math.max(0, width - #clipped))
end

local function reportUnavailable(reason)
    setTextColorBestEffort(type(colors) == "table" and colors.yellow or nil)
    print("Hardware discovery unavailable.")

    if reason ~= nil and tostring(reason) ~= "" then
        print("Reason: " .. clip(reason, math.max(1, readTerminalWidth() - 8)))
    end

    setTextColorBestEffort(type(colors) == "table" and colors.white or nil)
end

-- Loading a noncritical hardware module is itself protected. A missing,
-- syntactically invalid, crashing, or API-incompatible library is reported as
-- unavailable rather than misrepresented as an empty live topology.
local function loadHardwareLibrary()
    local loadSucceeded, programOrError, compileError = pcall(
        loadfile,
        HARDWARE_LIBRARY_PATH
    )

    if not loadSucceeded or type(programOrError) ~= "function" then
        local failure = loadSucceeded and compileError or programOrError

        return nil, "unable to load hardware library: " .. tostring(failure)
    end

    local runSucceeded, moduleOrError = pcall(programOrError)

    if not runSucceeded or type(moduleOrError) ~= "table" or
        type(moduleOrError.scan) ~= "function" then
        return nil, "hardware library has an invalid API"
    end

    return moduleOrError, nil
end

local hardware, hardwareError = loadHardwareLibrary()

if hardware == nil then
    reportUnavailable(hardwareError)
    return
end

-- A module runtime failure remains a clean child-command diagnostic. The
-- shared library normally isolates individual peripheral calls, but this
-- boundary also handles a damaged/replaced library without affecting shell.
local scanSucceeded, descriptors, warnings, scanError = pcall(hardware.scan)

if not scanSucceeded then
    reportUnavailable("hardware scan failed: " .. tostring(descriptors))
    return
end

if type(descriptors) ~= "table" then
    reportUnavailable(scanError or "hardware scan returned an invalid result")
    return
end

if type(warnings) ~= "table" then
    reportUnavailable("hardware scan returned an invalid warning list")
    return
end

local terminalWidth = readTerminalWidth()

if #descriptors == 0 then
    print("No peripherals detected.")
else
    if terminalWidth >= MINIMUM_TABLE_WIDTH then
        local supportWidth = 11
        local stateWidth = 8
        local typeWidth = 10
        local deviceWidth = terminalWidth - supportWidth - stateWidth -
            typeWidth - 3

        setTextColorBestEffort(
            type(colors) == "table" and colors.white or nil
        )
        print(
            padded("DEVICE", deviceWidth) .. " " ..
            padded("TYPE", typeWidth) .. " " ..
            padded("STATE", stateWidth) .. " " ..
            padded("SUPPORT", supportWidth)
        )

        for _, descriptor in ipairs(descriptors) do
            local typeText = table.concat(descriptor.types or {}, ",")

            if typeText == "" then
                typeText = descriptor.primaryType or "unknown"
            end

            local rowColor = type(colors) == "table" and colors.white or nil

            if descriptor.support ~= "supported" or
                descriptor.state == "unknown" then
                rowColor = type(colors) == "table" and colors.yellow or nil
            end

            setTextColorBestEffort(rowColor)
            print(
                padded(descriptor.name, deviceWidth) .. " " ..
                padded(typeText, typeWidth) .. " " ..
                padded(descriptor.state, stateWidth) .. " " ..
                padded(descriptor.support, supportWidth)
            )
        end
    else
        -- Full DICK/OS normally has a wider Advanced Computer terminal. This
        -- compact fallback keeps redirected/narrow host terminals readable
        -- without introducing a fullscreen UI.
        for _, descriptor in ipairs(descriptors) do
            local typeText = table.concat(descriptor.types or {}, ",")

            if typeText == "" then
                typeText = descriptor.primaryType or "unknown"
            end

            print(clip(descriptor.name, terminalWidth))
            print(clip(
                "  " .. typeText .. " | " .. descriptor.state .. " | " ..
                    descriptor.support,
                terminalWidth
            ))
        end
    end
end

if #warnings > 0 then
    setTextColorBestEffort(type(colors) == "table" and colors.yellow or nil)

    for _, warning in ipairs(warnings) do
        print(clip("Warning: " .. tostring(warning), terminalWidth))
    end
end

setTextColorBestEffort(type(colors) == "table" and colors.white or nil)
