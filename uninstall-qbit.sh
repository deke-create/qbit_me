#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# uninstall-qbit.sh — Uninstall qbit.me BYOH components from a host
# ==============================================================================
#
# Reverses everything install-qbit.sh installs on a macOS, Ubuntu, or
# Raspberry Pi host:
#
#   1. Stops + disables + removes the qbit-managed systemd units
#      (qbit-hermes-daemon, qbit-hermes-local-api, qbit-hermes-gateway,
#      qbit-hermes-ble) on Linux.
#   2. Removes the installed qbit binaries:
#        qbit-me-local-api, qbit-me-daemon, qbit-me-ble
#        qbit-hermes-agent-install (provisioner hook)
#        qbit-hermes-setup (launcher)
#   3. Removes the setup UI bundle under the share dir.
#   4. Removes BYOH user data (bootstrap state, runtime tree, health history,
#      cloud-bridge state, staged config/secrets, install progress).
#   5. Removes the managed runtime tree (if present) created by the provisioner.
#
# It explicitly DOES NOT:
#   - Touch or remove an existing Hermes installation (~/​.hermes, /usr/local/bin/hermes,
#     /opt/hermes, etc.). Hermes was installed by the user or by the official
#     Hermes installer; qbit only ran alongside it.
#   - Modify host network / Wi-Fi configuration.
#   - Remove the qbit Cloud account or any cloud-side records. Use the
#     dashboard (Account → Decommission) for cloud-side cleanup.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/deke-create/qbit_me/main/uninstall-qbit.sh | bash -s -- [-y]
#
# Or from a repo checkout:
#   device/scripts/uninstall-qbit.sh [-y]
#
# Options:
#   -y, --yes              Do not prompt for confirmation.
#   --keep-user-data       Keep BYOH user data (~/.local/share/qbit-hermes and
#                          the managed runtime tree). Only removes binaries,
#                          the setup UI bundle, and systemd units.
#   --keep-runtime-tree    Keep the managed runtime tree under the BYOH data
#                          root. Implied by --keep-user-data.
#   --install-dir <dir>    Where binaries were installed. Default: /usr/local/bin
#                          (falls back to ~/.local/bin if not writable, same as
#                          the installer).
#   --share-dir <dir>      Where the setup UI bundle was installed.
#                          Default: /usr/local/share/qbit-hermes
#   --data-dir <dir>       BYOH user data root. Default:
#                          ${XDG_DATA_HOME:-$HOME/.local/share}/qbit-hermes
#   --dry-run              Print the actions without changing the system.
#   -h, --help             Show this help.
#
# Environment overrides:
#   QBIT_INSTALL_DIR, QBIT_SHARE_DIR, QBIT_DATA_DIR
# ==============================================================================

PROGRAM_NAME="uninstall-qbit.sh"

# ── Defaults (mirror install-qbit.sh) ────────────────────────────────────────
INSTALL_DIR="${QBIT_INSTALL_DIR:-/usr/local/bin}"
SHARE_DIR="${QBIT_SHARE_DIR:-/usr/local/share/qbit-hermes}"
DATA_DIR="${QBIT_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qbit-hermes}"

keep_user_data=0
keep_runtime_tree=0
dry_run=0
assume_yes=0

# ── Output helpers ────────────────────────────────────────────────────────────
log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

run() {
  if [[ "${dry_run}" -eq 1 ]]; then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Uninstall qbit.me BYOH components from a macOS, Ubuntu, or Raspberry Pi host.
Reverses everything install-qbit.sh installed. Does NOT remove Hermes.

Options:
  -y, --yes              Do not prompt for confirmation.
  --keep-user-data       Keep BYOH user data (runtime tree, state, drafts).
                         Only removes binaries, the setup UI bundle, and
                         systemd units.
  --keep-runtime-tree    Keep the managed runtime tree under the BYOH data root.
                         Implied by --keep-user-data.
  --install-dir <dir>    Where binaries were installed. Default: ${INSTALL_DIR}
  --share-dir <dir>      Where the setup UI bundle was installed.
                         Default: ${SHARE_DIR}
  --data-dir <dir>       BYOH user data root. Default: ${DATA_DIR}
  --dry-run              Print the actions without changing the system.
  -h, --help             Show this help.

Environment overrides:
  QBIT_INSTALL_DIR, QBIT_SHARE_DIR, QBIT_DATA_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) assume_yes=1 ;;
    --keep-user-data) keep_user_data=1 ;;
    --keep-runtime-tree) keep_runtime_tree=1 ;;
    --install-dir) shift; [[ $# -gt 0 ]] || die "Missing value for --install-dir"; INSTALL_DIR="$1" ;;
    --share-dir) shift; [[ $# -gt 0 ]] || die "Missing value for --share-dir"; SHARE_DIR="$1" ;;
    --data-dir) shift; [[ $# -gt 0 ]] || die "Missing value for --data-dir"; DATA_DIR="$1" ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "${keep_user_data}" -eq 1 ]]; then
  keep_runtime_tree=1
fi

# ── Detect OS ──────────────────────────────────────────────────────────────────
detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "${uname_s}" in
    Darwin) OS_NAME="macos" ;;
    Linux)  OS_NAME="linux" ;;
    *) die "Unsupported operating system: ${uname_s} (supported: macOS, Linux)" ;;
  esac
  log "Operating system : ${OS_NAME}"
}

