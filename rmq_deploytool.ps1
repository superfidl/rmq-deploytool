###############################################
# RabbitMQ Deployment Tool
# Secret Server compatible
# Lab version
###############################################

param(
    [string]$DeployMode,
    [switch]$ReapplyOnly,
    [switch]$JoinCluster,
    [string]$NodeRole,
    [string]$ClusterName,
    [string]$Node1Host,
    [string]$TLSMode,
    [ValidateSet("Apply","Remove","Keep")]
    [string]$TlsAction,
    [string]$RabbitMQUser,
    [string]$RabbitMQUserPassword,
    [string]$RabbitMQAdmin = "admin",
    [string]$RabbitMQAdminPassword,
    [string]$CertMode,
    [string]$RabbitMQPfxPath,
    [string]$PfxPassword,
    [string]$ExternalCA,
    [string]$ServerCertPath,
    [string]$PrivateKeyPath,
    [string]$CAChainPath,
    [string]$ErlangCookieValue,
    [switch]$AllowInstallerDownload,
    [string]$InstallerManifestPath,
    [string]$OptionsManifestPath,
    [string]$OfflineErlangInstallerPath,
    [string]$OfflineRabbitMQInstallerPath
)

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
$deliveryRoot = $scriptRoot
$deliveryUpgradeRoot = Join-Path $deliveryRoot "RMQUpgrade"

if ([string]::IsNullOrWhiteSpace($InstallerManifestPath)) {
    $InstallerManifestPath = Join-Path $deliveryUpgradeRoot "manifest.rmq_deploytool_installers.json"
}

if ([string]::IsNullOrWhiteSpace($OptionsManifestPath)) {
    $OptionsManifestPath = Join-Path $deliveryRoot "manifest.rmq_deploytool_options.json"
}

if ([string]::IsNullOrWhiteSpace($OfflineErlangInstallerPath)) {
    $OfflineErlangInstallerPath = Join-Path $deliveryUpgradeRoot "otp_win64_27.3.4.6.exe"
}

if ([string]::IsNullOrWhiteSpace($OfflineRabbitMQInstallerPath)) {
    $OfflineRabbitMQInstallerPath = Join-Path $deliveryUpgradeRoot "rabbitmq-server-4.2.1.exe"
}

$script:RabbitMqBasePath = "C:\RabbitMQ"
$script:ManageFirewallRules = $true
$script:UpdateRabbitMqSbinPath = $true
$script:EnabledRabbitMqPlugins = @(
    "rabbitmq_management",
    "rabbitmq_shovel",
    "rabbitmq_shovel_management",
    "rabbitmq_prometheus"
)
$script:ManagementAllowedSources = @("127.0.0.1")
$script:AmqpAllowedSources = @("Any")
$script:ClusterAllowedSources = @("Any")
$script:PrometheusAllowedSources = @("127.0.0.1")
$script:PortSettings = @{
    AmqpTcp = 5672
    AmqpTls = 5671
    ManagementTcp = 15672
    ManagementTls = 15671
    Prometheus = 15692
    Epmd = 4369
    Distribution = 25672
}

###############################################
# INSTALLER INPUTS
###############################################

###############################################
# DEPLOYMENT MODE
###############################################

Write-Host ""
Write-Host "Deployment Mode"
Write-Host "1 - Standalone"
Write-Host "2 - 3 Node Cluster"
Write-Host "3 - Upgrade"
Write-Host "4 - Uninstall only"
Write-Host "5 - Uninstall and purge config"
Write-Host "6 - Uninstall and reinstall"
Write-Host ""
Write-Host "Optional flags:"
Write-Host "-ReapplyOnly  : skip install/upgrade and only reapply config for mode 1/2/3"
Write-Host "-JoinCluster  : in cluster node mode, re-run cluster join steps"
Write-Host "-TlsAction    : Apply | Remove | Keep"
Write-Host "-ErlangCookieValue : optionally set the Erlang cookie before cluster join"

if ([string]::IsNullOrWhiteSpace($DeployMode)) {
    $DeployMode = Read-Host "Select mode"
}

switch ($DeployMode) {
    "1" { Write-Host "Mode 1 selected: install a standalone RabbitMQ node." }
    "2" { Write-Host "Mode 2 selected: configure a 3-node RabbitMQ cluster." }
    "3" { Write-Host "Mode 3 selected: upgrade the existing RabbitMQ installation." }
    "4" { Write-Host "Mode 4 selected: uninstall RabbitMQ and Erlang only, then stop." }
    "5" { Write-Host "Mode 5 selected: uninstall RabbitMQ and Erlang, then purge local RabbitMQ config files." }
    "6" { Write-Host "Mode 6 selected: uninstall RabbitMQ and Erlang, then install again." }
    default { throw "Invalid deployment mode selected: $DeployMode" }
}

if ($ReapplyOnly -and $DeployMode -notin @("1","2","3")) {
    throw "-ReapplyOnly is only supported with DeployMode 1, 2, or 3."
}

if ($JoinCluster -and $DeployMode -ne "2") {
    throw "-JoinCluster is only supported with DeployMode 2."
}

if ($DeployMode -eq "2" -and -not [string]::IsNullOrWhiteSpace($NodeRole) -and $NodeRole -notin @("1","2","3")) {
    throw "Invalid NodeRole '$NodeRole'. Valid values are 1, 2, or 3."
}

###############################################
# HELPER FUNCTIONS
###############################################

