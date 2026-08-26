Set-StrictMode -Version Latest

function Get-AutodevTaskById {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [Parameter(Mandatory)]
        [string]$TaskId
    )

    $matches = @($State.tasks | Where-Object { $_.id -eq $TaskId })
    if ($matches.Count -ne 1) {
        throw "Task '$TaskId' was not found exactly once in the automation state."
    }

    return $matches[0]
}

function Assert-AutodevState {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    $allowedStatuses = @("TODO", "IN_PROGRESS", "REVIEW", "FIXING", "DONE", "BLOCKED")
    $ids = @{}

    foreach ($task in @($State.tasks)) {
        foreach ($requiredProperty in @("id", "title", "status", "depends_on", "milestone", "source")) {
            if ($null -eq $task.PSObject.Properties[$requiredProperty]) {
                throw "Task state is missing required property '$requiredProperty'."
            }
        }

        if ($ids.ContainsKey($task.id)) {
            throw "Duplicate task id '$($task.id)' in automation state."
        }
        $ids[$task.id] = $true

        if ($task.status -notin $allowedStatuses) {
            throw "Task '$($task.id)' has unsupported status '$($task.status)'."
        }
    }

    foreach ($task in @($State.tasks)) {
        foreach ($dependency in @($task.depends_on)) {
            if (-not $ids.ContainsKey($dependency)) {
                throw "Task '$($task.id)' depends on unknown task '$dependency'."
            }
        }
    }
}

function Assert-AutodevRunState {
    param(
        [Parameter(Mandatory)]
        [psobject]$RunState,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        [string]$CurrentHead,
        [Parameter(Mandatory)]
        [string]$CurrentWorkspaceFingerprint,
        [Parameter(Mandatory)]
        [string]$ReportsRoot
    )

    foreach ($requiredProperty in @(
        "task", "git_head", "report_directory", "fix_rounds", "review_number", "max_fix_rounds",
        "workspace_fingerprint", "runtime_fingerprint", "report_fingerprint"
    )) {
        if ($null -eq $RunState.PSObject.Properties[$requiredProperty]) {
            throw "Run-state is missing required property '$requiredProperty'."
        }
    }
    if ($RunState.task -ne $TaskId) {
        throw "Run-state belongs to '$($RunState.task)', not '$TaskId'."
    }
    if ($RunState.git_head -ne $CurrentHead) {
        throw "Git HEAD changed since the task run started."
    }
    if ([string]::IsNullOrWhiteSpace([string]$RunState.workspace_fingerprint)) {
        throw "Run-state workspace_fingerprint must not be empty."
    }
    if ($RunState.workspace_fingerprint -ne $CurrentWorkspaceFingerprint) {
        throw "Workspace changes differ from the last trusted automatic checkpoint."
    }
    foreach ($fingerprintProperty in @("runtime_fingerprint", "report_fingerprint")) {
        if ([string]::IsNullOrWhiteSpace([string]$RunState.$fingerprintProperty)) {
            throw "Run-state $fingerprintProperty must not be empty."
        }
    }
    if (($RunState.fix_rounds -isnot [int]) -and ($RunState.fix_rounds -isnot [long])) {
        throw "Run-state fix_rounds must be an integer."
    }
    if ([int]$RunState.fix_rounds -lt 0 -or [int]$RunState.fix_rounds -gt 2) {
        throw "Run-state fix_rounds must stay between 0 and 2."
    }
    if (($RunState.max_fix_rounds -isnot [int]) -and ($RunState.max_fix_rounds -isnot [long])) {
        throw "Run-state max_fix_rounds must be an integer."
    }
    if ([int]$RunState.max_fix_rounds -lt 0 -or [int]$RunState.max_fix_rounds -gt 2) {
        throw "Run-state max_fix_rounds must stay between 0 and 2."
    }
    if ([int]$RunState.fix_rounds -gt [int]$RunState.max_fix_rounds) {
        throw "Run-state fix_rounds exceeds max_fix_rounds."
    }
    if (($RunState.review_number -isnot [int]) -and ($RunState.review_number -isnot [long])) {
        throw "Run-state review_number must be an integer."
    }
    if ([int]$RunState.review_number -lt 1) {
        throw "Run-state review_number must be positive."
    }

    $resolvedReportsRoot = [System.IO.Path]::GetFullPath($ReportsRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $resolvedReportDirectory = [System.IO.Path]::GetFullPath([string]$RunState.report_directory)
    $reportsPrefix = $resolvedReportsRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedReportDirectory.StartsWith($reportsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Run-state report directory is outside automation/reports."
    }
}

function Assert-AutodevDependenciesComplete {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [Parameter(Mandatory)]
        [psobject]$Task
    )

    $unfinished = @()
    foreach ($dependencyId in @($Task.depends_on)) {
        $dependency = Get-AutodevTaskById -State $State -TaskId $dependencyId
        if ($dependency.status -ne "DONE") {
            $unfinished += "$dependencyId=$($dependency.status)"
        }
    }

    if ($unfinished.Count -gt 0) {
        throw "Task '$($Task.id)' has unfinished dependencies: $($unfinished -join ', ')."
    }
}