# ── Privilege helpers ──────────────────────────────────────────────────────────
SUDO=""
resolve_sudo() {
  # We need root to remove from /usr/local/bin and /etc/systemd/system. On macOS
  # there are no systemd units; we just need root for the binary/share removals.
  if [[ -w "${INSTALL_DIR}" ]] && [[ -w "$(dirname "${SHARE_DIR}")" ]] 2>/dev/null; then
    SUDO=""
    return
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    log "Using sudo for system-level removals."
  else
    warn "sudo unavailable and ${INSTALL_DIR} is not writable; system-level removals will fail."
  fi
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm() {
  [[ "${assume_yes}" -eq 1 ]] && return 0
  [[ "${dry_run}" -eq 1 ]] && return 0
  printf 'This will remove qbit.me BYOH components from this host.\n'
  printf 'Hermes itself will NOT be removed.\n\n'
  printf 'Proceed with uninstall? [y/N] '
  local reply
  read -r reply || true
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) die "Aborted by user." ;;
  esac
}

# ── Stop + remove systemd units (Linux only) ──────────────────────────────────
remove_systemd_units() {
  [[ "${OS_NAME}" != "linux" ]] && return 0

  local svc
  local units=(
    qbit-hermes-daemon.service
    qbit-hermes-local-api.service
    qbit-hermes-gateway.service
    qbit-hermes-ble.service
  )

  for svc in "${units[@]}"; do
    if systemctl list-unit-files "${svc}" >/dev/null 2>&1 \
       || [[ -f "/etc/systemd/system/${svc}" ]]; then
      log "Stopping + disabling ${svc}…"
      run ${SUDO} systemctl disable --now "${svc}" 2>/dev/null || true
      run ${SUDO} rm -f "/etc/systemd/system/${svc}"
    fi
  done

  run ${SUDO} systemctl daemon-reload
  ok "Systemd units removed."
}

# ── Remove binaries ────────────────────────────────────────────────────────────
remove_binaries() {
  local bins=(
    qbit-me-local-api
    qbit-me-daemon
    qbit-me-ble
    qbit-hermes-agent-install
    qbit-hermes-setup
  )
  local name path removed=0
  for name in "${bins[@]}"; do
    path="${INSTALL_DIR}/${name}"
    if [[ -f "${path}" ]] || [[ -L "${path}" ]]; then
      log "Removing ${path}"
      run ${SUDO} rm -f "${path}"
      removed=$((removed+1))
    fi
  done
  if [[ ${removed} -gt 0 ]]; then
    ok "Removed ${removed} binary/binaries from ${INSTALL_DIR}."
  else
    ok "No qbit binaries found in ${INSTALL_DIR}."
  fi
}

# ── Remove setup UI bundle ─────────────────────────────────────────────────────
remove_setup_ui() {
  if [[ -d "${SHARE_DIR}" ]]; then
    log "Removing setup UI bundle ${SHARE_DIR}"
    run ${SUDO} rm -rf "${SHARE_DIR}"
    ok "Setup UI bundle removed."
  else
    ok "No setup UI bundle found at ${SHARE_DIR}."
  fi
}

