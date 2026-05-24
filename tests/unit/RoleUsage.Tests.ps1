# RoleUsage.Tests.ps1 — ロール判定のスキーマ統一チェック
#
# roles 配列スキーマ移行後、コード中で .role -eq/-ne 'admin' 直接比較が残ると
# silent fail (AdminBtn を押しても反応しない 等) の原因になるため、本テストで
# 自動検出する。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    $script:ProductScripts = @()
    $script:ProductScripts += Get-ChildItem (Join-Path $script:RepoRoot 'client')  -Filter *.ps1 -Recurse | Select-Object -ExpandProperty FullName
    $script:ProductScripts += Get-ChildItem (Join-Path $script:RepoRoot 'reports') -Filter *.ps1 -Recurse | Select-Object -ExpandProperty FullName
}

Describe 'ロール判定スキーマ統一' -Tag 'unit','roles' {

    It '本番コードに .role -eq/-ne ''admin'' の直接比較が無い (Has-Role に統一)' {
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:ProductScripts) {
            $lines = Get-Content -LiteralPath $f
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # コメント行はスキップ
                if ($line -match '^\s*#') { continue }
                # .role -eq / -ne '...' / -eq "..." パターン
                if ($line -match '\.role\s+-(?:eq|ne|like|notlike|match|notmatch)\s+[''"]') {
                    $hits.Add(("{0}:{1}: {2}" -f (Split-Path -Leaf $f), ($i+1), $line.Trim()))
                }
            }
        }
        if ($hits.Count -gt 0) {
            $msg = "Has-Role に置換してください:`n" + (($hits) -join "`n")
            $hits.Count | Should -Be 0 -Because $msg
        }
    }

    It '本番コードに .role = ''admin'' / "leader" の直接代入が無い (roles 配列へ)' {
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($f in $script:ProductScripts) {
            $lines = Get-Content -LiteralPath $f
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '^\s*#') { continue }
                # role = 'admin' / "leader" 等の代入 (.role / role=  両方)
                # シンセティック CurrentMember 構築の role='member' は許容するため
                # 'admin' / 'leader' のみ検出
                if ($line -match '\brole\s*=\s*[''"](admin|leader)[''"]') {
                    $hits.Add(("{0}:{1}: {2}" -f (Split-Path -Leaf $f), ($i+1), $line.Trim()))
                }
            }
        }
        if ($hits.Count -gt 0) {
            $msg = "roles 配列にしてください:`n" + (($hits) -join "`n")
            $hits.Count | Should -Be 0 -Because $msg
        }
    }
}
