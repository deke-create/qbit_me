#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# install-qbit.sh — BYOH (Bring Your Own Hardware) installer for qbit.me
# ==============================================================================
#
# Prepares a macOS, Ubuntu, or Raspberry Pi host with the qbit.me device-side
# components so a tech-savvy operator can finish setup in a browser, without the
# mobile app + BLE onboarding path.
#
# What it does:
#   1. Detects operating system and CPU architecture.
#   2. Detects whether Hermes is already installed (HERMES_HOME,
#      HERMES_INSTALL_DIR, the `hermes` CLI on PATH, and common install paths).
#   3. Installs Hermes first only when it is not already present.
#   4. Installs the qbit.me binaries around the (existing or freshly installed)
#      Hermes install:
#        - qbit-me-local-api   (required)  serves the local web setup UI + API and
#                                     embeds the qbit-me-provisioner install/runtime
#                                     engine (a linked library, not a separate
#                                     binary)
#        - qbit-me-daemon      (required)  runtime health + cloud bridge
#        - qbit-me-ble         (optional)  only with --with-ble
#   5. Installs the browser setup UI bundle and a `qbit-hermes-setup` launcher
#      that serves it over http://127.0.0.1:8081 via qbit-me-local-api.
#
# It explicitly DOES NOT:
#   - Touch or interfere with the mobile app + BLE onboarding path.
#   - Overwrite or modify an existing Hermes installation.
#   - Install a desktop icon or auto-launch/boot service (browser-access only).
#   - Configure host network / Wi-Fi.
#
# Binaries can be obtained two ways:
#   - Download: architecture-specific artifacts from $QBIT_RELEASE_BASE_URL.
#   - Source:   built locally with `cargo` when run from a repo checkout
#               (pass --source). The setup UI is built with `npm` in that mode.
# ==============================================================================

PROGRAM_NAME="install-qbit.sh"

# ── Defaults (override via flags or environment) ──────────────────────────────
QBIT_RELEASE_BASE_URL="${QBIT_RELEASE_BASE_URL:-https://dev-downloads.qbit.me/byoh/latest}"
QBIT_HERMES_INSTALL_URL="${QBIT_HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
INSTALL_DIR="${QBIT_INSTALL_DIR:-/usr/local/bin}"
SHARE_DIR="${QBIT_SHARE_DIR:-/usr/local/share/qbit-hermes}"
SETUP_UI_DIR="${QBIT_SETUP_UI_DIR:-}"
SETUP_BIND_ADDRESS="${QBIT_HERMES_LOCAL_API_BIND:-127.0.0.1:8081}"

use_source=0
with_ble=0
skip_hermes=0
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

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options]

BYOH installer for qbit.me. Prepares a macOS, Ubuntu, or Raspberry Pi host and
then hands off to a local browser-based setup experience.

Options:
  --source                 Build binaries (cargo) and setup UI (npm) from a repo
                           checkout instead of downloading release artifacts.
  --release-base-url <url> Base URL for architecture-specific binary downloads.
                           Default: ${QBIT_RELEASE_BASE_URL}
  --install-dir <dir>      Where to install binaries. Default: ${INSTALL_DIR}
                           Falls back to ~/.local/bin if not writable.
  --setup-ui-dir <dir>     Where to install the browser setup UI bundle.
                           Default: <share>/setup-ui
  --with-ble               Also install the optional qbit-me-ble binary.
  --skip-hermes            Do not install Hermes even if it is missing.
  --hermes-install-url <u> Override the official Hermes installer URL.
  -y, --yes                Do not prompt for confirmation.
  --dry-run                Print the actions without changing the system.
  -h, --help               Show this help.

