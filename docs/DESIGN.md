# DICK/OS Design Document

## Distributed Infrastructure & Computer Kit Operating System

Current development version:

`0.1.0-unstable`

DICK/OS is an experimental Unix-inspired operating environment for
CC:Tweaked computers in Minecraft.

The project exists primarily as a systems-programming playground:
boot processes, service management, networking, authentication,
hardware discovery, recovery, package management and similar concepts
can be explored inside Minecraft without attempting to recreate a real
general-purpose operating system kernel.

---

# 1. Platform

DICK/OS runs on top of CC:Tweaked and CraftOS.

Conceptually:

CC:T runtime / ROM
        |
        v
CraftOS substrate
        |
        v
DICK/OS Stage-0
        |
        v
DICK/OS init
        |
        +-- integrity
        +-- configuration
        +-- hardware discovery
        +-- services
        +-- DickNet
        +-- authentication
        |
        v
DICK shell

CraftOS is not removed.

It remains the low-level runtime, compatibility layer and emergency
recovery environment.

During ordinary use, however, a user should remain inside DICK/OS and
should not normally see or interact with the CraftOS shell.

---

# 2. Supported hardware

The complete DICK/OS installation officially targets:

- CC:Tweaked Advanced Computer

Base DICK/OS should understand standard CC:Tweaked hardware where useful:

- standard Monitor
- Advanced Monitor
- wired modem
- wireless modem
- speaker
- printer
- disk drive
- redstone
- standard turtles

Turtles are part of the supported ecosystem but do not run the complete
DICK/OS 0.1.0 installation.

Basic Computers do not run full DICK/OS.

The colour terminal of an Advanced Computer is a baseline DICK/OS capability,
not an optional enhancement. Full DICK/OS interfaces may use all standard
CC:Tweaked colours and are not required to provide a separately designed
monochrome mode. A cheap `term.isColor()` check may still be used defensively,
but Basic Computer UI compatibility must not constrain the supported visual
design.

Basic Computers may eventually run separate lightweight appliance
software such as DIKModem.

That is a different product and is outside the scope of DICK/OS 0.1.0.

---

# 3. Addon policy

Base DICK/OS depends only on:

- CC:Tweaked

No addon peripheral mod is required.

Examples of optional hardware which may exist in a user's modpack:

- DirectGPU
- Tom's Peripherals
- Advanced Peripherals
- Lingua Peripherals
- CC: Terminals
- other CC:T peripheral addons

Base DICK/OS must continue to work if none of these are installed.

Unknown peripherals must not crash the OS.

Future support for addon hardware should be provided through optional
drivers/packages, eventually distributed through DickRepo.

Conceptually:

CC:T hardware
      |
      v
hardware discovery
      |
      v
driver layer
      |
      v
DICK/OS device interface

---

# 4. Storage requirements

Minimum supported computer storage:

4 MiB

Recommended:

16 MiB

The installer must check both:

- total filesystem capacity
- currently available free space

The installer must fail safely when requirements are not met.

---

# 5. Versioning policy

Current version:

`0.1.0-unstable`

Until 1.0, releases remain experimental.

Examples:

0.1.0-unstable
0.1.1-unstable
0.1.2-unstable
0.2.0-unstable

PATCH releases:

0.1.1
0.1.2
0.1.3

are intended for:

- bug fixes
- polishing
- smaller commands
- improvements to existing subsystems
- performance improvements
- diagnostics improvements

MINOR releases:

0.2.0
0.3.0

are intended for:

- significant new subsystems
- important new capabilities
- larger architectural changes
- potentially breaking changes

Before 1.0, breaking internal changes are acceptable when they improve the
design.

Protocol versions are independent from the DICK/OS release version.

For example:

DICK/OS 0.4.2

may still use:

DickNet/1

if the protocol itself did not change.

---

# 6. Scope of 0.1.0-unstable

0.1.0 is the foundation release.

It must provide:

