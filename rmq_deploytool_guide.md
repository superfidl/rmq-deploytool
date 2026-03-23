# RabbitMQ Deployment Script Guide

## Purpose

This document describes what [`rmq_deploytool.ps1`](rmq_deploytool.ps1) does, which parameters it accepts, which deployment combinations it supports, what actions it performs in each phase, which files it writes, which firewall rules it creates, and the prerequisites for a successful run.

`rmq_deploytool.ps1` is positioned as a sec.re platform tool. It exists specifically because Delinea RabbitMQ Helper based RabbitMQ deployments have historically been difficult to operate reliably in real customer environments. sec.re created this tool to help the RabbitMQ Helper path by standardizing installation, upgrade, TLS configuration, clustering, uninstall, and recovery actions into a repeatable operator workflow.

This script supports:

- Standalone RabbitMQ deployment
- 3-node RabbitMQ cluster deployment
- TLS and non-TLS deployments
- TLS using:
  - `PFX only`
  - `PFX + chain`
  - `Manual PEM files`
- Reapply-only configuration runs
- Upgrade runs
- Uninstall-only runs
- Uninstall + purge runs
- Uninstall + reinstall runs

## Script Location

Workspace copy:

- [`rmq_deploytool.ps1`](rmq_deploytool.ps1)

If you execute a separate runtime copy such as `C:\Delivery\rmq_deploytool.ps1`, copy the updated workspace version there before running it.

## What The Script Manages

The script can perform all of the following:

- Install RabbitMQ and Erlang using offline installers
- Configure RabbitMQ for standalone or cluster operation
- Enable RabbitMQ plugins
- Configure TLS or remove TLS
- Create certificate/key files under `C:\RabbitMQ\certs`
- Write RabbitMQ configuration
- Add Windows Firewall rules for required ports
- Join a node to an existing cluster
- Set the Erlang cookie on all relevant local paths
- Restart RabbitMQ when required for the cookie to take effect
- Validate cluster status and queue visibility
- Open the RabbitMQ management UI
- Uninstall RabbitMQ and Erlang
- Purge RabbitMQ configuration and TLS artifacts

## sec.re Platform Positioning

`rmq_deploytool.ps1` should be treated as the sec.re RabbitMQ deployment tool for Windows environments that rely on the Delinea RabbitMQ Helper ecosystem.

The intent is:

- help and stabilize the Delinea RabbitMQ Helper operational path
- reduce repeated manual troubleshooting
- standardize deployment and recovery steps across customers
- provide a free partner platform service aid for this specific deployment area

This is not just a generic RabbitMQ script. It is a platform support tool built to help the RabbitMQ Helper work predictably in delivery and support scenarios.

## Requirements

Before running the script, ensure the following are true.

### Windows / PowerShell

- Run PowerShell as Administrator
- Allow script execution for the session or call the script with `-ExecutionPolicy Bypass`
- Use a PowerShell host that can access services, firewall cmdlets, DNS resolution cmdlets, and local files
- For helper-driven installation and uninstall operations, use the Delinea RabbitMQ Helper shell as described below

### Unblock Files

If the script, installers, or certificates were downloaded from email, browser, Teams, or a network source, unblock them first.

Examples:

```powershell
Unblock-File C:\Delivery\rmq_deploytool.ps1
Unblock-File C:\Delivery\RMQUpgrade\otp_win64_27.3.4.6.exe
Unblock-File C:\Delivery\RMQUpgrade\rabbitmq-server-4.2.1.exe
Unblock-File C:\Delivery\certs\secre-aes.pfx
Unblock-File C:\Delivery\certs\server.crt
Unblock-File C:\Delivery\certs\server.key
Unblock-File C:\Delivery\certs\ca-chain.crt
```

To unblock an entire folder tree:

```powershell
Get-ChildItem C:\Delivery -Recurse -File | Unblock-File
```

### Offline Installers

The script now resolves installers through a dedicated installer manifest file.

Default manifest path:

```text
C:\Delivery\RMQUpgrade\manifest.rmq_deploytool_installers.json
```

The installer manifest is the source of truth for:

- installer file path or file name
- expected version
- hash type
- hash value
- optional download URL
- optional source reference

By default the script still uses these installer path values internally after manifest resolution:

```text
C:\Delivery\RMQUpgrade\otp_win64_27.3.4.6.exe
C:\Delivery\RMQUpgrade\rabbitmq-server-4.2.1.exe
```

These can still be overridden with:

- `-AllowInstallerDownload`
- `-InstallerManifestPath`
- `-OfflineErlangInstallerPath`
- `-OfflineRabbitMQInstallerPath`

For install, reinstall, and upgrade paths, the recommended and intended method is to use the installer manifest.

### Installer Manifest Format

Recommended file:

```text
C:\Delivery\RMQUpgrade\manifest.rmq_deploytool_installers.json
```

Recommended naming model:

- active/default manifest:
  - `manifest.rmq_deploytool_installers.json`
- optional prepared version-specific manifests:
  - `manifest.rmq_deploytool_installers-erlang-v27.3.4.6-rmq-v4.2.1.json`
  - `manifest.rmq_deploytool_installers-erlang-v27.3.4.6-rmq-v4.1.0.json`

This allows you to keep validated installer combinations for specific Erlang and RabbitMQ version pairs while still giving the script one stable default manifest name.

Example:

```json
{
  "erlang": {
    "file": "otp_win64_27.3.4.6.exe",
    "version": "27.3.4.6",
    "hash_type": "SHA256",
    "hash": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "download_url": "https://example.invalid/otp_win64_27.3.4.6.exe",
    "source": "official Erlang source"
  },
  "rabbitmq": {
    "file": "rabbitmq-server-4.2.1.exe",
    "version": "4.2.1",
    "hash_type": "SHA256",
    "hash": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    "download_url": "https://example.invalid/rabbitmq-server-4.2.1.exe",
    "source": "official RabbitMQ source"
  }
}
```

