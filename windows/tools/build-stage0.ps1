# build-stage0.ps1 — compile the pure-Win32 pipeline smoke test (windows/tools/stage0.c).
#
# Links the Zig core (built by `zig build lib -Dbackend=vk -Dtarget=aarch64-windows-msvc`
# into ../../zig-out) against the ARM64 Vulkan loader, with MSVC. Console subsystem
# so stderr/logs are visible, but the entry is WinMainCRTStartup so WinMain runs.
#
# Usage:  pwsh windows/tools/build-stage0.ps1   ->   windows/build/stage0.exe
$ErrorActionPreference = 'Stop'

$repo    = (Resolve-Path "$PSScriptRoot\..\..").Path
$zigout  = Join-Path $repo 'zig-out'
$outdir  = Join-Path $repo 'windows\build'
$src     = Join-Path $PSScriptRoot 'stage0.c'
New-Item -ItemType Directory -Force -Path $outdir | Out-Null

# Zig's msvc target installs the core as lookout_marine.lib already; tile57 rides
# along as libtile57.a (a COFF archive despite the .a name — MSVC link wants .lib).
Copy-Item (Join-Path $zigout 'lib\lookout_marine.lib') (Join-Path $outdir 'lookout_marine.lib') -Force
Copy-Item (Join-Path $zigout 'lib\libtile57.a')        (Join-Path $outdir 'tile57.lib')         -Force

# Vulkan SDK (ARM64) — vulkan-1.lib and headers.
$vk = $env:VULKAN_SDK
if (-not $vk) { $vk = 'C:\VulkanSDK\1.4.350.0' }

$vcvars = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat'

# x64_arm64: x64 host tools (run under emulation) producing native ARM64 — the
# only cross on this box (no Hostarm64 toolset installed).
$inc  = Join-Path $zigout 'include'
$cl = @"
call "$vcvars" x64_arm64
cl /nologo /W3 /Zi /TC "$src" /I "$inc" /I "$vk\Include" ^
   /Fe:"$outdir\stage0.exe" /Fo:"$outdir\\" /Fd:"$outdir\stage0.pdb" ^
   /link /SUBSYSTEM:CONSOLE /ENTRY:WinMainCRTStartup ^
   /LIBPATH:"$outdir" /LIBPATH:"$vk\Lib" ^
   lookout_marine.lib tile57.lib vulkan-1.lib ^
   ntdll.lib user32.lib gdi32.lib shell32.lib ole32.lib advapi32.lib
"@
$bat = Join-Path $env:TEMP 'lk_build_stage0.bat'
Set-Content -Path $bat -Value $cl -Encoding ascii
cmd /c $bat
if ($LASTEXITCODE -ne 0) { throw "stage0 build failed ($LASTEXITCODE)" }
Write-Host "OK -> $outdir\stage0.exe"
