-- DICK/OS Stage-0 boot supervisor
-- Version: 0.1.0-unstable

-- Stage-0 is deliberately small. Its job is to keep control of the boot path,
-- not to implement normal operating-system features. Authentication, services,
-- networking, hardware discovery, and the future shell belong below init.
local INIT_PATH = "/dickos/system/init.lua"
local RECOVERY_PATH = "/dickos/system/recovery.lua"

local INIT_RESTART_RESULT = "restart"
local RECOVERY_RETRY_RESULT = "retry"
local RECOVERY_RESCUE_RESULT = "rescue"

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

-- Convert an error into readable diagnostic text.
--
-- Ordinary Lua errors are often strings. Current CraftOS versions may instead
-- preserve richer errors as exception tables with a `message` field. Reading
-- that field when present keeps useful diagnostics without making Stage-0
-- depend on the rest of the exception implementation.
local function describeError(errorValue)
    if type(errorValue) == "table" and type(errorValue.message) == "string" then
        return errorValue.message
    end

    return tostring(errorValue)
end

-- Load and execute one DICK/OS program under protected execution.
--
-- `loadfile` compiles a Lua file and returns a callable function. If the file
-- is syntactically invalid, it instead returns nil plus an error message and no
-- program is run. `pcall` then invokes a successfully loaded function. Its
-- first return value is true when the child returned normally and false when
-- the child raised an error; following return values contain either the
-- child's results or its error value.
-- CC:T supports yielding through pcall, so init may wait for events for an
-- arbitrary time while this protected call remains active.
--
-- This protection is what lets Stage-0 survive a broken init or recovery.
-- Errors inside those child programs are ordinary boot failures. An error in
-- the supervisor itself is different and is caught by the outer guard at the
-- bottom of this file.
local function runProtected(path, ...)
    local program, loadError = loadfile(path)

    if program == nil then
        return false, "Unable to load " .. path .. ": " .. tostring(loadError)
    end

    return pcall(program, ...)
end

-- Attempt one normal boot and describe what Stage-0 should do next.
--
-- State strings make the control flow explicit. In particular, an expected
-- Ctrl+T path returns `restart`, while every other normal return is considered
-- unexpected. The supervisor loop consumes these states without recursively
-- launching another startup.lua, so repeated retries cannot grow Lua's call
-- stack forever.
local function attemptNormalBoot()
    if not fs.exists(INIT_PATH) then
        return "recovery", "Required init is missing: " .. INIT_PATH
    end

    local initSucceeded, initResult = runProtected(INIT_PATH)

    if not initSucceeded then
        return "recovery", "init crashed: " .. describeError(initResult)
    end

    if initResult == INIT_RESTART_RESULT then
        return "restart", nil
    end

    return "recovery", "init returned unexpectedly without reboot or shutdown."
end

-- Read fallback input without allowing Ctrl+T to escape Stage-0.
--
-- CraftOS `read` normally raises an error when it receives a terminate event.
-- Wrapping it in pcall converts that interruption into a false result. The
-- emergency menu can then redraw itself instead of accidentally returning to
-- the CraftOS prompt.
local function readFallbackInput(promptText)
    write(promptText)
    local inputSucceeded, inputOrError = pcall(read)

    if inputSucceeded then
        return inputOrError
    end

    print()
    print("[WARN] Input interrupted; Stage-0 remains active.")
    return nil
end

-- Provide the smallest viable recovery path when recovery.lua cannot run.
-- This duplicates only the actions Stage-0 needs for its own survival; it is
-- intentionally not a second full recovery environment.
local function runEmergencyFallback(reason)
    prepareTerminal()
    print("DICK/OS EMERGENCY FALLBACK")
    print()
    print("Recovery failure:")
    print(reason)

    while true do
        print()
        print("1. Retry normal boot")
        print("2. Enter CraftOS rescue shell")
        print("3. Reboot")
        print("4. Shutdown")
        print()

        local choice = readFallbackInput("Select: ")

        if choice == "1" then
            return RECOVERY_RETRY_RESULT
        elseif choice == "2" then
            local confirmation = readFallbackInput(
                "Enter CraftOS rescue shell? [y/N]: "
            )

            if confirmation ~= nil then
                confirmation = string.lower(confirmation)

                if confirmation == "y" or confirmation == "yes" then
                    return RECOVERY_RESCUE_RESULT
                end
            end
        elseif choice == "3" then
            os.reboot()
        elseif choice == "4" then
            os.shutdown()
        elseif choice ~= nil then
            print("Unknown selection. Please choose 1, 2, 3, or 4.")
        end
    end
end

-- Run Recovery under the same protection as init.
-- Missing, crashing, or unexpectedly returning recovery code cannot make
-- startup.lua finish. Those paths enter the built-in emergency fallback.
local function requestRecovery(bootFailureReason)
    if not fs.exists(RECOVERY_PATH) then
        return runEmergencyFallback(
            "Required recovery program is missing: " .. RECOVERY_PATH ..
            "\nOriginal boot failure: " .. bootFailureReason
        )
    end

    local recoverySucceeded, recoveryResult = runProtected(
        RECOVERY_PATH,
        bootFailureReason
    )

    if not recoverySucceeded then
        return runEmergencyFallback(
            "recovery.lua crashed: " .. describeError(recoveryResult) ..
            "\nOriginal boot failure: " .. bootFailureReason
        )
    end

    if recoveryResult == RECOVERY_RETRY_RESULT or
        recoveryResult == RECOVERY_RESCUE_RESULT then
        return recoveryResult
    end

    return runEmergencyFallback(
        "recovery.lua returned an invalid result: " ..
        describeError(recoveryResult) ..
        "\nOriginal boot failure: " .. bootFailureReason
    )
end

-- Supervise normal boot for as long as DICK/OS owns the machine.
-- Each pass through this loop is a fresh init attempt. A retry changes loop
-- state; it does not call Stage-0 again and therefore is not recursive.
local function superviseBoot()
    while true do
        local bootState, bootFailureReason = attemptNormalBoot()

        if bootState ~= "restart" then
            prepareTerminal()
            print("DICK/OS Stage-0")
            print()
            print("[FAIL] init terminated unexpectedly")
            print(bootFailureReason)
            print()
            print("Entering recovery...")

            local recoveryResult = requestRecovery(bootFailureReason)

            if recoveryResult == RECOVERY_RESCUE_RESULT then
                -- This return is intentional. The user explicitly selected the
                -- CraftOS rescue environment, so Stage-0 may now finish and let
                -- the underlying CraftOS startup sequence reach its shell.
                return
            end
        end
    end
end

-- Guard Stage-0's own supervisor loop separately from child execution. A bug
-- in Stage-0 must still lead to an emergency screen instead of an accidental
-- CraftOS prompt. Selecting retry starts a new loop iteration, not recursion.
while true do
    local supervisorSucceeded, supervisorError = pcall(superviseBoot)

    if supervisorSucceeded then
        -- `superviseBoot` returns normally only after explicit rescue choice.
        return
    end

    local fallbackResult = runEmergencyFallback(
        "Stage-0 internal failure: " .. describeError(supervisorError)
    )

    if fallbackResult == RECOVERY_RESCUE_RESULT then
        -- As above, this is the one deliberate path back to CraftOS.
        return
    end
end
