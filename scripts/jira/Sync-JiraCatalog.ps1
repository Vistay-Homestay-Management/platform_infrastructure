[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate', 'DryRun', 'Apply')]
    [string]$Mode = 'Validate',
    [string]$CatalogPath,
    [string]$CredentialPath,
    [string]$BackupRoot,
    [switch]$AllowTransitions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..\..\..\platform_contracts\docs\jira\jira-catalog.v1.2.json' }
if (-not $CredentialPath) { $CredentialPath = Join-Path $PSScriptRoot '..\..\..\.secrets\jira-api.xml' }
if (-not $BackupRoot) { $BackupRoot = Join-Path $PSScriptRoot '..\..\..\.backups\jira\sync' }

function Resolve-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function ConvertFrom-AdfText($Node) {
    if ($null -eq $Node) { return '' }
    if ($Node -is [System.Array]) { return (($Node | ForEach-Object { ConvertFrom-AdfText $_ }) -join ' ') }
    $parts = @()
    if ($Node.PSObject.Properties.Name -contains 'text') { $parts += [string]$Node.text }
    if ($Node.PSObject.Properties.Name -contains 'content') { $parts += ConvertFrom-AdfText $Node.content }
    return ($parts -join ' ').Trim()
}

function New-AdfText([string]$Text, [bool]$Strong = $false) {
    $node = [ordered]@{ type = 'text'; text = $Text }
    if ($Strong) { $node.marks = @(@{ type = 'strong' }) }
    return $node
}

function New-AdfParagraph([string]$Text) {
    return [ordered]@{ type = 'paragraph'; content = @(New-AdfText $Text) }
}

function New-AdfHeading([string]$Text, [int]$Level = 3) {
    return [ordered]@{ type = 'heading'; attrs = @{ level = $Level }; content = @(New-AdfText $Text) }
}

function New-AdfBulletList($Items) {
    return [ordered]@{
        type = 'bulletList'
        content = @($Items | ForEach-Object {
            [ordered]@{ type = 'listItem'; content = @([ordered]@{ type = 'paragraph'; content = @(New-AdfText ([string]$_)) }) }
        })
    }
}

function New-AdfDescription($Record, [string]$Readiness) {
    $content = @(
        [ordered]@{
            type = 'panel'
            attrs = @{ panelType = if ($Readiness -in @('externally-blocked', 'decision-required')) { 'warning' } else { 'info' } }
            content = @(New-AdfParagraph ("AGENT READINESS: {0} - Catalog schema v1.2. Implement only the stated scope; attach required evidence before Done." -f $Readiness.ToUpperInvariant()))
        },
        (New-AdfParagraph ("Source-ID: {0}" -f $Record.sourceId)),
        (New-AdfHeading 'Actor / outcome'),
        (New-AdfParagraph ("Actor: {0}" -f $Record.actor)),
        (New-AdfParagraph ("Outcome: {0}" -f $Record.outcome)),
        (New-AdfHeading 'Context'),
        (New-AdfParagraph $Record.context),
        (New-AdfHeading 'In scope'),
        (New-AdfBulletList $Record.inScope),
        (New-AdfHeading 'Out of scope'),
        (New-AdfBulletList $Record.outOfScope),
        (New-AdfHeading 'Business rules'),
        (New-AdfBulletList $Record.businessRules),
        (New-AdfHeading 'Repositories / ServiceOwner'),
        (New-AdfBulletList $Record.repositories),
        (New-AdfHeading 'Interfaces'),
        (New-AdfBulletList $Record.interfaces),
        (New-AdfHeading 'Data ownership / migration'),
        (New-AdfBulletList $Record.dataOwnership),
        (New-AdfHeading 'State machine'),
        (New-AdfBulletList $Record.stateMachine),
        (New-AdfHeading 'Authorization: action + partition + field group'),
        (New-AdfBulletList @(
            "Actions: $($Record.authorization.actions -join ', ')"
            "Data partitions: $($Record.authorization.dataPartitions -join ' | ')"
            "Field groups: $($Record.authorization.fieldGroups -join ' | ')"
        )),
        (New-AdfHeading 'Failure semantics'),
        (New-AdfBulletList $Record.failureSemantics),
        (New-AdfHeading 'Idempotency / concurrency / replay'),
        (New-AdfBulletList $Record.idempotencyConcurrency)
    )
    if (@($Record.dependencies).Count -gt 0) {
        $content += New-AdfHeading 'Dependencies and issue links'
        $content += New-AdfBulletList @($Record.dependencies | ForEach-Object { "$($_.relation): $($_.sourceId)" })
    }
    if (@($Record.externalBlockers).Count -gt 0) {
        $content += New-AdfHeading 'External blockers'
        $content += New-AdfBulletList $Record.externalBlockers
    }
    $content += New-AdfHeading 'Acceptance criteria'
    $index = 0
    $content += New-AdfBulletList @($Record.acceptanceCriteria | ForEach-Object {
        $index += 1
        "AC$index - Given $($_.given); When $($_.when); Then $($_.then)."
    })
    $content += @(
        (New-AdfHeading 'Test strategy'),
        (New-AdfBulletList $Record.tests),
        (New-AdfHeading 'Security / audit / observability'),
        (New-AdfBulletList $Record.observability),
        (New-AdfHeading 'Definition of Done'),
        (New-AdfBulletList $Record.definitionOfDone),
        (New-AdfHeading 'Required evidence'),
        (New-AdfBulletList $Record.evidence)
    )
    return [ordered]@{ type = 'doc'; version = 1; content = $content }
}

function Get-NormalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    return ($Value | ConvertTo-Json -Depth 100 -Compress)
}