function Get-ErlangCookieHash {

    $cookiePath = Get-ErlangCookiePath

    if(!(Test-Path $cookiePath)){

        Write-Host ""
        Write-Host "Erlang cookie missing"
        Write-Host "Copy file from another node:"
        Write-Host "C:\Windows\.erlang.cookie"
        throw "Cookie missing"

    }

    $hash=(Get-FileHash $cookiePath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "Local Erlang cookie hash:"
    Write-Host $hash

    return $hash
}

function Get-ErlangCookieValue {

    $cookiePath = Get-ErlangCookiePath

    if(!(Test-Path $cookiePath)){

        Write-Host ""
        Write-Host "Erlang cookie missing"
        Write-Host "Copy file from another node:"
        Write-Host "C:\Windows\.erlang.cookie"
        throw "Cookie missing"

    }

    return (Get-Content -LiteralPath $cookiePath -Raw)
}

function Get-ErlangCookiePath {

    $candidates = @(
        "C:\Windows\.erlang.cookie",
        "C:\Windows\System32\config\systemprofile\.erlang.cookie",
        (Join-Path $env:USERPROFILE ".erlang.cookie")
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates) {
        return $candidates[0]
    }

    return "C:\Windows\.erlang.cookie"
}

function Get-RabbitMqServiceAccountName {

    $service = Get-CimInstance Win32_Service -Filter "Name='RabbitMQ'" -ErrorAction SilentlyContinue
    if (-not $service) {
        return $null
    }

    return $service.StartName
}

function Get-RabbitMqServiceProfileCookiePath {

    $serviceAccount = Get-RabbitMqServiceAccountName
    if ([string]::IsNullOrWhiteSpace($serviceAccount)) {
        return $null
    }

    switch -Regex ($serviceAccount) {
        '^LocalSystem$' { return "C:\Windows\System32\config\systemprofile\.erlang.cookie" }
        '^NT AUTHORITY\\SYSTEM$' { return "C:\Windows\System32\config\systemprofile\.erlang.cookie" }
        '^LocalService$' { return "C:\Windows\ServiceProfiles\LocalService\.erlang.cookie" }
        '^NT AUTHORITY\\LocalService$' { return "C:\Windows\ServiceProfiles\LocalService\.erlang.cookie" }
        '^NetworkService$' { return "C:\Windows\ServiceProfiles\NetworkService\.erlang.cookie" }
        '^NT AUTHORITY\\NetworkService$' { return "C:\Windows\ServiceProfiles\NetworkService\.erlang.cookie" }
        default {
            $userName = ($serviceAccount -split '\\')[-1]
            if ([string]::IsNullOrWhiteSpace($userName)) {
                return $null
            }

            return (Join-Path "C:\Users\$userName" ".erlang.cookie")
        }
    }
}

function Get-ErlangCookieTargetPaths {

    $paths = @(
        "C:\Windows\.erlang.cookie",
        "C:\Windows\System32\config\systemprofile\.erlang.cookie",
        (Join-Path $env:USERPROFILE ".erlang.cookie"),
        (Get-RabbitMqServiceProfileCookiePath)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    return @($paths)
}

function Set-ErlangCookieValue {
    param(
        [Parameter(Mandatory)]
        [string]$CookieValue
    )

    if ([string]::IsNullOrWhiteSpace($CookieValue)) {
        throw "Erlang cookie value cannot be empty."
    }

    if ($CookieValue -match '\s') {
        throw "Erlang cookie value cannot contain whitespace."
    }

    $serviceAccount = Get-RabbitMqServiceAccountName
    if (-not [string]::IsNullOrWhiteSpace($serviceAccount)) {
        Write-Host "RabbitMQ service account: $serviceAccount"
    }

    $failedPaths = @()

    foreach ($path in (Get-ErlangCookieTargetPaths)) {
        $parent = Split-Path -Path $path -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }

            Set-Content -LiteralPath $path -Value $CookieValue -NoNewline -Encoding ascii -ErrorAction Stop
            Write-Host "Wrote Erlang cookie to $path"
        }
        catch {
            Write-Warning "Failed to write Erlang cookie to $path : $($_.Exception.Message)"
            $failedPaths += $path
        }
    }

    if ($failedPaths.Count -gt 0) {
        throw "Failed to write Erlang cookie to required path(s): $($failedPaths -join ', ')"
    }
}

function Remove-ErlangCookieFiles {

    foreach ($path in (Get-ErlangCookieTargetPaths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Write-Host "Removed Erlang cookie file $path"
            }
            catch {
                Write-Warning "Failed to remove Erlang cookie file $path : $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "Skipped missing Erlang cookie file $path"
        }
    }
}

function Test-RabbitClusterConnectivity($HostName){

    Write-Host ""
    Write-Host "Checking connectivity to $HostName"

    $ports=@(
        [int]$script:PortSettings.Epmd,
        [int]$script:PortSettings.Distribution
    )

    foreach($port in $ports){

        $ok=Test-NetConnection -ComputerName $HostName -Port $port -InformationLevel Quiet

        if(!$ok){

            Write-Host ""
            Write-Host "Cannot reach $HostName on port $port"
            Write-Host "Check firewall rules"
            throw "Cluster connectivity failure"

        }

    }

}

function Test-DnsResolution($HostName){

    Write-Host ""
    Write-Host "Checking DNS resolution for $HostName"

    try{

        $dnsResults = Resolve-DnsName $HostName -ErrorAction Stop
        $recordTypes = ($dnsResults | Select-Object -ExpandProperty Type -Unique) -join ", "

        Write-Host "DNS resolution OK for $HostName"
        if (-not [string]::IsNullOrWhiteSpace($recordTypes)) {
            Write-Host "Resolved record types: $recordTypes"
        }

    }
    catch{

        Write-Host "DNS resolution failed for $HostName"
        throw "DNS failure for host '$HostName' (expected resolvable A/AAAA records)"

    }

}

function Wait-RabbitMQReady($HostName, [int]$Port = 5672){

    Write-Host "Waiting for RabbitMQ on ${HostName}:$Port"

    for($i=0;$i -lt 30;$i++){

        $ready=Test-NetConnection -ComputerName $HostName -Port $Port -InformationLevel Quiet

        if($ready){
            Write-Host "RabbitMQ ready"
            return
        }

        Start-Sleep 5
    }

    throw "RabbitMQ bootstrap node not ready"

}

function Wait-LocalRabbitMqCliReady {

    Write-Host "Waiting for local RabbitMQ CLI connectivity"

    for($i=0;$i -lt 30;$i++){
        try {
            Invoke-RabbitMqCli rabbitmq-diagnostics ping
            Write-Host "Local RabbitMQ CLI ready"
            return
        }
        catch {
            Start-Sleep 5
        }
    }

    throw "Local RabbitMQ node not ready for CLI operations"

}

