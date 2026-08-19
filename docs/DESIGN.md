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

The network installer performs its capacity check during local preflight. Once
the complete remote payload is in memory, it checks free space again against
the actual number of content bytes which it is about to write. This is a
payload-derived minimum rather than a permanently hard-coded free-space
estimate; filesystem metadata and initial installation metadata may still add
small implementation overhead.

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

Current development usage requires only the current installer file to be
present locally:

copy install.lua to /install.lua
install

The installer fetches `manifest.lua` and every listed payload source from the
public `nano-lin/DICK-OS` repository through GitHub's raw-content endpoint. The
temporary development ref is `main`. Repository owner, repository name, and
ref are separate installer constants so a later milestone can select a tag,
release branch, or immutable commit without replacing the transport design.

The manifest is deliberately small. Its format version identifies the data
shape, its DICK/OS version and payload ID identify the intended development
payload, and each file entry maps one repository-relative `src/...` source to
one installed target. Validation accepts targets only below `/dickos/`, plus
the exact `/startup.lua` Stage-0 target. Duplicate, malformed, unsafe, empty,
or incorrectly ordered entries are rejected. This installation manifest is a
bootstrap file list, not DickPkg, DickRepo, or the future installed integrity
database.

`main` is mutable. Fetching one manifest and its complete file list reduces
accidental mixed-version installation, but it does not provide cryptographic
integrity, authenticity, or stable release pinning. Those guarantees require a
future release/signature design. Until then, the installer clearly identifies
`main` as an unstable development channel. Because separate raw-file requests
resolve that mutable ref independently, a branch update during one installation
can still create a version race; pinning an immutable commit is the intended
future correction for release transport.

Installer flow:

local preflight
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
HTTP availability and raw-domain permission check
    |
    v
remote manifest fetch and validation
    |
    v
complete payload fetch into memory
    |
    v
payload-derived free-space check
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
filesystem layout and initial metadata
    |
    v
init, Recovery, shell, shared libraries, configuration templates, and commands
    |
    v
shared password/user modules create and re-load validated users.db
    |
    v
Stage-0 payload file installed last
    |
    v
startup settings transaction
    |
    v
installation result; reboot remains explicit

Every payload body must be fetched, read, and validated before the first
persistent deployment write. Deployment performs no HTTP request and consumes
only that in-memory payload. A missing manifest, blocked domain, timeout, 404,
invalid response, malformed manifest, or failed payload download therefore
aborts before filesystem deployment and leaves local system state unchanged.

CC:T HTTP must be enabled and `raw.githubusercontent.com` must be allowed by
the Minecraft server configuration. The installer detects the missing HTTP API
and uses `http.checkURL` when that API is available, but it never changes server
configuration itself.

After explicit confirmation, deployment retains the existing rollback model.
Stage-0 remains the final payload item written to `/startup.lua`, after its
init, Recovery, login, shell, logger, configuration, authentication, and command
dependencies. The installer does not execute fetched auth/password code before
confirmation. Afterwards it loads the installed shared backend, validates the
confirmed password, derives the owner verifier, creates machine-specific
users.db transactionally, and strictly reloads it before writing Stage-0. Any
verifier/database/load failure rolls back the installer-owned tree and startup
settings. `users.db` is intentionally absent from the manifest.
`install.lua` does not download, overwrite, or restart itself. Configuration
templates are ordinary versioned payload files; the installer does not keep a
second embedded copy of their defaults.

Nothing persistent should be written before preflight, complete payload fetch,
and user confirmation finish.

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
- lowercase ASCII
- starts with a letter
- may contain:
  - lowercase letters
  - digits
  - underscore
- `root` and `bootstrap` are reserved

Password input is masked and confirmed. Passwords contain 8 through 128 bytes;
no uppercase/digit/symbol composition rule is imposed.

