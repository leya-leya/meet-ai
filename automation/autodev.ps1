[CmdletBinding()]
param(
    [switch]$Resume,
    [Alias("TaskId")]
    [string]$Task,
    [switch]$NoCommit,
    [switch]$DryRun,
    [switch]$AcceptHumanChanges,
    [ValidateRange(0, 2)]
    [int]$MaxFixRounds = 2,
    [ValidateRange(1, 1440)]
    [int]$AgentTimeoutMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$automationRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $automationRoot
$statePath = Join-Path $automationRoot "state/tasks.json"
$runStateDirectory = Join-Path $projectRoot ".git/autodev"
$runStatePath = Join-Path $runStateDirectory "current-run.json"
$reportsRoot = Join-Path $automationRoot "reports"
$schemaPath = Join-Path $automationRoot "schemas/review-result.schema.json"
$testScript = Join-Path $automationRoot "test.ps1"
$script:currentState = $null
$script:currentTask = $null
$script:runDirectory = $null
$script:runState = $null
$script:taskStarted = $false
$script:taskCommitCreated = $false
$script:preserveRunStateOnFailure = $false
$script:protectedInstructionPaths = @()
$script:runStateExistedAtInvocation = Test-Path -LiteralPath $runStatePath -PathType Leaf

Import-Module (Join-Path $automationRoot "lib/Autodev.Core.psm1") -Force

$script:controlPlanePaths = @(
    ".gitignore",
    "docs/PRODUCT_SPEC.md",
    "automation/autodev.ps1",
    "automation/test.ps1",
    "automation/lib/Autodev.Core.psm1",
    "automation/prompts/developer.md",
    "automation/prompts/reviewer.md",
    "automation/prompts/fixer.md",
    "automation/schemas/review-result.schema.json"
)
$script:controlPlaneFingerprint = Get-AutodevControlPlaneFingerprint -ProjectRoot $projectRoot -RelativePaths $script:controlPlanePaths

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & git -C $projectRoot @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$output"
    }

    return [pscustomobject]@{
        Output = $output.TrimEnd()
        ExitCode = $exitCode
    }
}

function Write-RunFile {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [AllowEmptyString()]
        [string]$Content
    )

    if (-not $script:runDirectory) {
        return
    }
    if ($script:runState) {
        Assert-RunReportsUnchanged
    }
    Protect-AutodevLogText -Text $Content | Set-Content -LiteralPath (Join-Path $script:runDirectory $Name) -Encoding utf8
    Update-RunReportCheckpoint
}

function Save-CurrentRunState {
    if ($null -eq $script:runState) {
        return
    }
    if (-not (Test-Path -LiteralPath $runStateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $runStateDirectory -Force | Out-Null
    }
    $temporaryPath = "$runStatePath.tmp"
    $script:runState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $runStatePath -Force
}

function Get-RunStateFileHash {
    if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
        throw "Trusted run-state '$runStatePath' is missing."
    }
    return (Get-FileHash -LiteralPath $runStatePath -Algorithm SHA256).Hash
}

function Get-FileTreeFingerprint {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [switch]$ExcludeRuntimeCaches
    )

    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Trusted directory '$root' is missing."
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
            $relativePath = [System.IO.Path]::GetRelativePath($projectRoot, $file.FullName).Replace("\", "/")
            if ($ExcludeRuntimeCaches -and (
                $relativePath -match '(?i)(?:^|/)__pycache__(?:/|$)' -or
                $relativePath.StartsWith("frontend/node_modules/.vite/", [System.StringComparison]::OrdinalIgnoreCase) -or
                $relativePath.StartsWith("frontend/node_modules/.cache/", [System.StringComparison]::OrdinalIgnoreCase)
            )) {
                continue
            }
            $entries.Add("$relativePath`n$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)")
        }
    }
    $payload = @($entries | Sort-Object) -join "`n"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)))
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-TestRuntimeFingerprint {
    return Get-FileTreeFingerprint -Roots @(
        (Join-Path $projectRoot "backend/.venv"),
        (Join-Path $projectRoot "frontend/node_modules")
    ) -ExcludeRuntimeCaches
}

function Get-RunReportFingerprint {
    if (-not $script:runDirectory) {
        return "NO_REPORT_DIRECTORY"
    }
    return Get-FileTreeFingerprint -Roots @($reportsRoot)
}

function Update-RunReportCheckpoint {
    if ($null -eq $script:runState -or -not $script:runDirectory) {
        return
    }
    $script:runState.report_fingerprint = Get-RunReportFingerprint
    Save-CurrentRunState
}

function Assert-TestRuntimeUnchanged {
    if ((Get-TestRuntimeFingerprint) -ne [string]$script:runState.runtime_fingerprint) {
        throw "BLOCKED: ignored test runtime files changed during the automatic task."
    }
}

function Assert-RunReportsUnchanged {
    if ((Get-RunReportFingerprint) -ne [string]$script:runState.report_fingerprint) {
        throw "BLOCKED: existing automatic task reports were changed outside the orchestrator."
    }
}

function Assert-TrustedRuntimeAndReports {
    Assert-TestRuntimeUnchanged
    Assert-RunReportsUnchanged
}

function Remove-CurrentRunState {
    if (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
        Remove-Item -LiteralPath $runStatePath -Force
    }
}

function Get-CodexCapabilities {
    param([switch]$AllowUnavailable)

    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        if ($AllowUnavailable) {
            return [pscustomobject]@{ Available = $false; Reason = "codex command was not found" }
        }
        throw "BLOCKED: Codex CLI was not found in PATH."
    }

    try {
        $versionOutput = & $command.Source --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "codex --version exited with code $LASTEXITCODE"
        }
        $helpOutput = & $command.Source exec --help 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "codex exec --help exited with code $LASTEXITCODE"
        }
        $testSandboxHelp = & $command.Source sandbox windows --help 2>&1 | Out-String
        $testSandboxExitCode = $LASTEXITCODE
    }
    catch {
        if ($AllowUnavailable) {
            return [pscustomobject]@{ Available = $false; Reason = $_.Exception.Message }
        }
        throw "BLOCKED: Codex CLI capability detection failed: $($_.Exception.Message)"
    }

    $capabilities = [pscustomobject]@{
        Available = $true
        Reason = $null
        Path = $command.Source
        Version = $versionOutput.Trim()
        Help = $helpOutput
        HasEphemeral = $helpOutput.Contains("--ephemeral")
        HasSandbox = $helpOutput.Contains("--sandbox")
        HasOutputLastMessage = $helpOutput.Contains("--output-last-message") -or $helpOutput.Contains("-o,")
        HasOutputSchema = $helpOutput.Contains("--output-schema")
        HasModel = $helpOutput.Contains("--model")
        HasWindowsTestSandbox = $testSandboxExitCode -eq 0 -and $testSandboxHelp.Contains("--full-auto")
        TestSandboxHelp = $testSandboxHelp
    }

    if (-not $capabilities.HasSandbox -and -not $AllowUnavailable) {
        throw "BLOCKED: This Codex CLI does not expose --sandbox; minimum role permissions cannot be enforced."
    }

    return $capabilities
}

