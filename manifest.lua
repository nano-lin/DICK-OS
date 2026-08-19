-- DICK/OS development installation manifest
-- Manifest format: 1

-- This file is data for the single-file network installer, not a package
-- database. `source` is a repository-relative raw GitHub path and `target` is
-- its installed CC:T path. The order is deployment order, so Stage-0 remains
-- last and cannot become visible before all of its dependencies are written.
return {
    manifestVersion = 1,
    version = "0.1.0-unstable",
    payloadID = "dickos-0.1.0-unstable-dickd-foundation",

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
            source = "src/dickos/system/login.lua",
            target = "/dickos/system/login.lua",
        },
        {
            source = "src/dickos/system/dickd.lua",
            target = "/dickos/system/dickd.lua",
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
            source = "src/dickos/lib/password.lua",
            target = "/dickos/lib/password.lua",
        },
        {
            source = "src/dickos/lib/users.lua",
            target = "/dickos/lib/users.lua",
        },
        {
            source = "src/dickos/lib/auth.lua",
            target = "/dickos/lib/auth.lua",
        },
        {
            source = "src/dickos/lib/fs_guard.lua",
            target = "/dickos/lib/fs_guard.lua",
        },
        {
            source = "src/dickos/lib/editor_buffer.lua",
            target = "/dickos/lib/editor_buffer.lua",
        },
        {
            source = "src/dickos/lib/hardware.lua",
            target = "/dickos/lib/hardware.lua",
        },
        {
            source = "src/dickos/lib/service_client.lua",
            target = "/dickos/lib/service_client.lua",
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
            source = "src/dickos/bin/peripherals.lua",
            target = "/dickos/bin/peripherals.lua",
        },
        {
            source = "src/dickos/bin/services.lua",
            target = "/dickos/bin/services.lua",
        },
        {
            source = "src/dickos/bin/service.lua",
            target = "/dickos/bin/service.lua",
        },
        {
            source = "src/dickos/bin/whoami.lua",
            target = "/dickos/bin/whoami.lua",
        },
        {
            source = "src/dickos/bin/id.lua",
            target = "/dickos/bin/id.lua",
        },
        {
            source = "src/dickos/bin/passwd.lua",
            target = "/dickos/bin/passwd.lua",
        },
        {
            source = "src/dickos/bin/touch.lua",
            target = "/dickos/bin/touch.lua",
        },
        {
            source = "src/dickos/bin/mkdir.lua",
            target = "/dickos/bin/mkdir.lua",
        },
        {
            source = "src/dickos/bin/cp.lua",
            target = "/dickos/bin/cp.lua",
        },
        {
            source = "src/dickos/bin/mv.lua",
            target = "/dickos/bin/mv.lua",
        },
        {
            source = "src/dickos/bin/rm.lua",
            target = "/dickos/bin/rm.lua",
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
