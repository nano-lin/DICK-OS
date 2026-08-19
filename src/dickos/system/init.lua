-- DICK/OS minimal init
-- Version: 0.1.0-unstable

local VERSION_PATH = "/dickos/etc/version"
local HOSTNAME_PATH = "/dickos/etc/hostname"
local MACHINE_ID_PATH = "/dickos/etc/machine-id"
local DICKFETCH_PATH = "/dickos/bin/dickfetch.lua"
local SHELL_PATH = "/dickos/system/shell.lua"
local LOGIN_PATH = "/dickos/system/login.lua"
local AUTH_LIBRARY_PATH = "/dickos/lib/auth.lua"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local CONFIG_LIBRARY_PATH = "/dickos/lib/config.lua"
local SYSTEM_CONFIG_PATH = "/dickos/etc/system.cfg"
local STAGE0_RESTART_RESULT = "restart"
local EXPECTED_RUNTIME_API_VERSION = 1

-- Schemas are ordinary data tables consumed by the shared config library.
-- Init owns these two current system settings because it applies the boot
-- setting and passes only the history limit needed by the shell. Neither the
-- full parsed table nor unrelated future configuration enters runtimeContext.
local SYSTEM_CONFIG_SCHEMA = {
    formatVersion = 1,
    entries = {
        ["format_version"] = {
            type = "integer",
            default = 1,
        },
        ["boot.cosmetic_delay"] = {
            type = "boolean",
            default = true,
        },
        ["shell.history_limit"] = {
            type = "integer",
            default = 64,
            min = 0,
            max = 256,
        },
    },
}

-- Full DICK/OS supports the Advanced Computer, so its colour terminal is a
-- platform baseline rather than an optional skin. These constants begin a
-- shared visual vocabulary: black for normal operation, cyan for activity,
-- lime for success, white for primary text, and gray for secondary structure.
local BOOT_BACKGROUND = colors.black
local PRIMARY_TEXT = colors.white
local SECONDARY_TEXT = colors.lightGray
local SEPARATOR_COLOR = colors.gray
local INFORMATION_COLOR = colors.lightBlue
local SUCCESS_COLOR = colors.lime
local WARNING_COLOR = colors.yellow

-- CC:T's bytes 128 through 159 are native 2-by-3-cell drawing characters.
-- `string.char` creates one such byte, while pasted UTF-8 box characters would
-- become several unrelated terminal glyphs. Some entries use colour inversion
-- because CC:T stores one shape from each foreground/background complement.
local BOX_HORIZONTAL = { character = string.char(140), invertColors = false }
local BOX_VERTICAL_LEFT = { character = string.char(149), invertColors = false }
local BOX_VERTICAL_RIGHT = { character = string.char(149), invertColors = true }
local BOX_TOP_LEFT = { character = string.char(156), invertColors = false }
local BOX_TOP_RIGHT = { character = string.char(147), invertColors = true }
local BOX_BOTTOM_LEFT = { character = string.char(141), invertColors = false }
local BOX_BOTTOM_RIGHT = { character = string.char(142), invertColors = false }
local BOX_LEFT_T = { character = string.char(157), invertColors = false }
local BOX_RIGHT_T = { character = string.char(145), invertColors = true }

local BOOT_FRAMES_PER_STAGE = 4
local BOOT_FRAME_DELAY = 0.05

-- A top-level Lua chunk receives arguments through `...`. Stage-0 passes the
-- same small table on every init attempt made during one supervisor execution.
-- Init reads its Boot ID but does not turn that table into a general state
-- manager and never persists it.
local runtimeContext = ...

-- Load the normal logger behind one complete protected boundary. `loadfile`
-- compiles the module, its returned function executes the module, and
-- `logModule.create` makes the context-bound logger. All three steps, including
-- table access on a malformed replacement module, remain inside `pcall`.
-- Returning nil on any problem turns every later log request into a no-op:
-- diagnostics must never be the reason init enters Recovery.
local function createBestEffortLogger(targetName, context)
    local constructionSucceeded, logger = pcall(function()
        local loggerProgram = loadfile(LOG_LIBRARY_PATH)

        if type(loggerProgram) ~= "function" then
            return nil
        end

        local logModule = loggerProgram()

        if type(logModule) ~= "table" or
            type(logModule.create) ~= "function" then
            return nil
        end

        local createdLogger = logModule.create(targetName, context)

        if type(createdLogger) ~= "table" then
            return nil
        end

        return createdLogger
    end)

    if not constructionSucceeded then
        return nil
    end

    return logger