function Invoke-CodexAgent {
    param(
        [Parameter(Mandatory)]
        [psobject]$Capabilities,
        [Parameter(Mandatory)]
        [ValidateSet("developer", "reviewer", "fixer", "smoke")]
        [string]$Role,
        [Parameter(Mandatory)]
        [string]$Prompt,
        [Parameter(Mandatory)]
        [ValidateSet("read-only", "workspace-write")]
        [string]$Sandbox,
        [string]$OutputSchema,
        [string]$Model
    )

    if (-not $Capabilities.Available) {
        throw "Codex CLI is unavailable: $($Capabilities.Reason)"
    }
    if ($Model -and -not $Capabilities.HasModel) {
        throw "A model override was requested for $Role, but this Codex CLI does not support --model."
    }
    Assert-NoWorkspaceCredentialFiles
    Assert-TaskControlPlaneUnchanged
    Assert-TrustedRuntimeAndReports

    $finalOutputPath = Join-Path $runStateDirectory "$Role-final.tmp"
    if (Test-Path -LiteralPath $finalOutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $finalOutputPath -Force
    }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add("exec")
    if ($Capabilities.HasEphemeral) {
        $arguments.Add("--ephemeral")
    }
    if ($Capabilities.HasSandbox) {
        $arguments.Add("--sandbox")
        $arguments.Add($Sandbox)
    }
    if ($Capabilities.HasOutputLastMessage) {
        $arguments.Add("--output-last-message")
        $arguments.Add($finalOutputPath)
    }
    if ($OutputSchema -and $Capabilities.HasOutputSchema) {
        $arguments.Add("--output-schema")
        $arguments.Add($OutputSchema)
    }
    if ($Model) {
        $arguments.Add("--model")
        $arguments.Add($Model)
    }
    $arguments.Add("-")

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Capabilities.Path
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($credentialName in @("ASR_APP_ID", "ASR_SECRET_KEY", "LLM_API_KEY")) {
        [void]$startInfo.Environment.Remove($credentialName)
    }
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $runStateHashBeforeAgent = Get-RunStateFileHash

    try {
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start Codex $Role agent."
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Prompt)
    $process.StandardInput.Close()

    $timeoutMilliseconds = $AgentTimeoutMinutes * 60 * 1000
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
        try {
            $process.Kill($true)
        }
        catch {
            $process.Kill()
        }
        Assert-NoWorkspaceCredentialFiles
        Assert-TaskControlPlaneUnchanged
        Assert-TrustedRuntimeAndReports
        if ((Get-RunStateFileHash) -ne $runStateHashBeforeAgent) {
            throw "BLOCKED: Codex $Role agent modified trusted run-state metadata."
        }
        throw "Codex $Role agent timed out after $AgentTimeoutMinutes minutes."
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $cliLog = "STDOUT`n$stdout`nSTDERR`n$stderr"
    Assert-NoWorkspaceCredentialFiles
    Assert-TaskControlPlaneUnchanged
    Assert-TrustedRuntimeAndReports
    if ((Get-RunStateFileHash) -ne $runStateHashBeforeAgent) {
        throw "BLOCKED: Codex $Role agent modified trusted run-state metadata."
    }
    Write-RunFile -Name "$Role-cli.txt" -Content $cliLog

    if ($process.ExitCode -ne 0) {
        throw "Codex $Role agent exited with code $($process.ExitCode). See $Role-cli.txt."
    }

    if ($Capabilities.HasOutputLastMessage -and (Test-Path -LiteralPath $finalOutputPath -PathType Leaf)) {
        $finalOutput = Get-Content -LiteralPath $finalOutputPath -Raw
        Remove-Item -LiteralPath $finalOutputPath -Force
    }
    else {
        $finalOutput = $stdout
    }

    if ([string]::IsNullOrWhiteSpace($finalOutput)) {
        throw "Codex $Role agent returned an empty final response."
    }

    if ($Role -in @("developer", "fixer")) {
        Update-RunWorkspaceCheckpoint
    }
    elseif ($Role -eq "reviewer" -and $script:runState) {
        $currentFingerprint = Get-WorkspaceFingerprint
        if ($currentFingerprint -ne $script:runState.workspace_fingerprint) {
            throw "BLOCKED: the read-only Reviewer changed the workspace; its result was rejected."
        }
    }
    return Protect-AutodevLogText -Text $finalOutput.Trim()
    }
    finally {
        if (Test-Path -LiteralPath $finalOutputPath -PathType Leaf) {
            Remove-Item -LiteralPath $finalOutputPath -Force
        }
    }
}

function Assert-GitRepositoryReady {
    param([switch]$ForResume)

    $topLevel = (Invoke-Git -Arguments @("rev-parse", "--show-toplevel")).Output
    if ([System.IO.Path]::GetFullPath($topLevel) -ne [System.IO.Path]::GetFullPath($projectRoot)) {
        throw "BLOCKED: automation must run from the repository rooted at '$projectRoot'."
    }

    $branch = (Invoke-Git -Arguments @("branch", "--show-current")).Output
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw "BLOCKED: Git is in detached HEAD state."
    }

    $unmerged = (Invoke-Git -Arguments @("diff", "--name-only", "--diff-filter=U")).Output
    if (-not [string]::IsNullOrWhiteSpace($unmerged)) {
        throw "BLOCKED: Git contains unmerged paths.`n$unmerged"
    }

    $gitStatus = (Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output
    if (-not $ForResume -and -not [string]::IsNullOrWhiteSpace($gitStatus)) {
        throw "BLOCKED: a new automatic task requires a clean working tree. Existing changes were not modified.`n$gitStatus"
    }
}

function Assert-NoWorkspaceCredentialFiles {
    $candidatePaths = & git -C $projectRoot ls-files -coi --exclude-standard -- ":(glob)**/.env" ":(glob)**/.env.*"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect workspace credential files."
    }
    $unsafePaths = @($candidatePaths | Where-Object { Test-AutodevSensitivePath -Path $_ } | Sort-Object -Unique)
    if ($unsafePaths.Count -gt 0) {
        throw "BLOCKED: real .env-style files are readable inside the Agent workspace. Move credentials to the parent PowerShell environment before automatic development: $($unsafePaths -join ', ')"
    }
}

function Assert-ControlPlaneMatchesHead {
    $result = Invoke-Git -Arguments (@("diff", "--quiet", "HEAD", "--") + $controlPlanePaths) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "BLOCKED: automation control-plane files differ from HEAD. Review and commit infrastructure changes manually before running or resuming autodev."
    }
}

function ConvertFrom-GitStatusPaths {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RawStatus,
        [switch]$IncludeUnstagedRenameSource
    )

    $segments = @($RawStatus -split "`0" | Where-Object { $_ })
    $paths = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $entry = $segments[$index]
        if ($entry.Length -lt 4) {
            throw "Unexpected Git porcelain entry: '$entry'."
        }
        $statusCode = $entry.Substring(0, 2)
        $paths.Add($entry.Substring(3))
        if ($statusCode -match '[RC]') {
            $index++
            if ($index -ge $segments.Count) {
                throw "Git rename/copy entry is incomplete."
            }
            if ($IncludeUnstagedRenameSource -and $statusCode.Substring(1, 1) -match '[RC]') {
                $paths.Add($segments[$index])
            }
        }
    }

    return @($paths | Sort-Object -Unique)
}