1. Installer
2. Hardware validation
3. Storage validation
4. Initial setup
5. Machine identity
6. DICK/OS filesystem layout
7. Stage-0 boot supervisor
8. Init system
9. Boot presentation
10. Configuration system
11. Logging
12. Recovery environment
13. User authentication
14. sudo-like privilege model
15. DICK shell
16. Unix-like basic commands
17. Help system
18. Hardware/peripheral discovery
19. Peripheral hotplug tracking
20. Small service manager
21. DickNet/1 local LAN
22. Integrity manifest
23. Modification detection
24. Diagnostics

---

# 7. Explicitly outside 0.1.0

The following must NOT delay 0.1.0:

- DickRepo
- online DickPkg repositories
- DIKModem
- multi-hop routing
- DickNet encryption
- remote administration
- turtle fleet management
- graphical desktop environment
- addon peripheral drivers
- DickTube integration
- Internet-facing services

Interesting ideas discovered during development should normally be scheduled
for a later 0.1.x or 0.x.0 release rather than silently added to 0.1.0.

---

# 8. Installer

The repository contains:

`install.lua`

This is the bootstrap installer.

Future intended usage may resemble:

wget <URL> install.lua
install

The current Milestone 2 development installer uses the repository as a local
payload: it reads `src/startup.lua`, `src/dickos/system/init.lua`, and
`src/dickos/system/recovery.lua`, and `src/dickos/bin/dickfetch.lua` beside
`install.lua`, then writes them to their installed paths after confirmation. A
single-file download/bootstrap transport is not implemented yet and must not be
confused with DickPkg or DickRepo.

Installer flow:

preflight
    |
    v
hardware validation
    |
    v
storage validation
    |
    v
existing installation detection
    |
    v
initial configuration
    |
    v
installation summary
    |
    v
explicit confirmation
    |
    v
filesystem deployment
    |
    v
identity creation
    |
    v
integrity manifest
    |
    v
Stage-0 installation
    |
    v
reboot

Nothing should be written before preflight and user confirmation complete.

An installation failure must not intentionally destroy unrelated user data.

---

# 9. Hardware validation

Allowed:

Advanced Computer

Rejected:

- Basic Computer
- Turtle
- Pocket Computer
- Command Computer

The installer should display a clear result.

Example:

[ OK ] Advanced Computer detected
[ OK ] Storage requirement satisfied

Hardware validation PASSED

Or:

[FAIL] Advanced Computer required.

The user should receive a useful error instead of a raw Lua exception.

---

# 10. Initial configuration

Installer requests:

- hostname
- owner username
- password
- password confirmation

Hostname requirements:

- 1-24 characters
- letters
- digits
- hyphen

Username requirements:

- 1-16 characters
- lowercase
- starts with a letter
- may contain:
  - lowercase letters
  - digits
  - underscore
  - hyphen

Password input must be masked.

Passwords must never be stored in plaintext.

---

# 11. Machine identity

DICK/OS distinguishes three identities.

Example:

CC ID:
12

Machine ID:
DCK-C-12-A91F

Hostname:
core-01

## CC ID

Provided by CC:Tweaked.

Represents the underlying CC computer identity.

## Machine ID

Generated by DICK/OS during installation.

Represents the DICK/OS installation.

It should remain stable for that installation.

Initial format:

DCK-C-<CCID>-<HEX>

Example:

DCK-C-12-A91F

The machine-ID generator should be isolated behind a function/module so the
format or generation strategy can later change.

## Hostname

Human-readable and changeable.

Examples:

core-01
media-01
node-01

CC ID, machine ID and hostname must never be treated as interchangeable.

## Identity duplication limitation

Physical CC:T computer blocks are not guaranteed to have distinct observable
identities after block or NBT state has been copied. Two physical computers may
report the same CC ID and therefore address the same persistent CC:T filesystem.
In that situation they also see the same DICK/OS machine ID, hostname, and
installed files.

This exact duplicate is not always detectable locally. If both physical
computers observe the same CC ID and filesystem, each computer sees internally
consistent identity data. DICK/OS must not claim that the permanent machine ID
alone proves that only one physical computer exists.

