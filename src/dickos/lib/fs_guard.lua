-- DICK/OS filesystem mutation policy
-- Version: 0.1.0-unstable

-- This module is a policy helper for native DICK commands. It is not a
-- filesystem sandbox: CC:T exposes `fs` to ordinary Lua programs, Recovery,
-- and CraftOS. The guard makes the official DICK mutation interfaces apply one
-- consistent path/elevation/confirmation policy before they call `fs.*`.
local guard = {}

local DICK_ROOT = "/dickos"
local TEMPORARY_ROOT = "/dickos/tmp"
local LOG_LIBRARY_PATH = "/dickos/lib/log.lua"

local CRITICAL_EXACT_PATHS = {
    ["/startup.lua"] = true,
    ["/.settings"] = true,
    ["/dickos/etc/users.db"] = true,
    ["/dickos/etc/version"] = true,
    ["/dickos/etc/hostname"] = true,
    ["/dickos/etc/machine-id"] = true,
}

local DESTRUCTIVE_OPERATIONS = {
    remove = true,
    move_source = true,
}

local VALID_OPERATIONS = {
    write = true,
    remove = true,
    move_source = true,
}

-- Lexical normalisation is intentionally independent from `fs.exists`.
-- Empty and `.` segments disappear, `..` removes one preceding segment, and
-- attempts to travel above `/` remain clamped at `/`. Requiring an absolute
-- input prevents ambient CraftOS shell state from influencing the result.
function guard.normalize(path)
    if type(path) ~= "string" or string.sub(path, 1, 1) ~= "/" then
        return nil, "path must be absolute"
    end

    local segments = {}

    for segment in string.gmatch(path, "[^/]+") do
        if segment == ".." then
            if #segments > 0 then
                table.remove(segments)
            end
        elseif segment ~= "." and segment ~= "" then
            segments[#segments + 1] = segment
        end
    end

    if #segments == 0 then
        return "/", nil
    end

    return "/" .. table.concat(segments, "/"), nil
end

-- Containment uses path-component boundaries. A raw prefix check would
-- incorrectly place `/dickos/systematic` inside `/dickos/system`; exact match
-- or a slash after the boundary is required instead.
function guard.isWithin(path, boundary)
    local normalPath = guard.normalize(path)
    local normalBoundary = guard.normalize(boundary)

    if normalPath == nil or normalBoundary == nil then
        return false
    end

    if normalBoundary == "/" then
        return true
    end

    return normalPath == normalBoundary or
        string.sub(normalPath, 1, #normalBoundary + 1) ==
            normalBoundary .. "/"
end

function guard.parent(path)
    local normalPath, normalizeError = guard.normalize(path)

    if normalPath == nil then
        return nil, normalizeError
    end

    if normalPath == "/" then
        return "/", nil
    end

    return string.match(normalPath, "^(.+)/[^/]+$") or "/", nil
end

function guard.name(path)
    local normalPath, normalizeError = guard.normalize(path)

    if normalPath == nil then
        return nil, normalizeError
    end

    if normalPath == "/" then
        return "", nil
    end

    return string.match(normalPath, "([^/]+)$"), nil
end

-- Resolve the two documented home forms and ordinary relative paths using a
-- command-context snapshot. This duplicates no CraftOS shell semantics: the
-- real authenticated home and DICK cwd remain the only resolution authority.
function guard.resolve(context, requestedPath)
    if type(context) ~= "table" or type(context.cwd) ~= "string" or
        type(context.home) ~= "string" or
        string.sub(context.cwd, 1, 1) ~= "/" or
        string.sub(context.home, 1, 1) ~= "/" then
        return nil, "DICK command context requires absolute cwd and home"
    end

    if type(requestedPath) ~= "string" or requestedPath == "" then
        return nil, "path must be a non-empty string"
    end

    if requestedPath == "~" then
        return guard.normalize(context.home)
    end

    if string.sub(requestedPath, 1, 2) == "~/" then
        return guard.normalize(context.home .. "/" ..
            string.sub(requestedPath, 3))
    end

    if string.sub(requestedPath, 1, 1) == "/" then
        return guard.normalize(requestedPath)
    end

    return guard.normalize(context.cwd .. "/" .. requestedPath)
end

local function classifyNormalised(path, operation, context)
    -- Removing or moving either filesystem root would invalidate the running
    -- environment itself, so this destructive meaning outranks other classes.
    if DESTRUCTIVE_OPERATIONS[operation] and
        (path == "/" or path == DICK_ROOT) then
        return "catastrophic"
    end

    if CRITICAL_EXACT_PATHS[path] or
        guard.isWithin(path, "/dickos/system") or
        guard.isWithin(path, "/dickos/lib") then
        return "critical"
    end

    local home = type(context) == "table" and context.home or nil
    local normalHome = type(home) == "string" and guard.normalize(home) or nil

    -- The authenticated user's own home and the shared temporary tree are the
    -- two ordinary writable regions beneath `/dickos`. Boundary-aware checks
    -- ensure a similarly named neighbour is not accidentally included.
    if normalHome ~= nil and guard.isWithin(path, normalHome) then
        return "ordinary"
    end

    if guard.isWithin(path, TEMPORARY_ROOT) then
        return "ordinary"
    end

    if guard.isWithin(path, DICK_ROOT) then
        return "protected"
    end

    -- These boot/platform files live outside `/dickos`, so they were handled
    -- explicitly above. All remaining external paths are ordinary in v1.
    return "ordinary"
end

-- Inspection is data-only: it normalises and classifies one intended
-- mutation, but performs neither authentication nor filesystem writes. This
-- separation lets multi-target commands validate every argument first.
function guard.inspect(path, operation, context)
    if not VALID_OPERATIONS[operation] then
        return nil, "unsupported mutation operation"
    end

    local normalPath, normalizeError = guard.normalize(path)

    if normalPath == nil then
        return nil, normalizeError
    end

    local risk = classifyNormalised(normalPath, operation, context)

    return {
        path = normalPath,
        operation = operation,
        risk = risk,
        requiresElevation = risk ~= "ordinary",
        requiresConfirmation = risk == "critical" or
            risk == "catastrophic",
    }, nil
end

local function hasEffectiveRoot(context)
    return type(context) == "table" and
        context.isElevated == true and
        context.effectiveUID == 0 and
        context.effectiveUser == "root" and
        context.isAdmin == true
end

-- The real account's admin role is deliberately insufficient here. Only the
-- short-lived context constructed by the sudo builtin carries both the
-- explicit elevation marker and effective UID 0.
function guard.authorize(inspections, context)
    if type(inspections) ~= "table" then
        return false, "mutation inspection list is missing"
    end

    for _, inspection in ipairs(inspections) do
        if type(inspection) ~= "table" or
            type(inspection.path) ~= "string" or
            type(inspection.risk) ~= "string" then
            return false, "mutation inspection is invalid"
        end

        if inspection.requiresElevation and not hasEffectiveRoot(context) then
            return false, "permission denied for " .. inspection.path ..
                "; use sudo with a native DICK command"
        end
    end

    return true, nil
end

local function setTextColorBestEffort(color)
    if type(term) == "table" and type(term.setTextColor) == "function" and
        color ~= nil then
        pcall(term.setTextColor, color)
    end
end

local function warningLines(inspection)
    local path = inspection.path

    if inspection.risk == "catastrophic" then
        if path == DICK_ROOT then
            return {
                "This operation may destroy the installed DICK/OS runtime.",
                "Normal boot and Recovery may stop working until manual " ..
                    "CraftOS repair or reinstallation.",
            }
        end

        return {
            "This operation targets the filesystem root.",
            "The computer's persistent files and DICK/OS installation may be " ..
                "destroyed.",
        }
    end

    if path == "/startup.lua" then
        return {
            "Changing this file can prevent Stage-0 from starting.",
            "Normal DICK/OS Recovery may no longer be reached automatically.",
            "Manual CraftOS repair may be required.",
        }
    end

    if path == "/.settings" then
        return {
            "Changing this file can alter CraftOS startup policy.",
            "DICK/OS may stop starting automatically.",
        }
    end

    if guard.isWithin(path, "/dickos/system") or
        guard.isWithin(path, "/dickos/lib") then
        return {
            "Changing core code can make normal DICK/OS boot fail.",
            "Recovery or manual CraftOS repair may be required.",
        }
    end

    if path == "/dickos/etc/users.db" then
        return {
            "Changing the user database can make authentication unusable.",
            "Normal login may fail and Recovery may be required.",
        }
    end

    return {
        "Changing required system identity metadata can make init fail.",
        "Recovery may be required.",
    }
end

-- Confirmation logging is best-effort and deliberately restricted to paths
-- already classified high-risk. Thus an arbitrary filename from a user's home
-- can never be copied into system.log by this helper.
local function logConfirmationBestEffort(operationName, path, context)
    pcall(function()
        local program = assert(loadfile(LOG_LIBRARY_PATH))
        local logModule = program()
        local logger = logModule.create("system", context)

        if type(logger) == "table" and type(logger.info) == "function" then
            logger.info(
                "fs_guard",
                "Critical mutation confirmed: " .. operationName .. " " ..
                    path
            )
        end
    end)
end

-- Confirm every distinct critical/catastrophic path before the caller begins
-- mutation. `read` is protected only so Ctrl+T becomes an explicit cancelled
-- preflight result; no password, verifier, or filesystem operation occurs in
-- this helper. The user must type the exact normalised absolute path.
function guard.confirm(inspections, operationName, context)
    if type(inspections) ~= "table" then
        return false, "invalid", nil
    end

    local displayedOperation = type(operationName) == "string" and
        operationName or "mutation"
    local confirmedPaths = {}
    local confirmedHighRisk = {}

    for _, inspection in ipairs(inspections) do
        if inspection.requiresConfirmation and
            not confirmedPaths[inspection.path] then
            confirmedPaths[inspection.path] = true

            if inspection.risk == "catastrophic" then
                setTextColorBestEffort(colors and colors.red)
                print("DANGER: CATASTROPHIC FILESYSTEM OPERATION")
            else
                setTextColorBestEffort(colors and colors.red)
                print("DANGER: CRITICAL DICK/OS PATH")
            end

            setTextColorBestEffort(colors and colors.white)
            print("Operation: " .. displayedOperation)
            print("Target: " .. inspection.path)
            print()

            for _, line in ipairs(warningLines(inspection)) do
                setTextColorBestEffort(colors and colors.yellow)
                print(line)
            end

            setTextColorBestEffort(colors and colors.white)
            print()
            print("Type the exact target path to continue:")
            write("> ")

            local readSucceeded, answer = pcall(read)

            if not readSucceeded then
                setTextColorBestEffort(colors and colors.white)
                print()
                print("Operation cancelled.")
                print("No files changed.")
                return false, "cancelled", inspection.path
            end

            if tostring(answer or "") ~= inspection.path then
                setTextColorBestEffort(colors and colors.white)
                print("Operation cancelled.")
                print("No files changed.")
                return false, "mismatch", inspection.path
            end

            confirmedHighRisk[#confirmedHighRisk + 1] = inspection.path
        end
    end

    -- Logging is delayed until every required answer is accepted. A wrong
    -- second answer therefore leaves both target paths and the diagnostic log
    -- untouched by the confirmation phase.
    for _, path in ipairs(confirmedHighRisk) do
        logConfirmationBestEffort(displayedOperation, path, context)
    end

    setTextColorBestEffort(colors and colors.white)
    return true, nil, nil
end

return guard
