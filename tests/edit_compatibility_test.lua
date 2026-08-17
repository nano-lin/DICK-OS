-- Host-side regression tests for the DICK/OS ROM editor compatibility boundary
-- Run with: lua tests/edit_compatibility_test.lua

local EDIT_WRAPPER_SOURCE = "src/dickos/bin/edit.lua"
local SHELL_SOURCE = "src/dickos/system/shell.lua"
local ROM_EDITOR_PATH = "/rom/programs/edit.lua"
local PACKAGE_LOADER_PATH = "rom/modules/main/cc/require.lua"
local EDITOR_DIRECTORY = "rom/programs"
local TEST_MODULE_NAME = "test.editor_dependency"
local EXPECTED_TARGET = "/dickos/home/bootstrap/test.txt"
local TEST_STOP = "__DICK_EDIT_TEST_STOP__"

local TEST_MODULE_SOURCE = [[
local compatibilityShell = shell

return {
    marker = "loaded through editor require",
    resolve = function(path)
        return compatibilityShell.resolve(path)
    end,
}
]]

local hostLoad = load
local hostLoadfile = loadfile
local hostGlobalPackage = rawget(_G, "package")
local hostGlobalRequire = rawget(_G, "require")
local hostGlobalShell = rawget(_G, "shell")

-- Give a test program ordinary desktop Lua globals while deliberately masking
-- host-provided `shell`, `require`, and `package`. A metatable `__index`
-- function runs only when a key is absent from the test environment, making
-- this a close host-side analogue of a CraftOS program before its shell injects
-- program-specific APIs.
local function inheritHostGlobalsWithoutProgramAPIs(environment)
    setmetatable(environment, {
        __index = function(_, fieldName)
            if fieldName == "shell" or fieldName == "require" or
                fieldName == "package" then
                return nil
            end

            return _G[fieldName]
        end,
    })
end

-- Stand in for CC:T's bundled `cc/require.lua` during host tests. The returned
-- `require` does real module work: it compiles TEST_MODULE_SOURCE in the editor
-- environment, executes it, and caches the returned module in `package.loaded`.
-- This ensures the regression cannot pass by merely inserting a dummy function
-- named `require`.
local function createMockPackageLoader(onMake, onModuleLoad)
    return {
        make = function(environment, directory)
            if onMake ~= nil then
                onMake(environment, directory)
            end

            local packageEnvironment = {
                loaded = {
                    _G = environment,
                },
            }
            packageEnvironment.loaded.package = packageEnvironment

            local function requireModule(moduleName)
                local alreadyLoaded = packageEnvironment.loaded[moduleName]

                if alreadyLoaded ~= nil then
                    return alreadyLoaded
                end

                if moduleName ~= TEST_MODULE_NAME then
                    error("unexpected test module: " .. tostring(moduleName), 0)
                end

                if onModuleLoad ~= nil then
                    onModuleLoad(moduleName)
                end

                local moduleProgram = assert(hostLoad(
                    TEST_MODULE_SOURCE,
                    "@/rom/modules/main/test/editor_dependency.lua",
                    "t",
                    environment
                ))
                local loadedModule = moduleProgram()
                packageEnvironment.loaded[moduleName] = loadedModule
                return loadedModule
            end

            return requireModule, packageEnvironment
        end,
    }
end

