#!/usr/bin/env bash
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

./scripts/generate-uniffi.sh
export DYLD_LIBRARY_PATH="$PWD/StacioCore/target/debug:${DYLD_LIBRARY_PATH:-}"
swift test
cargo test --manifest-path StacioCore/Cargo.toml
cargo check --manifest-path StacioCore/Cargo.toml
