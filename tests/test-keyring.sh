#!/usr/bin/env bash
# Write path against a local keyring. No host APT. No product domain.
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
script="${root}/install.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/xgc2-install-keyring.XXXXXX")"
trap 'kill "${httpd_pid:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT

export GNUPGHOME="${tmp}/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key \
  "Test <test@localhost>" default default never >/dev/null 2>&1
gpg --batch --export > "${tmp}/xgc2-archive-keyring.gpg"
fpr="$(
  gpg --show-keys --with-fingerprint --with-colons "${tmp}/xgc2-archive-keyring.gpg" \
    | awk -F: '/^fpr:/{print $10; exit}'
)"
test -n "$fpr"

port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server --bind 127.0.0.1 --directory "$tmp" "$port" >"${tmp}/httpd.out" 2>&1 &
httpd_pid=$!
ready=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${port}/xgc2-archive-keyring.gpg" -o /dev/null; then
    ready=1
    break
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  echo "local keyring HTTP server did not start" >&2
  cat "${tmp}/httpd.out" >&2 || true
  exit 1
fi

export XGC2_APT_KEY_FINGERPRINT="$fpr"
list="${tmp}/xgc2.list"
# install.sh writes the real list path; exercise --print-source + fingerprint gate via source-only
# would need root to write /etc/apt. Check print-source and mismatch only.
line="$("$script" --source-url "http://127.0.0.1:${port}" --print-source)"
[[ "$line" == *"http://127.0.0.1:${port}"* ]]

export XGC2_APT_KEY_FINGERPRINT=DEADBEEF
# source-only still fetches and verifies before writing; run in a fakeroot-less
# path by expecting verify to fail after curl.
if "$script" --source-url "http://127.0.0.1:${port}" --source-only --yes --role gcs; then
  echo "fingerprint mismatch should fail" >&2
  exit 1
fi

echo "test-keyring ok"
