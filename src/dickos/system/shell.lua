-- DICK/OS authenticated shell foundation
-- Version: 0.1.0-unstable

local BIN_PATH = "/dickos/bin"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"
local EXPECTED_RUNTIME_API_VERSION = 1

local SHELL_BACKGROUND = colors.black
local PRIMARY_TEXT = colors.white
local ERROR_TEXT = colors.red
local USER_COLOR = colors.lime
local HOSTNAME_COLOR = colors.lightBlue
local STRUCTURE_COLOR = colors.lightGray

-- Init calls this file as a compiled Lua chunk and supplies one explicit
-- session table through `...`. The table carries only the authenticated public
-- identity and runtime metadata needed by the shell. Password verifiers and
-- authentication modules are deliberately absent from this boundary.
local sessionContext = ...

-- Convert ordinary string errors and CC:T exception tables into text. Current
-- CC:T versions may preserve a richer exception as a table whose `message`
-- field contains the readable diagnostic.
local function describeError(errorValue)
    if type(errorValue) == "table" and
        type(errorValue.message) == "string" then
        return errorValue.message
    end

    return tostring(errorValue)
end

-- Ctrl+T normally appears as a `Terminated` error when a program uses
-- `os.pullEvent` or `read`. Matching both the exact message and a conventional
-- file/line suffix keeps the shell compatible with plain Lua error strings.
local function isTerminationError(errorValue)
    local message = describeError(errorValue)

    return message == "Terminated" or
        string.match(message, ": Terminated$") ~= nil
end

-- Validate the small init-to-shell contract before displaying a prompt. A
-- malformed context means the core shell could not be established, so raising
-- a clear error is intentional: init will pass it to the existing Recovery
-- path. Individual child programs are protected separately later.
local function validateSessionContext(context)
    if type(context) ~= "table" then
        error("DICK shell session context is missing.", 0)
    end

    if context.runtimeApiVersion ~= EXPECTED_RUNTIME_API_VERSION then
        error(string.format(
            "Unsupported shell runtime API. Expected: %d Received: %s",
            EXPECTED_RUNTIME_API_VERSION,
            tostring(context.runtimeApiVersion)
        ), 0)
    end

    local requiredStringFields = {
        "bootID",
        "version",
        "hostname",
        "machineID",
        "user",
        "home",
    }

    for _, fieldName in ipairs(requiredStringFields) do
        local value = context[fieldName]

        if type(value) ~= "string" or value == "" then
            error("DICK shell context is missing " .. fieldName .. ".", 0)
        end
    end

    if string.sub(context.home, 1, 1) ~= "/" then
        error("DICK shell home directory must be an absolute path.", 0)
    end

    if type(context.uid) ~= "number" or
        context.uid ~= math.floor(context.uid) or context.uid < 0 then
        error("DICK shell context contains an invalid UID.", 0)
    end

    if type(context.isAdmin) ~= "boolean" then
        error("DICK shell context contains an invalid admin flag.", 0)
    end

    if type(context.shellHistoryLimit) ~= "number" or
        context.shellHistoryLimit ~= math.floor(context.shellHistoryLimit) or
        context.shellHistoryLimit < 0 or
        context.shellHistoryLimit > 256 then
        error(
            "DICK shell context contains an invalid history limit.",
            0
        )
    end
end

validateSessionContext(sessionContext)

-- Load system.log defensively. Logging is useful but never part of the shell's
-- correctness boundary: module compilation, execution, table access, and
-- logger construction all happen inside one protected call. nil therefore
-- means only that diagnostics are unavailable.
local function createBestEffortLogger(context)
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

        local createdLogger = logModule.create("system", context)

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

local systemLogger = createBestEffortLogger(sessionContext)

-- Invoke one logger method without trusting the module or filesystem. The
-- complete raw command line is deliberately never passed here, establishing a
-- safe convention before commands may eventually accept secret arguments.
local function logBestEffort(level, component, message)
    if systemLogger == nil then
        return
    end

    pcall(function()
        local levelMethod = systemLogger[level]

        if type(levelMethod) == "function" then
            levelMethod(component, message)
        end
    end)
end

