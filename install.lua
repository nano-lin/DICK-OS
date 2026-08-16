-- DICK/OS bootstrap installer
-- Version: 0.1.0-unstable

-- `local` keeps a name inside this installer instead of adding it to Lua's
-- global environment. This prevents constants and helper functions from
-- accidentally colliding with CC:Tweaked APIs or other programs.
local VERSION = "0.1.0-unstable"
local ROOT_PATH = "/"
local INSTALL_PATH = "/dickos"
local STARTUP_PATH = "/startup.lua"
local ALTERNATE_STARTUP_PATH = "/startup"

local LOCAL_STARTUP_SETTING = "shell.allow_startup"
local DISK_STARTUP_SETTING = "shell.allow_disk_startup"

local MIB = 1024 * 1024
local MINIMUM_CAPACITY = 4 * MIB
local RECOMMENDED_CAPACITY = 16 * MIB

-- These flags let the final error handler distinguish a preflight failure
-- from an unexpected error during deployment. Ownership is tracked separately
-- for `/dickos`, `/startup.lua`, and persistent boot settings so rollback never
-- removes or replaces state which existed before this installer run.
local deploymentStarted = false
local deploymentFinished = false
local startupCreatedByInstaller = false
local bootSettingsChanged = false
local bootSettingsSnapshot = nil

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

-- Find any local startup path which would conflict with DICK/OS Stage-0.
-- CraftOS runs an extensionless `/startup` file or `/startup.lua`, followed by
-- programs inside a `/startup` directory. A directory therefore conflicts too:
-- after an explicit Stage-0 rescue return, its programs could run before the
-- CraftOS shell appears. Refusing either existing path keeps that transition
-- predictable without attempting an unsafe merge, backup, or startup chain.
local function findStartupConflict()
    if fs.exists(STARTUP_PATH) then
        return STARTUP_PATH
    end

    if fs.exists(ALTERNATE_STARTUP_PATH) then
        return ALTERNATE_STARTUP_PATH
    end

    return nil
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

-- Read one repository source file into memory during preflight.
--
-- This milestone deliberately uses a small local payload instead of inventing
-- a downloader or package manager. `shell.getRunningProgram` identifies the
-- installer file being executed, and the payload is expected in its sibling
-- `src` directory. Reading the source before confirmation is safe because
-- `fs.open` with mode "r" does not change the filesystem.
local function readSourceFile(path)
    local file, openError = fs.open(path, "r")

    if file == nil then
        return nil, "Unable to open source file " .. path .. ": " ..
            tostring(openError)
    end

    local readSucceeded, contentsOrError = pcall(file.readAll)
    local closeSucceeded, closeError = pcall(file.close)

    if not readSucceeded then
        return nil, "Unable to read source file " .. path .. ": " ..
            tostring(contentsOrError)
    end

    if not closeSucceeded then
        return nil, "Unable to close source file " .. path .. ": " ..
            tostring(closeError)
    end

    if contentsOrError == nil or contentsOrError == "" then
        return nil, "Source file is empty: " .. path
    end

    return contentsOrError, nil
end

-- Load the four real Milestone 2 programs into a small payload table.
--
-- Each entry maps a repository source path to its final installed path. The
-- ordering is intentional: init, Recovery, and dickfetch are deployed before
-- startup.lua, so the boot entry point is the last program file exposed on
-- disk. No generic package/dependency framework is needed for four fixed
-- bootstrap files.
local function loadInstallationPayload()
    local runningProgram = shell.getRunningProgram()
    local installerDirectory = fs.getDir(runningProgram)
    local sourceRoot = fs.combine(installerDirectory, "src")
    local payload = {
        {
            sourcePath = fs.combine(sourceRoot, "dickos/system/init.lua"),
            destinationPath = "/dickos/system/init.lua",
        },
        {
            sourcePath = fs.combine(sourceRoot, "dickos/system/recovery.lua"),
            destinationPath = "/dickos/system/recovery.lua",
        },
        {
            sourcePath = fs.combine(sourceRoot, "dickos/bin/dickfetch.lua"),
            destinationPath = "/dickos/bin/dickfetch.lua",
        },
        {
            sourcePath = fs.combine(sourceRoot, "startup.lua"),
            destinationPath = STARTUP_PATH,
        },
    }

    for _, payloadFile in ipairs(payload) do
        local contents, readError = readSourceFile(payloadFile.sourcePath)

        if contents == nil then
            return nil, readError
        end

        payloadFile.contents = contents
    end

    return payload, nil
end

-- Capture whether each boot setting has an explicit value, not merely its
-- effective default. `settings.getDetails` reports this with its boolean
-- `changed` field. Its `value` field may contain either an explicit value or a
-- definition's default, so checking value against nil would lose that crucial
-- distinction. Remembering `changed` lets rollback call `settings.unset`
-- instead of permanently writing what used to be only a default.
local function captureBootSettings()
    local settingNames = {
        LOCAL_STARTUP_SETTING,
        DISK_STARTUP_SETTING,
    }
    local snapshot = {}

    for _, settingName in ipairs(settingNames) do
        local detailsCallSucceeded, detailsOrError = pcall(
            settings.getDetails,
            settingName
        )

        if not detailsCallSucceeded then
            return nil, "Unable to inspect setting " .. settingName .. ": " ..
                tostring(detailsOrError)
        end

        if type(detailsOrError) ~= "table" then
            return nil, "Setting details were unavailable for " .. settingName
        end

        snapshot[#snapshot + 1] = {
            name = settingName,
            hadExplicitValue = detailsOrError.changed == true,
            value = detailsOrError.value,
        }
    end

    return snapshot, nil
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

