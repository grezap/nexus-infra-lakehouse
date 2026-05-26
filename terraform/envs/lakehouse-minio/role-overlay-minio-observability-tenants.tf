/*
 * role-overlay-minio-observability-tenants.tf -- Phase 0.I.2 + 0.I.3 (ADR-0038)
 *
 * Provisions the dedicated MinIO tenants for Loki + Tempo (the obs tier's
 * durable backends per ADR-0038). Mirrors the SR shared-data tenant pattern
 * (ADR-0037 / role-overlay-minio-starrocks-tenant.tf):
 *   - bucket `loki` + service account `nexus-loki-app` + policy `loki-tenant`
 *   - bucket `tempo` + service account `nexus-tempo-app` + policy `tempo-tenant`
 *
 * Each policy is `s3:*` scoped to its OWN bucket only (cross-bucket-deny
 * proven inline) -- not the global `readwrite` policy reused by Harbor for
 * lakehouse-app. Both Loki + Tempo write metadata + chunks to their bucket
 * via the S3 storage_config block (Loki) / s3 backend (Tempo).
 *
 * Selective ops: var.enable_minio_obs_tenants.
 */

resource "null_resource" "minio_obs_tenants" {
  count = var.enable_minio_obs_tenants ? 1 : 0

  triggers = {
    bootstrap_id = length(null_resource.minio_bucket_bootstrap) > 0 ? null_resource.minio_bucket_bootstrap[0].id : "disabled"
    loki_bucket  = var.minio_loki_bucket
    tempo_bucket = var.minio_tempo_bucket
    loki_policy  = var.minio_loki_policy_name
    tempo_policy = var.minio_tempo_policy_name
    obs_tenant_v = "1"
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
      $kvLokiAk    = '${var.kv_loki_s3_access_key_path}'
      $kvLokiSk    = '${var.kv_loki_s3_secret_key_path}'
      $kvTempoAk   = '${var.kv_tempo_s3_access_key_path}'
      $kvTempoSk   = '${var.kv_tempo_s3_secret_key_path}'
      $lokiBucket  = '${var.minio_loki_bucket}'
      $tempoBucket = '${var.minio_tempo_bucket}'
      $lokiPolicy  = '${var.minio_loki_policy_name}'
      $tempoPolicy = '${var.minio_tempo_policy_name}'
      $sshOpts     = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $tenant = @"
set -euo pipefail
VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_ADDR
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
RU=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootUser)
RP=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRootPass)
LOKI_AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvLokiAk)
LOKI_SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvLokiSk)
TEMPO_AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvTempoAk)
TEMPO_SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvTempoSk)
[ -n "`$RU" ] && [ -n "`$RP" ] && [ -n "`$LOKI_AK" ] && [ -n "`$LOKI_SK" ] && [ -n "`$TEMPO_AK" ] && [ -n "`$TEMPO_SK" ] || { echo "ERROR: empty MinIO/obs creds from Vault KV" >&2; exit 1; }

if ! sudo mc admin info nexuslocal >/dev/null 2>&1; then
  sudo install -d -m 0700 /root/.mc/certs/CAs
  sudo cp /etc/ssl/certs/minio-ca.pem /root/.mc/certs/CAs/nexus-ca.crt
  sudo mc alias set nexuslocal https://localhost:9000 "`$RU" "`$RP" >/dev/null
fi

provision_tenant() {
  local BUCKET="`$1"; local POLICY="`$2"; local AK="`$3"; local SK="`$4"; local LABEL="`$5"
  # 1. Bucket (idempotent)
  sudo mc mb --ignore-existing "nexuslocal/`$BUCKET"
  echo "[obs-tenant `$LABEL] bucket ready: `$BUCKET"

  # 2. Scoped policy (s3:* on `$BUCKET only)
  local POLICY_TMP
  POLICY_TMP=`$(mktemp)
  cat > "`$POLICY_TMP" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::`$BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::`$BUCKET/*"]
    }
  ]
}
JSON
  sudo mc admin policy create nexuslocal "`$POLICY" "`$POLICY_TMP" 2>/dev/null || sudo mc admin policy update nexuslocal "`$POLICY" "`$POLICY_TMP"
  rm -f "`$POLICY_TMP"
  echo "[obs-tenant `$LABEL] policy provisioned: `$POLICY (scoped to s3://`$BUCKET/*)"

  # 3. Service account
  if sudo mc admin user info nexuslocal "`$AK" >/dev/null 2>&1; then
    echo "[obs-tenant `$LABEL] service account already exists: `$AK"
  else
    sudo mc admin user add nexuslocal "`$AK" "`$SK"
    echo "[obs-tenant `$LABEL] created service account: `$AK"
  fi
  sudo mc admin policy attach nexuslocal "`$POLICY" --user "`$AK" 2>/dev/null || true

  # 4. Proof: write/read to OWN bucket succeeds
  local ALIAS_TMP="obs-`$LABEL-test-`$RANDOM"
  sudo mc alias set "`$ALIAS_TMP" https://localhost:9000 "`$AK" "`$SK" >/dev/null
  local T
  T=`$(mktemp)
  echo "nexus-obs-`$LABEL-probe" > "`$T"
  sudo mc cp "`$T" "`$ALIAS_TMP/`$BUCKET/.obs-probe" >/dev/null
  sudo mc cat "`$ALIAS_TMP/`$BUCKET/.obs-probe" | grep -q "nexus-obs-`$LABEL-probe" || { echo "ERROR: obs tenant `$LABEL write/read failed" >&2; exit 1; }
  sudo mc rm "`$ALIAS_TMP/`$BUCKET/.obs-probe" >/dev/null

  # 5. Proof: cross-bucket write to warehouse DENIED
  if sudo mc cp "`$T" "`$ALIAS_TMP/warehouse/.obs-cross-probe" >/dev/null 2>&1; then
    sudo mc rm "`$ALIAS_TMP/warehouse/.obs-cross-probe" >/dev/null 2>&1 || true
    echo "ERROR: obs tenant `$LABEL must NOT have write access to s3://warehouse (policy too broad)" >&2
    sudo mc alias remove "`$ALIAS_TMP" >/dev/null 2>&1 || true
    exit 1
  fi
  echo "[obs-tenant `$LABEL] confirmed: `$POLICY denies cross-bucket writes (s3://warehouse)"
  sudo mc alias remove "`$ALIAS_TMP" >/dev/null 2>&1 || true
  rm -f "`$T"
}

provision_tenant "$lokiBucket"  "$lokiPolicy"  "`$LOKI_AK"  "`$LOKI_SK"  loki
provision_tenant "$tempoBucket" "$tempoPolicy" "`$TEMPO_AK" "`$TEMPO_SK" tempo

echo OBS_TENANTS_OK
"@
      $out = ($tenant -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'OBS_TENANTS_OK') { throw "[obs-tenants] provisioning failed (rc=$LASTEXITCODE)" }
      Write-Host "[obs-tenants] Loki + Tempo MinIO tenants provisioned (buckets + scoped policies + service accounts)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      Write-Host "[obs-tenants destroy] best-effort -- leaves buckets + users + policies alone (data preservation)."
      exit 0
    PWSH
  }
}