function Get-SpecLabel($Record) {
    $json = $Record | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    return "spec-$($hash.Substring(0, 16))"
}

function Invoke-Jira([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$script:Site/rest/api/3/$Path"
        Headers = $script:Headers
        ContentType = 'application/json; charset=utf-8'
    }
    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 100 -Compress
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($jsonBody)
    }
    for ($attempt = 1; $attempt -le 6; $attempt += 1) {
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($attempt -ge 6 -or $statusCode -notin @(429, 502, 503, 504)) {
                throw "Jira request failed: $Method rest/api/3/$Path. $($_.Exception.Message)"
            }
            $retryAfter = 0
            if ($_.Exception.Response.Headers['Retry-After']) {
                [void][int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter)
            }
            $delay = [Math]::Max($retryAfter, [Math]::Min(30, [Math]::Pow(2, $attempt)))
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-AllIssues([string]$ProjectKey) {
    $all = @()
    $next = $null
    do {
        $jql = [uri]::EscapeDataString("project = $ProjectKey ORDER BY key ASC")
        $fields = [uri]::EscapeDataString('summary,description,status,issuetype,labels,parent,issuelinks,components,priority,assignee,resolution')
        $suffix = if ($next) { "&nextPageToken=$([uri]::EscapeDataString($next))" } else { '' }
        $result = Invoke-Jira 'GET' "search/jql?jql=$jql&maxResults=100&fields=$fields$suffix"
        $all += @($result.issues)
        $next = if ($result.PSObject.Properties.Name -contains 'nextPageToken') { $result.nextPageToken } else { $null }
    } while ($next)
    return $all
}

function Get-SourceId($Issue) {
    $fromSummary = ([string]$Issue.fields.summary) -replace '^\[([^\]]+)\].*$', '$1'
    if ($fromSummary -match '^(VS-E|PROJECT-)') { return $fromSummary }
    $text = ConvertFrom-AdfText $Issue.fields.description
    if ($text -match 'Source-ID:\s*([A-Z0-9-]+)') { return $Matches[1] }
    $sourceLabel = @($Issue.fields.labels | Where-Object { $_ -like 'source-*' } | Select-Object -First 1)
    if ($sourceLabel.Count -gt 0) { return ([string]$sourceLabel[0]).Substring(7).ToUpperInvariant() }
    return $null
}

function Get-Readiness($Record, $IssueBySource) {
    if (@($Record.externalBlockers).Count -gt 0) { return 'externally-blocked' }
    if ($Record.decisionStatus -eq 'decision-required') { return 'decision-required' }
    foreach ($dependency in @($Record.dependencies)) {
        if ($dependency.relation -notin @('is-blocked-by', 'remediates')) { continue }
        $target = $IssueBySource[[string]$dependency.sourceId]
        if ($null -eq $target -or $target.fields.status.name -ne 'Done') { return 'agent-ready-after-dependencies' }
    }
    return 'agent-ready'
}

function Get-DesiredLabels($Record, $CurrentLabels, [string]$Readiness) {
    $managed = @('agent-ready', 'agent-ready-after-dependencies', 'decision-required', 'externally-blocked', 'needs-refinement', 'agent-not-ready', 'roadmap-v1-2')
    $preserved = @($CurrentLabels | Where-Object { $_ -notin $managed -and $_ -notlike 'source-*' -and $_ -notlike 'owner-*' -and $_ -notlike 'spec-*' })
    return @($preserved + @($Record.labels) + $Readiness + (Get-SpecLabel $Record) | Sort-Object -Unique)
}

function Test-LabelsEqual($Left, $Right) {
    return ((@($Left) | Sort-Object) -join "`n") -ceq ((@($Right) | Sort-Object) -join "`n")
}

function Get-LinkedKeys($Issue) {
    return @($Issue.fields.issuelinks | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'inwardIssue') { $_.inwardIssue.key }
        elseif ($_.PSObject.Properties.Name -contains 'outwardIssue') { $_.outwardIssue.key }
    })
}

