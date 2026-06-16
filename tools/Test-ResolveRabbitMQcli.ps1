# Test-ResolveRabbitMqCli.ps1
 
function Resolve-RabbitMqCliPath {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )
 
    Write-Host ""
    Write-Host "=== RabbitMQ CLI Resolver ===" -ForegroundColor Cyan
    Write-Host "Searching for: $CommandName"
    Write-Host ""
 
    #
    # 1. PATH lookup
    #
    Write-Host "[1] Checking PATH..." -ForegroundColor Yellow
 
    $candidates = @(
        (Get-Command "$CommandName.bat" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    ) | Where-Object { $_ }
 
    if ($candidates) {
        Write-Host "[OK] Found via PATH" -ForegroundColor Green
        return $candidates[0]
    }
 
    #
    # 2. Registry uninstall lookup
    #
    Write-Host "[2] Checking installed applications registry..." -ForegroundColor Yellow
 
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
 
    foreach ($regPath in $uninstallPaths) {
 
        $rabbitInstall = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -match "RabbitMQ"
            } |
            Select-Object -First 1
 
        if ($rabbitInstall) {
 
            Write-Host "Found RabbitMQ install entry:"
            Write-Host "  DisplayName    : $($rabbitInstall.DisplayName)"
            Write-Host "  InstallLocation: $($rabbitInstall.InstallLocation)"
            Write-Host ""
 
            if ($rabbitInstall.InstallLocation) {
 
                $match = Get-ChildItem `
                    -Path $rabbitInstall.InstallLocation `
                    -Recurse `
                    -File `
                    -Filter "$CommandName.bat" `
                    -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName -First 1
 
                if ($match) {
                    Write-Host "[OK] Found via uninstall registry" -ForegroundColor Green
                    return $match
                }
            }
        }
    }
 
    #
    # 3. Program Files registry locations
    #
    Write-Host "[3] Checking Program Files registry paths..." -ForegroundColor Yellow
 
    $pf = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
 
    $programDirs = @(
        $pf.ProgramFilesDir,
        $pf.ProgramFilesDirx86,
        $pf.ProgramW6432Dir
    ) | Where-Object { $_ } | Select-Object -Unique
 
    foreach ($dir in $programDirs) {
 
        Write-Host "Checking: $dir"
 
        $rabbitRoot = Join-Path $dir "RabbitMQ Server"
 
        if (Test-Path $rabbitRoot) {
 
            $match = Get-ChildItem `
                -Path $rabbitRoot `
                -Recurse `
                -File `
                -Filter "$CommandName.bat" `
                -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName -First 1
 
            if ($match) {
                Write-Host "[OK] Found via Program Files registry path" -ForegroundColor Green
                return $match
            }
        }
    }
 
    #
    # 4. Fixed disk fallback search
    #
    Write-Host "[4] Scanning fixed disks..." -ForegroundColor Yellow
 
    $fixedDrives = Get-CimInstance Win32_LogicalDisk |
        Where-Object {
            $_.DriveType -eq 3
        }
 
    foreach ($drive in $fixedDrives) {
 
        Write-Host "Scanning drive: $($drive.DeviceID)"
 
        $possibleRoots = @(
            "$($drive.DeviceID)\Program Files",
            "$($drive.DeviceID)\Program Files (x86)"
        )
 
        foreach ($root in $possibleRoots) {
 
            if (Test-Path $root) {
 
                Write-Host "  Searching: $root"
 
                $match = Get-ChildItem `
                    -Path $root `
                    -Recurse `
                    -File `
                    -Filter "$CommandName.bat" `
                    -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName -First 1
 
                if ($match) {
                    Write-Host "[OK] Found via disk scan" -ForegroundColor Green
                    return $match
                }
            }
        }
    }
 
    throw "RabbitMQ CLI not found: $CommandName"
}
 
#
# TEST SECTION
#
 
try {
 
    $commands = @(
        "rabbitmqctl",
        "rabbitmq-diagnostics",
        "rabbitmq-service"
    )
 
    foreach ($cmd in $commands) {
 
        Write-Host ""
        Write-Host "====================================================="
        Write-Host "TESTING: $cmd"
        Write-Host "====================================================="
 
        $result = Resolve-RabbitMqCliPath -CommandName $cmd
 
        Write-Host ""
        Write-Host "FINAL RESULT:" -ForegroundColor Cyan
        Write-Host $result -ForegroundColor Green
    }
 
}
catch {
 
    Write-Host ""
    Write-Host "[ERROR]" -ForegroundColor Red
    Write-Host $_.Exception.Message
}
