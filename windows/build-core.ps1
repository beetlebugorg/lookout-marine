# build-core.ps1 — build the Zig chart core for the Windows shell.
#
# Analog of linux/build-core.sh. Runs `zig build lib -Dbackend=d3d12` for the
# platform the vcxproj is being built for (MSVC ABI) and normalizes the artifact
# names MSVC link wants: the core installs as lookout_marine.lib, but tile57
# rides along as libtile57.a (a COFF archive despite the .a name), which link
# wants as tile57.lib. The WAMR archive, when there is one, is the same story.
#
# PLUGINS. Own ship, AIS, NMEA 0183, Signal K and laylines are wasm plugins, so
# a core built without the host is a chartplotter with no boat and no traffic.
# The host needs the target's MSVC-ABI WAMR archive:
#   ARM64  vendor/wamr-dist-windows-arm64 — built on this machine by
#          `bash scripts/build-wamr.sh windows-arm64` (Git Bash; zig cc
#          targets aarch64-windows-msvc against the installed MSVC + SDK).
#   x64    vendor/wamr-dist-windows-x64 — must be the MSVC-ABI archive, not
#          the mingw one that script cross-builds elsewhere:
#          `bash scripts/build-wamr.sh windows-x64 --print-msvc` prints the
#          cmake command that builds it here.
# When the slot is empty this builds the core without the host rather than
# failing, and says so.
#
# Usage:  pwsh windows/build-core.ps1 [-Configuration Debug|Release] [-Platform ARM64|x64]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('ARM64', 'x64')]
    [string]$Platform = 'ARM64'
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
# The core chases 60 fps; ReleaseFast unless developing the engine itself.
$opt = if ($Configuration -eq 'Debug') { 'Debug' } else { 'ReleaseFast' }
$zigTarget = if ($Platform -eq 'x64') { 'x86_64-windows-msvc' } else { 'aarch64-windows-msvc' }

# The archive the plugin host links, one dist per architecture (see
# build.zig's wamrDist). Present -> the host goes in; absent -> warn and build
# the core without it.
$wamrDist = if ($Platform -eq 'x64') { 'wamr-dist-windows-x64' } else { 'wamr-dist-windows-arm64' }
$wamr = Join-Path $repo "vendor\$wamrDist\lib\libvmlib.a"
$plugins = Test-Path $wamr

Push-Location $repo
try {
    # No -Dbackend option exists in build.zig: the D3D12 backend is selected by
    # the windows target itself (charttable's build). Passing one fails the build.
    $args = @('lib', "-Dtarget=$zigTarget", "-Doptimize=$opt")
    if ($plugins) {
        $args += '-Dplugins=true'
    }
    else {
        Write-Warning ("no wasm plugin host in this core: $wamr is missing " +
            '(see the header of this script; for ARM64 run ' +
            '"bash scripts/build-wamr.sh windows-arm64"). ' +
            'The chart will have no own ship, no AIS and no instrument input.')
    }

    Write-Host "zig build $($args -join ' ')"
    & zig build @args
    if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" }

    # The shipped plugin set into zig-out\plugins-bundled, which the vcxproj's
    # LkCopyBundledPlugins target copies beside the exe. The modules are wasm,
    # so this takes no -Dtarget and builds nothing native. It runs whether or
    # not the host does: the modules travel with the app either way.
    Write-Host "zig build plugins"
    & zig build plugins
    if ($LASTEXITCODE -ne 0) { throw "zig build plugins failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$lib = Join-Path $repo 'zig-out\lib'
Copy-Item (Join-Path $lib 'libtile57.a') (Join-Path $lib 'tile57.lib') -Force
$vmlib = Join-Path $lib 'vmlib.lib'
if ($plugins) {
    Copy-Item (Join-Path $lib 'libvmlib.a') $vmlib -Force
}
else {
    # A stale one from an earlier plugin build would be linked by the vcxproj,
    # which conditions on the file, into a core that has no wasm symbols to
    # resolve. Leaving it behind is a confusing link, so it goes.
    Remove-Item $vmlib -Force -ErrorAction SilentlyContinue
}
Write-Host "core ready: $lib\lookout_marine.lib, $lib\tile57.lib$(if ($plugins) { ", $vmlib" })"
