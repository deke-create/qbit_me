# qbit.me — BYOH Installer

This repository hosts the standalone [qbit.me](https://qbit.me) BYOH (Bring Your Own Hardware) installer script.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/deke-create/qbit_me/main/install-qbit.sh | bash -s -- -y
```

The script auto-detects your OS, CPU architecture, and whether Hermes Agent is already installed — no manual selection needed.

## What it does

1. Detects OS (Linux/macOS) and CPU (x86_64/aarch64)
2. Detects existing Hermes Agent install — skips reinstall if found
3. Installs Hermes Agent first if missing (via official installer)
4. Downloads matching qbit.me binaries from the release server
5. Installs `hb-local-api`, `hb-daemon`, setup UI bundle, and launcher

## Documentation

Full docs and source: [github.com/deke-create/qbit.me_platform](https://github.com/deke-create/qbit.me_platform)
