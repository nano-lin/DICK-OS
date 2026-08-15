-- DICK/OS bootstrap installer
-- Version: 0.1.0-unstable

-- `local` keeps a name inside this installer instead of adding it to Lua's
-- global environment. This prevents constants and helper functions from
-- accidentally colliding with CC:Tweaked APIs or other programs.
local VERSION = "0.1.0-unstable"
local ROOT_PATH = "/"
local INSTALL_PATH = "/dickos"

local MIB = 1024 * 1024
local MINIMUM_CAPACITY = 4 * MIB
local RECOMMENDED_CAPACITY = 16 * MIB

-- These flags let the final error handler distinguish a preflight failure
-- from an unexpected error during deployment. Only a directory tree which
-- this run started creating may be removed by the rollback code.
local deploymentStarted = false
local deploymentFinished = false

-- CC:Tweaked's `term` API controls the computer's text terminal. Status
-- colours are optional presentation: a non-colour terminal must still be able
-- to display a useful rejection message.
local function setStatusColor(color)
    if term.isColor() then
        term.setTextColor(color)
    end
end

local function resetTextColor()
    term.setTextColor(colors.white)
end

local function ok(message)
    setStatusColor(colors.lime)
    write("[ OK ] ")
    resetTextColor()
    print(message)
end

local function info(message)
    setStatusColor(colors.lightBlue)
    write("[ .. ] ")
    resetTextColor()
    print(message)
end

local function warn(message)
    setStatusColor(colors.yellow)
    write("[WARN] ")
    resetTextColor()
    print(message)
end

local function fail(message)
    setStatusColor(colors.red)
    write("[FAIL] ")
    resetTextColor()
    print(message)
end

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    resetTextColor()
    term.clear()
    term.setCursorPos(1, 1)
end

local function printHeader()
    print("DICK/OS " .. VERSION)
    print("Distributed Infrastructure & Computer Kit")
    print()
    print("Installer preflight")
    print("-------------------")
    print()
end

-- Validate that this program is running on an Advanced Computer.
--
-- Some device-specific CC:T APIs exist only on their matching device. In Lua,
-- `nil` means that a value is absent. Checking these globals against nil lets
-- us reject turtles, pocket computers, and command computers before using the
-- colour terminal as the Advanced Computer capability check.
local function validateHardware()
    if turtle ~= nil then
        fail("Advanced Computer required.")
        info("Turtles cannot run the full DICK/OS installation.")
        return false
    end

    if pocket ~= nil then
        fail("Advanced Computer required.")
        info("Pocket Computers cannot run the full DICK/OS installation.")
        return false
    end

    if commands ~= nil then
        fail("Advanced Computer required.")
        info("Command Computers cannot run the full DICK/OS installation.")
        return false
    end

    -- In the current design, colour support is the standard CC:T capability
    -- used to distinguish an Advanced Computer from a Basic Computer.
    if not term.isColor() then
        fail("Advanced Computer required.")
        return false
    end

    ok("Advanced Computer detected")
    return true
end

-- Query the capacity and free space of the computer's main filesystem.
--
-- `fs.getCapacity` and `fs.getFreeSpace` are CC:Tweaked functions, not desktop
-- Lua functions. `pcall` (protected call) catches a Lua error and returns a
-- success boolean instead of allowing a low-level exception to become the
-- only message the user sees.
--
-- Lua functions may return several values. On success this helper returns the
-- numeric capacity, numeric free space, and nil for the error. On failure it
-- returns nil values followed by a diagnostic string.
local function getStorageInformation()
    local capacityCallSucceeded, capacityOrError = pcall(
        fs.getCapacity,
        ROOT_PATH
    )

    if not capacityCallSucceeded then
        return nil, nil, "Capacity query failed: " .. tostring(capacityOrError)
    end

    if type(capacityOrError) ~= "number" then
        return nil, nil, "The main filesystem did not report a numeric capacity."
    end

    local freeSpaceCallSucceeded, freeSpaceOrError = pcall(
        fs.getFreeSpace,
        ROOT_PATH
    )

    if not freeSpaceCallSucceeded then
        return nil, nil, "Free-space query failed: " .. tostring(freeSpaceOrError)
    end

    if type(freeSpaceOrError) ~= "number" then
        return nil, nil, "The main filesystem did not report numeric free space."
    end

    return capacityOrError, freeSpaceOrError, nil
end