Manifest file included with this tool:

- `manifest.rmq_deploytool_installers.json`

Each installer entry must define:

- `file` or `path`
- `hash_type`
- `hash`

Optional fields:

- `version`
- `download_url`
- `source`

Behavior:

- if `path` is used, that full path is used directly
- if `file` is used, the script resolves it relative to the manifest folder
- the script calculates the file hash before install / upgrade actions
- the script stops immediately if the hash does not match

### Installer Download Behavior

If an installer entry includes `download_url`, the script can optionally download the file.

Behavior:

- if the local file exists and the hash matches, the script skips download
- if the local file exists but the hash is wrong, the script can re-download it
- if the local file is missing, the script can download it
- before downloading, the script performs a quick reachability check against the download URL
- if the source cannot be reached, the script stops with a clear error
- if the file downloads but still fails hash validation, the script stops with a clear error

Download is opt-in and requires:

- `-AllowInstallerDownload`

Without `-AllowInstallerDownload`:

- missing installers cause a stop
- invalid installers cause a stop

If internet access is unavailable, place the installers manually in the expected path and let the script validate them by hash.

### Install Options Manifest

The installer manifest should stay focused on Erlang and RabbitMQ binaries. Operational defaults belong in a separate options manifest.

Default options manifest path:

```text
C:\Delivery\manifest.rmq_deploytool_options.json
```

The options manifest controls default deployment behavior such as:

- RabbitMQ base path
- whether Windows Firewall rules are created
- which source addresses may access the management ports
- which source addresses may access the Prometheus port
- which source addresses may access the AMQP ports
- which source addresses may access the cluster inter-node ports
- which RabbitMQ plugins are enabled
- whether the RabbitMQ `sbin` path is maintained in the machine `PATH`
- default AMQP, management, Prometheus, EPMD, and distribution ports

Firewall source scope model:

- `management_allowed_sources` applies to both management ports:
  - `15672` non-TLS
  - `15671` TLS
- `amqp_allowed_sources` applies to both client ports:
  - `5672` non-TLS
  - `5671` TLS
- `prometheus_allowed_sources` applies to:
  - `15692`
- `cluster_allowed_sources` applies to both cluster inter-node ports:
  - `4369`
  - `25672`

This means each source definition is applied to the full port pair for that section, not only to the currently active TLS or non-TLS listener.

Included file:

- `manifest.rmq_deploytool_options.json`

Example:

```json
{
  "rabbitmq_base_path": "C:\\RabbitMQ",
  "manage_firewall_rules": true,
  "update_rabbitmq_sbin_path": true,
  "_management_allowed_sources_help": "Use a JSON array of source IPs or CIDR ranges for management ports 15672/15671. Bare IPs are treated as /32 automatically. Default is localhost only.",
  "management_allowed_sources": [
    "127.0.0.1"
  ],
  "_prometheus_allowed_sources_help": "Use a JSON array of source IPs or CIDR ranges for TCP 15692. Bare IPs are treated as /32 automatically. Examples: 127.0.0.1, 172.20.0.0/16, 172.21.1.1/32",
  "prometheus_allowed_sources": [
    "127.0.0.1"
  ],
  "_amqp_allowed_sources_help": "Use a JSON array of source IPs or CIDR ranges for AMQP ports 5672/5671. Use \"Any\" to allow all sources. Bare IPs are treated as /32 automatically.",
  "amqp_allowed_sources": [
    "Any"
  ],
  "_cluster_allowed_sources_help": "Use a JSON array of cluster node IPs or CIDR ranges for EPMD and inter-node ports 4369/25672. Use \"Any\" to allow all sources. Bare IPs are treated as /32 automatically.",
  "cluster_allowed_sources": [
    "Any"
  ],
  "enable_plugins": [
    "rabbitmq_management",
    "rabbitmq_shovel",
    "rabbitmq_shovel_management",
    "rabbitmq_prometheus"
  ],
  "ports": {
    "amqp_tcp": 5672,
    "amqp_tls": 5671,
    "management_tcp": 15672,
    "management_tls": 15671,
    "prometheus": 15692,
    "epmd": 4369,
    "distribution": 25672
  }
}
```

Recommended use:

- keep installers and installer hashes in `manifest.rmq_deploytool_installers.json`
- keep deployment defaults in `manifest.rmq_deploytool_options.json`
- do not mix binary integrity data with operational defaults
- keep management and Prometheus restricted by default
- only narrow AMQP and cluster source scopes when you know exactly which hosts or subnets must connect
- keep Prometheus source access narrow by default and widen it only when monitoring systems require it

Certificate handling advice:

- do not create a third certificate manifest by default
- certificate paths and passwords are environment-specific and often secret-bearing
- keep certificate inputs as runtime parameters for clarity and to reduce configuration confusion
- only introduce certificate inventory files separately if you have a strong operational need and clear secret-handling controls

### Delinea Helper Downloads And Supporting Software

Use the Delinea RabbitMQ Helper documentation as the primary reference for helper installation files, prerequisites, and supporting downloads:

- <https://docs.delinea.com/online-help/rabbitmq-helper/installation/index.htm>

In addition to Erlang and RabbitMQ, ensure the environment also includes the Microsoft components required by the Delinea helper environment, including:

- Microsoft .NET runtime / hosting components required by the helper
- Windows Server PowerShell components
- PowerShell Core, if required by the helper version or its prerequisite stack

