# AllScripts.Tests.ps1 — リポジトリ内の全 .ps1 を AST パースして構文エラーを検出
# (ランタイムなしでも実行可能。CI でも回せる軽量チェック)

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent

    # 検査対象 .ps1 (tests 配下と analysis の Excel-COM スクリプトは別管理)
    $script:AllScripts = @(
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'client')  -Filter '*.ps1' -Recurse |
            Select-Object -ExpandProperty FullName
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'reports') -Filter '*.ps1' -Recurse |
            Select-Object -ExpandProperty FullName
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' -Recurse |
            Select-Object -ExpandProperty FullName
    )
}

Describe '全 .ps1 ファイルの構文チェック (Parser)' -Tag 'unit','syntax' {
    It '<file> がパースできる (構文エラーなし)' -TestCases @(
        # BeforeAll の前に TestCases が評価されるため、ここで再列挙
        $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
        $files = @()
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'client')  -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'reports') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files | ForEach-Object { @{ file = $_ } }
    ) {
        param($file)
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $msg = ($errors | ForEach-Object { "  ${($_.Extent.StartLineNumber)}: ${($_.Message)}" }) -join "`n"
            $errors.Count | Should -Be 0 -Because "構文エラー:`n$msg"
        }
    }
}

Describe '全 .ps1 ファイルが UTF-8 BOM で保存されている' -Tag 'unit','encoding' {
    # PS 5.1 は BOM 無し UTF-8 を CP932 として誤解釈するため、日本語含む .ps1 は BOM 必須
    It '<file> に UTF-8 BOM がある' -TestCases @(
        $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
        $files = @()
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'client')  -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'reports') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files += Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse | Select-Object -ExpandProperty FullName
        $files | ForEach-Object { @{ file = $_ } }
    ) {
        param($file)
        $b = [System.IO.File]::ReadAllBytes($file)
        $b.Length | Should -BeGreaterThan 2
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -Be $true -Because "BOM 無し: $file"
    }
}