## Identity health model foundation

The first future check is local identity consistency. DICK/OS can compare the
current `os.getComputerID()` value with the CC ID encoded in the installed
machine ID:

```text
Current CC ID: 9
Machine ID:    DCK-C-7-A91F

IDENTITY_CONFLICT
```

This detects a filesystem copied or moved to a computer with a different CC
ID. It cannot detect two physical computers which both expose the same CC ID
and shared filesystem.

The second future check is runtime/network duplicate detection. Stage-0 now
generates a temporary best-effort Boot ID in this exact format:

```text
B-XXXXXXXX
```

The eight suffix characters are uppercase hexadecimal. A Boot ID:

- is generated exactly once when one Stage-0 chunk begins executing;
- remains unchanged across Ctrl+T init restart, Recovery retry, and repeated
  init attempts supervised by that Stage-0 execution;
- changes when reboot, power-on, or another fresh CC:T startup executes
  Stage-0 again;
- exists only in a small runtime context passed from Stage-0 to init;
- is never written to `/dickos`, `/.settings`, or another persistent path;
- is best-effort uniqueness, not cryptographic identity;
- is not a permanent machine identity, password, token, or security secret;
- does not replace `/dickos/etc/machine-id`.

Runtime-only lifetime is important when copied physical CC:T computers expose
the same CC ID and persistent filesystem: a disk-backed Boot ID would also be
shared or raced. Future services, the DICK shell, and DickNet may inherit this
context when those components exist; Stage-0 is not a general runtime-state
manager.

A future DickNet node announcement may contain:

```text
machine_id
cc_id
hostname
boot_id
```

If two simultaneously-live announcements contain the same machine ID but
different Boot IDs, DICK/OS should report a possible `IDENTITY_CONFLICT`.
Future DickNet discovery must use liveness or heartbeat expiry before making
that comparison. Otherwise an announcement left over from the previous boot
could be mistaken for a second live machine and create a false conflict. Boot
ID generation and init context passing are implemented; DickNet announcement,
heartbeat, expiry, and duplicate detection are not.

---

# 12. Filesystem layout

Target installed layout:

/
├── startup.lua
└── dickos/
    ├── system/
    │   ├── init.lua
    │   ├── shell.lua
    │   ├── login.lua
    │   └── recovery.lua
    │
    ├── lib/
    │   ├── config.lua
    │   ├── auth.lua
    │   ├── integrity.lua
    │   ├── dicknet.lua
    │   ├── service.lua
    │   └── hardware.lua
    │
    ├── bin/
    │   └── dickfetch.lua
    ├── services/
    │
    ├── etc/
    │   ├── version
    │   ├── machine-id
    │   ├── hostname
    │   ├── users.db
    │   ├── system.cfg
    │   ├── network.cfg
    │   └── services.cfg
    │
    ├── home/
    │   └── <username>/
    │
    ├── var/
    │   ├── log/
    │   ├── lib/
    │   └── integrity/
    │
    └── tmp/

Repository source files should preferably live below:

src/

The repository tree does not need to perfectly mirror the installed tree,
but mapping between source paths and installed paths must remain obvious.

---

# 13. Stage-0

`/startup.lua` is DICK/OS Stage-0.

Stage-0 is deliberately tiny.

Its responsibilities:

- take control after CraftOS startup
- start DICK/OS init
- detect init failure
- prevent ordinary termination from exposing CraftOS
- restart the environment when practical
- enter recovery when boot is impossible

Stage-0 must not contain ordinary OS functionality.

It should change rarely.

## 0.1 boot contract

CraftOS remains the runtime and substrate beneath DICK/OS. DICK/OS does not
replace the CC:T runtime or attempt to preserve a running Lua stack across
power loss, reboot, server restart, or a chunk unload which causes a fresh
computer startup.

DICK/OS boot control begins only after CraftOS reaches its local startup phase.
CraftOS runs `/rom/autorun` earlier, and datapacks or other mods may extend that
directory. Stage-0 cannot supervise code which the platform executes before
`/startup.lua`; this is a platform limitation, not a failure which Recovery can
intercept.

