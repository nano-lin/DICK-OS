-- DICK/OS minimal service supervisor
-- Version: 0.1.0-unstable

local SERVICES_DIRECTORY = "/dickos/services"
local SERVICES_CONFIG_PATH = "/dickos/etc/services.cfg"
local CONFIG_LIBRARY_PATH = "/dickos/lib/config.lua"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local REQUEST_EVENT = "dickd_request"
local RESPONSE_EVENT = "dickd_response"
local SERVICE_API_VERSION = 1
local EXPECTED_RUNTIME_API_VERSION = 1

local STATE_STOPPED = "STOPPED"
local STATE_STARTING = "STARTING"
local STATE_RUNNING = "RUNNING"
local STATE_FAILED = "FAILED"

local dickd = {
    serviceApiVersion = SERVICE_API_VERSION,
    requestEvent = REQUEST_EVENT,
    responseEvent = RESPONSE_EVENT,
    states = {
        STOPPED = STATE_STOPPED,
        STARTING = STATE_STARTING,
        RUNNING = STATE_RUNNING,
        FAILED = STATE_FAILED,
    },
}

local function isValidServiceName(name)
    return type(name) == "string" and
        string.match(name, "^[a-z][a-z0-9_]*$") ~= nil
end

local function sortedKeys(values)
    local keys = {}

    for key in pairs(values) do
        keys[#keys + 1] = key
    end

    table.sort(keys)
    return keys
end

-- Logging is diagnostic-only. Loading, executing, and using log.lua all stay
-- behind protected calls, because a service manager failure must not turn an
-- otherwise healthy authenticated session into Recovery.
local function createBestEffortLogger(runtimeContext)
    local succeeded, logger = pcall(function()
        local program = loadfile(LOG_LIBRARY_PATH)

        if type(program) ~= "function" then
            return nil
        end

        local logModule = program()

        if type(logModule) ~= "table" or
            type(logModule.create) ~= "function" then
            return nil
        end

        return logModule.create("system", runtimeContext)
    end)

    if not succeeded or type(logger) ~= "table" then
        return nil
    end

    return logger
end

local function logBestEffort(logger, level, message)
    if logger == nil then
        return
    end

    pcall(function()
        local method = logger[level]

        if type(method) == "function" then
            method("dickd", message)
        end
    end)
end

-- Service code is trusted operating-system code, not a security sandbox.
-- Nevertheless, background services must not corrupt the interactive shell's
-- terminal. These explicit replacements make accidental terminal I/O fail at
-- the service boundary. Inheriting the remaining public CC:T globals keeps
-- normal event, timer, filesystem, peripheral, and networking APIs available.
local function makeBlockedTerminalAPI()
    local function unavailable()
        error("service terminal access is unavailable", 0)
    end

    return setmetatable({}, {
        __index = function()
            return unavailable
        end,
        __newindex = function()
            unavailable()
        end,
    })
end

local function makeServiceEnvironment()
    local function unavailable()
        error("service terminal access is unavailable", 0)
    end

    local environment = {
        print = unavailable,
        write = unavailable,
        read = unavailable,
        term = makeBlockedTerminalAPI(),
    }

    setmetatable(environment, { __index = _G })
    environment._G = environment
    return environment
end

local function validateRuntimeContext(runtimeContext)
    if type(runtimeContext) ~= "table" or
        runtimeContext.runtimeApiVersion ~= EXPECTED_RUNTIME_API_VERSION or
        type(runtimeContext.bootID) ~= "string" or
        type(runtimeContext.version) ~= "string" or
        type(runtimeContext.hostname) ~= "string" or
        type(runtimeContext.machineID) ~= "string" then
        return nil, "dickd received an invalid runtime context"
    end

    -- Copy only the documented data fields. The supervisor never receives a
    -- session user, password, sudo cache, cwd, or another authority-bearing
    -- object from init, and therefore cannot leak one into service contexts.
    return {
        serviceApiVersion = SERVICE_API_VERSION,
        name = nil,
        runtimeApiVersion = runtimeContext.runtimeApiVersion,
        bootID = runtimeContext.bootID,
        version = runtimeContext.version,
        hostname = runtimeContext.hostname,
        machineID = runtimeContext.machineID,
    }, nil
end

local function copyServiceContext(contextTemplate, serviceName)
    return {
        serviceApiVersion = contextTemplate.serviceApiVersion,
        name = serviceName,
        runtimeApiVersion = contextTemplate.runtimeApiVersion,
        bootID = contextTemplate.bootID,
        version = contextTemplate.version,
        hostname = contextTemplate.hostname,
        machineID = contextTemplate.machineID,
    }
end

local function makeRecord(name, path, autostart)
    return {
        name = name,
        path = path,
        state = STATE_STOPPED,
        autostart = autostart == true,
        installed = true,
        failure = nil,
        module = nil,
        coroutine = nil,
        filter = nil,
        context = nil,
    }
end

local function publicSnapshot(record)
    local snapshot = {
        name = record.name,
        state = record.state,
        autostart = record.autostart == true,
    }

    if record.state == STATE_FAILED and type(record.failure) == "string" then
        snapshot.failure = record.failure
    end

    return snapshot
end

-- Filesystem methods may throw when a mount disappears during a scan. Every
-- method call is protected separately so discovery returns one controlled
-- diagnostic instead of crashing the long-lived supervisor.
local function scanServiceDirectory()
    local existsSucceeded, directoryExists = pcall(
        fs.exists,
        SERVICES_DIRECTORY
    )

    if not existsSucceeded or type(directoryExists) ~= "boolean" then
        return nil, "unable to inspect service directory"
    end

    if not directoryExists then
        return {}, nil
    end

    local directorySucceeded, isDirectory = pcall(
        fs.isDir,
        SERVICES_DIRECTORY
    )

    if not directorySucceeded or isDirectory ~= true then
        return nil, "service path is not a directory"
    end

    local listSucceeded, entries = pcall(fs.list, SERVICES_DIRECTORY)

    if not listSucceeded or type(entries) ~= "table" then
        return nil, "unable to list service directory"
    end

    local discovered = {}

    for _, entry in ipairs(entries) do
        local name = type(entry) == "string" and
            string.match(entry, "^([a-z][a-z0-9_]*)%.lua$") or nil

        if name ~= nil then
            local path = SERVICES_DIRECTORY .. "/" .. entry
            local typeSucceeded, isDirectoryEntry = pcall(fs.isDir, path)

            if typeSucceeded and isDirectoryEntry == false then
                discovered[name] = path
            end
        end
    end

    return discovered, nil
end

-- services.cfg has a dynamic namespace, so it is parsed with the shared
-- data-only config-v1 parser instead of a fixed schema. A malformed file or an
-- unsupported format disables all autostarts; a well-formed but unrelated or
-- wrongly typed entry is ignored independently so other valid services remain
-- usable.
local function loadAutostartConfiguration(logger)
    local succeeded, valuesOrError = pcall(function()
        local program = loadfile(CONFIG_LIBRARY_PATH)

        if type(program) ~= "function" then
            error("configuration library unavailable", 0)
        end

        local configModule = program()

        if type(configModule) ~= "table" or
            type(configModule.readText) ~= "function" or
            type(configModule.parse) ~= "function" then
            error("configuration library has an invalid API", 0)
        end

        local text, readError = configModule.readText(SERVICES_CONFIG_PATH)

        if text == nil then
            error(readError or "services.cfg is unavailable", 0)
        end

        local values, parseError = configModule.parse(
            text,
            SERVICES_CONFIG_PATH
        )

        if values == nil then
            error(parseError or "services.cfg is malformed", 0)
        end

        return values
    end)

    if not succeeded or type(valuesOrError) ~= "table" then
        logBestEffort(
            logger,
            "warn",
            "Service autostart configuration unavailable; no autostarts selected"
        )
        return {}
    end

    if valuesOrError.format_version ~= 1 then
        logBestEffort(
            logger,
            "warn",
            "Unsupported services.cfg format; no autostarts selected"
        )
        return {}
    end

    local autostart = {}

    for _, key in ipairs(sortedKeys(valuesOrError)) do
        if key ~= "format_version" then
            local name = string.match(
                key,
                "^service%.([a-z][a-z0-9_]*)%.autostart$"
            )
            local value = valuesOrError[key]

            if name ~= nil and type(value) == "boolean" then
                autostart[name] = value
            else
                logBestEffort(
                    logger,
                    "warn",
                    "Ignoring invalid services.cfg entry: " .. key
                )
            end
        end
    end

    return autostart
end

local Manager = {}
Manager.__index = Manager

-- Collapse every failure path into the same inert record shape. Clearing all
-- executable references here guarantees FAILED services cannot accidentally
-- be resumed by a later event while retaining only a bounded classification.
function Manager:markFailed(record, classification)
    record.state = STATE_FAILED
    record.failure = classification
    record.module = nil
    record.coroutine = nil
    record.filter = nil
    record.context = nil

    logBestEffort(
        self.logger,
        "error",
        "Service failed: " .. record.name .. " (" .. classification .. ")"
    )
end

-- Rescan updates file presence without replacing active coroutine records.
-- Removed STOPPED records disappear from listings; removed running/failed
-- records remain internally long enough for stop/restart to dispose of their
-- runtime deterministically, but are not advertised as installed services.
function Manager:discover()
    local discovered, scanError = scanServiceDirectory()

    if discovered == nil then
        logBestEffort(self.logger, "warn", scanError)
        return false, scanError
    end

    for _, record in pairs(self.records) do
        record.installed = false
    end

    for name, path in pairs(discovered) do
        local record = self.records[name]

        if record == nil then
            record = makeRecord(name, path, self.autostart[name])
            self.records[name] = record
        else
            record.path = path
            record.autostart = self.autostart[name] == true
            record.installed = true
        end
    end

    for name, record in pairs(self.records) do
        if not record.installed and record.state == STATE_STOPPED then
            self.records[name] = nil
        end
    end

    return true, nil
end

function Manager:list()
    local discovered, discoveryError = self:discover()

    if not discovered then
        return false, discoveryError
    end

    local services = {}

    for _, name in ipairs(sortedKeys(self.records)) do
        local record = self.records[name]

        if record.installed then
            services[#services + 1] = publicSnapshot(record)
        end
    end

    return true, services
end

function Manager:status(name)
    if not isValidServiceName(name) then
        return false, "Invalid service name."
    end

    local discovered, discoveryError = self:discover()

    if not discovered then
        return false, discoveryError
    end

    local record = self.records[name]

    if record == nil or not record.installed then
        return false, "Service not found."
    end

    return true, publicSnapshot(record)
end

-- Compile and execute the service source afresh on every start. No module or
-- coroutine from a previous attempt is reused, which makes restart a real
-- reload operation and keeps FAILED state from retaining broken executable
-- objects. Raw Lua errors are deliberately classified rather than exposed to
-- shell users, because arbitrary service/event payload text may be sensitive.
function Manager:loadService(record)
    if not record.installed then
        return nil, "source unavailable"
    end

    local environment = makeServiceEnvironment()
    local loadSucceeded, programOrError = pcall(
        loadfile,
        record.path,
        "t",
        environment
    )

    if not loadSucceeded or type(programOrError) ~= "function" then
        return nil, "source load error"
    end

    local runSucceeded, moduleOrError = pcall(programOrError)

    if not runSucceeded then
        return nil, "module load error"
    end

    -- Even trusted code may accidentally return a table with a throwing
    -- metatable. Read and validate both hooks inside one protected boundary,
    -- then retain a plain snapshot so later lifecycle code never re-enters an
    -- arbitrary module __index implementation.
    local validated, runFunction, stopFunction = pcall(function()
        if type(moduleOrError) ~= "table" then
            return nil, nil
        end

        local declaredRun = moduleOrError.run
        local declaredStop = moduleOrError.stop

        if type(declaredRun) ~= "function" or
            (declaredStop ~= nil and type(declaredStop) ~= "function") then
            return nil, nil
        end

        return declaredRun, declaredStop
    end)

    if not validated or type(runFunction) ~= "function" then
        return nil, "invalid service module"
    end

    return {
        run = runFunction,
        stop = stopFunction,
    }, nil
end

-- A service coroutine communicates its desired event filter through the same
-- yield contract used by os.pullEvent. Nil means all ordinary events; a string
-- selects one event. Returning is never a successful daemon exit in this v1
-- foundation, and malformed yielded filters fail only that service.
function Manager:resumeRecord(record, ...)
    local resumed, yielded = coroutine.resume(record.coroutine, ...)

    if not resumed then
        self:markFailed(record, "runtime error")
        return false
    end

    if coroutine.status(record.coroutine) == "dead" then
        self:markFailed(record, "unexpected return")
        return false
    end

    if yielded ~= nil and type(yielded) ~= "string" then
        self:markFailed(record, "invalid event filter")
        return false
    end

    record.filter = yielded
    record.state = STATE_RUNNING
    record.failure = nil
    return true
end

-- Start owns the complete STOPPED/FAILED -> STARTING -> RUNNING transition.
-- Discovery is repeated for external calls, while restart may reuse the scan
-- it just completed so removal and replacement are judged as one operation.
function Manager:start(name, skipDiscovery)
    if not isValidServiceName(name) then
        return false, "Invalid service name."
    end

    if not skipDiscovery then
        local discovered, discoveryError = self:discover()

        if not discovered then
            return false, discoveryError
        end
    end

    local record = self.records[name]

    if record == nil then
        return false, "Service not found."
    end

    if not record.installed then
        self:markFailed(record, "source unavailable")
        return false, "Service source unavailable."
    end

    if record.state == STATE_RUNNING or record.state == STATE_STARTING then
        return false, "Service is already running."
    end

    record.state = STATE_STARTING
    record.failure = nil
    record.module = nil
    record.coroutine = nil
    record.filter = nil
    record.context = nil

    logBestEffort(self.logger, "info", "Service starting: " .. name)

    local serviceModule, loadError = self:loadService(record)

    if serviceModule == nil then
        self:markFailed(record, loadError)
        return false, "Service failed to start: " .. loadError .. "."
    end

    record.module = serviceModule
    record.context = copyServiceContext(self.contextTemplate, name)
    record.coroutine = coroutine.create(function()
        return serviceModule.run(record.context)
    end)

    if not self:resumeRecord(record) then
        return false, "Service failed to start: " .. record.failure .. "."
    end

    logBestEffort(self.logger, "info", "Service running: " .. name)
    return true, publicSnapshot(record)
end

-- stop hooks are explicitly short and non-yielding in service API v1. Running
-- one in a separate coroutine lets dickd detect a yield after one resume and
-- discard that coroutine instead of suspending the entire supervisor. Hook
-- errors/yields are warnings; runtime ownership is still released and STOPPED
-- is reached deterministically.
function Manager:runStopHook(record)
    if type(record.module) ~= "table" or
        type(record.module.stop) ~= "function" then
        return nil
    end

    local hookCoroutine = coroutine.create(function()
        record.module.stop(record.context)
    end)
    local resumed = coroutine.resume(hookCoroutine)

    if not resumed then
        logBestEffort(
            self.logger,
            "warn",
            "Service stop hook failed: " .. record.name
        )
        return "stop hook failed"
    elseif coroutine.status(hookCoroutine) ~= "dead" then
        logBestEffort(
            self.logger,
            "warn",
            "Service stop hook yielded: " .. record.name
        )
        return "stop hook yielded"
    end

    return nil
end

-- Stop is idempotent for an existing record: only a live instance receives a
-- hook, but every accepted call clears executable state and ends at STOPPED.
function Manager:stop(name, skipDiscovery)
    if not isValidServiceName(name) then
        return false, "Invalid service name."
    end

    if not skipDiscovery then
        local discovered, discoveryError = self:discover()

        if not discovered then
            return false, discoveryError
        end
    end

    local record = self.records[name]

    if record == nil then
        return false, "Service not found."
    end

    local cleanupWarning = nil

    if record.state == STATE_RUNNING or record.state == STATE_STARTING then
        cleanupWarning = self:runStopHook(record)
    end

    record.state = STATE_STOPPED
    record.failure = nil
    record.module = nil
    record.coroutine = nil
    record.filter = nil
    record.context = nil

    logBestEffort(self.logger, "info", "Service stopped: " .. name)
    local snapshot = publicSnapshot(record)
    snapshot.warning = cleanupWarning
    return true, snapshot
end

-- Restart never resumes an existing coroutine. It performs disposal first and
-- routes through start's fresh load/validation path even after FAILED/STOPPED.
function Manager:restart(name)
    if not isValidServiceName(name) then
        return false, "Invalid service name."
    end

    local discovered, discoveryError = self:discover()

    if not discovered then
        return false, discoveryError
    end

    local record = self.records[name]

    if record == nil then
        return false, "Service not found."
    end

    logBestEffort(self.logger, "info", "Service restart requested: " .. name)
    local _, stopSnapshot = self:stop(name, true)
    local started, result = self:start(name, true)

    if started and type(stopSnapshot) == "table" and
        type(stopSnapshot.warning) == "string" then
        result.warning = stopSnapshot.warning
    end

    return started, result
end

local function hasRootAuthority(caller)
    return type(caller) == "table" and
        caller.isElevated == true and
        caller.effectiveUID == 0 and
        caller.effectiveUser == "root"
end

-- IPC events are a local convenience boundary, not authentication against
-- hostile trusted Lua: arbitrary code with os.queueEvent can forge tables.
-- Requiring the exact sudo-created root tuple prevents normal DICK commands
-- from mutating service state accidentally while preserving this limitation
-- honestly for the current single-computer threat model.
function Manager:handleRequest(request)
    if type(request) ~= "table" or
        type(request.requestID) ~= "string" or
        #request.requestID < 1 or #request.requestID > 128 or
        type(request.action) ~= "string" then
        return nil
    end

    local response = {
        requestID = request.requestID,
        ok = false,
    }
    local action = request.action
    local succeeded, result

    if action == "list" then
        succeeded, result = self:list()
        response.services = succeeded and result or nil
    elseif action == "status" then
        succeeded, result = self:status(request.name)
        response.service = succeeded and result or nil
    elseif action == "start" or action == "stop" or action == "restart" then
        if not hasRootAuthority(request.caller) then
            result = "Permission denied: service control requires sudo."
        else
            succeeded, result = self[action](self, request.name)
            response.service = succeeded and result or nil
        end
    else
        result = "Unsupported service request."
    end

    response.ok = succeeded == true

    if not response.ok then
        response.error = type(result) == "string" and result or
            "Service request failed."
    end

    return response
end

-- Process control traffic before ordinary dispatch. This ordering means a stop
-- request takes effect without also delivering that infrastructure event to a
-- service which happened to be awaiting all events.
function Manager:handleEvent(eventName, ...)
    if eventName == REQUEST_EVENT then
        local response = self:handleRequest(...)

        if response ~= nil then
            local queued = pcall(os.queueEvent, RESPONSE_EVENT, response)

            if not queued then
                logBestEffort(
                    self.logger,
                    "warn",
                    "Unable to queue a service response"
                )
            end
        end

        return
    end

    -- Internal request/response traffic and Ctrl+T are supervisor concerns.
    -- Services receive only ordinary events matching the filter yielded by
    -- their coroutine, so a child-command terminate cannot stop a daemon.
    if eventName == RESPONSE_EVENT or eventName == "terminate" then
        return
    end

    for _, name in ipairs(sortedKeys(self.records)) do
        local record = self.records[name]

        if record.state == STATE_RUNNING and
            (record.filter == nil or record.filter == eventName) then
            self:resumeRecord(record, eventName, ...)
        end
    end
end

-- Initialization deliberately keeps discovery/config/autostart failures local
-- to dickd. Every true entry is attempted separately, and zero installed or
-- configured services is a normal ready supervisor.
function Manager:initialize()
    local discovered, discoveryError = self:discover()

    if not discovered then
        logBestEffort(
            self.logger,
            "warn",
            "Service discovery failed: " .. tostring(discoveryError)
        )
    end

    -- Discovery comes first so configuration remains pure policy over the
    -- current filesystem view. Loading it here, rather than in create(), also
    -- keeps construction side-effect-light for focused callers and tests.
    self.autostart = loadAutostartConfiguration(self.logger)
    self:discover()

    for _, name in ipairs(sortedKeys(self.autostart)) do
        if self.autostart[name] then
            logBestEffort(
                self.logger,
                "info",
                "Autostart starting: " .. name
            )
            local started, startError = self:start(name)

            if not started then
                logBestEffort(
                    self.logger,
                    "warn",
                    "Autostart failed: " .. name .. " (" ..
                        tostring(startError) .. ")"
                )
            end
        end
    end

    self.initialized = true
    logBestEffort(self.logger, "info", "Service manager started")
end

function dickd.create(runtimeContext)
    local contextTemplate, contextError = validateRuntimeContext(runtimeContext)

    if contextTemplate == nil then
        error(contextError, 0)
    end

    local logger = createBestEffortLogger(runtimeContext)
    local manager = setmetatable({
        records = {},
        contextTemplate = contextTemplate,
        logger = logger,
        autostart = {},
        initialized = false,
    }, Manager)

    return manager
end

function dickd.run(runtimeContext)
    local manager = dickd.create(runtimeContext)
    manager:initialize()

    while true do
        -- pullEventRaw keeps terminate visible so dickd can consume its own
        -- event-queue copy without raising. The parallel session copy still
        -- follows the established login/shell/editor Ctrl+T policy.
        manager:handleEvent(os.pullEventRaw())
    end
end

return dickd
