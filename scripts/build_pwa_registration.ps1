param([string]$Toolchain = '1.99.1')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$crate = Join-Path $root 'rust/pwa-registration'
cargo "+$Toolchain" build --locked --release --target wasm32-unknown-unknown --manifest-path (Join-Path $crate 'Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Could not build the registration WASM' }
$targetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $crate 'target' }
$wasm = Join-Path $targetDir 'wasm32-unknown-unknown/release/fqapi_web_registration.wasm'
Copy-Item -LiteralPath $wasm -Destination (Join-Path $root 'web/fqapi_web_registration.wasm')
