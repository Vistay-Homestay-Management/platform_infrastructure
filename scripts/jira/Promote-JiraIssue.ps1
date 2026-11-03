[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$IssueKey,
    [ValidateSet('Ready', 'Backlog')][string]$TargetStatus = 'Ready',
    [ValidateSet('Validate', 'DryRun', 'Apply')][string]$Mode = 'Validate',
    [string]$Reason,
    [string]$CatalogPath,
    [string]$CredentialPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..\..\..\platform_contracts\docs\jira\jira-catalog.v1.3.json' }
if (-not $CredentialPath) { $CredentialPath = Join-Path $PSScriptRoot '..\..\..\.secrets\jira-api.xml' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)
$CredentialPath = [IO.Path]::GetFullPath($CredentialPath)

function Invoke-Jira([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$script:Site/rest/api/3/$Path"
        Headers = $script:Headers
        ContentType = 'application/json; charset=utf-8'
    }
    if ($null -ne $Body) { $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)) }
    return Invoke-RestMethod @parameters
}

$validator = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $CatalogPath -Parent) -Parent) '..\scripts\validate-jira-catalog.mjs'))
& node $validator $CatalogPath
if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed.' }
$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$record = @($catalog.issues | Where-Object { $_.jiraKey -eq $IssueKey })
if ($record.Count -ne 1) { throw "Expected one catalog record for $IssueKey; found $($record.Count)" }
$record = $record[0]
if ($TargetStatus -eq 'Backlog' -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'A reason is required when demoting an issue to Backlog.' }

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
try {
    $issue = Invoke-Jira 'GET' "issue/$IssueKey`?fields=status,labels,assignee,issuetype,parent"
    $errors = @()
    if ($TargetStatus -eq 'Ready') {
        if ($record.specStatus -ne 'executable' -or -not [bool]$record.dispatchable) { $errors += 'catalog record is not executable and dispatchable' }
        if ($record.issueType -notin @('Task', 'Subtask', 'Bug', 'Spike', 'Tech Debt')) { $errors += 'issue type is not dispatchable' }
        if ('agent-ready' -notin @($issue.fields.labels)) { $errors += 'agent-ready label is absent; apply catalog sync first' }
        if ($null -eq $issue.fields.assignee) { $errors += 'assignee is required before Ready' }
        if ($record.PSObject.Properties.Name -contains 'parentSourceId') {
            $parent = @($catalog.issues | Where-Object { $_.sourceId -eq $record.parentSourceId })[0]
            if ($null -eq $parent -or $parent.specStatus -notin @('refined-parent', 'executable', 'historical')) { $errors += 'parent specification is not refined' }
        }
        foreach ($dependency in @($record.dependencies | Where-Object { $_.relation -in @('is-blocked-by', 'remediates') })) {
            $target = @($catalog.issues | Where-Object { $_.sourceId -eq $dependency.sourceId })[0]
            if ($null -eq $target -or -not $target.jiraKey) { $errors += "dependency $($dependency.sourceId) has no Jira identity"; continue }
            $targetIssue = Invoke-Jira 'GET' "issue/$($target.jiraKey)`?fields=status"
            if ($targetIssue.fields.status.name -ne 'Done') { $errors += "dependency $($dependency.sourceId) is not Done" }
        }
    }
    if ($errors.Count -gt 0) { throw "$IssueKey cannot move to $TargetStatus`: $($errors -join '; ')" }
    if ([string]$issue.fields.status.name -eq $TargetStatus) {
        [pscustomobject]@{ mode = $Mode; issueKey = $IssueKey; sourceId = $record.sourceId; from = $TargetStatus; to = $TargetStatus; noOp = $true } | ConvertTo-Json
        return
    }
    $transitionResponse = Invoke-Jira 'GET' "issue/$IssueKey/transitions"
    $transition = @($transitionResponse.transitions | Where-Object { $_.to.name -eq $TargetStatus })
    if ($transition.Count -ne 1) { throw "Expected one transition from $($issue.fields.status.name) to $TargetStatus; found $($transition.Count)" }
    $result = [ordered]@{
        mode = $Mode
        issueKey = $IssueKey
        sourceId = $record.sourceId
        from = $issue.fields.status.name
        to = $TargetStatus
        transitionId = $transition[0].id
        reason = $Reason
    }
    if ($Mode -eq 'Validate' -or $Mode -eq 'DryRun') { $result | ConvertTo-Json; return }
    Invoke-Jira 'POST' "issue/$IssueKey/transitions" @{ transition = @{ id = [string]$transition[0].id } } | Out-Null
    if ($Reason) {
        $comment = @{ body = @{ type = 'doc'; version = 1; content = @(@{ type = 'paragraph'; content = @(@{ type = 'text'; text = "[readiness-gate] $Reason" }) }) } }
        Invoke-Jira 'POST' "issue/$IssueKey/comment" $comment | Out-Null
    }
    $result.applied = $true
    $result | ConvertTo-Json
}
finally {
    $plainToken = $null
    $basic = $null
    $script:Headers = $null
}
