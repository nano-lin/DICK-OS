-- DICK/OS service inventory command
-- Version: 0.1.0-unstable

local SERVICE_CLIENT_PATH = "/dickos/lib/service_client.lua"
local DEFAULT_TERMINAL_WIDTH = 51

local context, firstArgument, extraArgument = ...

local function usage()
    print("services - list discovered DICK/OS services")
    print("Usage: services")
end

if firstArgument == "--help" and extraArgument == nil then
    usage()
    return
end

if firstArgument ~= nil then
    error("Usage: services", 0)
end

if type(context) ~= "table" or
    type(context.runtimeApiVersion) ~= "number" then
    error("services requires DICK command context.", 0)
end

local function terminalWidth()
    if type(term) == "table" and type(term.getSize) == "function" then
        local succeeded, width = pcall(term.getSize)

        if succeeded and type(width) == "number" and width >= 1 then
            return math.floor(width)
        end
    end

    return DEFAULT_TERMINAL_WIDTH
end

local function clip(value, width)
    local text = tostring(value or "")

    if #text <= width then
        return text
    end

    if width <= 3 then
        return string.sub(text, 1, width)
    end

    return string.sub(text, 1, width - 3) .. "..."
end

local function pad(value, width)
    local text = clip(value, width)

    return text .. string.rep(" ", math.max(0, width - #text))
end

local function loadClient()
    local succeeded, requestFunction = pcall(function()
        local program = assert(loadfile(SERVICE_CLIENT_PATH))
        local module = program()

        if type(module) ~= "table" or type(module.request) ~= "function" then
            return nil
        end

        return module.request
    end)

    if not succeeded or type(requestFunction) ~= "function" then
        return nil
    end

    return requestFunction
end

local serviceRequest = loadClient()

if serviceRequest == nil then
    print("Service manager unavailable.")
    return
end

local response, requestError = serviceRequest("list", nil, context)

if response == nil then
    print(requestError or "Service manager unavailable.")
    return
end

if not response.ok then
    print(response.error or "Service request failed.")
    return
end

if type(response.services) ~= "table" then
    print("Service supervisor returned an invalid response.")
    return
end

if #response.services == 0 then
    print("No services installed.")
    return
end

-- Keep the three requested columns on one line even on the standard 51-cell
-- terminal. Service names are the only elastic field; state and autostart have
-- bounded vocabularies and remain fully visible.
local nameWidth = math.max(7, terminalWidth() - 22)
print(pad("SERVICE", nameWidth) .. "  " .. pad("STATE", 8) ..
    "  AUTOSTART")

table.sort(response.services, function(left, right)
    return tostring(left.name) < tostring(right.name)
end)

for _, service in ipairs(response.services) do
    if type(service) == "table" then
        print(pad(service.name, nameWidth) .. "  " ..
            pad(service.state, 8) .. "  " ..
            (service.autostart == true and "yes" or "no"))
    end
end
