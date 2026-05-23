/*
 * role-overlay-iceberg-nftables-backplane.tf -- Phase 0.L.2
 *
 * Pushes the per-cluster nftables ruleset to all 4 iceberg nodes (2 PG + 2 REST)
 * + `nft -f`. Single combined ruleset (opening a port a node doesn't listen on
 * is harmless): trust the VMnet10 backplane (PG streaming replication) + open
 * PG :5432 + Nessie :19120 + VRRP (proto 112, keepalived VIP) on VMnet11.
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md + feedback_nftables_
 * runtime_add_after_drop.md (atomic `nft -f`).
 */

locals {
  iceberg_all_nodes = {
    "iceberg-rest-1" = "192.168.70.147"
    "iceberg-rest-2" = "192.168.70.148"
    "iceberg-pg-1"   = "192.168.70.149"
    "iceberg-pg-2"   = "192.168.70.150"
  }
}

resource "null_resource" "iceberg_nftables_backplane" {
  count = var.enable_iceberg_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.iceberg_all_nodes))
    nftables_v   = "1"
    ssh_user     = var.lakehouse_node_user
    boot_timeout = var.lakehouse_cluster_timeout_minutes
  }

  depends_on = [
    module.iceberg_pg_1, module.iceberg_pg_2, module.iceberg_rest_1, module.iceberg_rest_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.iceberg_all_nodes : "'${h}' = '${ip}'"])} }
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
        iifname "nic1" ip saddr 192.168.10.0/24 accept comment "trusted cluster backplane (VMnet10)"
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 5432, 19120 } accept comment "PostgreSQL + Nessie Iceberg REST from VMnet11"
        iifname "nic0" ip saddr 192.168.70.0/24 ip protocol vrrp accept comment "keepalived VRRP from VMnet11"
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
        Write-Host "[iceberg-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/lakehouse-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[iceberg-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[iceberg-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
        Write-Host "[iceberg-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}
