/*
 * role-overlay-iceberg-tls.tf -- Phase 0.L.2 -- Iceberg catalog TLS cert render
 *
 * Per-host Vault Agent PKI template -> leaf + key (PKCS#8) + ca-chain, with
 * ROLE-SPECIFIC file naming / owner / SANs:
 *   - PG nodes   -> /etc/nexus-iceberg-pg/tls/{server.crt,server.key,ca.crt}
 *     owner postgres; SANs add iceberg-db.nexus.lab + the VRRP VIP IP (.151)
 *     so clients connecting to the catalog-DB front door validate.
 *   - REST nodes -> /etc/nexus-iceberg-rest/tls/{cert.pem,key.pem,ca.crt}
 *     owner nessie; SANs add iceberg.nexus.lab (round-robin) for the Quarkus
 *     HTTPS listener.
 *
 * Port of the MinIO tls overlay (same split-script skeleton + PKCS#8 + SSH-stdin
 * + HCL-heredoc escaping), parameterised per role.
 *
 * Selective ops: var.enable_iceberg_tls AND var.enable_iceberg_vault_agents.
 */

locals {
  iceberg_tls_per_host = {
    "iceberg-pg-1"   = { vmnet10 = "192.168.10.149", vmnet11 = "192.168.70.149", dest_dir = "/etc/nexus-iceberg-pg/tls", group = "postgres", owner = "postgres", cert = "server.crt", key = "server.key", alt = "iceberg-db.nexus.lab", extra_ip = "192.168.70.151" }
    "iceberg-pg-2"   = { vmnet10 = "192.168.10.150", vmnet11 = "192.168.70.150", dest_dir = "/etc/nexus-iceberg-pg/tls", group = "postgres", owner = "postgres", cert = "server.crt", key = "server.key", alt = "iceberg-db.nexus.lab", extra_ip = "192.168.70.151" }
    "iceberg-rest-1" = { vmnet10 = "192.168.10.147", vmnet11 = "192.168.70.147", dest_dir = "/etc/nexus-iceberg-rest/tls", group = "iceberg", owner = "nessie", cert = "cert.pem", key = "key.pem", alt = "iceberg.nexus.lab", extra_ip = "" }
    "iceberg-rest-2" = { vmnet10 = "192.168.10.148", vmnet11 = "192.168.70.148", dest_dir = "/etc/nexus-iceberg-rest/tls", group = "iceberg", owner = "nessie", cert = "cert.pem", key = "key.pem", alt = "iceberg.nexus.lab", extra_ip = "" }
  }

  iceberg_tls_active = {
    for host, spec in local.iceberg_tls_per_host : host => spec
    if(
      var.enable_iceberg_tls && var.enable_iceberg_vault_agents
      && lookup(local.iceberg_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "iceberg_tls" {
  for_each = local.iceberg_tls_active

  triggers = {
    va_id         = null_resource.iceberg_vault_agent[each.key].id
    pki_role_name = var.vault_pki_iceberg_role_name
    dest_dir      = each.value.dest_dir
    iceberg_tls_v = "1"

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.lakehouse_node_user
    destroy_dest_dir = each.value.dest_dir
    destroy_cert     = each.value.cert
    destroy_key      = each.value.key
  }

  depends_on = [null_resource.iceberg_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $vmnet10  = '${each.value.vmnet10}'
      $destDir  = '${each.value.dest_dir}'
      $grp      = '${each.value.group}'
      $own      = '${each.value.owner}'
      $certName = '${each.value.cert}'
      $keyName  = '${each.value.key}'
      $altExtra = '${each.value.alt}'
      $ipExtra  = '${each.value.extra_ip}'
      $pkiRole  = '${var.vault_pki_iceberg_role_name}'
      $sshUser  = '${var.lakehouse_node_user}'
      $cn       = "$hostName.nexus.lab"
      $altNames = "$hostName,$hostName.nexus.lab,$altExtra,localhost"
      $ipSans   = if ($ipExtra) { "$vmnet10,$ip,$ipExtra,127.0.0.1" } else { "$vmnet10,$ip,127.0.0.1" }
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[iceberg-tls $hostName] cert render via Vault Agent PKI template -> $destDir/$certName"

      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: iceberg-tls-split.sh DEST GROUP OWNER CERTNAME KEYNAME}"
GROUP="$${2:?GROUP}"
OWNER="$${3:?OWNER}"
CERTNAME="$${4:?CERTNAME}"
KEYNAME="$${5:?KEYNAME}"
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
  echo "[iceberg-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2; exit 1
fi
openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"
ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
[ -s "$ROOT_BUNDLE" ] || { echo "[iceberg-tls-split] ERROR: $ROOT_BUNDLE missing" >&2; exit 1; }
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca-chain.pem"
cat "$LEAF" "$CA" > "$TMP/leaf-chain.pem"
install -m 0644 -o "$OWNER" -g "$GROUP" "$TMP/leaf-chain.pem" "$DEST/$CERTNAME"
install -m 0600 -o "$OWNER" -g "$GROUP" "$TMP/key-pkcs8.pem"  "$DEST/$KEYNAME"
install -m 0644 -o "$OWNER" -g "$GROUP" "$TMP/ca-chain.pem"   "$DEST/ca.crt"
install -m 0644 -o root -g root "$TMP/ca-chain.pem" /etc/ssl/certs/iceberg-ca.pem
echo "[iceberg-tls-split] $(date -u +%FT%TZ) bundle split -> $DEST/{$CERTNAME,$KEYNAME,ca.crt}"
'@
      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      $vaultAgentTemplate = @"
# 60-template-iceberg-tls.hcl -- Phase 0.L.2 (rendered for $hostName).
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
  group           = "$grp"
  command         = "/usr/local/sbin/iceberg-tls-split.sh $destDir $grp $own $certName $keyName"
  command_timeout = "30s"
}
"@
      $vaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultAgentTemplate -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
if ! getent group $grp >/dev/null; then sudo groupadd --system $grp; fi
if ! getent passwd $own >/dev/null; then sudo useradd --system --gid $grp --no-create-home --shell /usr/sbin/nologin $own; fi
sudo mkdir -p "$destDir"
sudo chown root:$grp "$destDir"
sudo chmod 0750 "$destDir"
echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/iceberg-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/iceberg-tls-split.sh
sudo chmod 0755 /usr/local/sbin/iceberg-tls-split.sh
echo '$vaB64' | base64 -d | sudo tee /etc/vault-agent/60-template-iceberg-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/60-template-iceberg-tls.hcl
sudo chmod 0644 /etc/vault-agent/60-template-iceberg-tls.hcl
sudo systemctl restart nexus-vault-agent.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo test -s "$destDir/bundle.pem" && break
  sleep 2
done
if ! sudo test -s "$destDir/bundle.pem"; then
  echo "[iceberg-tls stage] ERROR: bundle.pem not rendered within 20s" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
sudo /usr/local/sbin/iceberg-tls-split.sh "$destDir" "$grp" "$own" "$certName" "$keyName"
echo STAGE_OK
"@
      $stageOut = ($stage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') { Write-Host $stageOut.Trim(); throw "[iceberg-tls $hostName] cert render stage failed (rc=$LASTEXITCODE)" }

      $deadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $deadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $destDir/$certName && sudo openssl x509 -in $destDir/$certName -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) { throw "[iceberg-tls $hostName] cert files not rendered (CN=$cn) within 60s" }
      Write-Host "[iceberg-tls $hostName] cert rendered (CN=$cn) in $destDir"
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
      $certName = '${self.triggers.destroy_cert}'
      $keyName  = '${self.triggers.destroy_key}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/60-template-iceberg-tls.hcl $destDir/bundle.pem $destDir/$certName $destDir/$keyName $destDir/ca.crt /etc/ssl/certs/iceberg-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
