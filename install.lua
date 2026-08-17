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

-- The development channel is intentionally expressed as separate repository
-- coordinates. Replacing `main` with a tag or immutable commit later changes
-- the selected source without redesigning URL construction or deployment.
-- `main` is mutable and is not a cryptographic integrity guarantee.
local REPOSITORY_OWNER = "nano-lin"
local REPOSITORY_NAME = "DICK-OS"
local REPOSITORY_REF = "main"
local RAW_CONTENT_ORIGIN = "https://raw.githubusercontent.com"
local MANIFEST_SOURCE_PATH = "manifest.lua"
local EXPECTED_MANIFEST_VERSION = 1
local MAXIMUM_MANIFEST_FILES = 256

local LOCAL_STARTUP_SETTING = "shell.allow_startup"
local DISK_STARTUP_SETTING = "shell.allow_disk_startup"

local MIB = 1024 * 1024
local MINIMUM_CAPACITY = 4 * MIB
local RECOMMENDED_CAPACITY = 16 * MIB

local function formatByteCount(byteCount)
    if byteCount < 1024 then
        return string.format("%d B", byteCount)
    end

    return string.format("%.1f KiB", byteCount / 1024)
end

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
    print("DICK/OS NETWORK INSTALLER")
    print(VERSION)
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

-- Check the local storage policy before spending time on network requests.
-- The 4 MiB minimum applies to total main-filesystem capacity. Exact payload
-- free-space validation occurs after every remote body is available in memory,
-- because only then does the installer know the current content size.
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

-- Compare current free space with the downloaded content which deployment will
-- write. This is a content-byte minimum, not an invented permanent threshold;
-- CC:T filesystem metadata and the existing settings file may still add small
-- implementation overhead, and any real write failure remains rollback-safe.
local function validatePayloadFreeSpace(payloadBytes)
    local _, freeSpace, storageError = getStorageInformation()

    if freeSpace == nil then
        fail("Unable to recheck free space for the downloaded payload.")
        print("       Details: " .. tostring(storageError))
        return false
    end

    info(string.format(
        "Payload requires %s; %s free",
        formatByteCount(payloadBytes),
        formatByteCount(freeSpace)
    ))

    if freeSpace < payloadBytes then
        fail("Not enough free space for the downloaded DICK/OS payload.")
        return false
    end

    ok("Downloaded payload fits in current free space")
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

-- Build one raw-content URL from the selected repository coordinates. Manifest
-- validation below restricts every source to a safe relative `src/...` path,
-- so no downloaded value can inject another host, query, or parent directory.
local function buildRawContentURL(sourcePath)
    return table.concat({
        RAW_CONTENT_ORIGIN,
        REPOSITORY_OWNER,
        REPOSITORY_NAME,
        REPOSITORY_REF,
        sourcePath,
    }, "/")
end

-- HTTP responses are handles backed by network resources and should be closed
-- even on an error path. `pcall` makes cleanup best-effort: a broken handle
-- must not replace the more useful request/read error which caused the abort.
local function closeHTTPResponseBestEffort(response)
    pcall(function()
        if response ~= nil and type(response.close) == "function" then
            response.close()
        end
    end)
end

-- Extract an HTTP status from a failed response when CC:T supplies one. A 404
-- commonly returns `nil, reason, response`; closing that third value prevents
-- a failed request handle from being left open during the remaining preflight.
local function describeHTTPFailure(reason, failureResponse)
    local statusText = nil

    if failureResponse ~= nil then
        local statusSucceeded, statusCode, statusMessage = pcall(function()
            if type(failureResponse.getResponseCode) ~= "function" then
                return nil, nil
            end

            return failureResponse.getResponseCode()
        end)

        if statusSucceeded and type(statusCode) == "number" then
            statusText = tostring(statusCode)

            if type(statusMessage) == "string" and statusMessage ~= "" then
                statusText = statusText .. " " .. statusMessage
            end
        end

        closeHTTPResponseBestEffort(failureResponse)
    end

    if statusText ~= nil then
        return statusText
    end

    if reason == nil or tostring(reason) == "" then
        return "Unknown HTTP failure"
    end

    return tostring(reason)
