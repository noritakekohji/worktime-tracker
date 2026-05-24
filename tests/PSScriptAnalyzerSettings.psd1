@{
    # worktime-tracker 向け PSScriptAnalyzer 設定
    #
    # CI/Pester で fail させたいのは「真のバグになりやすい」高シグナルルールだけ。
    # WPF + PS5.1 という制約上、PSAvoidGlobalVars / PSUseApprovedVerbs 等は
    # 設計上避けられないためスキップ。
    #
    # 違反が出たらまず修正、どうしても無理ならコード側に SuppressMessageAttribute を付ける。

    Severity = @('Error','Warning')

    IncludeRules = @(
        # 真のバグになりやすいもの
        'PSAvoidAssignmentToAutomaticVariable'   # $matches / $error / $args 等への代入禁止
        'PSUseCmdletCorrectly'                   # Mandatory パラメータの省略など
        'PSUseDeclaredVarsMoreThanAssignments'   # 未使用変数 = タイポ警告
        'PSAvoidUsingPlainTextForPassword'       # パスワード平文渡し
        'PSAvoidUsingComputerNameHardcoded'      # ハードコーディングされたホスト名
        'PSAvoidUsingInvokeExpression'           # 任意コード実行リスク
        'PSAvoidNullOrEmptyHelpMessageAttribute' # ヘルプ未設定
        'PSAvoidUsingPositionalParameters'       # New-Object 引数解釈の事故 (Binding問題で実害発生)
        'PSMissingModuleManifestField'
        'PSPossibleIncorrectComparisonWithNull'  # $x -eq $null は左辺コレクションで誤動作
        'PSPossibleIncorrectUsageOfAssignmentOperator'   # if ($x = 1) 等
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSUseBOMForUnicodeEncodedFile'
        'PSUseLiteralInitializerForHashtable'
        'PSUseOutputTypeCorrectly'
        'PSUseUTF8EncodingForHelpFile'
    )

    # 個別抑制 (現状ではゼロ。必要に応じて追加)
    ExcludeRules = @()
}