function Select-AutodevTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [string]$RequestedTask,
        [switch]$Resume
    )

    Assert-AutodevState -State $State

    $activeStatuses = @("IN_PROGRESS", "REVIEW", "FIXING")
    $activeTasks = @($State.tasks | Where-Object { $_.status -in $activeStatuses })

    if ($activeTasks.Count -gt 1) {
        throw "Automation state is invalid: more than one task is active."
    }

    if ($RequestedTask) {
        $task = Get-AutodevTaskById -State $State -TaskId $RequestedTask
        if ($task.status -eq "BLOCKED" -and -not $Resume) {
            throw "Task '$RequestedTask' is BLOCKED and requires human resolution before it can run."
        }
        if ($task.status -eq "BLOCKED" -and $activeTasks.Count -gt 0) {
            throw "Task '$($activeTasks[0].id)' is already active. It must be resolved before resuming blocked task '$RequestedTask'."
        }
        if ($task.status -eq "DONE") {
            throw "Task '$RequestedTask' is already DONE."
        }
        if ($task.status -eq "TODO" -and $Resume) {
            throw "Task '$RequestedTask' is TODO; Resume only accepts an active or BLOCKED task."
        }
        if (($task.status -in $activeStatuses) -and -not $Resume) {
            throw "Task '$RequestedTask' is already active. Re-run with -Resume."
        }
        if (($task.status -eq "TODO") -and $activeTasks.Count -gt 0) {
            throw "Task '$($activeTasks[0].id)' is already active. Resume it before starting another task."
        }

        Assert-AutodevDependenciesComplete -State $State -Task $task
        return $task
    }

    if ($activeTasks.Count -eq 1) {
        if (-not $Resume) {
            throw "Task '$($activeTasks[0].id)' is unfinished. Re-run with -Resume."
        }
        Assert-AutodevDependenciesComplete -State $State -Task $activeTasks[0]
        return $activeTasks[0]
    }

    if ($Resume) {
        $blockedTasksForResume = @($State.tasks | Where-Object { $_.status -eq "BLOCKED" })
        if ($blockedTasksForResume.Count -eq 1) {
            Assert-AutodevDependenciesComplete -State $State -Task $blockedTasksForResume[0]
            return $blockedTasksForResume[0]
        }
        if ($blockedTasksForResume.Count -gt 1) {
            throw "More than one task is BLOCKED. Use -Task with -Resume after choosing the intended task."
        }
        throw "Resume requires exactly one IN_PROGRESS, REVIEW, FIXING, or BLOCKED task."
    }

    $blockedTasks = @($State.tasks | Where-Object { $_.status -eq "BLOCKED" })
    if ($blockedTasks.Count -gt 0) {
        throw "Task '$($blockedTasks[0].id)' is BLOCKED and requires human resolution before automatic development can continue."
    }

    $nextTask = @($State.tasks | Where-Object { $_.status -eq "TODO" } | Select-Object -First 1)
    if ($nextTask.Count -eq 0) {
        return $null
    }

    Assert-AutodevDependenciesComplete -State $State -Task $nextTask[0]
    return $nextTask[0]
}

function Test-AutodevMilestoneGate {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [Parameter(Mandatory)]
        [psobject]$Task
    )

    $milestone = @($State.milestones | Where-Object { $_.id -eq $Task.milestone })
    if ($milestone.Count -ne 1) {
        throw "Task '$($Task.id)' references unknown or duplicate milestone '$($Task.milestone)'."
    }

    return $milestone[0].gate_after_task -eq $Task.id
}