function Get-GitChangedPaths {
    $rawStatus = & git -C $projectRoot status --porcelain=v1 -z --untracked-files=all
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git changed paths."
    }
    return @(ConvertFrom-GitStatusPaths -RawStatus ([string]$rawStatus))
}

function Get-GitStageCandidatePaths {
    $rawStatus = & git -C $projectRoot status --porcelain=v1 -z --untracked-files=all
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git staging candidates."
    }

    return @(ConvertFrom-GitStatusPaths -RawStatus ([string]$rawStatus) -IncludeUnstagedRenameSource)
}

function Get-GitUntrackedPaths {
    $rawPaths = & git -C $projectRoot ls-files --others --exclude-standard -z
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git untracked paths."
    }
    return @(([string]$rawPaths) -split "`0" | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-GitAddedPaths {
    $rawPaths = & git -C $projectRoot diff HEAD --name-only --diff-filter=A -z -- .
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git added paths."
    }
    return @(([string]$rawPaths) -split "`0" | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-GitStagedPaths {
    $rawPaths = & git -C $projectRoot diff --cached --name-only -z -- .
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git staged paths."
    }
    return @(([string]$rawPaths) -split "`0" | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TaskSourceRelativePath {
    param([Parameter(Mandatory)][psobject]$Task)

    $separatorIndex = ([string]$Task.source).LastIndexOf("#")
    if ($separatorIndex -le 0) {
        throw "Task '$($Task.id)' has an invalid source path."
    }
    return ([string]$Task.source).Substring(0, $separatorIndex).Replace("\", "/")
}

function Initialize-TaskControlPlane {
    param([Parameter(Mandatory)][psobject]$Task)

    $taskSourcePath = Get-TaskSourceRelativePath -Task $Task
    $repositoryFiles = & git -C $projectRoot ls-files -co --exclude-standard
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to enumerate protected project instructions."
    }
    $ignoredInstructionFiles = & git -C $projectRoot ls-files --others --ignored --exclude-standard -- "AGENTS.md" ":(glob)**/AGENTS.md" ":(glob).codex/**" ":(glob)**/.codex/**"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to enumerate ignored protected project instructions."
    }
    $instructionPaths = @(($repositoryFiles + $ignoredInstructionFiles) | Where-Object { Test-AutodevProtectedInstructionPath -Path $_ } | Sort-Object -Unique)
    foreach ($instructionPath in $instructionPaths) {
        $trackedCheck = Invoke-Git -Arguments @("ls-files", "--error-unmatch", "--", $instructionPath) -AllowFailure
        if ($trackedCheck.ExitCode -ne 0) {
            throw "BLOCKED: protected project instruction is not committed to HEAD: $instructionPath"
        }
    }
    $protectedPaths = @($script:controlPlanePaths + $instructionPaths + $taskSourcePath | Sort-Object -Unique)

    foreach ($changedPath in @(Get-GitChangedPaths)) {
        if (($changedPath -eq $taskSourcePath) -or (Test-AutodevProtectedInstructionPath -Path $changedPath)) {
            throw "BLOCKED: protected project instruction or current Acceptance Source differs from HEAD: $changedPath"
        }
    }

    $script:protectedInstructionPaths = $instructionPaths
    $script:controlPlanePaths = $protectedPaths
    $script:controlPlaneFingerprint = Get-AutodevControlPlaneFingerprint -ProjectRoot $projectRoot -RelativePaths $script:controlPlanePaths
}

function Assert-TaskControlPlaneUnchanged {
    $repositoryFiles = & git -C $projectRoot ls-files -co --exclude-standard
    if ($LASTEXITCODE -ne 0) { throw "Unable to re-enumerate protected project instructions." }
    $ignoredInstructionFiles = & git -C $projectRoot ls-files --others --ignored --exclude-standard -- "AGENTS.md" ":(glob)**/AGENTS.md" ":(glob).codex/**" ":(glob)**/.codex/**"
    if ($LASTEXITCODE -ne 0) { throw "Unable to re-enumerate ignored protected project instructions." }
    $currentInstructionPaths = @(($repositoryFiles + $ignoredInstructionFiles) | Where-Object { Test-AutodevProtectedInstructionPath -Path $_ } | Sort-Object -Unique)
    if (($currentInstructionPaths -join "`n") -ne ($script:protectedInstructionPaths -join "`n")) {
        throw "Protected AGENTS.md or .codex instruction files were added or removed by an Agent."
    }
    Assert-AutodevControlPlaneUnchanged -ProjectRoot $projectRoot -Fingerprint $script:controlPlaneFingerprint
}

function Get-WorkspaceFingerprint {
    $rawStatus = & git -C $projectRoot status --porcelain=v1 -z --untracked-files=all
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to calculate the workspace fingerprint."
    }

    $fingerprintSource = [System.Text.StringBuilder]::new()
    [void]$fingerprintSource.Append([string]$rawStatus)
    foreach ($relativePath in @(Get-GitChangedPaths)) {
        [void]$fingerprintSource.Append("`nPATH:").Append($relativePath).Append("`n")
        $absolutePath = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            $fileHash = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
            [void]$fingerprintSource.Append($fileHash)
        }
        else {
            [void]$fingerprintSource.Append("<missing>")
        }
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintSource.ToString())
        return [Convert]::ToHexString($sha256.ComputeHash($bytes))
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PathContentFingerprint {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)

    $fingerprintSource = [System.Text.StringBuilder]::new()
    foreach ($relativePath in @($Paths | Sort-Object -Unique)) {
        [void]$fingerprintSource.Append("PATH:").Append($relativePath).Append("`n")
        $absolutePath = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            [void]$fingerprintSource.Append((Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash)
        }
        else {
            [void]$fingerprintSource.Append("<missing>")
        }
        [void]$fingerprintSource.Append("`n")
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintSource.ToString())
        return [Convert]::ToHexString($sha256.ComputeHash($bytes))
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-IndexMatchesWorktree {
    param([Parameter(Mandatory)][string[]]$Paths)

    $result = Invoke-Git -Arguments (@("diff", "--quiet", "--") + $Paths) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Staged content differs from the reviewed worktree content."
    }
}

function Update-RunWorkspaceCheckpoint {
    if ($null -eq $script:runState) {
        return
    }
    $script:runState.workspace_fingerprint = Get-WorkspaceFingerprint
    Save-CurrentRunState
}

function Assert-PathSetsEqual {
    param(
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string]$Context
    )

    $expectedNormalized = @($Expected | Sort-Object -Unique)
    $actualNormalized = @($Actual | Sort-Object -Unique)
    if (($expectedNormalized -join "`n") -ne ($actualNormalized -join "`n")) {
        throw "$Context path set changed after review. Expected: $($expectedNormalized -join ', '); actual: $($actualNormalized -join ', ')."
    }
}

