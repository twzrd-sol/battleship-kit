#!/usr/bin/env python3
"""Read-only backup attestation. Reads a bucket listing on stdin, one object per
line: <key>\t<size_bytes>\t<last_modified ISO-8601>. Classifies by AGE and
completeness, never by the dump job's exit status.

Exit 0: healthy (warnings allowed). Exit 1: a FAIL finding. Exit 2: cannot attest
(empty listing, listing error). Both 1 and 2 should page.

Env: KIT_MAX_AGE_HOURS (default 30), KIT_MIN_BYTES (default 1), KIT_NOW (tests).
"""
from __future__ import annotations
import os, sys
from datetime import datetime, timezone, timedelta

MAX_AGE_H = float(os.environ.get("KIT_MAX_AGE_HOURS", "30"))
MIN_BYTES = int(os.environ.get("KIT_MIN_BYTES", "1"))

def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)

def main() -> int:
    now = parse_ts(os.environ["KIT_NOW"]) if os.environ.get("KIT_NOW") else datetime.now(timezone.utc)
    rows, findings, warns = [], [], []
    raw = sys.stdin.read().splitlines()
    if not raw:
        print("CANNOT ATTEST: empty listing (bucket unreachable, wrong prefix, or no objects)"); return 2
    for n, line in enumerate(raw, 1):
        parts = line.split("\t")
        if len(parts) != 3:
            findings.append(f"unparseable listing line {n}: {line[:80]!r}"); continue
        key, size, ts = parts
        try:
            rows.append((key, int(size), parse_ts(ts)))
        except ValueError as e:
            findings.append(f"unparseable size/time on line {n} ({key}): {e}")
    if rows:
        key, size, ts = max(rows, key=lambda r: r[2])
        age_h = (now - ts).total_seconds() / 3600
        if age_h > MAX_AGE_H: findings.append(f"newest object {key} is {age_h:.1f} h old (max {MAX_AGE_H})")
        elif age_h > MAX_AGE_H * 0.8: warns.append(f"newest object {key} is {age_h:.1f} h old (late)")
        if size < MIN_BYTES: findings.append(f"newest object {key} is {size} bytes (min {MIN_BYTES})")
        days = {r[2].date() for r in rows}
        missing = [d.isoformat() for d in (now.date() - timedelta(days=i) for i in range(1, 8)) if d not in days]
        if missing: warns.append("missing days in the last 7: " + ", ".join(missing))
        print(f"objects={len(rows)} newest={key} age_h={age_h:.1f} size={size}")
    for w in warns: print("WARN", w)
    for f in findings: print("FAIL", f)
    return 1 if findings else 0

if __name__ == "__main__":
    raise SystemExit(main())
