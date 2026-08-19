-- DICK/OS minimal log viewer
-- Version: 0.1.0-unstable

local LOG_PATHS = {
    boot = "/dickos/var/log/boot.log",
    system = "/dickos/var/log/system.log",
    auth = "/dickos/var/log/auth.log",
}

local DEFAULT_LOG_NAME = "boot"
local DEFAULT_LINE_COUNT = 20

-- CraftOS rescue supplies ordinary arguments directly, while the DICK shell
-- places native command context in the first slot. Shifting only a table first
-- argument preserves all established manual forms such as
-- `/dickos/bin/dicklog.lua boot 50` without storing or requiring Boot ID.
local firstArgument, secondArgument, thirdArgument = ...
local requestedLogName = firstArgument
local requestedLineCount = secondArgument

if type(firstArgument) == "table" then
    requestedLogName = secondArgument
    requestedLineCount = thirdArgument
end

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function printUsage()
    print("Usage: dicklog [boot|system|auth] [line-count]")
    print("Examples:")
    print("  dicklog")
    print("  dicklog boot 50")
    print("  dicklog system")
    print("  dicklog auth 50")
end

if requestedLogName == "--help" then
    printUsage()
    return
end

-- Validate one positive whole-number line count. `tonumber` returns nil when
-- text is not numeric, and `math.floor` lets us reject fractions rather than
-- silently changing what the user requested.
local function parseLineCount(value)
    if value == nil then
        return DEFAULT_LINE_COUNT, nil
    end

    local lineCount = tonumber(value)

    if lineCount == nil or lineCount < 1 or
        lineCount ~= math.floor(lineCount) then
        return nil, "Line count must be a positive whole number."
    end

    return lineCount, nil
end

-- Read only the requested tail instead of keeping the complete log in memory.
-- The table holds at most `maximumLines` entries; when it is full, removing the
-- first entry makes room for the next line. CC:T file-handle reads and close
-- operations are protected separately so a damaged file produces a readable
-- viewer error rather than an unhandled exception.
local function readLastLines(path, maximumLines)
    local file, openError = fs.open(path, "r")

    if file == nil then
        return nil, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local lines = {}

    while true do
        local readSucceeded, lineOrError = pcall(file.readLine)

        if not readSucceeded then
            pcall(file.close)
            return nil, "Unable to read " .. path .. ": " ..
                tostring(lineOrError)
        end

        if lineOrError == nil then
            break
        end

        if #lines == maximumLines then
            table.remove(lines, 1)
        end

        lines[#lines + 1] = lineOrError
    end

    local closeSucceeded, closeError = pcall(file.close)

    if not closeSucceeded then
        return nil, "Unable to close " .. path .. ": " ..
            tostring(closeError)
    end

    return lines, nil
end

-- Apply a small severity palette by looking for the logger's exact level
-- field. Plain boot-marker lines intentionally use the default white. Colour
-- is presentation only; monochrome terminals still print every record.
local function setColorForLine(line)
    if not term.isColor() then
        term.setTextColor(colors.white)
        return
    end

    if string.find(line, "%[CRITICAL%]") or
        string.find(line, "%[ERROR%]") then
        term.setTextColor(colors.red)
    elseif string.find(line, "%[WARN%]") then
        term.setTextColor(colors.yellow)
    elseif string.find(line, "%[DEBUG%]") then
        term.setTextColor(colors.gray)
    elseif string.find(line, "%[INFO%]") then
        term.setTextColor(colors.lightBlue)
    else
        term.setTextColor(colors.white)
    end
end

local function runViewer()
    prepareTerminal()

    local logName = requestedLogName or DEFAULT_LOG_NAME
    local logPath = LOG_PATHS[logName]

    if logPath == nil then
        term.setTextColor(colors.red)
        print("Unknown log: " .. tostring(logName))
        term.setTextColor(colors.white)
        printUsage()
        return
    end

    local lineCount, countError = parseLineCount(requestedLineCount)

    if lineCount == nil then
        term.setTextColor(colors.red)
        print(countError)
        term.setTextColor(colors.white)
        printUsage()
        return
    end

    local lines, readError = readLastLines(logPath, lineCount)

    if lines == nil then
        term.setTextColor(colors.red)
        print(readError)
        return
    end

    term.setTextColor(colors.white)
    print(string.format(
        "DICK/OS %s log (last %d lines)",
        logName,
        lineCount
    ))
    print()

    if #lines == 0 then
        print("Log is empty.")
        return
    end

    for _, line in ipairs(lines) do
        setColorForLine(line)
        print(line)
    end
end

-- A viewer should also fail cleanly when it encounters unexpected filesystem
-- or terminal state. This protection is independent from OS boot: dicklog is a
-- diagnostic command and never participates in the supervisor contract.
local runSucceeded, runError = pcall(runViewer)

term.setTextColor(colors.white)

if not runSucceeded then
    print("dicklog failed: " .. tostring(runError))
end
