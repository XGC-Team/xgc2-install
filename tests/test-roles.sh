#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
script="${root}/install.sh"
chmod +x "$script"

bash -n "$script"

list="$("$script" --list)"
printf '%s\n' "$list" | grep -qx $'gcs\tGCS\txgc2-core'
printf '%s\n' "$list" | grep -qx $'robot\tROBOT\txgc2-agent'
if printf '%s\n' "$list" | grep -Eq 'agilex|fs150|timezone|desktop'; then
  echo "retired vehicle/host roles must not appear" >&2
  exit 1
fi

"$script" --help >/dev/null

if "$script" --role nosuch; then
  echo "unknown role should fail" >&2
  exit 1
fi

if "$script" --print-source >/dev/null 2>&1; then
  echo "unsubstituted APT placeholder should fail" >&2
  exit 1
fi
grep -Fq '__XGC2_APT_BASE_URL__' "$script"
grep -Fq '__XGC2_APT_KEY_FINGERPRINT__' "$script"
if grep -Eiq 'https?://[[:alnum:].-]+\.[a-z]{2,}' "$script" README.md; then
  echo "product tree must not contain a hostname" >&2
  exit 1
fi

line="$("$script" --source-url http://127.0.0.1 --print-source)"
[[ "$line" == deb\ *http://127.0.0.1* ]]

echo "test-roles ok"