function Get-RabbitMqInstallRoots {

    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($rabbitMqServerPath in @(
        $env:RABBITMQ_SERVER,
        [Environment]::GetEnvironmentVariable("RABBITMQ_SERVER", "Machine"),
        [Environment]::GetEnvironmentVariable("RABBITMQ_SERVER", "User")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($rabbitMqServerPath)) {
            $roots.Add($rabbitMqServerPath.TrimEnd('\'))
        }
    }

    foreach ($programFilesPath in @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432,
        [Environment]::GetEnvironmentVariable("ProgramFiles", "Machine"),
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Machine"),
        [Environment]::GetEnvironmentVariable("ProgramW6432", "Machine")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($programFilesPath)) {
            $roots.Add((Join-Path $programFilesPath "RabbitMQ Server"))
        }
    }

    try {
        $rabbitMqService = Get-CimInstance -ClassName Win32_Service -Filter "Name='RabbitMQ'" -ErrorAction Stop
        if ($rabbitMqService -and -not [string]::IsNullOrWhiteSpace($rabbitMqService.PathName)) {
            $serviceCommandPath = $rabbitMqService.PathName.Trim()
            if ($serviceCommandPath.StartsWith('"')) {
                $serviceCommandPath = $serviceCommandPath.Trim('"')
            }
            else {
                $serviceCommandPath = ($serviceCommandPath -split '\s+')[0]
            }

            $serviceCommandDirectory = Split-Path -Path $serviceCommandPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($serviceCommandDirectory)) {
                $roots.Add($serviceCommandDirectory)
                $roots.Add((Split-Path -Path $serviceCommandDirectory -Parent))
            }
        }
    }
    catch {
    }

    $uninstallRegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($registryPath in $uninstallRegistryPaths) {
        try {
            $entries = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like "RabbitMQ Server*" -or $_.DisplayName -like "RabbitMQ*"
                }

            foreach ($entry in $entries) {
                foreach ($candidate in @($entry.InstallLocation, $entry.DisplayIcon, $entry.UninstallString)) {
                    if ([string]::IsNullOrWhiteSpace($candidate)) {
                        continue
                    }

                    $normalizedCandidate = [string]$candidate
                    if ($normalizedCandidate.StartsWith('"')) {
                        $normalizedCandidate = $normalizedCandidate.Trim('"')
                    }
                    else {
                        $normalizedCandidate = ($normalizedCandidate -split '\s+/|\s+-|\s+')[0]
                    }

                    if ([string]::IsNullOrWhiteSpace($normalizedCandidate)) {
                        continue
                    }

                    if (Test-Path -LiteralPath $normalizedCandidate -PathType Leaf) {
                        $normalizedCandidate = Split-Path -Path $normalizedCandidate -Parent
                    }

                    if (-not [string]::IsNullOrWhiteSpace($normalizedCandidate)) {
                        $roots.Add($normalizedCandidate.TrimEnd('\'))
                        try {
                            $roots.Add((Split-Path -Path $normalizedCandidate -Parent))
                        }
                        catch {
                        }
                    }
                }
            }
        }
        catch {
        }
    }

    try {
        $fixedDrives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        foreach ($drive in $fixedDrives) {
            if (-not [string]::IsNullOrWhiteSpace($drive.DeviceID)) {
                $roots.Add((Join-Path $drive.DeviceID "Program Files\RabbitMQ Server"))
                $roots.Add((Join-Path $drive.DeviceID "Program Files (x86)\RabbitMQ Server"))
            }
        }
    }
    catch {
    }

    return @(
        $roots |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.TrimEnd('\') } |
        Select-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ }
    )
}

function Resolve-RabbitMqCliPath {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $candidates = @(
        (Get-Command "$CommandName.cmd" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Get-Command "$CommandName.bat" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    ) | Where-Object { $_ }

    if ($candidates) {
        return $candidates[0]
    }

    foreach ($rabbitRoot in Get-RabbitMqInstallRoots) {
        $match = @(
            Get-ChildItem -Path $rabbitRoot -Recurse -File -Filter "$CommandName.cmd" -ErrorAction SilentlyContinue
            Get-ChildItem -Path $rabbitRoot -Recurse -File -Filter "$CommandName.bat" -ErrorAction SilentlyContinue
        ) | Select-Object -ExpandProperty FullName -First 1

        if ($match) {
            return $match
        }
    }

    throw "RabbitMQ CLI not found: $CommandName"
}

function Invoke-RabbitMqCli {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $commandPath = Resolve-RabbitMqCliPath -CommandName $CommandName
    & $commandPath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "$CommandName failed with exit code $LASTEXITCODE"
    }
}

function Set-RabbitMqQuorumPolicy {

    Write-Host "RabbitMQ 4.x quorum default is configured via rabbitmq.conf instead of policy."
}

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function New-RabbitMqTlsMaterialFromPfx {
    param(
        [Parameter(Mandatory)]
        [string]$PfxPath,
        [Parameter(Mandatory)]
        [Security.SecureString]$PfxPassword,
        [Parameter(Mandatory)]
        [string]$CertPath,
        [Parameter(Mandatory)]
        [string]$KeyPath
    )

    $flags =
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet

    $pwd = Convert-SecureStringToPlainText -SecureString $PfxPassword
    try {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $pwd, $flags)
    }
    catch {
        throw "Failed to open PFX '$PfxPath'. Verify that the file is valid and that -PfxPassword is correct."
    }

    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if (-not $rsa) {
            throw "The PFX does not contain an RSA private key. Use certificate mode 3 with PEM files for non-RSA certificates."
        }

        try {
            $keyBytes = $rsa.ExportPkcs8PrivateKey()
        }
        catch {
            throw "The PFX private key could not be exported. The certificate likely uses a non-exportable or provider-restricted private key. Use an exportable PFX or certificate mode 3 with PEM files."
        }

        if (-not $keyBytes -or $keyBytes.Length -eq 0) {
            throw "The PFX private key export returned no data. Use an exportable PFX or certificate mode 3 with PEM files."
        }

        $certPem = "-----BEGIN CERTIFICATE-----`n"
        $certPem += [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
        $certPem += "`n-----END CERTIFICATE-----"

        $keyPem = "-----BEGIN PRIVATE KEY-----`n"
        $keyPem += [Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
        $keyPem += "`n-----END PRIVATE KEY-----"

        Set-Content -Path $CertPath -Value $certPem -Encoding ascii -ErrorAction Stop
        Set-Content -Path $KeyPath -Value $keyPem -Encoding ascii -ErrorAction Stop
    }
    catch {
        foreach ($path in @($CertPath, $KeyPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }

        throw
    }
    finally {
        if ($rsa) {
            $rsa.Dispose()
        }
        $cert.Dispose()
    }
}

function Verify-RabbitCluster{

    Write-Host ""
    Write-Host "Cluster status"
    Invoke-RabbitMqCli rabbitmq-diagnostics cluster_status

    Write-Host ""
    Write-Host "Queues"
    Invoke-RabbitMqCli rabbitmqctl list_queues name type durable

}

function Assert-FileExists {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
}

function Get-InstallerManifest {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-FileExists -Path $Path -Label "Installer manifest"

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse installer manifest '$Path' : $($_.Exception.Message)"
    }
}

function Get-OptionsManifest {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-FileExists -Path $Path -Label "Options manifest"

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse options manifest '$Path' : $($_.Exception.Message)"
    }
}