$CatalogPath = Resolve-FullPath $CatalogPath
$CredentialPath = Resolve-FullPath $CredentialPath
$BackupRoot = Resolve-FullPath $BackupRoot
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "Catalog not found: $CatalogPath" }
if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) { throw "Credential not found: $CredentialPath" }

$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$validator = Join-Path (Split-Path (Split-Path $CatalogPath -Parent) -Parent) '..\scripts\validate-jira-catalog.mjs'
$validator = Resolve-FullPath $validator
& node $validator $CatalogPath
if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed.' }
if ($Mode -eq 'Validate') {
    [pscustomobject]@{ mode = $Mode; catalog = $CatalogPath; issueCount = @($catalog.issues).Count; valid = $true } | ConvertTo-Json
    return
}

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [System.Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
try {
    $currentIssues = @(Get-AllIssues $catalog.projectKey)
    $issueBySource = @{}
    foreach ($issue in $currentIssues) {
        $source = Get-SourceId $issue
        if ($source) { $issueBySource[$source] = $issue }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupPath = Join-Path $BackupRoot "jira-$($catalog.projectKey)-$timestamp.json"
    [ordered]@{ capturedAt = (Get-Date).ToString('o'); project = $catalog.projectKey; issues = $currentIssues } |
        ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backupPath -Encoding utf8

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($catalog.issues)) {
        $current = $issueBySource[[string]$record.sourceId]
        if ($null -eq $current) {
            $plan.Add([pscustomobject]@{ action = 'create'; sourceId = $record.sourceId; jiraKey = $null; fields = @('summary', 'description', 'labels', 'parent') })
            continue
        }
        if (-not $record.manageDescription) { continue }
        $readiness = Get-Readiness $record $issueBySource
        $desiredDescription = New-AdfDescription $record $readiness
        $desiredLabels = Get-DesiredLabels $record @($current.fields.labels) $readiness
        $desiredSpecLabel = Get-SpecLabel $record
        $changed = @()
        if ([string]$current.fields.summary -cne [string]$record.summary) { $changed += 'summary' }
        if ($desiredSpecLabel -notin @($current.fields.labels) -and (Get-NormalJson $current.fields.description) -cne (Get-NormalJson $desiredDescription)) { $changed += 'description' }
        if (-not (Test-LabelsEqual @($current.fields.labels) $desiredLabels)) { $changed += 'labels' }
        if ($changed.Count -gt 0) {
            $plan.Add([pscustomobject]@{ action = 'update'; sourceId = $record.sourceId; jiraKey = $current.key; fields = $changed })
        }
    }

    foreach ($record in @($catalog.issues)) {
        foreach ($dependency in @($record.dependencies)) {
            $from = $issueBySource[[string]$record.sourceId]
            $to = $issueBySource[[string]$dependency.sourceId]
            if ($null -eq $from -or $null -eq $to) { continue }
            $linkedKeys = Get-LinkedKeys $from
            if ($to.key -notin $linkedKeys) {
                $plan.Add([pscustomobject]@{ action = 'link'; sourceId = $record.sourceId; jiraKey = $from.key; fields = @("$($dependency.relation):$($dependency.sourceId)") })
            }
        }
    }

    if ($Mode -eq 'DryRun') {
        $planPath = Join-Path $BackupRoot "plan-$($catalog.projectKey)-$timestamp.json"
        $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding utf8
        [pscustomobject]@{ mode = $Mode; backup = $backupPath; plan = $planPath; changes = $plan.Count; byAction = $plan | Group-Object action | ForEach-Object { @{ action = $_.Name; count = $_.Count } } } | ConvertTo-Json -Depth 10
        return
    }

    $project = Invoke-Jira 'GET' "project/$($catalog.projectKey)"
    $issueTypeResponse = Invoke-Jira 'GET' "issuetype/project?projectId=$($project.id)&maxResults=100"
    $issueTypes = if ($issueTypeResponse.PSObject.Properties.Name -contains 'values') { @($issueTypeResponse.values) } else { @($issueTypeResponse) }
    $typeByName = @{}
    foreach ($type in $issueTypes) { $typeByName[[string]$type.name] = $type }

    $pendingCreates = @($catalog.issues | Where-Object { -not $issueBySource.ContainsKey([string]$_.sourceId) })
    while ($pendingCreates.Count -gt 0) {
        $progress = 0
        $remaining = @()
        foreach ($record in $pendingCreates) {
            $recordParent = if ($record.PSObject.Properties.Name -contains 'parentSourceId') { [string]$record.parentSourceId } else { $null }
            if ($recordParent -and -not $issueBySource.ContainsKey($recordParent)) {
                $remaining += $record
                continue
            }
            $jiraType = $typeByName[[string]$record.issueType]
            if ($null -eq $jiraType -and $record.issueType -in @('Spike', 'Tech Debt', 'Bug')) { $jiraType = $typeByName['Task'] }
            if ($null -eq $jiraType) { throw "Jira issue type not available: $($record.issueType)" }
            $readiness = Get-Readiness $record $issueBySource
            $fields = [ordered]@{
                project = @{ key = $catalog.projectKey }
                summary = $record.summary
                issuetype = @{ id = $jiraType.id }
                description = New-AdfDescription $record $readiness
                labels = Get-DesiredLabels $record @() $readiness
            }
            if ($recordParent) { $fields.parent = @{ key = $issueBySource[$recordParent].key } }
            $created = Invoke-Jira 'POST' 'issue' @{ fields = $fields }
            $fresh = Invoke-Jira 'GET' "issue/$($created.key)?fields=summary,description,status,issuetype,labels,parent,issuelinks"
            $issueBySource[[string]$record.sourceId] = $fresh
            $comment = [ordered]@{ body = [ordered]@{ type = 'doc'; version = 1; content = @(New-AdfParagraph ("[catalog:v1.2] {0}" -f $record.decisionNoteVi)) } }
            Invoke-Jira 'POST' "issue/$($created.key)/comment" $comment | Out-Null
            $progress += 1
        }
        if ($progress -eq 0) { throw "Cannot resolve parents for: $($remaining.sourceId -join ', ')" }
        $pendingCreates = $remaining
    }

    foreach ($record in @($catalog.issues | Where-Object { $_.manageDescription })) {
        $current = $issueBySource[[string]$record.sourceId]
        $readiness = Get-Readiness $record $issueBySource
        $desiredDescription = New-AdfDescription $record $readiness
        $desiredLabels = Get-DesiredLabels $record @($current.fields.labels) $readiness
        $desiredSpecLabel = Get-SpecLabel $record
        $fields = [ordered]@{}
        if ([string]$current.fields.summary -cne [string]$record.summary) { $fields.summary = $record.summary }
        if ($desiredSpecLabel -notin @($current.fields.labels) -and (Get-NormalJson $current.fields.description) -cne (Get-NormalJson $desiredDescription)) { $fields.description = $desiredDescription }
        if (-not (Test-LabelsEqual @($current.fields.labels) $desiredLabels)) { $fields.labels = $desiredLabels }
        if ($fields.Count -gt 0) {
            Invoke-Jira 'PUT' "issue/$($current.key)" @{ fields = $fields } | Out-Null
            if ('roadmap-v1-2' -notin @($current.fields.labels)) {
                $comment = [ordered]@{ body = [ordered]@{ type = 'doc'; version = 1; content = @(New-AdfParagraph ("[catalog:v1.2] {0}" -f $record.decisionNoteVi)) } }
                Invoke-Jira 'POST' "issue/$($current.key)/comment" $comment | Out-Null
            }
        }
    }

    $refreshed = @(Get-AllIssues $catalog.projectKey)
    $issueBySource = @{}
    foreach ($issue in $refreshed) { $source = Get-SourceId $issue; if ($source) { $issueBySource[$source] = $issue } }
    foreach ($record in @($catalog.issues)) {
        foreach ($dependency in @($record.dependencies)) {
            $from = $issueBySource[[string]$record.sourceId]
            $to = $issueBySource[[string]$dependency.sourceId]
            if ($null -eq $from -or $null -eq $to) { continue }
            $linkedKeys = Get-LinkedKeys $from
            if ($to.key -in $linkedKeys) { continue }
            if ($dependency.relation -eq 'blocks') {
                $linkBody = @{ type = @{ name = 'Blocks' }; inwardIssue = @{ key = $to.key }; outwardIssue = @{ key = $from.key } }
            } elseif ($dependency.relation -eq 'is-blocked-by') {
                $linkBody = @{ type = @{ name = 'Blocks' }; inwardIssue = @{ key = $from.key }; outwardIssue = @{ key = $to.key } }
            } else {
                $linkBody = @{ type = @{ name = 'Relates' }; inwardIssue = @{ key = $from.key }; outwardIssue = @{ key = $to.key } }
            }
            Invoke-Jira 'POST' 'issueLink' $linkBody | Out-Null
        }
    }

    if ($AllowTransitions) {
        Write-Warning 'AllowTransitions was requested, but catalog v1.2 intentionally contains no workflow transition directive; statuses were preserved.'
    }
    [pscustomobject]@{ mode = $Mode; backup = $backupPath; plannedChanges = $plan.Count; applied = $true; statusTransitions = 0 } | ConvertTo-Json -Depth 10
}
finally {
    $plainToken = $null
    $basic = $null
    $script:Headers = $null
}
