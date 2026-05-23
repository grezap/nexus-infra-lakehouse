#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.L.1 smoke gate -- MinIO distributed erasure-coded object store (4 nodes), mTLS.

.DESCRIPTION
  Verifies the 0.L.1 exit gate: a genuine distributed MinIO cluster (ADR-0033) --
  4 nodes each with a dedicated xfs data drive, erasure-coded across the set,
  fronted by round-robin DNS minio.nexus.lab (no VIP -- ADR-0031), with TLS leaf
  certs from Vault PKI. Inter-node erasure/heal/lock traffic on the VMnet10
  backplane; client S3 + Console on VMnet11.

  Sections: reachability -> firstboot -> identity -> vault-agent -> TLS material
  -> nftables -> config/service -> cluster health -> erasure-set drives ->
  buckets -> app user -> round-robin DNS -> object round-trip. With -IncludeChaos:
  single-node-loss tolerance (cluster stays read-write at 3/4; destructive,
  restores after).

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md. Exits 1 on
  any FAIL. mc admin ops run on minio-1 against the nexuslocal alias the
  bucket-bootstrap overlay configured (root creds never printed).

.PARAMETER Strict
  Fail on warnings.

.PARAMETER IncludeChaos
  Run the destructive node-loss check. Default: false.
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [switch]$IncludeChaos
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$minioIps = @('192.168.70.141', '192.168.70.142', '192.168.70.143', '192.168.70.144')
$mc1 = $minioIps[0]
$warehouse = 'warehouse'
$appKey = 'nexus-lakehouse-app'

$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$failures = @()
$warnings = @()

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][scriptblock]$Probe)
    try {
        if (& $Probe) { Write-Host "[OK]   $Description" -ForegroundColor Green; return $true }
        else { Write-Host "[FAIL] $Description" -ForegroundColor Red; $script:failures += $Description; return $false }
    } catch {
        Write-Host "[FAIL] $Description ($($_.Exception.Message))" -ForegroundColor Red
        $script:failures += "$Description ($($_.Exception.Message))"; return $false
    }
}

function Invoke-RemoteCommand {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    return (ssh @sshOpts "$user@$Ip" $Command 2>&1 | Out-String).Trim()
}

# ─── Section 1: reachability ──────────────────────────────────────────────
Write-Section 'Per-node SSH reachability'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : SSH echo probe" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'echo nexus-smoke-marker') -match 'nexus-smoke-marker'
    } | Out-Null
}
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAIL early: $($failures.Count) reachability check(s) failed; skipping later sections." -ForegroundColor Red
    exit 1
}

# ─── Section 2: firstboot ─────────────────────────────────────────────────
Write-Section 'lakehouse-node firstboot completion'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/lakehouse-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
}

# ─── Section 3: identity ──────────────────────────────────────────────────
Write-Section 'Node-identity mapping + dedicated data disk'
$expected = @{
    '192.168.70.141' = 'minio-1'
    '192.168.70.142' = 'minio-2'
    '192.168.70.143' = 'minio-3'
    '192.168.70.144' = 'minio-4'
}
foreach ($ip in $minioIps) {
    $h = $expected[$ip]
    Test-Check -Description "$ip : hostname == $h" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$h\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity role == minio" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -E "^NEXUS_ROLE=" /etc/nexus-minio/node-identity.env') -match 'NEXUS_ROLE=minio'
    } | Out-Null
    Test-Check -Description "$ip : /mnt/minio/data is an xfs mountpoint" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'findmnt -no FSTYPE /mnt/minio/data 2>/dev/null') -match 'xfs'
    } | Out-Null
}

# ─── Section 4: Vault Agent ───────────────────────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : token sink populated" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /var/run/nexus-vault-agent/token && echo TOK') -match 'TOK'
    } | Out-Null
}

# ─── Section 5: TLS material ──────────────────────────────────────────────
Write-Section 'mTLS cert material (public.crt/private.key/CAs + round-robin SAN)'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : /etc/nexus-minio/certs/{public.crt,private.key,CAs/nexus-ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-minio/certs/public.crt && sudo test -s /etc/nexus-minio/certs/private.key && sudo test -s /etc/nexus-minio/certs/CAs/nexus-ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : private key is PKCS#8" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo head -1 /etc/nexus-minio/certs/private.key') -match 'BEGIN PRIVATE KEY'
    } | Out-Null
    Test-Check -Description "$ip : cert SAN includes minio.nexus.lab (round-robin)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-minio/certs/public.crt -noout -ext subjectAltName') -match 'minio\.nexus\.lab'
    } | Out-Null
}

# ─── Section 6: nftables ──────────────────────────────────────────────────
Write-Section 'nftables (VMnet10 backplane trust)'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}