Use the Delinea documentation above as the source of truth for the exact versions and download links required by your helper release.

Together, the effective requirements for this tool are:

- Delinea RabbitMQ Helper
- helper binaries and helper documentation
- RabbitMQ offline installer
- Erlang offline installer
- installer manifest with validated hashes
- Microsoft supporting runtime / PowerShell components required by the helper
- this sec.re deployment tool: `rmq_deploytool.ps1`

### RabbitMQ Helper Module

The script expects one of these PowerShell modules to be available:

- `Delinea.RabbitMq.Helper.PSCommands`
- `Delinea.RabbitMq.Helper`

These are used for:

- `Install-Connector`
- `Uninstall-RabbitMq`
- `Uninstall-Erlang`

### Delinea RabbitMQ Helper Shell Workflow

The helper commands should be executed from the Delinea RabbitMQ Helper PowerShell environment, not from a random standalone PowerShell session.

Recommended workflow:

1. Open the Windows Start Menu
2. Launch `Delinea RabbitMQ Helper`
3. Click `Next`
4. Continue through the welcome screen
5. Select `Advanced (PowerShell)`
6. In the helper PowerShell window, change to the delivery folder
7. Run the command-line parameter combinations from this guide

Example:

```powershell
Set-Location C:\Delivery
.\rmq_deploytool.ps1 <parameters>
```

This is important because the helper shell provides the expected Delinea helper command context used by:

- `Install-Connector`
- `Uninstall-RabbitMq`
- `Uninstall-Erlang`

If those commands are unavailable in a normal PowerShell session, start from the Delinea RabbitMQ Helper and choose `Advanced (PowerShell)`.

### Node Naming

Cluster joins use short hostnames, not FQDNs.

Use:

- `rmq10041`

Do not use:

- `rmq10041.domain.local`

The RabbitMQ node names are expected to be short names such as:

- `rabbit@rmq10041`
- `rabbit@rmq10042`
- `rabbit@rmq10043`

### DNS / Connectivity

For cluster deployments:

- `Node2` and `Node3` must resolve `Node1`
- `Node2` and `Node3` must reach `Node1` on:
  - `4369`
  - `25672`
- RabbitMQ client port on `Node1` must be reachable:
  - `5672` for non-TLS
  - `5671` for TLS
- If the Windows DNS suffix is incorrect, short hostnames can resolve to the wrong target or fail to resolve
- Fix the Windows DNS suffix search configuration and DNS zones so the cluster names resolve to the intended nodes
- If DNS cannot be corrected immediately, add the short node names to the Windows hosts file as a temporary workaround
- For client access, VIP access, or cluster service naming, the VIP or cluster DNS name must also resolve correctly
- If you add the VIP or cluster service name to the hosts file, use the FQDN form there so the full cluster name resolves consistently
- Windows hosts file path: `C:\Windows\System32\drivers\etc\hosts`

### Certificates

For TLS runs, prepare one of these:

- `CertMode 1`: a `.pfx` file only
- `CertMode 2`: a `.pfx` file plus CA chain file
- `CertMode 3`: PEM certificate file, PEM private key file, and CA chain file

### Permissions

The account running the script must be able to:

- install software
- manage Windows services
- create firewall rules
- create and remove files under:
  - `C:\RabbitMQ`
  - the effective RabbitMQ base path, which in this deployment model is typically `C:\RabbitMQ`
  - `C:\ProgramData\RabbitMQ` only if `RABBITMQ_BASE` is not set and the environment falls back to the script default
  - cookie paths under Windows and service profile locations

## Parameters

### Core Deployment Parameters

- `-DeployMode`
  - `1` = Standalone
  - `2` = 3-node cluster
  - `3` = Upgrade
  - `4` = Uninstall only
  - `5` = Uninstall and purge configuration
  - `6` = Uninstall and reinstall

- `-ReapplyOnly`
  - skip install/upgrade and reapply config only
  - supported with `DeployMode 1`, `2`, or `3`
  - re-applies managed configuration such as RabbitMQ config, TLS artifacts, plugins, firewall rules, base-path environment settings, and RabbitMQ `sbin` PATH handling
  - does not perform a fresh install or RabbitMQ binary upgrade
  - in cluster mode, cluster join itself is only re-run when `-JoinCluster` is also used

- `-JoinCluster`
  - re-run cluster join actions
  - supported only with `DeployMode 2`

### Cluster Parameters

- `-NodeRole`
  - `1` = first/bootstrap node
  - `2` = second node
  - `3` = third node

- `-ClusterName`
  - required on bootstrap node
  - use an FQDN for the cluster name
  - example: `rmq.dssdev1.sec.re`

- `-Node1Host`
  - required on node 2 and node 3
  - use short hostname such as `rmq10041`

### TLS Parameters

- `-TLSMode`
  - `1` = no TLS
  - `2` = TLS enabled

- `-TlsAction`
  - `Apply`
  - `Remove`
  - `Keep`

Rules:

- `-TlsAction Apply` requires `-TLSMode 2`
- `-TlsAction Remove` requires `-TLSMode 1`

### Credential Parameters

- `-RabbitMQUser`
- `-RabbitMQUserPassword`
- `-RabbitMQAdmin`
- `-RabbitMQAdminPassword`

These are required when the script performs a fresh install or reinstall.

Password format guidance:

- keep `-RabbitMQAdminPassword` simple
- prefer letters and numbers with only a small set of special characters
- recommended special characters: `!` and `#`
- avoid using too many special characters or shell-sensitive characters
- avoid characters such as `` ` ``, `"`, `'`, `;`, `&`, `|`, `<`, `>`, `(`, `)`, `$`

### Certificate Parameters

