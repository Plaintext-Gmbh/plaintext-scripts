#!/usr/bin/env bash
# wochenpatch/projectmind-patch.sh — Patch-/semver-kompatible Updates fuer ProjectMind (Karte 1340).
#
#   projectmind-patch.sh <repo-verzeichnis>
#
# cargo update (nur innerhalb der in Cargo.toml erlaubten Bereiche) und pnpm update (innerhalb
# der ^-Bereiche), danach die Pruefungen, die am 28.09.2026 von Hand liefen:
#   pnpm test / build / check, cargo test --workspace ohne Tauri-App und browser-host.
# Reihenfolge ist wichtig: das Frontend (app/dist) muss VOR cargo test gebaut sein, der
# MCP-Server bettet es per include_dir! ein; ohne dist bricht schon das Kompilieren ab.
# Braucht: cargo (rustup), node >= 22, npx (pnpm wird ueber npx geholt).
set -euo pipefail
DIR="${1:?Repo-Verzeichnis fehlt}"
cd "$DIR"
cargo update >&2
( cd app && npx -y pnpm@10 update >&2 && npx -y pnpm@10 install --frozen-lockfile >&2 \
    && npx -y pnpm@10 run test >&2 && npx -y pnpm@10 run build >&2 && npx -y pnpm@10 run check >&2 )
cargo test --workspace --exclude projectmind-app --exclude browser-host -j "${WP_JOBS:-2}" >&2
git diff --stat -- Cargo.lock app/package.json app/pnpm-lock.yaml | tail -1