-- Execute edit.lua without a global shell, and replace the ROM program with a
-- small chunk which needs exactly the same `shell.resolve` access as the real
-- CC:T editor. This directly reproduces the Minecraft failure boundary without
-- requiring the desktop Lua runtime to contain CC:T's ROM filesystem.
local function testCompatibilityEnvironment()
    local receivedPath = nil
    local receivedEditorEnvironment = nil
    local packageEnvironmentMade = nil
    local packageDirectory = nil
    local moduleLoadCount = 0
    local wrapperEnvironment = {}

    inheritHostGlobalsWithoutProgramAPIs(wrapperEnvironment)
    wrapperEnvironment._G = wrapperEnvironment

    wrapperEnvironment.fs = {
        getDir = function(path)
            assert(path == ROM_EDITOR_PATH)
            return EDITOR_DIRECTORY
        end,
    }

    wrapperEnvironment.dofile = function(path)
        assert(path == PACKAGE_LOADER_PATH)

        return createMockPackageLoader(
            function(environment, directory)
                packageEnvironmentMade = environment
                packageDirectory = directory
            end,
            function(moduleName)
                assert(moduleName == TEST_MODULE_NAME)
                moduleLoadCount = moduleLoadCount + 1
            end
        )
    end

    wrapperEnvironment.__recordEditorPath = function(
        resolvedPath,
        compatibilityShell,
        packageEnvironment,
        moduleMarker
    )
        assert(type(compatibilityShell) == "table")
        assert(type(compatibilityShell.resolve) == "function")
        assert(compatibilityShell.openTab == nil)
        assert(compatibilityShell.switchTab == nil)
        assert(type(packageEnvironment) == "table")
        assert(moduleMarker == "loaded through editor require")

        receivedPath = resolvedPath
        assert(receivedPath == EXPECTED_TARGET)
    end

    wrapperEnvironment.loadfile = function(path, mode, environment)
        assert(path == ROM_EDITOR_PATH)
        assert(mode == "t")
        assert(type(environment) == "table")

        receivedEditorEnvironment = environment

        -- Compile a mock ROM chunk which genuinely indexes global `shell`, just
        -- as the CC:T editor does. If edit.lua omitted the supplied environment,
        -- this reproducer would fail with the original "global 'shell'" error.
        return assert(hostLoad([[
            local pathArgument = ...
            local dependency = require "test.editor_dependency"
            local cachedDependency = require "test.editor_dependency"
            assert(cachedDependency == dependency)
            assert(package.loaded["test.editor_dependency"] == dependency)

            local resolvedPath = dependency.resolve(pathArgument)
            __recordEditorPath(
                resolvedPath,
                shell,
                package,
                dependency.marker
            )
        ]], "@/rom/programs/edit.lua", "t", environment))
    end

    assert(rawget(wrapperEnvironment, "shell") == nil)
    assert(wrapperEnvironment.shell == nil)
    assert(wrapperEnvironment.require == nil)
    assert(wrapperEnvironment.package == nil)

    local wrapperProgram = assert(hostLoadfile(
        EDIT_WRAPPER_SOURCE,
        "t",
        wrapperEnvironment
    ))
    local context = {
        cwd = "/dickos/home/bootstrap",
        home = "/dickos/home/bootstrap",
    }
    local succeeded, failure = pcall(wrapperProgram, context, "~/test.txt")

    assert(succeeded, tostring(failure))
    assert(receivedPath == EXPECTED_TARGET)
    assert(packageEnvironmentMade == receivedEditorEnvironment)
    assert(packageDirectory == EDITOR_DIRECTORY)
    assert(moduleLoadCount == 1)
    assert(rawget(wrapperEnvironment, "shell") == nil)
    assert(rawget(_G, "require") == hostGlobalRequire)
    assert(rawget(_G, "package") == hostGlobalPackage)
    assert(rawget(_G, "shell") == hostGlobalShell)

    -- `_G` inside the child must describe the compatibility environment, not
    -- reveal the wrapper's parent globals. The shell-shaped object itself has
    -- one method only, which keeps the ROM editor's Run action unavailable.
    assert(receivedEditorEnvironment._G == receivedEditorEnvironment)
    assert(receivedEditorEnvironment._G.shell ==
        receivedEditorEnvironment.shell)

    local environmentFieldCount = 0

    for fieldName in pairs(receivedEditorEnvironment) do
        environmentFieldCount = environmentFieldCount + 1
        assert(fieldName == "_G" or fieldName == "shell" or
            fieldName == "require" or fieldName == "package")
    end

    assert(environmentFieldCount == 4)
    assert(type(receivedEditorEnvironment.require) == "function")
    assert(type(receivedEditorEnvironment.package) == "table")
    assert(receivedEditorEnvironment.package.loaded[TEST_MODULE_NAME].marker ==
        "loaded through editor require")

    local shellFieldCount = 0

    for fieldName in pairs(receivedEditorEnvironment.shell) do
        shellFieldCount = shellFieldCount + 1
        assert(fieldName == "resolve")
    end

    assert(shellFieldCount == 1)

    local unexpectedPathSucceeded = pcall(
        receivedEditorEnvironment.shell.resolve,
        "/outside/dick/path.lua"
    )

    assert(not unexpectedPathSucceeded)
