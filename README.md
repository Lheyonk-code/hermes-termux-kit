# hermes-termux-kit

One-command Hermes Agent setup for Termux (Android) — born from a real
full-wipe rebuild, so nobody else has to redo it by hand for hours.

## What it sets up
- Hermes Agent inside proot-debian on Termux
- Provider template with automatic rotation/failover across your own providers (keys via `.env` — never in repo)
- ai-memory server + Termux `runsv` services (auto-start, logs, start/stop)
- Backup & restore scripts for Hermes config + memories

## Status
Spec phase. Build in progress by the Hermes ecosystem team setup
(guide: SPEC in project workspace).

## Install (target UX)
```bash
pkg install -y git
git clone https://github.com/robbertcalliso-code/hermes-termux-kit
cd hermes-termux-kit
bash install.sh
```

MIT License.
