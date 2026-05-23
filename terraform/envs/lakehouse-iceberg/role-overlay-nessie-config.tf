/*
 * role-overlay-nessie-config.tf -- Phase 0.L.2
 *
 * Configures + starts Project Nessie on both REST nodes:
 *   - import the Vault CA into the JVM truststore so Nessie's S3 client trusts
 *     minio.nexus.lab (the AWS SDK validates TLS).
 *   - render /etc/nexus-iceberg-rest/nessie.env: Quarkus HTTPS on :19120 (per-host
 *     PKI cert), version store = JDBC (Postgres via the iceberg-db VIP), Iceberg
 *     REST catalog warehouse = s3://warehouse on MinIO (nexus-lakehouse-app key).
 *   - enable + start nexus-nessie.service + wait for health.
 *
 * All creds read on-node via the local Vault Agent token; never transit the host.
 *
 * Selective ops: var.enable_nessie_config.
 */

resource "null_resource" "nessie_config" {
  count = var.enable_nessie_config ? 1 : 0

  triggers = {
    pg_repl_id  = length(null_resource.iceberg_pg_replication) > 0 ? null_resource.iceberg_pg_replication[0].id : "disabled"
    tls_rest    = join(",", [for k, r in null_resource.iceberg_tls : r.id if can(regex("iceberg-rest", k))])
    nessie_cfg_v = "1"
    ssh_user    = var.lakehouse_node_user
  }

  depends_on = [null_resource.iceberg_pg_replication, null_resource.iceberg_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.lakehouse_node_user}'
      $restNodes = @('192.168.70.147','192.168.70.148')
      $kvNessie  = '${var.kv_nessie_db_password_path}'
      $kvS3Ak    = '${var.kv_minio_app_access_key_path}'
      $kvS3Sk    = '${var.kv_minio_app_secret_key_path}'
      $dbName    = '${var.nessie_db_name}'
      $dbUser    = '${var.nessie_db_user}'
      $dbHost    = '${var.iceberg_db_dns_name}'
      $whBucket  = '${var.iceberg_warehouse_bucket}'
      $s3Endpoint = '${var.minio_s3_endpoint}'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $script = @"
set -euo pipefail
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
NESSIEPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvNessie)
S3AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvS3Ak)
S3SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvS3Sk)
[ -n "`$NESSIEPW" ] && [ -n "`$S3AK" ] && [ -n "`$S3SK" ] || { echo "ERROR: empty Nessie/S3 creds from KV" >&2; exit 1; }

# Import the Vault CA into the JVM truststore so Nessie's S3 client trusts MinIO.
sudo keytool -delete -alias nexus-ca -keystore "`$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null || true
sudo keytool -importcert -noprompt -alias nexus-ca -file /etc/vault-agent/ca-bundle.crt -keystore "`$JAVA_HOME/lib/security/cacerts" -storepass changeit

