# test-gitlab.ps1 — Gitlab 連携の診断 (読み取り専用)
#
# 目的:
#   「取得したのに明細が無い」「日付が足りない」のように、エラーが出ないまま
#   同期が壊れるケースを切り分ける。実際の Gitlab に対して読み取りだけを行い、
#   リモートの実態・ローカルの実態・同期状態 (.sync_state.json) の 3 つを
#   突き合わせて食い違いを表示する。
#
#   -RoundTrip を付けると、Tracker と同じ経路で明細を 1 件書き込み、
#   Gitlab に送信 → 取得し直し → Report と同じ関数でフィルタ・集計して、
#   書いた明細が正しく出てくるかを通しで検証する。
#
# 安全性:
#   - 既定 (-RoundTrip なし) は完全な読み取り専用
#   - -RoundTrip の書き込み先は「実在しない検証用の年月」に限定し、実データの
#     月次ファイルには一切触れない。検証後は Gitlab 上からも自動削除する
#   - 実行前に、何をコミットするかを表示して確認を求める (-Yes で省略)
#   - トークンは伏字でしか表示しない
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File scripts\test-gitlab.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\test-gitlab.ps1 -Detail
#   powershell -ExecutionPolicy Bypass -File scripts\test-gitlab.ps1 -RoundTrip
#   powershell -ExecutionPolicy Bypass -File scripts\test-gitlab.ps1 -RoundTrip -ProjectCode ABC001
#   powershell -ExecutionPolicy Bypass -File scripts\test-gitlab.ps1 -FixState
#
# 終了コード: 0 = 問題なし / 1 = 要確認の指摘あり / 2 = 実行不能 (設定不足など)

[CmdletBinding()]
param(
    # ファイル 1 件ごとの一覧まで表示する
    [switch]$Detail,
    # Tracker 書込 → Gitlab 送信 → 取得 → Report フィルタ の通し検証を行う
    [switch]$RoundTrip,
    # 検証に使うプロジェクト (省略時は projects.json の先頭の有効プロジェクト)
    [string]$ProjectCode,
    # -RoundTrip の実行確認をスキップする
    [switch]$Yes,
    # 差分同期の状態ファイル (.sync_state.json) を削除して次回全件取得させる
    [switch]$FixState
)

# 検証用の年月。実データが存在しえない値にして、本物の月次ファイルと
# 絶対に衝突しないようにする。Report の期間フィルタからも自然に外れる。
$Script:TestYear  = 2099
$Script:TestMonth = 12

$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'client/lib'
. (Join-Path $libDir 'Credential.ps1')
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'GitLab.ps1')
. (Join-Path $libDir 'DataStore.ps1')

$Script:Findings = New-Object 'System.Collections.Generic.List[string]'

