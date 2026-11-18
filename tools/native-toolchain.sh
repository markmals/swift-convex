#!/usr/bin/env bash

configure_native_toolchain() {
    local crate="$1"
    shift
    local rustup_binary
    rustup_binary="$(command -v rustup || true)"
    if [[ -z "$rustup_binary" ]]; then
        echo "error: rustup is required; install it from https://rustup.rs" >&2
        return 1
    fi
    local toolchain
    toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$crate/rust-toolchain.toml")"
    if [[ -z "$toolchain" ]]; then
        echo "error: no channel in $crate/rust-toolchain.toml" >&2
        return 1
    fi
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTUP_TOOLCHAIN="$toolchain"
    if ! "$rustup_binary" toolchain list | grep -q "^$toolchain-"; then
        "$rustup_binary" toolchain install "$toolchain" --profile minimal
    fi
    if [[ "$#" -gt 0 ]]; then
        "$rustup_binary" target add --toolchain "$toolchain" "$@"
    fi
    local compiler
    compiler="$("$rustup_binary" which --toolchain "$toolchain" rustc)"
    local toolchain_bin
    toolchain_bin="$(dirname "$compiler")"
    export PATH="$toolchain_bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
