<#
Build fqappX with the SAME local signer as its install-ready package.
Requires the Android Rust libraries from build_rust_backend.ps1.
Uses a fresh ASCII temporary source directory for Windows CMake compatibility.
User backups and cloud credentials are never copied into the staging directory.
#>
param(
    [Parameter(Mandatory=$true)][string]$FlutterSdk,
    [Parameter(Mandatory=$true)][string]$AndroidSdk
)
$ErrorActionPreference='Stop'
$workspaceRoot=Split-Path -Parent $PSScriptRoot
$FlutterSdk=(Resolve-Path -LiteralPath $FlutterSdk).Path.TrimEnd('\')
$AndroidSdk=(Resolve-Path -LiteralPath $AndroidSdk).Path.TrimEnd('\')
if(-not(Test-Path -LiteralPath "$FlutterSdk\bin\flutter.bat")){throw 'Flutter SDK missing'}
$createdSdkAlias=$false
$oldSigning=$env:FQAPPX_LOCAL_SIGNING
$oldAndroid=$env:ANDROID_HOME
try {
    # Query the UTF-16 Windows API: parsing subst's OEM text corrupts Chinese paths.
    if (-not ('FqappxDriveMapping' -as [type])) {
        Add-Type 'using System; using System.Text; using System.Runtime.InteropServices;
        public static class FqappxDriveMapping {
          [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
          public static extern uint QueryDosDevice(string name, StringBuilder target, int size);
        }'
    }
    $mappingBuffer=[Text.StringBuilder]::new(32768)
    $mappingSize=[FqappxDriveMapping]::QueryDosDevice('S:', $mappingBuffer, $mappingBuffer.Capacity)
    if($mappingSize -gt 0){
        $target=$mappingBuffer.ToString()
        if ($target.StartsWith('\??\')) {$target=$target.Substring(4)}
        if(-not $target.TrimEnd('\').Equals($FlutterSdk,[StringComparison]::OrdinalIgnoreCase)){throw 'Drive S is in use'}
    } elseif(Test-Path 'S:\'){throw 'Drive S is in use'}
    else {subst S: $FlutterSdk;if($LASTEXITCODE -ne 0){throw 'SDK alias creation failed'};$createdSdkAlias=$true}
    $prepared=& python (Join-Path $PSScriptRoot 'prepare_fqappx_build.py') --source $workspaceRoot --android-sdk $AndroidSdk
    if($LASTEXITCODE -ne 0){throw 'Build staging failed'}
    $stage=($prepared|ConvertFrom-Json).stage
    $env:FQAPPX_LOCAL_SIGNING='true'
    $env:ANDROID_HOME=$AndroidSdk
    Push-Location -LiteralPath $stage
    try {
        & 'S:\bin\flutter.bat' pub get
        if($LASTEXITCODE -ne 0){throw 'Dependency resolution failed'}
        & 'S:\bin\flutter.bat' build apk --debug --target-platform android-arm64 --no-pub
        if($LASTEXITCODE -ne 0){throw 'fqappX build failed'}
        $destination=Join-Path $workspaceRoot 'build\app\outputs\flutter-apk'
        New-Item -ItemType Directory -Force -Path $destination|Out-Null
        Copy-Item -LiteralPath (Join-Path $stage 'build\app\outputs\flutter-apk\app-debug.apk') -Destination (Join-Path $destination 'app-debug.apk')
    } finally {Pop-Location}
} finally {
    $env:FQAPPX_LOCAL_SIGNING=$oldSigning
    $env:ANDROID_HOME=$oldAndroid
    if($createdSdkAlias){subst S: /D}
}