Environment overrides:
  QBIT_RELEASE_BASE_URL, QBIT_HERMES_INSTALL_URL, QBIT_INSTALL_DIR,
  QBIT_SHARE_DIR, QBIT_SETUP_UI_DIR, QBIT_HERMES_LOCAL_API_BIND
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) use_source=1 ;;
    --release-base-url) shift; [[ $# -gt 0 ]] || die "Missing value for --release-base-url"; QBIT_RELEASE_BASE_URL="$1" ;;
    --install-dir) shift; [[ $# -gt 0 ]] || die "Missing value for --install-dir"; INSTALL_DIR="$1" ;;
    --setup-ui-dir) shift; [[ $# -gt 0 ]] || die "Missing value for --setup-ui-dir"; SETUP_UI_DIR="$1" ;;
    --with-ble) with_ble=1 ;;
    --skip-hermes) skip_hermes=1 ;;
    --hermes-install-url) shift; [[ $# -gt 0 ]] || die "Missing value for --hermes-install-url"; QBIT_HERMES_INSTALL_URL="$1" ;;
    -y|--yes) assume_yes=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

# ── 1. Detect OS and architecture ─────────────────────────────────────────────
detect_platform() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "${uname_s}" in
    Darwin) OS_NAME="macos" ;;
    Linux)  OS_NAME="linux" ;;
    *) die "Unsupported operating system: ${uname_s} (supported: macOS, Linux)" ;;
  esac

  case "${uname_m}" in
    x86_64|amd64)        ARCH_NAME="x86_64" ;;
    arm64|aarch64)       ARCH_NAME="aarch64" ;;
    armv7l|armv7|armhf)  ARCH_NAME="armv7" ;;
    *) die "Unsupported CPU architecture: ${uname_m} (supported: x86_64, aarch64, armv7)" ;;
  esac

  IS_RASPBERRY_PI=0
  if [[ "${OS_NAME}" == "linux" ]] && [[ -r /proc/device-tree/model ]] \
     && grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
    IS_RASPBERRY_PI=1
  fi

  log "Operating system : ${OS_NAME} (${uname_s})"
  log "CPU architecture : ${ARCH_NAME} (${uname_m})"
  if [[ "${IS_RASPBERRY_PI}" -eq 1 ]]; then
    log "Hardware         : Raspberry Pi"
  fi
}

# ── 2. Detect Hermes ──────────────────────────────────────────────────────────
detect_hermes() {
  HERMES_FOUND=0
  HERMES_DETAIL=""

  if [[ -n "${HERMES_HOME:-}" ]] && [[ -d "${HERMES_HOME}" ]]; then
    HERMES_FOUND=1; HERMES_DETAIL="HERMES_HOME=${HERMES_HOME}"; return
  fi
  if [[ -n "${HERMES_INSTALL_DIR:-}" ]] && [[ -d "${HERMES_INSTALL_DIR}" ]]; then
    HERMES_FOUND=1; HERMES_DETAIL="HERMES_INSTALL_DIR=${HERMES_INSTALL_DIR}"; return
  fi
  if command -v hermes >/dev/null 2>&1; then
    HERMES_FOUND=1; HERMES_DETAIL="hermes on PATH ($(command -v hermes))"; return
  fi
  local candidate
  for candidate in \
      "${HOME}/.hermes" \
      "${HOME}/.local/share/hermes" \
      "${HOME}/.local/bin/hermes" \
      "/usr/local/bin/hermes" \
      "/opt/hermes"; do
    if [[ -e "${candidate}" ]]; then
      HERMES_FOUND=1; HERMES_DETAIL="found at ${candidate}"; return
    fi
  done
}

install_hermes() {
  log "Installing Hermes via official installer…"
  log "  ${QBIT_HERMES_INSTALL_URL}"
  if ! command -v curl >/dev/null 2>&1; then
    die "curl is required to install Hermes. Install curl and re-run, or install Hermes first."
  fi
  # --skip-setup --skip-browser keeps the BYOH flow non-interactive; the qbit.me
  # browser setup completes provider/gateway configuration afterwards.
  if [[ "${dry_run}" -eq 1 ]]; then
    printf '   [dry-run] curl -fsSL %s | bash -s -- --skip-setup --skip-browser\n' "${QBIT_HERMES_INSTALL_URL}"
  else
    curl -fsSL "${QBIT_HERMES_INSTALL_URL}" | bash -s -- --skip-setup --skip-browser
  fi
  ok "Hermes installed."
}

# ── Privileged file install helper ────────────────────────────────────────────
SUDO=""
resolve_install_dir() {
  # Prefer the requested install dir; fall back to ~/.local/bin when we cannot
  # write to it even with sudo.
  if [[ -d "${INSTALL_DIR}" ]] && [[ -w "${INSTALL_DIR}" ]]; then
    SUDO=""
    return
  fi
  # If the directory does not exist yet but its nearest existing ancestor is
  # writable, we can create it without escalating privileges.
  if [[ ! -e "${INSTALL_DIR}" ]]; then
    local ancestor="${INSTALL_DIR}"
    while [[ ! -e "${ancestor}" ]]; do
      ancestor="$(dirname "${ancestor}")"
    done
    if [[ -w "${ancestor}" ]]; then
      SUDO=""
      run mkdir -p "${INSTALL_DIR}"
      return
    fi
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    run mkdir -p "${INSTALL_DIR}"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    log "Using sudo to install into ${INSTALL_DIR}."
    run ${SUDO} mkdir -p "${INSTALL_DIR}"
    return
  fi
  warn "Cannot write to ${INSTALL_DIR} and sudo is unavailable."
  INSTALL_DIR="${HOME}/.local/bin"
  SHARE_DIR="${HOME}/.local/share/qbit-hermes"
  SUDO=""
  log "Falling back to user install dir: ${INSTALL_DIR}"
  run mkdir -p "${INSTALL_DIR}"
}