end

-- Run the real DICK shell and real edit wrapper with only CC:T-facing APIs
-- mocked. `editorFailure` selects normal return, an ordinary editor crash, or
-- Ctrl+T's `Terminated` error. A second `pwd` command proves that each editor
-- outcome returns to the same DICK shell loop instead of escaping to Recovery
-- or a CraftOS prompt.
local function runShellScenario(editorFailure)
    local state = {
        background = nil,
        blink = nil,
        cursorX = 1,
        cursorY = 1,
        currentLine = "",
        editorEnvironment = nil,
        editorPath = nil,
        moduleLoads = 0,
        output = {},
        packageEnvironmentMade = nil,
        packageDirectory = nil,
        prompts = {},
        readCalls = 0,
        textColor = nil,
    }
    local colorsMock = {
        black = 1,
        white = 2,
        red = 3,
        lime = 4,
        lightBlue = 5,
        lightGray = 6,
    }
    local termMock = {}

    termMock.setBackgroundColor = function(color)
        state.background = color
    end

    termMock.setTextColor = function(color)
        state.textColor = color
    end

    termMock.setCursorBlink = function(blink)
        state.blink = blink
    end

    termMock.getCursorPos = function()
        return state.cursorX, state.cursorY
    end

    termMock.setCursorPos = function(x, y)
        state.cursorX = x
        state.cursorY = y

        if x == 1 then
            state.currentLine = ""
        end
    end

    termMock.write = function(value)
        local text = tostring(value)
        state.currentLine = state.currentLine .. text
        state.cursorX = state.cursorX + #text
    end

    termMock.clear = function()
        state.cursorX = 1
        state.cursorY = 1
        state.currentLine = ""
    end

    local fsMock = {}

    fsMock.exists = function(path)
        return path == "/dickos/home/bootstrap" or
            path == "/dickos/bin/edit.lua"
    end

    fsMock.isDir = function(path)
        return path == "/dickos/home/bootstrap"
    end

    fsMock.makeDir = function(path)
        error("unexpected directory creation: " .. tostring(path), 0)
    end

    fsMock.getDir = function(path)
        assert(path == ROM_EDITOR_PATH)
        return EDITOR_DIRECTORY
    end

    local shellEnvironment = {
        colors = colorsMock,
        fs = fsMock,
        term = termMock,
    }

    inheritHostGlobalsWithoutProgramAPIs(shellEnvironment)
    shellEnvironment._G = shellEnvironment

    shellEnvironment.dofile = function(path)
        assert(path == PACKAGE_LOADER_PATH)

        return createMockPackageLoader(
            function(environment, directory)
                state.packageEnvironmentMade = environment
                state.packageDirectory = directory
            end,
            function(moduleName)
                assert(moduleName == TEST_MODULE_NAME)
                state.moduleLoads = state.moduleLoads + 1
            end
        )
    end

    shellEnvironment.__runMockEditor = function(resolvedPath)
        state.editorPath = resolvedPath

        -- The outer shell must repair these values for both normal and
        -- exceptional editor exits.
        termMock.setBackgroundColor(colorsMock.red)
        termMock.setTextColor(colorsMock.lime)
        termMock.setCursorBlink(false)

        if editorFailure ~= nil then
            error(editorFailure, 0)
        end
    end

    shellEnvironment.print = function(...)
        local values = { ... }

        for index, value in ipairs(values) do
            values[index] = tostring(value)
        end

        state.output[#state.output + 1] = table.concat(values, "\t")
        state.currentLine = ""
        state.cursorX = 1
        state.cursorY = state.cursorY + 1
    end

    shellEnvironment.read = function()
        state.readCalls = state.readCalls + 1
        state.prompts[state.readCalls] = state.currentLine

        if state.readCalls == 1 then
            state.currentLine = ""
            state.cursorX = 1
            state.cursorY = state.cursorY + 1
            return "edit ~/test.txt"
        elseif state.readCalls == 2 then
            -- The editor deliberately damages presentation state before either
            -- returning or raising. The next DICK prompt must already have
            -- restored the shell-owned terminal contract.
            assert(state.background == colorsMock.black)
            assert(state.textColor == colorsMock.white)
            assert(state.blink == true)

            state.currentLine = ""
            state.cursorX = 1
            state.cursorY = state.cursorY + 1
            return "pwd"
        end

        error(TEST_STOP, 0)
    end

    shellEnvironment.loadfile = function(path, mode, environment)
        if path == "/dickos/lib/log.lua" then
            return nil, "logger intentionally absent in edit regression test"
        end

        if path == "/dickos/bin/edit.lua" then
            assert(mode == nil)
            return hostLoadfile(EDIT_WRAPPER_SOURCE, "t", shellEnvironment)
        end

        if path == ROM_EDITOR_PATH then
            assert(mode == "t")
            assert(type(environment) == "table")
            state.editorEnvironment = environment

            return assert(hostLoad([[
                local pathArgument = ...
                local dependency = require "test.editor_dependency"
                local resolvedPath = dependency.resolve(pathArgument)
                __runMockEditor(resolvedPath)
            ]], "@/rom/programs/edit.lua", "t", environment))
        end

        error("unexpected loadfile path: " .. tostring(path), 0)
    end

    assert(rawget(shellEnvironment, "shell") == nil)
    assert(shellEnvironment.shell == nil)
    assert(shellEnvironment.require == nil)
    assert(shellEnvironment.package == nil)

    local shellProgram = assert(hostLoadfile(
        SHELL_SOURCE,
        "t",
        shellEnvironment
    ))
    local sessionContext = {
        runtimeApiVersion = 1,
        bootID = "B-EDITTEST",
        version = "0.1.0-unstable",
        hostname = "test-host",
        machineID = "DCK-C-1-TEST",
        user = "bootstrap",
        home = "/dickos/home/bootstrap",
    }
    local shellSucceeded, shellError = pcall(shellProgram, sessionContext)

    assert(not shellSucceeded)
    assert(string.find(tostring(shellError), TEST_STOP, 1, true) ~= nil)
    assert(state.editorPath == EXPECTED_TARGET)
    assert(state.packageEnvironmentMade == state.editorEnvironment)
    assert(state.packageDirectory == EDITOR_DIRECTORY)
    assert(state.moduleLoads == 1)
    assert(state.readCalls == 3)
    assert(state.prompts[1] == "bootstrap@test-host:~$ ")
    assert(state.prompts[2] == "bootstrap@test-host:~$ ")
    assert(rawget(shellEnvironment, "shell") == nil)
    assert(state.editorEnvironment.shell.openTab == nil)
    assert(state.editorEnvironment.shell.switchTab == nil)

    return table.concat(state.output, "\n")
end

testCompatibilityEnvironment()

local normalOutput = runShellScenario(nil)
assert(string.find(normalOutput, EXPECTED_TARGET, 1, true) == nil)
assert(string.find(normalOutput, "/dickos/home/bootstrap", 1, true) ~= nil)

local failedOutput = runShellScenario("simulated ROM editor failure")
assert(string.find(failedOutput, "Command failed:", 1, true) ~= nil)
assert(string.find(failedOutput, "simulated ROM editor failure", 1, true) ~= nil)
assert(string.find(failedOutput, "/dickos/home/bootstrap", 1, true) ~= nil)
assert(string.find(failedOutput, "Recovery", 1, true) == nil)

local terminatedOutput = runShellScenario("Terminated")
assert(string.find(terminatedOutput, "Command terminated.", 1, true) ~= nil)
assert(string.find(terminatedOutput, "Command failed:", 1, true) == nil)
assert(string.find(terminatedOutput, "/dickos/home/bootstrap", 1, true) ~= nil)

io.stdout:write("edit compatibility tests: PASS\n")
