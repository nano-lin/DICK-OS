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

---

# 15. Startup policy

DICK/OS should prevent ordinary disk startup from bypassing the normal local
boot path.

CraftOS must remain available as an explicit recovery environment.

Recovery access is intentional.

Accidentally escaping into CraftOS is not.

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

Example:

DICK/OS 0.1.0-unstable
Distributed Infrastructure & Computer Kit

[ OK ] Initializing system
[ OK ] Loading machine identity
[ OK ] Checking system integrity
[ OK ] Loading configuration
[ OK ] Detecting peripherals
[ OK ] Starting system services
[ OK ] Starting DickNet
[ OK ] Starting authentication

System ready.

The boot sequence intentionally has a retro Unix/DOS appearance.

---

# 18. Artificial boot delay

Boot presentation may intentionally delay visual output.

Example:

[ OK ] Loading configuration
<small delay>
[ OK ] Detecting peripherals

This delay is cosmetic.

Actual initialization must never wait merely to make the system appear slower.

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
- DickNet protocol version

Machine ID is the primary persistent DICK/OS identity.

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

If normal boot cannot continue:

DICK/OS RECOVERY

1. Verify system
2. Restore system
3. Reinstall DICK/OS
4. Enter CraftOS rescue shell
5. Reboot
6. Shutdown

CraftOS rescue shell is explicitly selected.

It is not an accidental fallback.

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