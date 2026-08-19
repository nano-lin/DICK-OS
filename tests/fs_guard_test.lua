-- Host-side tests for DICK/OS filesystem mutation policy
-- Run with: lua tests/fs_guard_test.lua

local hostLoadfile = loadfile
local inputs = {}
local inputIndex = 0
local output = {}
local environment = {
    colors = { white = 1, yellow = 2, red = 3 },
    print = function(value) output[#output + 1] = tostring(value or "") end,
    write = function(value) output[#output + 1] = tostring(value or "") end,
    term = { setTextColor = function() end },
}

environment.read = function()
    inputIndex = inputIndex + 1
    local value = inputs[inputIndex]

    if type(value) == "table" and value.error ~= nil then
        error(value.error, 0)
    end

    return value
end

setmetatable(environment, { __index = _G })
environment._G = environment

local guard = assert(hostLoadfile(
    "src/dickos/lib/fs_guard.lua",
    "t",
    environment
))()

local normal = {
    user = "nano",
    uid = 1000,
    effectiveUser = "nano",
    effectiveUID = 1000,
    isAdmin = true,
    isElevated = false,
    home = "/dickos/home/nano",
    cwd = "/dickos/home/nano/project",
}
local elevated = {
    user = "nano",
    uid = 1000,
    effectiveUser = "root",
    effectiveUID = 0,
    isAdmin = true,
    isElevated = true,
    home = normal.home,
    cwd = normal.cwd,
}

assert(guard.normalize("/a//b/./c/../d") == "/a/b/d")
assert(guard.normalize("/../../a") == "/a")
assert(guard.normalize("/") == "/")
assert(guard.normalize("relative") == nil)
assert(guard.resolve(normal, ".") == normal.cwd)
assert(guard.resolve(normal, "..") == "/dickos/home/nano")
assert(guard.resolve(normal, "~") == normal.home)
assert(guard.resolve(normal, "~/x") == "/dickos/home/nano/x")
assert(guard.resolve(normal, "../x") == "/dickos/home/nano/x")
assert(guard.resolve(normal, "/x/../y") == "/y")

assert(guard.isWithin("/dickos/system", "/dickos/system"))
assert(guard.isWithin("/dickos/system/init.lua", "/dickos/system"))
assert(not guard.isWithin("/dickos/systematic", "/dickos/system"))
assert(not guard.isWithin("/dickos/home/nano-old", normal.home))

local function risk(path, operation, context)
    return assert(guard.inspect(path, operation or "write", context or normal)).risk
end

assert(risk("/dickos/home/nano/file") == "ordinary")
assert(risk("/dickos/home/nano") == "ordinary")
assert(risk("/dickos/home/nano-old/file") == "protected")
assert(risk("/dickos/home/other/file") == "protected")
assert(risk("/dickos/tmp/work") == "ordinary")
assert(risk("/dickos/tmp") == "ordinary")
assert(risk("/dickos/tmp-old/work") == "protected")
assert(risk("/outside/file") == "ordinary")
assert(risk("/dickos/etc/system.cfg") == "protected")
for _, path in ipairs({
    "/dickos",
    "/dickos/bin",
    "/dickos/services",
    "/dickos/var",
    "/dickos/home/root",
}) do
    assert(risk(path) == "protected", path)
end
assert(risk("/dickos/system/init.lua") == "critical")
assert(risk("/dickos/systematic/file") == "protected")
assert(risk("/dickos/lib/fs_guard.lua") == "critical")

for _, path in ipairs({
    "/startup.lua",
    "/.settings",
    "/dickos/etc/users.db",
    "/dickos/etc/version",
    "/dickos/etc/hostname",
    "/dickos/etc/machine-id",
}) do
    assert(risk(path) == "critical", path)
end

assert(risk("/", "remove") == "catastrophic")
assert(risk("/dickos", "move_source") == "catastrophic")
assert(risk("/", "write") == "ordinary")
assert(risk("/dickos", "write") == "protected")

local ordinaryInspection = assert(guard.inspect(
    "/dickos/home/nano/file",
    "write",
    normal
))
assert(guard.authorize({ ordinaryInspection }, normal))

local protectedInspection = assert(guard.inspect(
    "/dickos/etc/system.cfg",
    "write",
    normal
))
local allowed, denial = guard.authorize({ protectedInspection }, normal)
assert(not allowed)
assert(string.find(denial, "use sudo", 1, true))

-- An admin flag alone, an effective UID alone, or an elevation marker alone
-- cannot pass the mutation boundary. The complete shell-created tuple can.
local forgedAdmin = {}
for key, value in pairs(normal) do forgedAdmin[key] = value end
forgedAdmin.effectiveUID = 0
forgedAdmin.effectiveUser = "root"
assert(not guard.authorize({ protectedInspection }, forgedAdmin))

local forgedElevation = {}
for key, value in pairs(normal) do forgedElevation[key] = value end
forgedElevation.isElevated = true
assert(not guard.authorize({ protectedInspection }, forgedElevation))

local forgedNonAdminRoot = {}
for key, value in pairs(elevated) do forgedNonAdminRoot[key] = value end
forgedNonAdminRoot.isAdmin = false
assert(not guard.authorize({ protectedInspection }, forgedNonAdminRoot))

local elevatedInspection = assert(guard.inspect(
    "/dickos/etc/system.cfg",
    "write",
    elevated
))
assert(guard.authorize({ elevatedInspection }, elevated))

local criticalInspection = assert(guard.inspect(
    "/startup.lua",
    "write",
    elevated
))
inputs = { "/startup.lua" }
inputIndex = 0
assert(guard.confirm({ criticalInspection }, "rm", elevated))
local criticalOutput = table.concat(output, "\n")
assert(string.find(criticalOutput, "DANGER: CRITICAL", 1, true))
assert(string.find(criticalOutput, "Operation: rm", 1, true))
assert(string.find(criticalOutput, "Stage-0", 1, true))

inputs = { "" }
inputIndex = 0
local wrongConfirmation, wrongReason = guard.confirm(
    { criticalInspection },
    "rm",
    elevated
)
assert(not wrongConfirmation and wrongReason == "mismatch")

inputs = { "/startup.lua-wrong" }
inputIndex = 0
assert(not guard.confirm({ criticalInspection }, "rm", elevated))

inputs = { { error = "Terminated" } }
inputIndex = 0
local terminatedConfirmation, terminatedReason =
    guard.confirm({ criticalInspection }, "rm", elevated)
assert(not terminatedConfirmation and terminatedReason == "cancelled")

local catastrophicInspection = assert(guard.inspect(
    "/dickos",
    "remove",
    elevated
))
inputs = { "/dickos" }
inputIndex = 0
assert(guard.confirm({ catastrophicInspection }, "rm", elevated))
assert(string.find(table.concat(output, "\n"), "DANGER", 1, true))

io.stdout:write("filesystem guard tests: PASS\n")
