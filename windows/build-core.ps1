# build-core.ps1 — build the Zig chart core for the Windows shell.
#
# Analog of linux/build-core.sh. Runs `zig build lib -Dbackend=d3d12` for ARM64
# Windows (MSVC ABI) and normalizes the artifact names the vcxproj links against:
# the core installs as lookout_marine.lib, but tile57 rides along as libtile57.a
# (a COFF archive despite the .a name), which MSVC link wants as tile57.lib.
#
# Usage:  pwsh windows/build-core.ps1 [-Configuration Debug|Release]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
# The core chases 60 fps; ReleaseFast unless developing the engine itself.
$opt = if ($Configuration -eq 'Debug') { 'Debug' } else { 'ReleaseFast' }

Push-Location $repo
try {
    Write-Host "zig build lib -Dbackend=d3d12 -Dtarget=aarch64-windows-msvc -Doptimize=$opt"
    & zig build lib -Dbackend=d3d12 -Dtarget=aarch64-windows-msvc "-Doptimize=$opt"
    if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$lib = Join-Path $repo 'zig-out\lib'
Copy-Item (Join-Path $lib 'libtile57.a') (Join-Path $lib 'tile57.lib') -Force
Write-Host "core ready: $lib\lookout_marine.lib, $lib\tile57.lib"
