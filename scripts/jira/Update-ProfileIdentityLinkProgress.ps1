[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('DryRun', 'Apply')]
    [string]$Mode = 'DryRun',
    [string]$CredentialPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $CredentialPath) {
    $CredentialPath = Join-Path $PSScriptRoot '..\..\..\.secrets\jira-api.xml'
}
$marker = '[PROFILE-LINK-V16-2026-11-11]'
$revision = '[PROFILE-LINK-E2E-COMPLETE-V2]'
$issueKeys = @('SCRUM-428', 'SCRUM-831')

function ConvertFrom-AdfText($Node) {
    if ($null -eq $Node) { return '' }
    if ($Node -is [System.Array]) {
        return (($Node | ForEach-Object { ConvertFrom-AdfText $_ }) -join ' ')
    }
    $parts = @()
    if ($Node.PSObject.Properties.Name -contains 'text') { $parts += [string]$Node.text }
    if ($Node.PSObject.Properties.Name -contains 'content') { $parts += ConvertFrom-AdfText $Node.content }
    return ($parts -join ' ').Trim()
}

function New-Text([string]$Value) {
    return [ordered]@{ type = 'text'; text = $Value }
}

function New-Paragraph([string]$Value) {
    return [ordered]@{ type = 'paragraph'; content = @(New-Text $Value) }
}

function New-BulletList([string[]]$Items) {
    return [ordered]@{
        type = 'bulletList'
        content = @($Items | ForEach-Object {
            [ordered]@{
                type = 'listItem'
                content = @([ordered]@{ type = 'paragraph'; content = @(New-Text $_) })
            }
        })
    }
}

function Invoke-Jira([string]$Method, [string]$Path, $Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = "$script:Site/rest/api/3/$Path"
        Headers = $script:Headers
        ContentType = 'application/json; charset=utf-8'
    }
    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 30 -Compress
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($jsonBody)
    }
    return Invoke-RestMethod @parameters
}

$credential = Import-Clixml -LiteralPath $CredentialPath
$plainToken = [System.Net.NetworkCredential]::new('', $credential.ApiToken).Password
$script:Site = ([string]$credential.Site).TrimEnd('/')
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($credential.Email):$plainToken"))
$script:Headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }

try {
    foreach ($issueKey in $issueKeys) {
        $issue = Invoke-Jira 'GET' "issue/$issueKey`?fields=summary,status"
        $comments = Invoke-Jira 'GET' "issue/$issueKey/comment?maxResults=100&orderBy=-created"
        $existing = @($comments.comments | Where-Object {
            (ConvertFrom-AdfText $_.body).Contains($marker)
        } | Select-Object -First 1)

        if ($existing.Count -gt 0 -and (ConvertFrom-AdfText $existing[0].body).Contains($revision)) {
            Write-Output "$issueKey SKIPPED latest revision already present; status=$($issue.fields.status.name)"
            continue
        }

        $body = [ordered]@{
            body = [ordered]@{
                type = 'doc'
                version = 1
                content = @(
                    (New-Paragraph "$marker $revision Local implementation and verification complete (not a Done transition)."),
                    (New-BulletList @(
                        'User Service is the profile identity source of truth. V16 scopes CCCD uniqueness by profile type, stores no plaintext, and uses versioned Vault Transit HMAC for matching plus Vault Transit ciphertext for controlled recovery/re-verification.',
                        'Implemented CUSTOMER/HOST/ADMIN linking policies, duplicate-safe request and OTP state, email-only OTP delivery, maker-checker approval for HOST/ADMIN, stale/unlinked account expiry, audit/outbox, idempotency and pending out-of-order event handling.',
                        'Implemented GraphQL document protection, self-service link request/verify/status, admin review/approve/reject and user directory operations. Runtime permission checks are resolver-bound and fail closed.',
                        'Notification Service consumes challenge events, decrypts the destination through Vault, sends through the configured SMTP/Mailpit path and emits a delivery acknowledgement. Authentication consumes request/link events idempotently and projects the final profile ID into the correct Keycloak realm.',
                        'Customer and Host portals now use Authorization Code + PKCE and expose onboarding/linking flows without a mobile-specific API. Admin Web and Admin Mobile include Customer/Staff/Host directory surfaces; Admin Web includes permission-aware HOST/ADMIN review actions.',
                        'Keycloak bootstrap is repeatable for existing volumes and fresh realms: realm-local service clients, registration settings, managed profile-link attributes and reconciliation are applied by a one-shot Compose initializer.',
                        'V17 normalizes runtime permissions to canonical kebab-case while preserving time-bounded inactive aliases. Current registry evidence: 117 total entries, 107 active and 10 inactive compatibility entries.',
                        'E2E evidence: router request -> Vault HMAC/cipher match -> Mailpit OTP -> verification -> User LINKED/VERIFIED -> Authentication ACTIVE -> Keycloak vistay_profile_id projection passed, with test evidence removed afterward.',
                        'Runtime remediation evidence: Property now has a dedicated spiffe://vistay/service/property mTLS client identity for User role-policy lookup; Booking -> Property authority availability plus Property operational summary passed through the backoffice router in one authenticated smoke request.',
                        'Backoffice Keycloak role scope no longer injects the unrelated account audience. Tokens retain the required vistay-backoffice-api audience and resource_access client roles, so strict router validation accepts real portal tokens.',
                        'Automated evidence passed: service_user, service_authentication and service_notification test suites; platform_contracts schema/architecture catalog tests (589); Admin Web build plus API/UI tests; Admin Mobile typecheck/lint; Customer and Host production builds; Property hierarchy tests; Compose config validation.',
                        'No implementation item remains locally. Release gates still external to this change set: commit review, push/PR into dev, CI green, promotion to test and environment smoke/Newman evidence.'
                    )),
                    (New-Paragraph 'Repositories: service_user, service_notification, service_authentication, platform_contracts, platform_infrastructure, frontend_customer, frontend_host, frontend_admin and service_property. No workflow transition was made by this evidence update.')
                )
            }
        }

        if ($Mode -eq 'Apply') {
            if ($existing.Count -gt 0) {
                $updated = Invoke-Jira 'PUT' "issue/$issueKey/comment/$($existing[0].id)" $body
                Write-Output "$issueKey UPDATED commentId=$($updated.id); status=$($issue.fields.status.name)"
            }
            else {
                $created = Invoke-Jira 'POST' "issue/$issueKey/comment" $body
                Write-Output "$issueKey COMMENTED commentId=$($created.id); status=$($issue.fields.status.name)"
            }
        }
        else {
            $action = if ($existing.Count -gt 0) { 'update' } else { 'comment' }
            Write-Output "$issueKey DRY-RUN would $action; status=$($issue.fields.status.name); summary=$($issue.fields.summary)"
        }
    }
}
finally {
    $plainToken = $null
    $basic = $null
    $script:Headers = $null
}
