$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $didThrow = $false
    try {
        & $Action
    }
    catch {
        $didThrow = $true
    }

    Assert-True -Condition $didThrow -Message $Message
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        & $Action
    }
    catch {
        Assert-True -Condition ($_.Exception.Message -match $Pattern) -Message $Message
        return
    }
    throw "ASSERTION FAILED: $Message"
}

$automationRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $automationRoot "lib/Autodev.Core.psm1"
Import-Module $modulePath -Force

$state = [pscustomobject]@{
    version = 1
    source = "docs/DEVELOPMENT_PLAN.md"
    milestones = @(
        [pscustomobject]@{ id = "M1"; title = "Foundation"; gate_after_task = "TASK-002" },
        [pscustomobject]@{ id = "M2"; title = "Flow"; gate_after_task = "TASK-003" }
    )
    tasks = @(
        [pscustomobject]@{
            id = "TASK-001"; title = "First"; status = "DONE"; depends_on = @()
            milestone = "M1"; source = "docs/DEVELOPMENT_PLAN.md#Task 1"
        },
        [pscustomobject]@{
            id = "TASK-002"; title = "Second"; status = "TODO"; depends_on = @("TASK-001")
            milestone = "M1"; source = "docs/DEVELOPMENT_PLAN.md#Task 2"
        },
        [pscustomobject]@{
            id = "TASK-003"; title = "Third"; status = "TODO"; depends_on = @("TASK-002")
            milestone = "M2"; source = "docs/DEVELOPMENT_PLAN.md#Task 3"
        }
    )
}

$selected = Select-AutodevTask -State $state
Assert-True -Condition ($selected.id -eq "TASK-002") -Message "default selection must return the first dependency-ready TODO task"

$state.tasks[1].status = "IN_PROGRESS"
Assert-Throws -Action { Select-AutodevTask -State $state } -Message "a normal run must reject an unfinished active task"
$resumed = Select-AutodevTask -State $state -Resume
Assert-True -Condition ($resumed.id -eq "TASK-002") -Message "Resume must select the active task"

$state.tasks[1].status = "TODO"
Assert-Throws -Action { Select-AutodevTask -State $state -Resume } -Message "Resume without an active or blocked task must not start a new TODO task"
Assert-Throws -Action { Select-AutodevTask -State $state -RequestedTask "TASK-002" -Resume } -Message "Resume with -Task must not start a TODO task"
Assert-Throws -Action { Select-AutodevTask -State $state -RequestedTask "TASK-003" } -Message "a requested task with unfinished dependencies must be rejected"

$state.tasks[1].status = "DONE"
$state.tasks[2].status = "IN_PROGRESS"
$requestedResume = Select-AutodevTask -State $state -RequestedTask "TASK-003" -Resume
Assert-True -Condition ($requestedResume.id -eq "TASK-003") -Message "Resume with -Task must select the matching active task"
$state.tasks[2].status = "BLOCKED"
$blockedResume = Select-AutodevTask -State $state -RequestedTask "TASK-003" -Resume
Assert-True -Condition ($blockedResume.id -eq "TASK-003") -Message "an explicitly requested BLOCKED task must be resumable after human resolution"

Assert-True -Condition (Test-AutodevMilestoneGate -State $state -Task $state.tasks[1]) -Message "the configured final task in a milestone must stop the pipeline"
Assert-True -Condition (-not (Test-AutodevMilestoneGate -State $state -Task $state.tasks[0])) -Message "a non-gate task must continue the pipeline"

$validReview = ConvertFrom-AutodevReviewJson -Json '{"verdict":"FIX","summary":"One issue","issues":[{"severity":"P1","file":"app.py","line":12,"problem":"Wrong branch","recommendation":"Use the validated branch"}]}'
Assert-True -Condition ($validReview.verdict -eq "FIX") -Message "valid review JSON must be parsed"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"PASS","summary":"Invalid pass","issues":[{"severity":"P1","file":"app.py","line":12,"problem":"Bug","recommendation":"Fix it"}]}'
} -Message "PASS with a blocking issue must be rejected"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"MAYBE","summary":"Unknown","issues":[]}'
} -Message "unknown review verdicts must be rejected"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"PASS","summary":"Extra","issues":[],"unexpected":true}'
} -Message "review fallback validation must reject additional properties"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"FIX","summary":"Bad line","issues":[{"severity":"P1","file":"app.py","line":0,"problem":"Bug","recommendation":"Fix"}]}'
} -Message "review issue line numbers must be positive"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"FIX","summary":"Not an array","issues":{"severity":"P1","file":"app.py","line":1,"problem":"Bug","recommendation":"Fix"}}'
} -Message "review issues must remain a JSON array when output-schema is unavailable"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"PASS","summary":42,"issues":[]}'
} -Message "review fallback validation must enforce the schema string type for summary"
Assert-Throws -Action {
    ConvertFrom-AutodevReviewJson -Json '{"verdict":"FIX","summary":"Typed","issues":[{"severity":"P1","file":7,"line":1,"problem":true,"recommendation":9}]}'
} -Message "review fallback validation must enforce string types inside issues"

