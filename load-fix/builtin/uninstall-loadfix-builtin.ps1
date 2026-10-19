# Removes the built-in Load Fix: deletes each file listed in the game folder's
# loadfix-installed.txt whose content is still ours (a file changed since is left alone and
# named), then any folders that are left empty. With -RestoreZombieBuddyMod, puts the mod that the
# installer moved to Zomboid\mods-disabled back in place of the code-free LoadFix folder; this also
# works when no game files were installed (an install that failed partway).
#   powershell -ExecutionPolicy Bypass -File uninstall-loadfix-builtin.ps1 [-GameDir <dir>] [-ZomboidDir <dir>] [-RestoreZombieBuddyMod]
param(
    [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
    [string]$ZomboidDir = (Join-Path $env:USERPROFILE 'Zomboid'),
    [switch]$RestoreZombieBuddyMod
)
$ErrorActionPreference = 'Stop'
$list = Join-Path $GameDir 'loadfix-installed.txt'
if (Test-Path $list) {
    $kept = 0
    foreach ($l in Get-Content $list | Select-Object -Skip 1) {
        if (-not $l.Trim()) { continue }
        $p = $l.Trim() -split ' '
        $dest = Join-Path $GameDir $p[0]
        if (-not (Test-Path -LiteralPath $dest)) { continue }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower() -eq $p[1]) { Remove-Item -LiteralPath $dest }
        else { Write-Output "Left alone (changed since install): $dest"; $kept++ }
    }
    # Deepest first; a folder is only removed when nothing is left in it (pzopt's files keep zombie\).
    foreach ($d in 'pzmod\loadfix', 'pzmod', 'zombie\Lua', 'zombie\gameStates', 'zombie') {
        $dd = Join-Path $GameDir $d
        if ((Test-Path $dd) -and -not (Get-ChildItem -Force $dd)) { Remove-Item $dd }
    }
    if ($kept -eq 0) { Remove-Item $list }
    Write-Output "Load Fix removed from $GameDir."
} elseif (-not $RestoreZombieBuddyMod) {
    throw "No $list; Load Fix isn't installed there."
} else {
    Write-Output "No $list, so no game files to remove."
}
if ($RestoreZombieBuddyMod) {
    $disabled = Join-Path $ZomboidDir 'mods-disabled'
    $record = Join-Path $disabled 'loadfix-moved.txt'
    $src = if (Test-Path $record) { (Get-Content $record | Select-Object -First 1).Trim() } else { Join-Path $disabled 'LoadFix' }
    $dest = Join-Path $ZomboidDir 'mods\LoadFix'
    if ($src -and (Test-Path $src)) {
        if ((Test-Path $dest) -and (Test-Path (Join-Path $dest 'common\README.txt')) -and -not (Test-Path (Join-Path $dest '42\media'))) { Remove-Item -Recurse $dest }   # the code-free marker
        if (-not (Test-Path $dest)) {
            Move-Item $src $dest
            if (Test-Path $record) { Remove-Item $record }
            Write-Output "Restored $dest"
        } else { Write-Output "Not restoring: $dest exists and isn't the code-free marker." }
    } else { Write-Output "Nothing to restore: $src not found." }
}
