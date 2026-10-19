# Installs Load Fix built into the game's classes (the pzopt way, no ZombieBuddy needed for it).
# Copies game\* into the game folder, which is first on the game's classpath ("."): Load Fix's own
# classes first and the patched game classes last, so a copy that fails halfway never leaves game
# classes that call into missing Load Fix classes. Only after every copy has succeeded does it move
# the ZombieBuddy version (Zomboid\mods\LoadFix) to Zomboid\mods-disabled so it can't patch twice,
# and put a code-free LoadFix mod folder in its place so saves that list LoadFix still load.
# Before a Steam game update, run uninstall-loadfix-builtin.ps1; reinstall a matching build after.
# Refuses, changing nothing, if projectzomboid.jar isn't the one this was built for, if pzopt
# owns any of these files, or if a file it would replace isn't one of ours.
#   powershell -ExecutionPolicy Bypass -File install-loadfix-builtin.ps1 [-GameDir <dir>] [-ZomboidDir <dir>]
param(
    [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
    [string]$ZomboidDir = (Join-Path $env:USERPROFILE 'Zomboid')
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$listFile = Join-Path $here 'loadfix-installed.txt'
$lines = Get-Content $listFile
$wantJar = ($lines[0] -split 'sha256 ')[1].Trim()
$files = @{}
$order = @()
foreach ($l in $lines | Select-Object -Skip 1) { if ($l.Trim()) { $p = $l.Trim() -split ' '; $files[$p[0]] = $p[1]; $order += $p[0] } }
# Load Fix's own classes (pzmod/...) before the game classes that call them (zombie/...).
$order = @($order | Where-Object { -not $_.StartsWith('zombie/') }) + @($order | Where-Object { $_.StartsWith('zombie/') })

$jar = Join-Path $GameDir 'projectzomboid.jar'
$haveJar = (Get-FileHash -Algorithm SHA256 $jar).Hash.ToLower()
if ($haveJar -ne $wantJar) { throw "projectzomboid.jar is $haveJar, but this Load Fix was built for $wantJar. Nothing changed." }

$pzopt = Join-Path $GameDir 'pzopt-installed.txt'
if (Test-Path $pzopt) {
    $owned = @{}
    foreach ($l in Get-Content $pzopt) { if ($l.Trim() -and -not $l.Trim().StartsWith('#')) { $owned[(($l.Trim() -split '\s+')[0] -replace '\\', '/').TrimStart('./').ToLower()] = 1 } }
    foreach ($f in $files.Keys) { if ($owned.ContainsKey($f.ToLower())) { throw "pzopt installs $f too; installing would break pzopt. Nothing changed." } }
}

$oldList = Join-Path $GameDir 'loadfix-installed.txt'
$ours = @{}
if (Test-Path $oldList) { foreach ($l in Get-Content $oldList | Select-Object -Skip 1) { if ($l.Trim()) { $p = $l.Trim() -split ' '; $ours[$p[0]] = $p[1] } } }
foreach ($f in $files.Keys) {
    $dest = Join-Path $GameDir $f
    if (Test-Path -LiteralPath $dest) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
        if ($h -ne $files[$f] -and $h -ne $ours[$f]) { throw "$dest exists and isn't from Load Fix; not replacing it. Nothing changed." }
    }
}

Copy-Item $listFile $oldList -Force   # first, so the uninstaller can clean up even after a failed copy
foreach ($f in $order) {
    $src = Join-Path (Join-Path $here 'game') $f
    $dest = Join-Path $GameDir $f
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Force
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
    if ($h -ne $files[$f]) { throw "Copy check failed for $dest" }
}
# Only now, with every file in place, swap the ZombieBuddy version for the code-free marker.
# If this part fails, both versions would patch: run uninstall-loadfix-builtin.ps1 before playing.
$zbMod = Join-Path $ZomboidDir 'mods\LoadFix'
if (Test-Path $zbMod) {
    $disabled = Join-Path $ZomboidDir 'mods-disabled'
    New-Item -ItemType Directory -Force $disabled | Out-Null
    $marker = (Test-Path (Join-Path $zbMod 'common\README.txt')) -and -not (Test-Path (Join-Path $zbMod '42\media'))
    if ($marker) {
        Remove-Item -Recurse $zbMod   # our own code-free marker from an earlier install
    } else {
        $target = Join-Path $disabled 'LoadFix'
        if (Test-Path $target) { $target = Join-Path $disabled ('LoadFix-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
        Move-Item $zbMod $target
        Set-Content -Path (Join-Path $disabled 'loadfix-moved.txt') -Value $target   # for -RestoreZombieBuddyMod
        Write-Output "Moved the previous LoadFix mod to $target"
    }
}
Copy-Item -Recurse (Join-Path $here 'LoadFix') $zbMod
Write-Output "Load Fix installed into $GameDir ($($files.Count) files). Look for '[LoadFix] built into the game's classes' in console.txt."