$safeDiff = "+const provider = process.env.LLM_API_KEY;"
$unsafeDiff = "+LLM_API_KEY=" + "sk-test-" + ("1" * 20)
Assert-True -Condition ((Test-AutodevDiffSafety -DiffText $safeDiff).Count -eq 0) -Message "environment variable references must not be treated as leaked secrets"
Assert-True -Condition ((Test-AutodevDiffSafety -DiffText $unsafeDiff).Count -gt 0) -Message "credential-like added values must block the pipeline"
Assert-True -Condition (Test-AutodevSensitivePath -Path ".env") -Message "root .env must be blocked"
Assert-True -Condition (Test-AutodevSensitivePath -Path "config/.env.local") -Message "nested .env variants must be blocked"
Assert-True -Condition (-not (Test-AutodevSensitivePath -Path ".env.example")) -Message "the exact .env.example placeholder must be allowed"
Assert-True -Condition ((Protect-AutodevLogText -Text "Authorization: Bearer secret-value") -notmatch "secret-value") -Message "logs must redact bearer tokens"
$genericSecretFixture = "arbitrary-" + "secret-value"
Assert-True -Condition ((Protect-AutodevLogText -Text "ASR_SECRET_KEY=$genericSecretFixture") -notmatch [regex]::Escape($genericSecretFixture)) -Message "logs must redact generic secret assignments"
Assert-True -Condition (Test-AutodevProtectedInstructionPath -Path "AGENTS.md") -Message "root AGENTS.md must be treated as control-plane instructions"
Assert-True -Condition (Test-AutodevProtectedInstructionPath -Path "backend/AGENTS.md") -Message "nested AGENTS.md must be treated as control-plane instructions"
Assert-True -Condition (Test-AutodevProtectedInstructionPath -Path ".codex/rules/project.md") -Message ".codex rules must be treated as control-plane instructions"
Assert-True -Condition (-not (Test-AutodevProtectedInstructionPath -Path "backend/app/main.py")) -Message "ordinary source files must not be classified as instructions"

$imageTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("autodev-image-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $imageTestRoot -Force | Out-Null
try {
    $validPng = Join-Path $imageTestRoot "valid.png"
    $fakePng = Join-Path $imageTestRoot "fake.png"
    [System.IO.File]::WriteAllBytes($validPng, [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 0))
    [System.IO.File]::WriteAllText($fakePng, "not really an image")
    Assert-True -Condition (Test-AutodevImageSignature -Path $validPng) -Message "a PNG signature must be accepted"
    Assert-True -Condition (-not (Test-AutodevImageSignature -Path $fakePng)) -Message "an extension-only fake image must be rejected"
}
finally {
    Remove-Item -LiteralPath $imageTestRoot -Recurse -Force
}

$environmentTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("autodev-env-test-" + [guid]::NewGuid().ToString("N"))
$originalEnvironment = @{
    TEMP = $env:TEMP
    TMP = $env:TMP
    ASR_PROVIDER = $env:ASR_PROVIDER
    LLM_PROVIDER = $env:LLM_PROVIDER
    LLM_API_KEY = $env:LLM_API_KEY
}
$env:LLM_API_KEY = "sentinel-secret"
Invoke-AutodevIsolatedTestEnvironment -TempRoot $environmentTempRoot -Action {
    param($runTemp)
    Assert-True -Condition ($env:TEMP -eq $runTemp) -Message "isolated tests must use their workspace-local temp directory"
    Assert-True -Condition ($env:ASR_PROVIDER -eq "mock" -and $env:LLM_PROVIDER -eq "mock") -Message "isolated tests must force mock providers"
    Assert-True -Condition ([string]::IsNullOrEmpty($env:LLM_API_KEY)) -Message "isolated tests must remove real provider credentials"
}
Assert-True -Condition ($env:LLM_API_KEY -eq "sentinel-secret") -Message "test isolation must restore credentials after success"
Assert-True -Condition (-not (Test-Path -LiteralPath $environmentTempRoot)) -Message "test isolation must clean its temp root after success"
Assert-Throws -Action {
    Invoke-AutodevIsolatedTestEnvironment -TempRoot $environmentTempRoot -Action { param($runTemp) throw "expected" }
} -Message "the fixture action must propagate failures"
Assert-True -Condition ($env:LLM_API_KEY -eq "sentinel-secret") -Message "test isolation must restore credentials after failure"
foreach ($entry in $originalEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
}

$taskWithoutMetadata = [pscustomobject]@{ status = "TODO" }
Set-AutodevTaskStatus -Task $taskWithoutMetadata -Status "IN_PROGRESS" -Reason "started"
Assert-True -Condition ($taskWithoutMetadata.updated_at -is [string]) -Message "status updates must add optional timestamp metadata"
Assert-True -Condition ($taskWithoutMetadata.last_message -eq "started") -Message "status updates must add optional message metadata"

$validRunState = [pscustomobject]@{
    task = "TASK-003"
    git_head = "abc123"
    report_directory = "C:\project\automation\reports\run"
    fix_rounds = 2
    review_number = 3
    max_fix_rounds = 2
    workspace_fingerprint = "workspace-hash"
    runtime_fingerprint = "runtime-hash"
    report_fingerprint = "report-hash"
}
Assert-AutodevRunState -RunState $validRunState -TaskId "TASK-003" -CurrentHead "abc123" -CurrentWorkspaceFingerprint "workspace-hash" -ReportsRoot "C:\project\automation\reports"
Assert-Throws -Action {
    Assert-AutodevRunState -RunState $validRunState -TaskId "TASK-002" -CurrentHead "abc123" -CurrentWorkspaceFingerprint "workspace-hash" -ReportsRoot "C:\project\automation\reports"
} -Message "Resume must reject a run-state for another task"
Assert-Throws -Action {
    Assert-AutodevRunState -RunState $validRunState -TaskId "TASK-003" -CurrentHead "abc123" -CurrentWorkspaceFingerprint "changed-hash" -ReportsRoot "C:\project\automation\reports"
} -Message "Resume must reject workspace changes made after the last trusted checkpoint"
$invalidRoundsRunState = $validRunState.PSObject.Copy()
$invalidRoundsRunState.fix_rounds = 3
Assert-Throws -Action {
    Assert-AutodevRunState -RunState $invalidRoundsRunState -TaskId "TASK-003" -CurrentHead "abc123" -CurrentWorkspaceFingerprint "workspace-hash" -ReportsRoot "C:\project\automation\reports"
} -Message "persisted automatic fix rounds must never exceed two"
$missingMaxRunState = $validRunState.PSObject.Copy()
$missingMaxRunState.PSObject.Properties.Remove("max_fix_rounds")
Assert-Throws -Action {
    Assert-AutodevRunState -RunState $missingMaxRunState -TaskId "TASK-003" -CurrentHead "abc123" -CurrentWorkspaceFingerprint "workspace-hash" -ReportsRoot "C:\project\automation\reports"
} -Message "run-state must persist the selected maximum fix rounds"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("autodev-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $tempRoot "docs") -Force | Out-Null
try {
    @"
## Task 1：First
**目标：** First goal.
**验收：**
- [ ] It works.

## Task 2：Second
**目标：** Second goal.
**验证：** Run tests.
"@ | Set-Content -LiteralPath (Join-Path $tempRoot "docs/DEVELOPMENT_PLAN.md") -Encoding utf8

    $sourceBlock = Get-AutodevTaskSource -ProjectRoot $tempRoot -Source "docs/DEVELOPMENT_PLAN.md#Task 2"
    Assert-True -Condition ($sourceBlock -match "Second goal") -Message "task source extraction must return the requested task section"
    Assert-True -Condition ($sourceBlock -notmatch "First goal") -Message "task source extraction must not include a previous task"

    $controlFile = Join-Path $tempRoot "control.ps1"
    "Write-Output 'trusted'" | Set-Content -LiteralPath $controlFile -Encoding utf8
    $fingerprint = Get-AutodevControlPlaneFingerprint -ProjectRoot $tempRoot -RelativePaths @("control.ps1")
    Assert-AutodevControlPlaneUnchanged -ProjectRoot $tempRoot -Fingerprint $fingerprint
    "Write-Output 'tampered'" | Set-Content -LiteralPath $controlFile -Encoding utf8
    Assert-Throws -Action {
        Assert-AutodevControlPlaneUnchanged -ProjectRoot $tempRoot -Fingerprint $fingerprint
    } -Message "control-plane mutation must be detected before tests or review"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

$entryPoint = Join-Path $automationRoot "autodev.ps1"
$tokens = $null
$parseErrors = $null
$entryAst = [System.Management.Automation.Language.Parser]::ParseFile($entryPoint, [ref]$tokens, [ref]$parseErrors)
Assert-True -Condition ($parseErrors.Count -eq 0) -Message "autodev entry point must parse before Git guard integration tests"
foreach ($functionName in @(
    "Invoke-Git", "ConvertFrom-GitStatusPaths", "Get-GitChangedPaths", "Get-GitStageCandidatePaths", "Get-GitStagedPaths",
    "Get-GitUntrackedPaths", "Get-GitAddedPaths", "Get-ReviewDiff", "Test-FileContainsNullByte", "Assert-NoWorkspaceCredentialFiles",
    "Assert-SafeTaskChanges", "Get-PathContentFingerprint", "Assert-IndexMatchesWorktree"
)) {
    $definition = $entryAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-True -Condition ($null -ne $definition) -Message "Git guard function '$functionName' must exist"
    Invoke-Expression $definition.Extent.Text
}
function Assert-TrustedRuntimeAndReports { }

$nul = [char]0
$stagedRenameStatus = "R  new.txt${nul}old.txt${nul}"
$unstagedRenameStatus = " R new.txt${nul}old.txt${nul}"
Assert-True -Condition (((ConvertFrom-GitStatusPaths -RawStatus $stagedRenameStatus -IncludeUnstagedRenameSource) -join ",") -eq "new.txt") -Message "an index rename must not restage a no-longer-matching source path"
Assert-True -Condition (((ConvertFrom-GitStatusPaths -RawStatus $unstagedRenameStatus) -join ",") -eq "new.txt") -Message "Reviewer paths must canonicalize an unstaged rename to its destination"
Assert-True -Condition (((ConvertFrom-GitStatusPaths -RawStatus $unstagedRenameStatus -IncludeUnstagedRenameSource) -join ",") -eq "new.txt,old.txt") -Message "staging candidates must include the source of an unstaged rename"

$gitTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("autodev-git-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $gitTestRoot -Force | Out-Null
$originalProjectRoot = $projectRoot
try {
    $projectRoot = $gitTestRoot
    & git -C $projectRoot init --quiet
    & git -C $projectRoot config user.name "Autodev Test"
    & git -C $projectRoot config user.email "autodev-test@example.invalid"
    "reviewed-v1" | Set-Content -LiteralPath (Join-Path $projectRoot "old.txt") -Encoding utf8
    & git -C $projectRoot add old.txt
    & git -C $projectRoot commit --quiet -m "fixture"

    & git -C $projectRoot mv old.txt new.txt
    $changedRenamePaths = @(Get-GitChangedPaths)
    $stageRenamePaths = @(Get-GitStageCandidatePaths)
    $stagedRenamePaths = @(Get-GitStagedPaths)
    Assert-True -Condition (($changedRenamePaths -join ",") -eq "new.txt") -Message "reviewed rename paths must use the canonical destination"
    Assert-True -Condition (($stageRenamePaths -join ",") -eq "new.txt") -Message "already-staged renames must use the canonical destination path"
    Assert-True -Condition (($stagedRenamePaths -join ",") -eq "new.txt") -Message "staged rename paths must match canonical reviewed paths"

    $reviewedFingerprint = Get-PathContentFingerprint -Paths @("new.txt")
    "unreviewed-v2" | Set-Content -LiteralPath (Join-Path $projectRoot "new.txt") -Encoding utf8
    Assert-True -Condition ((Get-PathContentFingerprint -Paths @("new.txt")) -ne $reviewedFingerprint) -Message "same-path content changes after review must change the fingerprint"
    & git -C $projectRoot add -A -- .
    "post-stage-v3" | Set-Content -LiteralPath (Join-Path $projectRoot "new.txt") -Encoding utf8
    Assert-Throws -Action { Assert-IndexMatchesWorktree -Paths @("new.txt") } -Message "post-stage worktree changes must be rejected"

    & git -C $projectRoot add -A -- .
    & git -C $projectRoot commit --quiet -m "rename fixture"
    $largePath = Join-Path $projectRoot "large.txt"
    [System.IO.File]::WriteAllText($largePath, "x" * 200001)
    & git -C $projectRoot add large.txt
    Assert-ThrowsLike -Action { [void](Assert-SafeTaskChanges) } -Pattern "200 KB" -Message "a pre-staged new large text file must not bypass the review size limit"
}
finally {
    $projectRoot = $originalProjectRoot
    Remove-Item -LiteralPath $gitTestRoot -Recurse -Force
}

$statusBefore = git -C (Split-Path -Parent $automationRoot) status --porcelain=v1
$dryRunOutput = & $entryPoint -DryRun 2>&1 | Out-String
$dryRunExitCode = $LASTEXITCODE
$statusAfter = git -C (Split-Path -Parent $automationRoot) status --porcelain=v1
Assert-True -Condition ($dryRunExitCode -eq 0) -Message "DryRun must exit successfully"
Assert-True -Condition ($dryRunOutput -match "DryRun") -Message "DryRun must label its output"
Assert-True -Condition (($statusBefore -join "`n") -eq ($statusAfter -join "`n")) -Message "DryRun must not mutate the working tree"

Write-Host "automation tests passed"