Once CraftOS reaches local startup, every cold or fresh start creates a new
execution state. CraftOS runs the installed `/startup.lua`, Stage-0 loads init,
and persistent DICK/OS state is read again from `/dickos/etc` and `/dickos/var`
as those subsystems become available.

At the beginning of that Stage-0 execution, Stage-0 also creates one
runtime-only Boot ID and passes it to every init attempt in a small context
table. Supervisor retry does not execute startup.lua again, so it retains the
same Boot ID. A fresh CraftOS startup executes Stage-0 again and creates a new
one.

If CraftOS reaches local startup and `/startup.lua` exists and remains
syntactically executable, normal startup must lead either to the DICK/OS
environment or to DICK/OS Recovery. An unexpected init return, init crash, or
missing init must not casually expose the CraftOS prompt.

DICK/OS cannot guarantee this contract if `/startup.lua` itself is deleted or
damaged so severely that CraftOS cannot execute it. This is an unavoidable
limit of running on top of CraftOS's standard startup mechanism, not a recovery
case which already-running DICK/OS code can intercept.

---

# 14. Ctrl+T behaviour

Ctrl+T must not be a normal route into the CraftOS shell.

Conceptual behaviour:

Ctrl+T
   |
   v
current operation terminates
   |
   v
DICK/OS supervisor retains control
   |
   v
shell/process/environment restored

A crash must not silently result in:

CraftOS
>

The exact termination policy may differ depending on which component was
terminated, but DICK/OS must remain in control of the machine.

For the minimal 0.1 bootstrap, init receives the CC:T `terminate` event and
returns an explicit restart result to Stage-0. Stage-0 then starts a fresh init
attempt through its existing supervisor loop. A real Lua error and an
unexpected normal return are different failure states and enter Recovery.

---

# 15. Startup policy

DICK/OS should prevent ordinary disk startup from bypassing the normal local
boot path.

CraftOS must remain available as an explicit recovery environment.

Recovery access is intentional.

Accidentally escaping into CraftOS is not.

The installer persists `shell.allow_startup = true` and
`shell.allow_disk_startup = false`. Local Stage-0 therefore owns the ordinary
boot path, and a disk startup program cannot run before it. Recovery may still
end Stage-0 after an explicit CraftOS rescue selection; the next reboot or
fresh power-on starts DICK/OS again.

---

# 16. Init

The real operating environment begins in:

`/dickos/system/init.lua`

Init is responsible for coordinating:

- machine identity
- configuration
- integrity checks
- logging
- hardware discovery
- service startup
- DickNet
- authentication
- shell startup

Subsystem implementation should live in dedicated modules rather than making
init.lua a giant file.

---

# 17. Boot presentation

Normal DICK/OS boot uses a black background and places the complete bootstrap
presentation inside one native CC:T semigraphics frame. The title and tagline
are centred inside the frame, followed by an internal TUI separator:

```text
              DICK/OS 0.1.0-unstable
   Distributed Infrastructure & Computer Kit

   <native internal separator>
```

The implementation constructs single-byte drawing glyphs with `string.char`
rather than embedding UTF-8 box characters which CC:T would render as multiple
unrelated bytes. CC:T's drawing glyphs use foreground/background complements,
so some corners and edges exchange those colours. Exact glyph alignment is a
Minecraft runtime visual-verification item.

The current minimal init then animates only real bootstrap stages:

```text
[ OK ] Stage-0 supervisor
[ OK ] Version metadata
[ .. ] Machine identity
[    ] Hostname metadata
[    ] Bootstrap session

Activity: Machine identity
[#####################--------------------]  50%
```

A stage is represented by a small record containing a label and visual state.
This leaves an obvious place to add future real init work without introducing a
generic boot framework. Authentication, integrity, services, drivers, dickd,
DickNet, and package management must not appear as successful stages until
those subsystems exist.

