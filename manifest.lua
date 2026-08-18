-- DICK/OS development installation manifest
-- Manifest format: 1

-- This file is data for the single-file network installer, not a package
-- database. `source` is a repository-relative raw GitHub path and `target` is
-- its installed CC:T path. The order is deployment order, so Stage-0 remains
-- last and cannot become visible before all of its dependencies are written.
return {
    manifestVersion = 1,
    version = "0.1.0-unstable",
    payloadID = "dickos-0.1.0-unstable-configuration-foundation",

    files = {
        {
            source = "src/dickos/system/init.lua",
            target = "/dickos/system/init.lua",
        },
        {
            source = "src/dickos/system/recovery.lua",
            target = "/dickos/system/recovery.lua",
        },
        {
            source = "src/dickos/system/shell.lua",
            target = "/dickos/system/shell.lua",
        },
        {
            source = "src/dickos/lib/log.lua",
            target = "/dickos/lib/log.lua",
        },
        {
            source = "src/dickos/lib/config.lua",
            target = "/dickos/lib/config.lua",
        },
        {
            source = "src/dickos/lib/editor_buffer.lua",
            target = "/dickos/lib/editor_buffer.lua",
        },
        {
            source = "src/dickos/etc/system.cfg",
            target = "/dickos/etc/system.cfg",
        },
        {
            source = "src/dickos/etc/network.cfg",
            target = "/dickos/etc/network.cfg",
        },
        {
            source = "src/dickos/etc/services.cfg",
            target = "/dickos/etc/services.cfg",
        },
        {
            source = "src/dickos/bin/dickfetch.lua",
            target = "/dickos/bin/dickfetch.lua",
        },
        {
            source = "src/dickos/bin/dicklog.lua",
            target = "/dickos/bin/dicklog.lua",
        },
        {
            source = "src/dickos/bin/ls.lua",
            target = "/dickos/bin/ls.lua",
        },
        {
            source = "src/dickos/bin/cat.lua",
            target = "/dickos/bin/cat.lua",
        },
        {
            source = "src/dickos/bin/echo.lua",
            target = "/dickos/bin/echo.lua",
        },
        {
            source = "src/dickos/bin/edit.lua",
            target = "/dickos/bin/edit.lua",
        },
        {
            source = "src/dickos/bin/hostname.lua",
            target = "/dickos/bin/hostname.lua",
        },
        {
            source = "src/dickos/bin/uname.lua",
            target = "/dickos/bin/uname.lua",
        },
        {
            source = "src/dickos/bin/uptime.lua",
            target = "/dickos/bin/uptime.lua",
        },
        {
            source = "src/dickos/bin/df.lua",
            target = "/dickos/bin/df.lua",
        },
        {
            source = "src/dickos/bin/status.lua",
            target = "/dickos/bin/status.lua",
        },
        {
            source = "src/dickos/bin/reboot.lua",
            target = "/dickos/bin/reboot.lua",
        },
        {
            source = "src/dickos/bin/shutdown.lua",
            target = "/dickos/bin/shutdown.lua",
        },
        {
            source = "src/startup.lua",
            target = "/startup.lua",
        },
    },
}