-- Check the storage policy without changing the filesystem. The 4 MiB minimum
-- applies to the total main-filesystem capacity. Free space is reported too,
-- so a later write failure can be diagnosed rather than hidden.
--
-- TODO: Once DICK/OS has a real installation payload, calculate the required
-- free space from that payload and enforce the calculated value here. Until
-- then, an arbitrary minimum-free-space threshold would not describe an actual
-- installation requirement, so only total capacity has a minimum.
local function validateStorage()
    local capacity, freeSpace, storageError = getStorageInformation()

    if capacity == nil then
        fail("Unable to determine storage capacity and free space.")
        print("       Details: " .. tostring(storageError))
        return false
    end

    info(string.format(
        "Storage: %.2f MiB total, %.2f MiB free",
        capacity / MIB,
        freeSpace / MIB
    ))

    if capacity < MINIMUM_CAPACITY then
        fail("DICK/OS requires at least 4 MiB of storage capacity.")
        return false
    end

    ok("Minimum storage requirement satisfied")

    if capacity >= RECOMMENDED_CAPACITY then
        ok("Recommended 16 MiB storage available")
    else
        warn("16 MiB total storage capacity is recommended")
    end

    return true
end

-- Hostnames use a deliberately small portable character set. Lua patterns
-- are a lightweight matching language: `^` and `$` anchor the whole value,
-- while `[A-Za-z0-9-]+` means one or more allowed ASCII characters.
-- The function returns both a boolean and a user-facing validation message.
local function validateHostname(hostname)
    if #hostname < 1 or #hostname > 24 then
        return false, "Hostname must contain 1 to 24 characters."
    end

    if not string.match(hostname, "^[A-Za-z0-9-]+$") then
        return false, "Hostname may contain only letters, digits, and hyphens."
    end

    return true, nil
end

-- Usernames start with a lowercase letter. The `*` in the second character
-- class permits zero or more additional lowercase letters, digits,
-- underscores, or hyphens.
local function validateUsername(username)
    if #username < 1 or #username > 16 then
        return false, "Username must contain 1 to 16 characters."
    end

    if not string.match(username, "^[a-z][a-z0-9_-]*$") then
        return false,
            "Username must start with a lowercase letter and use only " ..
            "a-z, 0-9, underscore, or hyphen."
    end

    return true, nil
end

-- Ask for a value until its validator accepts it.
--
-- `validator` is a callback: Lua functions can be stored in variables and
-- passed to other functions. Calling it here avoids duplicating the same input
-- loop for hostname and username while keeping their rules separate.
local function promptForValidatedValue(promptText, validator)
    while true do
        write(promptText)

        -- `read()` is supplied by CraftOS. It waits for terminal input and
        -- returns the entered text as a Lua string.
        local value = read()
        local valueIsValid, validationError = validator(value)

        if valueIsValid then
            return value
        end

        fail(validationError)
        print("Please try again.")
        print()
    end
end

-- Exercise the intended password-entry UX without creating authentication.
-- Passing "*" to CC:T's `read` function replaces displayed characters with
-- asterisks. The returned strings still contain the real input, so they remain
-- local to this function and are never returned, logged, or written to disk.
local function confirmPasswordEntry()
    while true do
        write("Password: ")
        local password = read("*")

        write("Confirm password: ")
        local confirmation = read("*")

        if password == confirmation then
            return
        end

        fail("Passwords do not match.")
        print("Please enter both passwords again.")
        print()
    end
end