function ConvertFrom-AutodevReviewJson {
    param(
        [Parameter(Mandatory)]
        [string]$Json
    )

    try {
        $review = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Reviewer output is not valid JSON: $($_.Exception.Message)"
    }

    foreach ($requiredProperty in @("verdict", "summary", "issues")) {
        if ($null -eq $review.PSObject.Properties[$requiredProperty]) {
            throw "Reviewer JSON is missing '$requiredProperty'."
        }
    }

    $topLevelProperties = @($review.PSObject.Properties.Name)
    $unexpectedTopLevel = @($topLevelProperties | Where-Object { $_ -notin @("verdict", "summary", "issues") })
    if ($unexpectedTopLevel.Count -gt 0) {
        throw "Reviewer JSON contains unsupported properties: $($unexpectedTopLevel -join ', ')."
    }

    if ($review.verdict -notin @("PASS", "FIX", "BLOCKED")) {
        throw "Reviewer verdict '$($review.verdict)' is unsupported."
    }
    if ($review.summary -isnot [string] -or [string]::IsNullOrWhiteSpace($review.summary)) {
        throw "Reviewer summary must not be empty."
    }

    if ($review.issues -isnot [System.Array]) {
        throw "Reviewer issues must be a JSON array."
    }
    $issues = @($review.issues)
    foreach ($issue in $issues) {
        foreach ($requiredProperty in @("severity", "file", "line", "problem", "recommendation")) {
            if ($null -eq $issue.PSObject.Properties[$requiredProperty]) {
                throw "Reviewer issue is missing '$requiredProperty'."
            }
        }
        $issueProperties = @($issue.PSObject.Properties.Name)
        $unexpectedIssueProperties = @($issueProperties | Where-Object { $_ -notin @("severity", "file", "line", "problem", "recommendation") })
        if ($unexpectedIssueProperties.Count -gt 0) {
            throw "Reviewer issue contains unsupported properties: $($unexpectedIssueProperties -join ', ')."
        }
        if ($issue.severity -notin @("P0", "P1", "P2", "P3")) {
            throw "Reviewer issue severity '$($issue.severity)' is unsupported."
        }
        if ($issue.problem -isnot [string] -or [string]::IsNullOrWhiteSpace($issue.problem)) {
            throw "Reviewer issue problem must not be empty."
        }
        if ($issue.file -isnot [string] -or [string]::IsNullOrWhiteSpace($issue.file)) {
            throw "Reviewer issue file must not be empty."
        }
        if ($issue.recommendation -isnot [string] -or [string]::IsNullOrWhiteSpace($issue.recommendation)) {
            throw "Reviewer issue recommendation must not be empty."
        }
        if (($null -ne $issue.line) -and ($issue.line -isnot [int]) -and ($issue.line -isnot [long])) {
            throw "Reviewer issue line must be an integer or null."
        }
        if (($null -ne $issue.line) -and ([long]$issue.line -lt 1)) {
            throw "Reviewer issue line must be positive when provided."
        }
    }

    if (($review.verdict -eq "PASS") -and (@($issues | Where-Object { $_.severity -in @("P0", "P1") }).Count -gt 0)) {
        throw "Reviewer returned PASS with a blocking P0/P1 issue."
    }
    if (($review.verdict -eq "FIX") -and $issues.Count -eq 0) {
        throw "Reviewer returned FIX without any issues."
    }

    return $review
}

