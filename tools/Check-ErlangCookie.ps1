# Check-ErlangCookie.ps1
# Local by default.
# Remote when using: .\Check-ErlangCookie.ps1 -ClusterNodes server1,server2,server3

param(
    [string[]]$ClusterNodes
)

$ScriptBlock = {
    $LoggedOnUsers = Get-CimInstance Win32_ComputerSystem |
        Select-Object -ExpandProperty UserName

    $UserProfilePaths = @()

    if ($LoggedOnUsers) {
        foreach ($User in @($LoggedOnUsers)) {
            $Account = ($User -split "\\")[-1]
            $Profile = "C:\Users\$Account"

            if (Test-Path $Profile) {
                $UserProfilePaths += $Profile
            }
        }
    }

    $CookieFiles = @(
        "C:\Windows\System32\config\systemprofile\.erlang.cookie",
        "C:\Windows\.erlang.cookie"
    )

    foreach ($Profile in $UserProfilePaths) {
        $CookieFiles += Join-Path $Profile ".erlang.cookie"
    }

    foreach ($File in ($CookieFiles | Select-Object -Unique)) {
        [PSCustomObject]@{
            Computer = $env:COMPUTERNAME
            Path     = $File
            Exists   = Test-Path $File
            Cookie   = if (Test-Path $File) {
                (Get-Content $File -Raw).Trim()
            } else {
                $null
            }
        }
    }
}

if ($ClusterNodes -and $ClusterNodes.Count -gt 0) {
    $Results = Invoke-Command -ComputerName $ClusterNodes -ScriptBlock $ScriptBlock
} else {
    $Results = & $ScriptBlock
}

$Results | Format-Table -AutoSize

"`nCookie groups:"
$Results |
    Where-Object { $_.Exists -and $_.Cookie } |
    Group-Object Cookie |
    Select-Object Count, Name |
    Format-Table -AutoSize