end

-- Call one level method without trusting either the module or the filesystem.
-- Indexing and invoking the logger happen inside `pcall`, so even a malformed
-- replacement module cannot turn a best-effort diagnostic into boot failure.
local function logBestEffort(logger, level, component, message)
    if logger == nil then
        return
    end

    pcall(function()
        local levelMethod = logger[level]

        if type(levelMethod) == "function" then
            levelMethod(component, message)
        end
    end)
end

local bootLogger = createBestEffortLogger("boot", runtimeContext)
local systemLogger = createBestEffortLogger("system", runtimeContext)
local authLogger = createBestEffortLogger("auth", runtimeContext)

-- Configuration parsing is normal core functionality, unlike best-effort
-- diagnostics. A missing, syntactically broken, or malformed config library
-- therefore raises an init error into Stage-0 Recovery. User-editable config
-- file failures are handled later by the valid library's defaults policy.
local function requireConfigurationLibrary()
    local loadSucceeded, programOrError, compileError = pcall(
        loadfile,
        CONFIG_LIBRARY_PATH
    )

    if not loadSucceeded or type(programOrError) ~= "function" then
        local failure = loadSucceeded and compileError or programOrError
        local message = "Unable to load configuration core: " ..
            tostring(failure)

        logBestEffort(bootLogger, "error", "config", message)
        error(message, 0)
    end

    local runSucceeded, moduleOrError = pcall(programOrError)

    if not runSucceeded or type(moduleOrError) ~= "table" then
        local message = "Unable to start configuration core: " ..
            tostring(moduleOrError)

        logBestEffort(bootLogger, "error", "config", message)
        error(message, 0)
    end

    local requiredFunctions = {
        "parse",
        "load",
        "validate",
        "write",
        "get",
    }

    for _, functionName in ipairs(requiredFunctions) do
        if type(moduleOrError[functionName]) ~= "function" then
            local message = "Configuration core is missing " ..
                functionName .. "."

            logBestEffort(bootLogger, "error", "config", message)
            error(message, 0)
        end
    end

    logBestEffort(
        bootLogger,
        "info",
        "config",
        "Configuration library loaded"
    )
    logBestEffort(
        systemLogger,
        "info",
        "config",
        "Configuration library loaded"
    )
    return moduleOrError
end

-- Load system.cfg behind a core-library boundary. `config.load` treats file
-- problems as data failures and returns defaults plus warnings. If the library
-- itself crashes or violates its API, init treats that as a core failure.
local function loadSystemConfiguration(configModule)
    local callSucceeded, valuesOrError, warnings, status = pcall(
        configModule.load,
        SYSTEM_CONFIG_PATH,
        SYSTEM_CONFIG_SCHEMA
    )

    if not callSucceeded then
        local message = "Configuration core failed while loading system.cfg: " ..
            tostring(valuesOrError)

        logBestEffort(bootLogger, "error", "config", message)
        error(message, 0)
    end

    if type(valuesOrError) ~= "table" or type(warnings) ~= "table" or
        type(status) ~= "table" or type(status.loaded) ~= "boolean" then
        local message = "Configuration core returned an invalid load result."

        logBestEffort(bootLogger, "error", "config", message)
        error(message, 0)
    end

    for _, warning in ipairs(warnings) do
        logBestEffort(bootLogger, "warn", "config", warning)
        logBestEffort(systemLogger, "warn", "config", warning)
    end

    if status.loaded then
        logBestEffort(
            bootLogger,
            "info",
            "config",
            "System configuration loaded"
        )
        logBestEffort(
            systemLogger,
            "info",
            "config",
            "System configuration loaded"
        )
    else
        logBestEffort(
            bootLogger,
            "warn",
            "config",
            "System configuration defaults active"
        )
        logBestEffort(
            systemLogger,
            "warn",
            "config",
            "System configuration defaults active"
        )
    end

    return valuesOrError
end

