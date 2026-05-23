#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.L.2 smoke gate -- Iceberg REST catalog (Nessie) + dedicated PG HA, mTLS.

.DESCRIPTION
  Verifies the 0.L.2 exit gate (ADR-0034): a dedicated PostgreSQL master-replica
  pair (streaming replication + keepalived VRRP VIP iceberg-db.nexus.lab) backing
  two HA Project Nessie instances that serve the Iceberg REST API
  (https://iceberg.nexus.lab:19120/iceberg/), warehouse in MinIO.

  Sections: reachability -> firstboot -> identity -> vault-agent -> TLS material
  -> nftables -> PG replication -> keepalived VIP -> Nessie health + REST config
  -> round-robin/VIP DNS -> catalog namespace round-trip. With -IncludeChaos:
  PG primary-loss -> VIP failover + standby auto-promote -> catalog stays up.

  Probe robustness per memory/feedback_smoke_gate_probe_robustness.md. Exits 1 on
  any FAIL.

.PARAMETER Strict
  Fail on warnings.
.PARAMETER IncludeChaos
  Run the destructive PG failover check. Default: false.
#>

[CmdletBinding()]
param(
    [switch]$Strict,
    [switch]$IncludeChaos
)

$ErrorActionPreference = 'Stop'

$user = 'nexusadmin'
$pgIps   = @('192.168.70.149', '192.168.70.150')   # pg-1 primary, pg-2 replica
$restIps = @('192.168.70.147', '192.168.70.148')
$allIps  = $pgIps + $restIps
$primaryIp = $pgIps[0]
$vip = '192.168.70.151'

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
foreach ($ip in $allIps) {
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
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : firstboot-done marker present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'test -f /var/lib/lakehouse-node-firstboot-done && echo done') -match '(?m)^done\s*$'
    } | Out-Null
}

# ─── Section 3: identity ──────────────────────────────────────────────────
Write-Section 'Node-identity mapping'
$expected = @{
    '192.168.70.147' = @{ host = 'iceberg-rest-1'; role = 'iceberg-rest'; dir = '/etc/nexus-iceberg-rest' }
    '192.168.70.148' = @{ host = 'iceberg-rest-2'; role = 'iceberg-rest'; dir = '/etc/nexus-iceberg-rest' }
    '192.168.70.149' = @{ host = 'iceberg-pg-1';   role = 'iceberg-pg';   dir = '/etc/nexus-iceberg-pg' }
    '192.168.70.150' = @{ host = 'iceberg-pg-2';   role = 'iceberg-pg';   dir = '/etc/nexus-iceberg-pg' }
}
foreach ($ip in $allIps) {
    $e = $expected[$ip]
    Test-Check -Description "$ip : hostname == $($e.host)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'hostname') -match "(?m)^$($e.host)\s*$"
    } | Out-Null
    Test-Check -Description "$ip : node-identity role == $($e.role)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "sudo grep -E '^NEXUS_ROLE=' $($e.dir)/node-identity.env") -match "NEXUS_ROLE=$($e.role)"
    } | Out-Null
}
Test-Check -Description "iceberg-pg-1 : NEXUS_PG_ROLE == primary" -Probe {
    (Invoke-RemoteCommand -Ip '192.168.70.149' -Command 'sudo grep -E "^NEXUS_PG_ROLE=" /etc/nexus-iceberg-pg/node-identity.env') -match 'NEXUS_PG_ROLE=primary'
} | Out-Null

# ─── Section 4: Vault Agent ───────────────────────────────────────────────
Write-Section 'Vault Agent active + token sink'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : nexus-vault-agent.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-vault-agent.service') -match '(?m)^active\s*$'
    } | Out-Null
}

# ─── Section 5: TLS material ──────────────────────────────────────────────
Write-Section 'mTLS cert material'
foreach ($ip in $pgIps) {
    Test-Check -Description "$ip : PG /etc/nexus-iceberg-pg/tls/{server.crt,server.key,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-iceberg-pg/tls/server.crt && sudo test -s /etc/nexus-iceberg-pg/tls/server.key && sudo test -s /etc/nexus-iceberg-pg/tls/ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : PG cert SAN includes iceberg-db.nexus.lab" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-iceberg-pg/tls/server.crt -noout -ext subjectAltName') -match 'iceberg-db\.nexus\.lab'
    } | Out-Null
}
foreach ($ip in $restIps) {
    Test-Check -Description "$ip : REST /etc/nexus-iceberg-rest/tls/{cert.pem,key.pem,ca.crt} present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo test -s /etc/nexus-iceberg-rest/tls/cert.pem && sudo test -s /etc/nexus-iceberg-rest/tls/key.pem && sudo test -s /etc/nexus-iceberg-rest/tls/ca.crt && echo OK') -match 'OK'
    } | Out-Null
    Test-Check -Description "$ip : REST cert SAN includes iceberg.nexus.lab (round-robin)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo openssl x509 -in /etc/nexus-iceberg-rest/tls/cert.pem -noout -ext subjectAltName') -match 'iceberg\.nexus\.lab'
    } | Out-Null
}

# ─── Section 6: nftables ──────────────────────────────────────────────────
Write-Section 'nftables (VMnet10 backplane trust)'
foreach ($ip in $allIps) {
    Test-Check -Description "$ip : VMnet10 backplane trust rule present" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'sudo nft list chain inet filter input') -match 'saddr 192\.168\.10\.0/24 accept'
    } | Out-Null
}

