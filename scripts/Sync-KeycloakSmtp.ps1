param(
    [string]$ContainerName = 'vistay-keycloak-1',
    [string]$AdminUser,
    [string]$AdminPassword
)

$ErrorActionPreference = 'Stop'

function Get-ContainerEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = & docker exec $ContainerName printenv $Name
    if ($LASTEXITCODE -ne 0) {
        throw "Keycloak container is missing environment variable '$Name'."
    }
    return "$value".Trim()
}

$inspectionJson = & docker inspect $ContainerName
if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect local container: $ContainerName"
}
$inspection = @($inspectionJson | ConvertFrom-Json)
$serviceName = $inspection[0].Config.Labels.'com.docker.compose.service'
if ($serviceName -ne 'keycloak') {
    throw "Refusing to update a container that is not the local Compose keycloak service: $ContainerName"
}

if ([string]::IsNullOrWhiteSpace($AdminUser)) {
    $AdminUser = Get-ContainerEnvironmentValue -Name 'KC_BOOTSTRAP_ADMIN_USERNAME'
}
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $AdminPassword = Get-ContainerEnvironmentValue -Name 'KC_BOOTSTRAP_ADMIN_PASSWORD'
}

& docker exec $ContainerName /opt/keycloak/bin/kcadm.sh config credentials `
    --server http://localhost:8080 --realm master --user $AdminUser --password $AdminPassword | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Keycloak admin authentication failed.'
}

$realmSettings = @(
    @{ Realm = 'vistay-backoffice'; Prefix = 'VISTAY_BACKOFFICE_SMTP' },
    @{ Realm = 'vistay-customer'; Prefix = 'VISTAY_CUSTOMER_SMTP' },
    @{ Realm = 'vistay-host'; Prefix = 'VISTAY_HOST_SMTP' }
)

foreach ($setting in $realmSettings) {
    $realm = $setting.Realm
    $prefix = $setting.Prefix
    $hostName = Get-ContainerEnvironmentValue -Name "${prefix}_HOST"
    $port = Get-ContainerEnvironmentValue -Name "${prefix}_PORT"
    $from = Get-ContainerEnvironmentValue -Name "${prefix}_FROM"
    $auth = Get-ContainerEnvironmentValue -Name "${prefix}_AUTH"
    $startTls = Get-ContainerEnvironmentValue -Name "${prefix}_STARTTLS"
    $ssl = Get-ContainerEnvironmentValue -Name "${prefix}_SSL"
    $user = Get-ContainerEnvironmentValue -Name "${prefix}_USER"
    $password = Get-ContainerEnvironmentValue -Name "${prefix}_PASSWORD"

    if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($port) -or [string]::IsNullOrWhiteSpace($from)) {
        throw "SMTP host, port and sender are required for realm '$realm'."
    }

    & docker exec $ContainerName /opt/keycloak/bin/kcadm.sh update "realms/$realm" `
        -s "smtpServer.host=$hostName" `
        -s "smtpServer.port=$port" `
        -s "smtpServer.from=$from" `
        -s "smtpServer.auth=$auth" `
        -s "smtpServer.starttls=$startTls" `
        -s "smtpServer.ssl=$ssl" `
        -s "smtpServer.user=$user" `
        -s "smtpServer.password=$password" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not update SMTP settings for realm '$realm'."
    }

    Write-Host "Synchronized SMTP settings for $realm ($hostName`:$port, sender $from)."
}