- `-CertMode`
  - `1` = PFX only
  - `2` = PFX + chain
  - `3` = manual PEM files

For `CertMode 1`:

- `-RabbitMQPfxPath`
- `-PfxPassword`

For `CertMode 2`:

- `-RabbitMQPfxPath`
- `-PfxPassword`
- `-ExternalCA`

For `CertMode 3`:

- `-ServerCertPath`
- `-PrivateKeyPath`
- `-CAChainPath`

PFX password guidance:

- keep `-PfxPassword` simple for operational use
- prefer letters and numbers with only `!` and `#` if special characters are needed
- avoid complex special-character mixes when creating the PFX
- if possible, use a password that is easy to type correctly in PowerShell and remote sessions

### Cookie Parameter

- `-ErlangCookieValue`

This is optional, but recommended for cluster node 2 and node 3.

If supplied, the script:

- writes the cookie value to all relevant local cookie paths
- restarts RabbitMQ so the running Erlang node reloads it
- waits for local CLI readiness
- continues with the cluster join

### Installer Override Parameters

- `-AllowInstallerDownload`
- `-InstallerManifestPath`
- `-OptionsManifestPath`
- `-OfflineErlangInstallerPath`
- `-OfflineRabbitMQInstallerPath`

`-AllowInstallerDownload` enables manifest-driven download attempts when an installer file is missing or fails hash validation.

## Recommended Execution Method

For installation, upgrade, uninstall, reinstall, and cluster operations, use this run method:

1. Launch `Delinea RabbitMQ Helper`
2. Click `Next`
3. Select `Advanced (PowerShell)`
4. In that shell:

```powershell
Set-Location C:\Delivery
```

5. Execute the appropriate command line from this guide

This is the preferred operational method for final execution.

## Deployment Modes

### Mode 1: Standalone

Installs or configures a single RabbitMQ node.

Supported variants:

- Standalone without TLS
- Standalone with TLS using:
  - PFX only
  - PFX + chain
  - PEM certificate files

### Mode 2: 3-Node Cluster

Configures a 3-node cluster.

Supported variants:

- Cluster without TLS
- Cluster with TLS using:
  - PFX only
  - PFX + chain
  - PEM certificate files

Node roles:

- Node 1 sets the cluster name and acts as bootstrap node
- Node 2 joins node 1
- Node 3 joins node 1

### Mode 3: Upgrade

Upgrades RabbitMQ using the offline RabbitMQ installer.

Behavior:

- stops RabbitMQ service
- runs the RabbitMQ installer silently
- removes stale RabbitMQ `sbin` entries from the machine `PATH`
- adds the current RabbitMQ `sbin` path for the installed version when PATH management is enabled
- starts RabbitMQ again
- then continues with plugin, TLS, firewall, and validation logic

Default TLS behavior during upgrade:

- `TlsAction` defaults to `Keep`

### Mode 4: Uninstall Only

Behavior:

- stops RabbitMQ service
- attempts RabbitMQ uninstall
- removes Erlang cookie files
- removes RabbitMQ firewall rules created by this script
- removes RabbitMQ `sbin` path from machine PATH
- attempts Erlang uninstall
- exits

### Mode 5: Uninstall And Purge Configuration

Behavior:

- performs all uninstall actions from mode 4
- removes:
  - `C:\RabbitMQ\certs`
  - RabbitMQ base path, typically `C:\RabbitMQ` in this deployment model
- removes Erlang cookie files
- exits

### Mode 6: Uninstall And Reinstall

Behavior:

- performs uninstall actions
- installs Erlang and RabbitMQ again using offline installers
- refreshes the machine `PATH` to the current RabbitMQ `sbin` path when PATH management is enabled
- then continues with plugin, TLS, firewall, cluster, and validation logic

## TLS Modes And Certificate Modes

### No TLS

Use:

- `-TLSMode 1`
- `-TlsAction Remove`

Behavior:

- removes `C:\RabbitMQ\certs`
- writes non-TLS RabbitMQ configuration
- opens ports for plain AMQP and HTTP management

Generated config:

```ini
listeners.tcp.default = 5672
management.tcp.port = 15672
loopback_users.guest = false
```

### TLS Enabled

Use:

- `-TLSMode 2`
- `-TlsAction Apply`

Behavior:

- creates `C:\RabbitMQ\certs`
- writes certificate and key files there
- writes TLS RabbitMQ configuration
- opens ports for TLS AMQP and HTTPS management

Base TLS config:

```ini
listeners.tcp = none
listeners.ssl.default = 5671
ssl_options.certfile = C:\RabbitMQ\certs\server.crt
ssl_options.keyfile = C:\RabbitMQ\certs\server.key
management.ssl.port = 15671
management.ssl.certfile = C:\RabbitMQ\certs\server.crt
management.ssl.keyfile = C:\RabbitMQ\certs\server.key
loopback_users.guest = false
```

When a CA chain is used, these are also added:

```ini
ssl_options.cacertfile = C:\RabbitMQ\certs\ca.crt
management.ssl.cacertfile = C:\RabbitMQ\certs\ca.crt
```

### CertMode 1: PFX Only

Input:

- `.pfx`
- PFX password

Behavior:

- extracts certificate from the PFX into:
  - `C:\RabbitMQ\certs\server.crt`
- extracts RSA private key from the PFX into:
  - `C:\RabbitMQ\certs\server.key`
- no CA file is written
- `CertMode 1` assumes the certificate chain is already trusted by connecting clients or by the operating system trust store
- this is typically appropriate for publicly signed certificates or internal PKI certificates that are already distributed to client trust stores
- RabbitMQ is not given a separate `C:\RabbitMQ\certs\ca.crt` file in this mode
- if the PFX cannot be opened, the script stops immediately
- if the PFX password is wrong, the script stops with a clear error telling the operator to verify `-PfxPassword`