end

-- Confirm that the HTTP module exists and, where supported, ask CC:T whether
-- the raw GitHub URL is permitted by server configuration. `checkURL` does not
-- contact GitHub; the subsequent manifest request remains the real DNS,
-- connection, timeout, and response check.
local function verifyHTTPTransport(manifestURL)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return false, "CC:T HTTP API is unavailable or disabled."
    end

    if type(http.checkURL) ~= "function" then
        return true, nil
    end

    -- `pcall` places its own success boolean before every value returned by the
    -- protected function. The following names therefore preserve both normal
    -- `checkURL` results without allowing an API exception to escape.
    local checkSucceeded, allowedOrError, blockedReason = pcall(
        http.checkURL,
        manifestURL
    )

    if not checkSucceeded then
        return false, "Unable to check the raw GitHub URL: " ..
            tostring(allowedOrError)
    end

    if allowedOrError ~= true then
        return false, tostring(blockedReason or "Domain not permitted")
    end

    return true, nil
end

-- Download and completely read one HTTP response. CC:T's synchronous
-- `http.get` returns either a response handle or nil plus a reason and
-- sometimes a failing response handle. Every ordinary failure is converted
-- into a short return value rather than leaking a Lua stack trace.
local function fetchRemoteText(sourcePath)
    local url = buildRawContentURL(sourcePath)
    -- On success, `pcall` preserves all of `http.get`'s return values after its
    -- leading boolean. This matters because a failed CC:T request may include
    -- both an error string and a response handle containing an HTTP status.
    local requestSucceeded, response, requestError, failureResponse = pcall(
        http.get,
        url
    )

    if not requestSucceeded then
        return nil, tostring(response)
    end

    if response == nil then
        return nil, describeHTTPFailure(requestError, failureResponse)
    end

    local interfaceSucceeded, readAll, close, getResponseCode = pcall(
        function()
            return response.readAll, response.close, response.getResponseCode
        end
    )

    if not interfaceSucceeded or type(readAll) ~= "function" or
        type(close) ~= "function" or type(getResponseCode) ~= "function" then
        closeHTTPResponseBestEffort(response)
        return nil, "Invalid HTTP response handle"
    end

    local statusSucceeded, statusCode, statusMessage = pcall(getResponseCode)

    if not statusSucceeded or type(statusCode) ~= "number" then
        closeHTTPResponseBestEffort(response)
        return nil, "HTTP response did not provide a valid status code"
    end

    if statusCode < 200 or statusCode >= 300 then
        closeHTTPResponseBestEffort(response)
        return nil, tostring(statusCode) .. " " ..
            tostring(statusMessage or "HTTP error")
    end

    local readSucceeded, contentsOrError = pcall(readAll)
    local closeSucceeded, closeError = pcall(close)

    if not readSucceeded then
        return nil, "Response read failed: " .. tostring(contentsOrError)
    end

    if not closeSucceeded then
        return nil, "Response close failed: " .. tostring(closeError)
    end

    if type(contentsOrError) ~= "string" then
        return nil, "HTTP response body was not text"
    end

    return contentsOrError, nil
end

-- Check individual slash-separated path components. `string.gmatch` returns an
-- iterator function which yields one component on each loop iteration; exact
-- `.` and `..` components are unsafe because filesystems interpret them as the
-- current or parent directory.
local function hasSafePathSegments(path)
    if string.find(path, "//", 1, true) ~= nil or
        string.sub(path, -1) == "/" then
        return false
    end

    for segment in string.gmatch(path, "[^/]+") do
        if segment == "." or segment == ".." or segment == "" then
            return false
        end
    end

    return true
end