After progress completes, init clears the framed boot screen and invokes
`/dickos/bin/dickfetch.lua`. Dickfetch is the canonical compact post-boot
system-information presentation: the happy DICK/OS mascot begins at the same
vertical level as the title, followed in order by version, hostname, machine
ID, runtime Boot ID, and green `SYSTEM READY` state. It has no giant frame,
underline, or bootstrap-placeholder text.

Init passes dickfetch one explicit table containing `version`, `hostname`,
`machineID`, and `bootID`. The utility does not persist Boot ID or reconstruct
it from the filesystem. A future DICK shell should invoke the same utility with
the current runtime context; the shell itself is not implemented. Missing
required metadata remains an init failure, while a missing, invalid, or
crashing dickfetch is a noncritical presentation failure: init displays a
minimal identity/status fallback and remains in its event wait-loop rather
than entering Recovery.

This post-boot presentation is the future session handoff point. Until a real
DICK shell or session subsystem exists, minimal init remains in that wait-loop.
It must not provide fake commands merely to fill the space.

---

# 18. Artificial boot delay

Boot presentation may intentionally delay visual output.

Example:

[ OK ] Loading configuration
<small delay>
[ OK ] Detecting peripherals

This delay is cosmetic.

The minimal bootstrap may use approximately one second of short timer frames to
make progress movement legible. The animation must preserve terminate handling
and must not imply that nonexistent subsystem work is occurring.

Real initialization must not be extended merely to make the system appear
slower. When a stage later performs actual work, that work and any cosmetic
frame delay remain conceptually separate.

Future versions may allow the user to skip cosmetic delays while real boot work
continues normally.

---

# 19. Configuration

Configuration must not be hard-coded throughout the Lua source.

Persistent configuration belongs in dedicated files such as:

/dickos/etc/system.cfg
/dickos/etc/network.cfg
/dickos/etc/services.cfg
/dickos/etc/users.db

Shared configuration parsing/writing belongs in:

/dickos/lib/config.lua

---

# 20. Users

Initial conceptual users:

root
    UID = 0
    direct login = disabled

first human user
    UID = 1000
    admin = true

Installer creates the initial owner account.

Future versions may support additional users.

---

# 21. Authentication

Required functionality:

- login
- logout
- whoami
- id
- passwd

Passwords must not be stored as plaintext.

DICK/OS must not invent a deliberately weak custom password hashing algorithm
just to make authentication appear complete.

The password backend should be isolated so the implementation can improve
without rewriting the user subsystem.

DICK/OS authentication is an OS-level policy implemented in Lua.

It is not equivalent to kernel-enforced Unix security.

Documentation and code must not pretend otherwise.

---

# 22. sudo-like privileges

Administrative actions may require elevated privileges.

Example:

nano@core-01:~$ sudo service restart dicknet

[sudo] password for nano:

A successful authorization may be cached for a short session.

Ordinary commands must not require sudo.

The privilege model is intended to provide coherent OS behavior and prevent
accidental changes.

It is not a hard security boundary against somebody who completely bypasses
DICK/OS and obtains unrestricted lower-level execution.

---

# 23. DICK shell

After login:

nano@core-01:~$

DICK/OS provides its own user-facing shell environment.

The shell owns:

- PATH
- aliases
- prompt
- environment
- command discovery
- DICK/OS command behavior

CraftOS functionality may be reused internally when useful.

However DICK/OS must not depend on CraftOS startup having accidentally created
specific aliases or environment state.

---

# 24. Base commands

Filesystem/userland:

- ls
- cd
- cat
- touch
- mkdir
- cp
- mv
- rm
- pwd
- edit
- which
- clear

System:

- uname
- uptime
- df
- hostname
- status
- peripherals
- help

Users:

- login
- logout
- whoami
- id
- passwd
- sudo

Services:

- services
- service

Networking:

- nodes
- ping
- send

Administration:

- dickctl

Commands may wrap suitable CraftOS functionality internally.

The goal is a coherent DICK/OS interface, not rewriting every existing utility
merely for ideological purity.

---

# 25. id / machine identity commands