function Get-ManifestBooleanValue {
    param(
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $parsed = $false
    if ([bool]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    throw "$Label must be true or false."
}

function Get-ManifestIntValue {
    param(
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    throw "$Label must be an integer."
}

function Get-ManifestStringArrayValue {
    param(
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return @(
            $Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @(
            $Value |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )
    }

    throw "$Label must be a string or array of strings."
}

function Normalize-FirewallRemoteAddress {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    $trimmed = $Address.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    if ($trimmed.Contains('/')) {
        return $trimmed
    }

    if ($trimmed -ieq "Any") {
        return "Any"
    }

    if ($trimmed -ieq "Any") {
        return "Any"
    }

    $ipAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($trimmed, [ref]$ipAddress)) {
        throw "Invalid firewall allowed source address: $trimmed"
    }

    if ($ipAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return "$trimmed/128"
    }

    return "$trimmed/32"
}

function Resolve-FirewallRemoteAddressList {
    param(
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Label,
        [string[]]$DefaultValues
    )

    $items = Get-ManifestStringArrayValue -Value $Value -Label $Label
    if ($null -eq $items -or $items.Count -eq 0) {
        return @($DefaultValues)
    }

    $normalized = @(
        $items |
        ForEach-Object { Normalize-FirewallRemoteAddress -Address $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    if ($normalized -contains "Any") {
        return @("Any")
    }

    return @($normalized)
}

function Resolve-OptionsManifest {
    if (-not (Test-Path -LiteralPath $OptionsManifestPath -PathType Leaf)) {
        Write-Host "Options manifest not found; using built-in defaults."
        return
    }

    Write-Host "Using options manifest: $OptionsManifestPath"
    $options = Get-OptionsManifest -Path $OptionsManifestPath

    if (-not [string]::IsNullOrWhiteSpace($options.rabbitmq_base_path)) {
        $script:RabbitMqBasePath = [string]$options.rabbitmq_base_path
    }

    $manageFirewall = Get-ManifestBooleanValue -Value $options.manage_firewall_rules -Label "manage_firewall_rules"
    if ($null -ne $manageFirewall) {
        $script:ManageFirewallRules = $manageFirewall
    }

    $updateSbinPath = Get-ManifestBooleanValue -Value $options.update_rabbitmq_sbin_path -Label "update_rabbitmq_sbin_path"
    if ($null -ne $updateSbinPath) {
        $script:UpdateRabbitMqSbinPath = $updateSbinPath
    }

    $script:ManagementAllowedSources = Resolve-FirewallRemoteAddressList -Value $options.management_allowed_sources -Label "management_allowed_sources" -DefaultValues @("127.0.0.1")
    $script:PrometheusAllowedSources = Resolve-FirewallRemoteAddressList -Value $options.prometheus_allowed_sources -Label "prometheus_allowed_sources" -DefaultValues @("127.0.0.1")
    $script:AmqpAllowedSources = Resolve-FirewallRemoteAddressList -Value $options.amqp_allowed_sources -Label "amqp_allowed_sources" -DefaultValues @("Any")
    $script:ClusterAllowedSources = Resolve-FirewallRemoteAddressList -Value $options.cluster_allowed_sources -Label "cluster_allowed_sources" -DefaultValues @("Any")

    if ($null -ne $options.enable_plugins) {
        if ($options.enable_plugins -isnot [System.Collections.IEnumerable] -or $options.enable_plugins -is [string]) {
            throw "enable_plugins must be an array."
        }

        $script:EnabledRabbitMqPlugins = @(
            $options.enable_plugins |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )
    }

    if ($null -ne $options.ports) {
        $portMappings = @{
            amqp_tcp = "AmqpTcp"
            amqp_tls = "AmqpTls"
            management_tcp = "ManagementTcp"
            management_tls = "ManagementTls"
            prometheus = "Prometheus"
            epmd = "Epmd"
            distribution = "Distribution"
        }

        foreach ($manifestKey in $portMappings.Keys) {
            $portValue = Get-ManifestIntValue -Value $options.ports.$manifestKey -Label "ports.$manifestKey"
            if ($null -ne $portValue) {
                $script:PortSettings[$portMappings[$manifestKey]] = $portValue
            }
        }
    }
}

function Resolve-InstallerManifestEntry {
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [string]$EntryName,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $entry = $Manifest.$EntryName
    if (-not $entry) {
        throw "Installer manifest entry missing: $EntryName"
    }

    $resolvedPath = $null
    if (-not [string]::IsNullOrWhiteSpace($entry.path)) {
        $resolvedPath = $entry.path
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entry.file)) {
        $manifestDir = Split-Path -Path $ManifestPath -Parent
        $resolvedPath = Join-Path $manifestDir $entry.file
    }
    else {
        throw "$Label manifest entry must define either 'path' or 'file'"
    }

    if ([string]::IsNullOrWhiteSpace($entry.hash_type)) {
        throw "$Label manifest entry is missing 'hash_type'"
    }

    if ([string]::IsNullOrWhiteSpace($entry.hash)) {
        throw "$Label manifest entry is missing 'hash'"
    }

    $downloadUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($entry.download_url)) {
        $downloadUrl = [string]$entry.download_url
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entry.url)) {
        $downloadUrl = [string]$entry.url
    }

    return [PSCustomObject]@{
        Label = $Label
        Path = $resolvedPath
        HashType = [string]$entry.hash_type
        Hash = ([string]$entry.hash).ToUpperInvariant()
        Version = [string]$entry.version
        Source = [string]$entry.source
        DownloadUrl = $downloadUrl
    }
}

function Get-InstallerHashValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$HashType
    )

    Assert-FileExists -Path $Path -Label "Installer file"

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm $HashType -ErrorAction Stop).Hash.ToUpperInvariant()
    }
    catch {
        throw "Failed to calculate $HashType for installer '$Path' : $($_.Exception.Message)"
    }
}

function Test-InstallerHash {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$HashType,
        [Parameter(Mandatory)]
        [string]$ExpectedHash,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $actualHash = Get-InstallerHashValue -Path $Path -HashType $HashType

    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        return $false
    }

    Write-Host "$Label hash validation passed ($HashType)"
    return $true
}

function Test-DownloadUrlReachable {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$Label
    )

    try {
        $null = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Host "$Label download source reachable"
        return $true
    }
    catch {
        try {
            $null = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Host "$Label download source reachable"
            return $true
        }
        catch {
            Write-Warning "$Label download source is not reachable: $Url"
            return $false
        }
    }
}

function Save-InstallerDownload {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Write-Host "Downloading $Label from $Url"

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    }
    catch {
        throw "Failed to download $Label from '$Url' : $($_.Exception.Message)"
    }
}

function Resolve-InstallerArtifact {
    param(
        [Parameter(Mandatory)]
        [object]$Installer
    )

    $pathExists = Test-Path -LiteralPath $Installer.Path -PathType Leaf

    if ($pathExists) {
        if (Test-InstallerHash -Path $Installer.Path -HashType $Installer.HashType -ExpectedHash $Installer.Hash -Label $Installer.Label) {
            return
        }

        Write-Warning "$($Installer.Label) exists but failed hash validation."

        if (-not $AllowInstallerDownload) {
            throw "$($Installer.Label) hash mismatch. Re-download the file or rerun with -AllowInstallerDownload if the manifest includes a download_url."
        }
    }
    else {
        Write-Warning "$($Installer.Label) not found at $($Installer.Path)"

        if (-not $AllowInstallerDownload) {
            throw "$($Installer.Label) is missing. Place the file at the manifest path or rerun with -AllowInstallerDownload if the manifest includes a download_url."
        }
    }

    if ([string]::IsNullOrWhiteSpace($Installer.DownloadUrl)) {
        throw "$($Installer.Label) cannot be downloaded because the manifest entry has no download_url."
    }

    if (-not (Test-DownloadUrlReachable -Url $Installer.DownloadUrl -Label $Installer.Label)) {
        throw "$($Installer.Label) download source is not reachable. Validate internet access or place the installer file manually."
    }

    Save-InstallerDownload -Url $Installer.DownloadUrl -Path $Installer.Path -Label $Installer.Label

    if (-not (Test-InstallerHash -Path $Installer.Path -HashType $Installer.HashType -ExpectedHash $Installer.Hash -Label $Installer.Label)) {
        throw "$($Installer.Label) was downloaded but failed hash validation. Re-download a correct file or update the manifest if the expected hash is wrong."
    }
}

function Resolve-InstallerSources {
    param(
        [switch]$RequireManifest
    )

    if (Test-Path -LiteralPath $InstallerManifestPath -PathType Leaf) {
        Write-Host "Using installer manifest: $InstallerManifestPath"

        $manifest = Get-InstallerManifest -Path $InstallerManifestPath
        $erlangInstaller = Resolve-InstallerManifestEntry -Manifest $manifest -ManifestPath $InstallerManifestPath -EntryName "erlang" -Label "Erlang installer"
        $rabbitMqInstaller = Resolve-InstallerManifestEntry -Manifest $manifest -ManifestPath $InstallerManifestPath -EntryName "rabbitmq" -Label "RabbitMQ installer"

        Resolve-InstallerArtifact -Installer $erlangInstaller
        Resolve-InstallerArtifact -Installer $rabbitMqInstaller

        $script:OfflineErlangInstallerPath = $erlangInstaller.Path
        $script:OfflineRabbitMQInstallerPath = $rabbitMqInstaller.Path
    }
    elseif ($RequireManifest) {
        throw "Installer manifest not found: $InstallerManifestPath"
    }
    else {
        Write-Warning "Installer manifest not found; falling back to installer paths provided on the command line."
        Assert-FileExists -Path $OfflineErlangInstallerPath -Label "Erlang installer"
        Assert-FileExists -Path $OfflineRabbitMQInstallerPath -Label "RabbitMQ installer"
    }

    Write-Host "Using Erlang installer: $OfflineErlangInstallerPath"
    Write-Host "Using RabbitMQ installer: $OfflineRabbitMQInstallerPath"
}

function Assert-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $CommandName"
    }
}

