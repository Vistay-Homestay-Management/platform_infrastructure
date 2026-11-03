[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate', 'DryRun', 'Apply')]
    [string]$Mode = 'Validate',
    [string]$CatalogPath,
    [string]$CredentialPath,
    [string]$BackupRoot,
    [string[]]$SourceId,
    [switch]$AllowCreates,
    [switch]$ConfirmFullApply,
    [switch]$SkipLinks,
    [switch]$AllowTransitions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..\..\..\platform_contracts\docs\jira\jira-catalog.v1.3.json' }
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
            content = @(New-AdfParagraph ("AGENT READINESS: {0} - Catalog schema {1}. Implement only the stated scope; attach required evidence before Done." -f $Readiness.ToUpperInvariant(), $script:CatalogVersion))
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
        $criterionId = if ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id } else { "AC$index" }
        "$criterionId - Given $($_.given); When $($_.when); Then $($_.then)."
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
    if ($Record.PSObject.Properties.Name -contains 'testCases' -and @($Record.testCases).Count -gt 0) {
        $content += New-AdfHeading 'Executable test and evidence map'
        $content += New-AdfBulletList @($Record.testCases | ForEach-Object {
            "$($_.id) [$($_.level)] verifies $(@($_.verifies) -join ', '); command: $($_.command); evidence: $($_.evidence)"
        })
    }
    return [ordered]@{ type = 'doc'; version = 1; content = $content }
}

function ConvertTo-CanonicalObject($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary] -and $Value -isnot [pscustomobject]) {
        return @($Value | ForEach-Object { ConvertTo-CanonicalObject $_ })
    }
    $result = [ordered]@{}
    $properties = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | Sort-Object) } else { @($Value.PSObject.Properties.Name | Sort-Object) }
    foreach ($name in $properties) {
        $child = if ($Value -is [System.Collections.IDictionary]) { $Value[$name] } else { $Value.PSObject.Properties[$name].Value }
        $result[[string]$name] = ConvertTo-CanonicalObject $child
    }
    return $result
}

function Get-NormalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-CanonicalObject $Value | ConvertTo-Json -Depth 100 -Compress)
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
        $fieldList = 'summary,description,status,issuetype,labels,parent,issuelinks,components,priority,assignee,resolution,updated'
        if ($script:ModuleFieldId) { $fieldList += ",$($script:ModuleFieldId)" }
        $fields = [uri]::EscapeDataString($fieldList)
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
    if ($Record.PSObject.Properties.Name -contains 'specStatus') {
        switch ([string]$Record.specStatus) {
            'historical' { return 'historical' }
            'needs-refinement' { return 'needs-refinement' }
            'decision-required' { return 'decision-required' }
            'externally-blocked' { return 'externally-blocked' }
            'refined-parent' { return 'refined-parent' }
            'executable' {
                if (-not [bool]$Record.dispatchable) { throw "$($Record.sourceId): executable record is not dispatchable" }
                if ($Record.PSObject.Properties.Name -contains 'implementationBlockers' -and @($Record.implementationBlockers).Count -gt 0) { return 'externally-blocked' }
            }
            default { throw "$($Record.sourceId): unsupported specStatus $($Record.specStatus)" }
        }
    }
    if (-not ($Record.PSObject.Properties.Name -contains 'specStatus') -and @($Record.externalBlockers).Count -gt 0) { return 'externally-blocked' }
    if ($Record.PSObject.Properties.Name -contains 'decisionStatus' -and $Record.decisionStatus -eq 'decision-required') { return 'decision-required' }
    if ($Record.PSObject.Properties.Name -contains 'parentSourceId') {
        $parentRecord = $script:RecordBySource[[string]$Record.parentSourceId]
        if ($null -ne $parentRecord -and $parentRecord.PSObject.Properties.Name -contains 'specStatus' -and $parentRecord.specStatus -notin @('refined-parent', 'executable', 'historical')) {
            return 'needs-refinement'
        }
    }
    foreach ($dependency in @($Record.dependencies)) {
        if ($dependency.relation -notin @('is-blocked-by', 'remediates')) { continue }
        $target = $IssueBySource[[string]$dependency.sourceId]
        if ($null -eq $target -or $target.fields.status.name -ne 'Done') { return 'agent-ready-after-dependencies' }
    }
    return 'agent-ready'
}