### CertMode 2: PFX + Chain

Input:

- `.pfx`
- PFX password
- CA chain file

Behavior:

- extracts certificate and key as in `CertMode 1`
- copies the external CA chain to:
  - `C:\RabbitMQ\certs\ca.crt`
- writes TLS config that includes `cacertfile`
- if the PFX password is wrong, the script stops before continuing

### CertMode 3: Manual PEM Files

Input:

- certificate file
- private key file
- CA chain file

Behavior:

- copies:
  - server cert to `C:\RabbitMQ\certs\server.crt`
  - private key to `C:\RabbitMQ\certs\server.key`
  - CA chain to `C:\RabbitMQ\certs\ca.crt`
- writes TLS config that includes `cacertfile`

## Files And Paths Managed By The Script

### Installer Paths

Defaults:

- `C:\Delivery\RMQUpgrade\otp_win64_27.3.4.6.exe`
- `C:\Delivery\RMQUpgrade\rabbitmq-server-4.2.1.exe`

Active installer manifest default:

- `C:\Delivery\RMQUpgrade\manifest.rmq_deploytool_installers.json`

Active options manifest default:

- `C:\Delivery\manifest.rmq_deploytool_options.json`

### TLS Artifact Paths

- `C:\RabbitMQ\certs\server.crt`
- `C:\RabbitMQ\certs\server.key`
- `C:\RabbitMQ\certs\ca.crt`

### RabbitMQ Config Path

The script determines the config path using:

1. `RABBITMQ_CONFIG_FILE` if set
2. otherwise `RABBITMQ_BASE`
3. otherwise `C:\ProgramData\RabbitMQ\rabbitmq.conf`

The script now sets `RABBITMQ_BASE` from the options manifest default, which is typically `C:\RabbitMQ`.

In the current sec.re / Delinea Helper deployment model, the config therefore commonly becomes:

- `C:\RabbitMQ\rabbitmq.conf`
- `C:\RabbitMQ\advanced.config`
- `C:\RabbitMQ\enabled_plugins`

### RabbitMQ Base Path

Resolved as:

- `rabbitmq_base_path` from `manifest.rmq_deploytool_options.json`
- otherwise `RABBITMQ_BASE`
- otherwise `C:\RabbitMQ`

Operational note:

- in the deployment layout currently in use, the effective RabbitMQ base path is `C:\RabbitMQ`
- this means RabbitMQ state and configuration are typically found under:
  - `C:\RabbitMQ\db`
  - `C:\RabbitMQ\log`
  - `C:\RabbitMQ\rabbitmq.conf`
  - `C:\RabbitMQ\advanced.config`
  - `C:\RabbitMQ\enabled_plugins`
  - `C:\RabbitMQ\certs`
- if neither the options manifest nor `RABBITMQ_BASE` is set, the script fallback remains `C:\RabbitMQ`

### Erlang Cookie Paths

The script may write or remove cookies in:

- `C:\Windows\.erlang.cookie`
- `C:\Windows\System32\config\systemprofile\.erlang.cookie`
- `%USERPROFILE%\.erlang.cookie`
- the RabbitMQ service profile cookie path, depending on the service account

Simple cookie check commands:

```powershell
Get-Content C:\Windows\.erlang.cookie
Get-Content C:\Windows\System32\config\systemprofile\.erlang.cookie
Get-Content $env:USERPROFILE\.erlang.cookie
```

Check all likely cookie files at once:

```powershell
$paths = @(
  'C:\Windows\.erlang.cookie',
  'C:\Windows\System32\config\systemprofile\.erlang.cookie',
  (Join-Path $env:USERPROFILE '.erlang.cookie'),
  'C:\Windows\ServiceProfiles\LocalService\.erlang.cookie',
  'C:\Windows\ServiceProfiles\NetworkService\.erlang.cookie'
) | Where-Object { Test-Path $_ }

foreach ($path in $paths) {
  Write-Host "`n$path"
  Get-Content $path
}
```

Short rule: the Erlang cookie must be exactly the same in all cookie files that exist on the node, and it must also be the same on every cluster node.

### RabbitMQ CLI Path

The script resolves RabbitMQ CLI tools by:

- checking `PATH`
- checking `*.bat` commands
- scanning `C:\Program Files\RabbitMQ Server\...\sbin`

## Firewall Rules Created

The script creates inbound Windows Firewall rules grouped as:

- `RabbitMQ Deployment Tool`

Rule names:

- `RabbitMQ Deployment Tool - TCP <port>`

### Managed Standalone Ports

The script manages both the TLS and non-TLS RabbitMQ service ports so source scopes stay consistent even when the deployment mode changes later.

- `5672` AMQP
- `5671` AMQP over TLS
- `15672` HTTP management
- `15671` HTTPS management
- `15692` Prometheus

### Additional Ports For Clusters

In cluster mode, these are also opened:

- `4369` EPMD
- `25672` inter-node / CLI traffic

Firewall scope note:

- by default, the script creates Windows Firewall rules that allow all remote sources for the AMQP and cluster ports it manages
- the management ports are restricted to `127.0.0.1` by default using `management_allowed_sources`
- the Prometheus port is restricted to `127.0.0.1` by default using `prometheus_allowed_sources`
- the AMQP ports can be source-restricted using `amqp_allowed_sources` in `manifest.rmq_deploytool_options.json`
- the cluster ports can be source-restricted using `cluster_allowed_sources` in `manifest.rmq_deploytool_options.json`
- AMQP and management source scopes are applied to both the TLS and non-TLS port variants, not only the currently active one
- the secure default for Prometheus is `127.0.0.1`
- the secure default for management is `127.0.0.1`
- to broaden Prometheus access, add entries such as:
  - `172.20.0.0/16`
  - `172.21.1.1/32`
  - `172.21.1.1`
- to broaden management access, use the same entry format in `management_allowed_sources`
- to harden AMQP access, add the engine, web server, or application host IPs/subnets to `amqp_allowed_sources`
- to harden cluster inter-node access, add all cluster node IPs or cluster subnets to `cluster_allowed_sources`
- if a source IP is given without a prefix, the script treats it as `/32` automatically

## Plugins Enabled

The script enables:

- `rabbitmq_management`
- `rabbitmq_shovel`
- `rabbitmq_shovel_management`
- `rabbitmq_prometheus`

### Prometheus Plugin Usage

The Prometheus endpoint is exposed by `rabbitmq_prometheus`.

Default endpoint:

- `http://<hostname>:15692/metrics`

