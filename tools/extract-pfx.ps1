# Run in PowerShell 7

$RabbitMQPfxPath = "C:\Delivery\rmq-deploytool-main\certs\SecretServer.pfx"
$RabbitMQCertDir = "C:\RabbitMQ\certs"

$SecurePfxPassword = Read-Host "Enter PFX password" -AsSecureString

New-Item -ItemType Directory -Force -Path $RabbitMQCertDir | Out-Null

$RabbitMQCertPath = "$RabbitMQCertDir\server.crt"
$RabbitMQKeyPath  = "$RabbitMQCertDir\server.key"
$RabbitMQCAPath   = "$RabbitMQCertDir\ca.crt"

function Convert-ToPem {
    param(
        [string]$Label,
        [byte[]]$Bytes
    )

    $base64 = [Convert]::ToBase64String(
        $Bytes,
        [System.Base64FormattingOptions]::InsertLineBreaks
    )

    "-----BEGIN $Label-----`n$base64`n-----END $Label-----"
}

$flags =
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet

$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $RabbitMQPfxPath,
    $SecurePfxPassword,
    $flags
)

# server.crt
$certPem = Convert-ToPem "CERTIFICATE" $cert.RawData
Set-Content -Path $RabbitMQCertPath -Value $certPem -Encoding ascii

# server.key - same style as rmq_deploytool: PKCS#8 PRIVATE KEY
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)

if ($null -eq $rsa) {
    throw "No RSA private key found in the PFX."
}

try {
    $keyBytes = $rsa.ExportPkcs8PrivateKey()
}
finally {
    $rsa.Dispose()
}

$keyPem = Convert-ToPem "PRIVATE KEY" $keyBytes
Set-Content -Path $RabbitMQKeyPath -Value $keyPem -Encoding ascii

# ca.crt
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.Build($cert) | Out-Null

$caPem = ""

foreach ($element in $chain.ChainElements) {
    if ($element.Certificate.Thumbprint -ne $cert.Thumbprint) {
        $caPem += Convert-ToPem "CERTIFICATE" $element.Certificate.RawData
        $caPem += "`n"
    }
}

Set-Content -Path $RabbitMQCAPath -Value $caPem -Encoding ascii

$cert.Dispose()

Write-Output "Created:"
Write-Output $RabbitMQCertPath
Write-Output $RabbitMQKeyPath
Write-Output $RabbitMQCAPath