# ─── Section 7: config + service ──────────────────────────────────────────
Write-Section 'minio.conf rendered + nexus-minio.service active'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : /etc/nexus-minio/minio.conf present (MINIO_VOLUMES set)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo grep -c "^MINIO_VOLUMES=" /etc/nexus-minio/minio.conf') -match '(?m)^1\s*$'
    } | Out-Null
    Test-Check -Description "$ip : nexus-minio.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-minio.service') -match '(?m)^active\s*$'
    } | Out-Null
}

# ─── Section 8: cluster health ────────────────────────────────────────────
Write-Section 'Distributed cluster health (quorum)'
foreach ($ip in $minioIps) {
    Test-Check -Description "$ip : /minio/health/cluster returns 200" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsS -k -o /dev/null -w '%{http_code}' https://localhost:9000/minio/health/cluster 2>/dev/null") -match '200'
    } | Out-Null
}

# ─── Section 9: erasure-set drives ────────────────────────────────────────
Write-Section 'Erasure set (>=4 online drives across the cluster)'
Test-Check -Description "mc admin info: >= 4 drives in state ok" -Probe {
    $n = Invoke-RemoteCommand -Ip $mc1 -Command 'sudo mc admin info nexuslocal --json 2>/dev/null | jq "[.info.servers[].drives[] | select(.state==\"ok\")] | length"'
    [int]($n -replace '[^0-9]', '') -ge 4
} | Out-Null

# ─── Section 10: buckets ──────────────────────────────────────────────────
Write-Section 'Warehouse + auxiliary buckets present'
$mcLs = Invoke-RemoteCommand -Ip $mc1 -Command 'sudo mc ls nexuslocal 2>/dev/null'
foreach ($b in @('warehouse', 'spark-events', 'lakehouse')) {
    Test-Check -Description "bucket present: $b" -Probe { $mcLs -match "\b$b\b" } | Out-Null
}

# ─── Section 11: app service account ──────────────────────────────────────
Write-Section 'Least-priv app service account (consumed by 0.L.2/0.L.3)'
Test-Check -Description "app user '$appKey' exists" -Probe {
    (Invoke-RemoteCommand -Ip $mc1 -Command 'sudo mc admin user list nexuslocal 2>/dev/null') -match [regex]::Escape($appKey)
} | Out-Null

# ─── Section 12: round-robin DNS ──────────────────────────────────────────
Write-Section 'Round-robin DNS (minio.nexus.lab -> 4 nodes, no VIP)'
Test-Check -Description "minio.nexus.lab resolves to the 4 MinIO IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short minio.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($minioIps | Where-Object { $resolved -contains $_ }).Count -ge 4
} | Out-Null

# ─── Section 13: object round-trip ────────────────────────────────────────
Write-Section 'Object write/read round-trip on the warehouse bucket'
Test-Check -Description "mc cp + cat round-trip succeeds" -Probe {
    $probe = "nexus-smoke-$(Get-Random)"
    $cmd = "set -e; T=`$(mktemp); echo '$probe' > `$T; sudo mc cp `$T nexuslocal/$warehouse/.smoke-probe >/dev/null; sudo mc cat nexuslocal/$warehouse/.smoke-probe | grep -q '$probe' && sudo mc rm nexuslocal/$warehouse/.smoke-probe >/dev/null && rm -f `$T && echo RT_OK"
    (Invoke-RemoteCommand -Ip $mc1 -Command $cmd) -match 'RT_OK'
} | Out-Null

# ─── Section 14 (optional): chaos ─────────────────────────────────────────
if ($IncludeChaos) {
    Write-Section 'CHAOS: single-node-loss tolerance (cluster stays read-write at 3/4; destructive)'
    $victim = '192.168.70.144'  # minio-4 (NOT the mc-alias node minio-1)
    Write-Host "[chaos] stopping nexus-minio on $victim ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $victim -Command 'sudo systemctl stop nexus-minio.service' | Out-Null
    Start-Sleep -Seconds 10
    Test-Check -Description "write still succeeds with 1 node down (write quorum 3/4)" -Probe {
        $probe = "nexus-chaos-$(Get-Random)"
        $cmd = "set -e; T=`$(mktemp); echo '$probe' > `$T; sudo mc cp `$T nexuslocal/$warehouse/.chaos-probe >/dev/null && sudo mc cat nexuslocal/$warehouse/.chaos-probe | grep -q '$probe' && sudo mc rm nexuslocal/$warehouse/.chaos-probe >/dev/null && rm -f `$T && echo CHAOS_OK"
        (Invoke-RemoteCommand -Ip $mc1 -Command $cmd) -match 'CHAOS_OK'
    } | Out-Null
    Write-Host "[chaos] restarting nexus-minio on $victim ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $victim -Command 'sudo systemctl start nexus-minio.service' | Out-Null
    Start-Sleep -Seconds 10
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.L.1 SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "0.L.1 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