Simple test examples:

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:15692/metrics
```

```powershell
curl http://localhost:15692/metrics
```

Prometheus scrape target example:

```yaml
scrape_configs:
  - job_name: rabbitmq
    static_configs:
      - targets:
          - rmq10041:15692
          - rmq10042:15692
          - rmq10043:15692
```

Access restriction guidance:

- RabbitMQ exposes the Prometheus listener on port `15692` by default
- RabbitMQ can bind that listener to a specific local interface using `prometheus.tcp.ip`
- RabbitMQ documentation does not provide a native source-IP allowlist for Prometheus scrapers
- to restrict which source systems can reach the endpoint, use Windows Firewall remote address scoping or another network control in front of the node
- this tool now supports Windows Firewall remote address scoping for the Prometheus port through `prometheus_allowed_sources` in `manifest.rmq_deploytool_options.json`
- the default is localhost-only: `127.0.0.1`
- widen the allowed sources only for your monitoring subnets or monitoring hosts
- if you do not want the script to manage firewall rules at all, disable automatic firewall management in `manifest.rmq_deploytool_options.json`

Example RabbitMQ config for binding the Prometheus listener to a specific local IP:

```ini
prometheus.tcp.port = 15692
prometheus.tcp.ip = 127.0.0.1
```

Example Windows Firewall idea:

- allow TCP `15692` only from your Prometheus server IPs or monitoring subnet CIDRs
- do not leave TCP `15692` open to all remote addresses unless that is intended

## Hardening Tips

Windows Firewall source scoping can be used to harden access beyond the defaults:

- keep management restricted to localhost unless administrators need remote browser access
- if remote management is required, add only the administrator workstation subnets or jump hosts to `management_allowed_sources`
- keep Prometheus restricted to localhost unless a monitoring server must scrape the node
- if Prometheus scraping is required, add only the monitoring hosts or monitoring subnet CIDRs to `prometheus_allowed_sources`
- AMQP is open to all by default to avoid breaking client connectivity
- if you want to harden AMQP access, define `amqp_allowed_sources` with only the Secret Server web servers, engines, application servers, or approved client subnets
- cluster ports `4369` and `25672` are open to all by default
- if you want to harden cluster inter-node access, define `cluster_allowed_sources` with the IPs or CIDRs of all RabbitMQ cluster nodes
- when hardening cluster ports, make sure every participating node is included or clustering will fail

## Script Phases

## Phase 1: Parameter Validation And Input Collection

The script:

- shows mode information
- validates mode and flag combinations
- prompts for missing values where needed
- collects node role / cluster name / node1 host
- collects TLS mode and TLS action
- collects credentials if an install will happen
- collects certificate-related values if TLS is being applied

## Phase 2: Install / Upgrade / Reapply Decision

Depending on mode, the script:

- reinstalls completely
- upgrades
- installs if RabbitMQ is not present
- skips installation in reapply-only mode
- skips installation if RabbitMQ already exists

Actions performed here can include:

- loading the installer manifest
- loading the options manifest
- resolving Erlang and RabbitMQ installer paths from the manifest
- validating installer hashes using the manifest `hash_type` and `hash`
- if `download_url` is present and `-AllowInstallerDownload` is used:
  - checking whether the download source is reachable
  - downloading missing or invalid installers
  - validating the downloaded files again by hash
- setting `RABBITMQ_BASE` from the options manifest
- calling `Install-Connector`
- stopping the RabbitMQ service
- running the RabbitMQ installer silently
- removing stale RabbitMQ `sbin` entries from the machine PATH
- adding the current RabbitMQ `sbin` directory to the machine PATH when enabled

If the installer manifest is missing for an install / reinstall / upgrade path, the script stops before continuing.

### Reapply-Only Behavior

When `-ReapplyOnly` is used, the script does not reinstall Erlang or RabbitMQ, but it still reapplies the managed settings defined by the script and manifests.

This includes:

- loading the options manifest
- setting `RABBITMQ_BASE`
- refreshing the RabbitMQ `sbin` PATH entry when enabled
- enabling the configured RabbitMQ plugins
- rewriting plain or TLS RabbitMQ configuration depending on the selected TLS mode and action
- recreating TLS artifacts from the provided inputs when TLS is applied
- removing TLS artifacts when TLS removal is selected
- reapplying Windows Firewall rules and their source scopes for both TLS and non-TLS managed service ports
- restarting RabbitMQ
- validating the resulting local or cluster state

In cluster mode:

- `-ReapplyOnly` does not automatically re-run the cluster join
- use `-JoinCluster` together with `-ReapplyOnly` if you intentionally want to re-run node 2 or node 3 join actions

## Phase 3: Plugin Enablement

The script enables the plugin list defined in `manifest.rmq_deploytool_options.json`.

By default this includes:

- `rabbitmq_management`
- `rabbitmq_shovel`
- `rabbitmq_shovel_management`
- `rabbitmq_prometheus`

## Phase 4: TLS Or Non-TLS Configuration

Depending on `TlsAction`, the script:

- applies TLS by writing certificate files and TLS config
- removes TLS by deleting the active RabbitMQ `certs` directory and writing plain config
- keeps existing TLS configuration untouched

## Phase 5: Firewall Configuration

If firewall management is enabled in the options manifest, the script adds the required Windows Firewall rules for the selected deployment.

If firewall management is disabled, the script skips rule creation.

When `-ReapplyOnly` is used, existing managed firewall rules are removed and recreated so updated source scopes and ports are applied.

The current source-scope model is:

- management source scope applies to both `15672` and `15671`
- AMQP source scope applies to both `5672` and `5671`
- Prometheus source scope applies to `15692`
- cluster source scope applies to both `4369` and `25672`

## Phase 6: Cluster Logic

Only in cluster mode.

On RabbitMQ 4.2.x, a normal RabbitMQ cluster may use Khepri internally for metadata. Operators do not deploy a separate Khepri product, but they will see Khepri-related quorum messages during cluster operations.

Operational warning:

- never run reset, reapply, restart, or join actions on two cluster nodes at the same time
- in a 3-node cluster, always keep at least 2 nodes available
- otherwise the cluster can fall into minority and membership changes can fail even when the Windows services are running

### On Node 1

The script:

- sets the cluster name using `rabbitmqctl set_cluster_name`
- prints bootstrap cookie value
- prints bootstrap cookie hash
- sets quorum queue default in config

### On Node 2 / Node 3

The script:

- checks DNS resolution for `Node1Host`
- checks connectivity to node 1 on `4369` and `25672`
- handles Erlang cookie validation or replacement
- waits for bootstrap node RabbitMQ client port
- runs:
  - `rabbitmqctl join_cluster rabbit@<Node1Host>`
  - `rabbitmqctl start_app`
- validates cluster membership

For RabbitMQ 4.2.x recovery or rejoin scenarios, a working recovery sequence can be:

- `rabbitmqctl.bat join_cluster rabbit@rmq10041`
- `rabbitmqctl.bat start_app`

This avoids an unnecessary `reset` during simple recovery when the node only needs to rejoin the existing cluster.

### Important Cookie Behavior

If `-ErlangCookieValue` is supplied, the script now:

- writes the cookie to all relevant local cookie locations
- restarts the RabbitMQ Windows service
- waits until the local CLI can successfully communicate with the local node

This restart is required because changing the cookie file on disk does not update the cookie used by an already-running Erlang node.

Without this restart, cluster join can fail with:

- `rabbitmqctl failed with exit code 69`
- `Invalid challenge reply`

## Phase 7: Service Restart

If a cluster join was just performed:

- the script does not issue the final generic service restart

Otherwise:

- the script runs `Restart-Service RabbitMQ`
- waits 10 seconds

## Phase 8: Validation

The script validates by running:

- `rabbitmq-diagnostics cluster_status`
- `rabbitmqctl list_queues name type durable`

## Troubleshooting Recovery

### Cluster In Minority After Operational Mistake

If two nodes were restarted, reset, or reapplied at the same time in a 3-node cluster, the cluster can fall into minority.

Typical symptom:

- `Khepri has timed out on node rabbit@<node>`
- `Khepri cluster could be in minority`

Recovery approach:

1. Do not keep resetting nodes.
2. Bring two original cluster members back up first.
3. Confirm the cluster is healthy again on the bootstrap or surviving node:

```powershell
rabbitmqctl.bat cluster_status
rabbitmq-diagnostics.bat status
```

4. On the affected node, use the rejoin sequence:

```powershell
rabbitmqctl.bat join_cluster rabbit@rmq10041
rabbitmqctl.bat start_app
```

5. Confirm the node appears again in cluster status.

### Local Management Interface Not Working

If the local management UI does not open or does not allow login after a cluster issue, verify:

```powershell
rabbitmq-diagnostics.bat listeners
rabbitmq-plugins.bat list -E
rabbitmqctl.bat list_users
Get-Content C:\RabbitMQ\rabbitmq.conf
Get-ChildItem C:\RabbitMQ\certs
```

Check that:

- `rabbitmq_management` is enabled
- the management TLS listener is present on `15671`
- the expected admin user exists
- the certificate and key files are present
- the cluster is no longer in minority

## Phase 9: Cleanup And UI

The script:

- clears credential variables
- runs garbage collection
- opens the RabbitMQ management UI

Management UI URL depends on TLS mode:

- `http://127.0.0.1:15672` for non-TLS
- `https://127.0.0.1:15671` for TLS

