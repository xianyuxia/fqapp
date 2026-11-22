param(
  [string]$Flutter = 'flutter',
  [string]$Toolchain = '1.99.1',
  [string]$RelayUrl = '/relay',
  [switch]$NoPub
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  & (Join-Path $PSScriptRoot 'build_pwa_core.ps1') -Toolchain $Toolchain
  $arguments = @(
    'build', 'web', '--no-wasm-dry-run', '--no-web-resources-cdn', '--pwa-strategy=none',
    "--dart-define=SHIJINPU_RELAY_URL=$RelayUrl",
    '--dart-define=SHIJINPU_DEFER_SERIF=true'
  )
  if ($NoPub) { $arguments += '--no-pub' }
  & $Flutter @arguments
  if ($LASTEXITCODE -ne 0) { throw 'Could not build Flutter Web' }

  # Keep the font assets available to FontLoader without preloading them in CanvasKit.
  $manifestPath = 'build/web/assets/FontManifest.json'
  $fonts = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $startupFonts = @($fonts | Where-Object { $_.family -ne 'Home Serif' })
  ConvertTo-Json -InputObject $startupFonts -Depth 8 -Compress |
    Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
  @(
    '.last_build_id',
    '/assets/assets/config/',
    '/assets/assets/plugins/'
  ) | Set-Content -LiteralPath build/web/.assetsignore
} finally {
  Pop-Location
}