-- Repository sources are deliberately restricted to ordinary files below
-- `src/`. The manifest itself is fetched through a local constant and never
-- passes this remote-data validation boundary.
local function isAllowedSourcePath(sourcePath)
    return type(sourcePath) == "string" and #sourcePath <= 240 and
        string.match(sourcePath, "^src/[A-Za-z0-9_%.%/%-]+$") ~= nil and
        hasSafePathSegments(sourcePath)
end

-- Remote targets may write only inside DICK/OS's owned tree, with one explicit
-- exception for Stage-0. Paths containing parent/current segments, doubled
-- separators, or a directory-like trailing slash are rejected before any
-- payload request or filesystem mutation occurs.
local function isAllowedTargetPath(targetPath)
    if targetPath == STARTUP_PATH then
        return true
    end

    return type(targetPath) == "string" and #targetPath <= 240 and
        string.match(
            targetPath,
            "^/dickos/[A-Za-z0-9_%.%/%-]+$"
        ) ~= nil and hasSafePathSegments(targetPath)
end

-- Ensure a Lua list is dense: only positive consecutive integer keys are
-- accepted. This prevents a malformed manifest hole from making `ipairs` stop
-- early and silently omit later payload files.
local function countDenseListEntries(list)
    if type(list) ~= "table" then
        return nil, "Manifest files field must be a table."
    end

    local entryCount = 0
    local maximumIndex = 0

    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, "Manifest files must use positive integer indexes."
        end

        entryCount = entryCount + 1
        maximumIndex = math.max(maximumIndex, key)
    end

    if entryCount == 0 then
        return nil, "Manifest contains no payload files."
    end

    if entryCount ~= maximumIndex then
        return nil, "Manifest files list contains an index gap."
    end

    if entryCount > MAXIMUM_MANIFEST_FILES then
        return nil, "Manifest contains too many payload files."
    end

    return entryCount, nil
end

-- Copy only validated manifest data into a new table. Remote Lua tables are
-- not used directly after this point, keeping deployment independent from
-- unexpected fields or later mutation of the parsed structure.
local function validateManifest(manifest)
    if type(manifest) ~= "table" then
        return nil, "Manifest did not return a table."
    end

    if manifest.manifestVersion ~= EXPECTED_MANIFEST_VERSION then
        return nil, string.format(
            "Unsupported manifest format. Expected: %d Received: %s",
            EXPECTED_MANIFEST_VERSION,
            tostring(manifest.manifestVersion)
        )
    end

    if manifest.version ~= VERSION then
        return nil, "Manifest version does not match this installer. " ..
            "Expected: " .. VERSION .. " Received: " ..
            tostring(manifest.version)
    end

    if type(manifest.payloadID) ~= "string" or
        not string.match(manifest.payloadID, "^[A-Za-z0-9_.%-]+$") or
        #manifest.payloadID > 96 then
        return nil, "Manifest payloadID is missing or malformed."
    end

    local fileCount, listError = countDenseListEntries(manifest.files)

    if fileCount == nil then
        return nil, listError
    end

    local validatedFiles = {}
    local seenSources = {}
    local seenTargets = {}

    for fileIndex = 1, fileCount do
        local remoteEntry = manifest.files[fileIndex]

        if type(remoteEntry) ~= "table" then
            return nil, "Manifest file entry " .. fileIndex ..
                " must be a table."
        end

        if not isAllowedSourcePath(remoteEntry.source) then
            return nil, "Manifest file entry " .. fileIndex ..
                " has an invalid source path."
        end

        if not isAllowedTargetPath(remoteEntry.target) then
            return nil, "Manifest file entry " .. fileIndex ..
                " has an invalid target path."
        end

        if remoteEntry.allowEmpty ~= nil and
            type(remoteEntry.allowEmpty) ~= "boolean" then
            return nil, "Manifest file entry " .. fileIndex ..
                " has a non-boolean allowEmpty value."
        end

        if seenSources[remoteEntry.source] then
            return nil, "Manifest repeats source: " .. remoteEntry.source
        end

        if seenTargets[remoteEntry.target] then
            return nil, "Manifest repeats target: " .. remoteEntry.target
        end

        seenSources[remoteEntry.source] = true
        seenTargets[remoteEntry.target] = true
        validatedFiles[fileIndex] = {
            source = remoteEntry.source,
            target = remoteEntry.target,
            allowEmpty = remoteEntry.allowEmpty == true,
        }
    end

    local stage0Entry = validatedFiles[fileCount]

    if stage0Entry.source ~= "src/startup.lua" or
        stage0Entry.target ~= STARTUP_PATH then
        return nil, "Stage-0 must be the final manifest payload entry."
    end

    for fileIndex = 1, fileCount - 1 do
        if validatedFiles[fileIndex].target == STARTUP_PATH then
            return nil, "Stage-0 appears before the final manifest entry."
        end
    end

    return {
        manifestVersion = manifest.manifestVersion,
        version = manifest.version,
        payloadID = manifest.payloadID,
        files = validatedFiles,
    }, nil