-- Authentication code and users.db are security-critical state. Unlike the
-- optional system.cfg policy above, no defaults or automatic account creation
-- are safe here. Missing/broken modules or an invalid database therefore raise
-- an init error which Stage-0 converts into the established Recovery path.
local function requireAuthenticationState()
    local loadSucceeded, programOrError, compileError = pcall(
        loadfile,
        AUTH_LIBRARY_PATH
    )

    if not loadSucceeded or type(programOrError) ~= "function" then
        local failure = loadSucceeded and compileError or programOrError
        local message = "Unable to load authentication core: " ..
            tostring(failure)

        logBestEffort(bootLogger, "error", "auth", message)
        logBestEffort(
            authLogger,
            "error",
            "auth",
            "Authentication core load failed"
        )
        error(message, 0)
    end

    local runSucceeded, moduleOrError = pcall(programOrError)

    if not runSucceeded or type(moduleOrError) ~= "table" or
        type(moduleOrError.validateState) ~= "function" then
        local message = "Unable to start authentication core: " ..
            tostring(moduleOrError)

        logBestEffort(bootLogger, "error", "auth", message)
        logBestEffort(
            authLogger,
            "error",
            "auth",
            "Authentication core start failed"
        )
        error(message, 0)
    end

    local validationSucceeded, validOrError, validationError = pcall(
        moduleOrError.validateState
    )

    if not validationSucceeded or validOrError ~= true then
        local failure = validationSucceeded and validationError or validOrError
        local message = "Authentication state is invalid: " ..
            tostring(failure)

        logBestEffort(bootLogger, "error", "auth", message)
        logBestEffort(authLogger, "error", "auth", "Authentication state invalid")
        error(message, 0)
    end

    logBestEffort(bootLogger, "info", "auth", "Authentication core validated")
    logBestEffort(systemLogger, "info", "auth", "User database validated")
    return moduleOrError
end

-- Each stage is a small Lua table containing the text shown to the user and
-- its current visual state. This is enough structure for later init work to
-- add real bootstrap stages without creating a generic boot framework now.
-- Every label below describes work which this minimal bootstrap really does.
local BOOT_STAGES = {
    { label = "Stage-0 supervisor", state = "pending" },
    { label = "Version metadata", state = "pending" },
    { label = "Machine identity", state = "pending" },
    { label = "Hostname metadata", state = "pending" },
    { label = "Configuration", state = "pending" },
    { label = "User database / auth core", state = "pending" },
}