DICK/OS `id` should follow Unix-like semantics.

Example:

id

uid=1000(nano) groups=admin

Computer identity should be exposed separately.

For example:

machine-id

DCK-C-12-A91F

and:

ccid

12

Exact command naming may be adjusted during implementation.

---

# 26. Help system

`help` is mandatory in 0.1.0.

Examples:

help
help cat
help sudo
help service
help dickctl

Preferred style:

CAT(1)                    DICK/OS

NAME
    cat - print file contents

USAGE
    cat <file> [file...]

EXAMPLES
    cat /dickos/etc/version
    cat notes.txt

Help must not become one giant hard-coded program.

Commands should be able to provide/install their own help metadata/pages.

Future DickRepo packages should eventually be capable of installing:

program
+
help page

without modifying the central help command.

---

# 27. Text user interface

DICK/OS is primarily a text-mode operating environment.

Base UI targets standard CC:T terminal capabilities.

Desired style:

┌ DICK/OS System ──────────────────┐
│ Hostname       core-01           │
│ DickNet        ONLINE            │
│ Storage        15.3 MiB free     │
│ Services       4 running         │
├──────────────────────────────────┤
│ F1 Help                 F10 Exit │
└──────────────────────────────────┘

The visual direction takes inspiration from:

- DOS
- Unix terminals
- old text-mode setup tools
- character-based TUIs

A pixel-based graphical desktop is not required for 0.1.0.

## Visual language

Full DICK/OS targets the Advanced Computer colour terminal. The three boot
states must be immediately distinguishable:

- normal DICK/OS: black background and one boxed boot TUI;
- DICK/OS Recovery: blue boxed TUI;
- Emergency Fallback: red boxed TUI.

Shared colour semantics are:

- lime/green: healthy, successful, complete, `[ OK ]`;
- light blue/cyan: information, activity, network information;
- yellow: warning, degraded state, confirmation requiring attention;
- red: failure, critical state, `IDENTITY_CONFLICT`;
- white: primary text;
- light gray/gray: secondary text and separators;
- magenta: reserved for `MODIFIED` and future integrity state.

The compact DICK/OS mascot has happy and sad variants. Happy appears after a
successful normal boot. Sad appears inside Recovery and Emergency Fallback.
The art must remain small enough to share the standard Advanced Computer screen
with diagnostics and actions.

---

# 28. Hardware discovery

DICK/OS must dynamically discover peripherals.

Never assume:

left = modem
right = speaker

Hardware may be attached to arbitrary sides or through wired peripheral
networks.

The system should track:

- device name
- device type
- current availability
- known driver/support status

Example:

DEVICE       TYPE        STATE

left         modem       wireless
top          monitor     online
right        speaker     online

Unknown addon hardware should be represented safely, for example:

gpu_0        directgpu   unsupported

and boot should continue.

---

# 29. Peripheral hotplug

DICK/OS should react to peripherals being attached or detached while running.

A full reboot should not normally be required simply because a monitor,
speaker or modem changed.

Hardware state should be refreshed accordingly.

---

# 30. Service manager

Working name:

`dickd`

The goal is a small service supervisor.

Do not recreate all of systemd.

Required operations:

services

service status <name>
service start <name>
service stop <name>
service restart <name>

Conceptual states:

STOPPED
STARTING
RUNNING
FAILED

Services may eventually define restart policies.

Example:

dicknet crashes
    |
    v
dickd notices failure
    |
    v
failure logged
    |
    v
restart according to policy

---

# 31. DickNet/1

DICK/OS 0.1.0 implements only local LAN communication.

Transport:

standard CC:T modem hardware

No DIKModem.

No multi-hop routing.

No network encryption.

Required functionality:

- discovery
- node list
- hostname association
- ping
- simple text messages

Commands:

nodes
ping node-01
send node-01 "hello"

---

# 32. DickNet identity

Nodes may advertise:

- machine ID
- hostname
- CC ID
- the current runtime Boot ID
- DickNet protocol version

