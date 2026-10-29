[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $StorePassword
)

$ErrorActionPreference = 'Stop'
$generatedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\certs\generated'))
$certificatesRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\certs'))

if ((Split-Path -Parent $generatedRoot) -ne $certificatesRoot -or
    (Split-Path -Leaf $generatedRoot) -ne 'generated') {
    throw 'Refusing to generate certificates outside certs/generated.'
}

if (Test-Path -LiteralPath $generatedRoot) {
    Remove-Item -LiteralPath $generatedRoot -Recurse -Force
}

$kafkaBrokerOutput = Join-Path $generatedRoot 'kafka\broker'
$kafkaAdminOutput = Join-Path $generatedRoot 'kafka\admin'
$kafkaClientOutput = Join-Path $generatedRoot 'kafka\client'
$grpcServerOutput = Join-Path $generatedRoot 'grpc\user-server'
$grpcClientOutput = Join-Path $generatedRoot 'grpc\authentication-client'
$grpcBookingClientOutput = Join-Path $generatedRoot 'grpc\booking-client'
$grpcFinanceClientOutput = Join-Path $generatedRoot 'grpc\finance-client'
$grpcPaymentClientOutput = Join-Path $generatedRoot 'grpc\payment-client'
$grpcNotificationClientOutput = Join-Path $generatedRoot 'grpc\notification-client'
$workDirectory = Join-Path $generatedRoot '.work'

foreach ($directory in @(
    $kafkaBrokerOutput,
    $kafkaAdminOutput,
    $kafkaClientOutput,
    $grpcServerOutput,
    $grpcClientOutput,
    $grpcBookingClientOutput,
    $grpcFinanceClientOutput,
    $grpcPaymentClientOutput,
    $grpcNotificationClientOutput,
    $workDirectory
)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Invoke-Keytool {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
    & keytool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed with exit code $LASTEXITCODE"
    }
}

$openSslCommand = Get-Command openssl -ErrorAction SilentlyContinue
$openSslExecutable = if ($openSslCommand) {
    $openSslCommand.Source
}
else {
    @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($openSslExecutable)) {
    throw 'OpenSSL is required to generate the development gRPC PEM bundle.'
}

function Invoke-OpenSsl {
    param([string[]] $OpenSslArguments)
    & $openSslExecutable @OpenSslArguments
    if ($LASTEXITCODE -ne 0) {
        throw "openssl failed with exit code $LASTEXITCODE"
    }
}