## Supported Installation Combinations

### Standalone

- Standalone, no TLS
- Standalone, TLS, `CertMode 1`
- Standalone, TLS, `CertMode 2`
- Standalone, TLS, `CertMode 3`

### Cluster

- 3-node cluster, no TLS
- 3-node cluster, TLS, `CertMode 1`
- 3-node cluster, TLS, `CertMode 2`
- 3-node cluster, TLS, `CertMode 3`

### Maintenance

- Upgrade existing RabbitMQ
- Uninstall only
- Uninstall and purge configuration
- Uninstall and reinstall
- Reapply configuration only

## Example Command Lines

### Standalone Without TLS

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 1 `
  -TLSMode 1 `
  -TlsAction Remove `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#'
```

### Standalone TLS PFX Only

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 1 `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 1 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#'
```

### Standalone TLS PFX + Chain

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 1 `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 2 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#' `
  -ExternalCA 'C:\Delivery\certs\__dssdev1_sec_re.ca-bundle'
```

### Standalone TLS PEM Files

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 1 `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 3 `
  -ServerCertPath 'C:\Delivery\certs\server.crt' `
  -PrivateKeyPath 'C:\Delivery\certs\server.key' `
  -CAChainPath 'C:\Delivery\certs\ca-chain.crt'
```

