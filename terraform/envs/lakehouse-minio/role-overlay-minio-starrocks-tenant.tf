/*
 * role-overlay-minio-starrocks-tenant.tf -- Phase 0.L.5 (ADR-0037)
 *
 * Provisions the dedicated MinIO tenant for the StarRocks shared-data cluster:
 *   - bucket `starrocks` (where the storage volume's cloud-native internal
 *     tables physically live; addressed as s3://starrocks/<volume-tree>)
 *   - MinIO service account `nexus-starrocks-app` (access/secret keys
 *     sticky-seeded in Vault KV by nexus-infra-vmware's security env
 *     role-overlay-vault-starrocks-sd-creds-seed.tf, field `value`)
 *   - MinIO policy `starrocks-tenant`: s3:* scoped to arn:aws:s3:::starrocks/*
 *     + bucket listing; attached to the nexus-starrocks-app user. NOT the
 *     global `readwrite` policy reused by Harbor for the lakehouse-app key
 *     -- this is the tighter least-privilege identity Greg chose for 0.L.5
 *     (see ADR-0037 § "Three either/or decisions").
 *
 * Runs on minio-1 (as the existing bucket-bootstrap does), reading root creds
 * + the SR S3 access/secret from Vault KV via the per-host Vault Agent token.
 *
 * Selective ops: var.enable_minio_starrocks_tenant.
 */

resource "null_resource" "minio_starrocks_tenant" {
  count = var.enable_minio_starrocks_tenant ? 1 : 0

  triggers = {
    bootstrap_id = length(null_resource.minio_bucket_bootstrap) > 0 ? null_resource.minio_bucket_bootstrap[0].id : "disabled"
    sr_bucket    = var.minio_starrocks_bucket
    sr_policy    = var.minio_starrocks_policy_name
    sr_tenant_v  = "1"
  }

  depends_on = [null_resource.minio_bucket_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '192.168.70.141'
      $sshUser     = '${var.lakehouse_node_user}'
      $kvRootUser  = '${var.kv_root_user_path}'
      $kvRootPass  = '${var.kv_root_password_path}'
      $kvSrAk      = '${var.kv_starrocks_s3_access_key_path}'
      $kvSrSk      = '${var.kv_starrocks_s3_secret_key_path}'
      $srBucket    = '${var.minio_starrocks_bucket}'
      $srPolicy    = '${var.minio_starrocks_policy_name}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $tenant = @"
set -euo pipefail
VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_ADDR
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
RU=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootUser)
RP=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootPass)
SR_AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvSrAk)
SR_SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvSrSk)
[ -n "`$RU" ] && [ -n "`$RP" ] && [ -n "`$SR_AK" ] && [ -n "`$SR_SK" ] || { echo "ERROR: empty MinIO/SR creds from Vault KV" >&2; exit 1; }

# Reuse the bucket-bootstrap mc alias (already configured on minio-1).
if ! sudo mc admin info nexuslocal >/dev/null 2>&1; then
  sudo install -d -m 0700 /root/.mc/certs/CAs
  sudo cp /etc/ssl/certs/minio-ca.pem /root/.mc/certs/CAs/nexus-ca.crt
  sudo mc alias set nexuslocal https://localhost:9000 "`$RU" "`$RP" >/dev/null
fi

# 1. The starrocks bucket (idempotent).
sudo mc mb --ignore-existing "nexuslocal/$srBucket"
echo "[sr-tenant] bucket ready: $srBucket"

# 2. The scoped MinIO policy (idempotent).
POLICY_TMP=`$(mktemp)
cat > "`$POLICY_TMP" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::$srBucket"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::$srBucket/*"]
    }
  ]
}
JSON
sudo mc admin policy create nexuslocal $srPolicy "`$POLICY_TMP" 2>/dev/null || sudo mc admin policy update nexuslocal $srPolicy "`$POLICY_TMP"
rm -f "`$POLICY_TMP"
echo "[sr-tenant] policy provisioned: $srPolicy (scoped to s3://$srBucket/*)"

# 3. The service account (idempotent).
if sudo mc admin user info nexuslocal "`$SR_AK" >/dev/null 2>&1; then
  echo "[sr-tenant] service account already exists: `$SR_AK"
else
  sudo mc admin user add nexuslocal "`$SR_AK" "`$SR_SK"
  echo "[sr-tenant] created service account: `$SR_AK"
fi
sudo mc admin policy attach nexuslocal $srPolicy --user "`$SR_AK" 2>/dev/null || true

# 4. Sanity-check: the new identity can write to its bucket but NOT to the
# warehouse bucket (negative proof of the scoping).
SR_ALIAS_TMP=sr-tenant-test-`$RANDOM
sudo mc alias set "`$SR_ALIAS_TMP" https://localhost:9000 "`$SR_AK" "`$SR_SK" >/dev/null
T=`$(mktemp)
echo "nexus-sr-tenant-probe" > "`$T"
sudo mc cp "`$T" "`$SR_ALIAS_TMP/$srBucket/.sr-tenant-probe" >/dev/null
sudo mc cat "`$SR_ALIAS_TMP/$srBucket/.sr-tenant-probe" | grep -q 'nexus-sr-tenant-probe' || { echo "ERROR: SR tenant write/read failed" >&2; exit 1; }
sudo mc rm "`$SR_ALIAS_TMP/$srBucket/.sr-tenant-probe" >/dev/null

if sudo mc cp "`$T" "`$SR_ALIAS_TMP/warehouse/.sr-tenant-cross-probe" >/dev/null 2>&1; then
  sudo mc rm "`$SR_ALIAS_TMP/warehouse/.sr-tenant-cross-probe" >/dev/null 2>&1 || true
  echo "ERROR: SR tenant identity must NOT have write access to s3://warehouse (policy too broad)" >&2
  sudo mc alias remove "`$SR_ALIAS_TMP" >/dev/null 2>&1 || true
  exit 1
fi
echo "[sr-tenant] confirmed: $srPolicy denies cross-bucket writes (s3://warehouse)"
sudo mc alias remove "`$SR_ALIAS_TMP" >/dev/null 2>&1 || true
rm -f "`$T"

echo SR_TENANT_OK
"@
      $out = ($tenant -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'SR_TENANT_OK') { throw "[sr-tenant] tenant bootstrap failed (rc=$LASTEXITCODE)" }
      Write-Host "[sr-tenant] StarRocks shared-data tenant provisioned -- bucket=$srBucket, identity=nexus-starrocks-app, policy=$srPolicy"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      Write-Host "[sr-tenant destroy] best-effort -- leaves the bucket + user + policy alone (data preservation)."
      exit 0
    PWSH
  }
}
