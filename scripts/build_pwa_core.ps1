param([string]$Toolchain = '1.99.1')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build_pwa_registration.ps1') -Toolchain $Toolchain
$manifest = Join-Path $root 'rust/Cargo.toml'
cargo "+$Toolchain" build --locked --release --target wasm32-unknown-unknown --manifest-path $manifest
if ($LASTEXITCODE -ne 0) { throw 'Could not build the browser Rust core' }
$targetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $root 'rust/target' }
$wasm = Join-Path $targetDir 'wasm32-unknown-unknown/release/fqapi_core.wasm'
wasm-bindgen $wasm --target web --out-dir (Join-Path $root 'web/wasm')
if ($LASTEXITCODE -ne 0) { throw 'Could not build the browser bindings' }