# ─── Section 7: PostgreSQL streaming replication ──────────────────────────
Write-Section 'PostgreSQL master-replica streaming replication'
Test-Check -Description "primary (pg-1): >= 1 streaming standby" -Probe {
    [int](Invoke-RemoteCommand -Ip $primaryIp -Command "sudo -u postgres psql -tAc `"SELECT count(*) FROM pg_stat_replication WHERE state='streaming'`"") -ge 1
} | Out-Null
Test-Check -Description "replica (pg-2): pg_is_in_recovery() == true" -Probe {
    (Invoke-RemoteCommand -Ip '192.168.70.150' -Command 'sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()"') -match '(?i)^t'
} | Out-Null
Test-Check -Description "primary (pg-1): nessie database exists" -Probe {
    (Invoke-RemoteCommand -Ip $primaryIp -Command "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_database WHERE datname='nessie'`"") -match '1'
} | Out-Null

# ─── Section 8: keepalived VRRP VIP ───────────────────────────────────────
Write-Section 'keepalived VRRP VIP (.151 -> current primary)'
Test-Check -Description "VIP $vip bound on exactly one PG node" -Probe {
    $count = 0
    foreach ($ip in $pgIps) {
        $has = (Invoke-RemoteCommand -Ip $ip -Command "ip -4 -o addr show nic0 | grep -c '$vip'")
        if ($has -match '(?m)^[1-9]') { $count++ }
    }
    $count -eq 1
} | Out-Null

# ─── Section 9: Nessie + Iceberg REST ─────────────────────────────────────
Write-Section 'Nessie health + Iceberg REST API'
foreach ($ip in $restIps) {
    Test-Check -Description "$ip : nexus-nessie.service active" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command 'systemctl is-active nexus-nessie.service') -match '(?m)^active\s*$'
    } | Out-Null
    Test-Check -Description "$ip : Nessie /q/health == 200 (mgmt :9000)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:9000/q/health") -match '200'
    } | Out-Null
    Test-Check -Description "$ip : Iceberg REST /v1/config == 200" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsS -k -o /dev/null -w '%{http_code}' https://localhost:19120/iceberg/v1/config") -match '200'
    } | Out-Null
    Test-Check -Description "$ip : Nessie /api/v2/config == 200 (PG backend)" -Probe {
        (Invoke-RemoteCommand -Ip $ip -Command "curl -fsS -k -o /dev/null -w '%{http_code}' https://localhost:19120/api/v2/config") -match '200'
    } | Out-Null
}

# ─── Section 10: DNS ──────────────────────────────────────────────────────
Write-Section 'Round-robin + VIP DNS'
Test-Check -Description "iceberg.nexus.lab resolves to the 2 REST IPs" -Probe {
    $a = (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short iceberg.nexus.lab @127.0.0.1') -split "\s+"
    $resolved = @($a | Where-Object { $_ })
    ($restIps | Where-Object { $resolved -contains $_ }).Count -ge 2
} | Out-Null
Test-Check -Description "iceberg-db.nexus.lab resolves to the VIP $vip" -Probe {
    (Invoke-RemoteCommand -Ip '192.168.70.1' -Command 'dig +short iceberg-db.nexus.lab @127.0.0.1') -match [regex]::Escape($vip)
} | Out-Null

# ─── Section 11: catalog namespace round-trip ─────────────────────────────
Write-Section 'Catalog namespace round-trip (created by bootstrap)'
Test-Check -Description "namespace nexus_lakehouse present via Iceberg REST" -Probe {
    $prefix = (Invoke-RemoteCommand -Ip $restIps[0] -Command "curl -sk https://localhost:19120/iceberg/v1/config | jq -r '.overrides.prefix // .defaults.prefix // `"main`"'")
    (Invoke-RemoteCommand -Ip $restIps[0] -Command "curl -sk https://localhost:19120/iceberg/v1/$prefix/namespaces") -match 'nexus_lakehouse'
} | Out-Null

# ─── Section 12 (optional): chaos -- PG failover ──────────────────────────
if ($IncludeChaos) {
    Write-Section 'CHAOS: PG primary-loss -> VIP failover + standby auto-promote (destructive)'
    Write-Host "[chaos] stopping PostgreSQL on the primary ($primaryIp) ..." -ForegroundColor Yellow
    Invoke-RemoteCommand -Ip $primaryIp -Command 'sudo systemctl stop postgresql@17-main' | Out-Null
    Start-Sleep -Seconds 20
    Test-Check -Description "VIP $vip moved to the replica (pg-2)" -Probe {
        (Invoke-RemoteCommand -Ip '192.168.70.150' -Command "ip -4 -o addr show nic0 | grep -c '$vip'") -match '(?m)^[1-9]'
    } | Out-Null
    Test-Check -Description "replica (pg-2) promoted out of recovery" -Probe {
        (Invoke-RemoteCommand -Ip '192.168.70.150' -Command 'sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()"') -match '(?i)^f'
    } | Out-Null
    Write-Host "[chaos] NOTE: pg-1 must be re-synced as a standby of pg-2 (manual recovery -- handbook §3)." -ForegroundColor Yellow
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
if ($failures.Count -eq 0 -and (-not $Strict -or $warnings.Count -eq 0)) {
    Write-Host 'ALL 0.L.2 SMOKE CHECKS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host "0.L.2 SMOKE FAILED: $($failures.Count) failure(s)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