-- Write exact text to one installed file.
--
-- `fs.open` returns a CC:T file handle, not the file contents. A failed open
-- returns nil plus an error message. Successful handles must be closed so
-- buffered data is committed. Writes and closes are protected separately so
-- the installer can report which operation failed and attempt to release the
-- handle even after a write error.
local function writeTextFile(path, contents)
    local file, openError = fs.open(path, "w")

    if file == nil then
        return false, "Unable to open " .. path .. ": " .. tostring(openError)
    end

    local writeSucceeded, writeError = pcall(file.write, contents)

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
            contents = VERSION .. "\n",
        },
        {
            path = "/dickos/etc/hostname",
            contents = hostname .. "\n",
        },
        {
            path = "/dickos/etc/machine-id",
            contents = machineID .. "\n",
        },
    }

    for _, metadata in ipairs(metadataFiles) do
        local writeSucceeded, writeError = writeTextFile(
            metadata.path,
            metadata.contents
        )

        if not writeSucceeded then
            return false, writeError
        end
    end

    return true, nil
end

-- Deploy the already-read source payload to its final paths.
--
-- The startup ownership flag is set before attempting its write. Preflight and
-- the immediate pre-deployment recheck proved that `/startup.lua` was absent,
-- so any partial file created by this attempt belongs to this installer and may
-- be removed safely during rollback.
local function writeSystemPayload(payload)
    for _, payloadFile in ipairs(payload) do
        if payloadFile.destinationPath == STARTUP_PATH then
            if fs.exists(STARTUP_PATH) then
                return false,
                    "Refusing to overwrite a newly appeared " .. STARTUP_PATH
            end

            startupCreatedByInstaller = true
        end

        local writeSucceeded, writeError = writeTextFile(
            payloadFile.destinationPath,
            payloadFile.contents
        )

        if not writeSucceeded then
            return false, writeError
        end

        if not fs.exists(payloadFile.destinationPath) then
            return false,
                "Installed file is missing: " .. payloadFile.destinationPath
        end
    end

    return true, nil
end

-- Persist the CraftOS startup policy required by DICK/OS.
--
-- Official CC:T startup settings control two separate decisions. Local startup
-- must remain enabled so `/startup.lua` runs, while disk startup is disabled so
-- a disk cannot run its own startup before the local Stage-0. `settings.set`
-- changes only the in-memory setting value and queues a setting_changed event;
-- `settings.save` is required to write those values to `/.settings` for the
-- next reboot or cold start.
--
-- CraftOS itself remains available: Recovery may explicitly return from
-- startup.lua into the current CraftOS shell. The persistent policy only makes
-- the next boot enter DICK/OS again.
local function applyBootSettings()
    bootSettingsChanged = true

    local localSetSucceeded, localSetError = pcall(
        settings.set,
        LOCAL_STARTUP_SETTING,
        true
    )

    if not localSetSucceeded then
        return false, "Unable to enable local startup: " ..
            tostring(localSetError)
    end

    local diskSetSucceeded, diskSetError = pcall(
        settings.set,
        DISK_STARTUP_SETTING,
        false
    )

    if not diskSetSucceeded then
        return false, "Unable to disable disk startup: " ..
            tostring(diskSetError)
    end

    local saveCallSucceeded, savedOrError = pcall(settings.save)

    if not saveCallSucceeded then
        return false, "Unable to save startup settings: " ..
            tostring(savedOrError)
    end

    if savedOrError ~= true then
        return false, "settings.save reported that startup settings were not saved."
    end

    return true, nil
end