function Write-Head { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "  [OK]   $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "  [info] $M" -ForegroundColor Gray }
function Write-Ng   {
    param([string]$M)
    Write-Host "  [NG]   $M" -ForegroundColor Red
    [void]$Script:Findings.Add($M)
}
function Write-Warn {
    param([string]$M)
    Write-Host "  [warn] $M" -ForegroundColor Yellow
    [void]$Script:Findings.Add($M)
}

function Mask {
    # トークンを伏字にする。長さだけ分かれば十分。
    param([string]$s)
    if (-not $s) { return '(なし)' }
    if ($s.Length -le 8) { return ('*' * $s.Length) }
    return ($s.Substring(0,4) + ('*' * ($s.Length - 8)) + $s.Substring($s.Length - 4))
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ' WorkTime Tracker - Gitlab 診断 (読み取り専用)' -ForegroundColor Cyan
Write-Host '================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. 設定
Write-Head '1. 設定'
$cfg = Load-Config
Write-Info ("config     : {0}" -f (Get-ConfigPath))
Write-Info ("mode       : {0}" -f $cfg.mode)
Write-Info ("gitlab_url : {0}" -f $cfg.gitlab_url)
Write-Info ("project_id : {0}" -f $cfg.project_id)
Write-Info ("branch     : {0}" -f $cfg.branch)
Write-Info ("member_id  : {0}" -f $cfg.member_id)
Write-Info ("local_store: {0}" -f $cfg.local_store)

if ($cfg.mode -ne 'gitlab') {
    Write-Warn 'mode が gitlab ではありません。スタンドアローン構成では診断できません。'
    Write-Host ''
    exit 2
}
if (-not $cfg.project_id) { Write-Ng 'project_id が未設定です'; exit 2 }

$token = Get-GitLabToken
if (-not $token) {
    Write-Ng 'トークンが保存されていません (設定画面で PAT を登録してください)'
    exit 2
}
Write-Info ("token      : {0} (長さ {1})" -f (Mask $token), $token.Length)

$ctx = New-GitLabContext -BaseUrl $cfg.gitlab_url -ProjectId $cfg.project_id `
                         -Branch $cfg.branch -Token $token
$source = New-DataSource -Config $cfg -Token $token

# ---------------------------------------------------------------- 2. 接続
Write-Head '2. 接続 / 認証'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $proj = Test-GitLabConnection -Ctx $ctx
    $sw.Stop()
    Write-Ok ("接続成功: {0} (id={1})  {2} ms" -f $proj.path_with_namespace, $proj.id, $sw.ElapsedMilliseconds)
    if ($sw.ElapsedMilliseconds -gt 3000) {
        Write-Warn ("1 リクエストに {0} ms かかっています。同期が遅い主因になります。" -f $sw.ElapsedMilliseconds)
    }
} catch {
    Write-Ng ("接続失敗: {0}" -f $_.Exception.Message)
    Write-Host ''
    Write-Host '  確認: gitlab_url / project_id / PAT の有効期限とスコープ (read_repository 以上)' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- 3. tree API
Write-Head '3. tree API (ページングの健全性)'
# ここが壊れると「100 件までしか見えない」形で静かに同期が欠ける。
# recursive=true はディレクトリ項目も件数に含むため、blob だけの数と分けて出す。
$treeMaster = Get-GitLabTree -Ctx $ctx -Path 'master'
$treeData   = Get-GitLabTree -Ctx $ctx -Path 'data'

function Count-Blobs { param($Tree) @($Tree | Where-Object { $_ -and [string]$_.type -eq 'blob' }).Count }
function Count-Trees { param($Tree) @($Tree | Where-Object { $_ -and [string]$_.type -eq 'tree' }).Count }

$mAll = @($treeMaster).Count; $dAll = @($treeData).Count
Write-Info ("master/ : 全 {0} 件 (blob {1} / dir {2})" -f $mAll, (Count-Blobs $treeMaster), (Count-Trees $treeMaster))
Write-Info ("data/   : 全 {0} 件 (blob {1} / dir {2})" -f $dAll, (Count-Blobs $treeData),   (Count-Trees $treeData))

if ($dAll -eq 100) {
    Write-Ng 'data/ の tree がちょうど 100 件です。ページングが 1 ページで打ち切られている可能性が非常に高いです。'
} elseif ($dAll -gt 100) {
    Write-Ok ("100 件を超えて取得できています ({0} 件) — ページングは正常です" -f $dAll)
} else {
    Write-Info ("100 件未満のためページングは今回検証されていません ({0} 件)" -f $dAll)
}

# blob マップ (実際の同期が使う経路をそのまま通す)
$mapMaster = _RemoteBlobMap -Source $source -Path 'master'
$mapData   = _RemoteBlobMap -Source $source -Path 'data'
Write-Info ("blob マップ: master={0} 件 / data={1} 件" -f $mapMaster.Count, $mapData.Count)

# 二重ラップ事故の検出: パスに空白が入るのは配列が文字列化された証拠
foreach ($m in @(@{N='master';M=$mapMaster}, @{N='data';M=$mapData})) {
    foreach ($k in $m.M.Keys) {
        if ($k -match '\s') {
            Write-Ng ("{0} の blob マップに空白入りキーがあります (配列の二重ラップ): {1}" -f $m.N, $k)
            break
        }
    }
}
if ($mapData.Count -eq 0 -and (Count-Blobs $treeData) -gt 0) {
    Write-Ng 'tree には blob があるのに blob マップが空です。同期は何もダウンロードしません。'
}

# ---------------------------------------------------------------- 4. マスタ
Write-Head '4. マスタ (master/)'
foreach ($name in @('members.json','projects.json','categories.json','task_patterns.json','holidays.json')) {
    $rel = "master/$name"
    $onRemote = $mapMaster.ContainsKey($rel)
    $localPath = Join-Path $source.LocalRoot $rel
    $onLocal = Test-Path -LiteralPath $localPath
    if (-not $onRemote) {
        Write-Warn ("{0}: リモートに存在しません" -f $rel)
    } elseif (-not $onLocal) {
        Write-Warn ("{0}: リモートにあるがローカル未取得" -f $rel)
    } else {
        Write-Ok ("{0}" -f $rel)
    }
}

# ---------------------------------------------------------------- 5. 実績データ
Write-Head '5. 実績データ (data/)'
# data/YYYY/MM/<member_id>.json を年月・メンバーで俯瞰する
$byMember = @{}
$byMonth  = @{}
foreach ($rel in $mapData.Keys) {
    if ($rel -notmatch '^data/(\d{4})/(\d{2})/(.+)\.json$') { continue }
    $ym  = "$($Matches[1])-$($Matches[2])"
    $mid = $Matches[3]
    if (-not $byMember.ContainsKey($mid)) { $byMember[$mid] = 0 }
    if (-not $byMonth.ContainsKey($ym))   { $byMonth[$ym]   = 0 }
    $byMember[$mid]++
    $byMonth[$ym]++
}
Write-Info ("メンバー数 {0} / 対象月 {1} / ファイル {2}" -f $byMember.Count, $byMonth.Count, $mapData.Count)

if ($byMonth.Count -gt 0) {
    Write-Host '  月別ファイル数:' -ForegroundColor Gray
    foreach ($ym in ($byMonth.Keys | Sort-Object)) {
        Write-Host ("    {0} : {1,3} 件" -f $ym, $byMonth[$ym]) -ForegroundColor Gray
    }
}
if ($byMember.Count -gt 0) {
    Write-Host '  メンバー別ファイル数:' -ForegroundColor Gray
    foreach ($mid in ($byMember.Keys | Sort-Object)) {
        Write-Host ("    {0,-16} : {1,3} 件" -f $mid, $byMember[$mid]) -ForegroundColor Gray
    }
}

# members.json に居るのに data が 1 件も無いメンバーを洗い出す
$localMembers = @(Get-MasterMembers -Source $source)
if ($localMembers.Count -gt 0) {
    $noData = @()
    foreach ($m in $localMembers) {
        if (-not $m -or -not $m.id) { continue }
        if ($null -ne $m.active -and -not $m.active) { continue }
        if (-not $byMember.ContainsKey([string]$m.id)) { $noData += ("{0} ({1})" -f $m.id, $m.name) }
    }
    if ($noData.Count -gt 0) {
        Write-Info ("リモートに実績ファイルが無いメンバー: " + ($noData -join ', '))
    }
}

# ---------------------------------------------------------------- 6. ローカルとの突き合わせ
Write-Head '6. リモートとローカルの突き合わせ'
$state = _LoadSyncState -Source $source
$statePath = _SyncStatePath -Source $source
Write-Info ("同期状態: {0} (pull {1} 件 / push {2} 件)" -f $statePath, $state.pull.Count, $state.push.Count)

$missingLocal = New-Object 'System.Collections.Generic.List[string]'
$staleLocal   = New-Object 'System.Collections.Generic.List[string]'
$upToDate = 0
foreach ($rel in ($mapData.Keys | Sort-Object)) {
    $dst = Join-Path $source.LocalRoot $rel
    if (-not (Test-Path -LiteralPath $dst)) { [void]$missingLocal.Add($rel); continue }
    # 状態ファイルの SHA がリモートと一致しなければ、次回取得で落ちてくる = 今は古い
    if ($state.pull[$rel] -ne [string]$mapData[$rel]) { [void]$staleLocal.Add($rel); continue }
    $upToDate++
}
Write-Info ("最新 {0} 件 / 未取得 {1} 件 / 古い(要更新) {2} 件" -f $upToDate, $missingLocal.Count, $staleLocal.Count)

if ($missingLocal.Count -gt 0) {
    Write-Warn ("ローカルに無いファイルが {0} 件あります。Report で明細が欠けます。" -f $missingLocal.Count)
    $show = if ($Detail) { $missingLocal } else { $missingLocal | Select-Object -First 10 }
    foreach ($x in $show) { Write-Host "      - $x" -ForegroundColor DarkYellow }
    if (-not $Detail -and $missingLocal.Count -gt 10) {
        Write-Host ("      ... 他 {0} 件 (-Detail で全件表示)" -f ($missingLocal.Count - 10)) -ForegroundColor DarkGray
    }
}
if ($staleLocal.Count -gt 0) {
    Write-Info ("次回の「📥 取得」で更新される見込みのファイル: {0} 件" -f $staleLocal.Count)
    if ($Detail) { foreach ($x in $staleLocal) { Write-Host "      - $x" -ForegroundColor DarkGray } }
}

# ---------------------------------------------------------------- 7. 実ダウンロード検証
Write-Head '7. 実ダウンロード検証 (1 ファイルのみ)'
# tree に載っているファイルを 1 つだけ実際に取得し、中身が読めるか確認する。
# ここが通れば「一覧は取れるが本体が取れない」系の切り分けができる。
$sample = @($mapData.Keys | Sort-Object | Select-Object -First 1)
if ($sample.Count -eq 0) {
    Write-Warn 'data/ に .json が 1 件もありません'
} else {
    $rel = $sample[0]
    try {
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Get-GitLabFileRaw -Ctx $ctx -Path $rel
        $sw2.Stop()
        if ($null -eq $raw) {
            Write-Ng ("{0}: tree にあるのに 404 です" -f $rel)
        } else {
            $doc = $raw | ConvertFrom-Json
            $n = @($doc.entries).Count
            Write-Ok ("{0}: {1} bytes / entries {2} 件 / {3} ms" -f $rel, $raw.Length, $n, $sw2.ElapsedMilliseconds)
            if ($doc.member_id) { Write-Info ("member_id={0} updated_at={1}" -f $doc.member_id, $doc.updated_at) }
        }
    } catch {
        Write-Ng ("{0}: 取得失敗 {1}" -f $rel, $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 8. ラウンドトリップ
if ($RoundTrip) {
    Write-Head '8. Tracker 書込 → Gitlab → Report フィルタ の通し検証'

    # Report の判定関数を「実物のまま」使う。ここでロジックを書き写すと
    # 検証にならない (コピーが正しいことしか確かめられない) ため、
    # ReportViewer.ps1 の AST から必要な関数定義だけを取り出して評価する。
    $viewer = Join-Path (Split-Path $PSScriptRoot -Parent) 'reports/ReportViewer.ps1'
    $wanted = @(
        '_BuildMasterIndexes','_MergeCodeName','_SumBy','_ProjectWorkType',
        'Resolve-MemberName','Resolve-MemberDisplay','Resolve-MemberCompany',
        'Resolve-ProjectName','Resolve-ProjectDisplay','Resolve-ProjectTargetSystem',
        'Resolve-CategoryName','Resolve-CategoryDisplay',
        'Resolve-ProjectTaskPattern','Resolve-ProcessName','Resolve-TaskGroupName','Resolve-TaskName'
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($viewer, [ref]$null, [ref]$null)
    $defs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))
    Write-Info ("Report の判定関数 {0} 個を ReportViewer.ps1 から読み込みました" -f @($defs).Count)

    # 検証対象のプロジェクトを決める
    $projects = @(Get-MasterProjects -Source $source)
    $target = $null
    if ($ProjectCode) {
        $target = $projects | Where-Object { [string]$_.unit_code -eq $ProjectCode } | Select-Object -First 1
        if (-not $target) { Write-Ng ("プロジェクト {0} が projects.json にありません" -f $ProjectCode); exit 1 }
    } else {
        $target = $projects | Where-Object { $_ -and $_.unit_code -and ($null -eq $_.active -or $_.active) } | Select-Object -First 1
        if (-not $target) { Write-Ng 'projects.json に有効なプロジェクトがありません'; exit 1 }
    }
    $projCode = [string]$target.unit_code
    $memberId = [string]$cfg.member_id
    $rel = Get-MonthRelPath -MemberId $memberId -Year $Script:TestYear -Month $Script:TestMonth

    # マスタ索引が参照する変数を用意 (Report と同じ形)
    $Script:Members     = @(Get-MasterMembers     -Source $source)
    $Script:Projects    = $projects
    $Script:Categories  = @(Get-MasterCategories  -Source $source)
    $Script:TaskPatterns= @(Get-MasterTaskPatterns -Source $source)
    $Script:_Idx = $null

    Write-Host ''
    Write-Host '  --- この内容を Gitlab にコミットします ---' -ForegroundColor Yellow
    Write-Host ("    パス      : {0}" -f $rel) -ForegroundColor Yellow
    Write-Host ("    メンバー  : {0}" -f $memberId) -ForegroundColor Yellow
    Write-Host ("    プロジェクト: {0}  {1}" -f $projCode, $target.project_name) -ForegroundColor Yellow
    Write-Host ("    年月      : {0}/{1} (検証専用。実データと衝突しません)" -f $Script:TestYear, $Script:TestMonth) -ForegroundColor Yellow
    Write-Host '    検証後、このファイルは Gitlab 上から自動削除します' -ForegroundColor Yellow
    Write-Host ''
    if (-not $Yes) {
        $ans = Read-Host '  続行しますか? (y/N)'
        if ($ans -ne 'y' -and $ans -ne 'Y') {
            Write-Info '中止しました (何も書き込んでいません)'
            exit 0
        }
    }

    $testDate  = '{0:D4}-{1:D2}-15' -f $Script:TestYear, $Script:TestMonth
    $testHours = 3.25
    $marker    = 'worktime-tracker 診断: 自動生成 (削除して構いません)'
    $cleanupNeeded = $false

    try {
        # --- 手順 1: Tracker と同じ経路でローカル保存 ---
        $entry = [pscustomobject]@{
            date            = $testDate
            project_code    = $projCode
            process_code    = ''
            task_group_code = ''
            task_code       = ''
            category        = ''
            is_leave        = $false
            hours           = $testHours
            comment         = $marker
        }
        Save-EntriesGrouped -Source $source -MemberId $memberId -AllEntries @($entry) `
            -ViewYear $Script:TestYear -ViewMonth $Script:TestMonth `
            -AuthorName 'diagnostic' -AuthorEmail "$memberId@worktime-tracker.local"
        $cleanupNeeded = $true
        Write-Ok ("1. ローカル保存 (Tracker と同じ Save-EntriesGrouped): {0}" -f $rel)

        # --- 手順 2: Gitlab へ送信 ---
        $localText = Get-DataFile -Source $source -RelPath $rel
        $null = Set-GitLabFile -Ctx $ctx -Path $rel -Content $localText `
            -CommitMessage 'diagnostic: round-trip test (auto-generated)' `
            -AuthorName 'diagnostic' -AuthorEmail "$memberId@worktime-tracker.local"
        Write-Ok '2. Gitlab へ送信'

        # --- 手順 3: ローカルを消して、取得で戻ってくるか確かめる ---
        $localPath = Join-Path $source.LocalRoot $rel
        Remove-Item -LiteralPath $localPath -Force
        $st = _LoadSyncState -Source $source
        [void]$st.pull.Remove($rel)
        _SaveSyncState -Source $source -State $st
        Write-Ok '3. ローカルを削除 (取得が本当に効いているか確認するため)'

        $pull = Sync-Pull-AllData -Source $source
        if (-not (Test-Path -LiteralPath $localPath)) {
            Write-Ng ("4. 取得してもローカルに戻りません (Pulled={0} Skipped={1} Total={2})" -f $pull.Pulled, $pull.Skipped, $pull.Total)
            foreach ($e in @($pull.Errors)) { Write-Host "        $e" -ForegroundColor Red }
        } else {
            Write-Ok ("4. 取得で復元 (更新 {0} 件 / 据置 {1} 件 / 全 {2} 件)" -f $pull.Pulled, $pull.Skipped, $pull.Total)
        }

        # --- 手順 5: Report と同じ経路で読み込む ---
        $all = @(Load-AllEntries-Local -Source $source)
        $hit = @($all | Where-Object {
            [string]$_.member_id -eq $memberId -and
            [string]$_.date -eq $testDate -and
            [string]$_.project_code -eq $projCode
        })
        if ($hit.Count -eq 0) {
            Write-Ng '5. Load-AllEntries-Local で明細が見つかりません (Report にも出ません)'
        } else {
            Write-Ok ("5. Report の読込経路で検出: {0} 件" -f $hit.Count)
        }

        # --- 手順 6: Report と同じ判定関数でフィルタを検証 ---
        if ($hit.Count -gt 0) {
            $row = $hit[0]
            $pc  = [string]$row.project_code
            $mid = [string]$row.member_id

            $sys  = Resolve-ProjectTargetSystem $pc
            $wt   = _ProjectWorkType $pc
            $co   = Resolve-MemberCompany $mid
            $mdsp = Resolve-MemberDisplay $mid
            $pdsp = Resolve-ProjectDisplay $pc
            Write-Info ("メンバー表示 : {0}" -f $mdsp)
            Write-Info ("プロジェクト : {0}" -f $pdsp)
            Write-Info ("対象システム : {0}" -f $(if ($sys) { $sys } else { '(未設定)' }))
            Write-Info ("業務種別     : {0}" -f $wt)
            Write-Info ("会社         : {0}" -f $(if ($co) { $co } else { '(未設定)' }))

            # 名称が解決できない = Report にコードだけが並ぶ状態
            if ($mdsp -eq $mid) { Write-Warn ("メンバー {0} が members.json で解決できません (Report にコードだけ表示されます)" -f $mid) }
            if ($pdsp -eq $pc)  { Write-Warn ("プロジェクト {0} が projects.json で解決できません" -f $pc) }

            # Apply-Filters と同じ判定を、同じ関数を使って確認する
            $checks = @(
                @{ N='メンバー一致';       Pass = ($mid -eq $memberId) }
                @{ N='メンバー不一致で除外'; Pass = -not ('__no_such_member__' -eq $mid) }
                @{ N='プロジェクト一致';   Pass = ($pc -eq $projCode) }
                @{ N='システム一致';       Pass = (-not $sys) -or ((Resolve-ProjectTargetSystem $pc) -eq $sys) }
                @{ N='業務種別一致';       Pass = ((_ProjectWorkType $pc) -eq $wt) }
                @{ N='会社一致';           Pass = ((Resolve-MemberCompany $mid) -eq $co) }
            )
            foreach ($c in $checks) {
                if ($c.Pass) { Write-Ok ("6. フィルタ {0}" -f $c.N) } else { Write-Ng ("6. フィルタ {0} が期待どおりに動きません" -f $c.N) }
            }

            # 期間フィルタ: 検証月に入ること / 別月では外れること
            $d = [datetime]::MinValue
            [void][datetime]::TryParse([string]$row.date, [ref]$d)
            $inRange  = ($d -ge (Get-Date "$($Script:TestYear)-$($Script:TestMonth)-01")) -and ($d -le (Get-Date "$($Script:TestYear)-$($Script:TestMonth)-28"))
            $outRange = ($d -lt (Get-Date '2000-01-01'))
            if ($inRange -and -not $outRange) { Write-Ok '6. フィルタ 期間 (対象月に入り、範囲外では外れる)' }
            else { Write-Ng '6. 期間フィルタが期待どおりに動きません' }

            # --- 手順 7: 集計 (Report のサマリと同じ _SumBy) ---
            $sum = _SumBy $hit 'member_id' 'メンバー' { param($k) Resolve-MemberDisplay $k }
            if ($sum -isnot [System.Collections.IEnumerable] -or $sum -is [string]) {
                Write-Ng '7. _SumBy が配列を返していません (1 行のとき ItemsSource 代入で落ちます)'
            } elseif (@($sum).Count -ne 1) {
                Write-Ng ("7. 集計行数が 1 ではありません: {0}" -f @($sum).Count)
            } elseif ([double]$sum[0].工数 -ne $testHours) {
                Write-Ng ("7. 集計工数が一致しません: 期待 {0} / 実際 {1}" -f $testHours, $sum[0].工数)
            } else {
                Write-Ok ("7. 集計 (メンバー別): {0} / 件数 {1} / 工数 {2} h" -f $sum[0].メンバー, $sum[0].件数, $sum[0].工数)
            }
        }
    } catch {
        Write-Ng ("ラウンドトリップ中に例外: {0}" -f $_.Exception.Message)
        Write-Host ("      $($_.ScriptStackTrace)") -ForegroundColor DarkGray
    } finally {
        # --- 後片付け: 検証用ファイルをリモート・ローカル双方から消す ---
        Write-Host ''
        Write-Info '後片付け中...'
        try {
            $removed = Remove-GitLabFile -Ctx $ctx -Path $rel `
                -CommitMessage 'diagnostic: remove round-trip test file' `
                -AuthorName 'diagnostic' -AuthorEmail "$memberId@worktime-tracker.local"
            if ($removed) { Write-Ok ("Gitlab から削除: {0}" -f $rel) }
            else { Write-Info ("Gitlab には既にありません: {0}" -f $rel) }
        } catch {
            Write-Ng ("Gitlab の検証用ファイル削除に失敗しました。手動で削除してください: {0}  ({1})" -f $rel, $_.Exception.Message)
        }
        if ($cleanupNeeded) {
            $lp = Join-Path $source.LocalRoot $rel
            if (Test-Path -LiteralPath $lp) { Remove-Item -LiteralPath $lp -Force }
            $st2 = _LoadSyncState -Source $source
            [void]$st2.pull.Remove($rel)
            [void]$st2.push.Remove($rel)
            _SaveSyncState -Source $source -State $st2
            Write-Ok 'ローカルの検証用ファイルと同期状態を削除'
        }
    }
}

# ---------------------------------------------------------------- 9. 状態ファイルのリセット
if ($FixState) {
    Write-Head '9. 同期状態のリセット'
    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Ok ("削除しました: {0}" -f $statePath)
        Write-Info '次回の「📥 取得」で全ファイルを取り直します。'
    } else {
        Write-Info '状態ファイルはありません (既に全件取得の状態です)'
    }
}

# ---------------------------------------------------------------- まとめ
Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
if ($Script:Findings.Count -eq 0) {
    Write-Host ' 結果: 問題は見つかりませんでした' -ForegroundColor Green
    Write-Host '================================================' -ForegroundColor Cyan
    Write-Host ''
    exit 0
}
Write-Host (" 結果: 要確認 {0} 件" -f $Script:Findings.Count) -ForegroundColor Yellow
Write-Host '================================================' -ForegroundColor Cyan
$i = 0
foreach ($f in $Script:Findings) { $i++; Write-Host ("  {0}. {1}" -f $i, $f) -ForegroundColor Yellow }
Write-Host ''
Write-Host ' ヒント: ローカルが古い/欠けている場合は -FixState で同期状態を' -ForegroundColor Gray
Write-Host '         リセットしてから Report の「📥 取得」を実行してください。' -ForegroundColor Gray
Write-Host ''
exit 1
