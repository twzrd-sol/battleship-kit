#!/usr/bin/env python3
"""Write a read-only truth board about this machine for agents to read first.

Output: ~/.config/kit/status.json. No secrets, no secret-manager calls, no
wallet material. Mutates nothing but its own file. Run from a user timer every
few minutes. Every field is something a human can re-derive with one command;
the command is named next to the field in this file.

gate_color means LIVE HEALTH (production answers), never "main is passing".
"""
from __future__ import annotations
import json, os, subprocess, time
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(os.environ.get("KIT_STATUS_OUT", Path.home() / ".config/kit/status.json"))
SHARED = Path(os.environ.get("KIT_SHARED_TREE_PATH", Path.home() / "app"))
FF_LOG = Path(os.environ.get("KIT_FF_LOG", Path.home() / ".local/state/ff-only.log"))
HEALTH_URLS = [u for u in os.environ.get("KIT_HEALTH_URLS", "").split(",") if u]
CONTAINERS = [c for c in os.environ.get("KIT_PROD_CONTAINERS", "").split(",") if c]

def run(cmd, timeout=8):
    """(returncode, stdout). The return code is None when the command could not run or timed out:
    its text is never data, and every caller must check for 0 before it believes the output."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None, ""

def host():  # uname -r; /proc/uptime; /proc/loadavg; free -b; df -B1 /
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1); mem[k] = int(v.split()[0]) * 1024
    st = os.statvfs("/")
    return {
        "hostname": os.uname().nodename, "kernel": os.uname().release,
        "uptime_seconds": int(float(open("/proc/uptime").read().split()[0])),
        "loadavg": [float(x) for x in open("/proc/loadavg").read().split()[:3]],
        "memory": {"MemTotal": mem.get("MemTotal"), "MemAvailable": mem.get("MemAvailable"),
                   "SwapTotal": mem.get("SwapTotal"), "SwapFree": mem.get("SwapFree")},
        "disk_root": {"size_bytes": st.f_blocks * st.f_frsize, "avail_bytes": st.f_bavail * st.f_frsize},
    }

def containers():  # docker ps --format '{{.Names}}\t{{.Status}}'
    """Return (rows, error). A CONFIGURED container that is not listed is DOWN, not absent."""
    rc, out = run(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"])
    if rc != 0:
        return [], "docker ps failed"
    listed = {}
    for line in out.splitlines():
        name, _, status = line.partition("\t")
        listed[name] = status
    rows = []
    for name in (CONTAINERS or sorted(listed)):
        status = listed.get(name)
        if status is None:
            rows.append({"name": name, "status": "not running", "state": "down", "healthy": False})
            continue
        if "(Paused)" in status: state = "paused"         # a paused container is not serving
        elif "(unhealthy)" in status: state = "unhealthy"
        elif "health: starting" in status: state = "starting"
        elif "(healthy)" in status: state = "healthy"
        elif status.startswith("Up"): state = "up"   # running, no healthcheck defined
        else: state = "down"
        rows.append({"name": name, "status": status, "state": state, "healthy": state in ("healthy", "up")})
    return rows, None

def _ff_lines():
    try:
        return FF_LOG.read_text().splitlines() if FF_LOG.exists() else []
    except OSError:
        return []

def shared_git():  # git -C $SHARED status --porcelain --untracked-files=no; rev-parse HEAD origin/main
    if not SHARED.exists():
        return {"path": str(SHARED), "present": False}
    def g(*a):   # None when git failed: a field that could not be read is null, never false
        rc, out = run(["git", "-C", str(SHARED), *a])
        return out.strip() if rc == 0 else None
    dirty, wts = g("status", "--porcelain", "--untracked-files=no"), g("worktree", "list")
    board = {"path": str(SHARED), "present": True, "branch": g("rev-parse", "--abbrev-ref", "HEAD"),
             "head": g("rev-parse", "--short", "HEAD"), "origin_main": g("rev-parse", "--short", "origin/main"),
             "tracked_dirty": None if dirty is None else bool(dirty),
             "worktree_count": None if wts is None else len(wts.splitlines()),
             "ff_only_last": (_ff_lines()[-1] if _ff_lines() else None)}
    if any(board[k] is None for k in ("branch", "head", "tracked_dirty", "worktree_count")):
        errors.append("shared_git: git could not read the shared checkout")
    return board

def timers():  # systemctl --user list-timers --all --no-legend --no-pager | grep -c .   (every timer row, enabled or not)
    rc, out = run(["systemctl", "--user", "list-timers", "--all", "--no-legend", "--no-pager"])
    if rc != 0:
        errors.append("timers: systemctl could not list the user timers")
        return {"count": None}
    return {"count": len([l for l in out.splitlines() if l.strip()])}

def health():  # curl -s -o /dev/null -w '%{http_code}' URL
    res = []
    for u in HEALTH_URLS:
        t = time.time(); rc, code = run(["curl", "-s", "-m", "6", "-o", "/dev/null", "-w", "%{http_code}", u])
        if rc is None:
            raise RuntimeError("curl could not run")   # not a red service: no answer to read, so the color is unknown
        res.append({"url": u, "code": code.strip(), "seconds": round(time.time() - t, 2)})
    return res

def backup_age():  # newest object in the backup bucket; wire your lister here, report AGE not exit status
    return {"newest_object_age_hours": None, "note": "wire a read-only bucket listing; age, never job status"}

errors = []

def safe(fn, default):
    """One broken section must not stop the board being written, and must not read as healthy."""
    try:
        return fn()
    except Exception as e:
        errors.append("%s: %s" % (fn.__name__, type(e).__name__))
        return default

def main():
    h = safe(health, [])
    c, c_err = safe(containers, ([], "containers failed"))
    # Only CONFIGURED expectations produce a color. Each check is True, False, or None (could not tell).
    checks = []
    if HEALTH_URLS:
        checks.append(None if any(e.startswith("health") for e in errors) else all(r["code"] == "200" for r in h))
    if CONTAINERS:
        checks.append(None if (c_err or any(e.startswith("containers") for e in errors)) else all(x["healthy"] for x in c))
    if not checks:
        color = "unknown"      # nothing configured: no evidence is not green (see LESSONS 3)
    elif any(x is False for x in checks):
        color = "red"
    elif any(x is None for x in checks):
        color = "unknown"      # a configured check could not be run: cannot attest
    else:
        color = "green"
    host_b, git_b, timers_b = safe(host, {}), safe(shared_git, {}), safe(timers, {})
    board = {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "valid_for_seconds": 600,   # a reader treats a board older than this as unknown, whatever its color says
             "read_me": "Read-only truth board. Agents read this before touching code or services. Not a public API.",
             "gate_color": color, "gate_color_means": "live health, not main passing",
             "gate_color_inputs": {"health_urls": len(HEALTH_URLS), "containers": len(CONTAINERS), "container_error": c_err},
             "host": host_b, "containers": c, "shared_git": git_b, "timers": timers_b,
             "health": h, "backup": backup_age(), "section_errors": errors}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp"); tmp.write_text(json.dumps(board, indent=2)); tmp.replace(OUT)
    print(f"wrote {OUT} gate_color={color}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
