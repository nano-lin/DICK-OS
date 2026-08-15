# DICK/OS Agent Instructions

## Read first

Before making meaningful changes, read:

1. README.md
2. docs/DESIGN.md
3. existing code relevant to the task

docs/DESIGN.md is the current architectural source of truth.

Do not silently expand the scope of DICK/OS 0.1.0-unstable.

---

## Project

DICK/OS means:

Distributed Infrastructure & Computer Kit Operating System

DICK/OS is a Unix-inspired operating environment for CC:Tweaked.

Current target:

0.1.0-unstable

Base DICK/OS depends only on CC:Tweaked.

Do not introduce mandatory addon dependencies unless explicitly requested.

Full DICK/OS targets Advanced Computers.

---

## Development priorities

Prefer, in order:

1. correctness
2. clarity
3. educational readability
4. predictable behavior
5. maintainability
6. simplicity
7. performance

This is an experimental systems-programming project and a learning project.

Code should therefore be understandable to somebody who is still learning Lua
and CC:Tweaked.

Do not optimize code into something cryptic merely to save a few lines.

---

# Lua explanation and comment policy

IMPORTANT:

DICK/OS source code should be unusually well explained.

The project is intended to be readable by people who do not already know Lua
well.

Comments must explain both Lua concepts and DICK/OS architecture when useful.

Do not assume the reader already understands:

- Lua tables
- ipairs / pairs
- local scope
- multiple return values
- nil
- closures
- callbacks
- pcall
- coroutines
- events
- CC:T handles
- peripheral wrapping
- term redirection
- filesystem handles
- os.pullEvent / os.pullEventRaw
- CC:T-specific APIs

When one of these appears in non-trivial code, explain what it is doing.

Example:

-- `fs.open` returns a file handle rather than the file contents directly.
-- We use that handle to write the file and must close it afterwards so the
-- resource is released correctly.
local file, err = fs.open(path, "w")

if not file then
    error("Unable to open file: " .. tostring(err))
end

file.write(contents)
file.close()

Prefer comments which explain WHY and HOW.

Avoid useless comments such as:

-- Add one to x
x = x + 1

Instead explain relevant intent:

-- CC:T computer IDs are not used as the permanent DICK/OS identity.
-- They are included here only as one component of the initial machine ID.
local ccID = os.getComputerID()

---

## Function documentation

Non-trivial functions should normally have a short explanatory comment.

Example:

-- Validate a DICK/OS hostname.
--
-- Hostnames are deliberately restricted to a small portable character set so
-- they can later be used safely by DickNet and shell utilities without each
-- subsystem requiring its own escaping rules.
local function isValidHostname(hostname)
    ...
end

For important functions, explain:

- purpose
- arguments
- returned values
- important failure cases
- any CC:T-specific behavior

---

## Explain architecture in code

When a piece of code exists because of an architectural decision, explain that
decision close to the implementation.

Example:

-- Stage-0 deliberately contains as little logic as possible.
-- If normal DICK/OS components become corrupted, this file must still remain
-- simple enough to start the recovery environment.
local INIT_PATH = "/dickos/system/init.lua"

Do not force a future reader to reverse-engineer design decisions from code.

---

## Prefer readable Lua

Prefer:

local capacity = fs.getCapacity("/")

if capacity < MIN_STORAGE then
    fail("DICK/OS requires at least 4 MiB of storage.")
    return
end

over unnecessarily compressed forms.

Avoid:

- clever one-liners
- excessive chaining
- unnecessary metaprogramming
- dense anonymous callbacks
- giant functions
- giant files
- premature generic frameworks

Use descriptive names.

Bad:

local x = fs.getFreeSpace("/")

Good:

local freeSpace = fs.getFreeSpace("/")

---

## CC:T compatibility

Use Lua features supported by the CC:Tweaked runtime.

Do not assume ordinary desktop Lua APIs exist.

Do not invent CC:T APIs.

When unsure, consult official CC:Tweaked documentation before coding.

Base system must work without addon mods.

Unknown peripherals must fail gracefully rather than crash boot.