function Import-RabbitMqHelperModule {

    $moduleNames = @(
        "Delinea.RabbitMq.Helper.PSCommands",
        "Delinea.RabbitMq.Helper"
    )

    foreach ($moduleName in $moduleNames) {
        if (Get-Module -Name $moduleName) {
            return
        }

        if (Get-Module -ListAvailable -Name $moduleName) {
            Import-Module $moduleName -ErrorAction Stop
            return
        }
    }
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentValue,
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    return (Read-Host $Prompt)
}

function Read-SecureValueAsPlainText {
    param(
        [string]$CurrentValue,
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    return Convert-SecureStringToPlainText -SecureString (Read-Host $Prompt -AsSecureString)
}

function Read-ValidatedValue {
    param(
        [string]$CurrentValue,
        [Parameter(Mandatory)]
        [string]$Prompt,
        [Parameter(Mandatory)]
        [string[]]$ValidValues
    )

    $value = $CurrentValue
    while ($true) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $ValidValues -contains $value) {
            return $value
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "Invalid value '$value'. Valid values: $($ValidValues -join ', ')"
        }

        $value = Read-Host $Prompt
    }
}

function New-PlainTextCredential {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,
        [Parameter(Mandatory)]
        [string]$Password
    )

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    return [PSCredential]::new($UserName, $securePassword)
}

function Get-RabbitMqClientPort {
    if ($TLSMode -eq "2") {
        return [int]$script:PortSettings.AmqpTls
    }

    return [int]$script:PortSettings.AmqpTcp
}

function Get-RabbitMqManagementPort {
    if ($TLSMode -eq "2" -and $TlsAction -ne "Remove") {
        return [int]$script:PortSettings.ManagementTls
    }

    return [int]$script:PortSettings.ManagementTcp
}

function Get-RabbitMqRequiredFirewallPorts {

    $ports = @(
        [int]$script:PortSettings.AmqpTcp,
        [int]$script:PortSettings.AmqpTls,
        [int]$script:PortSettings.ManagementTcp,
        [int]$script:PortSettings.ManagementTls,
        [int]$script:PortSettings.Prometheus
    )

    if ($DeployMode -eq "2") {
        $ports += @(
            [int]$script:PortSettings.Epmd,
            [int]$script:PortSettings.Distribution
        )
    }

    return @($ports | Sort-Object -Unique)
}

function Get-RabbitMqFirewallRuleName {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    return "RabbitMQ Deployment Tool - TCP $Port"
}

function Get-RabbitMqFirewallRemoteAddressesForPort {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    if ($Port -eq [int]$script:PortSettings.Prometheus) {
        return @($script:PrometheusAllowedSources)
    }

    if ($Port -eq [int]$script:PortSettings.ManagementTcp -or $Port -eq [int]$script:PortSettings.ManagementTls) {
        return @($script:ManagementAllowedSources)
    }

    if ($Port -eq [int]$script:PortSettings.AmqpTcp -or $Port -eq [int]$script:PortSettings.AmqpTls) {
        return @($script:AmqpAllowedSources)
    }

    if ($Port -eq [int]$script:PortSettings.Epmd -or $Port -eq [int]$script:PortSettings.Distribution) {
        return @($script:ClusterAllowedSources)
    }

    return @("Any")
}

function Test-RabbitMqFirewallRuleMatches {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$Rule,
        [Parameter(Mandatory)]
        [int]$Port,
        [Parameter(Mandatory)]
        [string[]]$DesiredRemoteAddresses
    )

    $portFilter = $Rule | Get-NetFirewallPortFilter
    $addressFilter = $Rule | Get-NetFirewallAddressFilter

    if (-not $portFilter -or -not $addressFilter) {
        return $false
    }

    if ($Rule.Direction -ne "Inbound" -or $Rule.Action -ne "Allow" -or $portFilter.Protocol -ne "TCP") {
        return $false
    }

    $actualPorts = @($portFilter.LocalPort | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedPorts = @([string]$Port)
    if (@($actualPorts) -join ',' -ne @($expectedPorts) -join ',') {
        return $false
    }

    $actualRemoteAddresses = @($addressFilter.RemoteAddress | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $expectedRemoteAddresses = @($DesiredRemoteAddresses | ForEach-Object { [string]$_ } | Sort-Object -Unique)

    return ((@($actualRemoteAddresses) -join ',') -eq (@($expectedRemoteAddresses) -join ','))
}

function Update-RabbitMqFirewallRules {

    if (-not $script:ManageFirewallRules) {
        Write-Host "Firewall management disabled by options manifest; skipping firewall rule creation."
        return
    }

    Assert-CommandExists -CommandName Get-NetFirewallRule
    Assert-CommandExists -CommandName New-NetFirewallRule

    foreach ($port in (Get-RabbitMqRequiredFirewallPorts)) {
        $ruleName = Get-RabbitMqFirewallRuleName -Port $port
        $desiredRemoteAddresses = Get-RabbitMqFirewallRemoteAddressesForPort -Port $port
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if ($existingRule) {
            $needsRefresh = $ReapplyOnly

            if (-not $needsRefresh) {
                $matchingRule = $existingRule | Where-Object {
                    Test-RabbitMqFirewallRuleMatches -Rule $_ -Port $port -DesiredRemoteAddresses $desiredRemoteAddresses
                } | Select-Object -First 1

                if ($matchingRule) {
                    Write-Host "Firewall rule already present: $ruleName"
                    continue
                }

                $needsRefresh = $true
            }

            if ($needsRefresh) {
                $existingRule | Remove-NetFirewallRule
                Write-Host "Reapplied firewall rule for TCP port $port"
            }
        }

        $newRuleParams = @{
            DisplayName = $ruleName
            Direction   = "Inbound"
            Action      = "Allow"
            Protocol    = "TCP"
            LocalPort   = $port
            Profile     = "Any"
            Group       = "RabbitMQ Deployment Tool"
        }

        if ($desiredRemoteAddresses.Count -gt 0 -and $desiredRemoteAddresses[0] -ne "Any") {
            $newRuleParams.RemoteAddress = @($desiredRemoteAddresses)
        }

        New-NetFirewallRule @newRuleParams | Out-Null

        Write-Host "Added firewall rule for TCP port $port"
    }
}

function Remove-RabbitMqFirewallRules {

    Assert-CommandExists -CommandName Get-NetFirewallRule
    Assert-CommandExists -CommandName Remove-NetFirewallRule

    $rules = Get-NetFirewallRule -Group "RabbitMQ Deployment Tool" -ErrorAction SilentlyContinue
    if (-not $rules) {
        Write-Host "RabbitMQ firewall rules not present"
        return
    }

    $rules | Remove-NetFirewallRule
    Write-Host "Removed RabbitMQ firewall rules"
}

function Invoke-RabbitMqUninstall {

    Write-Host "Starting RabbitMQ and Erlang uninstall"

    Import-RabbitMqHelperModule
    Assert-CommandExists -CommandName Uninstall-RabbitMq
    Assert-CommandExists -CommandName Uninstall-Erlang

    Stop-Service RabbitMQ -ErrorAction SilentlyContinue

    try {
        Uninstall-RabbitMq -Verbose
    }
    catch {
        Write-Warning "RabbitMQ uninstall reported an issue: $($_.Exception.Message)"
    }

    Remove-ErlangCookieFiles
    Remove-RabbitMqFirewallRules
    Remove-RabbitMqSbinFromPath

    try {
        Uninstall-Erlang -Verbose
    }
    catch {
        Write-Warning "Erlang uninstall reported an issue: $($_.Exception.Message)"
    }
}

function Get-RabbitMqSbinPath {

    $candidates = foreach ($rabbitRoot in Get-RabbitMqInstallRoots) {
        if ((Split-Path -Leaf $rabbitRoot) -eq "sbin" -and (Test-Path -LiteralPath $rabbitRoot)) {
            $rabbitRoot
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $rabbitRoot "sbin")) {
            Join-Path $rabbitRoot "sbin"
        }

        Get-ChildItem -Path $rabbitRoot -Directory -Filter "rabbitmq_server-*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "sbin" } |
            Where-Object { Test-Path -LiteralPath $_ }
    }

    return @($candidates | Select-Object -Unique | Select-Object -First 1)
}

