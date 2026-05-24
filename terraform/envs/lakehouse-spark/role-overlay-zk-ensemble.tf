/*
 * role-overlay-zk-ensemble.tf -- Phase 0.L.3
 *
 * Forms the 3-node Apache ZooKeeper ensemble that coordinates Spark master HA
 * (recoveryMode=ZOOKEEPER). For each ZK node:
 *   0. connect ethernet1 backplane (NO-CARRIER auto-fix; the ensemble rides VMnet10).
 *   1. render /etc/nexus-zookeeper/zoo.cfg (server.1/2/3 on the backplane IPs) +
 *      /var/lib/zookeeper/myid (from NEXUS_ZK_ID emitted by firstboot).
 *   2. enable + start nexus-zookeeper.service.
 * Then verify the ensemble elected exactly 1 leader + 2 followers.
 *
 * ZooKeeper is backplane-only (client 2181 + quorum 2888/3888 on VMnet10),
 * plaintext -- network segmentation is the coordination-layer security boundary
 * (ADR-0035). It is the platform's one deliberate Apache-ZK exception.
 *
 * Selective ops: var.enable_zk_ensemble.
 */

resource "null_resource" "zk_ensemble" {
  count = var.enable_zk_ensemble ? 1 : 0

  triggers = {
    nftables_id = length(null_resource.spark_nftables_backplane) > 0 ? null_resource.spark_nftables_backplane[0].id : "disabled"
    zk_bp_ips   = join(",", var.zookeeper_backplane_ips)
    zk_cfg_v    = "1"
    ssh_user    = var.lakehouse_node_user
  }

  depends_on = [null_resource.spark_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.lakehouse_node_user}'
      $vmrunPath = '${var.vmrun_path}'
      $vmOutRoot = '${var.vm_output_dir_root}'
      $zkClient  = ${var.zookeeper_client_port}
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      # host -> @{ ip (VMnet11); bp (VMnet10 backplane) }
      $zk = @(
        @{ h='zookeeper-1'; ip='192.168.70.155'; bp='192.168.10.155' },
        @{ h='zookeeper-2'; ip='192.168.70.156'; bp='192.168.10.156' },
        @{ h='zookeeper-3'; ip='192.168.70.157'; bp='192.168.10.157' }
      )

      # zoo.cfg is identical on all 3 (server.N entries use the backplane IPs).
      $zooCfg = @"
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/var/lib/zookeeper
clientPort=$zkClient
maxClientCnxns=60
admin.enableServer=false
4lw.commands.whitelist=ruok,srvr,stat,mntr,conf,isro
autopurge.snapRetainCount=3
autopurge.purgeInterval=24
server.1=192.168.10.155:2888:3888
server.2=192.168.10.156:2888:3888
server.3=192.168.10.157:2888:3888
"@
      $zooCfgB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($zooCfg -replace "`r`n","`n")))

      # ── 0. Connect the VMnet10 backplane on all 3 (NO-CARRIER auto-fix) ──
      foreach ($n in $zk) {
        $vmx = Join-Path $vmOutRoot ("08-spark\{0}\{0}.vmx" -f $n.h)
        & $vmrunPath connectNamedDevice $vmx ethernet1 2>&1 | Out-Null
      }
      Start-Sleep -Seconds 3
      foreach ($n in $zk) {
        ssh @sshOpts "$sshUser@$($n.ip)" 'sudo systemctl restart systemd-networkd' 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(2); $up = $false
        while ((Get-Date) -lt $deadline) {
          $has = (ssh @sshOpts "$sshUser@$($n.ip)" "ip -4 -o addr show nic1 2>/dev/null | grep -c '$($n.bp)'" 2>&1 | Out-String).Trim()
          if ($has -match '(?m)^[1-9]') { $up = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $up) { throw "[zk-ensemble] backplane nic1 never came up on $($n.ip)" }
      }
      Write-Host "[zk-ensemble] backplane up on all 3 ZooKeeper nodes"

      # ── 1+2. Render zoo.cfg + myid, enable + start nexus-zookeeper ───────
      foreach ($n in $zk) {
        $cfg = @"
set -euo pipefail
ZKID=`$(sudo grep -oP '^NEXUS_ZK_ID=\K.*' /etc/nexus-zookeeper/node-identity.env)
[ -n "`$ZKID" ] || { echo "ERROR: NEXUS_ZK_ID empty in node-identity.env" >&2; exit 1; }
echo '$zooCfgB64' | base64 -d | sudo tee /etc/nexus-zookeeper/zoo.cfg >/dev/null
sudo chown root:zookeeper /etc/nexus-zookeeper/zoo.cfg
sudo chmod 0640 /etc/nexus-zookeeper/zoo.cfg
echo "`$ZKID" | sudo tee /var/lib/zookeeper/myid >/dev/null
sudo chown zookeeper:zookeeper /var/lib/zookeeper/myid
sudo chmod 0644 /var/lib/zookeeper/myid
sudo systemctl daemon-reload
sudo systemctl enable nexus-zookeeper.service >/dev/null 2>&1 || true
sudo systemctl restart nexus-zookeeper.service
echo "ZK_CFG_OK myid=`$ZKID"
"@
        Write-Host "[zk-ensemble $($n.h)] rendering zoo.cfg + myid + starting"
        $out = ($cfg -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($n.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'ZK_CFG_OK') { Write-Host $out.Trim(); throw "[zk-ensemble $($n.h)] config/start failed (rc=$LASTEXITCODE)" }
        Write-Host ("[zk-ensemble $($n.h)] " + ($out.Trim() -split "`n" | Select-String 'ZK_CFG_OK'))
      }

      # ── 3. Verify quorum: exactly 1 leader + 2 followers (poll; election ~10-20s)
      $deadline = (Get-Date).AddMinutes(3)
      $ok = $false
      while ((Get-Date) -lt $deadline) {
        $leaders = 0; $followers = 0
        foreach ($n in $zk) {
          $mode = (ssh @sshOpts "$sshUser@$($n.ip)" "sudo JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ZOOCFGDIR=/etc/nexus-zookeeper /opt/zookeeper/bin/zkServer.sh status /etc/nexus-zookeeper/zoo.cfg 2>/dev/null | grep -i Mode" 2>&1 | Out-String).Trim()
          if ($mode -match '(?i)leader')   { $leaders++ }
          if ($mode -match '(?i)follower') { $followers++ }
        }
        if ($leaders -eq 1 -and $followers -eq 2) { $ok = $true; break }
        Start-Sleep -Seconds 8
      }
      if (-not $ok) {
        foreach ($n in $zk) {
          $j = (ssh @sshOpts "$sshUser@$($n.ip)" "sudo journalctl -u nexus-zookeeper.service --no-pager -n 15" 2>&1 | Out-String)
          Write-Host "--- $($n.h) zk journal ---`n$j"
        }
        throw "[zk-ensemble] ensemble never reached 1 leader + 2 followers within 3 min"
      }
      Write-Host "[zk-ensemble] quorum healthy -- 1 leader + 2 followers"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.155','192.168.70.156','192.168.70.157')) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-zookeeper.service 2>/dev/null; sudo rm -f /etc/nexus-zookeeper/zoo.cfg /var/lib/zookeeper/myid" 2>$null
      }
      exit 0
    PWSH
  }
}
