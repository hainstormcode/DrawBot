<#
.SYNOPSIS
  Builds DrawBot for Windows: build\DrawBot.exe (the app) and build\DrawBotTests.exe (the tests).

.DESCRIPTION
  Needs no SDK download: it uses the Roslyn C# compiler that ships with Visual Studio 2019+ or
  the free "Build Tools for Visual Studio", and targets .NET Framework 4.8, which every
  Windows 10 / 11 already has.

  .\build.ps1            # release build
  .\build.ps1 -Debug     # debug build (full PDBs, no optimizations)
  .\build.ps1 -Test      # build, then run the unit tests
#>
param(
    [switch]$Debug,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root 'build'
New-Item -ItemType Directory -Force $out | Out-Null

function Find-Csc {
    $candidates = @()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $paths = & $vswhere -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null
        foreach ($p in $paths) { $candidates += Join-Path $p 'MSBuild\Current\Bin\Roslyn\csc.exe' }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $vs = Join-Path $base 'Microsoft Visual Studio'
        if (Test-Path $vs) {
            Get-ChildItem $vs -Directory | ForEach-Object {
                Get-ChildItem $_.FullName -Directory | ForEach-Object {
                    $candidates += Join-Path $_.FullName 'MSBuild\Current\Bin\Roslyn\csc.exe'
                }
            }
        }
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

$csc = Find-Csc
if (-not $csc) {
    Write-Error ("No Roslyn C# compiler found. Install Visual Studio 2019 or later, or the free " +
        "'Build Tools for Visual Studio' (workload: .NET desktop build tools), then run this script again.")
}

$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf = Join-Path $fw 'WPF'
$refs = @(
    'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Xml.dll',
    'Microsoft.CSharp.dll', 'System.Xaml.dll'
) | ForEach-Object { "/reference:$(Join-Path $fw $_)" }
$refs += "/reference:$(Join-Path $wpf 'PresentationCore.dll')"
$refs += "/reference:$(Join-Path $wpf 'WindowsBase.dll')"
$refs += "/reference:$(Join-Path $wpf 'UIAutomationClient.dll')"
$refs += "/reference:$(Join-Path $wpf 'UIAutomationTypes.dll')"

$common = @('/nologo', '/langversion:latest', '/platform:anycpu', '/utf8output', '/nowarn:1591', '/warn:4') + $refs
if ($Debug) { $common += @('/debug:full', '/optimize-', '/define:DEBUG;TRACE') }
else { $common += @('/debug:pdbonly', '/optimize+') }

$core = Get-ChildItem (Join-Path $root 'src\Core') -Filter *.cs | ForEach-Object FullName
$win = Get-ChildItem (Join-Path $root 'src\Win') -Filter *.cs -ErrorAction SilentlyContinue | ForEach-Object FullName
$app = Get-ChildItem (Join-Path $root 'src\App') -Filter *.cs -ErrorAction SilentlyContinue | ForEach-Object FullName
$tests = Get-ChildItem (Join-Path $root 'tests') -Filter *.cs -ErrorAction SilentlyContinue | ForEach-Object FullName

$manifest = Join-Path $root 'src\App\DrawBot.manifest'
$icon = Join-Path $root 'src\App\DrawBot.ico'

Write-Host "Compiler: $csc"
$appArgs = $common + @('/target:winexe', "/out:$(Join-Path $out 'DrawBot.exe')")
if (Test-Path $manifest) { $appArgs += "/win32manifest:$manifest" }
if (Test-Path $icon) { $appArgs += "/win32icon:$icon" }
& $csc @appArgs @core @win @app
if ($LASTEXITCODE -ne 0) { throw "DrawBot.exe failed to compile" }
Write-Host "Built $(Join-Path $out 'DrawBot.exe')"

if ($tests) {
    # The tests compile the same sources (minus the app's entry point) so they can reach internals.
    $appNoMain = $app | Where-Object { (Split-Path -Leaf $_) -ne 'Program.cs' }
    $testArgs = $common + @('/target:exe', "/out:$(Join-Path $out 'DrawBotTests.exe')")
    if (Test-Path $manifest) { $testArgs += "/win32manifest:$manifest" }
    & $csc @testArgs @core @win @appNoMain @tests
    if ($LASTEXITCODE -ne 0) { throw "DrawBotTests.exe failed to compile" }
    Write-Host "Built $(Join-Path $out 'DrawBotTests.exe')"
}

if ($Test) {
    & (Join-Path $out 'DrawBotTests.exe')
    exit $LASTEXITCODE
}