function Get-RabbitMqBasePath {

    if (-not [string]::IsNullOrWhiteSpace($script:RabbitMqBasePath)) {
        return $script:RabbitMqBasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:RABBITMQ_BASE)) {
        return $env:RABBITMQ_BASE
    }

    return "C:\RabbitMQ"
}

function Set-RabbitMqBaseEnvironment {
    $basePath = Get-RabbitMqBasePath

    [Environment]::SetEnvironmentVariable("RABBITMQ_BASE", $basePath, "Machine")
    $env:RABBITMQ_BASE = $basePath

    Write-Host "Using RabbitMQ base path: $basePath"
}

function Get-RabbitMqCertDir {
    return (Join-Path (Get-RabbitMqBasePath) "certs")
}

function Get-MachinePathEntries {

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($machinePath)) {
        return @()
    }

    return @($machinePath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Set-MachinePathEntries {
    param(
        [Parameter(Mandatory)]
        [string[]]$Entries
    )

    $normalizedEntries = @(
        $Entries |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique
    )

    $machinePath = $normalizedEntries -join ';'
    [Environment]::SetEnvironmentVariable("Path", $machinePath, "Machine")

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Add-RabbitMqSbinToPath {

    if (-not $script:UpdateRabbitMqSbinPath) {
        Write-Host "RabbitMQ sbin PATH management disabled by options manifest."
        return
    }

    $sbinPath = Get-RabbitMqSbinPath
    if ([string]::IsNullOrWhiteSpace($sbinPath)) {
        Write-Warning "RabbitMQ sbin path not found. Skipping PATH update."
        return
    }

    $entries = Get-MachinePathEntries
    $filteredEntries = @(
        $entries | Where-Object { $_ -notmatch '\\RabbitMQ Server\\rabbitmq_server-.*\\sbin$' }
    )

    if ($filteredEntries -contains $sbinPath) {
        Set-MachinePathEntries -Entries $filteredEntries
        Write-Host "RabbitMQ sbin path already aligned in machine PATH: $sbinPath"
        return
    }

    Set-MachinePathEntries -Entries ($filteredEntries + $sbinPath)
    Write-Host "Updated machine PATH to current RabbitMQ sbin path: $sbinPath"
}

function Sync-RabbitMqSbinPathSafely {

    try {
        Add-RabbitMqSbinToPath
    }
    catch {
        Write-Warning "Failed to update RabbitMQ sbin in machine PATH: $($_.Exception.Message)"
        Write-Warning "Continuing because RabbitMQ CLI resolution does not rely only on PATH."
    }
}

function Remove-RabbitMqSbinFromPath {

    $entries = Get-MachinePathEntries
    $filteredEntries = @(
        $entries | Where-Object { $_ -notmatch '\\RabbitMQ Server\\rabbitmq_server-.*\\sbin$' }
    )

    if ($filteredEntries.Count -eq $entries.Count) {
        Write-Host "RabbitMQ sbin path not present in machine PATH"
        return
    }

    Set-MachinePathEntries -Entries $filteredEntries
    Write-Host "Removed RabbitMQ sbin path from machine PATH"
}

function Get-RabbitMqConfigPath {

    if (-not [string]::IsNullOrWhiteSpace($env:RABBITMQ_CONFIG_FILE)) {
        if ($env:RABBITMQ_CONFIG_FILE.EndsWith(".conf")) {
            return $env:RABBITMQ_CONFIG_FILE
        }

        return "$($env:RABBITMQ_CONFIG_FILE).conf"
    }

    return (Join-Path (Get-RabbitMqBasePath) "rabbitmq.conf")
}

function Invoke-RabbitMqConfigPurge {

    Write-Host "Purging RabbitMQ configuration files"

    $rabbitMqBase = Get-RabbitMqBasePath

    $pathsToRemove = @(
        (Get-RabbitMqCertDir),
        $rabbitMqBase
    )

    foreach ($path in $pathsToRemove) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "Removed $path"
        }
        else {
            Write-Host "Skipped missing path $path"
        }
    }

    Remove-ErlangCookieFiles
}

function Set-RabbitMqDefaultQueueTypeQuorum {

    $conf = Get-RabbitMqConfigPath
    $confDir = Split-Path -Path $conf -Parent
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null

    $line = "default_queue_type = quorum"
    if (Test-Path -LiteralPath $conf) {
        $content = Get-Content -LiteralPath $conf -ErrorAction Stop
        if ($content -notcontains $line) {
            Add-Content -LiteralPath $conf -Value "`r`n$line"
            Write-Host "Added default quorum queue type to $conf"
        }
        else {
            Write-Host "Quorum queue default already present in $conf"
        }
    }
    else {
        Set-Content -LiteralPath $conf -Value $line -Encoding ascii
        Write-Host "Created $conf with default quorum queue type"
    }
}

function Write-RabbitMqConfigFile {
    param(
        [Parameter(Mandatory)]
        [object[]]$Lines
    )

    $conf = Get-RabbitMqConfigPath
    $confDir = Split-Path -Path $conf -Parent
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null

    $normalizedLines = foreach ($line in $Lines) {
        if ($null -eq $line) {
            continue
        }

        [string]$line
    }

    $content = $normalizedLines -join "`r`n"
    Set-Content -LiteralPath $conf -Value $content -Encoding ascii
    Write-Host "Wrote RabbitMQ config to $conf"
}

function Set-RabbitMqPlainConfiguration {

    Write-RabbitMqConfigFile -Lines @(
        "listeners.tcp.default = $(Get-RabbitMqClientPort)",
        "management.tcp.port = $(Get-RabbitMqManagementPort)",
        "",
        "loopback_users.guest = false"
    )

    Write-Host "Applied non-TLS RabbitMQ configuration"
}

function Set-RabbitMqTlsConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$RabbitMQCertPath,
        [Parameter(Mandatory)]
        [string]$RabbitMQKeyPath,
        [string]$RabbitMQCAPath,
        [bool]$UseTlsCa
    )

    $lines = @(
        "listeners.tcp = none",
        "listeners.ssl.default = $([int]$script:PortSettings.AmqpTls)",
        "",
        "ssl_options.certfile = $RabbitMQCertPath",
        "ssl_options.keyfile = $RabbitMQKeyPath"
    )

    if ($UseTlsCa) {
        $lines += "ssl_options.cacertfile = $RabbitMQCAPath"
    }

    $lines += @(
        "",
        "management.ssl.port = $([int]$script:PortSettings.ManagementTls)",
        "management.ssl.certfile = $RabbitMQCertPath",
        "management.ssl.keyfile = $RabbitMQKeyPath"
    )

    if ($UseTlsCa) {
        $lines += "management.ssl.cacertfile = $RabbitMQCAPath"
    }

    $lines += @(
        "",
        "loopback_users.guest = false"
    )

    Write-RabbitMqConfigFile -Lines $lines
    Write-Host "Applied TLS RabbitMQ configuration"
}