function Get-ReviewDiff {
    $trackedDiff = (Invoke-Git -Arguments @("diff", "HEAD", "--no-ext-diff", "--", ".")).Output
    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($relativePath in @(Get-GitChangedPaths)) {
        $absolutePath = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            continue
        }
        $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        if ($extension -in @(".png", ".jpg", ".jpeg", ".gif", ".webp")) {
            $fileInfo = Get-Item -LiteralPath $absolutePath -ErrorAction Stop
            $hash = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash
            $parts.Add("image-review-manifest: $relativePath; $($fileInfo.Length) bytes; SHA256 $hash; Reviewer must inspect this workspace file")
        }
    }

    if ($trackedDiff) {
        $parts.Add($trackedDiff)
    }

    foreach ($relativePath in @(Get-GitUntrackedPaths)) {
        $absolutePath = Join-Path $projectRoot $relativePath
        $fileInfo = Get-Item -LiteralPath $absolutePath -ErrorAction Stop
        $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        if ($extension -in @(".png", ".jpg", ".jpeg", ".gif", ".webp")) {
            continue
        }
        try {
            $content = Get-Content -LiteralPath $absolutePath -Raw -ErrorAction Stop
            $addedContent = (($content -split "`r?`n") | ForEach-Object { "+$_" }) -join "`n"
            $parts.Add("diff --autodev-untracked a/$relativePath b/$relativePath`n--- /dev/null`n+++ b/$relativePath`n$addedContent")
        }
        catch {
            $parts.Add("diff --autodev-untracked a/$relativePath b/$relativePath`n+[binary or unreadable untracked file]")
        }
    }

    return ($parts -join "`n")
}

function Test-FileContainsNullByte {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $buffer = [byte[]]::new(65536)
    try {
        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($index = 0; $index -lt $bytesRead; $index++) {
                if ($buffer[$index] -eq 0) {
                    return $true
                }
            }
        }
        return $false
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SafeTaskChanges {
    Assert-TrustedRuntimeAndReports
    Assert-NoWorkspaceCredentialFiles
    $status = (Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output
    if ([string]::IsNullOrWhiteSpace($status)) {
        throw "No task changes were produced; an empty task cannot be reviewed or committed."
    }
    if ($status -match '(?m)^(?:DD|AU|UD|UA|DU|AA|UU)') {
        throw "Git contains unmerged task changes."
    }

    $changedPaths = @(Get-GitChangedPaths)
    $untrackedPaths = @(Get-GitUntrackedPaths)
    $addedPaths = @(Get-GitAddedPaths)
    foreach ($changedPath in $changedPaths) {
        if (Test-AutodevSensitivePath -Path $changedPath) {
            throw "A real .env-style file appears in Git changes: $changedPath"
        }
        $absolutePath = Join-Path $projectRoot $changedPath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            continue
        }
        $fileInfo = Get-Item -LiteralPath $absolutePath -ErrorAction Stop
        $extension = [System.IO.Path]::GetExtension($changedPath).ToLowerInvariant()
        $isReviewableImage = $extension -in @(".png", ".jpg", ".jpeg", ".gif", ".webp")
        if ($isReviewableImage) {
            if ($fileInfo.Length -gt 5MB) {
                throw "Changed image '$changedPath' exceeds the 5 MB automatic review limit."
            }
            if (-not (Test-AutodevImageSignature -Path $absolutePath)) {
                throw "Changed image '$changedPath' does not match its declared image format."
            }
            continue
        }
        if ((($changedPath -in $untrackedPaths) -or ($changedPath -in $addedPaths)) -and $fileInfo.Length -gt 200000) {
            throw "New file '$changedPath' exceeds the 200 KB automatic text review limit."
        }
        if (Test-FileContainsNullByte -Path $absolutePath) {
            throw "Changed binary file '$changedPath' is not an allowed reviewable image."
        }
    }

    $diff = Get-ReviewDiff
    $safetyIssues = @(Test-AutodevDiffSafety -DiffText $diff)
    if ($safetyIssues.Count -gt 0) {
        throw "Potential secret detected in task changes: $($safetyIssues -join ' ')"
    }

    $numStat = (Invoke-Git -Arguments @("diff", "HEAD", "--numstat", "--", ".")).Output
    $deletedLines = 0
    $deletedFiles = 0
    foreach ($line in @($numStat -split "`r?`n" | Where-Object { $_ })) {
        $columns = $line -split "`t"
        if ($columns.Count -ge 3 -and $columns[1] -match '^\d+$') {
            $deletedLines += [int]$columns[1]
        }
        if ($columns.Count -ge 3 -and $columns[0] -eq "0" -and $columns[1] -match '^[1-9]\d*$') {
            $deletedFiles++
        }
    }
    if ($deletedFiles -gt 20 -or $deletedLines -gt 1000) {
        throw "Abnormal deletion volume detected ($deletedFiles files, $deletedLines lines)."
    }

    return $diff
}

function Invoke-ObjectiveTests {
    param([Parameter(Mandatory)][string]$OutputFile)

    Assert-TrustedRuntimeAndReports
    Assert-TaskControlPlaneUnchanged
    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $OutputFile))
    if ($resolvedOutputDirectory -ne [System.IO.Path]::GetFullPath($script:runDirectory)) {
        throw "Objective test output must stay in the current report directory."
    }
    $temporaryTestOutput = Join-Path $automationRoot "state/objective-test-$PID.tmp"
    if (Test-Path -LiteralPath $temporaryTestOutput -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryTestOutput -Force
    }

    $headBeforeTest = (Invoke-Git -Arguments @("rev-parse", "HEAD")).Output
    $indexTreeBeforeTest = (Invoke-Git -Arguments @("write-tree")).Output
    $gitConfigPath = (Invoke-Git -Arguments @("rev-parse", "--git-path", "config")).Output
    if (-not [System.IO.Path]::IsPathRooted($gitConfigPath)) {
        $gitConfigPath = Join-Path $projectRoot $gitConfigPath
    }
    $gitConfigHashBeforeTest = (Get-FileHash -LiteralPath $gitConfigPath -Algorithm SHA256).Hash
    $runStateHashBeforeTest = Get-RunStateFileHash
    $workspaceBeforeTest = Get-WorkspaceFingerprint

    try {
        $sandboxArguments = @(
            "sandbox", "windows", "--full-auto", "--",
            (Join-Path $PSHOME "pwsh.exe"), "-NoProfile", "-File", $testScript, "-OutputPath", $temporaryTestOutput
        )
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:codexCapabilities.Path
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($environmentName in @($startInfo.Environment.Keys)) {
            if ($environmentName -match '(?i)(?:KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)') {
                [void]$startInfo.Environment.Remove($environmentName)
            }
        }
        foreach ($argument in $sandboxArguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start the isolated objective test sandbox."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($AgentTimeoutMinutes * 60 * 1000)) {
            try { $process.Kill($true) } catch { $process.Kill() }
            throw "Objective tests timed out after $AgentTimeoutMinutes minutes."
        }
        $sandboxStdout = $stdoutTask.GetAwaiter().GetResult()
        $sandboxStderr = $stderrTask.GetAwaiter().GetResult()
        $passed = $process.ExitCode -eq 0

        if ((Invoke-Git -Arguments @("rev-parse", "HEAD")).Output -ne $headBeforeTest) {
            throw "BLOCKED: objective tests changed Git HEAD."
        }
        if ((Invoke-Git -Arguments @("write-tree")).Output -ne $indexTreeBeforeTest) {
            throw "BLOCKED: objective tests changed the Git index."
        }
        if ((Get-FileHash -LiteralPath $gitConfigPath -Algorithm SHA256).Hash -ne $gitConfigHashBeforeTest) {
            throw "BLOCKED: objective tests changed Git configuration."
        }
        if ((Get-RunStateFileHash) -ne $runStateHashBeforeTest) {
            throw "BLOCKED: objective tests changed trusted run-state metadata."
        }
        if ((Get-WorkspaceFingerprint) -ne $workspaceBeforeTest) {
            throw "BLOCKED: objective tests changed tracked or untracked project files."
        }
        Assert-TestRuntimeUnchanged
        Assert-RunReportsUnchanged
        Assert-NoWorkspaceCredentialFiles
        Assert-TaskControlPlaneUnchanged
        $sandboxWrapperOutput = "===== sandbox wrapper =====`nSTDOUT`n$sandboxStdout`nSTDERR`n$sandboxStderr`nexit code: $($process.ExitCode)"
        if (-not (Test-Path -LiteralPath $temporaryTestOutput -PathType Leaf)) {
            Write-RunFile -Name ([System.IO.Path]::GetFileName($OutputFile)) -Content $sandboxWrapperOutput
            throw "BLOCKED: objective test sandbox did not start or did not produce its required report file."
        }
        $testOutput = (Get-Content -LiteralPath $temporaryTestOutput -Raw) + "`n`n$sandboxWrapperOutput"
        Write-RunFile -Name ([System.IO.Path]::GetFileName($OutputFile)) -Content $testOutput
        return $passed
    }
    finally {
        if (Test-Path -LiteralPath $temporaryTestOutput -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryTestOutput -Force
        }
    }
}

