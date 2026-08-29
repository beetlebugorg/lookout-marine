# build-tests.ps1 — build and run the Windows shell's tests.
#
# The suite covers the shell's MODEL: the parsers, the formatters, the geometry
# and the store. Not the WinUI layer — that needs a XAML host — and not the
# core, which has its own `zig build test`.
#
# It builds with zig rather than MSVC on purpose. zig is already a prerequisite
# of this shell (build-core.ps1 needs it), so the tests run for anyone who can
# build the app, including on a machine with no Visual Studio: the mingw-ABI
# target links the same Win32 API the shell calls without needing the SDK.
# Nothing here links the core or WinRT, which is what keeps that true.
#
# The C layer is compiled with `zig cc` and the C++ with `zig c++`: clang++
# compiles a .c file as C++, and that code is C.
#
# Usage:  pwsh windows/build-tests.ps1 [-Platform x64|arm64] [-Build]
#         -Build   compile only, do not run
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Platform = 'x64',
    [switch]$Build
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$out = Join-Path $here 'test\out'
$target = if ($Platform -eq 'arm64') { 'aarch64-windows-gnu' } else { 'x86_64-windows-gnu' }

# Every source directory is on the include path, the way the vcxproj puts it
# there ($(LkSourceDirs)), so a header is included by name here too. The ui\
# directories are on it as well: a model header may not include one, but the
# path costs nothing and keeps the two builds saying the same thing.
$sourceDirs = @('app\ui', 'chart', 'chart\ui', 'hud', 'hud\ui', 'library', 'library\ui',
    'plugins', 'plugins\ui', 'settings\ui', 'about', 'about\ui', 'engine', 'util') |
    ForEach-Object { "-I$PSScriptRoot\src\$_" }

# The core's headers, for the TYPES the store and the paths speak in
# (lookout_view, tile57_mariner). Headers only: nothing here links the core,
# and a test that needed a lookout_* symbol would be testing the core.
$coreInclude = Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\include'
if (Test-Path $coreInclude) { $sourceDirs += "-I$coreInclude" }
else { Write-Warning "no core headers at $coreInclude; run windows\build-core.ps1 first" }

# The shell's own sources under test. A new module goes in one of the first two
# lists, its suite in the third, and main.cpp names the suite function.
$cSources = @(
    'src\util\lk_coord.c',
    'src\engine\lk_store.c'
)
$cppSources = @(
    'src\util\lk_json.cpp',
    'src\util\lk_utf8.cpp',
    'src\chart\lk_pick.cpp',
    'src\about\lk_licenses.cpp',
    'src\plugins\lk_plugin_registry.cpp',
    'src\plugins\lk_alerts.cpp',
    'src\plugins\lk_table.cpp',
    'src\hud\lk_text.cpp',
    'src\library\lk_paths.cpp'
)
$suites = @(
    'test\main.cpp',
    'test\test_coord.cpp',
    'test\test_json.cpp',
    'test\test_utf8.cpp',
    'test\test_pick.cpp',
    'test\test_licenses.cpp',
    'test\test_plugin_registry.cpp',
    'test\test_alerts.cpp',
    'test\test_table.cpp',
    'test\test_text.cpp',
    'test\test_paths.cpp',
    'test\test_store.cpp'
)

New-Item -ItemType Directory -Force $out | Out-Null
$objects = New-Object System.Collections.Generic.List[string]

function Compile([string]$Sub, [string]$Source, [string[]]$Extra) {
    $obj = Join-Path $out ((Split-Path $Source -Leaf) + '.o')
    $arguments = @($Sub, '-target', $target, '-c', (Join-Path $here $Source), '-o', $obj) +
        $sourceDirs + @("-I$here\test", '-Wall', '-Wextra', '-Wno-unused-parameter', '-g') + $Extra
    & zig @arguments
    if ($LASTEXITCODE -ne 0) { throw "zig $Sub failed on $Source ($LASTEXITCODE)" }
    $objects.Add($obj)
}

foreach ($s in $cSources) { Compile 'cc' $s @('-std=c11') }
foreach ($s in ($cppSources + $suites)) { Compile 'c++' $s @('-std=c++20') }

$exe = Join-Path $out 'lk-tests.exe'
# shell32/ole32: the known-folder calls the store and the chart paths make.
& zig c++ -target $target @($objects.ToArray()) -o $exe -lshell32 -lole32
if ($LASTEXITCODE -ne 0) { throw "link failed ($LASTEXITCODE)" }

Write-Host "tests built: $exe`n"
if ($Build) { return }

& $exe
if ($LASTEXITCODE -ne 0) { throw "tests failed ($LASTEXITCODE)" }