function Get-DesiredLabels($Record, $CurrentLabels, [string]$Readiness) {
    $managed = @('agent-ready', 'agent-ready-after-dependencies', 'decision-required', 'externally-blocked', 'needs-refinement', 'refined-parent', 'historical', 'agent-not-ready', 'roadmap-v1-2', 'roadmap-v1-3')
    $preserved = @($CurrentLabels | Where-Object { $_ -notin $managed -and $_ -notlike 'source-*' -and $_ -notlike 'owner-*' -and $_ -notlike 'spec-*' })
    return @($preserved + @($Record.labels) + $Readiness + (Get-SpecLabel $Record) | Sort-Object -Unique)
}

function Test-LabelsEqual($Left, $Right) {
    return ((@($Left) | Sort-Object) -join "`n") -ceq ((@($Right) | Sort-Object) -join "`n")
}

function Get-DesiredModuleNames($Record) {
    $moduleByRepository = @{
        'cross-service' = 'Cross-service'
        'data_warehouse' = 'Service Data Warehouse'
        'frontend_admin' = 'Frontend Admin'
        'frontend_customer' = 'Frontend Customer'
        'frontend_host' = 'Frontend Host'
        'platform_contracts' = 'Platform Contracts'
        'platform_infrastructure' = 'Platform Infrastructure'
        'service_authentication' = 'Service Authentication'
        'service_booking' = 'Service Booking'
        'service_finance' = 'Service Finance'
        'service_media' = 'Service Media'
        'service_notification' = 'Service Notification'
        'service_operations' = 'Service Operations'
        'service_payment' = 'Service Payment'
        'service_property' = 'Service Property'
        'service_user' = 'Service User'
    }
    return @(@($Record.repositories) | ForEach-Object {
        if ($moduleByRepository.ContainsKey([string]$_)) { $moduleByRepository[[string]$_] }
    } | Sort-Object -Unique)
}

function Get-CurrentModuleOptions($Issue) {
    if (-not $script:ModuleFieldId) { return @() }
    $property = $Issue.fields.PSObject.Properties[$script:ModuleFieldId]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    $flattened = @()
    foreach ($item in @($property.Value)) {
        if ($item -is [System.Array]) { $flattened += @($item) }
        else { $flattened += $item }
    }
    return @($flattened | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains 'value' -and $_.PSObject.Properties.Name -contains 'id'
    })
}

function Get-CurrentModuleNames($Issue) {
    return @((Get-CurrentModuleOptions $Issue) | ForEach-Object { [string]$_.value } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-DesiredModuleOptions($Record) {
    $names = @(Get-DesiredModuleNames $Record)
    $missing = @($names | Where-Object { -not $script:ModuleOptionByName.ContainsKey([string]$_) })
    if ($missing.Count -gt 0) {
        throw "Jira Module option IDs could not be discovered for: $($missing -join ', ')"
    }
    return @($names | ForEach-Object { @{ id = [string]$script:ModuleOptionByName[[string]$_].id } })
}

function Get-MergedModuleOptions($Record, $Issue) {
    $byId = @{}
    foreach ($option in @(Get-CurrentModuleOptions $Issue)) { $byId[[string]$option.id] = @{ id = [string]$option.id } }
    foreach ($option in @(Get-DesiredModuleOptions $Record)) { $byId[[string]$option.id] = $option }
    return @($byId.Values | Sort-Object { [string]$_.id })
}

function Get-LinkedKeys($Issue) {
    return @($Issue.fields.issuelinks | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'inwardIssue') { $_.inwardIssue.key }
        elseif ($_.PSObject.Properties.Name -contains 'outwardIssue') { $_.outwardIssue.key }
    })
}