function Set-TaskStatusAndSave {
    param(
        [Parameter(Mandatory)]
        [string]$Status,
        [string]$Reason
    )

    Set-AutodevTaskStatus -Task $script:currentTask -Status $Status -Reason $Reason
    Save-AutodevState -State $script:currentState -Path $statePath
    Update-RunWorkspaceCheckpoint
}

function New-AgentPrompt {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("developer", "reviewer", "fixer")]
        [string]$Role,
        [Parameter(Mandatory)]
        [string]$TaskSource,
        [string]$Diff,
        [string]$TestOutput,
        [string]$ReviewJson
    )

    $basePrompt = Get-Content -LiteralPath (Join-Path $automationRoot "prompts/$Role.md") -Raw
    $sections = [System.Collections.Generic.List[string]]::new()
    $sections.Add($basePrompt.Trim())
    $sections.Add("`n# 当前 Task`nID: $($script:currentTask.id)`n标题: $($script:currentTask.title)`n里程碑: $($script:currentTask.milestone)`n`n$TaskSource")
    if ($null -ne $TestOutput) {
        $sections.Add("`n# 客观测试结果`n$TestOutput")
    }
    if ($null -ne $Diff) {
        $sections.Add("`n# 当前完整 Git Diff（含未跟踪文本文件）`n$Diff")
    }
    if ($null -ne $ReviewJson) {
        $sections.Add("`n# Reviewer JSON`n$ReviewJson")
    }
    return $sections -join "`n"
}