try {
    $kafkaCaStore = Join-Path $workDirectory 'kafka-ca.p12'
    $kafkaCaCertificate = Join-Path $workDirectory 'kafka-ca.crt'
    $brokerStore = Join-Path $kafkaBrokerOutput 'kafka.keystore.jks'
    $brokerRequest = Join-Path $workDirectory 'kafka.csr'
    $brokerCertificate = Join-Path $workDirectory 'kafka.crt'
    $trustStore = Join-Path $workDirectory 'kafka.truststore.jks'
    $adminStore = Join-Path $kafkaAdminOutput 'admin.keystore.jks'
    $adminRequest = Join-Path $workDirectory 'admin.csr'
    $adminCertificate = Join-Path $workDirectory 'admin.crt'

    Invoke-Keytool -genkeypair -alias vistay-dev-ca -keyalg RSA -keysize 4096 `
        -dname 'CN=ViStay Development CA,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
        -ext 'bc:c' -validity 3650 -storetype PKCS12 -keystore $kafkaCaStore `
        -storepass $StorePassword -keypass $StorePassword -noprompt
    Invoke-Keytool -exportcert -rfc -alias vistay-dev-ca -keystore $kafkaCaStore `
        -storepass $StorePassword -file $kafkaCaCertificate

    Invoke-Keytool -genkeypair -alias kafka -keyalg RSA -keysize 3072 `
        -dname 'CN=kafka,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
        -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1' -validity 825 `
        -storetype JKS -keystore $brokerStore -storepass $StorePassword -keypass $StorePassword -noprompt
    Invoke-Keytool -certreq -alias kafka -keystore $brokerStore -storepass $StorePassword `
        -keypass $StorePassword -file $brokerRequest -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1'
    Invoke-Keytool -gencert -rfc -alias vistay-dev-ca -keystore $kafkaCaStore -storepass $StorePassword `
        -infile $brokerRequest -outfile $brokerCertificate -validity 825 `
        -ext 'KU=digitalSignature,keyEncipherment' -ext 'EKU=serverAuth,clientAuth' `
        -ext 'SAN=dns:kafka,dns:localhost,ip:127.0.0.1'
    Invoke-Keytool -importcert -alias vistay-dev-ca -file $kafkaCaCertificate -keystore $brokerStore `
        -storepass $StorePassword -noprompt
    Invoke-Keytool -importcert -alias kafka -file $brokerCertificate -keystore $brokerStore `
        -storepass $StorePassword -noprompt
    Invoke-Keytool -importcert -alias vistay-dev-ca -file $kafkaCaCertificate -keystore $trustStore `
        -storetype JKS -storepass $StorePassword -noprompt

    Invoke-Keytool -genkeypair -alias admin -keyalg RSA -keysize 3072 `
        -dname 'CN=vistay-kafka-admin,OU=Platform,O=ViStay,L=Ho Chi Minh City,C=VN' `
        -validity 825 -storetype JKS -keystore $adminStore `
        -storepass $StorePassword -keypass $StorePassword -noprompt
    Invoke-Keytool -certreq -alias admin -keystore $adminStore -storepass $StorePassword `
        -keypass $StorePassword -file $adminRequest
    Invoke-Keytool -gencert -rfc -alias vistay-dev-ca -keystore $kafkaCaStore -storepass $StorePassword `
        -infile $adminRequest -outfile $adminCertificate -validity 825 `
        -ext 'KU=digitalSignature,keyEncipherment' -ext 'EKU=clientAuth'
    Invoke-Keytool -importcert -alias vistay-dev-ca -file $kafkaCaCertificate -keystore $adminStore `
        -storepass $StorePassword -noprompt
    Invoke-Keytool -importcert -alias admin -file $adminCertificate -keystore $adminStore `
        -storepass $StorePassword -noprompt

    foreach ($destination in @($kafkaBrokerOutput, $kafkaAdminOutput, $kafkaClientOutput)) {
        Copy-Item -LiteralPath $trustStore -Destination (Join-Path $destination 'kafka.truststore.jks')
    }

    $brokerProperties = @"
security.protocol=SSL
ssl.truststore.location=/etc/kafka/broker/kafka.truststore.jks
ssl.truststore.password=$StorePassword
ssl.keystore.location=/etc/kafka/broker/kafka.keystore.jks
ssl.keystore.password=$StorePassword
ssl.key.password=$StorePassword
ssl.endpoint.identification.algorithm=https
"@
    Set-Content -LiteralPath (Join-Path $kafkaBrokerOutput 'broker.properties') `
        -Value $brokerProperties -NoNewline

    $adminProperties = @"
security.protocol=SSL
ssl.truststore.location=/etc/kafka/admin/kafka.truststore.jks
ssl.truststore.password=$StorePassword
ssl.keystore.location=/etc/kafka/admin/admin.keystore.jks
ssl.keystore.password=$StorePassword
ssl.key.password=$StorePassword
ssl.endpoint.identification.algorithm=https
"@
    Set-Content -LiteralPath (Join-Path $kafkaAdminOutput 'admin.properties') `
        -Value $adminProperties -NoNewline

    $grpcCaKey = Join-Path $workDirectory 'grpc-ca.key'
    $grpcCaCertificate = Join-Path $workDirectory 'grpc-ca.crt'
    $grpcCaSerial = Join-Path $workDirectory 'grpc-ca.srl'
    $grpcServerKey = Join-Path $grpcServerOutput 'server.key'
    $grpcServerRequest = Join-Path $workDirectory 'server.csr'
    $grpcServerCertificate = Join-Path $grpcServerOutput 'server.crt'
    $grpcServerExtensions = Join-Path $workDirectory 'server.ext'
    $grpcAuthenticationKey = Join-Path $grpcClientOutput 'authentication.key'
    $grpcAuthenticationRequest = Join-Path $workDirectory 'authentication.csr'
    $grpcAuthenticationCertificate = Join-Path $grpcClientOutput 'authentication.crt'
    $grpcAuthenticationExtensions = Join-Path $workDirectory 'authentication.ext'
    $grpcBookingKey = Join-Path $grpcBookingClientOutput 'booking.key'
    $grpcBookingRequest = Join-Path $workDirectory 'booking.csr'
    $grpcBookingCertificate = Join-Path $grpcBookingClientOutput 'booking.crt'
    $grpcBookingExtensions = Join-Path $workDirectory 'booking.ext'
    $grpcFinanceKey = Join-Path $grpcFinanceClientOutput 'finance.key'
    $grpcFinanceRequest = Join-Path $workDirectory 'finance.csr'
    $grpcFinanceCertificate = Join-Path $grpcFinanceClientOutput 'finance.crt'
    $grpcFinanceExtensions = Join-Path $workDirectory 'finance.ext'
    $grpcPaymentKey = Join-Path $grpcPaymentClientOutput 'payment.key'
    $grpcPaymentRequest = Join-Path $workDirectory 'payment.csr'
    $grpcPaymentCertificate = Join-Path $grpcPaymentClientOutput 'payment.crt'
    $grpcPaymentExtensions = Join-Path $workDirectory 'payment.ext'
    $grpcNotificationKey = Join-Path $grpcNotificationClientOutput 'notification.key'
    $grpcNotificationRequest = Join-Path $workDirectory 'notification.csr'
    $grpcNotificationCertificate = Join-Path $grpcNotificationClientOutput 'notification.crt'
    $grpcNotificationExtensions = Join-Path $workDirectory 'notification.ext'

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:user,DNS:service-user,DNS:localhost,IP:127.0.0.1
'@ | Set-Content -LiteralPath $grpcServerExtensions -NoNewline

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=URI:spiffe://vistay/service/authentication
'@ | Set-Content -LiteralPath $grpcAuthenticationExtensions -NoNewline

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=URI:spiffe://vistay/service/booking
'@ | Set-Content -LiteralPath $grpcBookingExtensions -NoNewline

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=URI:spiffe://vistay/service/finance
'@ | Set-Content -LiteralPath $grpcFinanceExtensions -NoNewline

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=URI:spiffe://vistay/service/payment
'@ | Set-Content -LiteralPath $grpcPaymentExtensions -NoNewline

    @'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=URI:spiffe://vistay/service/notification
'@ | Set-Content -LiteralPath $grpcNotificationExtensions -NoNewline

    Invoke-OpenSsl @(
        'req', '-x509', '-newkey', 'rsa:4096', '-sha256', '-nodes',
        '-keyout', $grpcCaKey, '-out', $grpcCaCertificate, '-days', '3650',
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=ViStay Development gRPC CA'
    )
    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcServerKey, '-out', $grpcServerRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-user'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcServerRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAcreateserial',
        '-out', $grpcServerCertificate, '-days', '825', '-extfile', $grpcServerExtensions
    )
    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcAuthenticationKey, '-out', $grpcAuthenticationRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-authentication'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcAuthenticationRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAserial', $grpcCaSerial,
        '-out', $grpcAuthenticationCertificate, '-days', '825',
        '-extfile', $grpcAuthenticationExtensions
    )
    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcBookingKey, '-out', $grpcBookingRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-booking'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcBookingRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAserial', $grpcCaSerial,
        '-out', $grpcBookingCertificate, '-days', '825',
        '-extfile', $grpcBookingExtensions
    )
    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcFinanceKey, '-out', $grpcFinanceRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-finance'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcFinanceRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAserial', $grpcCaSerial,
        '-out', $grpcFinanceCertificate, '-days', '825',
        '-extfile', $grpcFinanceExtensions
    )
    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcPaymentKey, '-out', $grpcPaymentRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-payment'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcPaymentRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAserial', $grpcCaSerial,
        '-out', $grpcPaymentCertificate, '-days', '825',
        '-extfile', $grpcPaymentExtensions
    )

    Invoke-OpenSsl @(
        'req', '-new', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-keyout', $grpcNotificationKey, '-out', $grpcNotificationRequest,
        '-subj', '/C=VN/L=Ho Chi Minh City/O=ViStay/OU=Platform/CN=service-notification'
    )
    Invoke-OpenSsl @(
        'x509', '-req', '-sha256', '-in', $grpcNotificationRequest,
        '-CA', $grpcCaCertificate, '-CAkey', $grpcCaKey, '-CAserial', $grpcCaSerial,
        '-out', $grpcNotificationCertificate, '-days', '825',
        '-extfile', $grpcNotificationExtensions
    )

    foreach ($destination in @($grpcServerOutput, $grpcClientOutput, $grpcBookingClientOutput, $grpcFinanceClientOutput, $grpcPaymentClientOutput, $grpcNotificationClientOutput)) {
        Copy-Item -LiteralPath $grpcCaCertificate -Destination (Join-Path $destination 'ca.crt')
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        & chmod 0644 `
            (Join-Path $grpcServerOutput 'ca.crt') `
            $grpcServerCertificate `
            $grpcServerKey `
            (Join-Path $grpcClientOutput 'ca.crt') `
            $grpcAuthenticationCertificate `
            $grpcAuthenticationKey `
            (Join-Path $grpcBookingClientOutput 'ca.crt') `
            $grpcBookingCertificate `
            $grpcBookingKey `
            (Join-Path $grpcFinanceClientOutput 'ca.crt') `
            $grpcFinanceCertificate `
            $grpcFinanceKey `
            (Join-Path $grpcPaymentClientOutput 'ca.crt') `
            $grpcPaymentCertificate `
            $grpcPaymentKey `
            (Join-Path $grpcNotificationClientOutput 'ca.crt') `
            $grpcNotificationCertificate `
            $grpcNotificationKey
        if ($LASTEXITCODE -ne 0) {
            throw "chmod failed with exit code $LASTEXITCODE"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $workDirectory) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}

Write-Output "Kafka role-scoped development bundles created under $(Join-Path $generatedRoot 'kafka')"
Write-Output "gRPC role-scoped development bundles created under $(Join-Path $generatedRoot 'grpc')"