---

## CraftOS policy

CraftOS is the substrate and recovery environment.

Normal DICK/OS users should remain inside DICK/OS.

Do not create normal code paths which casually drop the user into CraftOS.

Stage-0 and recovery behavior are especially sensitive.

---

## Stage-0 policy

/startup.lua is Stage-0.

Keep it extremely small.

Its responsibilities are limited to:

- entering DICK/OS
- supervising init
- handling fatal boot failure
- entering recovery
- preventing ordinary termination from exposing CraftOS

Do not place normal OS features in Stage-0.

---

## Error handling

User-facing errors should be understandable.

Prefer:

[FAIL] Advanced Computer required.

over exposing raw implementation errors whenever a clean explanation is
possible.

Low-level details may be logged for diagnosis.

Never silently discard important failures.

---

## Authentication

Never store plaintext passwords.

Do not invent weak fake cryptography.

If a secure implementation is not yet available:

- define a clean interface
- leave the backend clearly incomplete
- document the limitation

Do not pretend DICK/OS users/sudo are equivalent to kernel-level Unix security.

---

## Integrity system

The integrity system tracks only DICK/OS-managed files.

User files must not be treated as system corruption.

Modification detection should report changes.

Do not automatically destroy an intentionally modified file merely because it
differs from the official manifest.

Critical and non-critical files should be treated differently.

---

## Shell

The DICK shell owns its own:

- PATH
- aliases
- prompt
- command discovery

Do not rely on CraftOS startup having prepared aliases.

CraftOS programs may be reused internally where appropriate.

Do not rewrite existing functionality without a reason.

---

## Help requirements

Every official user-facing command should have useful help.

`help <command>` should explain:

- purpose
- syntax
- options where relevant
- examples where useful

Help must eventually be extensible by packages.

Do not build the help system as one giant hard-coded command list.

---

## UI

Base DICK/OS uses character/text-mode interfaces.

Think:

- DOS
- Unix
- BIOS/setup screens
- old text-mode utilities

Do not require pixel graphics or GPU addons.

---

## Services

Keep dickd small.

Do not recreate systemd.

Service functionality should remain easy to understand and easy to debug.

---

## DickNet

For 0.1.0 implement only local modem LAN.

Do not implement:

- DIKModem
- routing
- encryption
- repository networking

unless the task explicitly changes the design scope.

Keep the packet format future-compatible without overengineering it.

---

## Scope control

0.1.0 is frozen to the features in docs/DESIGN.md.

If a requested implementation naturally suggests another feature, mention it
as a future idea.

Do not implement it automatically.

Small improvements belong in future 0.1.x releases.

Major new subsystems generally belong in a future 0.x.0 release.

---

## Repository organization

Prefer:

install.lua
src/
docs/

Source files should map clearly to their final installed locations.

Avoid placeholder files that contain fake implementations merely to make the
tree appear complete.

---

## Documentation

If code materially changes architecture or expected behavior, update
docs/DESIGN.md or other relevant documentation.

Do not let implementation and documentation silently diverge.

---

## Current testing policy

Minecraft integration testing will be performed later by the developer.

Unless explicitly asked, do not attempt to claim that code has been tested
inside CC:T.

You may:

- inspect syntax
- inspect code paths
- perform static review
- inspect diffs
- check path consistency
- check obvious Lua errors

Clearly mark anything requiring real CC:T runtime verification.

Never fabricate successful test results.

---

## Task discipline

For every task:

1. inspect existing code first
2. identify the smallest relevant change
3. preserve established architecture
4. implement only the requested milestone
5. review the resulting diff
6. update documentation if necessary
7. report runtime-unverified behavior

Do not perform large unrelated refactors.

Do not rewrite working subsystems merely because another style is preferred.

---

## Completion report

At the end of a task, summarize:

- files created
- files changed
- what was implemented
- important architectural decisions
- known limitations
- what still needs in-game verification

Do not claim DICK/OS 0.1.0 is complete until the Definition of Done in
docs/DESIGN.md is actually satisfied.