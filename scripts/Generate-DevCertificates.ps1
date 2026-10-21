[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $StorePassword
)

$ErrorActionPreference = 'Stop'
$outputDirectory = Join-Path $PSScriptRoot '..\certs\generated\kafka'
$resolvedOutput = [System.IO.Path]::GetFullPath($outputDirectory)

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$caStore = Join-Path $resolvedOutput 'ca.p12'
$caCertificate = Join-Path $resolvedOutput 'ca.crt'
$brokerStore = Join-Path $resolvedOutput 'kafka.keystore.jks'
$brokerRequest = Join-Path $resolvedOutput 'kafka.csr'
$brokerCertificate = Join-Path $resolvedOutput 'kafka.crt'
$trustStore = Join-Path $resolvedOutput 'kafka.truststore.jks'
$adminStore = Join-Path $resolvedOutput 'admin.keystore.jks'
$adminRequest = Join-Path $resolvedOutput 'admin.csr'
$adminCertificate = Join-Path $resolvedOutput 'admin.crt'

function Invoke-Keytool {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
    & keytool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed with exit code $LASTEXITCODE"
    }
}

Invoke-Keytool -genkeypair -alias vistay-dev-ca -keyalg RSA -keysize 4096 `
    -dname 'CN=ViStay Development CA,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
    -ext 'bc:c' -validity 3650 -storetype PKCS12 -keystore $caStore `
    -storepass $StorePassword -keypass $StorePassword -noprompt
Invoke-Keytool -exportcert -rfc -alias vistay-dev-ca -keystore $caStore `
    -storepass $StorePassword -file $caCertificate

Invoke-Keytool -genkeypair -alias kafka -keyalg RSA -keysize 3072 `
    -dname 'CN=kafka,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
    -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1' -validity 825 `
    -keystore $brokerStore -storepass $StorePassword -keypass $StorePassword -noprompt
Invoke-Keytool -certreq -alias kafka -keystore $brokerStore -storepass $StorePassword `
    -keypass $StorePassword -file $brokerRequest -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1'
Invoke-Keytool -gencert -rfc -alias vistay-dev-ca -keystore $caStore -storepass $StorePassword `
    -infile $brokerRequest -outfile $brokerCertificate -validity 825 `
    -ext 'KU=digitalSignature,keyEncipherment' -ext 'EKU=serverAuth,clientAuth' `
    -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1'

Invoke-Keytool -importcert -alias vistay-dev-ca -file $caCertificate -keystore $brokerStore `
    -storepass $StorePassword -noprompt
Invoke-Keytool -importcert -alias kafka -file $brokerCertificate -keystore $brokerStore `
    -storepass $StorePassword -noprompt
Invoke-Keytool -importcert -alias vistay-dev-ca -file $caCertificate -keystore $trustStore `
    -storepass $StorePassword -noprompt

Invoke-Keytool -genkeypair -alias admin -keyalg RSA -keysize 3072 `
    -dname 'CN=vistay-kafka-admin,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
    -validity 825 -keystore $adminStore -storepass $StorePassword -keypass $StorePassword -noprompt
Invoke-Keytool -certreq -alias admin -keystore $adminStore -storepass $StorePassword `
    -keypass $StorePassword -file $adminRequest
Invoke-Keytool -gencert -rfc -alias vistay-dev-ca -keystore $caStore -storepass $StorePassword `
    -infile $adminRequest -outfile $adminCertificate -validity 825 `
    -ext 'KU=digitalSignature,keyEncipherment' -ext 'EKU=clientAuth'
Invoke-Keytool -importcert -alias vistay-dev-ca -file $caCertificate -keystore $adminStore `
    -storepass $StorePassword -noprompt
Invoke-Keytool -importcert -alias admin -file $adminCertificate -keystore $adminStore `
    -storepass $StorePassword -noprompt

Set-Content -LiteralPath (Join-Path $resolvedOutput 'keystore.credentials') -Value $StorePassword -NoNewline
Set-Content -LiteralPath (Join-Path $resolvedOutput 'truststore.credentials') -Value $StorePassword -NoNewline
Set-Content -LiteralPath (Join-Path $resolvedOutput 'key.credentials') -Value $StorePassword -NoNewline

$adminProperties = @"
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/kafka.truststore.jks
ssl.truststore.password=$StorePassword
ssl.keystore.location=/etc/kafka/secrets/admin.keystore.jks
ssl.keystore.password=$StorePassword
ssl.key.password=$StorePassword
ssl.endpoint.identification.algorithm=https
"@
Set-Content -LiteralPath (Join-Path $resolvedOutput 'admin.properties') -Value $adminProperties -NoNewline

Remove-Item -LiteralPath $brokerRequest, $adminRequest -Force
Write-Output "Development certificates created under $resolvedOutput"
