#!/usr/bin/env bash
# Install xgc2-core (gcs) or xgc2-agent (robot).
set -euo pipefail

VERSION="0.2.0"
APT_BASE_URL="${XGC2_APT_BASE_URL:-__XGC2_APT_BASE_URL__}"
KEYRING_NAME="xgc2-archive-keyring.gpg"
EXPECTED_FPR="${XGC2_APT_KEY_FINGERPRINT:-__XGC2_APT_KEY_FINGERPRINT__}"
# curl | bash sets $0 to "bash" and leaves BASH_SOURCE unset (fatal with set -u).
case "${0##*/}" in
  bash|sh|dash|-bash|-sh|-)
    SCRIPT_DIR=""
    ;;
  *)
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
    ;;
esac
PROFILE_DIR="${SCRIPT_DIR:+${SCRIPT_DIR}/profiles}"

usage() {
  cat <<EOF
Usage:
  $0
  $0 --role gcs|robot --yes
  $0 --uninstall --role gcs|robot --yes
  $0 --source-only --yes

  (no args)          interactive HUD on a real terminal
  --role NAME        gcs (core) or robot (agent)
  --source-url URL   override APT base
  --uninstall        purge the role package
  --yes              non-interactive
  --source-only      write the APT source only
  --list
  -h, --help
EOF
}

# stdin may be the script itself (curl | sudo bash). The HUD uses /dev/tty.
is_tty() { [[ -t 1 && -r /dev/tty && -w /dev/tty ]]; }

normalize_role() {
  case "$1" in
    gcs|core) echo gcs ;;
    robot|agent) echo robot ;;
    *) echo "$1" ;;
  esac
}

# --- profiles --------------------------------------------------------------

PROFILE_IDS=()
PROFILE_LABELS=()
PROFILE_DETAILS=()
PROFILE_HINTS=()
PROFILE_PURGE_GLOBS=()
PROFILE_PURGE_UNITS=()
PROFILE_PURGE_UNIT_GLOBS=()
declare -A PROFILE_PKG=()

register_profile() {
  local id="$1" label="$2" detail="$3" hint="$4" pkg="$5" glob="$6" units="$7"
  PROFILE_IDS+=("$id")
  PROFILE_LABELS+=("$label")
  PROFILE_DETAILS+=("$detail")
  PROFILE_HINTS+=("$hint")
  PROFILE_PKG["$id"]="$pkg"
  PROFILE_PURGE_GLOBS+=("$glob")
  PROFILE_PURGE_UNITS+=("$units")
  PROFILE_PURGE_UNIT_GLOBS+=("${8:-$pkg}")
}

load_profile_file() {
  local file="$1"
  local PROFILE_ID="" PROFILE_LABEL="" PROFILE_DETAIL="" PROFILE_HINT=""
  local PACKAGE="" PURGE_PKG_GLOB="" PURGE_UNITS="" PURGE_UNIT_GLOB=""
  # shellcheck disable=SC1090
  source "$file"
  [[ -n "$PROFILE_ID" && -n "$PACKAGE" ]] || return 0
  register_profile "$PROFILE_ID" "$PROFILE_LABEL" "$PROFILE_DETAIL" \
    "$PROFILE_HINT" "$PACKAGE" "${PURGE_PKG_GLOB:-$PACKAGE}" \
    "$PURGE_UNITS" "${PURGE_UNIT_GLOB:-$PACKAGE}"
}

