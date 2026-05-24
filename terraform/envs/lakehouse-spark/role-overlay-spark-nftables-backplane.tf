/*
 * role-overlay-spark-nftables-backplane.tf -- Phase 0.L.3
 *
 * Pushes the per-cluster nftables ruleset to all 8 spark-tier nodes (2 masters +
 * 3 workers + 3 ZooKeeper) + `nft -f`. Single combined ruleset (opening a port a
 * node doesn't listen on is harmless): trust the VMnet10 backplane (Spark<->ZK
 * election, master<->worker, ZK quorum 2888/3888 + client 2181) + open the Spark
 * RPC :7077 + master UI :8080 + worker UI :8081 on VMnet11. ZooKeeper exposes
 * nothing on VMnet11 (backplane-only, ADR-0035).
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md + feedback_nftables_
 * runtime_add_after_drop.md (atomic `nft -f`).
 */

locals {
  spark_all_nodes = {
    "spark-master-1" = "192.168.70.140"
    "spark-master-2" = "192.168.70.153"
    "spark-worker-1" = "192.168.70.145"
    "spark-worker-2" = "192.168.70.146"
    "spark-worker-3" = "192.168.70.154"
    "zookeeper-1"    = "192.168.70.155"
    "zookeeper-2"    = "192.168.70.156"
    "zookeeper-3"    = "192.168.70.157"
  }
}

resource "null_resource" "spark_nftables_backplane" {
  count = var.enable_spark_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.spark_all_nodes))
    nftables_v   = "2" # v2 (0.L.3): + Spark cluster-peer RPC accept (dynamic driver/blockManager ports)
    ssh_user     = var.lakehouse_node_user
    boot_timeout = var.lakehouse_cluster_timeout_minutes
  }

  depends_on = [
    module.spark_master_1, module.spark_master_2,
    module.spark_worker_1, module.spark_worker_2, module.spark_worker_3,
    module.zookeeper_1, module.zookeeper_2, module.zookeeper_3,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.spark_all_nodes : "'${h}' = '${ip}'"])} }
      $sshUser     = '${var.lakehouse_node_user}'
      $bootTimeout = ${var.lakehouse_cluster_timeout_minutes}
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state { established, related } accept
        ct state invalid drop
        ip protocol icmp   accept
        ip6 nexthdr icmpv6 accept
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 22   accept comment "SSH from VMnet11"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport 9100 accept comment "node_exporter from VMnet11"
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted cluster backplane (VMnet10) -- Spark<->ZK + ZK quorum/client"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 7077, 8080, 8081 } accept comment "Spark RPC + master/worker Web UI from VMnet11"
        iifname "nic0" ip saddr { 192.168.70.140, 192.168.70.153, 192.168.70.145, 192.168.70.146, 192.168.70.154 } accept comment "Spark cluster-peer RPC (dynamic driver/blockManager ports, 5 Spark nodes)"
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
'@
      $rulesetB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($ruleset -replace "`r`n","`n")))

      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key
        $ip       = $entry.Value
        Write-Host "[spark-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/lakehouse-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[spark-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[spark-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
        Write-Host "[spark-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}