end

-- Compile the data-only Lua manifest with an empty global environment. This
-- permits the small `return { ... }` format while denying access to filesystem,
-- HTTP, shell, settings, and other installer globals. Structural/path checks
-- still run afterwards; this is validation, not a signature or trust proof.
local function parseManifest(contents)
    if contents == "" then
        return nil, "Remote manifest is empty."
    end

    if type(load) ~= "function" then
        return nil, "Lua manifest loader is unavailable."
    end

    local loadSucceeded, manifestProgram, compileError = pcall(
        load,
        contents,
        "@" .. MANIFEST_SOURCE_PATH,
        "t",
        {}
    )

    if not loadSucceeded then
        return nil, "Manifest compilation failed: " ..
            tostring(manifestProgram)
    end

    if type(manifestProgram) ~= "function" then
        return nil, "Manifest compilation failed: " .. tostring(compileError)
    end

    local runSucceeded, manifestOrError = pcall(manifestProgram)

    if not runSucceeded then
        return nil, "Manifest execution failed: " .. tostring(manifestOrError)
    end

    return validateManifest(manifestOrError)
end

-- Fetch the manifest through the same checked response path as payload files,
-- then return only the copied structure accepted by manifest validation.
local function fetchRemoteManifest()
    local manifestContents, fetchError = fetchRemoteText(
        MANIFEST_SOURCE_PATH
    )

    if manifestContents == nil then
        return nil, fetchError
    end

    return parseManifest(manifestContents)
end