function Remove-RabbitMqTlsArtifacts {

    $pathsToRemove = @(
        (Get-RabbitMqCertDir)
    )

    foreach ($path in $pathsToRemove) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "Removed TLS path $path"
        }
    }
}

function Get-RabbitMqManagementUri {

    if ($TLSMode -eq "2" -and $TlsAction -ne "Remove") {
        return "https://127.0.0.1:$([int]$script:PortSettings.ManagementTls)"
    }

    return "http://127.0.0.1:$([int]$script:PortSettings.ManagementTcp)"
}

function Enable-RabbitMqConfiguredPlugins {

    if (-not $script:EnabledRabbitMqPlugins -or $script:EnabledRabbitMqPlugins.Count -eq 0) {
        Write-Host "No RabbitMQ plugins configured for enablement."
        return
    }

    foreach ($plugin in $script:EnabledRabbitMqPlugins) {
        Invoke-RabbitMqCli rabbitmq-plugins enable $plugin
    }
}

function Open-RabbitMqManagementUi {

    $uri = Get-RabbitMqManagementUri
    Write-Host "Opening RabbitMQ management UI: $uri"
    Start-Process $uri
}

###############################################
# INPUT COLLECTION
###############################################

if ($DeployMode -eq "2") {

    Write-Host ""
    Write-Host "Cluster Node Role"
    Write-Host "1 - First node (bootstrap)"
    Write-Host "2 - Second node"
    Write-Host "3 - Third node"

    $NodeRole = Read-ValidatedValue -CurrentValue $NodeRole -Prompt "Select node role" -ValidValues @("1","2","3")

    if ($NodeRole -eq "1") {
        $ClusterName = Read-RequiredValue -CurrentValue $ClusterName -Prompt "Cluster name"
    }
    elseif ($NodeRole -eq "2" -or $NodeRole -eq "3") {
        $Node1Host = Read-RequiredValue -CurrentValue $Node1Host -Prompt "Hostname of node1"
    }
}

Resolve-OptionsManifest
Set-RabbitMqBaseEnvironment

if($DeployMode -eq "4"){

    Invoke-RabbitMqUninstall
    Write-Host "Uninstall completed. Start the installer again when ready."
    return

}

if($DeployMode -eq "5"){

    Invoke-RabbitMqUninstall
    Invoke-RabbitMqConfigPurge
    Write-Host "Uninstall and config purge completed. Start the installer again when ready."
    return

}

###############################################
# TLS MODE
###############################################

Write-Host ""
Write-Host "TLS Mode"
Write-Host "1 - No TLS (lab quick deploy)"
Write-Host "2 - TLS enabled"

$TLSMode = Read-RequiredValue -CurrentValue $TLSMode -Prompt "Select TLS mode"

if ([string]::IsNullOrWhiteSpace($TlsAction)) {
    if ($ReapplyOnly) {
        $TlsAction = "Keep"
    }
    elseif ($DeployMode -eq "3") {
        $TlsAction = "Keep"
    }
    elseif ($TLSMode -eq "2") {
        $TlsAction = "Apply"
    }
    else {
        $TlsAction = "Remove"
    }
}
else {
    $TlsAction = Read-ValidatedValue -CurrentValue $TlsAction -Prompt "TlsAction (Apply, Remove, Keep)" -ValidValues @("Apply","Remove","Keep")
}

if ($TlsAction -eq "Apply" -and $TLSMode -ne "2") {
    throw "-TlsAction Apply requires -TLSMode 2."
}

if ($TlsAction -eq "Remove" -and $TLSMode -ne "1") {
    throw "-TlsAction Remove requires -TLSMode 1."
}

###############################################
# READ CREDENTIALS
###############################################

$RabbitService = Get-Service RabbitMQ -ErrorAction SilentlyContinue
$RequiresInstallCredentials = (-not $ReapplyOnly) -and ($DeployMode -eq "6" -or (($DeployMode -eq "1" -or $DeployMode -eq "2") -and -not $RabbitService))

if ($RequiresInstallCredentials) {
    $RabbitMQUser = Read-RequiredValue -CurrentValue $RabbitMQUser -Prompt "Secret Server Site Connector user"
    $RabbitMQUserPassword = Read-SecureValueAsPlainText -CurrentValue $RabbitMQUserPassword -Prompt "Password"

    if ([string]::IsNullOrWhiteSpace($RabbitMQAdmin)) {
        $RabbitMQAdmin = "admin"
    }

    $RabbitMQAdmin = Read-RequiredValue -CurrentValue $RabbitMQAdmin -Prompt "RabbitMQ Admin (default admin)"
    $RabbitMQAdminPassword = Read-SecureValueAsPlainText -CurrentValue $RabbitMQAdminPassword -Prompt "RabbitMQ Admin Password"
}

if($TlsAction -eq "Apply"){
    Write-Host ""
    Write-Host "Certificate Mode"
    Write-Host "1 PFX"
    Write-Host "2 PFX + chain"
    Write-Host "3 Manual PEM"

    $CertMode = Read-RequiredValue -CurrentValue $CertMode -Prompt "Select"

    if($CertMode -eq "1" -or $CertMode -eq "2"){
        $RabbitMQPfxPath = Read-RequiredValue -CurrentValue $RabbitMQPfxPath -Prompt "Path to PFX"
        $PfxPassword = Read-SecureValueAsPlainText -CurrentValue $PfxPassword -Prompt "PFX Password"

        if($CertMode -eq "2"){
            $ExternalCA = Read-RequiredValue -CurrentValue $ExternalCA -Prompt "CA chain path"
        }
    }
    elseif($CertMode -eq "3"){
        $ServerCertPath = Read-RequiredValue -CurrentValue $ServerCertPath -Prompt "Server cert path"
        $PrivateKeyPath = Read-RequiredValue -CurrentValue $PrivateKeyPath -Prompt "Private key path"
        $CAChainPath = Read-RequiredValue -CurrentValue $CAChainPath -Prompt "CA chain path"
    }
    else {
        throw "Invalid certificate mode selected: $CertMode"
    }
}

$credentialRabbitMQUser = $null
$credentialRabbitMQAdmin = $null
$PerformedClusterJoin = $false

if ($RequiresInstallCredentials) {
    $credentialRabbitMQUser = New-PlainTextCredential -UserName $RabbitMQUser -Password $RabbitMQUserPassword
    $credentialRabbitMQAdmin = New-PlainTextCredential -UserName $RabbitMQAdmin -Password $RabbitMQAdminPassword
}

$RequiresOfflineInstallers = $false

if ($DeployMode -eq "6" -or $DeployMode -eq "3") {
    $RequiresOfflineInstallers = $true
}
elseif (-not $ReapplyOnly -and -not $RabbitService) {
    $RequiresOfflineInstallers = $true
}

if ($RequiresOfflineInstallers) {
    Resolve-InstallerSources -RequireManifest
}

###############################################
# INSTALL OR UPGRADE
###############################################