Passwords must never be stored in plaintext. The confirmed installer value is
retained only until post-confirmation verifier creation and then dereferenced;
Lua garbage collection is not claimed to provide secure memory wiping.

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

The current runtime-context contract is deliberately small:

```lua
{
    apiVersion = 1,
    bootID = "B-XXXXXXXX",
}
```

Stage-0 owns this table and passes the same instance to init attempts and to
Recovery during one supervisor execution. `apiVersion` is an exact
compatibility marker: init accepts version 1, rejects a missing or unsupported
version with a clear boot error, and does not attempt protocol negotiation.
The marker versions only this runtime table; it is independent from the
DICK/OS release version and future network protocol versions.

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
    │   ├── log.lua
    │   ├── editor_buffer.lua
    │   ├── config.lua
    │   ├── password.lua
    │   ├── users.lua
    │   ├── auth.lua
    │   ├── integrity.lua
    │   ├── dicknet.lua
    │   ├── service.lua
    │   └── hardware.lua
    │
    ├── bin/
    │   ├── cat.lua
    │   ├── df.lua
    │   ├── dickfetch.lua
    │   ├── dicklog.lua
    │   ├── echo.lua
    │   ├── edit.lua
    │   ├── hostname.lua
    │   ├── ls.lua
    │   ├── reboot.lua
    │   ├── shutdown.lua
    │   ├── status.lua
    │   ├── whoami.lua
    │   ├── id.lua
    │   ├── passwd.lua
    │   ├── uname.lua
    │   └── uptime.lua
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

The manifest installs versioned code and configuration templates, but never a
static `users.db`. The installer creates that machine-specific database only
after explicit confirmation, using the installed password/users modules, and
validates it before making Stage-0 visible.

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
one. The context currently has runtime API version 1; init validates both that
version and the Boot ID format before continuing normal bootstrap.

Stage-0 also has a tiny self-contained best-effort append helper for
`/dickos/var/log/boot.log`. It must not load `/dickos/lib/log.lua`, because a
missing or damaged normal library cannot be allowed to disable boot supervision
or Emergency Fallback. Any Stage-0 logging or rotation failure is ignored after
the attempted write and does not replace the real boot error.

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

Before the interactive shell starts, init receives the CC:T `terminate` event
during the boot animation and returns an explicit restart result to Stage-0.
Stage-0 starts a fresh init attempt with the same runtime context and Boot ID.
A real init error and an unexpected normal return remain different failure
states and enter Recovery.

After the DICK shell starts, it owns Ctrl+T containment. Ctrl+T while `read` is
waiting at an idle prompt only redraws the prompt. A normal child which uses
ordinary CC:T event functions raises `Terminated`; the shell catches that child
error, reports `Command terminated.`, logs a warning best-effort, and restores
the same prompt and Boot ID. A deliberately raw-event child may choose to
ignore `terminate`; forcibly scheduling or killing such a child is outside the
current shell foundation.

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

The current implemented handoff is:

```text
init -> persistent system configuration -> authentication core/users.db
     -> boot presentation -> dickfetch -> login
     -> authenticated /dickos/system/shell.lua
```

Init combines Stage-0's runtime API version and Boot ID with the installed
version, hostname, and Machine ID. It loads `/dickos/etc/system.cfg` through the
required configuration library, requires auth core plus a strictly valid
`/dickos/etc/users.db`, and then runs the native login program. Only a public
authenticated identity and validated `shell.history_limit` join the shell
session table; parsed configuration, users.db, verifiers, passwords, and auth
modules are not forwarded. Boot ID is never written to disk.

Init owns the session loop. The shell may return only `logout`; init records
that transition best-effort and starts login again with the same Boot ID. A
missing/broken auth dependency, invalid users.db, missing/crashing login, or
missing/crashing/unexpectedly returning shell is an init failure and reaches
Stage-0 Recovery. This core contract remains separate from optional config-data
fallback and the shell's protected child-command boundary.

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
[    ] Configuration
[    ] User database / auth core