# ── Remove BYOH user data ─────────────────────────────────────────────────────
remove_user_data() {
  if [[ "${keep_user_data}" -eq 1 ]]; then
    log "Keeping BYOH user data (--keep-user-data): ${DATA_DIR}"
    return 0
  fi

  if [[ -d "${DATA_DIR}" ]]; then
    log "Removing BYOH user data ${DATA_DIR}"
    # The provisioner and daemon run as root and create root-owned files
    # (state, secrets, managed runtime tree) inside the user's data dir.
    # Use sudo to ensure root-owned files are removed cleanly.
    if [[ -n "${SUDO}" ]]; then
      run ${SUDO} rm -rf "${DATA_DIR}"
    else
      run rm -rf "${DATA_DIR}"
    fi
    ok "BYOH user data removed."
  else
    ok "No BYOH user data found at ${DATA_DIR}."
  fi
}

# ── Remove managed runtime tree ───────────────────────────────────────────────
remove_runtime_tree() {
  if [[ "${keep_runtime_tree}" -eq 1 ]]; then
    log "Keeping managed runtime tree (--keep-runtime-tree / --keep-user-data)."
    return 0
  fi

  # The provisioner creates the managed runtime tree under the data dir at
  # <data_dir>/setup/runtime/hermes (BYOH) or the legacy duplicated
  # <data_dir>/setup/setup/runtime/hermes path. The data-dir removal above
  # already handles the common case; this is a belt-and-suspenders cleanup
  # for hosts where the runtime tree was placed outside the data dir.
  local runtime_roots=(
    "${DATA_DIR}/setup/runtime/hermes"
    "${DATA_DIR}/setup/setup/runtime/hermes"
  )
  local root removed_any=0
  for root in "${runtime_roots[@]}"; do
    if [[ -d "${root}" ]]; then
      log "Removing managed runtime tree ${root}"
      run rm -rf "${root}"
      removed_any=1
    fi
  done
  if [[ ${removed_any} -eq 1 ]]; then
    ok "Managed runtime tree removed."
  fi
}

# ── Sanity check: Hermes untouched ────────────────────────────────────────────
verify_hermes_intact() {
  local hermes_loc=""
  if [[ -n "${HERMES_HOME:-}" ]] && [[ -d "${HERMES_HOME}" ]]; then
    hermes_loc="${HERMES_HOME}"
  elif command -v hermes >/dev/null 2>&1; then
    hermes_loc="$(command -v hermes)"
  elif [[ -d "${HOME}/.hermes" ]]; then
    hermes_loc="${HOME}/.hermes"
  fi
  if [[ -n "${hermes_loc}" ]]; then
    ok "Hermes still present at ${hermes_loc} (untouched)."
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  cat <<EOF

✓ qbit.me BYOH uninstall complete.

Removed:
  - Binaries from ${INSTALL_DIR}
  - Setup UI bundle under ${SHARE_DIR}
  - Systemd units (Linux)
EOF
  if [[ "${keep_user_data}" -eq 1 ]]; then
    printf 'Kept (per --keep-user-data):\n  - BYOH user data at %s\n' "${DATA_DIR}"
  else
    printf 'Removed:\n  - BYOH user data at %s\n' "${DATA_DIR}"
  fi
  cat <<EOF

Hermes itself was NOT removed. To uninstall Hermes, use the official
Hermes uninstall path or remove its install directory manually.

Notes:
  - Cloud-side records (device registration, sessions, telemetry) are NOT
    removed by this script. Use the qbit Cloud dashboard to decommission the
    device if you want full cloud cleanup.
  - No host network / Wi-Fi configuration was changed.
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  printf '== qbit.me BYOH uninstaller ==\n\n'

  detect_os
  resolve_sudo
  echo

  printf 'Plan:\n'
  printf '  - Install dir : %s\n' "${INSTALL_DIR}"
  printf '  - Share dir   : %s\n' "${SHARE_DIR}"
  printf '  - Data dir    : %s\n' "${DATA_DIR}"
  if [[ "${keep_user_data}" -eq 1 ]]; then
    printf '  - User data   : keep (--keep-user-data)\n'
  else
    printf '  - User data   : remove\n'
  fi
  if [[ "${keep_runtime_tree}" -eq 1 ]]; then
    printf '  - Runtime tree: keep\n'
  else
    printf '  - Runtime tree: remove\n'
  fi
  printf '  - Dry run     : %s\n' "$([[ ${dry_run} -eq 1 ]] && echo yes || echo no)"
  echo

  confirm
  echo

  remove_systemd_units
  remove_binaries
  remove_setup_ui
  remove_user_data
  remove_runtime_tree

  echo
  verify_hermes_intact
  print_summary
}

main "$@"