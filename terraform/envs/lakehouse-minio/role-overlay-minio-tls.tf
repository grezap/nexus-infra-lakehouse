/*
 * role-overlay-minio-tls.tf -- Phase 0.L.1 -- MinIO TLS cert render
 *
 * Per-host Vault Agent PKI template -> public.crt + private.key (PKCS#8) +
 * CAs/nexus-ca.crt in each node's MinIO certs dir (/etc/nexus-minio/certs).
 *
 * Port of the StarRocks tls overlay (same split-script skeleton + PKCS#8 +
 * ca-chain + SSH-stdin + HCL-heredoc escaping), with the MinIO file layout:
 *   - public.crt  = leaf + intermediate (Go crypto/tls default server cert)
 *   - private.key = PKCS#8 key
 *   - CAs/nexus-ca.crt = full CA chain (so each node TRUSTS its 3 peers in
 *     distributed mode -- peers connect over https://192.168.10.{141..144}:9000).
 * Each cert SAN covers minio-N + minio-N.nexus.lab + the round-robin
 * minio.nexus.lab (ADR-0031/0033) + IP SANs for both the VMnet11 service IP and
 * the VMnet10 backplane IP (peer traffic validates against the backplane IP).
 *
 * Selective ops: var.enable_minio_tls AND var.enable_minio_vault_agents.
 */

locals {
  minio_tls_per_host = {
    "minio-1" = { vmnet10 = "192.168.10.141", vmnet11 = "192.168.70.141", dest_dir = "/etc/nexus-minio/certs" }
    "minio-2" = { vmnet10 = "192.168.10.142", vmnet11 = "192.168.70.142", dest_dir = "/etc/nexus-minio/certs" }
    "minio-3" = { vmnet10 = "192.168.10.143", vmnet11 = "192.168.70.143", dest_dir = "/etc/nexus-minio/certs" }
    "minio-4" = { vmnet10 = "192.168.10.144", vmnet11 = "192.168.70.144", dest_dir = "/etc/nexus-minio/certs" }
  }

  minio_tls_active = {
    for host, spec in local.minio_tls_per_host : host => spec
    if(
      var.enable_minio_tls && var.enable_minio_vault_agents
      && lookup(local.minio_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "minio_tls" {
  for_each = local.minio_tls_active

  triggers = {
    va_id         = null_resource.minio_vault_agent[each.key].id
    pki_role_name = var.vault_pki_minio_role_name
    dest_dir      = each.value.dest_dir
    minio_tls_v   = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.lakehouse_node_user
    destroy_dest_dir = each.value.dest_dir
  }

  depends_on = [null_resource.minio_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $destDir  = '${each.value.dest_dir}'
      $pkiRole  = '${var.vault_pki_minio_role_name}'
      $sshUser  = '${var.lakehouse_node_user}'
      $cn       = "$hostName.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,minio.nexus.lab,localhost"
      $ipSans   = "$vmnet10,$ip,127.0.0.1"
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[minio-tls $hostName] cert render via Vault Agent PKI template -> $destDir"

      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: minio-tls-split.sh DEST_DIR GROUP}"
GROUP="$${2:?usage: minio-tls-split.sh DEST_DIR GROUP}"
BUNDLE="$DEST/bundle.pem"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"
LEAF=""; KEY=""; CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*) KEY=$f ;;
    *"BEGIN CERTIFICATE"*) if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi ;;
  esac
done
if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[minio-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "$ROOT_BUNDLE" ] || { echo "[minio-tls-split] ERROR: $ROOT_BUNDLE missing" >&2; exit 1; }
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"
cat "$LEAF" "$CA" > "$TMP/public.crt"
install -d -m 0750 -o minio -g "$GROUP" "$DEST/CAs"
install -m 0644 -o minio -g "$GROUP" "$TMP/public.crt"    "$DEST/public.crt"
install -m 0600 -o minio -g "$GROUP" "$TMP/key-pkcs8.pem" "$DEST/private.key"
install -m 0644 -o minio -g "$GROUP" "$TMP/ca-chain.pem"  "$DEST/CAs/nexus-ca.crt"
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/minio-ca.pem
echo "[minio-tls-split] $(date -u +%FT%TZ) bundle split -> $DEST/{public.crt,private.key,CAs/nexus-ca.crt}"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-minio-tls.hcl -- Phase 0.L.1 (rendered for $hostName).
template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT
  destination     = "$destDir/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "minio"
  command         = "/usr/local/sbin/minio-tls-split.sh $destDir minio"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
if ! getent group minio >/dev/null; then sudo groupadd --system minio; fi
if ! getent passwd minio >/dev/null; then sudo useradd --system --gid minio --no-create-home --shell /usr/sbin/nologin minio; fi
sudo mkdir -p "$destDir/CAs"
sudo chown root:minio "$destDir"
sudo chmod 0750 "$destDir"
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/minio-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/minio-tls-split.sh
sudo chmod 0755 /usr/local/sbin/minio-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-minio-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-minio-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-minio-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s "$destDir/bundle.pem" && break
  sleep 2
done
if ! sudo test -s "$destDir/bundle.pem"; then
  echo "[minio-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/minio-tls-split.sh "$destDir" minio
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[minio-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $destDir/public.crt && sudo openssl x509 -in $destDir/public.crt -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[minio-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      Write-Host "[minio-tls $hostName] cert rendered (CN=$cn) in $destDir"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $destDir  = '${self.triggers.destroy_dest_dir}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-minio-tls.hcl $destDir/bundle.pem $destDir/public.crt $destDir/private.key $destDir/CAs/nexus-ca.crt /etc/ssl/certs/minio-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