function Test-DependencyLinkExists($FromIssue, $ToIssue, [string]$Relation) {
    foreach ($link in @($FromIssue.fields.issuelinks)) {
        $typeName = [string]$link.type.name
        if ($Relation -in @('blocks', 'is-blocked-by')) {
            if ($typeName -ne 'Blocks') { continue }
            if ($Relation -eq 'blocks' -and $link.PSObject.Properties.Name -contains 'outwardIssue' -and $link.outwardIssue.key -eq $ToIssue.key) { return $true }
            if ($Relation -eq 'is-blocked-by' -and $link.PSObject.Properties.Name -contains 'inwardIssue' -and $link.inwardIssue.key -eq $ToIssue.key) { return $true }
        }
        elseif ($Relation -in @('relates-to', 'remediates') -and $typeName -eq 'Relates') {
            if (($link.PSObject.Properties.Name -contains 'outwardIssue' -and $link.outwardIssue.key -eq $ToIssue.key) -or
                ($link.PSObject.Properties.Name -contains 'inwardIssue' -and $link.inwardIssue.key -eq $ToIssue.key)) { return $true }
        }
    }
    return $false
}

$CatalogPath = Resolve-FullPath $CatalogPath
$CredentialPath = Resolve-FullPath $CredentialPath
$BackupRoot = Resolve-FullPath $BackupRoot
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "Catalog not found: $CatalogPath" }
if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) { throw "Credential not found: $CredentialPath" }