### Cluster Node 1 Without TLS

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -NodeRole 1 `
  -ClusterName 'rmq.dssdev1.sec.re' `
  -TLSMode 1 `
  -TlsAction Remove `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#'
```

### Cluster Node 2 Or 3 Without TLS

On node 1, read the Erlang cookie first and use that value for `-ErlangCookieValue`:

```powershell
Get-Content C:\Windows\.erlang.cookie
```

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 2 `
  -Node1Host 'rmq10041' `
  -TLSMode 1 `
  -TlsAction Remove `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -ErlangCookieValue 'GOLRHLWTJDVTUGCDVHOD'
```

For node 3, change only:

```text
-NodeRole 3
```

### Cluster Node 1 TLS PFX Only

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -NodeRole 1 `
  -ClusterName 'rmq.dssdev1.sec.re' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 1 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#'
```

### Cluster Node 2 Or 3 TLS PFX Only

On node 1, read the Erlang cookie first and use that value for `-ErlangCookieValue`:

```powershell
Get-Content C:\Windows\.erlang.cookie
```

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 3 `
  -Node1Host 'rmq10041' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 1 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#' `
  -ErlangCookieValue 'GOLRHLWTJDVTUGCDVHOD'
```

### Cluster Node 1 TLS PFX + Chain

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -NodeRole 1 `
  -ClusterName 'rmq.dssdev1.sec.re' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 2 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#' `
  -ExternalCA 'C:\Delivery\certs\__dssdev1_sec_re.ca-bundle'
```

### Cluster Node 2 Or 3 TLS PFX + Chain

On node 1, read the Erlang cookie first and use that value for `-ErlangCookieValue`:

```powershell
Get-Content C:\Windows\.erlang.cookie
```

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 3 `
  -Node1Host 'rmq10041' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 2 `
  -RabbitMQPfxPath 'C:\Delivery\certs\secre-aes.pfx' `
  -PfxPassword 'Pfx8m!R4kT2#' `
  -ExternalCA 'C:\Delivery\certs\__dssdev1_sec_re.ca-bundle' `
  -ErlangCookieValue 'GOLRHLWTJDVTUGCDVHOD'
```

### Cluster Node 1 TLS PEM Files

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -NodeRole 1 `
  -ClusterName 'rmq.dssdev1.sec.re' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 3 `
  -ServerCertPath 'C:\Delivery\certs\server.crt' `
  -PrivateKeyPath 'C:\Delivery\certs\server.key' `
  -CAChainPath 'C:\Delivery\certs\ca-chain.crt'
```

### Cluster Node 2 Or 3 TLS PEM Files

On node 1, read the Erlang cookie first and use that value for `-ErlangCookieValue`:

```powershell
Get-Content C:\Windows\.erlang.cookie
```

```powershell
.\rmq_deploytool.ps1 `
  -DeployMode 2 `
  -JoinCluster `
  -NodeRole 3 `
  -Node1Host 'rmq10041' `
  -TLSMode 2 `
  -TlsAction Apply `
  -RabbitMQUser 'test' `
  -RabbitMQUserPassword 'test' `
  -RabbitMQAdmin 'admin' `
  -RabbitMQAdminPassword 'Adm9x!Q2vL7#' `
  -CertMode 3 `
  -ServerCertPath 'C:\Delivery\certs\server.crt' `
  -PrivateKeyPath 'C:\Delivery\certs\server.key' `
  -CAChainPath 'C:\Delivery\certs\ca-chain.crt' `
  -ErlangCookieValue 'GOLRHLWTJDVTUGCDVHOD'
```

## Notes And Recommendations

- Always run as Administrator
- Prefer passing parameters explicitly instead of relying on interactive prompts
- Use short hostnames for cluster joins
- Supply `-ErlangCookieValue` on node 2 and node 3 to avoid manual hash checks
- If you run the script from `C:\Delivery\rmq_deploytool.ps1`, keep that copy synchronized with the workspace copy
- If files came from the internet or a remote source, unblock them before execution
- Start from `Delinea RabbitMQ Helper` and use `Advanced (PowerShell)` for helper-based operations
- Treat `manifest.rmq_deploytool_installers.json` as the installer source of truth, not the folder contents alone
- Treat `manifest.rmq_deploytool_options.json` as the deployment-default source of truth for base path, ports, plugins, firewall behavior, and PATH management
- Do not rely only on whatever files happen to exist in `C:\Delivery\RMQUpgrade`
- Keep the manifest hash values updated when you intentionally change installer versions
- Keep versioned manifests for known-good Erlang/RabbitMQ combinations

## Summary

`rmq_deploytool.ps1` is the sec.re RabbitMQ deployment tool for Delinea RabbitMQ Helper based Windows deployments. It is a combined installer, configurator, cluster join tool, TLS configurator, upgrade helper, and uninstall tool for RabbitMQ on Windows. It supports standalone and clustered deployments, TLS and non-TLS modes, multiple certificate input methods, controlled firewall configuration, separated installer and options manifests, and clean removal paths.

It was specifically created to help the RabbitMQ Helper path, because that operational model has historically required too much manual troubleshooting. This tool turns that process into a documented, repeatable delivery workflow.