Machine ID is the primary persistent DICK/OS identity.
Boot ID is transient and may only support duplicate detection while its node
announcement remains live. Future DickNet heartbeat/liveness expiry must remove
stale Boot IDs before comparing simultaneous announcements.

---

# 33. DickNet packet format

The initial format must remain simple but leave room for future routing.

Conceptual fields:

protocol version
packet ID
source
destination
packet type
TTL
payload

Example concept:

{
    version = 1,
    packet_id = "...",
    src = "DCK-C-12-A91F",
    dst = "DCK-C-15-7B20",
    type = "message",
    ttl = 8,
    payload = ...
}

0.1.0 does not need to use every field extensively.

The point is to avoid redesigning every endpoint when routing is introduced
later.

---

# 34. Future DIKModem

Not part of 0.1.0.

Future topology:

DICK/OS
   |
DIKModem
   |
DIKModem
   |
DICK/OS / DickRepo

DIKModem may run on a Basic Computer.

Relays should eventually be treated as untrusted infrastructure.

This does not need implementation in 0.1.0.

---

# 35. Integrity system

Modification detection is a first-class DICK/OS feature.

DICK/OS maintains an integrity manifest for files managed by the operating
system.

Possible location:

/dickos/var/integrity/manifest.db

For each managed file, the manifest should eventually contain:

- path
- owning package/component
- component version
- file size
- digest/hash
- critical/non-critical flag

Example concept:

path=/dickos/system/init.lua
package=dickos-core
version=0.1.0
size=7312
hash=<digest>
critical=true

---

# 36. What integrity tracks

Managed system files:

/dickos/system/init.lua
/dickos/lib/auth.lua
/dickos/bin/cat.lua

are tracked.

User-created files:

/dickos/home/nano/test.lua
/dickos/home/nano/server.lua

are not treated as operating-system modifications.

The fundamental rule:

DICK/OS verifies only files DICK/OS owns.

---

# 37. Modification states

Integrity verification should distinguish at least:

OK
MODIFIED
MISSING
CORRUPT

Potential future states may be added when useful.

---

# 38. Boot-time integrity

Boot should verify the critical subset required to safely start the OS.

Examples:

- Stage-0 assumptions
- init
- critical libraries
- configuration/database viability

A modification to a non-critical utility should not automatically prevent boot.

Example:

/dickos/bin/cat.lua modified

may result in:

System state: MODIFIED

while the system continues to operate.

---

# 39. Critical corruption

Missing or invalid critical components may stop normal boot.

Example:

[FAIL] Critical system integrity failure

Entering recovery...

Normal failure must not simply expose the CraftOS shell.

---

# 40. Manual integrity verification

Administrative command:

sudo dickctl verify

Example output:

DICK/OS Integrity Verification

dickos-core ............. OK
auth .................... OK
coreutils ................ MODIFIED
dicknet .................. OK

Modified:
  /dickos/bin/cat.lua

Missing:
  none

User files:
  ignored

---

# 41. Modification does not imply automatic replacement

If a user intentionally modifies an official file, DICK/OS should report the
modification.

It should not silently erase the modification.

Example:

SYSTEM MODIFIED

A user is allowed to experiment.

The integrity system exists to know what changed, not to enforce vendor control.

---

# 42. Integrity and future packages

The integrity database is deliberately designed to later become part of the
DickPkg package database.

Future operations may reuse the same metadata:

dickpkg verify
dickpkg reinstall coreutils
dickpkg update

Package ownership therefore matters from the beginning even before DickRepo is
implemented.

---

# 43. Compatibility philosophy

Users are allowed to modify DICK/OS or write an entirely different operating
environment.

DICK/OS does not claim exclusive ownership of the ecosystem.

Future compatibility should be defined through public specifications such as:

- DickNet
- machine identity
- package formats
- DIKModem protocol
- driver interfaces

A different operating system may remain compatible with DICK ecosystem
services without being DICK/OS internally.

---

# 44. Logging

Initial logs:

