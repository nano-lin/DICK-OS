-- Host-side tests for the DICK/OS network installer transport
-- Run with: lua tests/installer_network_test.lua

local RAW_PREFIX =
    "https://raw.githubusercontent.com/nano-lin/DICK-OS/main/"
local MIB = 1024 * 1024

local function readHostFile(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    file:close()
    return contents
end

local manifestContents = readHostFile("manifest.lua")
local manifest = assert(loadfile("manifest.lua"))()

local payloadBodies = {}
local completePayloadBytes = 0

for _, manifestFile in ipairs(manifest.files) do
    local body = readHostFile(manifestFile.source)
    payloadBodies[manifestFile.source] = body
    completePayloadBytes = completePayloadBytes + #body
end

local function contains(text, fragment)
    return string.find(text, fragment, 1, true) ~= nil
end

local function createHTTPResponse(body, statusCode, statusMessage, readError)
    local closed = false

    return {
        readAll = function()
            assert(not closed, "response was already closed")

            if readError ~= nil then
                error(readError, 0)
            end

            return body
        end,
        getResponseCode = function()
            return statusCode or 200, statusMessage or "OK"
        end,
        close = function()
            closed = true
        end,
    }
end

-- Each scenario executes the real install.lua chunk inside a table of mocked
-- CC:T globals. The mock records HTTP requests and persistent mutations, which
-- lets the tests prove ordering without changing the host repository.
local function runScenario(options)
    local state = {
        actions = {},
        directories = { ["/"] = true },
        files = {},
        openedWritePaths = {},
        output = {},
        requests = {},
        settingsSaveCalls = 0,
        settingValues = {
            ["shell.allow_disk_startup"] = true,
        },
    }

    local function recordMutation(action)
        state.actions[#state.actions + 1] = action
    end

    local fsMock = {}

    fsMock.getCapacity = function(path)
        assert(path == "/")
        return 16 * MIB
    end

    fsMock.getFreeSpace = function(path)
        assert(path == "/")
        return options.freeSpace or 8 * MIB
    end

    fsMock.exists = function(path)
        return state.directories[path] == true or state.files[path] ~= nil
    end

    fsMock.isDir = function(path)
        return state.directories[path] == true
    end

    fsMock.makeDir = function(path)
        recordMutation("mkdir:" .. path)

        -- CC:T creates missing parent directories as part of makeDir(). The
        -- mock records that behaviour so rollback sees the installed root.
        if string.sub(path, 1, 8) == "/dickos/" then
            state.directories["/dickos"] = true
        end

        state.directories[path] = true
    end

    fsMock.open = function(path, mode)
        assert(mode == "w", "unexpected filesystem mode: " .. tostring(mode))
        recordMutation("write-open:" .. path)
        state.openedWritePaths[#state.openedWritePaths + 1] = path

        if options.writeFailureTarget == path then
            return nil, "simulated write failure"
        end

        state.files[path] = ""

        return {
            write = function(contents)
                state.files[path] = contents
            end,
            close = function() end,
        }
    end

    fsMock.delete = function(path)
        recordMutation("delete:" .. path)

        if path == "/dickos" then
            local filePaths = {}
            local directoryPaths = {}

            for existingPath in pairs(state.files) do
                if string.sub(existingPath, 1, 8) == "/dickos/" then
                    filePaths[#filePaths + 1] = existingPath
                end
            end

            for existingPath in pairs(state.directories) do
                if existingPath == "/dickos" or
                    string.sub(existingPath, 1, 8) == "/dickos/" then
                    directoryPaths[#directoryPaths + 1] = existingPath
                end
            end

            for _, existingPath in ipairs(filePaths) do
                state.files[existingPath] = nil
            end

            for _, existingPath in ipairs(directoryPaths) do
                state.directories[existingPath] = nil
            end
        else
            state.files[path] = nil
            state.directories[path] = nil
        end
    end

    local settingsMock = {}

    settingsMock.getDetails = function(name)
        if name == "shell.allow_startup" then
            return { changed = false, value = true }
        end

        return { changed = true, value = state.settingValues[name] }
    end

    settingsMock.set = function(name, value)
        recordMutation("setting-set:" .. name)
        state.settingValues[name] = value
    end

    settingsMock.unset = function(name)
        recordMutation("setting-unset:" .. name)
        state.settingValues[name] = nil
    end

    settingsMock.save = function()
        state.settingsSaveCalls = state.settingsSaveCalls + 1
        recordMutation("settings-save")

        if options.failFirstSettingsSave and
            state.settingsSaveCalls == 1 then
            return false
        end

        return true
    end

    local httpMock = nil

    if not options.httpUnavailable then
        httpMock = {}

        httpMock.checkURL = function(url)
            assert(url == RAW_PREFIX .. "manifest.lua")

            if options.blockedHTTP then
                return false, "Domain not permitted"
            end

            return true
        end

        httpMock.get = function(url)
            assert(string.sub(url, 1, #RAW_PREFIX) == RAW_PREFIX)
            local source = string.sub(url, #RAW_PREFIX + 1)

            state.actions[#state.actions + 1] = "http:" .. source
            state.requests[#state.requests + 1] = source

            if options.invalidManifestResponse and source == "manifest.lua" then
                return { close = function() end }
            end

            if options.timeoutSource == source then
                return nil, "Timed out"
            end

            if options.missingSource == source then
                return nil,
                    "Not Found",
                    createHTTPResponse("", 404, "Not Found")
            end

            if source == "manifest.lua" then
                return createHTTPResponse(
                    options.manifestBody or manifestContents,
                    200,
                    "OK"
                )
            end

            local body = payloadBodies[source]

            if options.emptySource == source then
                body = ""
            end

            assert(body ~= nil, "test has no remote body for " .. source)
            return createHTTPResponse(
                body,
                200,
                "OK",
                options.readErrorSource == source and
                    "Connection closed during download" or nil
            )
        end
    end

    local inputValues = {
        "test-01",
        "nano",
        "secret",
        "secret",
        "y",
    }
    local inputIndex = 0

    local environment = {
        colors = {
            black = 1,
            white = 2,
            lime = 3,
            lightBlue = 4,
            yellow = 5,
            red = 6,
        },
        term = {
            isColor = function() return true end,
            setTextColor = function() end,
            setBackgroundColor = function() end,
            clear = function() end,
            setCursorPos = function() end,
        },
        fs = fsMock,
        settings = settingsMock,
        http = httpMock,
        os = {
            getComputerID = function() return 11 end,
            epoch = function(kind) assert(kind == "utc"); return 123456789 end,
            setComputerLabel = function() end,
        },
        print = function(...)
            local values = { ... }

            for index, value in ipairs(values) do
                values[index] = tostring(value)
            end

            state.output[#state.output + 1] = table.concat(values, "\t")
        end,
        write = function(value)
            state.output[#state.output + 1] = tostring(value)
        end,
        read = function()
            inputIndex = inputIndex + 1
            return assert(inputValues[inputIndex], "unexpected installer input")
        end,
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment

    local installerProgram = assert(loadfile("install.lua", "t", environment))
    local installerSucceeded, installerError = pcall(installerProgram)

    assert(installerSucceeded, tostring(installerError))
    state.outputText = table.concat(state.output, "\n")
    assert(not contains(state.outputText, "Installer stopped unexpectedly."))

    return state
end

local function assertNoPersistentMutation(state)
    for _, action in ipairs(state.actions) do
        assert(string.sub(action, 1, 5) == "http:",
            "unexpected mutation before abort: " .. action)
    end
end

-- The manifest must cover every current Lua payload and versioned config
-- template exactly once. The host `find` command derives this list from the
-- repository tree instead of duplicating a historical payload count.
local discoveredSources = {}
local discoveredSourceCount = 0
local sourceProcess = assert(io.popen(
    "find src -type f \\( -name '*.lua' -o -name '*.cfg' \\) -print"
))

for sourcePath in sourceProcess:lines() do
    discoveredSources[sourcePath] = true
    discoveredSourceCount = discoveredSourceCount + 1
end

assert(sourceProcess:close())
assert(#manifest.files == discoveredSourceCount)

for _, manifestFile in ipairs(manifest.files) do
    assert(discoveredSources[manifestFile.source],
        "manifest source is not current: " .. manifestFile.source)
    discoveredSources[manifestFile.source] = nil
end

assert(next(discoveredSources) == nil, "manifest omits a current source file")
assert(manifest.files[#manifest.files].source == "src/startup.lua")
assert(manifest.files[#manifest.files].target == "/startup.lua")

local expectedConfigurationTargets = {
    ["src/dickos/lib/config.lua"] = "/dickos/lib/config.lua",
    ["src/dickos/etc/system.cfg"] = "/dickos/etc/system.cfg",
    ["src/dickos/etc/network.cfg"] = "/dickos/etc/network.cfg",
    ["src/dickos/etc/services.cfg"] = "/dickos/etc/services.cfg",
}

for _, manifestFile in ipairs(manifest.files) do
    local expectedTarget = expectedConfigurationTargets[manifestFile.source]

    if expectedTarget ~= nil then
        assert(manifestFile.target == expectedTarget)
        expectedConfigurationTargets[manifestFile.source] = nil
    end
end

assert(next(expectedConfigurationTargets) == nil,
    "manifest omits a configuration payload")

local success = runScenario({})
assert(#success.requests == #manifest.files + 1)
assert(success.requests[1] == "manifest.lua")
assert(success.files["/startup.lua"] == payloadBodies["src/startup.lua"])
assert(success.openedWritePaths[#success.openedWritePaths] == "/startup.lua")
assert(success.files["/dickos/lib/config.lua"] ==
    payloadBodies["src/dickos/lib/config.lua"])
assert(success.files["/dickos/etc/system.cfg"] ==
    payloadBodies["src/dickos/etc/system.cfg"])
assert(success.files["/dickos/etc/network.cfg"] ==
    payloadBodies["src/dickos/etc/network.cfg"])
assert(success.files["/dickos/etc/services.cfg"] ==
    payloadBodies["src/dickos/etc/services.cfg"])

local lastHTTPAction = 0
local firstDeploymentAction = nil

for actionIndex, action in ipairs(success.actions) do
    if string.sub(action, 1, 5) == "http:" then
        lastHTTPAction = actionIndex
    elseif firstDeploymentAction == nil then
        firstDeploymentAction = actionIndex
    end
end

assert(firstDeploymentAction ~= nil)
assert(lastHTTPAction < firstDeploymentAction)

local missingManifest = runScenario({ missingSource = "manifest.lua" })
assertNoPersistentMutation(missingManifest)
assert(contains(missingManifest.outputText, "404 Not Found"))

local missingPayload = runScenario({
    missingSource = "src/dickos/system/shell.lua",
})
assertNoPersistentMutation(missingPayload)
assert(contains(missingPayload.outputText, "src/dickos/system/shell.lua"))
assert(contains(missingPayload.outputText, "404 Not Found"))

local timedOut = runScenario({ timeoutSource = "manifest.lua" })
assertNoPersistentMutation(timedOut)
assert(contains(timedOut.outputText, "Timed out"))

local interrupted = runScenario({
    readErrorSource = "src/dickos/system/init.lua",
})
assertNoPersistentMutation(interrupted)
assert(contains(interrupted.outputText, "Connection closed during download"))

local blocked = runScenario({ blockedHTTP = true })
assertNoPersistentMutation(blocked)
assert(#blocked.requests == 0)
assert(contains(blocked.outputText, "Domain not permitted"))

local unavailable = runScenario({ httpUnavailable = true })
assertNoPersistentMutation(unavailable)
assert(contains(unavailable.outputText, "HTTP API is unavailable"))

local malformed = runScenario({ manifestBody = "return {" })
assertNoPersistentMutation(malformed)
assert(contains(malformed.outputText, "Manifest compilation failed"))

local invalidTargetManifest = [[
return {
    manifestVersion = 1,
    version = "0.1.0-unstable",
    payloadID = "invalid-target-test",
    files = {
        {
            source = "src/dickos/system/init.lua",
            target = "/rom/evil.lua",
        },
        {
            source = "src/startup.lua",
            target = "/startup.lua",
        },
    },
}
]]
local invalidTarget = runScenario({ manifestBody = invalidTargetManifest })
assertNoPersistentMutation(invalidTarget)
assert(contains(invalidTarget.outputText, "invalid target path"))

local invalidResponse = runScenario({ invalidManifestResponse = true })
assertNoPersistentMutation(invalidResponse)
assert(contains(invalidResponse.outputText, "Invalid HTTP response handle"))

local emptyPayload = runScenario({
    emptySource = "src/dickos/bin/echo.lua",
})
assertNoPersistentMutation(emptyPayload)
assert(contains(emptyPayload.outputText, "unexpectedly empty"))

local insufficientSpace = runScenario({
    freeSpace = completePayloadBytes - 1,
})
assertNoPersistentMutation(insufficientSpace)
assert(#insufficientSpace.requests == #manifest.files + 1)
assert(contains(insufficientSpace.outputText, "Not enough free space"))

local writeFailure = runScenario({
    writeFailureTarget = "/dickos/bin/cat.lua",
})
assert(writeFailure.directories["/dickos"] == nil)
assert(writeFailure.files["/startup.lua"] == nil)
assert(contains(writeFailure.outputText, "Partial installation"))

local settingsFailure = runScenario({ failFirstSettingsSave = true })
assert(settingsFailure.directories["/dickos"] == nil)
assert(settingsFailure.files["/startup.lua"] == nil)
assert(settingsFailure.settingValues["shell.allow_startup"] == nil)
assert(settingsFailure.settingValues["shell.allow_disk_startup"] == true)

io.stdout:write("installer network tests: PASS\n")