if($DeployMode -eq "6"){

    Import-RabbitMqHelperModule
    Assert-FileExists -Path $OfflineErlangInstallerPath -Label "Erlang installer"
    Assert-FileExists -Path $OfflineRabbitMQInstallerPath -Label "RabbitMQ installer"

    Invoke-RabbitMqUninstall

    Install-Connector `
    -AgreeRabbitMqLicense `
    -AgreeErlangLicense `
    -OfflineErlangInstallerPath $OfflineErlangInstallerPath `
    -OfflineRabbitMQInstallerPath $OfflineRabbitMQInstallerPath `
    -Credential $credentialRabbitMQUser `
    -AdminCredential $credentialRabbitMQAdmin `
    -Verbose

    Sync-RabbitMqSbinPathSafely

}
elseif($ReapplyOnly){

    Write-Host "Reapply-only mode selected; skipping install/upgrade"
    Sync-RabbitMqSbinPathSafely

}
elseif($DeployMode -eq "3"){

    Write-Host "Upgrade detected"

    Assert-FileExists -Path $OfflineRabbitMQInstallerPath -Label "RabbitMQ installer"

    Stop-Service RabbitMQ -ErrorAction SilentlyContinue

    Start-Process $OfflineRabbitMQInstallerPath -ArgumentList "/S" -Wait

    Sync-RabbitMqSbinPathSafely

    Start-Service RabbitMQ

}
elseif(-not $RabbitService){

    Import-RabbitMqHelperModule
    Assert-FileExists -Path $OfflineErlangInstallerPath -Label "Erlang installer"
    Assert-FileExists -Path $OfflineRabbitMQInstallerPath -Label "RabbitMQ installer"

    Install-Connector `
    -AgreeRabbitMqLicense `
    -AgreeErlangLicense `
    -OfflineErlangInstallerPath $OfflineErlangInstallerPath `
    -OfflineRabbitMQInstallerPath $OfflineRabbitMQInstallerPath `
    -Credential $credentialRabbitMQUser `
    -AdminCredential $credentialRabbitMQAdmin `
    -Verbose

    Sync-RabbitMqSbinPathSafely

}
else{

    Write-Host "Existing RabbitMQ service detected; skipping install/upgrade"

}

###############################################
# ENABLE PLUGINS
###############################################

Enable-RabbitMqConfiguredPlugins

###############################################
# TLS CONFIGURATION
###############################################

if($TlsAction -eq "Apply"){

    $RabbitMQCertDir = Get-RabbitMqCertDir

    $RabbitMQCertPath="$RabbitMQCertDir\server.crt"
    $RabbitMQKeyPath="$RabbitMQCertDir\server.key"
    $RabbitMQCAPath="$RabbitMQCertDir\ca.crt"
    $UseTlsCa = $false

    New-Item -ItemType Directory -Force -Path $RabbitMQCertDir | Out-Null

    if($CertMode -eq "1" -or $CertMode -eq "2"){
        $SecurePfxPassword = ConvertTo-SecureString $PfxPassword -AsPlainText -Force

        New-RabbitMqTlsMaterialFromPfx `
        -PfxPath $RabbitMQPfxPath `
        -PfxPassword $SecurePfxPassword `
        -CertPath $RabbitMQCertPath `
        -KeyPath $RabbitMQKeyPath

        if($CertMode -eq "2"){
            Copy-Item $ExternalCA $RabbitMQCAPath -Force
            $UseTlsCa = $true

        }

    }

    if($CertMode -eq "3"){
        Copy-Item $ServerCertPath $RabbitMQCertPath
        Copy-Item $PrivateKeyPath $RabbitMQKeyPath
        Copy-Item $CAChainPath $RabbitMQCAPath
        $UseTlsCa = $true

    }

    Set-RabbitMqTlsConfiguration `
    -RabbitMQCertPath $RabbitMQCertPath `
    -RabbitMQKeyPath $RabbitMQKeyPath `
    -RabbitMQCAPath $RabbitMQCAPath `
    -UseTlsCa $UseTlsCa

}
elseif($TlsAction -eq "Remove"){

    Remove-RabbitMqTlsArtifacts
    Set-RabbitMqPlainConfiguration

}
else{

    Write-Host "TLS configuration unchanged (-TlsAction Keep)"

}

###############################################
# FIREWALL RULES
###############################################

Update-RabbitMqFirewallRules

###############################################
# CLUSTER JOIN LOGIC
###############################################

if($DeployMode -eq "2"){

    if($NodeRole -eq "2" -or $NodeRole -eq "3"){

        Test-DnsResolution $Node1Host

        if($JoinCluster -or -not $ReapplyOnly){

            Test-RabbitClusterConnectivity $Node1Host

            if (-not [string]::IsNullOrWhiteSpace($ErlangCookieValue)) {
                Set-ErlangCookieValue -CookieValue $ErlangCookieValue
                Write-Host "Skipping manual cookie hash validation because -ErlangCookieValue was supplied."
                Write-Host "Restarting RabbitMQ service so the node reloads the updated Erlang cookie"
                Restart-Service RabbitMQ
                Wait-LocalRabbitMqCliReady
            }
            else {
                $localHash=Get-ErlangCookieHash

                Write-Host ""
                Write-Host "Enter cookie hash from node1"

                $remoteHash=Read-Host "Node1 cookie hash"

                if($localHash -ne $remoteHash){

                    Write-Host ""
                    Write-Host "COOKIE MISMATCH"
                    Write-Host "Copy file or pass -ErlangCookieValue from node1."
                    Write-Host "Target paths:"
                    Get-ErlangCookieTargetPaths | ForEach-Object { Write-Host $_ }

                    throw "Cookie mismatch"

                }
            }

            Wait-RabbitMQReady $Node1Host (Get-RabbitMqClientPort)

            Invoke-RabbitMqCli rabbitmqctl stop_app
            Invoke-RabbitMqCli rabbitmqctl reset
            Invoke-RabbitMqCli rabbitmqctl join_cluster "rabbit@$Node1Host"
            Invoke-RabbitMqCli rabbitmqctl start_app
            $PerformedClusterJoin = $true

            Write-Host ""
            Write-Host "Validating cluster membership after join"
            Invoke-RabbitMqCli rabbitmqctl cluster_status

        }
        else{
            Write-Host "Skipping cluster join in reapply-only mode. Use -JoinCluster to re-run join steps."
        }

    }

    if($NodeRole -eq "1"){

        Invoke-RabbitMqCli rabbitmqctl set_cluster_name $ClusterName

        Write-Host ""
        Write-Host "Bootstrap cookie value:"
        Write-Host (Get-ErlangCookieValue)

        Write-Host ""
        Write-Host "Bootstrap cookie hash:"
        Get-FileHash (Get-ErlangCookiePath)

    }

}

###############################################
# QUORUM POLICY
###############################################

if($DeployMode -eq "2" -and $NodeRole -eq "1"){

    if($TlsAction -ne "Keep" -or $ReapplyOnly -or $DeployMode -eq "2"){
        Set-RabbitMqDefaultQueueTypeQuorum
    }
    Set-RabbitMqQuorumPolicy

}

###############################################
# SERVICE RESTART
###############################################

if ($PerformedClusterJoin) {
    Write-Host "Skipping service restart because cluster join already restarted the RabbitMQ app."
}
else {
    Restart-Service RabbitMQ
    Start-Sleep 10
}

###############################################
# CLUSTER VALIDATION
###############################################

Verify-RabbitCluster

###############################################
# CLEANUP
###############################################

$credentialRabbitMQAdmin=$null
$credentialRabbitMQUser=$null
[System.GC]::Collect()

###############################################
# OPEN MANAGEMENT UI
###############################################

Open-RabbitMqManagementUi

Write-Host ""
Write-Host "RabbitMQ deployment completed"
