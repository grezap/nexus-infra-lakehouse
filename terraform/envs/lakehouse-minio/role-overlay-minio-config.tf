/*
 * role-overlay-minio-config.tf -- Phase 0.L.1
 *
 * Renders /etc/nexus-minio/minio.conf on all 4 nodes (each node reads its own
 * MINIO_ROOT_USER/PASSWORD from Vault KV via its local vault-agent token -- the
 * secret never transits the build host), then enables + starts nexus-minio on
 * all 4 together so they form the distributed erasure set. Waits for cluster
 * health (quorum) before returning.
 *
 * MINIO_VOLUMES uses the VMnet10 backplane IPs (https://192.168.10.{141..144})
 * so inter-node erasure/heal/lock traffic stays on the isolated backplane; the
 * client S3 endpoint (minio.nexus.lab, round-robin VMnet11) and console
 * (minio-N.nexus.lab:9001) ride VMnet11. The per-host cert SANs cover both.
 *
 * Selective ops: var.enable_minio_config.
 */

resource "null_resource" "minio_config" {
  count = var.enable_minio_config ? 1 : 0

  triggers = {
    node_ips     = join(",", values(local.minio_all_nodes))
    tls_ids      = join(",", [for h, r in null_resource.minio_tls : r.id])
    kv_root_user = var.kv_root_user_path
    kv_root_pass = var.kv_root_password_path
    minio_cfg_v  = "1"
    ssh_user     = var.lakehouse_node_user
  }

  depends_on = [null_resource.minio_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes        = @{ ${join("; ", [for h, ip in local.minio_all_nodes : "'${h}' = '${ip}'"])} }
      $sshUser      = '${var.lakehouse_node_user}'
      $kvRootUser   = '${var.kv_root_user_path}'
      $kvRootPass   = '${var.kv_root_password_path}'
      $vmrunPath    = '${var.vmrun_path}'
      $vmOutRoot    = '${var.vm_output_dir_root}'
      $sshOpts      = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # ── 0. Ensure the VMnet10 backplane NIC (ethernet1) is connected ─────
      # VMware sporadically leaves ethernet1 NO-CARRIER at power-on despite
      # startConnected=TRUE (handbook §3 transient #1; also seen on the analytics
      # tier). MinIO identifies its local host in the distributed grid by matching
      # a MINIO_VOLUMES backplane IP to a local interface, so the backplane MUST
      # be up before MinIO starts. Connect ethernet1 (idempotent), nudge
      # networkd, and wait for the backplane IP on every node.
      foreach ($entry in $nodes.GetEnumerator()) {
        $vmx = Join-Path $vmOutRoot ("08-spark\{0}\{0}.vmx" -f $entry.Key)
        & $vmrunPath connectNamedDevice $vmx ethernet1 2>&1 | Out-Null
      }
      Start-Sleep -Seconds 3
      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key; $ip = $entry.Value
        $bp = $ip -replace '192\.168\.70', '192.168.10'
        ssh @sshOpts "$sshUser@$ip" 'sudo systemctl restart systemd-networkd' 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(2)
        $up = $false
        while ((Get-Date) -lt $deadline) {
          $has = (ssh @sshOpts "$sshUser@$ip" "ip -4 -o addr show nic1 2>/dev/null | grep -c '$bp'" 2>&1 | Out-String).Trim()
          if ($has -match '(?m)^[1-9]') { $up = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $up) { throw "[minio-config $hostName] backplane nic1 never came up with $bp after connectNamedDevice (2 min)" }
        Write-Host "[minio-config $hostName] backplane nic1 = $bp (connected)"
      }

      # ── 1. Render /etc/nexus-minio/minio.conf on every node ──────────────
      $renderTmpl = @"
set -euo pipefail
VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_ADDR
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
RU=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootUser)
RP=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootPass)
if [ -z "`$RU" ] || [ -z "`$RP" ]; then echo "ERROR: empty MinIO root creds from Vault KV" >&2; exit 1; fi
sudo tee /etc/nexus-minio/minio.conf > /dev/null <<EOF
# Rendered by role-overlay-minio-config.tf -- do not edit by hand.
MINIO_VOLUMES="https://192.168.10.{141...144}:9000/mnt/minio/data"
MINIO_OPTS="--address :9000 --console-address :9001 --certs-dir /etc/nexus-minio/certs"
MINIO_ROOT_USER=`$RU
MINIO_ROOT_PASSWORD=`$RP
MINIO_SERVER_URL=https://minio.nexus.lab:9000
MINIO_PROMETHEUS_AUTH_TYPE=public
EOF
sudo chown root:minio /etc/nexus-minio/minio.conf
sudo chmod 0640 /etc/nexus-minio/minio.conf
sudo systemctl daemon-reload
sudo systemctl enable nexus-minio.service >/dev/null 2>&1 || true
echo CONFIG_OK
"@
      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key; $ip = $entry.Value
        Write-Host "[minio-config $hostName] rendering minio.conf from Vault KV"
        $out = ($renderTmpl -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'CONFIG_OK') { Write-Host $out.Trim(); throw "[minio-config $hostName] config render failed (rc=$LASTEXITCODE)" }
      }

      # ── 2. Start nexus-minio on every node (peers wait for each other) ───
      foreach ($entry in $nodes.GetEnumerator()) {
        $hostName = $entry.Key; $ip = $entry.Value
        Write-Host "[minio-config $hostName] starting nexus-minio.service"
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl start nexus-minio.service" 2>&1 | Out-Null
      }

      # ── 3. Wait for distributed cluster health (quorum) ──────────────────
      $deadline = (Get-Date).AddMinutes(5)
      $healthy = $false
      while ((Get-Date) -lt $deadline) {
        $h = (ssh @sshOpts "$sshUser@192.168.70.141" "curl -fsS -k -o /dev/null -w '%%{http_code}' https://localhost:9000/minio/health/cluster 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($h -match '200') { $healthy = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $healthy) {
        $j = (ssh @sshOpts "$sshUser@192.168.70.141" "sudo journalctl -u nexus-minio.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $j
        throw "[minio-config] cluster health endpoint never returned 200 within 5 min"
      }
      Write-Host "[minio-config] distributed MinIO cluster healthy (quorum reached)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $nodes   = @('192.168.70.141','192.168.70.142','192.168.70.143','192.168.70.144')
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in $nodes) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-minio.service 2>/dev/null; sudo rm -f /etc/nexus-minio/minio.conf" 2>$null
      }
      exit 0
    PWSH
  }
}
