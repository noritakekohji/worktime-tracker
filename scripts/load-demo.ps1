# load-demo.ps1 — worktime-tracker デモ用サンプルデータを一括投入
#
# 何を入れるか:
#   - master/members.json      4 メンバー (admin / leader / member 混在) + 退職者 1
#   - master/projects.json     4 プロジェクト (案件対応 2 + 維持運用 2) + wbs_items
#   - master/task_patterns.json 共通パターン 1 (新規 / 維持)
#   - master/categories.json   設計 / 実装 / テスト / レビュー / 打合せ / 等
#   - master/holidays.json     2026 GW + 月例
#   - data/{Y}/{M}/{member}.json  当月 + 前月の実績エントリ (休暇含む)
#
# 動作:
#   - %APPDATA%\worktime-tracker\config.json から local_store パスを取得
#   - 既存ファイルは確認後に上書き (-Force でスキップ可)
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File scripts\load-demo.ps1
#   または scripts\load-demo.cmd をダブルクリック

param(
    [string]$LocalStore = $null,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function _WriteJson {
    param([string]$Path, $Obj)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Obj -Depth 32
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  ✔ {0}" -f $Path) -ForegroundColor Green
}

# ---- local_store 解決 ----
if (-not $LocalStore) {
    $cfgPath = Join-Path $env:APPDATA 'worktime-tracker\config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg -and $cfg.local_store) { $LocalStore = [string]$cfg.local_store }
        } catch { }
    }
}
if (-not $LocalStore) {
    Write-Host "ERROR: local_store パスを特定できません。" -ForegroundColor Red
    Write-Host "  worktime-tracker を一度起動して初回設定を完了させるか、"
    Write-Host "  -LocalStore <path> オプションで指定してください。"
    exit 1
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ' worktime-tracker デモデータ投入' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "投入先: $LocalStore"
Write-Host ''
Write-Host '投入内容:'
Write-Host '  master/members.json       4 メンバー + 退職者 1'
Write-Host '  master/projects.json      4 プロジェクト (案件 2 + 維持 2)'
Write-Host '  master/task_patterns.json 共通パターン 2'
Write-Host '  master/categories.json    9 カテゴリ'
Write-Host '  master/holidays.json      2026 GW + 月例'
Write-Host '  data/YYYY/MM/*.json       4 メンバー × 当月 + 前月'
Write-Host ''

if (-not $Force) {
    $r = Read-Host '既存ファイルを上書きします。続行しますか? (y/N)'
    if ($r -notmatch '^[yY]') {
        Write-Host '中断しました' -ForegroundColor Yellow
        exit 0
    }
}

# ===== マスタ =====

# --- task_patterns ---
$patterns = @(
    [ordered]@{
        id = 'PAT-NEW'
        name = '新規開発標準パターン'
        processes = @(
            [ordered]@{ code='PLAN'; name='プロジェクト計画'; task_groups = @(
                [ordered]@{ code='REQ';  name='要件定義'; tasks=@(
                    [ordered]@{ code='HEAR'; name='ヒアリング' }
                    [ordered]@{ code='SPEC'; name='要件書作成' }
                )}
                [ordered]@{ code='SCHED'; name='スケジューリング'; tasks=@(
                    [ordered]@{ code='WBS'; name='WBS作成' }
                )}
            )}
            [ordered]@{ code='DSN'; name='設計'; task_groups = @(
                [ordered]@{ code='DB';  name='DB設計'; tasks=@(
                    [ordered]@{ code='ERD';  name='ER図作成' }
                    [ordered]@{ code='DDL';  name='DDL作成' }
                )}
                [ordered]@{ code='API'; name='API設計'; tasks=@(
                    [ordered]@{ code='IF';   name='IF定義書' }
                )}
                [ordered]@{ code='UI';  name='画面設計'; tasks=@(
                    [ordered]@{ code='MOCK'; name='モック作成' }
                )}
            )}
            [ordered]@{ code='IMP'; name='実装'; task_groups = @(
                [ordered]@{ code='BE';  name='バックエンド'; tasks=@(
                    [ordered]@{ code='ENT';  name='エンティティ' }
                    [ordered]@{ code='SVC';  name='サービス' }
                )}
                [ordered]@{ code='FE';  name='フロントエンド'; tasks=@(
                    [ordered]@{ code='CMP';  name='コンポーネント' }
                )}
            )}
            [ordered]@{ code='TST'; name='テスト'; task_groups = @(
                [ordered]@{ code='UT';  name='単体'; tasks=@(
                    [ordered]@{ code='CASE'; name='テストケース' }
                )}
                [ordered]@{ code='IT';  name='結合'; tasks=@(
                    [ordered]@{ code='SCEN'; name='シナリオ' }
                )}
            )}
        )
    }
    [ordered]@{
        id = 'PAT-OPS'
        name = '維持運用標準パターン'
        processes = @(
            [ordered]@{ code='OPS'; name='運用'; task_groups = @(
                [ordered]@{ code='MON';  name='監視'; tasks=@(
                    [ordered]@{ code='HEALTH'; name='ヘルスチェック' }
                    [ordered]@{ code='ALERT';  name='アラート対応' }
                )}
                [ordered]@{ code='HELP'; name='問合せ対応'; tasks=@(
                    [ordered]@{ code='Q&A';    name='Q&A' }
                )}
            )}
            [ordered]@{ code='INC'; name='障害対応'; task_groups = @(
                [ordered]@{ code='TRBL'; name='トラブル'; tasks=@(
                    [ordered]@{ code='ANALYZ'; name='原因分析' }
                    [ordered]@{ code='FIX';    name='恒久対策' }
                )}
            )}
            [ordered]@{ code='MNT'; name='保守'; task_groups = @(
                [ordered]@{ code='UPD'; name='アップデート'; tasks=@(
                    [ordered]@{ code='PATCH';  name='パッチ適用' }
                )}
            )}
        )
    }
)
_WriteJson (Join-Path $LocalStore 'master/task_patterns.json') $patterns

# --- members ---
$members = @(
    [ordered]@{ id='E001'; name='山田太郎'; company='株式会社サンプル'; department='開発1課'; rank='主任';
                roles=@('admin','leader','member'); active=$true }
    [ordered]@{ id='E002'; name='佐藤花子'; company='株式会社サンプル'; department='開発1課'; rank='リーダー';
                roles=@('leader','member'); active=$true }
    [ordered]@{ id='E003'; name='鈴木一郎'; company='株式会社サンプル'; department='開発2課'; rank='メンバー';
                roles=@('member'); active=$true }
    [ordered]@{ id='E004'; name='田中美咲'; company='パートナーA社'; department='運用課'; rank='リーダー';
                roles=@('leader','member'); active=$true }
    [ordered]@{ id='E099'; name='退職太郎'; company='株式会社サンプル'; department='開発1課'; rank='';
                roles=@('member'); active=$false }
)
_WriteJson (Join-Path $LocalStore 'master/members.json') $members

# --- projects (案件 2 + 維持 2) ---
$projects = @(
    [ordered]@{
        unit_code='ABC001'; project_name='ABC社 受発注システム刷新'; unit_name='次世代EC';
        target_system='ABC社受発注'; work_type='案件対応';
        period_from='2026-04-01'; period_to='2026-09-30';
        task_pattern_id='PAT-NEW'; active=$true
        wbs_items=@(
            [ordered]@{ process_code='PLAN'; task_group_code='REQ';  task_code='HEAR'; alias='初期ヒアリング';
                        status='完了';     planned_hours=8.0;  assignee='山田'; planned_start='2026-04-01'; planned_end='2026-04-05' }
            [ordered]@{ process_code='PLAN'; task_group_code='REQ';  task_code='SPEC'; alias='要件定義書';
                        status='完了';     planned_hours=24.0; assignee='山田'; planned_start='2026-04-06'; planned_end='2026-04-18' }
            [ordered]@{ process_code='DSN';  task_group_code='DB';   task_code='ERD';  alias='ER図 - 顧客マスタ';
                        status='進捗中';   planned_hours=12.0; assignee='佐藤'; planned_start='2026-04-19'; planned_end='2026-04-30' }
            [ordered]@{ process_code='DSN';  task_group_code='API';  task_code='IF';   alias='受注API';
                        status='進捗中';   planned_hours=16.0; assignee='佐藤'; planned_start='2026-05-01'; planned_end='2026-05-10' }
            [ordered]@{ process_code='IMP';  task_group_code='BE';   task_code='ENT';  alias='エンティティ実装';
                        status='未着手';   planned_hours=40.0; assignee='鈴木'; planned_start='2026-05-11'; planned_end='2026-05-31' }
            [ordered]@{ process_code='IMP';  task_group_code='FE';   task_code='CMP';  alias='画面実装';
                        status='未着手';   planned_hours=40.0; assignee='鈴木'; planned_start='2026-06-01'; planned_end='2026-06-30' }
        )
    }
    [ordered]@{
        unit_code='XYZ002'; project_name='XYZ社 在庫管理改修'; unit_name='在庫システム';
        target_system='XYZ社在庫'; work_type='案件対応';
        period_from='2026-05-01'; period_to='2026-07-31';
        task_pattern_id='PAT-NEW'; active=$true
        wbs_items=@(
            [ordered]@{ process_code='PLAN'; task_group_code='SCHED'; task_code='WBS';  alias='WBS策定';
                        status='完了';   planned_hours=4.0;  assignee='山田'; planned_start='2026-05-01'; planned_end='2026-05-02' }
            [ordered]@{ process_code='DSN';  task_group_code='UI';    task_code='MOCK'; alias='画面モック';
                        status='進捗中'; planned_hours=16.0; assignee='田中'; planned_start='2026-05-07'; planned_end='2026-05-15' }
            [ordered]@{ process_code='TST';  task_group_code='UT';    task_code='CASE'; alias='単体テストケース';
                        status='未着手'; planned_hours=20.0; assignee='田中'; planned_start='2026-06-01'; planned_end='2026-06-15' }
        )
    }
    [ordered]@{
        unit_code='OPS001'; project_name='共通基盤 運用'; unit_name='インフラ運用';
        target_system='社内共通基盤'; work_type='維持運用';
        period_from='2026-04-01'; period_to='2027-03-31';
        task_pattern_id='PAT-OPS'; active=$true
        wbs_items=@(
            [ordered]@{ process_code='OPS'; task_group_code='MON'; task_code='HEALTH'; alias='日次ヘルスチェック';
                        status='進捗中'; planned_hours=20.0; assignee='田中'; planned_start='2026-04-01'; planned_end='2027-03-31' }
            [ordered]@{ process_code='OPS'; task_group_code='HELP'; task_code='Q&A';   alias='ユーザ問合せ';
                        status='進捗中'; planned_hours=15.0; assignee='田中'; planned_start='2026-04-01'; planned_end='2027-03-31' }
            [ordered]@{ process_code='MNT'; task_group_code='UPD'; task_code='PATCH';  alias='月次パッチ';
                        status='進捗中'; planned_hours=8.0;  assignee='鈴木'; planned_start='2026-04-15'; planned_end='2027-03-15' }
        )
    }
    [ordered]@{
        unit_code='OPS002'; project_name='ABC社 障害対応窓口'; unit_name='保守サポート';
        target_system='ABC社受発注'; work_type='維持運用';
        period_from='2026-04-01'; period_to='2027-03-31';
        task_pattern_id='PAT-OPS'; active=$true
        wbs_items=@(
            [ordered]@{ process_code='INC'; task_group_code='TRBL'; task_code='ANALYZ'; alias='原因分析';
                        status='進捗中'; planned_hours=12.0; assignee='佐藤'; planned_start='2026-04-01'; planned_end='2027-03-31' }
            [ordered]@{ process_code='INC'; task_group_code='TRBL'; task_code='FIX';    alias='恒久対策実施';
                        status='進捗中'; planned_hours=8.0;  assignee='佐藤'; planned_start='2026-04-01'; planned_end='2027-03-31' }
        )
    }
)
_WriteJson (Join-Path $LocalStore 'master/projects.json') $projects

# --- categories ---
$categories = @(
    [ordered]@{ code='DESIGN';  name='設計' }
    [ordered]@{ code='CODE';    name='実装' }
    [ordered]@{ code='TEST';    name='テスト' }
    [ordered]@{ code='REVIEW';  name='レビュー' }
    [ordered]@{ code='MEETING'; name='打合せ' }
    [ordered]@{ code='DOC';     name='ドキュメント' }
    [ordered]@{ code='STUDY';   name='学習・調査' }
    [ordered]@{ code='OPS';     name='運用業務' }
    [ordered]@{ code='OTHER';   name='その他' }
)
_WriteJson (Join-Path $LocalStore 'master/categories.json') $categories

# --- holidays (2026 GW + 月例) ---
$holidays = @(
    [ordered]@{ date='2026-04-29'; name='昭和の日' }
    [ordered]@{ date='2026-05-03'; name='憲法記念日' }
    [ordered]@{ date='2026-05-04'; name='みどりの日' }
    [ordered]@{ date='2026-05-05'; name='こどもの日' }
    [ordered]@{ date='2026-05-06'; name='振替休日' }
    [ordered]@{ date='2026-07-20'; name='海の日' }
    [ordered]@{ date='2026-08-11'; name='山の日' }
    [ordered]@{ date='2026-09-21'; name='敬老の日' }
    [ordered]@{ date='2026-09-23'; name='秋分の日' }
)
_WriteJson (Join-Path $LocalStore 'master/holidays.json') $holidays

# ===== 実績データ =====
# 当月 + 前月 で、各メンバーに変化のあるデータを投入
$today = [datetime]::Today
$months = @(
    (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddMonths(-1)
    (Get-Date -Year $today.Year -Month $today.Month -Day 1)
)

# entry テンプレ生成
function _Entry {
    param($Date,$Pj,$Proc,$Tg,$Tc,$Cat,$Hours,$Comment,[bool]$Leave=$false)
    return [ordered]@{
        date            = $Date
        project_code    = $Pj
        process_code    = $Proc
        task_group_code = $Tg
        task_code       = $Tc
        category        = $Cat
        is_leave        = $Leave
        hours           = $Hours
        comment         = $Comment
    }
}

# 営業日 (土日休業日除く) を列挙
function _BusinessDays {
    param([datetime]$From, [datetime]$To, [string[]]$Holidays)
    $holSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($h in $Holidays) { [void]$holSet.Add($h) }
    $list = New-Object 'System.Collections.Generic.List[datetime]'
    $cur = $From
    while ($cur -le $To) {
        $isWk = ($cur.DayOfWeek -ne 'Saturday' -and $cur.DayOfWeek -ne 'Sunday')
        if ($isWk -and -not $holSet.Contains($cur.ToString('yyyy-MM-dd'))) {
            [void]$list.Add($cur)
        }
        $cur = $cur.AddDays(1)
    }
    return $list
}

$holDates = $holidays | ForEach-Object { [string]$_.date }
$rand = New-Object System.Random 42   # 再現性のためシード固定

# メンバー × 月ごとの「やり方」プロファイル
$profiles = @{
    'E001' = @{  # 山田: 案件 (ABC) リード ＋ 打合せ多め
        projects = @('ABC001')
        weights  = @(@{ proc='PLAN'; tg='REQ';  tc='SPEC'; cat='MEETING'; w=3 },
                     @{ proc='PLAN'; tg='SCHED';tc='WBS';  cat='DOC';     w=2 },
                     @{ proc='DSN';  tg='DB';   tc='ERD';  cat='REVIEW';  w=2 },
                     @{ proc='DSN';  tg='API';  tc='IF';   cat='DESIGN';  w=2 })
    }
    'E002' = @{  # 佐藤: ABC設計 + 障害対応
        projects = @('ABC001','OPS002')
        weights  = @(@{ proc='DSN';  tg='DB';   tc='ERD';  cat='DESIGN';  w=3 },
                     @{ proc='DSN';  tg='API';  tc='IF';   cat='DESIGN';  w=3 },
                     @{ proc='INC';  tg='TRBL'; tc='ANALYZ';cat='OPS';    w=2 },
                     @{ proc='INC';  tg='TRBL'; tc='FIX';  cat='CODE';    w=1 })
    }
    'E003' = @{  # 鈴木: ABC実装 + パッチ
        projects = @('ABC001','OPS001')
        weights  = @(@{ proc='IMP';  tg='BE';   tc='ENT';  cat='CODE';    w=4 },
                     @{ proc='IMP';  tg='FE';   tc='CMP';  cat='CODE';    w=2 },
                     @{ proc='MNT';  tg='UPD';  tc='PATCH';cat='OPS';     w=1 })
    }
    'E004' = @{  # 田中: 運用メイン + XYZ画面
        projects = @('OPS001','XYZ002')
        weights  = @(@{ proc='OPS';  tg='MON';  tc='HEALTH';cat='OPS';    w=3 },
                     @{ proc='OPS';  tg='HELP'; tc='Q&A';   cat='OPS';    w=2 },
                     @{ proc='DSN';  tg='UI';   tc='MOCK';  cat='DESIGN'; w=2 })
    }
}
# 重み付きランダム選択
function _PickWeighted { param($Items, $Rand)
    $total = 0; foreach ($it in $Items) { $total += [int]$it.w }
    $r = $Rand.Next(0, $total)
    foreach ($it in $Items) { $r -= [int]$it.w; if ($r -lt 0) { return $it } }
    return $Items[0]
}

foreach ($mStart in $months) {
    $mEnd = $mStart.AddMonths(1).AddDays(-1)
    $businessDays = _BusinessDays -From $mStart -To $mEnd -Holidays $holDates

    foreach ($mid in $profiles.Keys) {
        $prof = $profiles[$mid]
        $entries = New-Object 'System.Collections.Generic.List[object]'

        # 各営業日に 1-3 エントリ (合計 6-8h 程度)
        foreach ($d in $businessDays) {
            $dstr = $d.ToString('yyyy-MM-dd')
            # 月に 1 回程度の有給休暇 (15%)
            if ($rand.NextDouble() -lt 0.05) {
                [void]$entries.Add( (_Entry -Date $dstr -Pj '' -Proc '' -Tg '' -Tc '' -Cat '' -Hours 8.0 -Comment '有給休暇' -Leave $true) )
                continue
            }
            # 1 日のエントリ数 (1-3)
            $n = $rand.Next(1, 4)
            $remain = 7.5
            for ($i = 0; $i -lt $n; $i++) {
                $pick = _PickWeighted $prof.weights $rand
                $proj = $prof.projects[$rand.Next(0, $prof.projects.Count)]
                if ($i -eq $n - 1) { $h = [Math]::Round($remain, 2) }
                else { $h = [Math]::Round((1.0 + $rand.NextDouble() * 3.0), 1); $remain -= $h }
                if ($h -le 0) { continue }
                $com = ''
                if ($pick.cat -eq 'MEETING') { $com = '定例ミーティング' }
                elseif ($pick.cat -eq 'REVIEW') { $com = 'コードレビュー' }
                elseif ($pick.cat -eq 'CODE') { $com = '実装作業' }
                [void]$entries.Add(
                    (_Entry -Date $dstr -Pj $proj -Proc $pick.proc -Tg $pick.tg -Tc $pick.tc -Cat $pick.cat -Hours $h -Comment $com)
                )
            }
        }

        $doc = [ordered]@{
            member_id = $mid
            year      = $mStart.Year
            month     = $mStart.Month
            entries   = $entries.ToArray()
        }
        $relPath = ('data/{0:D4}/{1:D2}/{2}.json' -f $mStart.Year, $mStart.Month, $mid)
        _WriteJson (Join-Path $LocalStore $relPath) $doc
    }
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ' デモデータ投入完了' -ForegroundColor Green
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '次の手順:'
Write-Host '  1. WorkTime Tracker / WBS / Report を起動して動作確認'
Write-Host '  2. config.json の member_id を E001-E004 のどれかに切替えると'
Write-Host '     ロール別 (admin/leader/member) の挙動を試せます'
Write-Host '  3. Gitlab モードならまだリモートに push されていないので、'
Write-Host '     必要に応じて Tracker から 📤 送信、または管理画面から保存'
Write-Host ''