-- Normalise an absolute path without inventing mounts or Unix permissions.
-- Empty segments and `.` are ignored. `..` removes one segment but is clamped
-- at the filesystem root, so a path can never escape above `/`.
local function normalizeAbsolutePath(path)
    local segments = {}

    for segment in string.gmatch(tostring(path), "[^/]+") do
        if segment == ".." then
            if #segments > 0 then
                table.remove(segments)
            end
        elseif segment ~= "." and segment ~= "" then
            segments[#segments + 1] = segment
        end
    end

    if #segments == 0 then
        return "/"
    end

    return "/" .. table.concat(segments, "/")
end

local homeDirectory = normalizeAbsolutePath(sessionContext.home)
local currentWorkingDirectory = homeDirectory

-- Expand only the documented `~` and `~/...` forms. All other relative paths
-- are resolved against the DICK shell's own cwd rather than CraftOS shell
-- state. The returned value always begins with `/`.
local function resolveUserPath(path, cwdSnapshot)
    local requestedPath = tostring(path or "")
    local baseDirectory = cwdSnapshot or currentWorkingDirectory

    if requestedPath == "" then
        return normalizeAbsolutePath(baseDirectory)
    end

    if requestedPath == "~" then
        return homeDirectory
    end

    if string.sub(requestedPath, 1, 2) == "~/" then
        return normalizeAbsolutePath(
            homeDirectory .. "/" .. string.sub(requestedPath, 3)
        )
    end

    if string.sub(requestedPath, 1, 1) == "/" then
        return normalizeAbsolutePath(requestedPath)
    end

    return normalizeAbsolutePath(baseDirectory .. "/" .. requestedPath)
end

-- Display the exact home directory as `~` and descendants as `~/...`. A
-- neighbouring prefix such as `/dickos/home/nano-old` is not shortened.
local function displayWorkingDirectory(path)
    if path == homeDirectory then
        return "~"
    end

    local homePrefix = homeDirectory .. "/"

    if string.sub(path, 1, #homePrefix) == homePrefix then
        return "~/" .. string.sub(path, #homePrefix + 1)
    end

    return path
end

-- The installer creates the authenticated owner's home. Keeping this defensive
-- check preserves a clear core failure if that path was replaced by a file and
-- allows a manually repaired missing directory to be recreated.
local function ensureHomeDirectory()
    local preparationSucceeded, preparationError = pcall(function()
        if fs.exists(homeDirectory) then
            if not fs.isDir(homeDirectory) then
                error("Home path exists but is not a directory.", 0)
            end

            return
        end

        fs.makeDir(homeDirectory)

        if not fs.isDir(homeDirectory) then
            error("Home directory was not created.", 0)
        end
    end)

    if not preparationSucceeded then
        local failure = "Unable to prepare authenticated home " ..
            homeDirectory .. ": " .. describeError(preparationError)

        logBestEffort("error", "shell", failure)
        error(failure, 0)
    end
end

-- Restore readable shell terminal state after every child. Child programs may
-- freely change colours, cursor blink, and cursor position. When a command
-- start row is supplied, a child which moved upward cannot make the next
-- prompt overwrite the command line or older output.
local function restoreShellTerminal(minimumCursorRow)
    term.setBackgroundColor(SHELL_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(true)

    if minimumCursorRow ~= nil then
        local cursorX, cursorY = term.getCursorPos()

        if cursorY < minimumCursorRow then
            term.setCursorPos(1, minimumCursorRow)
        end
    end
end

local function moveToFreshLineIfNeeded()
    local cursorX = term.getCursorPos()

    if cursorX ~= 1 then
        print()
    end
end

local function printShellError(message)
    restoreShellTerminal()
    term.setTextColor(ERROR_TEXT)
    print(message)
    term.setTextColor(PRIMARY_TEXT)
end

-- Draw a restrained prompt from semantic colour fragments. `term.write` does
-- not append a newline, leaving the cursor ready for CC:T's `read` function.
local function drawPrompt()
    restoreShellTerminal()
    moveToFreshLineIfNeeded()

    term.setTextColor(USER_COLOR)
    term.write(sessionContext.user)
    term.setTextColor(STRUCTURE_COLOR)
    term.write("@")
    term.setTextColor(HOSTNAME_COLOR)
    term.write(sessionContext.hostname)
    term.setTextColor(STRUCTURE_COLOR)
    term.write(":")
    term.setTextColor(PRIMARY_TEXT)
    term.write(displayWorkingDirectory(currentWorkingDirectory))
    term.setTextColor(STRUCTURE_COLOR)
    term.write("$ ")
    term.setTextColor(PRIMARY_TEXT)
    term.setCursorBlink(true)
end

-- Split one interactive line into command tokens. Whitespace separates tokens
-- only outside quotes; matching single or double quotes remove themselves and
-- keep enclosed spaces. This deliberately is not a scripting parser: pipes,
-- redirection, substitutions, globbing, and escaping are not implemented.
--
-- The first return value is the token table. An unterminated quote returns nil
-- plus a small user-facing reason so the shell can continue at the next prompt.
local function parseCommandLine(line)
    local tokens = {}
    local currentCharacters = {}
    local tokenStarted = false
    local activeQuote = nil

    local function finishToken()
        if not tokenStarted then
            return
        end

        tokens[#tokens + 1] = table.concat(currentCharacters)
        currentCharacters = {}
        tokenStarted = false
    end

    for position = 1, #line do
        local character = string.sub(line, position, position)

        if activeQuote ~= nil then
            if character == activeQuote then
                activeQuote = nil
            else
                currentCharacters[#currentCharacters + 1] = character
            end
        elseif character == '"' or character == "'" then
            activeQuote = character
            tokenStarted = true
        elseif string.match(character, "%s") then
            finishToken()
        else
            currentCharacters[#currentCharacters + 1] = character
            tokenStarted = true
        end
    end

    if activeQuote ~= nil then
        return nil, "unterminated quote"
    end

    finishToken()
    return tokens, nil
end

local builtins = {}

local function isRunnableFile(path)
    return fs.exists(path) and not fs.isDir(path)
end

local function isExplicitProgramPath(commandName)
    return string.find(commandName, "/", 1, true) ~= nil
end

local function isNativeCommandPath(path)
    local binPrefix = BIN_PATH .. "/"

    return string.sub(path, 1, #binPrefix) == binPrefix
end

-- Resolve a command once for both execution and `which`. Plain names search
-- only built-ins and `/dickos/bin`; CraftOS PATH and aliases are intentionally
-- ignored. A user must type a slash to request an explicit relative or
-- absolute program path.
local function resolveCommand(commandName)
    local builtin = builtins[commandName]

    if builtin ~= nil then
        return {
            kind = "builtin",
            name = commandName,
            builtin = builtin,
        }
    end

    if not isExplicitProgramPath(commandName) then
        local extensionlessPath = BIN_PATH .. "/" .. commandName

        if isRunnableFile(extensionlessPath) then
            return {
                kind = "program",
                name = commandName,
                path = extensionlessPath,
                native = true,
            }
        end

        if string.sub(commandName, -4) ~= ".lua" then
            local luaPath = extensionlessPath .. ".lua"

            if isRunnableFile(luaPath) then
                return {
                    kind = "program",
                    name = commandName,
                    path = luaPath,
                    native = true,
                }
            end
        end
    end

    if isExplicitProgramPath(commandName) then
        local explicitPath = resolveUserPath(commandName)

        if isRunnableFile(explicitPath) then
            return {
                kind = "program",
                name = commandName,
                path = explicitPath,
                native = isNativeCommandPath(explicitPath),
            }
        end
    end

    return nil
end

-- Discover command names for the general help listing. Removing a final
-- `.lua` mirrors the resolver's convenience lookup. A set table prevents a
-- future extensionless file and matching `.lua` file from appearing twice.
local function discoverExternalCommands()
    local listSucceeded, entries = pcall(fs.list, BIN_PATH)

    if not listSucceeded or type(entries) ~= "table" then
        return {}
    end

    local discoveredSet = {}

    for _, entryName in ipairs(entries) do
        local entryPath = BIN_PATH .. "/" .. entryName

        if not fs.isDir(entryPath) then
            local commandName = string.gsub(entryName, "%.lua$", "")

            discoveredSet[commandName] = true
        end
    end

    local commandNames = {}

    for commandName in pairs(discoveredSet) do
        commandNames[#commandNames + 1] = commandName
    end

    table.sort(commandNames)
    return commandNames
end

-- Native DICK commands receive a fresh snapshot rather than the mutable shell
-- session table. Explicit user scripts receive only their typed arguments, so
-- ordinary `local firstArgument = ...` programs keep intuitive Lua behaviour.
local function buildCommandContext()
    return {
        runtimeApiVersion = sessionContext.runtimeApiVersion,
        bootID = sessionContext.bootID,
        version = sessionContext.version,
        hostname = sessionContext.hostname,
        machineID = sessionContext.machineID,
        user = sessionContext.user,
        uid = sessionContext.uid,
        isAdmin = sessionContext.isAdmin,
        home = homeDirectory,
        cwd = currentWorkingDirectory,
    }
end

local executeResolvedCommand

local function printBuiltinHelp(commandName, builtin)
    print(commandName .. " - " .. builtin.summary)
    print("Usage: " .. builtin.usage)
end

local function runHelp(arguments)
    local topic = arguments[1]

    if #arguments > 1 then
        printShellError("Usage: " .. builtins.help.usage)
        return
    end

    if topic == "--help" then
        topic = "help"
    end

    if topic == nil then
        print("DICK/OS authenticated shell")
        print()
        print("Built-ins:")

        local builtinNames = {}

        for commandName in pairs(builtins) do
            builtinNames[#builtinNames + 1] = commandName
        end

        table.sort(builtinNames)
        print("  " .. table.concat(builtinNames, "  "))

        local externalNames = discoverExternalCommands()

        if #externalNames > 0 then
            print()
            print("DICK commands:")
            print("  " .. table.concat(externalNames, "  "))
        end

        print()
        print("Use 'help <command>' for command-specific help.")
        return
    end

    local resolution = resolveCommand(topic)

    if resolution == nil then
        printShellError("No help available: " .. topic)
        return
    end

    if resolution.kind == "builtin" then
        printBuiltinHelp(topic, resolution.builtin)
        return
    end

    executeResolvedCommand(resolution, { "--help" })
end

local function runClear(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("clear", builtins.clear)
        return
    end

    if #arguments > 0 then
        printShellError("Usage: " .. builtins.clear.usage)
        return
    end

    term.setBackgroundColor(SHELL_BACKGROUND)
    term.setTextColor(PRIMARY_TEXT)
    term.clear()
    term.setCursorPos(1, 1)
end

local function runChangeDirectory(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("cd", builtins.cd)
        return
    end

    if #arguments > 1 then
        printShellError("Usage: " .. builtins.cd.usage)
        return
    end

    local destination = resolveUserPath(arguments[1] or "~")

    if not fs.exists(destination) then
        printShellError("cd: path does not exist: " .. destination)
        return
    end

    if not fs.isDir(destination) then
        printShellError("cd: not a directory: " .. destination)
        return
    end

    currentWorkingDirectory = destination
end

local function runPrintWorkingDirectory(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("pwd", builtins.pwd)
        return
    end

    if #arguments > 0 then
        printShellError("Usage: " .. builtins.pwd.usage)
        return
    end

    print(currentWorkingDirectory)
end

local function runWhich(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("which", builtins.which)
        return
    end

    if #arguments == 0 then
        printShellError("Usage: " .. builtins.which.usage)
        return
    end

    for _, commandName in ipairs(arguments) do
        local resolution = resolveCommand(commandName)

        if resolution == nil then
            print(commandName .. " not found")
        elseif resolution.kind == "builtin" then
            print(commandName .. ": shell built-in")
        else
            print(resolution.path)
        end
    end
end

local function runExit(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("exit", builtins.exit)
        return
    end

    if #arguments > 0 then
        printShellError("Usage: " .. builtins.exit.usage)
        return
    end

    print("Use 'logout' to return to login.")
    print("Use 'reboot' or 'shutdown' for power control.")
end

-- Logout returns one explicit control result instead of starting another login
-- screen inside the shell. Init owns session lifecycle and consumes this value
-- to begin a fresh authentication attempt under the same runtime Boot ID.
local function runLogout(arguments)
    if arguments[1] == "--help" then
        printBuiltinHelp("logout", builtins.logout)
        return
    end

    if #arguments > 0 then
        printShellError("Usage: " .. builtins.logout.usage)
        return
    end

    return "logout"
end

builtins.help = {
    summary = "show built-in and DICK command help",
    usage = "help [command]",
    run = runHelp,
}
builtins.clear = {
    summary = "clear the terminal",
    usage = "clear",
    run = runClear,
}
builtins.cd = {
    summary = "change the DICK shell working directory",
    usage = "cd [path]",
    run = runChangeDirectory,
}
builtins.pwd = {
    summary = "print the absolute working directory",
    usage = "pwd",
    run = runPrintWorkingDirectory,
}
builtins.which = {
    summary = "show how the DICK shell resolves a command",
    usage = "which <command> [command...]",
    run = runWhich,
}
builtins.exit = {
    summary = "describe the authenticated shell exit policy",
    usage = "exit",
    run = runExit,
}
builtins.logout = {
    summary = "end this authenticated session",
    usage = "logout",
    run = runLogout,
}

-- Compile and run one external program behind a protected boundary. Load and
-- runtime failures are child-command failures: they are printed and logged,
-- then control returns to the prompt. They never propagate into init or
-- Recovery. Source/line diagnostics are preserved on the terminal.
executeResolvedCommand = function(resolution, arguments)
    local _, commandStartRow = term.getCursorPos()
    local loadCallSucceeded, program, loadError = pcall(
        loadfile,
        resolution.path
    )

    if not loadCallSucceeded or type(program) ~= "function" then
        local failure = loadCallSucceeded and loadError or program

        moveToFreshLineIfNeeded()
        printShellError("Command failed:")
        print(describeError(failure))
        logBestEffort(
            "error",
            "shell",
            "Command load failure: " .. resolution.name
        )
        return
    end

    local invocationArguments = {}

    if resolution.native then
        invocationArguments[#invocationArguments + 1] = buildCommandContext()
    end

    for _, argument in ipairs(arguments) do
        invocationArguments[#invocationArguments + 1] = argument
    end

    local commandSucceeded, commandError = pcall(
        program,
        table.unpack(invocationArguments)
    )

    restoreShellTerminal(commandStartRow)

    if commandSucceeded then
        return
    end

    moveToFreshLineIfNeeded()

    if isTerminationError(commandError) then
        print("Command terminated.")
        logBestEffort(
            "warn",
            "shell",
            "Command terminated: " .. resolution.name
        )
        return
    end

    printShellError("Command failed:")
    print(describeError(commandError))
    logBestEffort(
        "error",
        "shell",
        "Command runtime failure: " .. resolution.name
    )
end

local function executeTokens(tokens)
    local commandName = tokens[1]
    local resolution = resolveCommand(commandName)

    if resolution == nil then
        printShellError("Command not found: " .. commandName)
        logBestEffort(
            "warn",
            "shell",
            "Command not found: " .. commandName
        )
        return
    end

    local arguments = {}

    for tokenIndex = 2, #tokens do
        arguments[#arguments + 1] = tokens[tokenIndex]
    end

    if resolution.kind == "builtin" then
        return resolution.builtin.run(arguments)
    else
        return executeResolvedCommand(resolution, arguments)
    end
end

ensureHomeDirectory()
logBestEffort("info", "shell", "Shell started")

-- `read(nil, history)` uses CC:T's built-in in-memory up/down history support.
-- The configured limit applies only to this running shell and is never written
-- back to disk or logs. Zero leaves the table empty and disables history.
local commandHistory = {}
local commandHistoryLimit = sessionContext.shellHistoryLimit

-- Remember only non-blank commands. A Lua table used as a list grows at its
-- numeric end; when it exceeds the configured bound, `table.remove(..., 1)`
-- discards the oldest item and shifts the remaining recent entries down.
local function rememberCommand(line)
    if commandHistoryLimit == 0 or string.match(line, "%S") == nil then
        return
    end

    commandHistory[#commandHistory + 1] = line

    while #commandHistory > commandHistoryLimit do
        table.remove(commandHistory, 1)
    end
end

restoreShellTerminal()
moveToFreshLineIfNeeded()
print()

while true do
    drawPrompt()

    local readSucceeded, lineOrError = pcall(read, nil, commandHistory)

    if not readSucceeded then
        restoreShellTerminal()
        print()

        if isTerminationError(lineOrError) then
            -- Ctrl+T at an idle prompt is contained entirely inside the shell.
            -- The next loop iteration redraws the same prompt and Boot ID.
        else
            error(
                "DICK shell input failed: " .. describeError(lineOrError),
                0
            )
        end
    else
        local line = tostring(lineOrError)

        rememberCommand(line)

        local tokens, parseError = parseCommandLine(line)

        if tokens == nil then
            printShellError("Parse error: " .. parseError)
        elseif #tokens > 0 then
            local action = executeTokens(tokens)

            if action == "logout" then
                logBestEffort("info", "shell", "Shell logout requested")
                restoreShellTerminal()
                term.setCursorBlink(false)
                return "logout"
            end
        end
    end
end
