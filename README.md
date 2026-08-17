# DICK/OS

**Distributed Infrastructure & Computer Kit Operating System**

DICK/OS is a Unix-inspired operating environment for
[CC:Tweaked](https://tweaked.cc/) computers in Minecraft.

> Current version: `0.1.0-unstable`

## Goals

- Advanced Computer support
- DICK/OS boot environment
- User authentication and sudo-like privilege model
- Unix-like command set
- Service management
- Peripheral auto-detection
- DickNet local networking
- Integrity verification and recovery

## Hardware requirements

DICK/OS officially targets CC:Tweaked Advanced Computers.

Base DICK/OS requires only CC:Tweaked. Support for addon
peripherals will be distributed separately through DickRepo.

## Development installation

Place the current repository `install.lua` at `/install.lua` on a fresh
Advanced Computer, then run:

```text
install
```

No local `src/` tree is required. The installer downloads `manifest.lua` and
the complete payload from `nano-lin/DICK-OS` before it begins writing system
files. CC:T HTTP access must be enabled and `raw.githubusercontent.com` must be
permitted by the Minecraft server configuration.

The installer currently follows the mutable `main` branch. This is an unstable
development transport, not a cryptographic integrity guarantee or a pinned
release. A failed or incomplete download aborts before deployment.

## Status

Early development. Expect breaking changes.