load_profiles() {
  local f
  if [[ -d "$PROFILE_DIR" ]]; then
    for f in "$PROFILE_DIR"/*.conf; do
      [[ -f "$f" ]] || continue
      load_profile_file "$f"
    done
  fi
  if ((${#PROFILE_IDS[@]} == 0)); then
    register_profile gcs "GCS" "Ground station · Core" \
      "xgc2-core only" xgc2-core xgc2-core xgc2-core.service xgc2-core
    register_profile robot "ROBOT" "Onboard · Agent" \
      "xgc2-agent only" xgc2-agent xgc2-agent xgc2-agent.service xgc2-agent
  fi
}

profile_index() {
  local id="$1" i
  id="$(normalize_role "$id")"
  for i in "${!PROFILE_IDS[@]}"; do
    if [[ "${PROFILE_IDS[$i]}" == "$id" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

package_for() {
  local id="$1" pkg=""
  id="$(normalize_role "$id")"
  pkg="${PROFILE_PKG[$id]:-}"
  if [[ -z "$pkg" ]]; then
    echo "no package mapped for role '${id}'" >&2
    return 1
  fi
  printf '%s' "$pkg"
}

# --- host facts ------------------------------------------------------------

host_arch() { dpkg --print-architecture 2>/dev/null || uname -m; }

host_suite() {
  local suite=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    suite="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  fi
  if [[ -z "$suite" ]] && command -v lsb_release >/dev/null 2>&1; then
    suite="$(lsb_release -cs)"
  fi
  printf '%s' "${suite:-unknown}"
}

host_pretty() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-Linux}"
  else
    printf 'Linux'
  fi
}

require_apt_url() {
  case "$APT_BASE_URL" in
    http://*|https://*) ;;
    *)
      echo "APT base is not configured" >&2
      return 2
      ;;
  esac
}

require_apt_key() {
  if [[ ! "$EXPECTED_FPR" =~ ^[0-9A-Fa-f]{16,}$ ]]; then
    echo "APT key fingerprint is not configured" >&2
    return 2
  fi
}

# --- HUD -------------------------------------------------------------------

C_RESET="" C_DIM="" C_BOLD="" C_CYAN="" C_TEAL="" C_AMBER="" C_GREEN="" C_RED="" C_LINE=""

setup_colors() {
  if ! is_tty || [[ -n "${NO_COLOR:-}" ]]; then
    return 0
  fi
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[38;5;51m'
  C_TEAL=$'\033[38;5;44m'
  C_AMBER=$'\033[38;5;214m'
  C_GREEN=$'\033[38;5;84m'
  C_RED=$'\033[38;5;203m'
  C_LINE=$'\033[38;5;24m'
}

ui() { is_tty || return 0; printf "$@" > /dev/tty; }
hide_cursor() { is_tty && ui '\033[?25l'; }
show_cursor() { is_tty && ui '\033[?25h'; }
clear_screen() { is_tty && ui '\033[2J\033[H'; }

restore_terminal() {
  show_cursor
  if [[ -n "${STTY_ORIG:-}" ]]; then
    stty "$STTY_ORIG" < /dev/tty 2>/dev/null || true
  fi
}

W=62

draw_frame_top() {
  ui '%s╔%s╗%s\n' "$C_LINE" "$(printf '═%.0s' $(seq 1 "$W"))" "$C_RESET"
}

draw_frame_bot() {
  ui '%s╚%s╝%s\n' "$C_LINE" "$(printf '═%.0s' $(seq 1 "$W"))" "$C_RESET"
}

frame_row() {
  local inner="$1"
  ui '%s║%s%s%s║%s\n' "$C_LINE" "$C_RESET" "$inner" "$C_LINE" "$C_RESET"
}

pad_inner() {
  local raw="$1"
  local visible
  visible="$(printf '%s' "$raw" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
  local n=${#visible}
  local fill=$((W - n))
  ((fill < 0)) && fill=0
  printf '%s%*s' "$raw" "$fill" ""
}

draw_brand() {
  draw_frame_top
  frame_row "$(pad_inner "  ${C_CYAN}${C_BOLD}XGC${C_RESET}  ${C_DIM}INSTALL${C_RESET}                              ${C_AMBER}${VERSION}${C_RESET}")"
  frame_row "$(pad_inner "  ${C_LINE}$(printf '─%.0s' $(seq 1 58))${C_RESET}")"
  if [[ "${ACTION:-install}" == uninstall ]]; then
    frame_row "$(pad_inner "  ${C_RED}${C_BOLD}PURGE${C_RESET}  ${C_DIM}remove core or agent${C_RESET}")"
  else
    frame_row "$(pad_inner "  ${C_AMBER}${C_BOLD}DEPLOY${C_RESET}  ${C_DIM}install core or agent${C_RESET}")"
  fi
}

draw_facts() {
  local host suite arch pretty
  host="$(hostname -s 2>/dev/null || hostname)"
  suite="$(host_suite)"
  arch="$(host_arch)"
  pretty="$(host_pretty)"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_DIM}HOST${C_RESET}  ${host}    ${C_DIM}ARCH${C_RESET}  ${arch}")"
  frame_row "$(pad_inner "  ${C_DIM}OS  ${C_RESET}  ${pretty}  ${C_DIM}SUITE${C_RESET} ${suite}")"
  if [[ -n "$APT_BASE_URL" ]]; then
    frame_row "$(pad_inner "  ${C_DIM}APT ${C_RESET}  ${APT_BASE_URL}")"
  else
    frame_row "$(pad_inner "  ${C_AMBER}APT ${C_RESET}  unset — pass --source-url")"
  fi
}

draw_menu() {
  local selected="$1"
  local i marker label
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_AMBER}${C_BOLD}SELECT ROLE${C_RESET}")"
  frame_row "$(pad_inner "")"
  for i in "${!PROFILE_IDS[@]}"; do
    label="${PROFILE_LABELS[$i]}"
    if [[ "$i" == "$selected" ]]; then
      marker="${C_CYAN}▶${C_RESET}"
      frame_row "$(pad_inner "    ${marker} ${C_BOLD}${C_CYAN}${label}${C_RESET}    ${PROFILE_DETAILS[$i]}")"
      frame_row "$(pad_inner "       ${C_DIM}${PROFILE_HINTS[$i]}${C_RESET}")"
    else
      frame_row "$(pad_inner "      ${C_DIM}${label}${C_RESET}    ${C_DIM}${PROFILE_DETAILS[$i]}${C_RESET}")"
    fi
  done
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_DIM}↑↓  select     enter  confirm     q  abort${C_RESET}")"
  draw_frame_bot
}

draw_action_menu() {
  local selected="$1"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_AMBER}${C_BOLD}SELECT ACTION${C_RESET}")"
  frame_row "$(pad_inner "")"
  if [[ "$selected" == 0 ]]; then
    frame_row "$(pad_inner "    ${C_CYAN}▶${C_RESET} ${C_BOLD}${C_CYAN}DEPLOY${C_RESET}     add APT source, install role")"
    frame_row "$(pad_inner "      ${C_DIM}PURGE${C_RESET}      remove that role package")"
  else
    frame_row "$(pad_inner "      ${C_DIM}DEPLOY${C_RESET}     add APT source, install role")"
    frame_row "$(pad_inner "    ${C_RED}▶${C_RESET} ${C_BOLD}${C_RED}PURGE${C_RESET}      remove that role package")"
  fi
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_DIM}↑↓  select     enter  confirm     q  abort${C_RESET}")"
  draw_frame_bot
}

draw_confirm() {
  local idx="$1" pkg
  pkg="$(package_for "${PROFILE_IDS[$idx]}")"
  draw_frame_top
  frame_row "$(pad_inner "  ${C_CYAN}${C_BOLD}XGC${C_RESET}  ${C_DIM}INSTALL${C_RESET}                               ${C_AMBER}DEPLOY${C_RESET}")"
  frame_row "$(pad_inner "  ${C_LINE}$(printf '─%.0s' $(seq 1 58))${C_RESET}")"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_DIM}ROLE   ${C_RESET}   ${C_BOLD}${PROFILE_LABELS[$idx]}${C_RESET}  ${PROFILE_DETAILS[$idx]}")"
  frame_row "$(pad_inner "  ${C_DIM}PACKAGE${C_RESET}   ${pkg}")"
  frame_row "$(pad_inner "  ${C_DIM}SOURCE ${C_RESET}   ${APT_BASE_URL:-unset}")"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_AMBER}enter${C_RESET}  write APT source and install")"
  frame_row "$(pad_inner "  ${C_DIM}q${C_RESET}      abort")"
  frame_row "$(pad_inner "")"
  draw_frame_bot
}

draw_confirm_purge() {
  local idx="$1" pkg
  pkg="$(package_for "${PROFILE_IDS[$idx]}")"
  draw_frame_top
  frame_row "$(pad_inner "  ${C_CYAN}${C_BOLD}XGC${C_RESET}  ${C_DIM}INSTALL${C_RESET}                                ${C_RED}PURGE${C_RESET}")"
  frame_row "$(pad_inner "  ${C_LINE}$(printf '─%.0s' $(seq 1 58))${C_RESET}")"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_DIM}ROLE   ${C_RESET}   ${C_BOLD}${PROFILE_LABELS[$idx]}${C_RESET}")"
  frame_row "$(pad_inner "  ${C_DIM}PURGE  ${C_RESET}   ${pkg}")"
  frame_row "$(pad_inner "")"
  frame_row "$(pad_inner "  ${C_RED}enter${C_RESET}  purge this role")"
  frame_row "$(pad_inner "  ${C_DIM}q${C_RESET}      abort")"
  frame_row "$(pad_inner "")"
  draw_frame_bot
}

status_line() {
  local kind="$1" msg="$2"
  case "$kind" in
    run) printf '  %s·%s  %s\n' "$C_AMBER" "$C_RESET" "$msg" ;;
    ok)  printf '  %s✓%s  %s\n' "$C_GREEN" "$C_RESET" "$msg" ;;
    err) printf '  %s✗%s  %s\n' "$C_RED" "$C_RESET" "$msg" ;;
  esac
}

need_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
  else
    SUDO=(sudo)
  fi
}

# --- APT -------------------------------------------------------------------

deb_line() {
  local suite arch keydir
  suite="$(host_suite)"
  arch="$(host_arch)"
  keydir=/etc/apt/keyrings
  printf 'deb [arch=%s signed-by=%s/%s] %s %s main\n' \
    "$arch" "$keydir" "$KEYRING_NAME" "$APT_BASE_URL" "$suite"
}

verify_fingerprint() {
  local keyfile="$1" home fpr
  if gpg --help 2>&1 | grep -q -- '--show-keys'; then
    fpr="$(gpg --show-keys --with-fingerprint --with-colons "$keyfile" 2>/dev/null \
      | awk -F: '/^fpr:/{print $10; exit}')"
  else
    home="$(mktemp -d)"
    gpg --homedir "$home" --batch --import "$keyfile" >/dev/null 2>&1
    fpr="$(gpg --homedir "$home" --batch --with-colons --fingerprint 2>/dev/null \
      | awk -F: '/^fpr:/{print $10; exit}')"
    rm -rf "$home"
  fi
  [[ "$fpr" == "$EXPECTED_FPR" ]]
}

install_apt_source() {
  local tmp keydir
  require_apt_url
  require_apt_key
  tmp="$(mktemp)"
  status_line run "fetch keyring"
  curl -fsSL "${APT_BASE_URL}/${KEYRING_NAME}" -o "$tmp"
  status_line run "verify fingerprint ${EXPECTED_FPR:0:8}…"
  if ! verify_fingerprint "$tmp"; then
    rm -f "$tmp"
    status_line err "archive key fingerprint mismatch"
    return 1
  fi
  keydir=/etc/apt/keyrings
  "${SUDO[@]}" install -d -m 0755 "$keydir"
  "${SUDO[@]}" cp "$tmp" "${keydir}/${KEYRING_NAME}"
  "${SUDO[@]}" chmod 0644 "${keydir}/${KEYRING_NAME}"
  rm -f "$tmp"
  deb_line | "${SUDO[@]}" tee /etc/apt/sources.list.d/xgc2.list >/dev/null
  status_line ok "wrote /etc/apt/sources.list.d/xgc2.list"
}

install_if_present() {
  local pkg="$1"
  if ! apt-cache show "$pkg" >/dev/null 2>&1; then
    status_line err "${pkg} is not in the index"
    return 1
  fi
  status_line run "install ${pkg}"
  "${SUDO[@]}" apt-get install -y "$pkg"
  status_line ok "${pkg} is installed"
}

install_profile() {
  local id="$1" pkg
  pkg="$(package_for "$id")"
  need_sudo
  printf '\n'
  install_apt_source
  status_line run "apt-get update (xgc2 only)"
  "${SUDO[@]}" apt-get update \
    -o Dir::Etc::sourcelist="sources.list.d/xgc2.list" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0"
  if [[ "$SOURCE_ONLY" -eq 1 ]]; then
    status_line ok "source-only: not installing packages"
    return 0
  fi
  install_if_present "$pkg"
  printf '\n  %snext%s  review /etc/xgc2 and enable the service\n' "$C_DIM" "$C_RESET"
  printf '  %s     %s  extras stay in APT; install them from Core/Agent\n\n' "$C_DIM" "$C_RESET"
}

installed_packages_matching() {
  local needle="$1"
  dpkg-query -W -f '${db:Status-Abbrev}\t${Package}\n' 2>/dev/null \
    | awk -v n="$needle" '$1 ~ /^ii/ && index($2, n) { print $2 }'
}

systemd_is_running() { [[ -d /run/systemd/system ]]; }

stop_profile_units() {
  local units="$1" unit_glob="$2" f base
  systemd_is_running || return 0
  for base in $units; do
    "${SUDO[@]}" systemctl disable --now "$base" >/dev/null 2>&1 || true
  done
  if [[ -n "$unit_glob" ]]; then
    for f in /lib/systemd/system/${unit_glob}* /etc/systemd/system/${unit_glob}*; do
      [[ -e "$f" ]] || continue
      "${SUDO[@]}" systemctl disable --now "$(basename "$f")" >/dev/null 2>&1 || true
    done
  fi
  "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
}

drop_apt_source_if_unused() {
  local leftover
  leftover="$(installed_packages_matching xgc2 || true)"
  if [[ -n "$leftover" ]]; then
    status_line ok "kept APT source — other xgc2 packages remain"
    return 0
  fi
  if [[ -e /etc/apt/sources.list.d/xgc2.list ]]; then
    "${SUDO[@]}" rm -f /etc/apt/sources.list.d/xgc2.list
    status_line ok "removed /etc/apt/sources.list.d/xgc2.list"
  fi
  if [[ -e /etc/apt/keyrings/${KEYRING_NAME} ]]; then
    "${SUDO[@]}" rm -f "/etc/apt/keyrings/${KEYRING_NAME}"
    status_line ok "removed /etc/apt/keyrings/${KEYRING_NAME}"
  fi
}

uninstall_profile() {
  local id="$1" idx="$2" pkg glob units unit_glob leftover
  local -a pkgs=()
  pkg="$(package_for "$id")"
  glob="${PROFILE_PURGE_GLOBS[$idx]:-$pkg}"
  units="${PROFILE_PURGE_UNITS[$idx]:-}"
  unit_glob="${PROFILE_PURGE_UNIT_GLOBS[$idx]:-$pkg}"
  need_sudo
  printf '\n'
  status_line run "stop ${id} services"
  stop_profile_units "$units" "$unit_glob"

  while IFS= read -r leftover; do
    [[ -n "$leftover" ]] && pkgs+=("$leftover")
  done < <(installed_packages_matching "$glob")
  if [[ -n "$pkg" ]] && dpkg-query -W -f '${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    local seen=0 p
    for p in "${pkgs[@]+"${pkgs[@]}"}"; do
      [[ "$p" == "$pkg" ]] && seen=1
    done
    [[ "$seen" -eq 1 ]] || pkgs+=("$pkg")
  fi

  if ((${#pkgs[@]} > 0)); then
    status_line run "purge ${#pkgs[@]} package(s)"
    "${SUDO[@]}" apt-get purge -y "${pkgs[@]}"
    "${SUDO[@]}" apt-get autoremove --purge -y
  else
    status_line ok "no ${glob} packages installed"
  fi

  if systemd_is_running; then
    "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  drop_apt_source_if_unused
  leftover="$(installed_packages_matching "$glob" || true)"
  if [[ -n "$leftover" ]]; then
    status_line err "still installed:"$'\n'"${leftover}"
    return 1
  fi
  status_line ok "${id} purged"
}

# --- input -----------------------------------------------------------------

read_key() {
  local key rest
  IFS= read -rsn1 key < /dev/tty || return 1
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 rest < /dev/tty || rest=""
    case "$rest" in
      '[A') echo up ;;
      '[B') echo down ;;
      *) echo esc ;;
    esac
    return 0
  fi
  case "$key" in
    '') echo enter ;;
    q|Q) echo quit ;;
    *) echo other ;;
  esac
}

select_action() {
  local idx=0
  if is_tty; then
    STTY_ORIG="$(stty -g < /dev/tty)"
    stty -echo < /dev/tty
  fi
  trap restore_terminal EXIT
  hide_cursor
  while true; do
    clear_screen
    ACTION=install
    [[ "$idx" == 1 ]] && ACTION=uninstall
    draw_brand
    draw_facts
    draw_action_menu "$idx"
    case "$(read_key)" in
      up) idx=0 ;;
      down) idx=1 ;;
      enter)
        restore_terminal
        trap - EXIT
        echo "$idx"
        return 0
        ;;
      quit)
        restore_terminal
        trap - EXIT
        return 1
        ;;
    esac
  done
}

select_role() {
  local idx=0
  if is_tty; then
    STTY_ORIG="$(stty -g < /dev/tty)"
    stty -echo < /dev/tty
  fi
  trap restore_terminal EXIT
  hide_cursor
  while true; do
    clear_screen
    draw_brand
    draw_facts
    draw_menu "$idx"
    case "$(read_key)" in
      up)
        ((idx > 0)) && idx=$((idx - 1))
        ;;
      down)
        ((idx < ${#PROFILE_IDS[@]} - 1)) && idx=$((idx + 1))
        ;;
      enter)
        restore_terminal
        trap - EXIT
        echo "$idx"
        return 0
        ;;
      quit)
        restore_terminal
        trap - EXIT
        return 1
        ;;
    esac
  done
}

confirm_deploy() {
  local idx="$1"
  if is_tty; then
    STTY_ORIG="$(stty -g < /dev/tty)"
    stty -echo < /dev/tty
  fi
  trap restore_terminal EXIT
  hide_cursor
  while true; do
    clear_screen
    if [[ "$ACTION" == uninstall ]]; then
      draw_confirm_purge "$idx"
    else
      draw_confirm "$idx"
    fi
    case "$(read_key)" in
      enter)
        restore_terminal
        trap - EXIT
        return 0
        ;;
      quit)
        restore_terminal
        trap - EXIT
        return 1
        ;;
    esac
  done
}

# --- main ------------------------------------------------------------------

PROFILE_ARG=""
ASSUME_YES=0
SOURCE_ONLY=0
PRINT_SOURCE=0
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role|--profile)
      PROFILE_ARG="${2:-}"
      [[ -n "$PROFILE_ARG" ]] || { echo "missing ${1} value" >&2; exit 2; }
      shift 2
      ;;
    --source-url)
      APT_BASE_URL="${2:-}"
      [[ -n "$APT_BASE_URL" ]] || { echo "missing --source-url value" >&2; exit 2; }
      shift 2
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --source-only)
      SOURCE_ONLY=1
      shift
      ;;
    --print-source)
      PRINT_SOURCE=1
      shift
      ;;
    --uninstall|--purge)
      ACTION=uninstall
      shift
      ;;
    --list)
      load_profiles
      for i in "${!PROFILE_IDS[@]}"; do
        printf '%s\t%s\t%s\n' "${PROFILE_IDS[$i]}" "${PROFILE_LABELS[$i]}" "${PROFILE_PKG[${PROFILE_IDS[$i]}]}"
      done
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

setup_colors
load_profiles

if [[ "$PRINT_SOURCE" -eq 1 ]]; then
  require_apt_url
  deb_line
  exit 0
fi

if [[ -n "$PROFILE_ARG" ]]; then
  profile_index "$PROFILE_ARG" >/dev/null || {
    echo "unknown role: ${PROFILE_ARG}" >&2
    echo "known roles: gcs robot (aliases: core agent)" >&2
    exit 2
  }
  PROFILE_ARG="$(normalize_role "$PROFILE_ARG")"
fi

if [[ -z "$ACTION" ]]; then
  if [[ "$ASSUME_YES" -eq 1 ]] || ! is_tty; then
    ACTION=install
  else
    case "$(select_action)" in
      0) ACTION=install ;;
      1) ACTION=uninstall ;;
      *)
        printf '%saborted%s\n' "$C_DIM" "$C_RESET"
        exit 1
        ;;
    esac
  fi
fi

SELECTED=""
if [[ "$SOURCE_ONLY" -eq 1 && -z "$PROFILE_ARG" ]]; then
  SELECTED="$(profile_index gcs)"
elif [[ -n "$PROFILE_ARG" ]]; then
  SELECTED="$(profile_index "$PROFILE_ARG")"
elif [[ "$ASSUME_YES" -eq 1 ]] || ! is_tty; then
  echo "not a TTY: pass --role gcs|robot --yes, or --source-only" >&2
  exit 2
else
  SELECTED="$(select_role)" || {
    printf '%saborted%s\n' "$C_DIM" "$C_RESET"
    exit 1
  }
fi

if [[ "$ACTION" != uninstall ]]; then
  require_apt_url
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  if is_tty; then
    confirm_deploy "$SELECTED" || {
      printf '%saborted%s\n' "$C_DIM" "$C_RESET"
      exit 1
    }
  else
    echo "refusing to ${ACTION} without --yes on a non-TTY" >&2
    exit 2
  fi
fi

if [[ "$ACTION" == uninstall ]]; then
  uninstall_profile "${PROFILE_IDS[$SELECTED]}" "$SELECTED"
else
  install_profile "${PROFILE_IDS[$SELECTED]}"
fi