$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:CatalogVersion = [string]$catalog.schemaVersion
$script:RecordBySource = @{}
foreach ($record in @($catalog.issues)) {
    $catalogSourceId = [string]$record.sourceId
    if ($script:RecordBySource.ContainsKey($catalogSourceId)) { throw "Duplicate catalog Source-ID: $catalogSourceId" }
    $script:RecordBySource[$catalogSourceId] = $record
}
$validator = Join-Path (Split-Path (Split-Path $CatalogPath -Parent) -Parent) '..\scripts\validate-jira-catalog.mjs'
$validator = Resolve-FullPath $validator
& node $validator $CatalogPath
if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed.' }
$requestedSourceIds = @($SourceId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$managedRecords = if ($requestedSourceIds.Count -gt 0) {
    $unknownSources = @($requestedSourceIds | Where-Object { -not $script:RecordBySource.ContainsKey([string]$_) })
    if ($unknownSources.Count -gt 0) { throw "Requested Source-ID is absent from catalog: $($unknownSources -join ', ')" }
    @($requestedSourceIds | ForEach-Object { $script:RecordBySource[[string]$_] })
} else {
    @($catalog.issues)
}
if ($Mode -eq 'Apply' -and $requestedSourceIds.Count -eq 0 -and -not $ConfirmFullApply) {
    throw 'Full-catalog Apply is disabled by default. Supply up to five -SourceId values for a canary, or explicitly use -ConfirmFullApply.'
}
if ($Mode -eq 'Apply' -and $requestedSourceIds.Count -gt 5 -and -not $ConfirmFullApply) {
    throw 'Canary Apply accepts at most five Source-IDs unless -ConfirmFullApply is explicitly supplied.'
}
if ($Mode -eq 'Validate') {
    [pscustomobject]@{ mode = $Mode; catalog = $CatalogPath; issueCount = @($catalog.issues).Count; selectedCount = @($managedRecords).Count; valid = $true } | ConvertTo-Json
    return
}

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [System.Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
try {
    $allJiraFields = @(Invoke-Jira 'GET' 'field')
    if ($allJiraFields.Count -eq 1 -and $allJiraFields[0] -is [System.Array]) { $allJiraFields = @($allJiraFields[0]) }
    $moduleFields = @($allJiraFields | Where-Object { $_.custom -and $_.name -eq 'Module' })
    if ($moduleFields.Count -gt 1) { throw 'Multiple Jira custom fields named Module were found.' }
    $script:ModuleFieldId = if ($moduleFields.Count -eq 1) { [string]$moduleFields[0].id } else { $null }
    $currentIssues = @(Get-AllIssues $catalog.projectKey)
    $script:ModuleOptionByName = @{}
    if ($script:ModuleFieldId) {
        $editMetaIssue = @($currentIssues | Select-Object -First 1)
        if ($editMetaIssue.Count -eq 1) {
            try {
                $editMeta = Invoke-Jira 'GET' "issue/$($editMetaIssue[0].key)/editmeta"
                $editMetaProperty = $editMeta.fields.PSObject.Properties[$script:ModuleFieldId]
                if ($null -ne $editMetaProperty) {
                    foreach ($option in @($editMetaProperty.Value.allowedValues)) {
                        if ($null -ne $option -and $option.value -and $option.id) {
                            $script:ModuleOptionByName[[string]$option.value] = $option
                        }
                    }
                }
            } catch {
                Write-Warning "Jira Module allowed values could not be read from edit metadata; falling back to observed issue values. $($_.Exception.Message)"
            }
        }
        foreach ($issue in $currentIssues) {
            foreach ($option in @(Get-CurrentModuleOptions $issue)) {
                if ($null -ne $option -and $option.value -and $option.id) {
                    $script:ModuleOptionByName[[string]$option.value] = $option
                }
            }
        }
    }
    $issueBySource = @{}
    foreach ($issue in $currentIssues) {
        $source = Get-SourceId $issue
        if ($source) {
            if ($issueBySource.ContainsKey([string]$source)) { throw "Duplicate live Jira Source-ID $source on $($issueBySource[$source].key) and $($issue.key)" }
            $issueBySource[$source] = $issue
        }
    }
    $unmanagedLive = @($issueBySource.Keys | Where-Object { -not $script:RecordBySource.ContainsKey([string]$_) } | Sort-Object)
    if ($unmanagedLive.Count -gt 0) { throw "Live Jira contains Source-IDs absent from catalog: $($unmanagedLive -join ', ')" }
    foreach ($record in @($managedRecords)) {
        $current = $issueBySource[[string]$record.sourceId]
        if ($null -ne $current -and $record.PSObject.Properties.Name -contains 'jiraKey' -and [string]$record.jiraKey -ne [string]$current.key) {
            throw "$($record.sourceId): catalog jiraKey $($record.jiraKey) does not match live key $($current.key)"
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupPath = Join-Path $BackupRoot "jira-$($catalog.projectKey)-$timestamp.json"
    [ordered]@{ capturedAt = (Get-Date).ToString('o'); project = $catalog.projectKey; issues = $currentIssues } |
        ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backupPath -Encoding utf8

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($managedRecords)) {
        $current = $issueBySource[[string]$record.sourceId]
        if ($null -eq $current) {
            if (-not $AllowCreates) { throw "$($record.sourceId): missing from Jira; rerun with -AllowCreates only after reviewing the catalog identity and parent" }
            $createFields = @('summary', 'description', 'labels', 'parent')
            if ($script:ModuleFieldId -and @(Get-DesiredModuleNames $record).Count -gt 0) { $createFields += 'Module' }
            $plan.Add([pscustomobject]@{ action = 'create'; sourceId = $record.sourceId; jiraKey = $null; fields = $createFields })
            continue
        }
        $changed = @()
        if ([string]$current.fields.issuetype.name -cne [string]$record.issueType) { $changed += 'issueType' }
        $desiredParentKey = if ($record.PSObject.Properties.Name -contains 'parentSourceId') { [string]$issueBySource[[string]$record.parentSourceId].key } else { $null }
        $currentParentKey = if ($current.fields.PSObject.Properties.Name -contains 'parent' -and $null -ne $current.fields.parent) { [string]$current.fields.parent.key } else { $null }
        if ($desiredParentKey -cne $currentParentKey) { $changed += 'parent' }
        $desiredModuleNames = @(Get-DesiredModuleNames $record)
        $currentModuleNames = @(Get-CurrentModuleNames $current)
        if ($script:ModuleFieldId -and (($desiredModuleNames -join "`n") -cne ($currentModuleNames -join "`n"))) { $changed += 'Module' }
        if (-not $record.manageDescription) {
            if ($changed.Count -gt 0) {
                $plan.Add([pscustomobject]@{ action = 'update'; sourceId = $record.sourceId; jiraKey = $current.key; fields = $changed })
            }
            continue
        }
        $readiness = Get-Readiness $record $issueBySource
        $desiredDescription = New-AdfDescription $record $readiness
        $desiredLabels = Get-DesiredLabels $record @($current.fields.labels) $readiness
        $desiredSpecLabel = Get-SpecLabel $record
        if ([string]$current.fields.summary -cne [string]$record.summary) { $changed += 'summary' }
        if ((Get-NormalJson $current.fields.description) -cne (Get-NormalJson $desiredDescription)) { $changed += 'description' }
        if (-not (Test-LabelsEqual @($current.fields.labels) $desiredLabels)) { $changed += 'labels' }
        if ($changed.Count -gt 0) {
            $plan.Add([pscustomobject]@{ action = 'update'; sourceId = $record.sourceId; jiraKey = $current.key; fields = $changed })
        }
    }

    if (-not $SkipLinks) {
        foreach ($record in @($managedRecords)) {
            foreach ($dependency in @($record.dependencies)) {
                $from = $issueBySource[[string]$record.sourceId]
                $to = $issueBySource[[string]$dependency.sourceId]
                if ($null -eq $from -or $null -eq $to) { continue }
                if (-not (Test-DependencyLinkExists $from $to ([string]$dependency.relation))) {
                    $plan.Add([pscustomobject]@{ action = 'link'; sourceId = $record.sourceId; jiraKey = $from.key; fields = @("$($dependency.relation):$($dependency.sourceId)") })
                }
            }
        }
    }

    if ($Mode -eq 'DryRun') {
        $planPath = Join-Path $BackupRoot "plan-$($catalog.projectKey)-$timestamp.json"
        $planJson = if ($plan.Count -eq 0) { '[]' } else { $plan | ConvertTo-Json -Depth 20 }
        $planJson | Set-Content -LiteralPath $planPath -Encoding utf8
        [pscustomobject]@{ mode = $Mode; backup = $backupPath; plan = $planPath; changes = $plan.Count; byAction = $plan | Group-Object action | ForEach-Object { @{ action = $_.Name; count = $_.Count } } } | ConvertTo-Json -Depth 10
        return
    }

    # Abort the entire apply if any issue changed after the backup/plan read.
    $latestIssues = @(Get-AllIssues $catalog.projectKey)
    $latestByKey = @{}
    foreach ($issue in $latestIssues) { $latestByKey[[string]$issue.key] = $issue }
    $concurrentChanges = @($currentIssues | Where-Object {
        $latest = $latestByKey[[string]$_.key]
        $null -eq $latest -or [string]$latest.fields.updated -ne [string]$_.fields.updated
    } | ForEach-Object { $_.key })
    if ($concurrentChanges.Count -gt 0) {
        throw "Jira changed after backup; no mutations were applied. Review and retry: $($concurrentChanges -join ', ')"
    }

    $project = Invoke-Jira 'GET' "project/$($catalog.projectKey)"
    $issueTypeResponse = Invoke-Jira 'GET' "issuetype/project?projectId=$($project.id)&maxResults=100"
    $issueTypes = if ($issueTypeResponse.PSObject.Properties.Name -contains 'values') { @($issueTypeResponse.values) } else { @($issueTypeResponse) }
    $typeByName = @{}
    foreach ($type in $issueTypes) { $typeByName[[string]$type.name] = $type }

    $pendingCreates = @($managedRecords | Where-Object { -not $issueBySource.ContainsKey([string]$_.sourceId) })
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
            if ($script:ModuleFieldId -and @(Get-DesiredModuleNames $record).Count -gt 0) {
                $fields[$script:ModuleFieldId] = @(Get-DesiredModuleOptions $record)
            }
            if ($recordParent) { $fields.parent = @{ key = $issueBySource[$recordParent].key } }
            $created = Invoke-Jira 'POST' 'issue' @{ fields = $fields }
            $freshFields = 'summary,description,status,issuetype,labels,parent,issuelinks'
            if ($script:ModuleFieldId) { $freshFields += ",$($script:ModuleFieldId)" }
            $fresh = Invoke-Jira 'GET' "issue/$($created.key)?fields=$freshFields"
            $issueBySource[[string]$record.sourceId] = $fresh
            $comment = [ordered]@{ body = [ordered]@{ type = 'doc'; version = 1; content = @(New-AdfParagraph ("[catalog:v$($script:CatalogVersion)] {0}" -f $record.decisionNoteVi)) } }
            Invoke-Jira 'POST' "issue/$($created.key)/comment" $comment | Out-Null
            $progress += 1
        }
        if ($progress -eq 0) { throw "Cannot resolve parents for: $($remaining.sourceId -join ', ')" }
        $pendingCreates = $remaining
    }

    foreach ($record in @($managedRecords)) {
        $current = $issueBySource[[string]$record.sourceId]
        $fields = [ordered]@{}
        if ([string]$current.fields.issuetype.name -cne [string]$record.issueType) {
            $jiraType = $typeByName[[string]$record.issueType]
            if ($null -eq $jiraType) { throw "$($record.sourceId): Jira issue type is unavailable: $($record.issueType)" }
            $fields.issuetype = @{ id = [string]$jiraType.id }
        }
        $desiredParentKey = if ($record.PSObject.Properties.Name -contains 'parentSourceId') { [string]$issueBySource[[string]$record.parentSourceId].key } else { $null }
        $currentParentKey = if ($current.fields.PSObject.Properties.Name -contains 'parent' -and $null -ne $current.fields.parent) { [string]$current.fields.parent.key } else { $null }
        if ($desiredParentKey -cne $currentParentKey) {
            $fields.parent = if ($desiredParentKey) { @{ key = $desiredParentKey } } else { $null }
        }
        if ($record.manageDescription) {
            $readiness = Get-Readiness $record $issueBySource
            $desiredDescription = New-AdfDescription $record $readiness
            $desiredLabels = Get-DesiredLabels $record @($current.fields.labels) $readiness
            $desiredSpecLabel = Get-SpecLabel $record
            if ([string]$current.fields.summary -cne [string]$record.summary) { $fields.summary = $record.summary }
            if ((Get-NormalJson $current.fields.description) -cne (Get-NormalJson $desiredDescription)) { $fields.description = $desiredDescription }
            if (-not (Test-LabelsEqual @($current.fields.labels) $desiredLabels)) { $fields.labels = $desiredLabels }
        }
        $desiredModuleNames = @(Get-DesiredModuleNames $record)
        $currentModuleNames = @(Get-CurrentModuleNames $current)
        if ($script:ModuleFieldId -and (($desiredModuleNames -join "`n") -cne ($currentModuleNames -join "`n"))) {
            $fields[$script:ModuleFieldId] = @(Get-DesiredModuleOptions $record)
        }
        if ($fields.Count -gt 0) {
            Invoke-Jira 'PUT' "issue/$($current.key)" @{ fields = $fields } | Out-Null
            if ($record.manageDescription -and 'roadmap-v1-2' -notin @($current.fields.labels)) {
                $comment = [ordered]@{ body = [ordered]@{ type = 'doc'; version = 1; content = @(New-AdfParagraph ("[catalog:v$($script:CatalogVersion)] {0}" -f $record.decisionNoteVi)) } }
                Invoke-Jira 'POST' "issue/$($current.key)/comment" $comment | Out-Null
            }
        }
    }

    $refreshed = @(Get-AllIssues $catalog.projectKey)
    $issueBySource = @{}
    foreach ($issue in $refreshed) { $source = Get-SourceId $issue; if ($source) { $issueBySource[$source] = $issue } }
    if (-not $SkipLinks) {
        foreach ($record in @($managedRecords)) {
            foreach ($dependency in @($record.dependencies)) {
                $from = $issueBySource[[string]$record.sourceId]
                $to = $issueBySource[[string]$dependency.sourceId]
                if ($null -eq $from -or $null -eq $to) { continue }
                if (Test-DependencyLinkExists $from $to ([string]$dependency.relation)) { continue }
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
    $script:ModuleFieldId = $null
    $script:ModuleOptionByName = $null
    $script:CatalogVersion = $null
    $script:RecordBySource = $null
}
