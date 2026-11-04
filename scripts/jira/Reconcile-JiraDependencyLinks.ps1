[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate', 'DryRun', 'Apply')][string]$Mode = 'Validate',
    [string]$CatalogPath,
    [string]$CredentialPath,
    [string]$BackupRoot,
    [switch]$ConfirmApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..\..\..\platform_contracts\docs\jira\jira-catalog.v1.3.json' }
if (-not $CredentialPath) { $CredentialPath = Join-Path $PSScriptRoot '..\..\..\.secrets\jira-api.xml' }
if (-not $BackupRoot) { $BackupRoot = Join-Path $PSScriptRoot '..\..\..\.backups\jira\links' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)
$CredentialPath = [IO.Path]::GetFullPath($CredentialPath)
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)

function Invoke-Jira([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{ Method = $Method; Uri = "$script:Site/rest/api/3/$Path"; Headers = $script:Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress)) }
    return Invoke-RestMethod @parameters
}

function Get-AllIssues([string]$ProjectKey) {
    $all = @(); $next = $null
    do {
        $jql = [uri]::EscapeDataString("project = $ProjectKey ORDER BY key ASC")
        $suffix = if ($next) { "&nextPageToken=$([uri]::EscapeDataString($next))" } else { '' }
        $page = Invoke-Jira 'GET' "search/jql?jql=$jql&maxResults=100&fields=summary,description,labels,issuelinks,updated$suffix"
        $all += @($page.issues)
        $next = if ($page.PSObject.Properties.Name -contains 'nextPageToken') { $page.nextPageToken } else { $null }
    } while ($next)
    return $all
}