install_binary_file() {
  # install_binary_file <src> <dest-name>
  local src="$1" name="$2" dest="${INSTALL_DIR}/$2"
  if [[ "${dry_run}" -ne 1 ]] && [[ ! -f "${src}" ]]; then
    die "Expected binary not found: ${src}"
  fi
  run ${SUDO} install -m 0755 "${src}" "${dest}"
  ok "Installed ${name} -> ${dest}"
}

# ── Download helpers ──────────────────────────────────────────────────────────
download_to() {
  # download_to <url> <dest>
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    run curl -fSL --proto '=https' --tlsv1.2 -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    run wget -qO "${dest}" "${url}"
  else
    die "Neither curl nor wget is available to download ${url}"
  fi
}

# ── Resolve binary set ────────────────────────────────────────────────────────
# qbit-me-provisioner is the install/runtime engine, but it is a library crate that
# is statically linked into qbit-me-local-api rather than a standalone binary, so the
# installable binaries are qbit-me-local-api (which embeds the provisioner) and
# qbit-me-daemon, plus the optional qbit-me-ble.
required_binaries=(qbit-me-local-api qbit-me-daemon)
optional_binaries=()
if [[ "${with_ble}" -eq 1 ]]; then
  optional_binaries+=(qbit-me-ble)
fi

