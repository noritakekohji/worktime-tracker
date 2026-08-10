# MasterSchema.Tests.ps1 — マスタ保存時の JSON スキーマ (配列が配列のまま保たれるか)
#
# 回帰防止の狙い:
#   _ToPSObjectDeep が `return $list.ToArray()` と書かれていたため、要素が 1 個の
#   配列が PS 5.1 の戻り値展開で剥がれ、JSON に配列ではなくスカラー/オブジェクトが
#   出力されていた。
#     roles     = @('member') -> "roles": "member"     (配列でない)
#     wbs_items = @(1 件)     -> "wbs_items": { ... }   (配列でない)
#     processes / task_groups / tasks も同様
#   ツール内では @() で囲んで読むため動いてしまい、壊れているのは
#   「ファイルの中身」だけ。他の読み手やスキーマ検証で初めて露見する。
#   そのため型ではなく「保存された JSON テキスト」を直接検証する。

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    . (Join-Path $script:RepoRoot 'client/lib/Config.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/Credential.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/GitLab.ps1')
    . (Join-Path $script:RepoRoot 'client/lib/DataStore.ps1')

    function New-TempDataSource {
        $tmp = Join-Path $env:TEMP ("worktime-schema-test-" + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $cfg = [pscustomobject]@{ mode='local'; member_id='ut'; local_store=$tmp }
        return [pscustomobject]@{ Source = (New-DataSource -Config $cfg); Dir = $tmp }
    }
    function Remove-TempDataSource {
        param($Ctx)
        if ($Ctx -and $Ctx.Dir) { Remove-Item -LiteralPath $Ctx.Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 保存された生 JSON を読む (ツールの読込経路を通さずファイルの実体を見る)
    function Get-RawMaster {
        param($Ctx, [string]$Name)
        return [System.IO.File]::ReadAllText((Join-Path $Ctx.Dir "master\$Name"),
                                             [System.Text.UTF8Encoding]::new($false))
    }
    # 壊れた形の生 JSON を直接書き込む (本番に既にあるファイルの再現用)
    function Write-RawMaster {
        param($Ctx, [string]$Name, [string]$Json)
        [System.IO.File]::WriteAllText((Join-Path $Ctx.Dir "master\$Name"), $Json,
                                       [System.Text.UTF8Encoding]::new($false))
    }
    # JSON 上で指定プロパティが配列 ([) になっているか
    function Test-JsonPropIsArray {
        param([string]$Json, [string]$Prop)
        $doc = $Json | ConvertFrom-Json
        foreach ($item in @($doc)) {
            if ($null -eq $item.$Prop) { continue }
            # ConvertFrom-Json は JSON 配列を Object[] に、スカラー/オブジェクトはそのまま返す
            if ($item.$Prop -isnot [System.Array]) { return $false }
        }
        return $true
    }
}

Describe 'members.roles は常に JSON 配列' -Tag 'lib','schema' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It 'ロールが 1 個でも配列で保存される' {
        # 本件の中心。1 個だけのとき "roles": "member" になっていた。
        $data = @([ordered]@{ id='M1'; name='一人'; roles=@('member'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $raw = Get-RawMaster -Ctx $script:ctx -Name 'members.json'
        $raw | Should -Not -Match '"roles"\s*:\s*"'
        (Test-JsonPropIsArray -Json $raw -Prop 'roles') | Should -BeTrue
    }

    It 'ロールが 2 個 / 3 個でも配列' {
        $data = @(
            [ordered]@{ id='M2'; name='二'; roles=@('admin','member');          active=$true },
            [ordered]@{ id='M3'; name='三'; roles=@('admin','leader','member'); active=$true }
        )
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        (Test-JsonPropIsArray -Json (Get-RawMaster -Ctx $script:ctx -Name 'members.json') -Prop 'roles') | Should -BeTrue
    }

    It 'メンバーが 1 人だけでもトップレベルは JSON 配列' {
        $data = @([ordered]@{ id='S1'; name='ひとり'; roles=@('admin'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        (Get-RawMaster -Ctx $script:ctx -Name 'members.json').TrimStart() | Should -Match '^\['
        @(Get-MasterMembers -Source $script:ctx.Source).Count | Should -Be 1
    }

    It '保存 → 読込 で roles が配列のまま復元される' {
        $data = @([ordered]@{ id='M1'; name='一人'; roles=@('admin'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        # 注意: `$x | Should -BeOfType` はパイプが配列を展開するため型判定に使えない。
        # 1 要素配列だと中身の string が流れて必ず落ちる。-is で直接判定する。
        ($m.roles -is [System.Array]) | Should -BeTrue
        @($m.roles).Count | Should -Be 1
        @($m.roles)[0] | Should -Be 'admin'
    }

    It '保存 → 読込 後も Has-Role が正しく効く' {
        # ここが壊れると AdminBtn が押せない等の silent fail になる
        $data = @(
            [ordered]@{ id='A'; name='管理者';   roles=@('admin');            active=$true },
            [ordered]@{ id='L'; name='リーダー'; roles=@('leader');           active=$true },
            [ordered]@{ id='B'; name='両方';     roles=@('admin','leader');   active=$true }
        )
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        $a = $loaded | Where-Object { $_.id -eq 'A' }
        $l = $loaded | Where-Object { $_.id -eq 'L' }
        $b = $loaded | Where-Object { $_.id -eq 'B' }
        (Has-Role -Member $a -Role 'admin')  | Should -BeTrue
        (Has-Role -Member $a -Role 'leader') | Should -BeFalse
        (Has-Role -Member $l -Role 'leader') | Should -BeTrue
        (Has-Role -Member $l -Role 'admin')  | Should -BeFalse
        (Has-Role -Member $b -Role 'admin')  | Should -BeTrue
        (Has-Role -Member $b -Role 'leader') | Should -BeTrue
    }
}

Describe '旧スキーマ (role 単一文字列) との互換' -Tag 'lib','schema' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It '旧 role="admin" のファイルを読んで admin と判定できる' {
        $json = '[{"id":"OLD","name":"旧","role":"admin","active":true}]'
        $dir = Join-Path $script:ctx.Dir 'master'
        [System.IO.File]::WriteAllText((Join-Path $dir 'members.json'), $json, [System.Text.UTF8Encoding]::new($false))
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        (Has-Role -Member $m -Role 'admin') | Should -BeTrue
        (Get-MemberRoles -Member $m) | Should -Be @('admin')
    }

    It '旧 role のメンバーを roles 配列で保存し直せる (移行経路)' {
        $json = '[{"id":"OLD","name":"旧","role":"member","active":true}]'
        [System.IO.File]::WriteAllText((Join-Path $script:ctx.Dir 'master\members.json'), $json, [System.Text.UTF8Encoding]::new($false))
        $old = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        $roles = @(Get-MemberRoles -Member $old)
        $migrated = @([ordered]@{ id=[string]$old.id; name=[string]$old.name; roles=$roles; active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $migrated -AuthorName 'ut' -AuthorEmail 'ut@local'

        $raw = Get-RawMaster -Ctx $script:ctx -Name 'members.json'
        # 1 ロールでも配列であること (移行直後が最も潰れやすい)
        $raw | Should -Not -Match '"roles"\s*:\s*"'
        (Test-JsonPropIsArray -Json $raw -Prop 'roles') | Should -BeTrue
    }

    It 'roles と role が両方あるときは roles を優先' {
        $json = '[{"id":"X","name":"両方","role":"admin","roles":["member"],"active":true}]'
        [System.IO.File]::WriteAllText((Join-Path $script:ctx.Dir 'master\members.json'), $json, [System.Text.UTF8Encoding]::new($false))
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        (Has-Role -Member $m -Role 'admin') | Should -BeFalse
        (Has-Role -Member $m -Role 'member') | Should -BeTrue
    }

    It 'roles も role も無いメンバーは member 扱い' {
        $json = '[{"id":"N","name":"無指定","active":true}]'
        [System.IO.File]::WriteAllText((Join-Path $script:ctx.Dir 'master\members.json'), $json, [System.Text.UTF8Encoding]::new($false))
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        (Get-MemberRoles -Member $m) | Should -Be @('member')
        (Has-Role -Member $m -Role 'admin') | Should -BeFalse
    }

    It 'roles が空配列でも例外にならない' {
        $json = '[{"id":"E","name":"空","roles":[],"active":true}]'
        [System.IO.File]::WriteAllText((Join-Path $script:ctx.Dir 'master\members.json'), $json, [System.Text.UTF8Encoding]::new($false))
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        { Get-MemberRoles -Member $m } | Should -Not -Throw
        (Has-Role -Member $m -Role 'admin') | Should -BeFalse
    }
}

Describe '本番に既に存在する壊れた形を読めること (後方互換の担保)' -Tag 'lib','schema','compat' {

    # 保存側の不具合により、本番のマスタには要素 1 個の配列が
    # 文字列 / オブジェクトとして書かれたファイルが既に存在する。
    # 保存側を直しても既存ファイルは残るため、読込がこれを吸収できなければ
    # 本番が動かなくなる。実際に壊れた JSON を書いて読ませる。

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It 'roles が文字列で保存されていても配列として読める' {
        Write-RawMaster -Ctx $script:ctx -Name 'members.json' `
            -Json '[{"id":"M1","name":"壊れ","roles":"admin","active":true}]'
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        ($m.roles -is [System.Array]) | Should -BeTrue
        @($m.roles).Count | Should -Be 1
        @($m.roles)[0] | Should -Be 'admin'
    }

    It 'roles が文字列でも Has-Role が正しく効く (管理者モードが開ける)' {
        Write-RawMaster -Ctx $script:ctx -Name 'members.json' `
            -Json '[{"id":"A","name":"管理","roles":"admin","active":true},{"id":"B","name":"一般","roles":"member","active":true}]'
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'A' }) -Role 'admin') | Should -BeTrue
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'B' }) -Role 'admin') | Should -BeFalse
    }

    It 'wbs_items がオブジェクトで保存されていても配列として読める' {
        Write-RawMaster -Ctx $script:ctx -Name 'projects.json' `
            -Json '[{"unit_code":"P1","project_name":"PJ1","active":true,"wbs_items":{"process_code":"DSN","task_group_code":"DB","task_code":"ERD","alias":"ER図","status":"未着手"}}]'
        $p = @(Get-MasterProjects -Source $script:ctx.Source)[0]
        ($p.wbs_items -is [System.Array]) | Should -BeTrue
        @($p.wbs_items).Count | Should -Be 1
        @($p.wbs_items)[0].task_code | Should -Be 'ERD'
    }

    It 'processes / task_groups / tasks がオブジェクトでも全階層を配列として辿れる' {
        Write-RawMaster -Ctx $script:ctx -Name 'task_patterns.json' -Json @'
[{"id":"PT1","processes":{"code":"DSN","name":"設計","task_groups":{"code":"DB","name":"DB設計","tasks":{"code":"ERD","name":"ER図"}}}}]
'@
        $pt = @(Get-MasterTaskPatterns -Source $script:ctx.Source)[0]
        ($pt.processes -is [System.Array]) | Should -BeTrue
        ($pt.processes[0].task_groups -is [System.Array]) | Should -BeTrue
        ($pt.processes[0].task_groups[0].tasks -is [System.Array]) | Should -BeTrue
        $pt.processes[0].task_groups[0].tasks[0].code | Should -Be 'ERD'
    }

    It '壊れた形と正しい形が混在していても両方読める' {
        Write-RawMaster -Ctx $script:ctx -Name 'members.json' -Json @'
[{"id":"OLD","name":"旧","role":"admin","active":true},
 {"id":"BAD","name":"壊れ","roles":"leader","active":true},
 {"id":"OK","name":"正常","roles":["admin","member"],"active":true}]
'@
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        $loaded.Count | Should -Be 3
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'OLD' }) -Role 'admin')  | Should -BeTrue
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'BAD' }) -Role 'leader') | Should -BeTrue
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'OK'  }) -Role 'member') | Should -BeTrue
    }

    It '壊れたファイルを読んで保存し直すと正しい配列に自己修復する' {
        Write-RawMaster -Ctx $script:ctx -Name 'members.json' `
            -Json '[{"id":"M1","name":"壊れ","roles":"admin","active":true}]'
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        Save-MasterMembers -Source $script:ctx.Source -Data $loaded -AuthorName 'ut' -AuthorEmail 'ut@local'
        $raw = Get-RawMaster -Ctx $script:ctx -Name 'members.json'
        $raw | Should -Not -Match '"roles"\s*:\s*"'
        (Test-JsonPropIsArray -Json $raw -Prop 'roles') | Should -BeTrue
    }

    It '壊れた wbs_items を読んで保存し直すと配列に戻る' {
        Write-RawMaster -Ctx $script:ctx -Name 'projects.json' `
            -Json '[{"unit_code":"P1","project_name":"PJ1","active":true,"wbs_items":{"process_code":"DSN","task_group_code":"DB","task_code":"ERD","alias":"","status":"未着手"}}]'
        $loaded = @(Get-MasterProjects -Source $script:ctx.Source)
        Save-MasterProjects -Source $script:ctx.Source -Data $loaded -AuthorName 'ut' -AuthorEmail 'ut@local'
        (Get-RawMaster -Ctx $script:ctx -Name 'projects.json') | Should -Not -Match '"wbs_items"\s*:\s*\{'
    }

    It 'roles が空文字でも例外にならない' {
        Write-RawMaster -Ctx $script:ctx -Name 'members.json' `
            -Json '[{"id":"E","name":"空","roles":"","active":true}]'
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        { Get-MemberRoles -Member $m } | Should -Not -Throw
        (Has-Role -Member $m -Role 'admin') | Should -BeFalse
    }

    It 'wbs_items / processes が null でも落ちない' {
        Write-RawMaster -Ctx $script:ctx -Name 'projects.json' `
            -Json '[{"unit_code":"P1","project_name":"PJ1","active":true,"wbs_items":null}]'
        Write-RawMaster -Ctx $script:ctx -Name 'task_patterns.json' `
            -Json '[{"id":"PT1","processes":null}]'
        { @(Get-MasterProjects     -Source $script:ctx.Source) } | Should -Not -Throw
        { @(Get-MasterTaskPatterns -Source $script:ctx.Source) } | Should -Not -Throw
        @((@(Get-MasterProjects -Source $script:ctx.Source)[0]).wbs_items).Count | Should -Be 0
    }
}

Describe '_AsArray (壊れた形を配列に揃えるヘルパ)' -Tag 'lib','schema','compat' {

    It '文字列は 1 要素の配列にする (char 分解しない)' {
        $r = _AsArray 'admin'
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 1
        @($r)[0] | Should -Be 'admin'
    }

    It '空文字も 1 要素として扱う' {
        $r = _AsArray ''
        @($r).Count | Should -Be 1
    }

    It '$null は空配列' {
        $r = _AsArray $null
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 0
    }

    It '既に配列ならそのまま件数を保つ' {
        # _AsArray は ,$arr を返すため、呼出結果を @() で囲むと二重ラップになる。
        # 必ず一度変数で受けること。
        $r3 = _AsArray @('a','b','c')
        @($r3).Count | Should -Be 3
        $r0 = _AsArray @()
        @($r0).Count | Should -Be 0
    }

    It '単一オブジェクトは 1 要素の配列にする' {
        $r = _AsArray ([pscustomobject]@{ code = 'X' })
        @($r).Count | Should -Be 1
        @($r)[0].code | Should -Be 'X'
    }
}

Describe 'task_patterns の入れ子配列' -Tag 'lib','schema' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It '各階層が 1 要素でも processes / task_groups / tasks が配列で保存される' {
        $pat = @(
            [ordered]@{
                id = 'PT1'
                processes = @(
                    [ordered]@{
                        code = 'DSN'; name = '設計'
                        task_groups = @(
                            [ordered]@{ code='DB'; name='DB設計'; tasks = @([ordered]@{ code='ERD'; name='ER図' }) }
                        )
                    }
                )
            }
        )
        Save-MasterTaskPatterns -Source $script:ctx.Source -Data $pat -AuthorName 'ut' -AuthorEmail 'ut@local'
        $raw = Get-RawMaster -Ctx $script:ctx -Name 'task_patterns.json'
        $raw | Should -Not -Match '"processes"\s*:\s*\{'
        $raw | Should -Not -Match '"task_groups"\s*:\s*\{'
        $raw | Should -Not -Match '"tasks"\s*:\s*\{'
    }

    It '保存 → 読込 で全階層が配列として辿れる' {
        $pat = @(
            [ordered]@{
                id = 'PT1'
                processes = @(
                    [ordered]@{
                        code = 'DSN'; name = '設計'
                        task_groups = @(
                            [ordered]@{ code='DB'; name='DB設計'; tasks = @([ordered]@{ code='ERD'; name='ER図' }) }
                        )
                    }
                )
            }
        )
        Save-MasterTaskPatterns -Source $script:ctx.Source -Data $pat -AuthorName 'ut' -AuthorEmail 'ut@local'
        $p = @(Get-MasterTaskPatterns -Source $script:ctx.Source)[0]
        ($p.processes -is [System.Array])                      | Should -BeTrue
        ($p.processes[0].task_groups -is [System.Array])       | Should -BeTrue
        ($p.processes[0].task_groups[0].tasks -is [System.Array]) | Should -BeTrue
        $p.processes[0].task_groups[0].tasks[0].code | Should -Be 'ERD'
    }

    It '複数階層 (2 工程 × 2 グループ) でも壊れない' {
        $pat = @(
            [ordered]@{
                id = 'PT2'
                processes = @(
                    [ordered]@{ code='DSN'; name='設計'; task_groups=@(
                        [ordered]@{ code='DB'; name='DB'; tasks=@([ordered]@{code='ERD';name='ER'},[ordered]@{code='DDL';name='DDL'}) }
                        [ordered]@{ code='UI'; name='UI'; tasks=@([ordered]@{code='WF';name='WF'}) }
                    )}
                    [ordered]@{ code='IMP'; name='実装'; task_groups=@(
                        [ordered]@{ code='BE'; name='BE'; tasks=@([ordered]@{code='API';name='API'}) }
                    )}
                )
            }
        )
        Save-MasterTaskPatterns -Source $script:ctx.Source -Data $pat -AuthorName 'ut' -AuthorEmail 'ut@local'
        $p = @(Get-MasterTaskPatterns -Source $script:ctx.Source)[0]
        @($p.processes).Count | Should -Be 2
        @($p.processes[0].task_groups).Count | Should -Be 2
        @($p.processes[1].task_groups[0].tasks).Count | Should -Be 1
    }
}

Describe 'projects.wbs_items の配列維持' -Tag 'lib','schema' {

    BeforeEach {
        $script:ctx = New-TempDataSource
        $projects = @(
            [ordered]@{ unit_code='P1'; project_name='PJ1'; active=$true },
            [ordered]@{ unit_code='P2'; project_name='PJ2'; active=$true }
        )
        Save-MasterProjects -Source $script:ctx.Source -Data $projects -AuthorName 'ut' -AuthorEmail 'ut@local'
    }
    AfterEach { Remove-TempDataSource $script:ctx }

    It 'wbs_items が 1 件でも配列で保存される' {
        $items = @([ordered]@{ process_code='DSN'; task_group_code='DB'; task_code='ERD'; alias='ER図'; status='未着手' })
        $null = Save-ProjectWbsItems -Source $script:ctx.Source -ProjectCode 'P1' -WbsItems $items -AuthorName 'ut' -AuthorEmail 'ut@local'
        $raw = Get-RawMaster -Ctx $script:ctx -Name 'projects.json'
        $raw | Should -Not -Match '"wbs_items"\s*:\s*\{'
    }

    It '保存 → 読込 で wbs_items が配列として辿れる' {
        $items = @([ordered]@{ process_code='DSN'; task_group_code='DB'; task_code='ERD'; alias='ER図'; status='未着手' })
        $null = Save-ProjectWbsItems -Source $script:ctx.Source -ProjectCode 'P1' -WbsItems $items -AuthorName 'ut' -AuthorEmail 'ut@local'
        $p1 = @(Get-MasterProjects -Source $script:ctx.Source) | Where-Object { $_.unit_code -eq 'P1' }
        ($p1.wbs_items -is [System.Array]) | Should -BeTrue
        @($p1.wbs_items).Count | Should -Be 1
        @($p1.wbs_items)[0].task_code | Should -Be 'ERD'
    }

    It 'wbs_items を空にしても他プロジェクトは無傷' {
        $items = @([ordered]@{ process_code='DSN'; task_group_code='DB'; task_code='ERD'; alias=''; status='未着手' })
        $null = Save-ProjectWbsItems -Source $script:ctx.Source -ProjectCode 'P1' -WbsItems $items -AuthorName 'ut' -AuthorEmail 'ut@local'
        $null = Save-ProjectWbsItems -Source $script:ctx.Source -ProjectCode 'P1' -WbsItems @() -AuthorName 'ut' -AuthorEmail 'ut@local'
        $all = @(Get-MasterProjects -Source $script:ctx.Source)
        $all.Count | Should -Be 2
        ($all | Where-Object { $_.unit_code -eq 'P2' }).project_name | Should -Be 'PJ2'
    }
}

Describe 'マスタ全種の保存 / 読込 (0 件・1 件・複数件)' -Tag 'lib','schema' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    $cases = @(
        @{ Name='members';      File='members.json';      Save='Save-MasterMembers';      Load='Get-MasterMembers' }
        @{ Name='projects';     File='projects.json';     Save='Save-MasterProjects';     Load='Get-MasterProjects' }
        @{ Name='categories';   File='categories.json';   Save='Save-MasterCategories';   Load='Get-MasterCategories' }
        @{ Name='taskpatterns'; File='task_patterns.json';Save='Save-MasterTaskPatterns'; Load='Get-MasterTaskPatterns' }
        @{ Name='holidays';     File='holidays.json';     Save='Save-MasterHolidays';     Load='Get-MasterHolidays' }
    )

    It '<Name>: 0 件を保存すると空の JSON 配列になり、読込も 0 件' -ForEach $cases {
        & $Save -Source $script:ctx.Source -Data @() -AuthorName 'ut' -AuthorEmail 'ut@local'
        (Get-RawMaster -Ctx $script:ctx -Name $File).Trim() | Should -Match '^\[\s*\]$'
        @(& $Load -Source $script:ctx.Source).Count | Should -Be 0
    }

    It '<Name>: 1 件を保存してもトップレベルは JSON 配列' -ForEach $cases {
        & $Save -Source $script:ctx.Source -Data @([ordered]@{ id='X'; code='X'; unit_code='X'; date='2026-01-01'; name='一件' }) `
                -AuthorName 'ut' -AuthorEmail 'ut@local'
        (Get-RawMaster -Ctx $script:ctx -Name $File).TrimStart() | Should -Match '^\['
        @(& $Load -Source $script:ctx.Source).Count | Should -Be 1
    }

    It '<Name>: 3 件のラウンドトリップで件数と値が保たれる' -ForEach $cases {
        $data = @(
            [ordered]@{ id='A'; code='A'; unit_code='A'; date='2026-01-01'; name='あ' }
            [ordered]@{ id='B'; code='B'; unit_code='B'; date='2026-01-02'; name='い' }
            [ordered]@{ id='C'; code='C'; unit_code='C'; date='2026-01-03'; name='う' }
        )
        & $Save -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $loaded = @(& $Load -Source $script:ctx.Source)
        $loaded.Count | Should -Be 3
        $loaded[1].name | Should -Be 'い'
    }

    It '<Name>: 未保存でも読込が 0 件で返る (例外にしない)' -ForEach $cases {
        @(& $Load -Source $script:ctx.Source).Count | Should -Be 0
    }
}

Describe '入力形式の混在に耐える (Hashtable / PSCustomObject / 入れ子)' -Tag 'lib','schema' {

    BeforeEach { $script:ctx = New-TempDataSource }
    AfterEach  { Remove-TempDataSource $script:ctx }

    It 'Hashtable と PSCustomObject が混ざっていても保存できる' {
        # AdminDialog は [ordered]、読み戻しは PSCustomObject になるため混在しうる
        $data = @(
            [ordered]@{ id='H'; name='ハッシュ'; roles=@('member'); active=$true },
            [pscustomobject]@{ id='P'; name='オブジェクト'; roles=@('admin'); active=$true }
        )
        { Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local' } | Should -Not -Throw
        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        $loaded.Count | Should -Be 2
        (Has-Role -Member ($loaded | Where-Object { $_.id -eq 'P' }) -Role 'admin') | Should -BeTrue
    }

    It '読み込んだデータをそのまま保存し直しても形が崩れない (再保存の冪等性)' {
        # 管理画面で「読込 → 無変更 → 保存」したときに壊れないこと
        $data = @([ordered]@{ id='M1'; name='一人'; roles=@('member'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $first = Get-RawMaster -Ctx $script:ctx -Name 'members.json'

        $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
        Save-MasterMembers -Source $script:ctx.Source -Data $loaded -AuthorName 'ut' -AuthorEmail 'ut@local'
        $second = Get-RawMaster -Ctx $script:ctx -Name 'members.json'

        $second | Should -Not -Match '"roles"\s*:\s*"'
        $second.Trim() | Should -Be $first.Trim()
    }

    It '3 回保存し直しても roles が配列のまま (段階的な劣化がない)' {
        $data = @([ordered]@{ id='M1'; name='一人'; roles=@('admin'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        foreach ($i in 1..3) {
            $loaded = @(Get-MasterMembers -Source $script:ctx.Source)
            Save-MasterMembers -Source $script:ctx.Source -Data $loaded -AuthorName 'ut' -AuthorEmail 'ut@local'
        }
        $raw = Get-RawMaster -Ctx $script:ctx -Name 'members.json'
        (Test-JsonPropIsArray -Json $raw -Prop 'roles') | Should -BeTrue
        (Has-Role -Member (@(Get-MasterMembers -Source $script:ctx.Source)[0]) -Role 'admin') | Should -BeTrue
    }

    It '日本語とサロゲートペアを含む値が保存 → 読込で保たれる' {
        $data = @([ordered]@{ id='J'; name='山田 太郎'; company='株式会社テスト'; roles=@('member'); active=$true })
        Save-MasterMembers -Source $script:ctx.Source -Data $data -AuthorName 'ut' -AuthorEmail 'ut@local'
        $m = @(Get-MasterMembers -Source $script:ctx.Source)[0]
        $m.name    | Should -Be '山田 太郎'
        $m.company | Should -Be '株式会社テスト'
    }
}

Describe '_ToPSObjectDeep / _ToObjectArray の単体挙動' -Tag 'lib','schema' {

    It '_ToPSObjectDeep: 1 要素配列を配列のまま返す' {
        $r = _ToPSObjectDeep @('member')
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 1
    }

    It '_ToPSObjectDeep: 空配列を配列のまま返す' {
        $r = _ToPSObjectDeep @()
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 0
    }

    It '_ToPSObjectDeep: 入れ子の 1 要素配列も剥がれない' {
        $r = _ToPSObjectDeep ([ordered]@{ items = @([ordered]@{ code = 'X' }) })
        ($r.items -is [System.Array]) | Should -BeTrue
        @($r.items).Count | Should -Be 1
        @($r.items)[0].code | Should -Be 'X'
    }

    It '_ToPSObjectDeep: スカラーはそのまま' {
        (_ToPSObjectDeep 'abc') | Should -Be 'abc'
        (_ToPSObjectDeep 42)    | Should -Be 42
        (_ToPSObjectDeep $true) | Should -BeTrue
        (_ToPSObjectDeep $null) | Should -Be $null
    }

    It '_ToObjectArray: 1 要素でも配列として返す' {
        $r = _ToObjectArray @([ordered]@{ id = 'X' })
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 1
    }

    It '_ToObjectArray: $null は空配列' {
        $r = _ToObjectArray $null
        ($r -is [System.Array]) | Should -BeTrue
        @($r).Count | Should -Be 0
    }
}