function Get-SourceId($Issue) {
    $summary = [string]$Issue.fields.summary
    if ($summary -match '^\[([^\]]+)\]') { return $Matches[1] }
    $label = @($Issue.fields.labels | Where-Object { $_ -like 'source-*' } | Select-Object -First 1)
    if ($label.Count -eq 1) { return ([string]$label[0]).Substring(7).ToUpperInvariant() }
    return $null
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$validator = [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $CatalogPath -Parent) -Parent) '..\scripts\validate-jira-catalog.mjs'))
& node $validator $CatalogPath
if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed.' }
if ($Mode -eq 'Validate') {
    $dependencyCount = @($catalog.issues | ForEach-Object { @($_.dependencies) }).Count
    [pscustomobject]@{ mode = $Mode; issueCount = @($catalog.issues).Count; dependencyDeclarations = $dependencyCount; valid = $true } | ConvertTo-Json
    return
}
if ($Mode -eq 'Apply' -and -not $ConfirmApply) { throw 'Apply requires explicit -ConfirmApply after reviewing DryRun.' }

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
try {
    $issues = @(Get-AllIssues $catalog.projectKey)
    $issueBySource = @{}; $issueByKey = @{}; $recordBySource = @{}
    foreach ($record in @($catalog.issues)) { $recordBySource[[string]$record.sourceId] = $record }
    foreach ($issue in $issues) {
        $source = Get-SourceId $issue
        if ($source) { $issueBySource[[string]$source] = $issue }
        $issueByKey[[string]$issue.key] = $issue
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupPath = Join-Path $BackupRoot "links-$($catalog.projectKey)-$timestamp.json"
    [ordered]@{ capturedAt = (Get-Date).ToString('o'); issues = $issues } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backupPath -Encoding utf8

    $desiredByPhysicalKey = @{}
    foreach ($record in @($catalog.issues)) {
        foreach ($dependency in @($record.dependencies)) {
            $from = $issueBySource[[string]$record.sourceId]; $to = $issueBySource[[string]$dependency.sourceId]
            if ($null -eq $from -or $null -eq $to) { throw "Cannot resolve dependency $($record.sourceId) -> $($dependency.sourceId)" }
            if ($dependency.relation -eq 'blocks') { $kind = 'Blocks'; $outward = [string]$from.key; $inward = [string]$to.key }
            elseif ($dependency.relation -eq 'is-blocked-by') { $kind = 'Blocks'; $outward = [string]$to.key; $inward = [string]$from.key }
            else { $kind = 'Relates'; $pair = @([string]$from.key, [string]$to.key) | Sort-Object; $outward = $pair[0]; $inward = $pair[1] }
            $physicalKey = "$kind|$outward|$inward"
            if (-not $desiredByPhysicalKey.ContainsKey($physicalKey)) {
                $desiredByPhysicalKey[$physicalKey] = [pscustomobject]@{ type = $kind; outward = $outward; inward = $inward; declarations = @() }
            }
            $desiredByPhysicalKey[$physicalKey].declarations += "$($record.sourceId):$($dependency.relation):$($dependency.sourceId)"
        }
    }

    $existingByPhysicalKey = @{}; $existingByPair = @{}
    foreach ($issue in $issues) {
        foreach ($link in @($issue.fields.issuelinks)) {
            $other = if ($link.PSObject.Properties.Name -contains 'outwardIssue') { $link.outwardIssue.key } else { $link.inwardIssue.key }
            if (-not $issueByKey.ContainsKey([string]$other)) { continue }
            if ($link.type.name -eq 'Blocks') {
                if ($link.PSObject.Properties.Name -contains 'outwardIssue') { $outward = [string]$issue.key; $inward = [string]$other }
                else { $outward = [string]$other; $inward = [string]$issue.key }
                $physicalKey = "Blocks|$outward|$inward"
            } else {
                $pair = @([string]$issue.key, [string]$other) | Sort-Object; $outward = $pair[0]; $inward = $pair[1]
                $physicalKey = "Relates|$outward|$inward"
            }
            $existingByPhysicalKey[$physicalKey] = [pscustomobject]@{ id = [string]$link.id; type = [string]$link.type.name; outward = $outward; inward = $inward }
            $pairKey = (@([string]$issue.key, [string]$other) | Sort-Object) -join '|'
            $existingByPair[$pairKey] = $existingByPhysicalKey[$physicalKey]
        }
    }

    $plan = @(); $deleteIds = @{}
    foreach ($entry in $desiredByPhysicalKey.GetEnumerator() | Sort-Object Name) {
        if ($existingByPhysicalKey.ContainsKey($entry.Key)) { continue }
        $desired = $entry.Value; $pairKey = (@($desired.outward, $desired.inward) | Sort-Object) -join '|'
        $wrong = $existingByPair[$pairKey]
        if ($null -ne $wrong) { $deleteIds[[string]$wrong.id] = $wrong }
        $plan += [pscustomobject]@{
            action = if ($null -ne $wrong) { 'replace' } else { 'create' }
            declarations = $desired.declarations
            deleteLinkId = if ($null -ne $wrong) { $wrong.id } else { $null }
            before = if ($null -ne $wrong) { "$($wrong.type)|$($wrong.outward)|$($wrong.inward)" } else { $null }
            after = $entry.Key
        }
    }
    $planPath = Join-Path $BackupRoot "plan-$($catalog.projectKey)-$timestamp.json"
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
    if ($Mode -eq 'DryRun') {
        [pscustomobject]@{ mode = $Mode; backup = $backupPath; plan = $planPath; changes = $plan.Count; replacements = @($plan | Where-Object action -eq 'replace').Count; creates = @($plan | Where-Object action -eq 'create').Count } | ConvertTo-Json
        return
    }

    $fresh = @(Get-AllIssues $catalog.projectKey); $freshByKey = @{}; foreach ($issue in $fresh) { $freshByKey[[string]$issue.key] = $issue }
    $changed = @($issues | Where-Object { [string]$freshByKey[[string]$_.key].fields.updated -ne [string]$_.fields.updated } | ForEach-Object key)
    if ($changed.Count -gt 0) { throw "Jira changed after link backup; no link mutation was applied: $($changed -join ', ')" }
    foreach ($linkId in $deleteIds.Keys) { Invoke-Jira 'DELETE' "issueLink/$linkId" | Out-Null }
    foreach ($item in $plan) {
        $parts = $item.after -split '\|'
        # Jira's create-link payload uses inwardIssue for the blocking/source issue and outwardIssue for the blocked/target issue.
        $body = if ($parts[0] -eq 'Blocks') {
            @{ type = @{ name = $parts[0] }; inwardIssue = @{ key = $parts[1] }; outwardIssue = @{ key = $parts[2] } }
        } else {
            @{ type = @{ name = $parts[0] }; inwardIssue = @{ key = $parts[1] }; outwardIssue = @{ key = $parts[2] } }
        }
        Invoke-Jira 'POST' 'issueLink' $body | Out-Null
    }
    [pscustomobject]@{ mode = $Mode; backup = $backupPath; plan = $planPath; replaced = $deleteIds.Count; created = $plan.Count; applied = $true } | ConvertTo-Json
}
finally {
    $plainToken = $null; $basic = $null; $script:Headers = $null
}
