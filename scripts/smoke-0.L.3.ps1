#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Smoke gate for Phase 0.L.3 -- Spark standalone HA cluster (2 masters + 3 workers)
  + the 3-node ZooKeeper ensemble.

.DESCRIPTION
  All checks run via SSH to the nodes (on-node curl/zkServer where the Vault CA is
  trusted). Pass -IncludeChaos to add a master-failover test (kills the active
  master; the standby must auto-promote and keep the workers).
#>
[CmdletBinding()]
param(
    [switch]$IncludeChaos
)

$ErrorActionPreference = 'Continue'
$sshUser = 'nexusadmin'
$sshOpts = @('-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$script:fail = 0
function Check([string]$label, [bool]$ok) {
    if ($ok) { Write-Host "[OK]   $label" } else { Write-Host "[FAIL] $label" -ForegroundColor Red; $script:fail++ }
}
function Rssh([string]$ip, [string]$cmd) {
    return (ssh @sshOpts "$sshUser@$ip" $cmd 2>&1 | Out-String).Trim()
}

$sparkNodes = [ordered]@{
    'spark-master-1' = '192.168.70.140'; 'spark-master-2' = '192.168.70.153'
    'spark-worker-1' = '192.168.70.145'; 'spark-worker-2' = '192.168.70.146'; 'spark-worker-3' = '192.168.70.154'
}
$zkNodes = [ordered]@{ 'zookeeper-1' = '192.168.70.155'; 'zookeeper-2' = '192.168.70.156'; 'zookeeper-3' = '192.168.70.157' }
$masters = @('192.168.70.140', '192.168.70.153')
$allNodes = @(); $sparkNodes.GetEnumerator() | ForEach-Object { $allNodes += $_ }; $zkNodes.GetEnumerator() | ForEach-Object { $allNodes += $_ }

Write-Host "`n=== Per-node SSH reachability ==="
foreach ($n in $allNodes) { Check "$($n.Value) : SSH echo probe" ((Rssh $n.Value "echo ok") -match 'ok') }

Write-Host "`n=== lakehouse-node firstboot completion ==="
foreach ($n in $allNodes) { Check "$($n.Value) : firstboot-done marker present" ((Rssh $n.Value "test -f /var/lib/lakehouse-node-firstboot-done && echo Y") -match 'Y') }

Write-Host "`n=== Node-identity mapping ==="
foreach ($n in $sparkNodes.GetEnumerator()) {
    $hn = (Rssh $n.Value "hostname"); Check "$($n.Value) : hostname == $($n.Key)" ($hn -match "^$($n.Key)$")
    $role = (Rssh $n.Value "sudo grep -oP '^NEXUS_ROLE=\K.*' /etc/nexus-spark/node-identity.env")
    $expRole = if ($n.Key -like 'spark-master*') { 'spark-master' } else { 'spark-worker' }
    Check "$($n.Value) : NEXUS_ROLE == $expRole" ($role -match "^$expRole$")
}
foreach ($n in $zkNodes.GetEnumerator()) {
    $hn = (Rssh $n.Value "hostname"); Check "$($n.Value) : hostname == $($n.Key)" ($hn -match "^$($n.Key)$")
    $zid = (Rssh $n.Value "sudo grep -oP '^NEXUS_ZK_ID=\K.*' /etc/nexus-zookeeper/node-identity.env")
    $expId = $n.Key.Split('-')[-1]
    Check "$($n.Value) : NEXUS_ZK_ID == $expId" ($zid -match "^$expId$")
}

Write-Host "`n=== Vault Agent active (5 Spark nodes; ZK has no Vault footprint) ==="
foreach ($n in $sparkNodes.GetEnumerator()) {
    Check "$($n.Value) : nexus-vault-agent.service active" ((Rssh $n.Value "systemctl is-active nexus-vault-agent.service") -match '^active$')
}

Write-Host "`n=== nftables (VMnet10 backplane trust) ==="
foreach ($n in $allNodes) {
    Check "$($n.Value) : VMnet10 backplane trust rule present" ((Rssh $n.Value "sudo nft list ruleset 2>/dev/null | grep -c '192.168.10.0/24'") -match '(?m)^[1-9]')
}

Write-Host "`n=== ZooKeeper ensemble health (1 leader + 2 followers) ==="
$leaders = 0; $followers = 0
foreach ($n in $zkNodes.GetEnumerator()) {
    $mode = (Rssh $n.Value "sudo JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ZOOCFGDIR=/etc/nexus-zookeeper /opt/zookeeper/bin/zkServer.sh status /etc/nexus-zookeeper/zoo.cfg 2>/dev/null | grep -i Mode")
    $isUp = ($mode -match '(?i)leader|follower')
    Check "$($n.Value) : ZooKeeper Mode = leader/follower ($($mode -replace '.*Mode:\s*',''))" $isUp
    if ($mode -match '(?i)leader') { $leaders++ }; if ($mode -match '(?i)follower') { $followers++ }
}
Check "ensemble quorum == 1 leader + 2 followers" ($leaders -eq 1 -and $followers -eq 2)

Write-Host "`n=== Spark masters (HA: 1 ALIVE + 1 STANDBY) + workers ==="
$active = $null; $aliveWorkers = 0; $standby = 0
foreach ($m in $masters) {
    Check "$m : nexus-spark-master.service active" ((Rssh $m "systemctl is-active nexus-spark-master.service") -match '^active$')
    # Master UI binds to the node VMnet11 IP (SPARK_LOCAL_IP), not localhost.
    $j = (Rssh $m "curl -fsS http://${m}:8080/json/ 2>/dev/null")
    if ($j -match '"status"\s*:\s*"ALIVE"') {
        $active = $m
        if ($j -match '"aliveworkers"\s*:\s*([0-9]+)') { $aliveWorkers = [int]$matches[1] }
    } elseif ($j -match '"status"\s*:\s*"STANDBY"') { $standby++ }
}
Check "exactly one master ALIVE" ($null -ne $active)
Check "exactly one master STANDBY" ($standby -eq 1)
Check "active master reports 3 ALIVE workers (got $aliveWorkers)" ($aliveWorkers -ge 3)
foreach ($n in @('spark-worker-1', 'spark-worker-2', 'spark-worker-3')) {
    $ip = $sparkNodes[$n]
    Check "$ip : nexus-spark-worker.service active" ((Rssh $ip "systemctl is-active nexus-spark-worker.service") -match '^active$')
}

Write-Host "`n=== Spark RPC security (authenticate + AES crypto) ==="
$conf = (Rssh $masters[0] "sudo grep -E 'spark.authenticate |spark.network.crypto.enabled' /opt/spark/conf/spark-defaults.conf")
Check "spark.authenticate=true + spark.network.crypto.enabled=true" (($conf -match 'spark.authenticate\s+true') -and ($conf -match 'spark.network.crypto.enabled\s+true'))

Write-Host "`n=== Spark master-HA election state in ZooKeeper (/spark) ==="
$zk = (Rssh '192.168.70.155' "sudo JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 /opt/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181 ls /spark 2>/dev/null | tail -3")
Check "ZooKeeper holds /spark (master_status / leader_election)" (($zk -match 'master_status') -or ($zk -match 'leader_election'))

Write-Host "`n=== Iceberg catalog round-trip (created by the bootstrap exit gate) ==="
# The bootstrap created nexus.lakehouse_demo.smoke (Iceberg via Nessie -> MinIO).
# Verify the namespace persisted via the Nessie Iceberg REST API. Two musts:
#  - the prefixed path: Nessie scopes namespaces under {ref}|{warehouse} =
#    'main%7Cwarehouse' (a bare /v1/namespaces returns empty); discover the prefix
#    from /v1/config?warehouse=warehouse if it ever changes.
#  - --cacert: curl uses the system trust store (no nexus CA); the Vault Agent
#    CA bundle on each spark node validates iceberg.nexus.lab.
$ns = (Rssh $masters[0] "curl -fsS --cacert /etc/vault-agent/ca-bundle.crt 'https://iceberg.nexus.lab:19120/iceberg/v1/main%7Cwarehouse/namespaces' 2>/dev/null")
Check "namespace lakehouse_demo present via Iceberg REST" ($ns -match 'lakehouse_demo')

Write-Host "`n=== Round-robin DNS ==="
$dns = (Rssh '192.168.70.1' "dig +short spark-master.nexus.lab @127.0.0.1")
Check "spark-master.nexus.lab resolves to the 2 master IPs" (($dns -match '192.168.70.140') -and ($dns -match '192.168.70.153'))

if ($IncludeChaos) {
    Write-Host "`n=== CHAOS: active master failover (ZooKeeper-elected) ==="
    Write-Host "[chaos] stopping active master $active ; the standby must promote..."
    Rssh $active "sudo systemctl stop nexus-spark-master.service" | Out-Null
    $other = $masters | Where-Object { $_ -ne $active }
    $promoted = $false
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $j = (Rssh $other "curl -fsS http://${other}:8080/json/ 2>/dev/null")
        if ($j -match '"status"\s*:\s*"ALIVE"') { $promoted = $true; break }
        Start-Sleep -Seconds 8
    }
    Check "standby master $other promoted to ALIVE after failover" $promoted
    Write-Host "[chaos] restarting $active (rejoins as STANDBY)..."
    Rssh $active "sudo systemctl start nexus-spark-master.service" | Out-Null
}

Write-Host "`n===================================================="
if ($script:fail -eq 0) {
    Write-Host "ALL 0.L.3 SMOKE CHECKS PASSED"
    exit 0
} else {
    Write-Host "0.L.3 SMOKE: $script:fail CHECK(S) FAILED" -ForegroundColor Red
    exit 1
}
