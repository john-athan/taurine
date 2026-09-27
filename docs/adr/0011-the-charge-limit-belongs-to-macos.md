# 11. The charge limit belongs to macOS

Date: 2026-09-23
Status: accepted

## Context

Taurine limited charging with a root LaunchDaemon that wrote an undocumented
SMC key (`CHTE` on macOS 26, `CH0B`+`CH0C` before). macOS 27 ships a charge
limit in System Settings → Battery. powerd keeps it as a `manualChargeLimit`
policy in `/Library/Preferences/com.apple.powerd.charging.plist` and drives the
same hardware. On the first macOS 27 machine the daemon exited with status 1 on
every start: 3,041 launchd respawns before anyone noticed.

## Decision

Delete the charge limiter: the daemon, the SMC client, the installer and the
config files, on every macOS version. What remains is `OldChargeDaemon`, which
removes an earlier install behind one admin prompt from the menu, and
`taurine batt`, which points at System Settings.

## Consequences

- One root daemon, one reverse-engineered SMC interface and one admin prompt
  fewer. Apple changed that interface twice; the next change is theirs to carry.
- Macs on macOS 13 to 26 lose the feature. AlDente covers them.
- Two limiters writing one SMC key cannot happen any more.
- The cleanup has to stay until old installs are plausibly gone. It is about
  40 lines and costs nothing when the files are absent.