function Test-AutodevDiffSafety {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DiffText
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $addedLines = @($DiffText -split "`r?`n" | Where-Object {
        $_.StartsWith("+") -and -not $_.StartsWith("+++")
    })

    foreach ($line in $addedLines) {
        if ($line -match "-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----") {
            $issues.Add("A private key marker appears in added content.")
        }
        if ($line -match "\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})\b") {
            $issues.Add("A credential-like token appears in added content.")
        }
        $assignmentPattern = @'
(?i)(?:\b[A-Za-z0-9]+_)*(?:api[_-]?key|secret(?:_key)?|password|access[_-]?token|app[_-]?id)\b\s*[:=]\s*['"]?([^\s'"]{8,})
'@
        if ($line -match $assignmentPattern) {
            $value = $Matches[1]
            if ($value -notmatch '(?i)^(?:\$\{|\$env:|process\.env|os\.getenv|env\(|example|placeholder|your[_-]|changeme|none|null)') {
                $issues.Add("A credential-like literal is assigned in added content.")
            }
        }
    }

    return @($issues | Select-Object -Unique)
}

function Test-AutodevSensitivePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path.Replace("\", "/")
    $leaf = [System.IO.Path]::GetFileName($normalized)
    if ($leaf -eq ".env.example") {
        return $false
    }
    return $leaf -eq ".env" -or $leaf.StartsWith(".env.", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-AutodevProtectedInstructionPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path.Replace("\", "/")
    while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    $normalized = $normalized.TrimStart("/")
    $leaf = [System.IO.Path]::GetFileName($normalized)
    if ($leaf.Equals("AGENTS.md", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $normalized.StartsWith(".codex/", [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalized.Contains("/.codex/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-AutodevImageSignature {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $stream = [System.IO.File]::OpenRead($Path)
    $header = [byte[]]::new(12)
    try {
        $count = $stream.Read($header, 0, $header.Length)
    }
    finally {
        $stream.Dispose()
    }

    switch ($extension) {
        ".png" {
            return $count -ge 8 -and (($header[0..7] -join ",") -eq "137,80,78,71,13,10,26,10")
        }
        { $_ -in @(".jpg", ".jpeg") } {
            return $count -ge 3 -and $header[0] -eq 255 -and $header[1] -eq 216 -and $header[2] -eq 255
        }
        ".gif" {
            if ($count -lt 6) { return $false }
            $signature = [System.Text.Encoding]::ASCII.GetString($header, 0, 6)
            return $signature -in @("GIF87a", "GIF89a")
        }
        ".webp" {
            if ($count -lt 12) { return $false }
            return [System.Text.Encoding]::ASCII.GetString($header, 0, 4) -eq "RIFF" -and
                [System.Text.Encoding]::ASCII.GetString($header, 8, 4) -eq "WEBP"
        }
        default { return $false }
    }
}

function Protect-AutodevLogText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $protected = $Text
    $protected = [regex]::Replace($protected, '(?i)Authorization:\s*Bearer\s+\S+', 'Authorization: Bearer [REDACTED]')
    $protected = [regex]::Replace($protected, '\bsk-(?:proj-)?[A-Za-z0-9_-]{12,}\b', '[REDACTED_TOKEN]')
    $protected = [regex]::Replace($protected, '\bAKIA[0-9A-Z]{16}\b', '[REDACTED_TOKEN]')
    $protected = [regex]::Replace($protected, '\bAIza[0-9A-Za-z_-]{30,}\b', '[REDACTED_TOKEN]')
    $protected = [regex]::Replace(
        $protected,
        '(?im)((?:\b[A-Za-z0-9]+_)*(?:api[_-]?key|secret(?:_key)?|password|access[_-]?token|app[_-]?id)\b\s*[:=]\s*)(["'']?)([^\s"''`;,]+)',
        { param($match) $match.Groups[1].Value + $match.Groups[2].Value + '[REDACTED]' }
    )
    return $protected
}

function Invoke-AutodevIsolatedTestEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$TempRoot,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $environmentNames = @(
        "TEMP", "TMP", "ASR_PROVIDER", "LLM_PROVIDER",
        "ASR_APP_ID", "ASR_SECRET_KEY", "LLM_API_KEY",
        "DATABASE_URL", "UPLOAD_DIR"
    )
    $originalEnvironment = @{}
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($TempRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $createdRoot = -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)
    New-Item -ItemType Directory -Path $resolvedRoot -Force | Out-Null
    $runTemp = Join-Path $resolvedRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runTemp -Force | Out-Null

    try {
        [Environment]::SetEnvironmentVariable("TEMP", $runTemp, "Process")
        [Environment]::SetEnvironmentVariable("TMP", $runTemp, "Process")
        [Environment]::SetEnvironmentVariable("ASR_PROVIDER", "mock", "Process")
        [Environment]::SetEnvironmentVariable("LLM_PROVIDER", "mock", "Process")
        foreach ($secretName in @("ASR_APP_ID", "ASR_SECRET_KEY", "LLM_API_KEY")) {
            [Environment]::SetEnvironmentVariable($secretName, $null, "Process")
        }
        $databasePath = (Join-Path $runTemp "autodev-test.db").Replace("\", "/")
        [Environment]::SetEnvironmentVariable("DATABASE_URL", "sqlite:///$databasePath", "Process")
        [Environment]::SetEnvironmentVariable("UPLOAD_DIR", (Join-Path $runTemp "uploads"), "Process")

        & $Action $runTemp
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process")
        }

        $resolvedRunTemp = [System.IO.Path]::GetFullPath($runTemp)
        $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedRunTemp.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedRunTemp -PathType Container)) {
            Remove-Item -LiteralPath $resolvedRunTemp -Recurse -Force
        }
        if ($createdRoot -and (Test-Path -LiteralPath $resolvedRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $resolvedRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $resolvedRoot -Force
        }
    }
}

function Get-AutodevControlPlaneFingerprint {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string[]]$RelativePaths
    )

    $fingerprint = [ordered]@{}
    foreach ($relativePath in $RelativePaths) {
        $absolutePath = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Control-plane file '$relativePath' does not exist."
        }
        $fingerprint[$relativePath] = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
    }
    return $fingerprint
}

function Assert-AutodevControlPlaneUnchanged {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Fingerprint
    )

    foreach ($relativePath in $Fingerprint.Keys) {
        $absolutePath = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Control-plane file '$relativePath' was removed by an Agent."
        }
        $currentHash = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
        if ($currentHash -ne $Fingerprint[$relativePath]) {
            throw "Control-plane file '$relativePath' was modified by an Agent."
        }
    }
}