-- Restore every boot setting to its exact pre-install explicit/default state.
-- The restore is attempted even when one individual operation fails, and the
-- combined result is saved afterwards so rollback is persistent across reboot.
local function restoreBootSettings()
    if not bootSettingsChanged then
        return true, nil
    end

    local restoreErrors = {}

    for _, previousSetting in ipairs(bootSettingsSnapshot) do
        local restoreSucceeded
        local restoreError

        if previousSetting.hadExplicitValue then
            restoreSucceeded, restoreError = pcall(
                settings.set,
                previousSetting.name,
                previousSetting.value
            )
        else
            restoreSucceeded, restoreError = pcall(
                settings.unset,
                previousSetting.name
            )
        end

        if not restoreSucceeded then
            restoreErrors[#restoreErrors + 1] =
                previousSetting.name .. ": " .. tostring(restoreError)
        end
    end

    local saveCallSucceeded, savedOrError = pcall(settings.save)

    if not saveCallSucceeded then
        restoreErrors[#restoreErrors + 1] =
            "settings.save: " .. tostring(savedOrError)
    elseif savedOrError ~= true then
        restoreErrors[#restoreErrors + 1] = "settings.save returned false"
    end

    if #restoreErrors > 0 then
        return false, table.concat(restoreErrors, "; ")
    end

    bootSettingsChanged = false
    return true, nil
end

-- Roll back only resources which this installer owns.
--
-- `/dickos` was absent before deployment, so its partial tree belongs to this
-- run. `/startup.lua` is more sensitive: it is deleted only when the ownership
-- flag proves this run attempted to create it. Previous startup settings are
-- restored before files are removed, and unrelated paths are never touched.
local function rollbackPartialInstallation()
    local rollbackErrors = {}
    local settingsRestored, settingsRestoreError = restoreBootSettings()

    if not settingsRestored then
        rollbackErrors[#rollbackErrors + 1] =
            "startup settings: " .. tostring(settingsRestoreError)
    end

    if startupCreatedByInstaller and fs.exists(STARTUP_PATH) then
        local deleteSucceeded, deleteError = pcall(fs.delete, STARTUP_PATH)

        if not deleteSucceeded then
            rollbackErrors[#rollbackErrors + 1] =
                STARTUP_PATH .. ": " .. tostring(deleteError)
        elseif fs.exists(STARTUP_PATH) then
            rollbackErrors[#rollbackErrors + 1] =
                STARTUP_PATH .. ": path still exists after deletion"
        else
            startupCreatedByInstaller = false
        end
    end

    if fs.exists(INSTALL_PATH) then
        local deleteSucceeded, deleteError = pcall(fs.delete, INSTALL_PATH)

        if not deleteSucceeded then
            rollbackErrors[#rollbackErrors + 1] =
                INSTALL_PATH .. ": " .. tostring(deleteError)
        elseif fs.exists(INSTALL_PATH) then
            rollbackErrors[#rollbackErrors + 1] =
                INSTALL_PATH .. ": path still exists after deletion"
        end
    end

    if #rollbackErrors > 0 then
        return false, table.concat(rollbackErrors, "; ")
    end

    deploymentStarted = false
    return true, nil
end

local function reportDeploymentFailure(message, details)
    fail(message)

    if details ~= nil then
        print("       Details: " .. tostring(details))
    end

    local rollbackSucceeded, rollbackError = rollbackPartialInstallation()

    if rollbackSucceeded then
        info("Partial installation and boot settings rolled back")
    else
        warn("Partial files or startup settings may remain.")
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
    print("DICK/OS bootstrap environment installed.")
    print()
    print("Machine ID: " .. machineID)
    print("Hostname:   " .. hostname)
    print("Owner:      " .. ownerUsername)
    print()
    print("Stage-0, minimal init, Recovery, and dickfetch are installed.")
    print("Reboot or power on the computer to enter DICK/OS.")
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

    local startupConflict = findStartupConflict()

    if startupConflict ~= nil then
        fail("Existing " .. startupConflict .. " detected.")
        print("DICK/OS will not overwrite an existing startup program.")
        print("No files were changed.")
        return
    end

    local installationPayload, payloadError = loadInstallationPayload()

    if installationPayload == nil then
        fail("Unable to load the Milestone 2 installation payload.")
        print("       Details: " .. tostring(payloadError))
        print("No files were changed.")
        return
    end

    ok("Stage-0, init, Recovery, and dickfetch source payload available")

    local capturedSettings, settingsCaptureError = captureBootSettings()

    if capturedSettings == nil then
        fail("Unable to inspect CraftOS startup settings.")
        print("       Details: " .. tostring(settingsCaptureError))
        print("No files were changed.")
        return
    end

    bootSettingsSnapshot = capturedSettings

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

    -- Recheck both owned targets immediately before the first write. This
    -- prevents an existing installation or startup program from being
    -- overwritten if filesystem state changed during setup.
    if fs.exists(INSTALL_PATH) then
        print()
        fail("The /dickos path appeared before deployment could begin.")
        print("No files were overwritten.")
        return
    end

    startupConflict = findStartupConflict()

    if startupConflict ~= nil then
        print()
        fail(startupConflict .. " appeared before deployment could begin.")
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

    local payloadSucceeded, payloadWriteError = writeSystemPayload(
        installationPayload
    )

    if not payloadSucceeded then
        reportDeploymentFailure(
            "Unable to install Stage-0, init, Recovery, or dickfetch.",
            payloadWriteError
        )
        return
    end

    local settingsSucceeded, settingsError = applyBootSettings()

    if not settingsSucceeded then
        reportDeploymentFailure(
            "Unable to persist the DICK/OS startup policy.",
            settingsError
        )
        return
    end

    deploymentFinished = true
    ok("Base filesystem, boot programs, and metadata installed")
    ok("Local startup enabled; disk startup disabled")

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
        local rollbackSucceeded, rollbackError = rollbackPartialInstallation()

        if rollbackSucceeded then
            info("Partial installation and boot settings rolled back")
        else
            warn("Partial files or startup settings may remain.")
            print("       Rollback details: " .. tostring(rollbackError))
        end
    end
end
