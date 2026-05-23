/*
 * role-overlay-minio-nftables-backplane.tf -- Phase 0.L.1
 *
 * Pushes the per-cluster nftables ruleset to all 4 MinIO nodes + `nft -f`.
 * Single ruleset for all 4: trust the VMnet10 backplane (MinIO distributed peer
 * traffic on 9000 -- erasure read/write, heal, distributed locks) + open the
 * client ports on VMnet11 (S3 API 9000 + Console 9001).
 *
 * Per memory/feedback_cluster_template_nftables_backplane.md + feedback_nftables_
 * runtime_add_after_drop.md (atomic `nft -f`, not runtime add).
 */

locals {
  minio_all_nodes = {
    "minio-1" = "192.168.70.141"
    "minio-2" = "192.168.70.142"
    "minio-3" = "192.168.70.143"
    "minio-4" = "192.168.70.144"
  }
}

resource "null_resource" "minio_nftables_backplane" {
  count = var.enable_minio_nftables_backplane ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.minio_all_nodes))
    nftables_v   = "1"
    ssh_user     = var.lakehouse_node_user
    boot_timeout = var.lakehouse_cluster_timeout_minutes
  }

  depends_on = [
    module.minio_1, module.minio_2, module.minio_3, module.minio_4,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes       = @{ ${join("; ", [for h, ip in local.minio_all_nodes : "'${h}' = '${ip}'"])} }
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
        iifname "nic0" ip saddr 192.168.70.0/24 tcp dport { 9000, 9001 } accept comment "MinIO S3 API + Console from VMnet11"
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
        Write-Host "[minio-nftables $hostName] waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($bootTimeout)
        $booted = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$sshUser@$ip" "test -f /var/lib/lakehouse-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $booted = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $booted) { throw "[minio-nftables $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

        $apply = @"
set -euo pipefail
echo '$rulesetB64' | base64 -d | sudo tee /etc/nftables.conf > /dev/null
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo NFT_OK
"@
        $out = ($apply -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NFT_OK') { Write-Host $out.Trim(); throw "[minio-nftables $hostName] nft -f failed (rc=$LASTEXITCODE)" }
        Write-Host "[minio-nftables $hostName] ruleset applied"
      }
    PWSH
  }
}
