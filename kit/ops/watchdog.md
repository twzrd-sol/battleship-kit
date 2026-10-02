# Hardware watchdog

A box that serves production and also does risky things (GPU passthrough,
kernel module unloads, driver experiments) needs a hardware watchdog armed
BEFORE the first risky action. A hang otherwise leaves production dark until
someone power-cycles the machine.

Recipe (the module depends on the board, for example `iTCO_wdt` on Intel chipsets or
`sp5100_tco` on many AMD ones):

1. Load the module by hand once and confirm `/dev/watchdog0` appears.
2. Persist the load. Note that Ubuntu ships a kernel blacklist for watchdog
   modules and `systemd-modules-load` honors it, so a `modules-load.d` entry
   silently does nothing. Use a oneshot unit that runs a bare `modprobe`
   instead.
3. Set `RuntimeWatchdogSec=60s` in a `system.conf.d` drop-in and
   `systemctl daemon-reexec`. Verify `state=active` and that `timeleft`
   sawtooths (PID 1 pets it every ~20 s).
4. After any reboot, verify the device exists again. "RuntimeWatchdogSec set,
   no device" is silently inert.

What it bought us: a poweroff that stalled with a VM holding the GPU became a
60-second reset instead of a dark box. What it did not buy: the last minute
of the journal, which the reset loses. Journald syncs on an interval; accept
that and look at file mtimes for the timeline.

Pair it with: GRUB pinned to a kernel you have actually booted, a logind
drop-in that ignores the power key on a production box, and the rule
"shut the VM down first, confirm it is off, then reboot".
