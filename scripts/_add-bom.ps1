param([string[]]$Files)
foreach ($rel in $Files) {
    $f = Join-Path (Split-Path $PSCommandPath -Parent | Split-Path -Parent) $rel
    $b = [System.IO.File]::ReadAllBytes($f)
    if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
        $c = [System.IO.File]::ReadAllText($f)
        [System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "BOM added: $rel"
    } else {
        Write-Host "BOM OK:    $rel"
    }
}