function Get-AutodevTaskSource {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory)]
        [string]$Source
    )

    $separatorIndex = $Source.LastIndexOf("#")
    if ($separatorIndex -le 0 -or $separatorIndex -eq ($Source.Length - 1)) {
        throw "Task source '$Source' must use the form relative/path.md#Task heading."
    }

    $relativePath = $Source.Substring(0, $separatorIndex)
    $heading = $Source.Substring($separatorIndex + 1)
    $rootPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $rootPath $relativePath))
    $rootPrefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $sourcePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Task source must stay inside the project root."
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Task source file '$relativePath' does not exist."
    }

    $lines = @(Get-Content -LiteralPath $sourcePath)
    $escapedHeading = [regex]::Escape($heading)
    $startIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^#{1,6}\s*$escapedHeading(?:\s|[：:])") {
            $startIndex = $index
            break
        }
    }
    if ($startIndex -lt 0) {
        throw "Task heading '$heading' was not found in '$relativePath'."
    }

    $endIndex = $lines.Count
    for ($index = $startIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^#{1,6}\s*Task\s+\S+") {
            $endIndex = $index
            break
        }
    }

    $block = ($lines[$startIndex..($endIndex - 1)] -join "`n").Trim()
    if ($block -notmatch "目标") {
        throw "Task source '$Source' does not contain a goal."
    }
    if ($block -notmatch "验收|验证|测试") {
        throw "Task source '$Source' does not contain acceptance or verification criteria."
    }

    return $block
}

function Read-AutodevState {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Automation state file '$Path' does not exist."
    }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-AutodevState -State $state
    return $state
}

function Save-AutodevState {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-AutodevState -State $State
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Set-AutodevTaskStatus {
    param(
        [Parameter(Mandatory)]
        [psobject]$Task,
        [Parameter(Mandatory)]
        [ValidateSet("TODO", "IN_PROGRESS", "REVIEW", "FIXING", "DONE", "BLOCKED")]
        [string]$Status,
        [string]$Reason
    )

    $allowedTransitions = @{
        TODO = @("IN_PROGRESS", "BLOCKED")
        IN_PROGRESS = @("REVIEW", "BLOCKED")
        REVIEW = @("FIXING", "DONE", "BLOCKED")
        FIXING = @("REVIEW", "BLOCKED")
        BLOCKED = @("TODO", "IN_PROGRESS")
        DONE = @()
    }

    if ($Status -eq $Task.status) {
        return
    }
    if ($Status -notin $allowedTransitions[$Task.status]) {
        throw "Invalid task status transition: $($Task.status) -> $Status."
    }

    $Task.status = $Status
    if ($null -eq $Task.PSObject.Properties["updated_at"]) {
        $Task | Add-Member -NotePropertyName "updated_at" -NotePropertyValue $null
    }
    if ($null -eq $Task.PSObject.Properties["last_message"]) {
        $Task | Add-Member -NotePropertyName "last_message" -NotePropertyValue $null
    }
    $Task.updated_at = [DateTime]::UtcNow.ToString("o")
    if ($Reason) {
        $Task.last_message = $Reason
    }
    elseif ($null -ne $Task.PSObject.Properties["last_message"]) {
        $Task.last_message = $null
    }
}

Export-ModuleMember -Function @(
    "Assert-AutodevRunState",
    "Assert-AutodevState",
    "Assert-AutodevControlPlaneUnchanged",
    "ConvertFrom-AutodevReviewJson",
    "Get-AutodevTaskById",
    "Get-AutodevControlPlaneFingerprint",
    "Get-AutodevTaskSource",
    "Invoke-AutodevIsolatedTestEnvironment",
    "Read-AutodevState",
    "Save-AutodevState",
    "Select-AutodevTask",
    "Set-AutodevTaskStatus",
    "Protect-AutodevLogText",
    "Test-AutodevDiffSafety",
    "Test-AutodevMilestoneGate",
    "Test-AutodevImageSignature",
    "Test-AutodevProtectedInstructionPath",
    "Test-AutodevSensitivePath"
)
