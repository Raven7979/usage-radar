#!/bin/bash
set -euo pipefail

input_file="$(mktemp)"
trap 'rm -f "$input_file"' EXIT
cat > "$input_file"

cache_dir="$HOME/Library/Application Support/QuotaRadar"
cache_file="$cache_dir/claude-rate-limits.json"
probe_file="$cache_dir/claude-statusline-probe.json"
mkdir -p "$cache_dir"

/usr/bin/python3 - "$input_file" "$cache_file" "$probe_file" <<'PY'
import datetime
import json
import os
import sys

input_path, cache_path, probe_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(input_path, "r", encoding="utf-8") as f:
    raw = f.read()

try:
    data = json.loads(raw or "{}")
except json.JSONDecodeError:
    print("Claude")
    raise SystemExit(0)

rate_limits = data.get("rate_limits") or {}
model = (data.get("model") or {}).get("display_name") or "Claude"

probe = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "source": "claude-code-statusline",
    "session_id": data.get("session_id"),
    "model": model,
    "cwd": data.get("workspace", {}).get("current_dir") if isinstance(data.get("workspace"), dict) else None,
    "has_rate_limits": bool(rate_limits),
    "rate_limit_keys": sorted(rate_limits.keys()),
}
tmp_probe_path = f"{probe_path}.tmp"
with open(tmp_probe_path, "w", encoding="utf-8") as f:
    json.dump(probe, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp_probe_path, probe_path)

def read_window(name):
    window = rate_limits.get(name) or {}
    used = window.get("used_percentage")
    if used is None:
        return None
    try:
        used_value = float(used)
    except (TypeError, ValueError):
        return None
    return {
        "used_percentage": used_value,
        "resets_at": window.get("resets_at"),
    }

five_hour = read_window("five_hour")
seven_day = read_window("seven_day")

if five_hour or seven_day:
    payload = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": "claude-code-statusline",
        "session_id": data.get("session_id"),
        "model": model,
        "five_hour": five_hour,
        "seven_day": seven_day,
    }
    tmp_path = f"{cache_path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp_path, cache_path)

parts = []
if five_hour:
    parts.append(f"5h {max(0, 100 - five_hour['used_percentage']):.0f}% left")
if seven_day:
    parts.append(f"7d {max(0, 100 - seven_day['used_percentage']):.0f}% left")

print(f"{model} | {' · '.join(parts)}" if parts else model)
PY