-- Fetch every payload body before returning anything deployable. The returned
-- list is entirely in memory and preserves manifest order. If one request,
-- read, empty-content check, or Lua syntax check fails, the partial local table
-- is discarded and deployment never begins.
local function downloadInstallationPayload(manifest)
    local payload = {}
    local payloadBytes = 0

    for fileIndex, manifestFile in ipairs(manifest.files) do
        info("Downloading " .. manifestFile.source)

        local contents, fetchError = fetchRemoteText(manifestFile.source)

        if contents == nil then
            return nil, nil, manifestFile.source, fetchError
        end

        if contents == "" and not manifestFile.allowEmpty then
            return nil, nil, manifestFile.source,
                "Downloaded file is unexpectedly empty"
        end

        if string.sub(manifestFile.source, -4) == ".lua" then
            local program, syntaxError = load(
                contents,
                "@" .. manifestFile.source,
                "t",
                {}
            )

            if program == nil then
                return nil, nil, manifestFile.source,
                    "Lua syntax validation failed: " .. tostring(syntaxError)
            end
        end

        payload[fileIndex] = {
            source = manifestFile.source,
            target = manifestFile.target,
            contents = contents,
        }
        payloadBytes = payloadBytes + #contents
    end

    return payload, payloadBytes, nil, nil
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
    -- The requested owner directory preserves the tested installer layout.
    -- Because no account metadata exists yet, the interactive milestone also
    -- needs a separate documented bootstrap home. If the requested name is
    -- itself `bootstrap`, calling `fs.makeDir` twice is harmless and verified
    -- as a directory both times.
    local directories = {
        "/dickos/system",
        "/dickos/lib",
        "/dickos/bin",
        "/dickos/services",
        "/dickos/etc",
        "/dickos/home/" .. ownerUsername,
        "/dickos/home/bootstrap",
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

-- Deploy the already-downloaded source payload to its final paths. No HTTP
-- call occurs here: this critical phase consumes only the validated in-memory
-- list returned after the complete fetch phase.
--
-- The startup ownership flag is set before attempting its write. Preflight and
-- the immediate pre-deployment recheck proved that `/startup.lua` was absent,
-- so any partial file created by this attempt belongs to this installer and may
-- be removed safely during rollback.
local function writeSystemPayload(payload)
    for _, payloadFile in ipairs(payload) do
        if payloadFile.target == STARTUP_PATH then
            if fs.exists(STARTUP_PATH) then
                return false,
                    "Refusing to overwrite a newly appeared " .. STARTUP_PATH
            end

            startupCreatedByInstaller = true
        end

        local writeSucceeded, writeError = writeTextFile(
            payloadFile.target,
            payloadFile.contents
        )

        if not writeSucceeded then
            return false, writeError
        end

        if not fs.exists(payloadFile.target) then
            return false,
                "Installed file is missing: " .. payloadFile.target
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
    print("Stage-0, init, Recovery, logging, and the DICK shell are installed.")
    print("Interactive session: bootstrap (authentication is not implemented).")
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

    -- Startup-setting inspection is a local read-only preflight. Performing it
    -- before HTTP avoids downloading the payload when the later transaction
    -- could not capture a rollback snapshot safely.
    local capturedSettings, settingsCaptureError = captureBootSettings()

    if capturedSettings == nil then
        fail("Unable to inspect CraftOS startup settings.")
        print("       Details: " .. tostring(settingsCaptureError))
        print("No files were changed.")
        return
    end

    bootSettingsSnapshot = capturedSettings

    print()
    print("Network source")
    print("--------------")
    print("Repository: " .. REPOSITORY_OWNER .. "/" .. REPOSITORY_NAME)
    print("Channel:    " .. REPOSITORY_REF)
    warn("main is a mutable development channel")
    print()

    local manifestURL = buildRawContentURL(MANIFEST_SOURCE_PATH)
    local httpAvailable, httpError = verifyHTTPTransport(manifestURL)

    if not httpAvailable then
        fail("HTTP transport is unavailable.")
        print("       Reason: " .. tostring(httpError))
        print("Enable CC:T HTTP and permit raw.githubusercontent.com.")
        print("Installation aborted.")
        print("No files were changed.")
        return
    end

    ok("HTTP available")
    info("Downloading " .. MANIFEST_SOURCE_PATH)

    local installationManifest, manifestError = fetchRemoteManifest()

    if installationManifest == nil then
        fail("Download failed: " .. MANIFEST_SOURCE_PATH)
        print("       Reason: " .. tostring(manifestError))
        print("Installation aborted.")
        print("No files were changed.")
        return
    end

    ok("Manifest downloaded: " .. installationManifest.payloadID)

    local installationPayload, payloadBytes, failedSource, payloadError =
        downloadInstallationPayload(installationManifest)

    if installationPayload == nil then
        fail("Download failed: " .. tostring(failedSource))
        print("       Reason: " .. tostring(payloadError))
        print("Installation aborted.")
        print("No files were changed.")
        return
    end

    ok("Payload downloaded")
    ok(tostring(#installationPayload) .. " files ready")
    ok(formatByteCount(payloadBytes) .. " payload")

    if not validatePayloadFreeSpace(payloadBytes) then
        print("Installation aborted.")
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
            "Unable to install the bootstrap program payload.",
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