WORK_DIR=""
cleanup() { [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

REPO_ROOT=""
resolve_repo_root() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"
}

# ── Source build path ─────────────────────────────────────────────────────────
build_from_source() {
  resolve_repo_root
  local device_dir="${REPO_ROOT}/device"
  [[ -f "${device_dir}/Cargo.toml" ]] || die "--source requires running from a repo checkout (device/Cargo.toml not found)."
  command -v cargo >/dev/null 2>&1 || die "--source requires cargo (Rust toolchain) on PATH."

  local crate
  for crate in "${required_binaries[@]}" "${optional_binaries[@]}"; do
    log "Building ${crate} (release)…"
    run sh -c "cd '${device_dir}' && cargo build --release -p '${crate}'"
  done

  SOURCE_BIN_DIR="${device_dir}/target/release"

  # Build the setup UI bundle.
  local ui_src="${device_dir}/setup-ui"
  if [[ -d "${ui_src}" ]]; then
    command -v npm >/dev/null 2>&1 || die "--source requires npm to build the setup UI."
    log "Building setup UI bundle…"
    run sh -c "cd '${ui_src}' && npm install && npm run build -- --configuration production"
    SOURCE_UI_DIR="${ui_src}/dist/setup-ui/browser"
  else
    warn "setup-ui source not found at ${ui_src}; skipping UI build."
    SOURCE_UI_DIR=""
  fi
}

# ── Download build path ───────────────────────────────────────────────────────
download_artifacts() {
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qbit-install.XXXXXX")"
  local base="${QBIT_RELEASE_BASE_URL%/}/${OS_NAME}-${ARCH_NAME}"
  local name
  for name in "${required_binaries[@]}" "${optional_binaries[@]}"; do
    log "Downloading ${name} (${OS_NAME}-${ARCH_NAME})…"
    download_to "${base}/${name}" "${WORK_DIR}/${name}"
    run chmod 0755 "${WORK_DIR}/${name}"
  done
  SOURCE_BIN_DIR="${WORK_DIR}"

  # Setup UI bundle tarball.
  log "Downloading setup UI bundle…"
  download_to "${QBIT_RELEASE_BASE_URL%/}/setup-ui.tar.gz" "${WORK_DIR}/setup-ui.tar.gz"
  run mkdir -p "${WORK_DIR}/setup-ui"
  run tar -xzf "${WORK_DIR}/setup-ui.tar.gz" -C "${WORK_DIR}/setup-ui"
  # Tarball layouts vary: some ship index.html at the top, others nest it under
  # setup-ui/browser/. Resolve to the directory that actually contains
  # index.html so the launcher's --setup-ui-dir points at a usable bundle.
  local candidate
  SOURCE_UI_DIR="${WORK_DIR}/setup-ui"
  if [[ ! -f "${SOURCE_UI_DIR}/index.html" ]]; then
    for candidate in \
        "${SOURCE_UI_DIR}/setup-ui/browser" \
        "${SOURCE_UI_DIR}/browser" \
        "${SOURCE_UI_DIR}/setup-ui"; do
      if [[ -f "${candidate}/index.html" ]]; then
        SOURCE_UI_DIR="${candidate}"
        break
      fi
    done
  fi
  if [[ ! -f "${SOURCE_UI_DIR}/index.html" ]]; then
    warn "Setup UI bundle did not contain index.html at a recognized path; browser flow may not serve."
  fi
}

# ── Install setup UI bundle + launcher ────────────────────────────────────────
install_setup_ui() {
  [[ -n "${SETUP_UI_DIR}" ]] || SETUP_UI_DIR="${SHARE_DIR}/setup-ui"
  if [[ -z "${SOURCE_UI_DIR}" ]] || [[ ! -d "${SOURCE_UI_DIR}" ]]; then
    warn "No setup UI bundle available; the browser flow will not be served locally."
    SETUP_UI_INSTALLED=0
    return
  fi
  log "Installing setup UI to ${SETUP_UI_DIR}…"
  run ${SUDO} mkdir -p "${SETUP_UI_DIR}"
  if command -v rsync >/dev/null 2>&1; then
    run ${SUDO} rsync -a --delete "${SOURCE_UI_DIR}/" "${SETUP_UI_DIR}/"
  else
    run ${SUDO} cp -R "${SOURCE_UI_DIR}/." "${SETUP_UI_DIR}/"
  fi
  SETUP_UI_INSTALLED=1
  ok "Setup UI installed."
}

install_launcher() {
  # A small launcher the operator runs explicitly. No auto-launch / boot service
  # is installed, per the BYOH constraints.
  local launcher="${INSTALL_DIR}/qbit-hermes-setup"
  local data_dir='${XDG_DATA_HOME:-$HOME/.local/share}/qbit-hermes/setup'
  local ui_dir_literal="${SETUP_UI_DIR}"

  log "Installing launcher ${launcher}…"
  local tmp_launcher="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-setup"
  WORK_DIR="${WORK_DIR:-$(dirname "${tmp_launcher}")}"
  cat > "${tmp_launcher}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# qbit.me BYOH local setup server launcher.
# Serves the browser setup UI + API on http://${SETUP_BIND_ADDRESS}/

BIND_ADDRESS="\${QBIT_HERMES_LOCAL_API_BIND:-${SETUP_BIND_ADDRESS}}"
SETUP_UI_DIR="\${QBIT_HERMES_SETUP_UI_DIR:-${ui_dir_literal}}"
DATA_DIR="${data_dir}"
mkdir -p "\${DATA_DIR}/setup"

export QBIT_HERMES_SETUP_UI_DIR="\${SETUP_UI_DIR}"
export QBIT_HERMES_LOCAL_API_BIND="\${BIND_ADDRESS}"

# Point the Phase 3 provisioner at user-writable paths so the BYOH path (which
# runs as the operator user, not root) can write the managed hermes CLI wrapper
# and find the install hook without requiring root privileges.
export QBIT_HERMES_CLI_BIN_PATH="\${HOME}/.local/bin/hermes"
export QBIT_HERMES_INSTALL_HOOK_PATH="${INSTALL_DIR}/qbit-hermes-agent-install"

echo "Starting qbit.me local setup server on http://\${BIND_ADDRESS}/"
echo "Open that URL in your browser to complete setup. Press Ctrl+C to stop."

exec "${INSTALL_DIR}/qbit-me-local-api" \\
  --bind "\${BIND_ADDRESS}" \\
  --setup-ui-dir "\${SETUP_UI_DIR}" \\
  --state-path "\${DATA_DIR}/bootstrap-state.json" \\
  --draft-path "\${DATA_DIR}/setup/staged-config.json" \\
  --secret-path "\${DATA_DIR}/setup/staged-secrets.json" \\
  --progress-path "\${DATA_DIR}/setup/install-progress.json"
EOF
  run chmod 0755 "${tmp_launcher}"
  run ${SUDO} install -m 0755 "${tmp_launcher}" "${launcher}"
  ok "Launcher installed -> ${launcher}"
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm() {
  [[ "${assume_yes}" -eq 1 ]] && return 0
  [[ "${dry_run}" -eq 1 ]] && return 0
  printf 'Proceed with installation? [y/N] '
  local reply
  read -r reply || true
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) die "Aborted by user." ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  printf '== qbit.me BYOH installer ==\n\n'

  detect_platform
  echo

  detect_hermes
  if [[ "${HERMES_FOUND}" -eq 1 ]]; then
    ok "Hermes already installed (${HERMES_DETAIL}); installing qbit.me around it."
  else
    if [[ "${skip_hermes}" -eq 1 ]]; then
      warn "Hermes not detected and --skip-hermes was set; the browser setup will block until Hermes is available."
    else
      log "Hermes not detected; it will be installed first."
    fi
  fi
  echo

  printf 'Plan:\n'
  printf '  - Install dir : %s\n' "${INSTALL_DIR}"
  printf '  - Setup UI    : %s\n' "${SETUP_UI_DIR:-${SHARE_DIR}/setup-ui}"
  printf '  - Binaries    : %s%s\n' "${required_binaries[*]}" \
    "$([[ ${#optional_binaries[@]} -gt 0 ]] && printf ' %s' "${optional_binaries[*]}")"
  printf '  - Source mode : %s\n' "$([[ ${use_source} -eq 1 ]] && echo yes || echo 'no (download)')"
  echo
  confirm
  echo

  if [[ "${HERMES_FOUND}" -eq 0 ]] && [[ "${skip_hermes}" -eq 0 ]]; then
    install_hermes
    echo
  fi

  resolve_install_dir

  if [[ "${use_source}" -eq 1 ]]; then
    build_from_source
  else
    download_artifacts
  fi
  echo

  local name
  for name in "${required_binaries[@]}" "${optional_binaries[@]}"; do
    install_binary_file "${SOURCE_BIN_DIR}/${name}" "${name}"
  done
  echo

  install_setup_ui
  install_launcher
  install_provisioner_hook
  echo

  print_post_install
}

# ── Install the default Phase 3 Hermes install hook ───────────────────────────
# The qbit-me-provisioner needs a Hermes install command to invoke during the
# "Install Hermes core" step. On the normal Pi appliance path this is pre-wired
# via systemd env files. On the BYOH path we install a small hook script that
# runs the official Hermes installer with --skip-setup --skip-browser so it
# installs into the provisioner's managed runtime tree (the provisioner sets
# HOME, HERMES_HOME, and HERMES_INSTALL_DIR env vars before invoking the hook).
install_provisioner_hook() {
  local hook_path="${INSTALL_DIR}/qbit-hermes-agent-install"
  local tmp_hook="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-agent-install"
  cat > "${tmp_hook}" <<'HOOK_EOF'
#!/usr/bin/env bash
# qbit-hermes-agent-install — default Phase 3 Hermes install hook for BYOH
#
# The qbit-me-provisioner sets HOME, HERMES_HOME, HERMES_INSTALL_DIR, and
# QBIT_HERMES_* env vars pointing at the managed runtime tree before invoking
# this hook. We run the official Hermes installer with --skip-setup --skip-browser
# so it installs into the managed tree without launching interactive setup.
set -euo pipefail

INSTALL_URL="${QBIT_HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required to install Hermes into the managed runtime tree" >&2
  exit 1
fi

curl -fsSL "${INSTALL_URL}" | bash -s -- --skip-setup --skip-browser
HOOK_EOF
  run chmod 0755 "${tmp_hook}"
  run ${SUDO} install -m 0755 "${tmp_hook}" "${hook_path}"
  ok "Provisioner install hook -> ${hook_path}"
}

print_post_install() {
  cat <<EOF
✓ qbit.me BYOH installation complete.

Next steps:
  1. Start the local setup server (it does not auto-start):

       qbit-hermes-setup

     (full path: ${INSTALL_DIR}/qbit-hermes-setup)

  2. Open the browser setup UI:

       http://${SETUP_BIND_ADDRESS}/

  3. Complete the guided setup (device name, timezone, providers, gateways)
     and watch install progress in the browser.

Installed binaries (in ${INSTALL_DIR}):
  - qbit-me-local-api (embeds the qbit-me-provisioner install/runtime engine), qbit-me-daemon$([[ ${with_ble} -eq 1 ]] && printf ', qbit-me-ble')

Notes:
  - The mobile app + BLE onboarding path is unaffected by this installer.
  - No host network / Wi-Fi configuration was changed.
  - No desktop icon or boot service was installed; start setup with the
    'qbit-hermes-setup' command above whenever you need it.
EOF
}

main "$@"
