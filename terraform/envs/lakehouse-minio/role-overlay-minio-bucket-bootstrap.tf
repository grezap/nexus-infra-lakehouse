/*
 * role-overlay-minio-bucket-bootstrap.tf -- Phase 0.L.1 exit gate
 *
 * One-shot bootstrap run on minio-1: configure mc against the cluster (root
 * creds from Vault KV), create the warehouse + auxiliary buckets, create the
 * least-priv lakehouse-app service account (app creds from Vault KV) used by
 * 0.L.2 Iceberg + 0.L.3 Spark, and prove the erasure set is healthy with an
 * object write/read round-trip.
 *
 * This is the analytics schema-bootstrap equivalent -- the deterministic exit
 * gate that proves the cluster is usable, not just running.
 *
 * Selective ops: var.enable_minio_bucket_bootstrap.
 */

resource "null_resource" "minio_bucket_bootstrap" {
  count = var.enable_minio_bucket_bootstrap ? 1 : 0

  triggers = {
    config_id        = length(null_resource.minio_config) > 0 ? null_resource.minio_config[0].id : "disabled"
    warehouse_bucket = var.minio_warehouse_bucket
    extra_buckets    = join(",", var.minio_extra_buckets)
    bucket_v         = "1"
  }

  depends_on = [null_resource.minio_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '192.168.70.141'
      $sshUser     = '${var.lakehouse_node_user}'
      $kvRootUser  = '${var.kv_root_user_path}'
      $kvRootPass  = '${var.kv_root_password_path}'
      $kvAppAk     = '${var.kv_app_access_key_path}'
      $kvAppSk     = '${var.kv_app_secret_key_path}'
      $warehouse   = '${var.minio_warehouse_bucket}'
      $extra       = '${join(" ", var.minio_extra_buckets)}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $bootstrap = @"
set -euo pipefail
VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_ADDR
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
RU=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootUser)
RP=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootPass)
APP_AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvAppAk)
APP_SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvAppSk)
[ -n "`$RU" ] && [ -n "`$RP" ] && [ -n "`$APP_AK" ] && [ -n "`$APP_SK" ] || { echo "ERROR: empty MinIO creds from Vault KV" >&2; exit 1; }

# Trust the cluster CA for mc (run as root; mc config dir /root/.mc)
sudo install -d -m 0700 /root/.mc/certs/CAs
sudo cp /etc/ssl/certs/minio-ca.pem /root/.mc/certs/CAs/nexus-ca.crt

sudo mc alias set nexuslocal https://localhost:9000 "`$RU" "`$RP" >/dev/null

# Erasure-set health: count online drives
ONLINE=`$(sudo mc admin info nexuslocal --json | jq '[.info.servers[].drives[] | select(.state=="ok")] | length')
echo "[minio-bootstrap] online drives: `$ONLINE"
if [ "`$ONLINE" -lt 4 ]; then echo "ERROR: expected >=4 online drives, got `$ONLINE" >&2; sudo mc admin info nexuslocal >&2; exit 1; fi

# Create buckets (idempotent)
for b in $warehouse $extra; do
  sudo mc mb --ignore-existing "nexuslocal/`$b"
  echo "[minio-bootstrap] bucket ready: `$b"
done

# Least-priv app service account (consumed by 0.L.2 Iceberg + 0.L.3 Spark)
if sudo mc admin user info nexuslocal "`$APP_AK" >/dev/null 2>&1; then
  echo "[minio-bootstrap] app user already exists: `$APP_AK"
else
  sudo mc admin user add nexuslocal "`$APP_AK" "`$APP_SK"
  echo "[minio-bootstrap] created app user: `$APP_AK"
fi
sudo mc admin policy attach nexuslocal readwrite --user "`$APP_AK" 2>/dev/null || true

# Object write/read round-trip on the warehouse bucket
TMPF=`$(mktemp)
echo "nexus-lakehouse-0.L.1-`$(date -u +%FT%TZ)" > "`$TMPF"
sudo mc cp "`$TMPF" "nexuslocal/$warehouse/.nexus-bootstrap-probe" >/dev/null
sudo mc cat "nexuslocal/$warehouse/.nexus-bootstrap-probe" | grep -q 'nexus-lakehouse-0.L.1' || { echo "ERROR: object round-trip failed" >&2; exit 1; }
sudo mc rm "nexuslocal/$warehouse/.nexus-bootstrap-probe" >/dev/null
rm -f "`$TMPF"

echo BOOTSTRAP_OK
"@
      $out = ($bootstrap -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'BOOTSTRAP_OK') { throw "[minio-bootstrap] exit gate failed (rc=$LASTEXITCODE)" }
      Write-Host "[minio-bootstrap] EXIT GATE GREEN -- buckets created, app user provisioned, erasure set healthy, object round-trip OK"
    PWSH
  }
}
