-- DICK/OS minimal recovery bootstrap
-- Version: 0.1.0-unstable

local RETRY_RESULT = "retry"
local RESCUE_RESULT = "rescue"

-- A top-level Lua program receives arguments through `...`. Stage-0 passes the
-- boot-failure reason as the first argument when it calls this file's compiled
-- chunk. nil means no value was supplied; converting that case into explicit
-- text keeps the recovery screen useful instead of causing a concatenation
-- error.
local bootFailureReason = ...

if bootFailureReason == nil then
    bootFailureReason = "No boot-failure reason was supplied."
else
    bootFailureReason = tostring(bootFailureReason)
end

local function prepareTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function confirmCraftOSRescue()
    write("Enter CraftOS rescue shell? [y/N]: ")
    local answer = string.lower(read())

    return answer == "y" or answer == "yes"
end

prepareTerminal()
print("DICK/OS RECOVERY")
print()
print("Boot failure:")
print(bootFailureReason)

-- Recovery communicates with Stage-0 through small result strings. Returning
-- `retry` asks the existing supervisor loop for another init attempt; it does
-- not execute startup.lua recursively. Returning `rescue` is accepted only
-- after explicit confirmation and tells Stage-0 that ending startup is now an
-- intentional request to reach the underlying CraftOS shell.
--
-- `read()` waits on CC:T's event system instead of busy-polling. Ctrl+T causes
-- it to raise the normal terminate error. Stage-0 executes this whole recovery
-- chunk with pcall, so that error leads to its emergency fallback rather than
-- accidentally exposing CraftOS.
while true do
    print()
    print("1. Retry normal boot")
    print("2. Enter CraftOS rescue shell")
    print("3. Reboot")
    print("4. Shutdown")
    print()

    write("Select: ")
    local choice = read()

    if choice == "1" then
        return RETRY_RESULT
    elseif choice == "2" then
        if confirmCraftOSRescue() then
            return RESCUE_RESULT
        end
    elseif choice == "3" then
        -- These CC:T calls immediately change the computer's power state.
        -- Stage-0 does not intercept them. A reboot starts again at startup.lua;
        -- a shutdown executes no more Lua until the computer is powered on.
        os.reboot()
    elseif choice == "4" then
        os.shutdown()
    else
        print("Unknown selection. Please choose 1, 2, 3, or 4.")
    end
end