-- Generate the initial DICK/OS installation identity in one isolated helper.
--
-- A seed is the starting value from which a pseudo-random number generator
-- produces its sequence. `math.randomseed` resets Lua's global generator to a
-- known starting state, so this result does not silently depend on random calls
-- made earlier by CraftOS or another program. The current UTC time in
-- milliseconds makes repeated installations at different times start from
-- different states, while the CC computer ID also varies the seed by machine.
--
-- This is not cryptographic protection: the time and CC ID are observable,
-- pseudo-random output is predictable, and a four-digit suffix has only 65,536
-- possible values. Machine IDs are installation identifiers rather than
-- passwords or authentication tokens, so this best-effort uniqueness is
-- sufficient for the current unstable milestone.
--
-- A numerically indexed Lua table collects one uppercase hexadecimal character
-- at a time, then `table.concat` joins the characters. Keeping the seed and
-- suffix algorithm here lets a future unstable version replace both without
-- spreading identity rules throughout the installer.
local function generateMachineID(ccID)
    local hexadecimalDigits = "0123456789ABCDEF"
    local suffixCharacters = {}
    local seed = os.epoch("utc") + ccID

    math.randomseed(seed)

    for position = 1, 4 do
        local digitIndex = math.random(1, #hexadecimalDigits)
        suffixCharacters[position] = string.sub(
            hexadecimalDigits,
            digitIndex,
            digitIndex
        )
    end

    return "DCK-C-" .. tostring(ccID) .. "-" .. table.concat(suffixCharacters)
end

local function printInstallationSummary(hostname, ownerUsername, machineID)
    print()
    print("Installation summary")
    print("--------------------")
    print("Hostname:   " .. hostname)
    print("Owner:      " .. ownerUsername)
    print("Machine ID: " .. machineID)
    print()
end

-- Installation requires an explicit affirmative answer. `string.lower`
-- makes Y/YES equivalent to y/yes; every other answer follows the safe default
-- and cancels without touching the filesystem.
local function confirmInstallation()
    write("Install DICK/OS? [y/N]: ")
    local answer = string.lower(read())

    return answer == "y" or answer == "yes"
end

-- Create the directory layout for this milestone.
--
-- A Lua table is used as an ordered list. `ipairs` visits its numeric entries
-- from first to last; the conventional `_` variable means that the numeric
-- index is intentionally unused. CC:T's `fs.makeDir` creates missing parent
-- directories too. Each call is protected and then verified because failure
-- of any directory is fatal to this installation.
local function createDirectoryLayout(ownerUsername)
    local directories = {
        "/dickos/system",
        "/dickos/lib",
        "/dickos/bin",
        "/dickos/services",
        "/dickos/etc",
        "/dickos/home/" .. ownerUsername,
        "/dickos/var/log",
        "/dickos/var/lib",
        "/dickos/var/integrity",
        "/dickos/tmp",
    }

    for _, path in ipairs(directories) do
        local makeDirSucceeded, makeDirError = pcall(fs.makeDir, path)

        if not makeDirSucceeded then
            return false,
                "Unable to create " .. path .. ": " .. tostring(makeDirError)
        end

        if not fs.isDir(path) then
            return false, "Directory was not created: " .. path
        end
    end

    return true, nil
end

-- Write one metadata value followed by a newline.
--
-- `fs.open` returns a CC:T file handle, not the file contents. A failed open
-- returns nil plus an error message. Successful handles must be closed so
-- buffered data is committed. Writes and closes are protected separately so
-- the installer can report which operation failed and attempt to release the
-- handle even after a write error.
local function writeMetadataFile(path, contents)
    local file, openError = fs.open(path, "w")

    if file == nil then
        return false, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local writeSucceeded, writeError = pcall(file.writeLine, contents)

    if not writeSucceeded then
        pcall(file.close)
        return false, "Unable to write " .. path .. ": " .. tostring(writeError)
    end

    local closeSucceeded, closeError = pcall(file.close)

    if not closeSucceeded then
        return false, "Unable to close " .. path .. ": " .. tostring(closeError)
    end

    return true, nil
end

-- Only the three metadata files implemented by this milestone are deployed.
-- Each table entry names both its destination and its exact value; no fake
-- user, service, network, or integrity databases are created.
local function writeInitialMetadata(hostname, machineID)
    local metadataFiles = {
        {
            path = "/dickos/etc/version",
            contents = VERSION,
        },
        {
            path = "/dickos/etc/hostname",
            contents = hostname,
        },
        {
            path = "/dickos/etc/machine-id",
            contents = machineID,
        },
    }

    for _, metadata in ipairs(metadataFiles) do
        local writeSucceeded, writeError = writeMetadataFile(
            metadata.path,
            metadata.contents
        )

        if not writeSucceeded then
            return false, writeError
        end
    end

    return true, nil
end

-- Roll back only `/dickos`, which preflight proved absent before this run began
-- deployment. Unrelated user data elsewhere on the computer is never touched.
local function removePartialInstallation()
    if not fs.exists(INSTALL_PATH) then
        return true, nil
    end

    local deleteSucceeded, deleteError = pcall(fs.delete, INSTALL_PATH)

    if not deleteSucceeded then
        return false, tostring(deleteError)
    end

    if fs.exists(INSTALL_PATH) then
        return false, "The path still exists after the rollback attempt."
    end

    return true, nil
end

local function reportDeploymentFailure(message, details)
    fail(message)

    if details ~= nil then
        print("       Details: " .. tostring(details))
    end

    local rollbackSucceeded, rollbackError = removePartialInstallation()

    if rollbackSucceeded then
        info("Partial /dickos installation removed")
        deploymentStarted = false
    else
        warn("Partial files may remain under /dickos.")
        print("       Rollback details: " .. tostring(rollbackError))
    end
end

-- Computer labels are useful CraftOS metadata, but not part of the DICK/OS
-- filesystem transaction. Failure is returned as a warning and does not turn
-- an otherwise complete base installation into a false failure.
local function trySetComputerLabel(hostname)
    local labelSucceeded, labelError = pcall(os.setComputerLabel, hostname)

    if not labelSucceeded then
        return false, tostring(labelError)
    end

    return true, nil
end

local function printSuccess(hostname, ownerUsername, machineID)
    print()
    print("DICK/OS base environment installed.")
    print()
    print("Machine ID: " .. machineID)
    print("Hostname:   " .. hostname)
    print("Owner:      " .. ownerUsername)
    print()
    print("Authentication subsystem is not installed yet.")
    print("The supplied password was not written to disk.")
end

local function runInstaller()
    prepareTerminal()
    printHeader()

    if not validateHardware() then
        return
    end

    -- The CraftOS computer ID identifies the CC computer. It is deliberately
    -- displayed separately from the generated DICK/OS machine ID and hostname.
    local ccID = os.getComputerID()
    ok("CC ID: " .. tostring(ccID))

    if not validateStorage() then
        return
    end

    -- This check is still preflight: `fs.exists` only reads filesystem state.
    -- Upgrade, reinstall, repair, and migration are intentionally not offered.
    if fs.exists(INSTALL_PATH) then
        warn("An existing /dickos path was detected.")
        print("Upgrade, reinstall, repair, and migration are not available yet.")
        print("No files were changed.")
        return
    end

    print()
    setStatusColor(colors.lime)
    print("Preflight PASSED")
    resetTextColor()

    print()
    print("Initial setup")
    print("-------------")
    print()

    local hostname = promptForValidatedValue("Hostname: ", validateHostname)
    local ownerUsername = promptForValidatedValue(
        "Owner username: ",
        validateUsername
    )

    confirmPasswordEntry()

    local machineID = generateMachineID(ccID)
    printInstallationSummary(hostname, ownerUsername, machineID)

    if not confirmInstallation() then
        print()
        print("Installation cancelled.")
        return
    end

    -- Recheck immediately before the first write. This prevents an existing
    -- path from being overwritten if filesystem state changed during setup.
    if fs.exists(INSTALL_PATH) then
        print()
        fail("The /dickos path appeared before deployment could begin.")
        print("No files were overwritten.")
        return
    end

    print()
    info("Creating DICK/OS base filesystem")
    deploymentStarted = true

    local layoutSucceeded, layoutError = createDirectoryLayout(ownerUsername)

    if not layoutSucceeded then
        reportDeploymentFailure("Unable to create the filesystem layout.", layoutError)
        return
    end

    local metadataSucceeded, metadataError = writeInitialMetadata(
        hostname,
        machineID
    )

    if not metadataSucceeded then
        reportDeploymentFailure("Unable to write system metadata.", metadataError)
        return
    end

    deploymentFinished = true
    ok("Base filesystem and metadata installed")

    local labelSucceeded, labelError = trySetComputerLabel(hostname)

    if labelSucceeded then
        ok("Computer label set to " .. hostname)
    else
        warn("Unable to set the computer label; installation can continue.")
        print("       Details: " .. tostring(labelError))
    end

    printSuccess(hostname, ownerUsername, machineID)
end

-- Catch any error not handled closer to its operation. If deployment had
-- started but had not completed, make a best-effort rollback before returning
-- control to CraftOS. Preflight and cancellation never set `deploymentStarted`,
-- so this handler cannot delete anything in those paths.
local runSucceeded, unexpectedError = pcall(runInstaller)

resetTextColor()

if not runSucceeded then
    fail("Installer stopped unexpectedly.")
    print("       Details: " .. tostring(unexpectedError))

    if deploymentStarted and not deploymentFinished then
        local rollbackSucceeded, rollbackError = removePartialInstallation()

        if rollbackSucceeded then
            info("Partial /dickos installation removed")
        else
            warn("Partial files may remain under /dickos.")
            print("       Rollback details: " .. tostring(rollbackError))
        end
    end
end