/dickos/var/log/boot.log
/dickos/var/log/system.log
/dickos/var/log/auth.log
/dickos/var/log/dicknet.log

Logs must be bounded.

Do not allow unlimited files to consume the computer's storage.

Avoid unnecessary writes every tick.

---

# 45. dickctl

`dickctl` is the primary administrative/diagnostic utility.

Initial planned operations include:

dickctl status
dickctl verify
dickctl doctor

Future operations may be added as needed.

---

# 46. dickctl doctor

`dickctl doctor` should gather useful diagnostic information in one place.

Example:

DICK/OS SYSTEM DOCTOR

Bootloader .............. OK
Core files .............. OK
Integrity database ...... OK
Machine identity ........ OK
Hostname ................ core-01
User database ........... OK

Storage ................. OK
Peripherals ............. OK

dickd ................... RUNNING
DickNet ................. RUNNING

System state ............ HEALTHY

Possible final system states may include:

HEALTHY
DEGRADED
MODIFIED
FAILED

---

# 47. Recovery environment

The current bootstrap Recovery is a blue full-screen boxed TUI using the same
native CC:T semigraphics family as Normal Boot. It displays a sad mascot, keeps
the title / failure heading / separator / diagnostic / menu hierarchy, wraps
the boot diagnostic so the menu remains visible, and offers:

```text
DICK/OS RECOVERY

1. Retry normal boot
2. Enter CraftOS rescue shell
3. Reboot
4. Shutdown
```

CraftOS rescue shell is explicitly selected.

It is not an accidental fallback.

If Recovery itself is missing or fails, Stage-0 displays a red native-framed
Emergency Fallback with the sad mascot. Its title is followed by spaced
`CRITICAL BOOT FAILURE` severity, an internal separator, Recovery failure,
original boot failure, and the same four survival actions. Its minimal drawing,
wrapping, colour, mascot, and input logic remain self-contained inside
`/startup.lua`. This small duplication is intentional: the last-resort path
cannot depend on init, Recovery, or a shared DICK/OS UI library which may be
unavailable.

Future integrity verification, restore, and reinstall actions may extend the
real Recovery environment only after those capabilities exist. The bootstrap
must not display such actions as if they already work.

---

# 48. Last known good state

The architecture should leave room for keeping a previous known-good copy of
critical system files.

Future upgrades may use this for rollback.

0.1.0 does not need a sophisticated snapshot filesystem.

However recovery code should not be designed in a way that makes a future
last-known-good restore impossible.

---

# 49. Definition of Done

0.1.0-unstable is ready when two clean Advanced Computers can be installed from
scratch.

Expected lifecycle:

installer
    |
    v
hardware/storage validation
    |
    v
hostname/user/password
    |
    v
machine identity
    |
    v
installation
    |
    v
reboot
    |
    v
DICK/OS boot
    |
    v
integrity
    |
    v
login
    |
    v
DICK shell
    |
    +-- services
    +-- peripherals
    +-- DickNet

The following should work:

help
cat
ls
cp
mv
rm
df
uptime
uname

whoami
id
passwd
sudo

hostname
status
peripherals

services
service

nodes
ping
send

dickctl verify
dickctl doctor

---

# 50. Required corruption tests

## Modified non-critical file

Modify:

/dickos/bin/cat.lua

Expected:

dickctl verify

reports the file/package as MODIFIED.

System remains bootable.

## Missing critical file

Remove:

/dickos/system/init.lua

Expected:

Stage-0 detects boot failure and enters DICK/OS Recovery.

It must not simply expose CraftOS.

## User file

Create:

/dickos/home/<user>/test.lua

Expected:

Integrity verification ignores it.

---

# 51. Future development

After 0.1.0, development continues incrementally.

0.1.x releases improve the existing foundation.

A new major subsystem may justify 0.2.0.

Potential future projects include:

- DickRepo
- DickPkg
- DIKModem
- multi-hop DickNet
- endpoint authentication/encryption
- addon drivers
- graphical frontend
- DickFleet
- remote management
- media packages

These are intentionally not committed to a specific release yet.