Activity: Machine identity
[#####################--------------------]  50%
```

A stage is represented by a small record containing a label and visual state.
This leaves an obvious place to add future real init work without introducing a
generic boot framework. User database/auth core now describes real validation;
integrity, services, drivers, dickd, DickNet, and package management must not
appear as successful stages until those subsystems exist.

After progress completes, init clears the framed boot screen and invokes
`/dickos/bin/dickfetch.lua`. Dickfetch is the canonical compact post-boot
system-information presentation: the happy DICK/OS mascot begins at the same
vertical level as the title, followed in order by version, hostname, machine
ID, runtime Boot ID, and green `SYSTEM READY` state. It has no giant frame,
underline, or bootstrap-placeholder text.

Init passes dickfetch one explicit table containing `version`, `hostname`,
`machineID`, and `bootID`. The utility does not persist Boot ID or reconstruct
it from the filesystem. Missing required metadata remains an init failure,
while a missing, invalid, or crashing dickfetch is a noncritical presentation
failure: init displays a minimal identity/status fallback rather than entering
Recovery.

After either successful dickfetch or that fallback, init starts the native
login screen. Successful authentication starts the DICK shell in the account's
home. The user may run `dickfetch` again explicitly like any other
`/dickos/bin` utility.

---

# 18. Artificial boot delay

Boot presentation may intentionally delay visual output.

Example:

[ OK ] Loading configuration
<small delay>
[ OK ] Detecting peripherals

This delay is cosmetic.

With `boot.cosmetic_delay = true`, the minimal bootstrap uses short timer frames
to make progress movement legible. With it set to `false`, init renders the same
real stages as complete without intentionally waiting between cosmetic frames.
The animation must preserve terminate containment and must not imply that
nonexistent subsystem work is occurring.

Real initialization must not be extended merely to make the system appear
slower. When a stage later performs actual work, that work and any cosmetic
frame delay remain conceptually separate.

This setting is read once during init. Editing it does not alter an already
running boot/session; the new value takes effect on the next init or reboot.

---

# 19. Configuration

`/dickos/lib/config.lua` is the shared parser, schema validator, loader, and
writer for persistent configuration below `/dickos/etc`. Configuration is data,
not Lua: values are never passed to `load`, `loadstring`, or another execution
mechanism.

## Config format v1

Version 1 is a deliberately small line-oriented key/value format:

```text
# DICK/OS system configuration

format_version = 1
boot.cosmetic_delay = true
shell.history_limit = 64
```

Its grammar is:

- one `key = value` assignment per non-comment line;
- blank lines and full-line comments whose first non-whitespace character is
  `#` are ignored;
- keys are lowercase identifier segments separated by dots; every segment
  starts with `a-z` and continues with `a-z`, `0-9`, or `_`;
- duplicate keys are invalid rather than last-write-wins;
- values are `true`, `false`, finite decimal numbers with an optional `e`/`E`
  exponent, or quoted strings;
- quoted strings support only `\\`, `\"`, `\n`, `\r`, and `\t` escapes;
- arrays, tables, inline comments, functions, and executable chunks are not
  part of format v1.

Parser failures include the source name and line number when a line is known.
Parsing produces a flat table but does not decide which subsystem keys are
valid. Each subsystem supplies an ordinary Lua schema whose entries describe a
type, safe default, optional numeric minimum/maximum, and optional allowed
values. Validation is a separate step:

- a missing known key receives its default;
- an invalid known value receives its default and produces a warning;
- an unknown key is retained for forward compatibility and produces a warning;
- a supported file with some invalid values may keep its other valid values;
- an unsupported `format_version` rejects the whole file as a usable source,
  so DICK/OS never partially interprets an unknown format.

The public module operations are `parse`, `validate`, `load`, `get`,
`serialize`, and `write`; `defaults` exposes a fresh schema-default table for
callers which need it. `readText`, `serializeValues`, and `writeValues` are the
narrow strict/dynamic extension used by users.lua: they reuse config-v1 parsing
and the same transaction without applying optional-setting defaults. `load`
applies a defensive 64 KiB limit. A missing,
unreadable, oversized, malformed, or unsupported-format user file returns safe
defaults plus warnings and is not automatically overwritten during boot.

This failure policy deliberately distinguishes code from data. A missing,
syntactically broken, crashing, or API-incompatible `/dickos/lib/config.lua` is
a core init failure and follows the existing Stage-0 Recovery path. A typo or
bad value in user-editable `system.cfg` logs WARN best-effort, activates safe
defaults for the affected scope, and continues normal boot. Logger failure
remains non-fatal, and configuration contents are never copied into logs.

The initial `/dickos/etc/system.cfg` contains only:

```text
format_version = 1
boot.cosmetic_delay = true
shell.history_limit = 64
```

`boot.cosmetic_delay` controls only intentional visual waits. The real init
work and Ctrl+T containment are unchanged. `shell.history_limit` is an integer
from 0 through 256: zero disables the in-memory session history, while a
positive value retains only that many newest non-blank commands. History is
neither persisted nor logged.

`network.cfg` and `services.cfg` currently contain only `format_version = 1`
plus explanatory comments. They reserve real versioned files for future
DickNet and dickd schemas without enabling a network subsystem, fake services,
or autostart. `users.db` also uses config-v1 syntax, but users.lua owns its
strict security semantics and never falls back to defaults or auto-recreation.

`serialize` emits deterministic canonical syntax with `format_version` first
and remaining keys sorted. Programmatic writing preserves scalar values but may
replace comments, whitespace, and original ordering. `write` first writes and
closes `<target>.tmp`, moves an existing target to `<target>.bak`, installs the
complete temporary file, and restores the backup where practical if the final
move fails. A retained backup is never erased while its target is missing.
Successful replacement cleans both reserved artifacts. This is a small
best-effort config transaction, not a general filesystem transaction framework.

There is no live reload or config-management CLI. Changes take effect on the
next init/reboot and can currently be inspected or edited with ordinary DICK
commands such as `cat /dickos/etc/system.cfg` and
`edit /dickos/etc/system.cfg`.

---

# 20. Users

The installer creates `/dickos/etc/users.db` format 1 with two records:

```text
root:  UID 0, admin=true, direct login disabled, no password
owner: UID 1000, admin=true, direct login enabled, salted verifier
```

`next_uid` begins at 1001. Root's home is `/dickos/home/root`; the owner home is
`/dickos/home/<username>`. The `admin` flag is role metadata reserved for later
authorization work and does not currently grant sudo or filesystem powers.

The flat config-v1 representation is canonical and conceptually contains:

```text
format_version = 1
next_uid = 1001
user.root.uid = 0
user.root.home = "/dickos/home/root"
user.root.admin = true
user.root.login_disabled = true
user.root.password.algorithm = "disabled"
user.nano.uid = 1000
user.nano.home = "/dickos/home/nano"
user.nano.admin = true
user.nano.login_disabled = false
user.nano.password.algorithm = "pbkdf2-hmac-sha256"
user.nano.password.iterations = 4096
user.nano.password.salt = "<32 lowercase hex characters>"
user.nano.password.digest = "<64 lowercase hex characters>"
```

Usernames are 1 through 16 bytes and match `^[a-z][a-z0-9_]*$`, making each
name exactly one valid config-v1 key segment. `root` and `bootstrap` are
reserved, and input is rejected rather than silently lowercased.

`/dickos/lib/users.lua` owns database semantics. Its public operations validate
usernames/databases, load strictly, look up by name or UID, create the initial
root/owner database, replace one verifier in a copied database, and write via
the config transaction. Validation rejects unsupported format, malformed or
unknown fields, duplicate UIDs, invalid flags/homes/verifiers, an incorrect
root contract, a missing/incorrect UID-1000 owner, or invalid `next_uid`.

Missing, unreadable, oversized, malformed, unsupported, or semantically invalid
users.db is fatal authentication state. Init enters Recovery; it never creates
bootstrap/anonymous access and never rewrites the database automatically.
Additional user-management commands remain future work.

---

# 21. Authentication

The implemented password backend is `/dickos/lib/password.lua`. It implements
the standard SHA-256, HMAC-SHA256, and PBKDF2-HMAC-SHA256 constructions with
Lua 5.2 `bit32`, tested against published vectors. Stored verifier fields are:

```text
algorithm  = "pbkdf2-hmac-sha256"
iterations = 4096
salt       = 16 bytes encoded as lowercase hex
digest     = 32 derived bytes encoded as lowercase hex
```

The production iteration count is central, with stored counts accepted only
from 1000 through 100000 to prevent damaged data from requesting absurd work.
Every new verifier receives a best-effort unique salt derived from changing
CC:T runtime/machine inputs. Salt is not secret, and CC:T is not claimed to
provide a cryptographically secure RNG. Digest comparison examines every byte
best-effort, but Lua/CC:T cannot promise hard constant-time execution.

Passwords must be 8 through 128 bytes. There are no arbitrary composition
rules. Login, installer, and `passwd` use masked interactive reads and
confirmation where a new password is chosen; passwords are never accepted as
command arguments. Plaintext is never persisted or logged. Setting references
to nil shortens their useful lifetime, but immutable garbage-collected Lua
strings cannot be claimed to be securely wiped.

`password.lua` exposes verifier creation/verification/validation, shared
password-policy validation, and vector-test primitives. `/dickos/lib/auth.lua`
owns policy: state validation, authentication, and current-user password
change. It distinguishes ordinary denial from broken state and transactional
write failure. Only public name/UID/home/admin identity crosses into a session.

`/dickos/system/login.lua` is a black native UI showing DICK/OS, hostname, and
masked credentials. Unknown user, wrong password, and disabled root login all
display only `Login incorrect.` and loop. Ctrl+T is contained and redraws login
without becoming a failed attempt. A broken auth state or login module is a
core init failure and therefore Recovery.

`logout` returns from the shell to init and starts login again without reboot,
preserving Boot ID. `whoami`, `id`, and current-user-only `passwd` are native
commands. `passwd` uses masked current/new/confirmation prompts; Ctrl+T remains
an ordinary protected child termination and no database write begins before
all prompt/policy checks and current-password verification succeed.

DICK/OS authentication is an OS-level policy implemented in Lua, not a
kernel-enforced Unix boundary. Recovery/CraftOS access or direct filesystem
modification can bypass it. PBKDF2 here is materially better than plaintext or
direct unsalted hashing, but pure-Lua PBKDF2 is not equivalent to a modern
native memory-hard Argon2 implementation. Runtime cost must be measured on a
real Advanced Computer before tuning.

---

# 22. sudo-like privileges

This section remains future design. The users/authentication foundation records
an admin role but implements no sudo command, elevation, authorization cache,
filesystem permissions, or root command execution.

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

The current shell begins only after successful native login:

```text
nano@core-01:~$
```

It owns its prompt, cwd, home expansion, command parsing, command discovery,
and execution protection. The background is
black; prompt fragments use restrained semantic colours, and the shell restores
background, foreground, and cursor blink before every new prompt so child
presentation state cannot permanently damage it.

The initial cwd and home come from the authenticated user record. An exact home path is
displayed as `~`, descendants as `~/...`, and `~`/`~/...` are expanded for
built-ins and native commands. Relative paths use the shell-owned cwd. Path
normalisation removes empty and `.` segments, applies `..`, and clamps at `/`;
it does not invent Unix mounts or permission semantics.

The implemented resolver is shared by execution and `which`, in this order:

1. registered shell built-ins;
2. `/dickos/bin/<command>`;
3. `/dickos/bin/<command>.lua`;
4. an explicit relative or absolute path when the typed name contains `/`.

CraftOS PATH and aliases are never searched implicitly. The current `edit`
command is a native DICK/OS program. It resolves its target from the DICK
cwd/home context, uses a small DICK-owned buffer module, and depends only on
public filesystem, terminal, key, colour, and event APIs. It does not load the
CraftOS ROM editor, construct a CraftOS compatibility environment, or expose a
CraftOS shell. Normal Quit returns to the protected DICK child-command call;
editor runtime errors and Ctrl+T remain ordinary child outcomes handled by the
existing shell boundary.

The parser recognises whitespace plus matching single and double quotes.
Unterminated input reports `Parse error: unterminated quote` and returns to the
prompt. Pipes, redirection, substitution, escaping, globbing, scripts,
background jobs, aliases, and job control are not implemented. `read` provides
in-memory history for the current session only, bounded by the validated
`shell.history_limit`; zero disables it.

Every external program is compiled and executed behind protected calls. A load
or runtime failure prints the exact child diagnostic when available, writes a
best-effort `system.log` record containing only the command name, restores the
terminal, and returns to the prompt. Such a child failure is not an init or
Recovery failure. The shell core itself is a required component: load failure,
fatal runtime failure, or unexpected return is propagated through init to
Stage-0 Recovery.

Native programs under `/dickos/bin` receive a fresh first-argument context with
runtime API version, Boot ID, version, hostname, Machine ID, username, UID,
admin flag, home, and a cwd snapshot. It contains no verifier, users database,
password, or auth module. Explicit user programs outside that directory receive
only their typed arguments. Boot ID therefore remains runtime-only. `dicklog`
also retains direct CraftOS-rescue invocation with ordinary arguments.

`logout` returns the explicit session result consumed by init. `exit` never
falls through to CraftOS; it directs the user to `logout`, `reboot`, or
`shutdown`. Explicit CraftOS access remains a Recovery selection only.

The current DICK shell does not implement mouse-wheel output scrollback. It
does not yet retain a historical output model, and calling `term.scroll()`
would only move and discard visible terminal cells rather than navigate real
history. Mouse-wheel shell scrollback remains a future shell feature and is
separate from native editor viewport scrolling.

---

# 24. Base commands

The current shell-foundation built-ins are:

- `help`, `clear`, `cd`, `pwd`, `which`, `exit`, `logout`.

The current external `/dickos/bin` commands are:

- `ls`, `cat`, `echo`, `edit`;
- `hostname`, `uname`, `uptime`, `df`, `status`;
- `whoami`, `id`, `passwd`;
- `reboot`, `shutdown`;
- `dickfetch`, `dicklog`.

The following planned 0.1.0 commands are not implemented by this milestone.

Filesystem/userland:

- touch
- mkdir
- cp
- mv
- rm

System:

- peripherals

Users/authorization:

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

The current shell implementation registers short help for shell built-ins,
discovers runnable names from `/dickos/bin`, and asks an external command for
its own `--help` output when `help <command>` is used. New binaries therefore
become discoverable without editing a central command list. Full manual pages
and package-installed help metadata remain future work.

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

## DICK EDIT v1

`/dickos/bin/edit.lua` is the first native DICK/OS text editor. Its pure text
model lives in `/dickos/lib/editor_buffer.lua`; the command file owns path and
file handling, rendering, shortcuts, and the event loop. Neither component
uses `/rom/programs/edit.lua`, a CraftOS shell, `multishell`, or private
`cc.internal` modules.

The command accepts exactly one target. Relative paths, `.` and `..` use the
DICK command's cwd snapshot; `~` and `~/...` use its home; absolute paths stay
absolute; parent traversal clamps at `/`. A missing target begins as one empty,
clean line and is not created until Save. Directories and files larger than
256 KiB are rejected before editing. Existing files are read completely, and
new input is refused before the in-memory document would cross the same limit.

The buffer is a list of lines without newline characters. It always contains
at least one line, uses one-based line/column cursors, and preserves trailing
empty lines. Save joins lines with LF and adds no unconditional final newline.
CRLF and lone-CR input are normalised to LF when loaded or pasted, so saving
such a document follows one explicit CC:T newline policy.

The Advanced Computer TUI has a black background, adaptive line-number width,
a horizontally clipped unwrapped text viewport, automatic vertical and
horizontal scrolling, a dirty marker, cursor coordinates, and Save/Quit hints.
It uses ASCII separators rather than raw UTF-8 box characters. A terminal
smaller than 42 by 7 cells receives a clear error and returns to the shell.

Editor v1 keys are:

- character input: insert printable text;
- Enter: split the current line;
- Backspace/Delete: remove a character or join adjacent lines;
- Tab: insert four spaces;
- Left/Right/Up/Down, Home/End, PageUp/PageDown: move the cursor;
- Ctrl+S: write the complete buffer and clear dirty state only after open,
  write, and close all succeed;
- Ctrl+Q: quit immediately when clean; when dirty, show a warning first and
  require a second non-repeated Ctrl+Q to discard;
- Escape: cancel the pending discard confirmation;
- CC:T paste events: insert the delivered text even when Ctrl remains down
  from Ctrl+V;
- mouse wheel: scroll the text viewport three lines up/down.

The `paste` event itself is authoritative. The editor's buffer can process
newline characters when they are present in the event text, including line
splitting and LF normalisation. Host-side tests inject such synthetic event
text to verify that internal behaviour. The standard CC:T Minecraft client
clipboard path, however, delivers only the first clipboard line to a Lua
program. Normal Ctrl+V is therefore effectively single-line, and multiline
clipboard paste is unavailable through that client path. This is a CC:T input
limitation rather than an editor-buffer failure.

Mouse-wheel scrolling clamps at the document boundaries and does not change
text or dirty state. The cursor stays on its original line while that line is
visible. If scrolling would hide it, the cursor moves to the nearest visible
line and its column is clamped to that line's length. Mouse clicks, dragging,
selection, and mouse editing remain outside v1.

A failed Save leaves the editor open and dirty with a visible diagnostic.
Editor v1 uses a direct CC:T write after a writable handle is obtained; it does
not yet implement atomic temporary-file replacement. Normal exit resets the
terminal to a sane black/white state, with the DICK shell's existing terminal
hygiene remaining the final safety boundary.

The event loop deliberately calls `os.pullEvent`, not `os.pullEventRaw`.
Ctrl+T therefore terminates the editor immediately as a child command, even
with unsaved changes. The DICK shell reports `Command terminated.`, restores
the same session/prompt, and does not enter Recovery or CraftOS. The editor
does not log keystrokes, pasted text, or buffer contents; current diagnostics
remain the shell's best-effort child failure/termination records.

### Runtime verification

DICK EDIT v1 has been manually runtime-verified in Minecraft with CC:T. The
confirmed paths include:

- native editor startup and return to the DICK shell without a CraftOS prompt;
- opening, creating, saving, and reopening files through relative, absolute,
  and DICK-home (`~`) paths;
- character input, cursor movement, Home/End, PageUp/PageDown, Enter,
  Backspace, Delete, Tab, and line splitting/joining;
- line numbers, vertical and horizontal viewport movement, and mouse-wheel
  scrolling through a document longer than the screen;
- dirty-state indication, unsaved-quit confirmation, and Escape cancellation;
- Ctrl+T child termination, terminal restoration, and a healthy subsequent
  shell prompt;
- single-line clipboard paste through normal Minecraft Ctrl+V.

Multiline Ctrl+V through the standard Minecraft client is N/A/unsupported
because that path does not deliver a multiline `paste` event to the program.
The runtime result does not contradict the synthetic host test of the editor's
newline-containing event handling.

### Current limitations

DICK EDIT v1 currently has:

- effectively single-line normal Ctrl+V due to the standard CC:T client path;
- no selection or cut/copy operations (clipboard paste is supported);
- no undo/redo;
- no search/replace;
- no syntax highlighting;
- no multiple buffers or tabs;
- direct, non-atomic save replacement.

Other deferred work includes goto line, mouse positioning, bracket matching,
auto-indent, configurable tab width, and read-only mode. Editor v1 has no
scheduler-backed Run action. These are possible later milestones, not
implemented v1 behaviour.

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

The currently implemented logs are:

/dickos/var/log/boot.log
/dickos/var/log/system.log
/dickos/var/log/auth.log

Normal init and Recovery components use `/dickos/lib/log.lua`. The module
creates an explicit logger bound to one log target and one runtime context; it
does not keep mutable global Boot ID state. Stage-0 and Emergency Fallback do
not depend on this module and use Stage-0's smaller autonomous append helper.

Ordinary records contain one event per physical line:

```text
2026-08-16T20:14:32Z [B-7C4A91E2] [INFO] [stage0] Stage-0 started
```

The fields are UTC timestamp, Boot ID, level, component, and message. Embedded
line breaks in values are replaced with a visible separator so one error cannot
imitate several records. Logs must not contain passwords or other secrets.

Current levels are:

- `DEBUG`: detailed diagnostic progress;
- `INFO`: expected lifecycle state;
- `WARN`: degraded or user-selected exceptional state;
- `ERROR`: one operation or component failed;
- `CRITICAL`: supervision or recovery reached a last-resort failure path.

`boot.log` contains fresh Stage-0 boot markers, supervisor attempts, init
progress, Recovery decisions, and fallback transitions. Its Boot ID groups
Ctrl+T init restarts and Recovery retries under the same Stage-0 execution. A
new Stage-0 execution appends a new marker and normally has a new Boot ID.
`system.log` begins the longer-lived system/session diagnostic stream. Init
records configuration-library loading, system-config loading/default fallback,
authentication-state readiness, and authenticated session transitions.
Configuration WARN records describe paths,
keys, and diagnostics but never contain the complete file contents. The shell
records startup, missing commands, ordinary command termination, and child
load/runtime failures. Shell records include the resolved command name but
deliberately omit the complete raw argument line so future secrets are not
blindly copied into logs. Reboot and shutdown requests are also logged
best-effort before invoking the real power API. `auth.log` records successful
login/logout/password changes, rejected login/password-change attempts at
WARN, and authentication state/write failures. It never records passwords,
password lengths, salts, digests, complete users.db contents, or raw commands.

All files are bounded before appending a record which would cross their limit:

- `boot.log`: 64 KiB;
- `system.log`: 128 KiB.
- `auth.log`: 64 KiB.

The current file is moved to `<name>.1`, an older `.1` is removed, and only one
rotated file is retained. There is no archive manager. Open, timestamp,
rotation, write, and close errors are all best-effort failures: logger failure
must never cause init to enter Recovery or prevent Recovery/Fallback actions.

`/dickos/bin/dicklog.lua` is the small current viewer. With no arguments it
shows the last 20 active `boot.log` lines. It also accepts `boot`, `system`,
`auth`, and a positive line count, for example `dicklog auth 50`. It
intentionally has no
search, filter, or archive framework yet and can be run directly by path from a
CraftOS rescue shell. DICK shell invocation shifts its native context first;
manual CraftOS forms and defaults remain unchanged.

Future `/dickos/var/log/dicknet.log` remains planned and is not created until
that subsystem exists.

Logging occurs on meaningful state transitions, not every timer tick.

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