local function prepareTerminal()
    term.setBackgroundColor(BOOT_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Write text at an explicit terminal coordinate.
--
-- CC:T terminal coordinates begin at column 1, row 1. `term.getSize` returns
-- the current width and height, so clipping here prevents a long value from
-- wrapping onto the next row and damaging the surrounding boot layout.
local function writeAt(x, y, text, color)
    local terminalWidth, terminalHeight = term.getSize()

    if x < 1 or x > terminalWidth or y < 1 or y > terminalHeight then
        return
    end

    local availableWidth = terminalWidth - x + 1
    local clippedText = string.sub(tostring(text), 1, availableWidth)

    term.setTextColor(color)
    term.setCursorPos(x, y)
    term.write(clippedText)
end

-- Write one native CC:T drawing character, optionally repeated.
--
-- The drawing-character table records when foreground and background colours
-- must be exchanged to reveal a complementary shape. Restoring the black
-- background afterwards prevents an inverted corner from affecting later
-- ordinary text.
local function writeBoxGlyphAt(x, y, glyph, count)
    local terminalWidth, terminalHeight = term.getSize()

    if x < 1 or x > terminalWidth or y < 1 or y > terminalHeight then
        return
    end

    local repeatCount = math.min(count or 1, terminalWidth - x + 1)
    local textColor = SEPARATOR_COLOR
    local backgroundColor = BOOT_BACKGROUND

    if glyph.invertColors then
        textColor, backgroundColor = backgroundColor, textColor
    end

    term.setTextColor(textColor)
    term.setBackgroundColor(backgroundColor)
    term.setCursorPos(x, y)
    term.write(string.rep(glyph.character, repeatCount))
    term.setBackgroundColor(BOOT_BACKGROUND)
end

-- Centre a string between the two vertical frame edges. Lua's `#` operator
-- returns the byte length of these ASCII headings, which is also their CC:T
-- terminal width. `math.floor` places any unavoidable odd spare cell on the
-- right side.
local function writeCenteredInside(row, text, color)
    local terminalWidth = term.getSize()
    local innerWidth = terminalWidth - 2
    local clippedText = string.sub(tostring(text), 1, innerWidth)
    local x = 2 + math.floor((innerWidth - #clippedText) / 2)

    writeAt(x, row, clippedText, color)
end

local function drawBootBox()
    local terminalWidth, terminalHeight = term.getSize()

    prepareTerminal()
    writeBoxGlyphAt(1, 1, BOX_TOP_LEFT)
    writeBoxGlyphAt(2, 1, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, 1, BOX_TOP_RIGHT)
    writeBoxGlyphAt(1, terminalHeight, BOX_BOTTOM_LEFT)
    writeBoxGlyphAt(2, terminalHeight, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, terminalHeight, BOX_BOTTOM_RIGHT)

    for row = 2, terminalHeight - 1 do
        writeBoxGlyphAt(1, row, BOX_VERTICAL_LEFT)
        writeBoxGlyphAt(terminalWidth, row, BOX_VERTICAL_RIGHT)
    end
end

local function drawBootSeparator(row)
    local terminalWidth = term.getSize()

    writeBoxGlyphAt(1, row, BOX_LEFT_T)
    writeBoxGlyphAt(2, row, BOX_HORIZONTAL, terminalWidth - 2)
    writeBoxGlyphAt(terminalWidth, row, BOX_RIGHT_T)
end

-- Read one required metadata line from the installed filesystem.
--
-- `fs.open` is a CC:Tweaked API and returns a file handle rather than the file
-- contents. A failed open returns nil plus a diagnostic message. File-handle
-- operations may raise Lua errors, so read and close are protected separately;
-- the helper then returns either the string value or nil plus an explanation.
-- These are Lua multiple return values, allowing the caller to distinguish an
-- empty result from a failure without relying on global error state.
local function readRequiredValue(path)
    local file, openError = fs.open(path, "r")

    if file == nil then
        return nil, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local readSucceeded, valueOrError = pcall(file.readLine)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        return nil, "Unable to read " .. path .. ": " .. tostring(valueOrError)
    end

    if not closeSucceeded then
        return nil, "Unable to close " .. path .. ": " .. tostring(closeError)
    end

    if valueOrError == nil or valueOrError == "" then
        return nil, "Required metadata is empty: " .. path
    end

    return valueOrError, nil
end

-- Turn a metadata failure into an init failure. Stage-0 runs this entire file
-- through pcall, so propagating an error here does not expose CraftOS: it sends
-- the diagnostic back to Stage-0, which enters Recovery.
local function requireValue(path, description)
    local value, readError = readRequiredValue(path)

    if value == nil then
        error("Unable to load " .. description .. ": " .. readError, 0)
    end

    return value
end

-- Validate the small runtime API supplied by Stage-0.
--
-- `apiVersion` is a compatibility marker, not a negotiation protocol. Init
-- accepts exactly the interface it understands and reports both expected and
-- received values when they differ. The Boot ID pattern then requires `B-`
-- followed by eight uppercase hexadecimal characters. Neither value can be
-- reconstructed from disk, so an invalid context is a real init failure.
-- Every rejection is logged before `error` returns it to Stage-0, but the
-- protected logging wrapper means a logger failure cannot hide that real error.
local function requireRuntimeContext(context)
    if type(context) ~= "table" then
        local contextError =
            "Runtime context missing. Expected Stage-0 runtime API 1."

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    logBestEffort(
        bootLogger,
        "info",
        "init",
        "Runtime context received"
    )

    if context.apiVersion ~= EXPECTED_RUNTIME_API_VERSION then
        local contextError = string.format(
            "Unsupported Stage-0 runtime API. Expected: %d Received: %s",
            EXPECTED_RUNTIME_API_VERSION,
            tostring(context.apiVersion)
        )

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    local bootID = context.bootID

    if type(bootID) ~= "string" or not string.match(
        bootID,
        "^B%-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" ..
            "[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$"
    ) then
        local contextError =
            "Stage-0 runtime context contains an invalid Boot ID."

        logBestEffort(bootLogger, "error", "init", contextError)
        error(contextError, 0)
    end

    logBestEffort(bootLogger, "info", "init", "Boot ID validated")
    return bootID
end

local function drawBootHeader(version)
    drawBootBox()
    writeCenteredInside(3, "DICK/OS " .. version, PRIMARY_TEXT)
    writeCenteredInside(
        4,
        "Distributed Infrastructure & Computer Kit",
        INFORMATION_COLOR
    )
    drawBootSeparator(6)
    writeAt(3, 8, "BOOTSTRAP SEQUENCE", PRIMARY_TEXT)
end

local function drawBootStage(stage, row)
    local marker = "[    ]"
    local markerColor = SEPARATOR_COLOR
    local labelColor = SECONDARY_TEXT

    if stage.state == "active" then
        marker = "[ .. ]"
        markerColor = INFORMATION_COLOR
        labelColor = PRIMARY_TEXT
    elseif stage.state == "ok" then
        marker = "[ OK ]"
        markerColor = SUCCESS_COLOR
        labelColor = PRIMARY_TEXT
    end

    writeAt(2, row, marker, markerColor)
    writeAt(9, row, stage.label, labelColor)
end

local function drawAllBootStages()
    for stageIndex, stage in ipairs(BOOT_STAGES) do
        drawBootStage(stage, 8 + stageIndex)
    end
end

-- Draw a progress bar sized from the current terminal width.
--
-- `percent / 100` converts the integer percentage into a fraction. Multiplying
-- that fraction by the available bar width tells us how many `#` cells should
-- be filled. The remaining cells use `-`, preserving a package-manager-like
-- sense of activity without copying another project's exact presentation.
local function drawProgressBar(percent, activityLabel)
    local terminalWidth, terminalHeight = term.getSize()
    local labelRow = terminalHeight - 4
    local progressRow = terminalHeight - 3
    local barWidth = math.max(8, terminalWidth - 10)
    local filledWidth = math.floor((percent / 100) * barWidth + 0.5)
    local emptyWidth = barWidth - filledWidth

    writeAt(2, labelRow, string.rep(" ", terminalWidth - 2), PRIMARY_TEXT)
    writeAt(2, labelRow, "Activity: " .. activityLabel, INFORMATION_COLOR)

    writeAt(2, progressRow, "[", SECONDARY_TEXT)
    writeAt(3, progressRow, string.rep("#", filledWidth), INFORMATION_COLOR)
    writeAt(
        3 + filledWidth,
        progressRow,
        string.rep("-", emptyWidth),
        SEPARATOR_COLOR
    )
    writeAt(3 + barWidth, progressRow, "]", SECONDARY_TEXT)
    writeAt(
        5 + barWidth,
        progressRow,
        string.format("%3d%%", percent),
        PRIMARY_TEXT
    )
end

-- Wait for one cosmetic animation frame without losing terminate handling.
--
-- `os.startTimer` queues a future timer event. `os.pullEventRaw` waits without
-- converting Ctrl+T into an immediate Lua error, allowing this helper to return
-- false when it sees `terminate`. Init can then return Stage-0's established
-- `restart` result while Ctrl+T still belongs to pre-shell bootstrap. Once the
-- interactive shell starts, its own prompt and child-command policy takes
-- over. Other events are intentionally ignored here.
local function waitForBootFrame()
    local timerID = os.startTimer(BOOT_FRAME_DELAY)

    while true do
        local eventName, eventID = os.pullEventRaw()

        if eventName == "terminate" then
            return false
        end

        if eventName == "timer" and eventID == timerID then
            return true
        end
    end
end

-- Animate only the visual representation of the already completed bootstrap
-- work. When cosmetic delay is disabled, the same real stages render directly
-- in their complete state without starting timers or waiting for frame events.
-- With delay enabled, each stage retains the existing four short visual frames.
local function animateBootProgress(cosmeticDelayEnabled)
    local totalFrames = #BOOT_STAGES * BOOT_FRAMES_PER_STAGE

    drawAllBootStages()

    if not cosmeticDelayEnabled then
        for _, stage in ipairs(BOOT_STAGES) do
            stage.state = "ok"
        end

        drawAllBootStages()
        drawProgressBar(100, "Bootstrap complete")
        return true
    end

    for stageIndex, stage in ipairs(BOOT_STAGES) do
        stage.state = "active"
        drawAllBootStages()

        for frameIndex = 1, BOOT_FRAMES_PER_STAGE do
            local completedFrames =
                (stageIndex - 1) * BOOT_FRAMES_PER_STAGE + frameIndex
            local percent = math.floor((completedFrames / totalFrames) * 100)

            drawProgressBar(percent, stage.label)

            if not waitForBootFrame() then
                return false
            end
        end

        stage.state = "ok"
        drawAllBootStages()
    end

    drawProgressBar(100, "Bootstrap complete")
    return true
end

local function drawInformationField(x, y, label, value)
    writeAt(x, y, label, SECONDARY_TEXT)
    writeAt(x + 12, y, value, PRIMARY_TEXT)
end

-- Load the post-boot presentation as a separate utility.
--
-- `loadfile` returns nil plus a compile diagnostic when dickfetch is missing or
-- syntactically invalid. `pcall` then converts a runtime rendering error into a
-- false result. Unlike metadata failures, either presentation failure is
-- noncritical: the caller can draw a minimal status view and keep init alive.
local function runDickfetch(context)
    local dickfetchProgram, loadError = loadfile(DICKFETCH_PATH)

    if dickfetchProgram == nil then
        return false, "Unable to load dickfetch: " .. tostring(loadError)
    end

    local runSucceeded, runError = pcall(dickfetchProgram, context)

    if not runSucceeded then
        return false, "dickfetch failed: " .. tostring(runError)
    end

    return true, nil
end

-- Login is a core boundary: missing or crashing UI must not skip credentials or
-- expose a shell. A successful program returns only the public user identity
-- produced by auth.lua; verifier/database details never enter init's session
-- context.
local function runLogin(context)
    local loadSucceeded, loginProgram, loadError = pcall(loadfile, LOGIN_PATH)

    if not loadSucceeded or type(loginProgram) ~= "function" then
        local failure = loadSucceeded and loadError or loginProgram

        return nil, "Unable to load DICK login: " .. tostring(failure)
    end

    local loginSucceeded, userOrError = pcall(loginProgram, context)

    if not loginSucceeded then
        return nil, "DICK login failed: " .. tostring(userOrError)
    end

    if type(userOrError) ~= "table" or
        type(userOrError.name) ~= "string" or userOrError.name == "" or
        type(userOrError.uid) ~= "number" or
        userOrError.uid ~= math.floor(userOrError.uid) or
        type(userOrError.home) ~= "string" or
        string.sub(userOrError.home, 1, 1) ~= "/" or
        type(userOrError.admin) ~= "boolean" then
        return nil, "DICK login returned an invalid user identity."
    end

    return userOrError, nil
end

-- Show required identity values even when the richer dickfetch presentation
-- cannot run. This keeps a cosmetic utility failure visibly degraded but does
-- not misreport healthy metadata as a catastrophic boot failure.
local function drawDickfetchFallback(context, presentationError)
    prepareTerminal()

    writeAt(3, 2, "DICK/OS", INFORMATION_COLOR)
    writeAt(3, 3, context.version, SECONDARY_TEXT)
    drawInformationField(3, 5, "Hostname:", context.hostname)
    drawInformationField(3, 6, "Machine ID:", context.machineID)
    drawInformationField(3, 7, "Boot ID:", context.bootID)
    writeAt(3, 9, "SYSTEM READY", SUCCESS_COLOR)
    writeAt(3, 11, "[WARN] dickfetch presentation unavailable", WARNING_COLOR)
    writeAt(
        3,
        12,
        presentationError,
        SECONDARY_TEXT
    )
end

-- Start the core shell behind init's own boundary. A missing or malformed
-- shell is not a cosmetic failure: returning a reason lets the caller log it
-- and raise an init error into the established Stage-0 Recovery path. A
-- healthy interactive shell may return only the explicit `logout` result.
local function runShell(context)
    local loadSucceeded, shellProgram, loadError = pcall(
        loadfile,
        SHELL_PATH
    )

    if not loadSucceeded or type(shellProgram) ~= "function" then
        local failure = loadSucceeded and loadError or shellProgram

        return nil, "Unable to load DICK shell: " .. tostring(failure)
    end

    local shellSucceeded, shellResult = pcall(shellProgram, context)

    if not shellSucceeded then
        return nil, "DICK shell failed: " .. tostring(shellResult)
    end

    if shellResult == "logout" then
        return "logout", nil
    end

    return nil, "DICK shell returned an invalid result: " ..
        tostring(shellResult)
end

prepareTerminal()
logBestEffort(bootLogger, "info", "init", "init started")

local bootID = requireRuntimeContext(runtimeContext)
local version = requireValue(VERSION_PATH, "DICK/OS version")
logBestEffort(bootLogger, "info", "init", "Version metadata loaded")
local hostname = requireValue(HOSTNAME_PATH, "hostname")
logBestEffort(bootLogger, "info", "init", "Hostname metadata loaded")
local machineID = requireValue(MACHINE_ID_PATH, "machine ID")
logBestEffort(bootLogger, "info", "init", "Machine ID metadata loaded")

local configModule = requireConfigurationLibrary()
local systemConfiguration = loadSystemConfiguration(configModule)
local bootCosmeticDelay = configModule.get(
    systemConfiguration,
    "boot.cosmetic_delay"
)
local shellHistoryLimit = configModule.get(
    systemConfiguration,
    "shell.history_limit"
)

if type(bootCosmeticDelay) ~= "boolean" or
    type(shellHistoryLimit) ~= "number" or
    shellHistoryLimit ~= math.floor(shellHistoryLimit) or
    shellHistoryLimit < 0 or shellHistoryLimit > 256 then
    local message = "Configuration core returned invalid system settings."

    logBestEffort(bootLogger, "error", "config", message)
    error(message, 0)
end


-- Keep the returned module alive only as proof that all authentication core
-- dependencies compiled and users.db validated. Login loads the same stateless
-- policy module for each attempt; no credential state is cached in init.
local authModule = requireAuthenticationState()
authModule = nil

logBestEffort(bootLogger, "info", "init", "Normal boot UI starting")
drawBootHeader(version)

if not animateBootProgress(bootCosmeticDelay) then
    logBestEffort(
        bootLogger,
        "warn",
        "init",
        "Terminate event received during boot UI; requesting init restart"
    )
    return STAGE0_RESTART_RESULT
end

-- Init combines persistent installation metadata with Stage-0's runtime-only
-- Boot ID for the post-authentication presentation. Constructing this table
-- does not display anything: the session loop invokes dickfetch only after
-- credentials have been accepted. The table is never saved.
local dickfetchContext = {
    version = version,
    hostname = hostname,
    machineID = machineID,
    bootID = bootID,
}

logBestEffort(bootLogger, "info", "init", "Login service ready")
logBestEffort(systemLogger, "info", "init", "Login service ready")

local loginContext = {
    runtimeApiVersion = runtimeContext.apiVersion,
    bootID = bootID,
    version = version,
    hostname = hostname,
    machineID = machineID,
}

-- Init owns the session loop. Logout returns here without rebooting, then the
-- same login context begins another authentication attempt under the same
-- Stage-0 Boot ID. Every successful authentication gets a fresh dickfetch
-- presentation before its shell; no presentation runs before credentials.
-- Any other shell/login return remains a core failure.
while true do
    logBestEffort(bootLogger, "info", "login", "DICK login starting")
    local authenticatedUser, loginError = runLogin(loginContext)

    if authenticatedUser == nil then
        logBestEffort(bootLogger, "error", "login", loginError)
        logBestEffort(systemLogger, "error", "login", loginError)
        error(loginError, 0)
    end

    -- login owns and clears its credential screen. Reset normal terminal state
    -- after it returns, then run the noncritical presentation. A broken
    -- dickfetch still receives the existing minimal fallback before the
    -- authenticated shell starts.
    prepareTerminal()
    logBestEffort(bootLogger, "info", "init", "dickfetch starting")
    local presentationSucceeded, presentationError =
        runDickfetch(dickfetchContext)

    if not presentationSucceeded then
        logBestEffort(
            bootLogger,
            "warn",
            "dickfetch",
            "Presentation failure: " .. tostring(presentationError)
        )
        drawDickfetchFallback(dickfetchContext, presentationError)
    end

    local shellContext = {
        runtimeApiVersion = runtimeContext.apiVersion,
        bootID = bootID,
        version = version,
        hostname = hostname,
        machineID = machineID,
        user = authenticatedUser.name,
        uid = authenticatedUser.uid,
        home = authenticatedUser.home,
        isAdmin = authenticatedUser.admin,
        shellHistoryLimit = shellHistoryLimit,
    }

    authenticatedUser = nil
    logBestEffort(bootLogger, "info", "init", "Authenticated shell starting")
    local shellResult, shellFailure = runShell(shellContext)

    if shellResult ~= "logout" then
        logBestEffort(bootLogger, "error", "shell", shellFailure)
        logBestEffort(systemLogger, "error", "shell", shellFailure)
        error(shellFailure, 0)
    end

    logBestEffort(
        systemLogger,
        "info",
        "shell",
        "Authenticated session logged out"
    )
    logBestEffort(
        authLogger,
        "info",
        "logout",
        "Logout for " .. shellContext.user ..
            " uid=" .. tostring(shellContext.uid)
    )
end