function Write-BlockedReport {
    param([Parameter(Mandatory)][string]$Reason)

    $safeReason = Protect-AutodevLogText -Text $Reason
    if ($script:taskStarted -and $script:currentTask -and $script:currentTask.status -ne "BLOCKED") {
        try {
            if ($script:currentTask.status -eq "DONE" -and -not $script:taskCommitCreated) {
                $script:currentTask.status = "BLOCKED"
                $script:currentTask.updated_at = [DateTime]::UtcNow.ToString("o")
                $script:currentTask.last_message = $safeReason
                Save-AutodevState -State $script:currentState -Path $statePath
                Update-RunWorkspaceCheckpoint
            }
            elseif ($script:currentTask.status -ne "DONE") {
                Set-TaskStatusAndSave -Status "BLOCKED" -Reason $safeReason
            }
        }
        catch {
            $script:currentTask.status = "BLOCKED"
            $script:currentTask.updated_at = [DateTime]::UtcNow.ToString("o")
            $script:currentTask.last_message = $safeReason
            Save-AutodevState -State $script:currentState -Path $statePath
            Update-RunWorkspaceCheckpoint
        }
    }

    $resumeInstructions = if ($script:taskStarted -and -not $script:taskCommitCreated) {
        "人工解决原因后运行：``.\automation\autodev.ps1 -Resume -Task `"$($script:currentTask.id)`"``。Fix 轮次、基准 HEAD 和受信工作区指纹将从 .git/autodev/current-run.json 恢复并校验；如人工修改了代码，另加 -AcceptHumanChanges。"
    }
    else {
        "任务尚未开始，Task 状态没有变化。清理启动前问题后重新运行原命令。"
    }

    $report = @"
# BLOCKED_REPORT

Task: $($script:currentTask.id) $($script:currentTask.title)
Time: $([DateTime]::Now.ToString("s"))

Reason:
$safeReason

现场已保留；脚本没有 reset、clean 或丢弃任何代码。

$resumeInstructions
"@
    try {
        Write-RunFile -Name "BLOCKED_REPORT.md" -Content $report
        Write-RunFile -Name "summary.md" -Content $report
    }
    catch {
        Write-Warning "BLOCKED report was not written because existing report integrity failed: $($_.Exception.Message)"
    }
    Write-Error "BLOCKED: $safeReason"
}

function Write-MilestoneReport {
    param(
        [Parameter(Mandatory)][psobject]$Task,
        [Parameter(Mandatory)][string]$CommitSha,
        [Parameter(Mandatory)][int]$FixRounds,
        [Parameter(Mandatory)][psobject]$Review
    )

    $milestone = @($script:currentState.milestones | Where-Object { $_.id -eq $Task.milestone })[0]
    $completedTasks = @($script:currentState.tasks | Where-Object { $_.milestone -eq $Task.milestone -and $_.status -eq "DONE" } | ForEach-Object { $_.id }) -join ", "
    $failedTasks = @($script:currentState.tasks | Where-Object { $_.milestone -eq $Task.milestone -and $_.status -eq "FIXING" } | ForEach-Object { $_.id }) -join ", "
    $blockedTasks = @($script:currentState.tasks | Where-Object { $_.milestone -eq $Task.milestone -and $_.status -eq "BLOCKED" } | ForEach-Object { $_.id }) -join ", "
    $counts = @{}
    foreach ($severity in @("P0", "P1", "P2", "P3")) {
        $counts[$severity] = @($Review.issues | Where-Object { $_.severity -eq $severity }).Count
    }
    $addedFiles = (Invoke-Git -Arguments @("show", "--pretty=format:", "--name-only", "--diff-filter=A", $CommitSha)).Output
    $modifiedFiles = (Invoke-Git -Arguments @("show", "--pretty=format:", "--name-only", "--diff-filter=CDMRT", $CommitSha)).Output
    if ([string]::IsNullOrWhiteSpace($addedFiles)) { $addedFiles = "无" }
    if ([string]::IsNullOrWhiteSpace($modifiedFiles)) { $modifiedFiles = "无" }

    $report = @"
# MILESTONE REPORT

Milestone: $($milestone.id) $($milestone.title)
完成 Task: $completedTasks
失败 Task: $failedTasks
Blocked Task: $blockedTasks

Git commits:
- $CommitSha

Tests:
- backend: PASS
- frontend: PASS
- lint: 未配置独立 lint 命令
- build: PASS

Reviewer:
- P0: $($counts.P0)
- P1: $($counts.P1)
- P2: $($counts.P2)
- P3: $($counts.P3)

自动修复次数: $FixRounds

新增文件:
$addedFiles

修改/删除/重命名文件:
$modifiedFiles

人工需要重点验收:
1. 按当前 Milestone 的验收标准执行实际用户流程。
2. 核对提交只包含当前 Task。
3. 确认报告中的 P2/P3 是否需要后续处理。

已知限制:
- 自动化不访问生产环境，不执行真实 AI、支付、部署或破坏性数据库操作。
"@
    Write-RunFile -Name "MILESTONE_REPORT.md" -Content $report
    Write-RunFile -Name "summary.md" -Content $report
}

function Invoke-TaskPipeline {
    param(
        [Parameter(Mandatory)][psobject]$Capabilities,
        [Parameter(Mandatory)][string]$TaskSource
    )

    $fixRounds = [int]$script:runState.fix_rounds
    $reviewNumber = [int]$script:runState.review_number
    $developerModel = [Environment]::GetEnvironmentVariable("AUTODEV_DEV_MODEL")
    $reviewModel = [Environment]::GetEnvironmentVariable("AUTODEV_REVIEW_MODEL")

    if ($script:currentTask.status -eq "BLOCKED") {
        Set-TaskStatusAndSave -Status "IN_PROGRESS" -Reason "Human requested Resume after resolving the blocked condition."
    }
    if ($script:currentTask.status -eq "TODO") {
        Set-TaskStatusAndSave -Status "IN_PROGRESS" -Reason "Developer agent started."
        $developerPrompt = New-AgentPrompt -Role "developer" -TaskSource $TaskSource
        $developerResult = Invoke-CodexAgent -Capabilities $Capabilities -Role "developer" -Prompt $developerPrompt -Sandbox "workspace-write" -Model $developerModel
        Write-RunFile -Name "developer.md" -Content $developerResult
    }

    while ($true) {
        $testFileName = if ($fixRounds -eq 0) { "test-before-review.txt" } else { "test-after-fix-$fixRounds.txt" }
        $testPath = Join-Path $script:runDirectory $testFileName
        $testsPassed = Invoke-ObjectiveTests -OutputFile $testPath
        if ($script:currentTask.status -in @("IN_PROGRESS", "FIXING")) {
            Set-TaskStatusAndSave -Status "REVIEW" -Reason "Objective tests completed; independent review started."
        }

        $diff = Assert-SafeTaskChanges
        $pathsPresentedToReviewer = @(Get-GitChangedPaths)
        $nonStatePathsPresentedToReviewer = @($pathsPresentedToReviewer | Where-Object { $_ -ne "automation/state/tasks.json" })
        $contentPresentedToReviewer = Get-PathContentFingerprint -Paths $pathsPresentedToReviewer
        $nonStateContentPresentedToReviewer = Get-PathContentFingerprint -Paths $nonStatePathsPresentedToReviewer
        $testOutput = Get-Content -LiteralPath $testPath -Raw
        $reviewPrompt = New-AgentPrompt -Role "reviewer" -TaskSource $TaskSource -Diff $diff -TestOutput $testOutput
        $reviewResultText = Invoke-CodexAgent -Capabilities $Capabilities -Role "reviewer" -Prompt $reviewPrompt -Sandbox "read-only" -OutputSchema $schemaPath -Model $reviewModel
        Assert-PathSetsEqual -Expected $pathsPresentedToReviewer -Actual @(Get-GitChangedPaths) -Context "Reviewer"
        if ((Get-PathContentFingerprint -Paths $pathsPresentedToReviewer) -ne $contentPresentedToReviewer) {
            throw "Workspace content changed while the Reviewer was running."
        }
        $review = ConvertFrom-AutodevReviewJson -Json $reviewResultText

        if (-not $testsPassed -and $review.verdict -eq "PASS") {
            $review = [pscustomobject]@{
                verdict = "FIX"
                summary = "Automated tests failed; PASS is not allowed. $($review.summary)"
                issues = @([pscustomobject]@{
                    severity = "P1"; file = "automation test output"; line = $null
                    problem = "One or more objective test commands returned a non-zero exit code."
                    recommendation = "Fix the underlying test failures without weakening or deleting tests."
                })
            }
        }
        $reviewJson = $review | ConvertTo-Json -Depth 10
        Write-RunFile -Name "review-$reviewNumber.json" -Content $reviewJson

        if ($review.verdict -eq "BLOCKED") {
            throw "Reviewer requested human intervention: $($review.summary)"
        }
        if ($review.verdict -eq "PASS") {
            if (-not $testsPassed) {
                throw "Reviewer protocol violation: PASS was returned while objective tests failed."
            }
            return [pscustomobject]@{
                Review = $review
                FixRounds = $fixRounds
                ReviewedPaths = $pathsPresentedToReviewer
                ReviewedContentFingerprint = $contentPresentedToReviewer
                ReviewedNonStateFingerprint = $nonStateContentPresentedToReviewer
            }
        }

        if ($fixRounds -ge $MaxFixRounds) {
            throw "连续 $MaxFixRounds 轮自动修复后仍未通过 Reviewer，需要人工处理。"
        }

        $fixRounds++
        $script:runState.fix_rounds = $fixRounds
        Save-CurrentRunState
        Set-TaskStatusAndSave -Status "FIXING" -Reason "Fix round $fixRounds started."
        $fixerPrompt = New-AgentPrompt -Role "fixer" -TaskSource $TaskSource -Diff $diff -TestOutput $testOutput -ReviewJson $reviewJson
        $fixerResult = Invoke-CodexAgent -Capabilities $Capabilities -Role "fixer" -Prompt $fixerPrompt -Sandbox "workspace-write" -Model $developerModel
        Write-RunFile -Name "fix-$fixRounds.md" -Content $fixerResult
        $reviewNumber++
        $script:runState.review_number = $reviewNumber
        Save-CurrentRunState
    }
}

try {
    if ($AcceptHumanChanges -and -not $Resume) {
        throw "-AcceptHumanChanges is only valid together with -Resume."
    }
    $script:currentState = Read-AutodevState -Path $statePath

    if (-not $DryRun -and (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
        $interruptedRun = Get-Content -LiteralPath $runStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $interruptedTask = Get-AutodevTaskById -State $script:currentState -TaskId ([string]$interruptedRun.task)
        $headForAudit = (Invoke-Git -Arguments @("rev-parse", "HEAD")).Output
        if ($interruptedTask.status -eq "TODO") {
            $workspaceForAudit = Get-WorkspaceFingerprint
            Assert-AutodevRunState -RunState $interruptedRun -TaskId $interruptedTask.id -CurrentHead $headForAudit -CurrentWorkspaceFingerprint $workspaceForAudit -ReportsRoot $reportsRoot
            if ([int]$interruptedRun.fix_rounds -ne 0 -or [int]$interruptedRun.review_number -ne 1) {
                throw "BLOCKED: TODO Task has a trusted run-state with unexpected progress metadata."
            }
            Remove-CurrentRunState
            $script:runStateExistedAtInvocation = $false
        }
        if ($interruptedTask.status -eq "DONE" -and $headForAudit -eq [string]$interruptedRun.git_head) {
            Assert-AutodevRunState -RunState $interruptedRun -TaskId $interruptedTask.id -CurrentHead $headForAudit -CurrentWorkspaceFingerprint ([string]$interruptedRun.workspace_fingerprint) -ReportsRoot $reportsRoot
            $script:currentTask = $interruptedTask
            $script:runState = $interruptedRun
            $script:runDirectory = [string]$interruptedRun.report_directory
            $script:preserveRunStateOnFailure = $true
            $script:taskStarted = $true
            $interruptedTask.status = "BLOCKED"
            $interruptedTask.updated_at = [DateTime]::UtcNow.ToString("o")
            $interruptedTask.last_message = "Recovered an interrupted commit window; no commit was created."
            Save-AutodevState -State $script:currentState -Path $statePath
            Update-RunWorkspaceCheckpoint
            throw "Recovered Task '$($interruptedTask.id)' from DONE to BLOCKED because its automatic commit was interrupted. Resume after inspecting the staged changes."
        }
        if ($interruptedTask.status -eq "DONE") {
            $script:preserveRunStateOnFailure = $true
            throw "BLOCKED: trusted run-state remains for DONE task '$($interruptedTask.id)' but HEAD changed. Inspect the last commit and run-state manually before continuing."
        }
    }

    $script:currentTask = Select-AutodevTask -State $script:currentState -RequestedTask $Task -Resume:$Resume

    if ($DryRun) {
        Write-Output "AUTODEV DryRun"
        if ($null -eq $script:currentTask) {
            Write-Output "Task: 无待执行 Task；automation/state/tasks.json 中所有任务均为 DONE。"
        }
        else {
            $taskSource = Get-AutodevTaskSource -ProjectRoot $projectRoot -Source $script:currentTask.source
            Write-Output "Task: $($script:currentTask.id) $($script:currentTask.title)"
            Write-Output "Status: $($script:currentTask.status)"
            Write-Output "Milestone: $($script:currentTask.milestone)"
            Write-Output "Acceptance source: $($script:currentTask.source) ($($taskSource.Length) chars)"
        }
        Write-Output "Tests: backend pytest -v; frontend npm test; frontend npm run build"
        Write-Output "Agents: fresh Developer(workspace-write) -> Reviewer(read-only) -> Fixer(workspace-write), MaxFixRounds=$MaxFixRounds"
        Write-Output "Commit: $(-not $NoCommit); model override: optional AUTODEV_DEV_MODEL/AUTODEV_REVIEW_MODEL"
        Write-Output "Stops: Milestone, BLOCKED, safety risk, invalid state, failed CLI, invalid Reviewer JSON"
        $dryCapabilities = Get-CodexCapabilities -AllowUnavailable
        if ($dryCapabilities.Available) {
            Write-Output "Codex: $($dryCapabilities.Version); agent-sandbox=$($dryCapabilities.HasSandbox); test-sandbox=$($dryCapabilities.HasWindowsTestSandbox); schema=$($dryCapabilities.HasOutputSchema); ephemeral=$($dryCapabilities.HasEphemeral)"
        }
        else {
            Write-Output "Codex capability check unavailable in this shell: $($dryCapabilities.Reason)"
        }
        exit 0
    }

    if ($null -eq $script:currentTask) {
        Write-Host "All tasks in automation/state/tasks.json are DONE. No changes were made."
        exit 0
    }

    Initialize-TaskControlPlane -Task $script:currentTask
    Assert-ControlPlaneMatchesHead
    Assert-NoWorkspaceCredentialFiles
    $currentHead = (Invoke-Git -Arguments @("rev-parse", "HEAD")).Output
    if ($Resume) {
        if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
            throw "BLOCKED: Resume requires trusted .git/autodev/current-run.json from the interrupted task."
        }
        $script:runState = Get-Content -LiteralPath $runStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $currentWorkspaceFingerprint = Get-WorkspaceFingerprint
        $fingerprintForValidation = if ($AcceptHumanChanges) { [string]$script:runState.workspace_fingerprint } else { $currentWorkspaceFingerprint }
        Assert-AutodevRunState -RunState $script:runState -TaskId $script:currentTask.id -CurrentHead $currentHead -CurrentWorkspaceFingerprint $fingerprintForValidation -ReportsRoot $reportsRoot
        if ($PSBoundParameters.ContainsKey("MaxFixRounds") -and $MaxFixRounds -ne [int]$script:runState.max_fix_rounds) {
            throw "BLOCKED: Resume MaxFixRounds differs from the original run ($($script:runState.max_fix_rounds))."
        }
        $MaxFixRounds = [int]$script:runState.max_fix_rounds
        $script:runDirectory = [string]$script:runState.report_directory
        if (-not (Test-Path -LiteralPath $script:runDirectory -PathType Container)) {
            throw "BLOCKED: Resume report directory '$($script:runDirectory)' is missing."
        }
        Assert-TrustedRuntimeAndReports
        Assert-GitRepositoryReady -ForResume
        if ($AcceptHumanChanges) {
            if ($script:currentTask.status -notin @("IN_PROGRESS", "REVIEW", "FIXING", "BLOCKED")) {
                throw "BLOCKED: -AcceptHumanChanges requires an interrupted active or BLOCKED task."
            }
            [void](Assert-SafeTaskChanges)
            $script:runState.workspace_fingerprint = $currentWorkspaceFingerprint
            Save-CurrentRunState
            Write-RunFile -Name "human-rebaseline.md" -Content "Human changes explicitly accepted at $([DateTime]::UtcNow.ToString('o')). Full objective tests and a fresh Reviewer will run before commit."
        }
        $script:taskStarted = $true
    }
    else {
        Assert-GitRepositoryReady
        $timestamp = [DateTime]::Now.ToString("yyyy-MM-dd_HHmmss")
        $safeTaskId = $script:currentTask.id -replace '[^A-Za-z0-9_-]', '_'
        $script:runDirectory = Join-Path $reportsRoot "${timestamp}_$safeTaskId"
        New-Item -ItemType Directory -Path $script:runDirectory -Force | Out-Null
        $script:runState = [pscustomobject]@{
            task = $script:currentTask.id
            started_at = [DateTime]::UtcNow.ToString("o")
            report_directory = $script:runDirectory
            git_head = $currentHead
            fix_rounds = 0
            review_number = 1
            max_fix_rounds = $MaxFixRounds
            workspace_fingerprint = Get-WorkspaceFingerprint
            runtime_fingerprint = Get-TestRuntimeFingerprint
            report_fingerprint = Get-RunReportFingerprint
        }
        Save-CurrentRunState
    }

    $taskSource = Get-AutodevTaskSource -ProjectRoot $projectRoot -Source $script:currentTask.source
    $capabilities = Get-CodexCapabilities
    if (-not $capabilities.HasWindowsTestSandbox) {
        throw "BLOCKED: Codex CLI does not expose 'sandbox windows --full-auto'; objective tests cannot run with isolated Git/network permissions."
    }
    $script:codexCapabilities = $capabilities
    Assert-TaskControlPlaneUnchanged
    $script:taskStarted = $true

    $result = Invoke-TaskPipeline -Capabilities $capabilities -TaskSource $taskSource
    [void](Assert-SafeTaskChanges)
    $reviewedPaths = @($result.ReviewedPaths)
    Assert-PathSetsEqual -Expected $reviewedPaths -Actual @(Get-GitChangedPaths) -Context "Pre-commit"
    if ((Get-PathContentFingerprint -Paths $reviewedPaths) -ne $result.ReviewedContentFingerprint) {
        throw "Reviewed file content changed after Reviewer PASS."
    }
    Write-RunFile -Name "pre-commit-status.txt" -Content ((Invoke-Git -Arguments @("status", "--short")).Output + "`n`n" + (Invoke-Git -Arguments @("diff", "--stat", "HEAD")).Output)

    if ($NoCommit) {
        $summary = "# AUTODEV SUMMARY`n`nTask $($script:currentTask.id) passed tests and Reviewer, but -NoCommit was set. Status remains REVIEW. Re-run with -Resume to revalidate and commit."
        Write-RunFile -Name "summary.md" -Content $summary
        Write-Host $summary
        exit 0
    }

    if ((Get-PathContentFingerprint -Paths $reviewedPaths) -ne $result.ReviewedContentFingerprint) {
        throw "Reviewed file content changed before staging."
    }
    $gitAddArguments = @("add", "-A", "--") + @(Get-GitStageCandidatePaths)
    Invoke-Git -Arguments $gitAddArguments | Out-Null
    Assert-PathSetsEqual -Expected $reviewedPaths -Actual @(Get-GitStagedPaths) -Context "Staging"
    Assert-IndexMatchesWorktree -Paths $reviewedPaths
    if ((Get-PathContentFingerprint -Paths $reviewedPaths) -ne $result.ReviewedContentFingerprint) {
        throw "Staged worktree content differs from the Reviewer-approved content."
    }
    $stagedDiff = (Invoke-Git -Arguments @("diff", "--cached", "--no-ext-diff")).Output
    $stagedIssues = @(Test-AutodevDiffSafety -DiffText $stagedDiff)
    if ($stagedIssues.Count -gt 0) {
        throw "Potential secret detected after staging: $($stagedIssues -join ' ')"
    }

    Set-TaskStatusAndSave -Status "DONE" -Reason "Objective tests and independent Reviewer passed."
    $expectedTasksStateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    Assert-PathSetsEqual -Expected $reviewedPaths -Actual @(Get-GitChangedPaths) -Context "DONE state update"
    Invoke-Git -Arguments @("add", "--", "automation/state/tasks.json") | Out-Null
    Assert-PathSetsEqual -Expected $reviewedPaths -Actual @(Get-GitStagedPaths) -Context "Final staging"
    Assert-IndexMatchesWorktree -Paths $reviewedPaths
    $reviewedNonStatePaths = @($reviewedPaths | Where-Object { $_ -ne "automation/state/tasks.json" })
    if ((Get-PathContentFingerprint -Paths $reviewedNonStatePaths) -ne $result.ReviewedNonStateFingerprint) {
        throw "Non-state file content changed after Reviewer PASS."
    }
    if ((Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -ne $expectedTasksStateHash) {
        throw "Task state changed unexpectedly before commit."
    }
    $worktreeStateBlob = (Invoke-Git -Arguments @("hash-object", "--", "automation/state/tasks.json")).Output
    $stagedStateBlob = (Invoke-Git -Arguments @("rev-parse", ":automation/state/tasks.json")).Output
    if ($worktreeStateBlob -ne $stagedStateBlob) {
        throw "Staged Task state does not match the expected DONE state."
    }
    $stagedDiff = (Invoke-Git -Arguments @("diff", "--cached", "--no-ext-diff")).Output
    $stagedIssues = @(Test-AutodevDiffSafety -DiffText $stagedDiff)
    if ($stagedIssues.Count -gt 0) {
        throw "Potential secret detected in final staged diff: $($stagedIssues -join ' ')"
    }

    $expectedTree = (Invoke-Git -Arguments @("write-tree")).Output
    Assert-NoWorkspaceCredentialFiles
    Assert-TrustedRuntimeAndReports
    $commitMessage = "feat: complete $($script:currentTask.id) $($script:currentTask.title)"
    $commitResult = Invoke-Git -Arguments @("commit", "-m", $commitMessage) -AllowFailure
    if ($commitResult.ExitCode -ne 0) {
        throw "Git commit failed; staged and working changes were preserved.`n$($commitResult.Output)"
    }

    $commitSha = (Invoke-Git -Arguments @("rev-parse", "HEAD")).Output
    $script:taskCommitCreated = $true
    $committedTree = (Invoke-Git -Arguments @("rev-parse", "HEAD^{tree}")).Output
    if ($committedTree -ne $expectedTree) {
        throw "Git hooks or concurrent activity changed the committed tree after final verification."
    }
    $remainingStatus = (Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output
    if ($remainingStatus) {
        throw "Git commit succeeded but the working tree still contains changes:`n$remainingStatus"
    }

    if (Test-AutodevMilestoneGate -State $script:currentState -Task $script:currentTask) {
        Write-MilestoneReport -Task $script:currentTask -CommitSha $commitSha -FixRounds $result.FixRounds -Review $result.Review
        Remove-CurrentRunState
        Write-Host "Milestone $($script:currentTask.milestone) completed. Automatic development stopped for human acceptance."
        exit 0
    }

    $summary = "# AUTODEV SUMMARY`n`nTask: $($script:currentTask.id) $($script:currentTask.title)`nCommit: $commitSha`nTests: PASS`nReviewer: PASS`nFix rounds: $($result.FixRounds)"
    Write-RunFile -Name "summary.md" -Content $summary

    if ($Task) {
        Remove-CurrentRunState
        Write-Host "Specified task $Task completed and committed as $commitSha."
        exit 0
    }

    Remove-CurrentRunState
    & $PSCommandPath -Resume:$false -NoCommit:$NoCommit -MaxFixRounds $MaxFixRounds -AgentTimeoutMinutes $AgentTimeoutMinutes
    exit $LASTEXITCODE
}
catch {
    $reason = $_.Exception.Message
    if ($script:currentTask) {
        if (-not $script:runDirectory) {
            $timestamp = [DateTime]::Now.ToString("yyyy-MM-dd_HHmmss")
            $script:runDirectory = Join-Path $automationRoot "reports/${timestamp}_$($script:currentTask.id)"
            New-Item -ItemType Directory -Path $script:runDirectory -Force | Out-Null
        }
        Write-BlockedReport -Reason $reason
        if (-not $script:taskStarted -and -not $Resume -and -not $script:runStateExistedAtInvocation -and -not $script:preserveRunStateOnFailure) {
            Remove-CurrentRunState
        }
    }
    else {
        Write-Error $reason
    }
    exit 1
}
finally {
    if ($script:taskStarted -and -not $script:taskCommitCreated -and $script:runDirectory -and (Test-Path -LiteralPath $runStatePath)) {
        $resumeHint = "Run .\automation\autodev.ps1 -Resume after resolving the reported condition."
        try {
            Write-RunFile -Name "resume.txt" -Content $resumeHint
        }
        catch {
            Write-Warning "Resume hint was not written because report integrity verification failed."
        }
    }
}
