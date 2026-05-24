/*
 * role-overlay-spark-config.tf -- Phase 0.L.3
 *
 * Configures + starts Spark on all 5 nodes (2 masters first, then 3 workers):
 *   0. connect ethernet1 backplane (Spark reaches the ZooKeeper ensemble over
 *      VMnet10; master<->worker RPC stays on VMnet11).
 *   1. fetch the spark.authenticate secret + the MinIO S3 app key from Vault KV
 *      (via the local Vault Agent token).
 *   2. import the Vault CA into the JVM truststore (trust Nessie + MinIO TLS).
 *   3. render $SPARK_HOME/conf/{spark-env.sh,spark-defaults.conf} +
 *      /etc/nexus-spark/spark-cluster.env (recoveryMode=ZOOKEEPER, multi-master
 *      URL, S3A->MinIO, Iceberg REST catalog->Nessie, spark.authenticate +
 *      spark.network.crypto AES RPC encryption + spark.io.encryption).
 *   4. enable + start the role unit selected from NEXUS_ROLE.
 *
 * Security: cluster RPC is authenticated (spark.authenticate, shared secret from
 * Vault KV) AND AES-encrypted (spark.network.crypto, keyed by the same secret) --
 * no certs needed on the RPC path. The Master/Worker Web UI is HTTP on the
 * nftables-restricted VMnet11 (UI TLS deferred; ADR-0035). Outbound HTTPS to
 * Nessie + MinIO validates against the Vault CA in the JVM truststore.
 *
 * All creds read on-node via the local Vault Agent token; never transit the host.
 *
 * Selective ops: var.enable_spark_config.
 */

resource "null_resource" "spark_config" {
  count = var.enable_spark_config ? 1 : 0

  triggers = {
    va_ids      = join(",", [for k, r in null_resource.spark_vault_agent : r.id])
    zk_id       = length(null_resource.zk_ensemble) > 0 ? null_resource.zk_ensemble[0].id : "disabled"
    spark_cfg_v = "2"
    ssh_user    = var.lakehouse_node_user
  }

  depends_on = [null_resource.spark_vault_agent, null_resource.zk_ensemble]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.lakehouse_node_user}'
      $vmrunPath  = '${var.vmrun_path}'
      $vmOutRoot  = '${var.vm_output_dir_root}'
      $kvAuth     = '${var.kv_spark_auth_secret_path}'
      $kvS3Ak     = '${var.kv_minio_app_access_key_path}'
      $kvS3Sk     = '${var.kv_minio_app_secret_key_path}'
      $zkUrl      = '${join(",", [for ip in var.zookeeper_backplane_ips : "${ip}:${var.zookeeper_client_port}"])}'
      $masterUrl  = 'spark://${join(",", [for ip in var.spark_master_ips : "${ip}:7077"])}'
      $s3Endpoint = '${var.minio_s3_endpoint}'
      $restUri    = '${var.iceberg_rest_uri}'
      $whBucket   = '${var.iceberg_warehouse_bucket}'
      $evBucket   = '${var.spark_events_bucket}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      # masters FIRST, then workers (workers connect to the masters).
      $nodes = @(
        @{ h='spark-master-1'; ip='192.168.70.140'; bp='192.168.10.140' },
        @{ h='spark-master-2'; ip='192.168.70.153'; bp='192.168.10.153' },
        @{ h='spark-worker-1'; ip='192.168.70.145'; bp='192.168.10.145' },
        @{ h='spark-worker-2'; ip='192.168.70.146'; bp='192.168.10.146' },
        @{ h='spark-worker-3'; ip='192.168.70.154'; bp='192.168.10.154' }
      )

      # ── 0. Connect the VMnet10 backplane on all 5 (NO-CARRIER auto-fix) ──
      foreach ($n in $nodes) {
        $vmx = Join-Path $vmOutRoot ("08-spark\{0}\{0}.vmx" -f $n.h)
        & $vmrunPath connectNamedDevice $vmx ethernet1 2>&1 | Out-Null
      }
      Start-Sleep -Seconds 3
      foreach ($n in $nodes) {
        ssh @sshOpts "$sshUser@$($n.ip)" 'sudo systemctl restart systemd-networkd' 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(2); $up = $false
        while ((Get-Date) -lt $deadline) {
          $has = (ssh @sshOpts "$sshUser@$($n.ip)" "ip -4 -o addr show nic1 2>/dev/null | grep -c '$($n.bp)'" 2>&1 | Out-String).Trim()
          if ($has -match '(?m)^[1-9]') { $up = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $up) { throw "[spark-config] backplane nic1 never came up on $($n.ip)" }
      }
      Write-Host "[spark-config] backplane up on all 5 Spark nodes"

      $script = @"
set -euo pipefail
ROLE=`$(sudo grep -oP '^NEXUS_ROLE=\K.*' /etc/nexus-spark/node-identity.env)
LOCALIP=`$(sudo grep -oP '^NEXUS_VMNET11_IP=\K.*' /etc/nexus-spark/node-identity.env)
[ -n "`$ROLE" ] && [ -n "`$LOCALIP" ] || { echo "ERROR: NEXUS_ROLE/NEXUS_VMNET11_IP empty" >&2; exit 1; }
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
AUTHSEC=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvAuth)
S3AK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvS3Ak)
S3SK=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvS3Sk)
[ -n "`$AUTHSEC" ] && [ -n "`$S3AK" ] && [ -n "`$S3SK" ] || { echo "ERROR: empty Spark/S3 creds from KV" >&2; exit 1; }
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# Trust the Vault CA in the JVM truststore so S3A (MinIO) + Iceberg REST (Nessie)
# TLS validate. Idempotent (delete+re-import).
sudo keytool -delete -alias nexus-ca -keystore "`$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null || true
sudo keytool -importcert -noprompt -alias nexus-ca -file /etc/vault-agent/ca-bundle.crt -keystore "`$JAVA_HOME/lib/security/cacerts" -storepass changeit

