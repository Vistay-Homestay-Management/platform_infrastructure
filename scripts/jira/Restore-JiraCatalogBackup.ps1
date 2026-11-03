[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string[]]$IssueKey,
    [ValidateSet('DryRun', 'Apply')][string]$Mode = 'DryRun',
    [string]$CredentialPath,
    [switch]$ConfirmMoreThanFive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $CredentialPath) { $CredentialPath = Join-Path $PSScriptRoot '..\..\..\.secrets\jira-api.xml' }
$BackupPath = [IO.Path]::GetFullPath($BackupPath)
$CredentialPath = [IO.Path]::GetFullPath($CredentialPath)
if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw "Backup not found: $BackupPath" }
$keys = @($IssueKey | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
if ($keys.Count -eq 0) { throw 'At least one IssueKey is required.' }
if ($keys.Count -gt 5 -and -not $ConfirmMoreThanFive) { throw 'Rollback is canary-limited to five issues unless -ConfirmMoreThanFive is explicit.' }

function Invoke-Jira([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{ Method = $Method; Uri = "$script:Site/rest/api/3/$Path"; Headers = $script:Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress)) }
    return Invoke-RestMethod @parameters
}

$backup = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
$backupByKey = @{}
foreach ($issue in @($backup.issues)) { $backupByKey[[string]$issue.key] = $issue }
$missing = @($keys | Where-Object { -not $backupByKey.ContainsKey([string]$_) })
if ($missing.Count -gt 0) { throw "Backup does not contain: $($missing -join ', ')" }

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
try {
    $plan = @()
    foreach ($key in $keys) {
        $current = Invoke-Jira 'GET' "issue/$key`?fields=summary,description,labels,status,updated"
        $saved = $backupByKey[$key]
        $changed = @()
        if ([string]$current.fields.summary -cne [string]$saved.fields.summary) { $changed += 'summary' }
        if (($current.fields.description | ConvertTo-Json -Depth 100 -Compress) -cne ($saved.fields.description | ConvertTo-Json -Depth 100 -Compress)) { $changed += 'description' }
        if ((@($current.fields.labels) | Sort-Object) -join "`n" -cne (@($saved.fields.labels) | Sort-Object) -join "`n") { $changed += 'labels' }
        $plan += [pscustomobject]@{ issueKey = $key; statusPreserved = $current.fields.status.name; fields = $changed; expectedUpdated = $current.fields.updated }
    }
    if ($Mode -eq 'DryRun') { [pscustomobject]@{ mode = $Mode; backup = $BackupPath; changes = @($plan | Where-Object { $_.fields.Count -gt 0 }).Count; plan = $plan } | ConvertTo-Json -Depth 20; return }
    foreach ($item in @($plan | Where-Object { $_.fields.Count -gt 0 })) {
        $fresh = Invoke-Jira 'GET' "issue/$($item.issueKey)`?fields=updated"
        if ([string]$fresh.fields.updated -ne [string]$item.expectedUpdated) { throw "$($item.issueKey) changed during rollback planning; nothing further was restored." }
        $saved = $backupByKey[[string]$item.issueKey]
        $fields = [ordered]@{}
        if ('summary' -in $item.fields) { $fields.summary = $saved.fields.summary }
        if ('description' -in $item.fields) { $fields.description = $saved.fields.description }
        if ('labels' -in $item.fields) { $fields.labels = @($saved.fields.labels) }
        Invoke-Jira 'PUT' "issue/$($item.issueKey)" @{ fields = $fields } | Out-Null
    }
    [pscustomobject]@{ mode = $Mode; backup = $BackupPath; restored = @($plan | Where-Object { $_.fields.Count -gt 0 }).Count; statusTransitions = 0 } | ConvertTo-Json
}
finally {
    $plainToken = $null
    $basic = $null
    $script:Headers = $null
}
