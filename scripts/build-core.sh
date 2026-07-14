#!/usr/bin/env bash
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  else
    echo "cargo is required to build StacioCore. Install Rust with rustup first." >&2
    exit 127
  fi
fi

cargo build --manifest-path StacioCore/Cargo.toml