sudo tee /etc/nexus-iceberg-rest/nessie.env >/dev/null <<EOF
# Rendered by role-overlay-nessie-config.tf -- do not edit by hand.
# Quarkus HTTPS-only on :19120
QUARKUS_HTTP_PORT=19120
QUARKUS_HTTP_INSECURE_REQUESTS=disabled
QUARKUS_HTTP_SSL_PORT=19120
QUARKUS_HTTP_SSL_CERTIFICATE_FILES=/etc/nexus-iceberg-rest/tls/cert.pem
QUARKUS_HTTP_SSL_CERTIFICATE_KEY_FILES=/etc/nexus-iceberg-rest/tls/key.pem
# Version store = JDBC2 (PostgreSQL via the iceberg-db VRRP VIP). Nessie selects
# the NAMED `postgresql` datasource (bundled but active=false by default), so it
# must be activated + given the URL/creds (the default datasource stays inert).
NESSIE_VERSION_STORE_TYPE=JDBC2
NESSIE_VERSION_STORE_PERSIST_JDBC_DATASOURCE=postgresql
QUARKUS_DATASOURCE_POSTGRESQL_ACTIVE=true
QUARKUS_DATASOURCE_POSTGRESQL_DB_KIND=postgresql
QUARKUS_DATASOURCE_POSTGRESQL_USERNAME=$dbUser
QUARKUS_DATASOURCE_POSTGRESQL_PASSWORD=`$NESSIEPW
QUARKUS_DATASOURCE_POSTGRESQL_JDBC_URL=jdbc:postgresql://$${dbHost}:5432/$${dbName}?sslmode=require
# Iceberg REST catalog + S3 warehouse (MinIO)
NESSIE_CATALOG_DEFAULT_WAREHOUSE=warehouse
NESSIE_CATALOG_WAREHOUSES_WAREHOUSE_LOCATION=s3://$whBucket/
NESSIE_CATALOG_SERVICE_S3_DEFAULT_OPTIONS_REGION=us-east-1
NESSIE_CATALOG_SERVICE_S3_DEFAULT_OPTIONS_ENDPOINT=$s3Endpoint/
NESSIE_CATALOG_SERVICE_S3_DEFAULT_OPTIONS_PATH_STYLE_ACCESS=true
NESSIE_CATALOG_SERVICE_S3_DEFAULT_OPTIONS_AUTH_TYPE=STATIC
# The compound S3 access-key secret (name+secret) does NOT map cleanly from env
# vars -- it must come from a properties file pulled in via QUARKUS_CONFIG_LOCATIONS.
QUARKUS_CONFIG_LOCATIONS=/etc/nexus-iceberg-rest/nessie.properties
EOF
sudo chown root:iceberg /etc/nexus-iceberg-rest/nessie.env
sudo chmod 0640 /etc/nexus-iceberg-rest/nessie.env
sudo tee /etc/nexus-iceberg-rest/nessie.properties >/dev/null <<EOF
# Rendered by role-overlay-nessie-config.tf -- S3 STATIC creds. access-key is a
# secret URN resolving to name/secret under an arbitrary (non-nessie-root)
# prefix; the inline access-key.name/.secret form is rejected by Quarkus config
# validation (SRCFG00050). Proven 2026-05-24.
nessie.catalog.service.s3.default-options.access-key=urn:nessie-secret:quarkus:lakehouse-s3-creds
lakehouse-s3-creds.name=`$S3AK
lakehouse-s3-creds.secret=`$S3SK
EOF
sudo chown root:iceberg /etc/nexus-iceberg-rest/nessie.properties
sudo chmod 0640 /etc/nexus-iceberg-rest/nessie.properties
sudo systemctl daemon-reload
sudo systemctl enable nexus-nessie.service >/dev/null 2>&1 || true
sudo systemctl restart nexus-nessie.service
echo NESSIE_CFG_OK
"@
      foreach ($ip in $restNodes) {
        Write-Host "[nessie-config $ip] importing CA + rendering nessie.env + starting"
        $out = ($script -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'NESSIE_CFG_OK') { Write-Host $out.Trim(); throw "[nessie-config $ip] config failed (rc=$LASTEXITCODE)" }
      }

      # Wait for Nessie health on both nodes. /q/health is on the Quarkus
      # MANAGEMENT interface (http :9000), NOT the app port (https :19120).
      foreach ($ip in $restNodes) {
        $deadline = (Get-Date).AddMinutes(4); $ok = $false
        while ((Get-Date) -lt $deadline) {
          $h = (ssh @sshOpts "$sshUser@$ip" "curl -fsS -o /dev/null -w '%%{http_code}' http://localhost:9000/q/health 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($h -match '200') { $ok = $true; break }
          Start-Sleep -Seconds 10
        }
        if (-not $ok) {
          $j = (ssh @sshOpts "$sshUser@$ip" "curl -s http://localhost:9000/q/health 2>&1 | head -30; sudo journalctl -u nexus-nessie.service --no-pager -n 20" 2>&1 | Out-String)
          Write-Host $j
          throw "[nessie-config $ip] Nessie health never reached 200 within 4 min"
        }
        Write-Host "[nessie-config $ip] Nessie healthy (mgmt :9000/q/health UP)"
      }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.147','192.168.70.148')) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-nessie.service 2>/dev/null; sudo rm -f /etc/nexus-iceberg-rest/nessie.env" 2>$null
      }
      exit 0
    PWSH
  }
}