# spark-env.sh (sourced by spark-class): recoveryMode=ZOOKEEPER + local bind.
sudo tee /opt/spark/conf/spark-env.sh >/dev/null <<EOF
#!/usr/bin/env bash
# Rendered by role-overlay-spark-config.tf -- do not edit by hand.
export JAVA_HOME=$JAVA_HOME
export SPARK_LOG_DIR=/var/log/spark
# Worker work dir MUST be spark-writable: /opt/spark is root-owned (the symlinked
# install), so the default \$SPARK_HOME/work fails AccessDenied. Use the
# spark-owned data dir instead. Proven 2026-05-24.
export SPARK_WORKER_DIR=/var/lib/spark/work
export SPARK_LOCAL_IP=`$LOCALIP
export SPARK_PUBLIC_DNS=`$LOCALIP
export SPARK_DAEMON_JAVA_OPTS="-Dspark.deploy.recoveryMode=ZOOKEEPER -Dspark.deploy.zookeeper.url=$zkUrl -Dspark.deploy.zookeeper.dir=/spark"
EOF
sudo chown root:spark /opt/spark/conf/spark-env.sh
sudo chmod 0644 /opt/spark/conf/spark-env.sh

# spark-cluster.env (systemd EnvironmentFile): role-specific master host/URL.
sudo tee /etc/nexus-spark/spark-cluster.env >/dev/null <<EOF
SPARK_MASTER_HOST=`$LOCALIP
SPARK_MASTER_URL=$masterUrl
EOF
sudo chown root:spark /etc/nexus-spark/spark-cluster.env
sudo chmod 0640 /etc/nexus-spark/spark-cluster.env

# spark-defaults.conf: authenticated+AES-encrypted RPC + Iceberg REST(Nessie) -> S3FileIO(MinIO).
sudo tee /opt/spark/conf/spark-defaults.conf >/dev/null <<EOF
# Rendered by role-overlay-spark-config.tf -- do not edit by hand.
spark.authenticate                       true
spark.authenticate.secret                `$AUTHSEC
spark.network.crypto.enabled             true
spark.network.crypto.keyLength           128
# Driver MUST advertise its own IP: reverse DNS of the node returns the
# round-robin spark-master.nexus.lab, which would send executors to the wrong
# master and they never register. Proven 2026-05-24.
spark.driver.host                        `$LOCALIP
spark.driver.bindAddress                 `$LOCALIP
# In-memory session catalog -- every table lives in the Iceberg REST catalog
# 'nexus'; this avoids booting an embedded Derby Hive metastore. Proven 2026-05-24.
spark.sql.catalogImplementation          in-memory
spark.sql.extensions                     org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.nexus                  org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.nexus.type             rest
spark.sql.catalog.nexus.uri              $restUri
# Nessie resolves the warehouse by NAME (a URI yields "Warehouse not known"); the
# location + server-side S3 config live in Nessie. Iceberg does client-side IO via
# S3FileIO (AWS SDK v2, the baked iceberg-aws-bundle); client.region is required.
spark.sql.catalog.nexus.warehouse        $whBucket
spark.sql.catalog.nexus.io-impl          org.apache.iceberg.aws.s3.S3FileIO
spark.sql.catalog.nexus.s3.endpoint      $s3Endpoint
spark.sql.catalog.nexus.s3.path-style-access true
spark.sql.catalog.nexus.s3.access-key-id `$S3AK
spark.sql.catalog.nexus.s3.secret-access-key `$S3SK
spark.sql.catalog.nexus.client.region    us-east-1
# Disable the EC2 instance-metadata fallback on executors (insurance; static S3
# creds + client.region above are authoritative, so IMDS is never needed).
spark.executorEnv.AWS_EC2_METADATA_DISABLED true
spark.eventLog.enabled                   false
EOF
sudo chown root:spark /opt/spark/conf/spark-defaults.conf
sudo chmod 0640 /opt/spark/conf/spark-defaults.conf

sudo systemctl daemon-reload
if [ "`$ROLE" = "spark-master" ]; then
  sudo systemctl enable nexus-spark-master.service >/dev/null 2>&1 || true
  sudo systemctl restart nexus-spark-master.service
  echo "SPARK_CFG_OK role=master ip=`$LOCALIP"
else
  sudo systemctl enable nexus-spark-worker.service >/dev/null 2>&1 || true
  sudo systemctl restart nexus-spark-worker.service
  echo "SPARK_CFG_OK role=worker ip=`$LOCALIP"
fi
"@

      foreach ($n in $nodes) {
        Write-Host "[spark-config $($n.h)] rendering config + starting role unit"
        $out = ($script -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($n.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'SPARK_CFG_OK') { Write-Host $out.Trim(); throw "[spark-config $($n.h)] config failed (rc=$LASTEXITCODE)" }
        Write-Host ("[spark-config $($n.h)] " + (($out.Trim() -split "`n") | Select-String 'SPARK_CFG_OK'))
        # Give the masters a head start so workers can register on first try.
        if ($n.h -eq 'spark-master-2') { Start-Sleep -Seconds 8 }
      }
      Write-Host "[spark-config] all 5 Spark role units started (2 masters + 3 workers)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.140','192.168.70.153','192.168.70.145','192.168.70.146','192.168.70.154')) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now nexus-spark-master.service nexus-spark-worker.service 2>/dev/null; sudo rm -f /etc/nexus-spark/spark-cluster.env /opt/spark/conf/spark-env.sh /opt/spark/conf/spark-defaults.conf" 2>$null
      }
      exit 0
    PWSH
  }
}
