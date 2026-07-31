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

# ── Snap-curl detection ───────────────────────────────────────────────────────
# On some Ubuntu variants (notably Ubuntu MATE), `curl` is shipped as a snap.
# Snap-curl runs in its own mount namespace and CANNOT open files written by
# the host shell into /tmp (or other host-only paths), so `curl -o /tmp/x`
# fails with "Failed to open the file ...: No such file or directory" even
# though the path exists from the shell's perspective.
#
# When snap-curl is detected, we prefer wget for file downloads (and for the
# piped Hermes installer) and only fall back to curl when wget is unavailable.
# Pipe-to-bash with snap-curl works fine (stdout is not a sandboxed file), but
# file writes do not, so this is the safer default.
is_snap_curl() {
  command -v curl >/dev/null 2>&1 || return 1
  local resolved
  resolved="$(readlink -f "$(command -v curl)" 2>/dev/null || true)"
  [[ "${resolved}" == /snap/* ]]
}

PREFER_WGET=0
if is_snap_curl; then
  PREFER_WGET=1
  warn "snap-curl detected; preferring wget for file downloads (snap-curl cannot write to host /tmp)."
fi

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
    *) die "Unsupported CPU architecture: ${uname_m} (supported: x86_64, aarch64)" ;;
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

  # A real Hermes install requires a working `hermes` binary. We check env vars
  # first, then PATH, then common install locations — but always verify the
  # binary actually exists and is executable, not just that a directory exists.
  # (An empty ~/.hermes/bin/ directory from a failed prior install must NOT
  # count as "Hermes installed".)

  if [[ -n "${HERMES_HOME:-}" ]] && [[ -x "${HERMES_HOME}/bin/hermes" ]]; then
    HERMES_FOUND=1; HERMES_DETAIL="HERMES_HOME=${HERMES_HOME}"; return
  fi
  if [[ -n "${HERMES_INSTALL_DIR:-}" ]] && [[ -x "${HERMES_INSTALL_DIR}/bin/hermes" ]]; then
    HERMES_FOUND=1; HERMES_DETAIL="HERMES_INSTALL_DIR=${HERMES_INSTALL_DIR}"; return
  fi
  if command -v hermes >/dev/null 2>&1; then
    local hermes_bin
    hermes_bin="$(command -v hermes)"
    if [[ -x "${hermes_bin}" ]]; then
      HERMES_FOUND=1; HERMES_DETAIL="hermes on PATH (${hermes_bin})"; return
    fi
  fi
  local candidate
  for candidate in \
      "${HOME}/.hermes/bin/hermes" \
      "${HOME}/.local/bin/hermes" \
      "${HOME}/.local/share/hermes/bin/hermes" \
      "/usr/local/bin/hermes" \
      "/usr/bin/hermes" \
      "/opt/hermes/bin/hermes"; do
    if [[ -x "${candidate}" ]]; then
      HERMES_FOUND=1; HERMES_DETAIL="found at ${candidate}"; return
    fi
  done
}

install_hermes() {
  log "Installing Hermes via official installer…"
  log "  ${QBIT_HERMES_INSTALL_URL}"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "curl or wget is required to install Hermes. Install one and re-run, or install Hermes first."
  fi
  # The Hermes installer uses `uv` which caches Python builds under ~/.cache/uv.
  # A previous failed install or provisioner run (as root) may have left
  # root-owned files there, causing "Permission denied" when the current user
  # tries to install Python. Fix ownership before running the installer.
  local chown_sudo=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      chown_sudo="sudo"
    fi
  fi
  # Fix ownership of all paths the Hermes installer writes to. A prior failed
  # provisioner run (as root) may have left root-owned files/dirs that block
  # the user from writing symlinks or cache files.
  for path in "${HOME}/.cache/uv" "${HOME}/.hermes" "${HOME}/.local/bin"; do
    if [[ -d "${path}" ]]; then
      run ${chown_sudo} chown -R "$(id -u):$(id -g)" "${path}" 2>/dev/null || true
    fi
  done
  # --skip-setup --skip-browser keeps the BYOH flow non-interactive; the qbit.me
  # browser setup completes provider/gateway configuration afterwards.
  if [[ "${dry_run}" -eq 1 ]]; then
    printf '   [dry-run] installer pipe -> bash -s -- --skip-setup --skip-browser\n'
  elif [[ "${PREFER_WGET}" -eq 1 ]] && command -v wget >/dev/null 2>&1; then
    wget -qO - "${QBIT_HERMES_INSTALL_URL}" | bash -s -- --skip-setup --skip-browser
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
  # When snap-curl is present, prefer wget first — snap-curl cannot write to
  # host /tmp paths (it lives in its own mount namespace). Only fall back to
  # curl when wget is unavailable.
  if [[ "${PREFER_WGET}" -eq 1 ]] && command -v wget >/dev/null 2>&1; then
    run wget -qO "${dest}" "${url}"
  elif command -v curl >/dev/null 2>&1; then
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

# ── Install the Phase 3 provisioner hook ─────────────────────────────────────
# The provisioner needs an executable hook that runs the official Hermes
# installer into the managed runtime tree. On the normal Pi appliance path this
# is pre-configured; on BYOH we install a default hook that pipes the official
# installer through bash with --skip-setup --skip-browser.
install_provisioner_hook() {
  local hook="${INSTALL_DIR}/qbit-hermes-agent-install"
  log "Installing provisioner hook ${hook}…"
  local tmp_hook="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-agent-install"
  WORK_DIR="${WORK_DIR:-$(dirname "${tmp_hook}")}"
  cat > "${tmp_hook}" <<'HOOKEOF'
#!/usr/bin/env bash
# qbit-hermes-agent-install — Phase 3 install hook for the BYOH path.
#
# The provisioner sets HOME, HERMES_HOME, HERMES_INSTALL_DIR, and QBIT_HERMES_*
# env vars pointing at the managed runtime tree before invoking this hook.
#
# If Hermes is already installed system-wide, we create symlinks in the managed
# runtime tree so the provisioner can find it. Otherwise we run the official
# Hermes installer into the managed tree.
set -euo pipefail

echo "qbit-hermes-agent-install: starting"
echo "  QBIT_HERMES_RUNTIME_ROOT=${QBIT_HERMES_RUNTIME_ROOT:-<unset>}"
echo "  HERMES_HOME=${HERMES_HOME:-<unset>}"
echo "  HERMES_INSTALL_DIR=${HERMES_INSTALL_DIR:-<unset>}"
echo "  HOME=${HOME:-<unset>}"

# ── Resolve the system Hermes binary ──────────────────────────────────────
# Prefer the real venv entrypoint first. Never treat a qbit managed wrapper
# (under qbit-hermes paths, or a shell script that re-execs another hermes
# path) as the system binary — that creates an exec loop with the managed
# runtime wrapper and the old BYOH QBIT_HERMES_CLI_BIN_PATH=~/.local/bin/hermes
# overwrite ("Argument list too long").
SYSTEM_HERMES=""
ORIG_HOME="${QBIT_HERMES_ORIG_HOME:-${HOME}}"
RUNTIME_ROOT="${QBIT_HERMES_RUNTIME_ROOT:-}"

is_usable_hermes_binary() {
  local candidate="$1"
  [[ -n "$candidate" && -x "$candidate" ]] || return 1
  # Never select binaries inside the managed runtime tree as the "system" source.
  if [[ -n "$RUNTIME_ROOT" && "$candidate" == "$RUNTIME_ROOT"* ]]; then
    return 1
  fi
  case "$candidate" in
    *qbit-hermes*) return 1 ;;
  esac
  # Skip qbit managed shell wrappers (they set HERMES_HOME / mention qbit-hermes).
  if head -1 "$candidate" 2>/dev/null | grep -qE '^#!.*(bash|sh)'; then
    if grep -qE 'qbit-hermes|HERMES_MANAGED=1|export HERMES_HOME=' "$candidate" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

for candidate in \
    "${ORIG_HOME}/.hermes/hermes-agent/venv/bin/hermes" \
    "${ORIG_HOME}/.hermes/bin/hermes" \
    /usr/local/bin/hermes \
    /usr/bin/hermes \
    /opt/hermes/bin/hermes \
    "${ORIG_HOME}/.local/bin/hermes"; do
  if is_usable_hermes_binary "$candidate"; then
    SYSTEM_HERMES="$candidate"
    break
  fi
done
if [[ -z "$SYSTEM_HERMES" ]] && command -v hermes >/dev/null 2>&1; then
  candidate="$(command -v hermes)"
  if is_usable_hermes_binary "$candidate"; then
    SYSTEM_HERMES="$candidate"
  fi
fi

if [[ -n "$SYSTEM_HERMES" ]]; then
  echo "qbit-hermes-agent-install: Hermes found at ${SYSTEM_HERMES}"

  # Always resolve to the final target when possible.
  RESOLVED_HERMES="$(readlink -f "$SYSTEM_HERMES" 2>/dev/null || true)"
  if [[ -z "$RESOLVED_HERMES" || ! -x "$RESOLVED_HERMES" ]]; then
    RESOLVED_HERMES="$SYSTEM_HERMES"
  fi
  if [[ ! -x "$RESOLVED_HERMES" ]]; then
    echo "ERROR: resolved Hermes binary not executable: ${RESOLVED_HERMES}" >&2
    exit 1
  fi
  # Final guard: never point the managed wrapper at itself / managed tree.
  if [[ -n "$RUNTIME_ROOT" && "$RESOLVED_HERMES" == "$RUNTIME_ROOT"* ]]; then
    echo "ERROR: resolved Hermes binary is inside the managed runtime tree: ${RESOLVED_HERMES}" >&2
    exit 1
  fi
  echo "qbit-hermes-agent-install: using resolved binary ${RESOLVED_HERMES}"

  if [[ -n "$RUNTIME_ROOT" ]]; then
    mkdir -p "$RUNTIME_ROOT/.local/bin"
    mkdir -p "$RUNTIME_ROOT/hermes-agent/venv/bin"

    # Managed wrapper only lives under the runtime tree. It must exec the real
    # upstream binary and must NOT prepend $RUNTIME_ROOT/.local/bin to PATH.
    cat > "$RUNTIME_ROOT/.local/bin/hermes" <<WRAPPER_EOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="\${HOME:-${RUNTIME_ROOT}}"
export HERMES_HOME="\${HERMES_HOME:-${RUNTIME_ROOT}/data}"
export HERMES_INSTALL_DIR="\${HERMES_INSTALL_DIR:-${RUNTIME_ROOT}/hermes-agent}"
exec '${RESOLVED_HERMES}' "\$@"
WRAPPER_EOF
    chmod +x "$RUNTIME_ROOT/.local/bin/hermes"

    # Prefer a direct venv-path symlink for anything that looks there first.
    ln -sfn "$RESOLVED_HERMES" "$RUNTIME_ROOT/hermes-agent/venv/bin/hermes"

    # Smoke-test: the wrapper must not E2BIG and must respond to --version.
    if ! "$RUNTIME_ROOT/.local/bin/hermes" --version >/dev/null 2>&1; then
      echo "ERROR: managed Hermes wrapper failed --version smoke test (exec -> ${RESOLVED_HERMES})" >&2
      echo "Wrapper contents:" >&2
      cat "$RUNTIME_ROOT/.local/bin/hermes" >&2 || true
      exit 1
    fi

    echo "Wrapper + symlink created in $RUNTIME_ROOT (exec -> ${RESOLVED_HERMES})"
  fi

  echo "qbit-hermes-agent-install: completed (system Hermes)"
  exit 0
fi

# ── No system Hermes found — install into managed tree ───────────────────
echo "qbit-hermes-agent-install: no system Hermes found, installing into managed runtime tree"

INSTALL_URL="${QBIT_HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required to install Hermes" >&2
  exit 1
fi

# The official installer runs with HOME=$RUNTIME_ROOT (set by the local API),
# so it places the venv at $RUNTIME_ROOT/.hermes/hermes-agent/venv/bin/hermes.
# The provisioner's resolve_runtime_hermes_binary() checks
# $RUNTIME_ROOT/hermes-agent/venv/bin/hermes and $RUNTIME_ROOT/.local/bin/hermes
# — neither of which exists after the official installer runs. We must create
# the managed wrapper + venv symlink so the provisioner can find and exec the
# real Hermes binary instead of recursing into a self-referencing wrapper
# ("Argument list too long" / E2BIG).
curl -fsSL "${INSTALL_URL}" | bash -s -- --skip-setup --skip-browser

echo "qbit-hermes-agent-install: Hermes install hook completed"

# Resolve the freshly-installed Hermes binary. The official installer places
# it under $HOME/.hermes/hermes-agent/venv/bin/hermes (HOME=$RUNTIME_ROOT here).
# NOTE: is_usable_hermes_binary() deliberately rejects RUNTIME_ROOT paths when
# looking for a *system* Hermes source. Fresh-install resolution must ALLOW
# the managed tree — use a separate checker that only requires an executable
# file and rejects self-exec shell wrappers.
if [[ -n "$RUNTIME_ROOT" ]]; then
  is_fresh_hermes_binary() {
    local candidate="$1"
    [[ -n "$candidate" && -x "$candidate" ]] || return 1
    # Reject self-exec shell wrappers (E2BIG source).
    if head -1 "$candidate" 2>/dev/null | grep -qE '^#!.*(bash|sh)'; then
      local exec_line
      exec_line="$(grep -E '^exec ' "$candidate" 2>/dev/null | head -1 || true)"
      if [[ -n "$exec_line" ]]; then
        # Extract the exec target (single-quoted path preferred).
        local target
        target="$(printf '%s\n' "$exec_line" | sed -n "s/^exec ['\"]\\([^'\"]*\\)['\"].*/\\1/p")"
        if [[ -z "$target" ]]; then
          target="$(printf '%s\n' "$exec_line" | awk '{print $2}')"
        fi
        if [[ -n "$target" ]]; then
          local cand_real target_real
          cand_real="$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
          target_real="$(readlink -f "$target" 2>/dev/null || echo "$target")"
          if [[ "$cand_real" == "$target_real" || "$target" == "$candidate" ]]; then
            return 1
          fi
        fi
      fi
    fi
    return 0
  }

  FRESH_HERMES=""
  for fresh_candidate in \
      "$RUNTIME_ROOT/.hermes/hermes-agent/venv/bin/hermes" \
      "$RUNTIME_ROOT/.hermes/bin/hermes" \
      "$HOME/.hermes/hermes-agent/venv/bin/hermes" \
      "$HOME/.hermes/bin/hermes" \
      /usr/local/bin/hermes; do
    if is_fresh_hermes_binary "$fresh_candidate" 2>/dev/null; then
      FRESH_HERMES="$fresh_candidate"
      break
    fi
  done

  if [[ -z "$FRESH_HERMES" ]]; then
    echo "ERROR: Hermes was installed but the venv binary could not be resolved." >&2
    echo "Checked: $RUNTIME_ROOT/.hermes/hermes-agent/venv/bin/hermes, $HOME/.hermes/..." >&2
    exit 1
  fi

  RESOLVED_HERMES="$(readlink -f "$FRESH_HERMES" 2>/dev/null || true)"
  if [[ -z "$RESOLVED_HERMES" || ! -x "$RESOLVED_HERMES" ]]; then
    RESOLVED_HERMES="$FRESH_HERMES"
  fi

  # Final guard: never point the managed wrapper at itself.
  if [[ "$RESOLVED_HERMES" == "$RUNTIME_ROOT/.local/bin/hermes" ]]; then
    echo "ERROR: resolved Hermes binary is the managed wrapper itself: ${RESOLVED_HERMES}" >&2
    exit 1
  fi

  echo "qbit-hermes-agent-install: using freshly-installed binary ${RESOLVED_HERMES}"

  mkdir -p "$RUNTIME_ROOT/.local/bin"
  mkdir -p "$RUNTIME_ROOT/hermes-agent/venv/bin"

  cat > "$RUNTIME_ROOT/.local/bin/hermes" <<WRAPPER_EOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="\${HOME:-${RUNTIME_ROOT}}"
export HERMES_HOME="\${HERMES_HOME:-${RUNTIME_ROOT}/data}"
export HERMES_INSTALL_DIR="\${HERMES_INSTALL_DIR:-${RUNTIME_ROOT}/hermes-agent}"
exec '${RESOLVED_HERMES}' "\$@"
WRAPPER_EOF
  chmod +x "$RUNTIME_ROOT/.local/bin/hermes"

  ln -sfn "$RESOLVED_HERMES" "$RUNTIME_ROOT/hermes-agent/venv/bin/hermes"

  # Smoke-test: the wrapper must not E2BIG and must respond to --version.
  if ! "$RUNTIME_ROOT/.local/bin/hermes" --version >/dev/null 2>&1; then
    echo "ERROR: managed Hermes wrapper failed --version smoke test (exec -> ${RESOLVED_HERMES})" >&2
    echo "Wrapper contents:" >&2
    cat "$RUNTIME_ROOT/.local/bin/hermes" >&2 || true
    exit 1
  fi

  echo "Wrapper + symlink created in $RUNTIME_ROOT (exec -> ${RESOLVED_HERMES})"
fi

echo "qbit-hermes-agent-install: completed (managed install)"
exit 0
HOOKEOF
  run chmod 0755 "${tmp_hook}"
  run ${SUDO} install -m 0755 "${tmp_hook}" "${hook}"
  ok "Provisioner hook installed -> ${hook}"
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

# Point the Phase 3 provisioner at user-writable managed paths. The managed
# Hermes CLI wrapper must live under the runtime tree only — never overwrite
# the operator's ~/.local/bin/hermes entrypoint (that caused the BYOH
# wrapper exec loop and broke the user Hermes CLI).
export QBIT_HERMES_CLI_BIN_PATH="\${DATA_DIR}/runtime/hermes/.local/bin/hermes"
export QBIT_HERMES_INSTALL_HOOK_PATH="${INSTALL_DIR}/qbit-hermes-agent-install"
export QBIT_HERMES_ORIG_HOME="${HOME}"

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

  install_provisioner_hook
  install_systemd_units
  install_setup_ui
  install_launcher
  echo

  print_post_install
}

# ── Install systemd service units for the daemon (and local-api) ──────────────
# On the normal Pi appliance, deploy_device.sh installs these units. On BYOH,
# we install adapted versions that point at the user-local data root instead of
# /var/lib/qbit-hermes. Both services run as root (matching the appliance path)
# because the daemon needs root for systemctl operations, service management,
# and file access within the managed runtime tree.
install_systemd_units() {
  local data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/qbit-hermes"
  local setup_root="${data_root}/setup"
  local legacy_setup_root="${data_root}/setup/setup"
  if [[ -d "${legacy_setup_root}/runtime/hermes" ]] && [[ ! -d "${setup_root}/runtime/hermes" ]]; then
    # Backward compatibility for earlier BYOH installs that wrote setup state
    # under a duplicated setup/setup path.
    setup_root="${legacy_setup_root}"
  fi
  local runtime_root="${setup_root}/runtime/hermes"
  # Managed CLI wrapper lives only under the runtime tree — never the operator
  # ~/.local/bin/hermes entrypoint (that overwrite created the BYOH exec loop).
  local managed_cli_bin="${runtime_root}/.local/bin/hermes"

  # --- daemon service ---
  local tmp_daemon_unit="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-daemon.service"
  cat > "${tmp_daemon_unit}" <<EOF
[Unit]
Description=qbit.me Hermes runtime health daemon (BYOH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/qbit-me-daemon --interval-seconds 30 --state-path ${data_root}/setup/bootstrap-state.json --history-path ${data_root}/runtime/health-history.json --setup-root ${setup_root} --cloud-api-base-url https://dev-app.qbit.me --cloud-prototype-access-key qbit-local-prototype-access-key --cloud-state-path ${data_root}/runtime/cloud-bridge-state.json --cloud-outbox-path ${data_root}/runtime/cloud-outbox.json
WorkingDirectory=${HOME}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=${runtime_root}"
Environment="HERMES_HOME=${runtime_root}/data"
Environment="HERMES_INSTALL_DIR=${runtime_root}/hermes-agent"
Environment="QBIT_HERMES_CLI_BIN_PATH=${managed_cli_bin}"
Environment="API_SERVER_ENABLED=true"
Environment="API_SERVER_KEY=TheyDontWait256%"
Environment="HERMES_API_SERVER_KEY=TheyDontWait256%"
Restart=always
RestartSec=5
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
ReadWritePaths=${data_root}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  # Ensure the data root exists before systemd constructs the mount namespace.
  run ${SUDO} mkdir -p "${data_root}"
  # Write the daemon env file so the local API can read the cloud config
  # (the setup UI uses this to derive the dashboard URL for the Done screen).
  local tmp_daemon_env="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-daemon"
  cat > "${tmp_daemon_env}" <<EOF
QBIT_CLOUD_API_BASE_URL=https://dev-app.qbit.me
QBIT_CLOUD_API_PROTOTYPE_ACCESS_KEY=qbit-local-prototype-access-key
API_SERVER_ENABLED=true
API_SERVER_KEY=TheyDontWait256%
HERMES_API_SERVER_KEY=TheyDontWait256%
EOF
  run ${SUDO} install -m 0644 "${tmp_daemon_env}" /etc/default/qbit-hermes-daemon
  run ${SUDO} install -m 0644 "${tmp_daemon_unit}" /etc/systemd/system/qbit-hermes-daemon.service
  run ${SUDO} systemctl daemon-reload
  run ${SUDO} systemctl enable qbit-hermes-daemon.service
  run ${SUDO} systemctl start qbit-hermes-daemon.service
  ok "Daemon systemd unit installed + enabled + started"

  # --- local-api service ---
  local tmp_api_unit="${WORK_DIR:-$(mktemp -d)}/qbit-hermes-local-api.service"
  cat > "${tmp_api_unit}" <<EOF
[Unit]
Description=qbit.me Hermes Local Setup API (BYOH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/qbit-me-local-api --bind 127.0.0.1:8081 --setup-ui-dir ${SHARE_DIR}/setup-ui --state-path ${data_root}/setup/bootstrap-state.json --draft-path ${data_root}/setup/staged-config.json --secret-path ${data_root}/setup/staged-secrets.json --progress-path ${data_root}/setup/install-progress.json
WorkingDirectory=${HOME}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="QBIT_HERMES_CLI_BIN_PATH=${managed_cli_bin}"
Environment="QBIT_HERMES_INSTALL_HOOK_PATH=${INSTALL_DIR}/qbit-hermes-agent-install"
Environment="QBIT_HERMES_ORIG_HOME=${HOME}"
Restart=on-failure
RestartSec=5
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
# The local-api needs write access to: the BYOH data root (state, drafts,
# secrets, progress, managed runtime tree) and /etc/systemd/system (where the
# provisioner installs the gateway unit). All entries MUST exist before
# systemd constructs the mount namespace, otherwise the service fails with
# status=226/NAMESPACE.
ReadWritePaths=${data_root} ${HOME}/.local/share /etc/systemd/system
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  # Ensure every ReadWritePaths entry exists before systemd constructs the
  # mount namespace — systemd refuses to start (status=226/NAMESPACE) if any
  # listed path is missing.
  run ${SUDO} mkdir -p "${data_root}" "${HOME}/.local/share" /etc/systemd/system
  # Repair a previously clobbered user hermes CLI if it is a qbit managed
  # wrapper. The user CLI must point at the real Hermes venv binary.
  repair_user_hermes_cli
  run ${SUDO} install -m 0644 "${tmp_api_unit}" /etc/systemd/system/qbit-hermes-local-api.service
  run ${SUDO} systemctl daemon-reload
  # Enable + start the local-api so the browser setup is immediately reachable
  # at http://127.0.0.1:8081/ with no terminal interaction. The BYOH path has no
  # BLE trigger to start it on-demand (unlike the Pi appliance path), so it must
  # be running from the moment the installer finishes.
  run ${SUDO} systemctl enable qbit-hermes-local-api.service
  run ${SUDO} systemctl start qbit-hermes-local-api.service
  ok "Local API systemd unit installed + enabled + started (http://${SETUP_BIND_ADDRESS}/)"
}

# If a previous BYOH install overwrote ~/.local/bin/hermes with a managed
# wrapper, restore a symlink to the real Hermes venv entrypoint.
repair_user_hermes_cli() {
  local user_hermes="${HOME}/.local/bin/hermes"
  local venv_hermes="${HOME}/.hermes/hermes-agent/venv/bin/hermes"
  [[ -x "${venv_hermes}" ]] || return 0
  mkdir -p "${HOME}/.local/bin"

  if [[ -L "${user_hermes}" ]]; then
    local target
    target="$(readlink -f "${user_hermes}" 2>/dev/null || true)"
    if [[ "${target}" == "${venv_hermes}" ]]; then
      return 0
    fi
  fi

  if [[ -f "${user_hermes}" ]] && head -1 "${user_hermes}" 2>/dev/null | grep -qE '^#!.*(bash|sh)'; then
    if grep -qE 'qbit-hermes|HERMES_MANAGED=1|export HERMES_HOME=' "${user_hermes}" 2>/dev/null; then
      log "Repairing user Hermes CLI at ${user_hermes} (was a managed qbit wrapper)"
      if [[ -n "${SUDO}" ]]; then
        run ${SUDO} rm -f "${user_hermes}"
      else
        run rm -f "${user_hermes}"
      fi
      run ln -sfn "${venv_hermes}" "${user_hermes}"
      ok "User Hermes CLI restored -> ${venv_hermes}"
      return 0
    fi
  fi

  if [[ ! -e "${user_hermes}" ]]; then
    run ln -sfn "${venv_hermes}" "${user_hermes}"
    ok "User Hermes CLI linked -> ${venv_hermes}"
  fi
}

print_post_install() {
  cat <<EOF
✓ qbit.me BYOH installation complete.

The local setup server is running now. Open this URL in your browser
to complete the guided setup (device name, timezone, providers, gateways)
and watch install progress:

    http://${SETUP_BIND_ADDRESS}/

Installed binaries (in ${INSTALL_DIR}):
  - qbit-me-local-api (embeds the qbit-me-provisioner install/runtime engine)
  - qbit-me-daemon
  - qbit-me-ble (--with-ble only)

Installed systemd services:
  - qbit-hermes-local-api.service (enabled + started; serving the setup UI now)
  - qbit-hermes-daemon.service (enabled, starts on boot)
  - qbit-hermes-gateway.service (installed by provisioner during setup)

Notes:
  - The mobile app + BLE onboarding path is unaffected by this installer.
  - No host network / Wi-Fi configuration was changed.
EOF
}

main "$@"
