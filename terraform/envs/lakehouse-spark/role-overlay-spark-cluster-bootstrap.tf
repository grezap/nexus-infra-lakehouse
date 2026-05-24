/*
 * role-overlay-spark-cluster-bootstrap.tf -- Phase 0.L.3 exit gate
 *
 * Runs AFTER spark-config. Verifies the HA cluster + the lakehouse write path:
 *   HARD 1. Exactly one master ALIVE + one STANDBY (the ZK election worked).
 *   HARD 2. All 3 workers registered ALIVE with the active master.
 *   HARD 3. The Spark master-HA election state exists in ZooKeeper (/spark).
 *   HARD 4. The full write path: a spark-sql job creates an Iceberg namespace +
 *           table via the Nessie REST catalog, INSERTs rows (Parquet -> MinIO
 *           s3a://warehouse), and reads the count back. This is the 0.L.3
 *           deliverable 0.L.2 deferred (Spark -> Nessie -> MinIO end to end).
 *
 * Selective ops: var.enable_spark_cluster_bootstrap.
 */

resource "null_resource" "spark_cluster_bootstrap" {
  count = var.enable_spark_cluster_bootstrap ? 1 : 0

  triggers = {
    spark_cfg_id = length(null_resource.spark_config) > 0 ? null_resource.spark_config[0].id : "disabled"
    bootstrap_v  = "2"
  }

  depends_on = [null_resource.spark_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser   = '${var.lakehouse_node_user}'
      $masters   = @('192.168.70.140','192.168.70.153')
      $masterUrl = 'spark://${join(",", [for ip in var.spark_master_ips : "${ip}:7077"])}'
      $sshOpts   = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # ── HARD 1+2. Active master ALIVE + 3 workers; the other STANDBY ─────
      $active = $null; $aliveWorkers = 0; $standby = 0
      $deadline = (Get-Date).AddMinutes(4)
      while ((Get-Date) -lt $deadline) {
        $active = $null; $aliveWorkers = 0; $standby = 0
        foreach ($m in $masters) {
          # The master Web UI binds to the node's VMnet11 IP (SPARK_LOCAL_IP), not
          # localhost -- query it by IP. Proven 2026-05-24.
          $j = (ssh @sshOpts "$sshUser@$m" "curl -fsS http://$${m}:8080/json/ 2>/dev/null" 2>&1 | Out-String).Trim()
          if ($j -match '"status"\s*:\s*"ALIVE"') {
            $active = $m
            if ($j -match '"aliveworkers"\s*:\s*([0-9]+)') { $aliveWorkers = [int]$matches[1] }
          } elseif ($j -match '"status"\s*:\s*"STANDBY"') {
            $standby++
          }
        }
        if ($active -and $aliveWorkers -ge 3 -and $standby -ge 1) { break }
        Start-Sleep -Seconds 10
      }
      if (-not $active) { throw "[spark-bootstrap] no ALIVE master found within 4 min" }
      if ($standby -lt 1) { throw "[spark-bootstrap] no STANDBY master found (HA not formed)" }
      if ($aliveWorkers -lt 3) { throw "[spark-bootstrap] active master ($active) reports $aliveWorkers/3 alive workers" }
      Write-Host "[spark-bootstrap] HA OK -- active master $active, 1 standby, $aliveWorkers workers ALIVE"

      # ── HARD 3. Spark election state present in ZooKeeper (/spark) ───────
      $zkOut = (ssh @sshOpts "$sshUser@192.168.70.155" "sudo JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 /opt/zookeeper/bin/zkCli.sh -server 127.0.0.1:2181 ls /spark 2>/dev/null | tail -3" 2>&1 | Out-String)
      if ($zkOut -notmatch 'master_status' -and $zkOut -notmatch 'leader_election') {
        Write-Host $zkOut
        throw "[spark-bootstrap] Spark master-HA election state (/spark) not found in ZooKeeper"
      }
      Write-Host "[spark-bootstrap] ZooKeeper holds the Spark master-HA election state (/spark)"

      # ── HARD 4. Spark -> Iceberg(Nessie) -> MinIO(S3A) write round-trip ──
      $sql = "CREATE NAMESPACE IF NOT EXISTS nexus.lakehouse_demo; " +
             "CREATE TABLE IF NOT EXISTS nexus.lakehouse_demo.smoke (id bigint, msg string) USING iceberg; " +
             "DELETE FROM nexus.lakehouse_demo.smoke; " +
             "INSERT INTO nexus.lakehouse_demo.smoke VALUES (1,'hello'),(2,'lakehouse'); " +
             "SELECT concat('SMOKECOUNT=', count(*)) FROM nexus.lakehouse_demo.smoke;"
      $sqlB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($sql))
      $job = @"
set -euo pipefail
SQL=`$(echo '$sqlB64' | base64 -d)
# spark-defaults.conf (rendered by spark-config v2) carries the full catalog +
# driver.host + S3FileIO config; timeout fails fast instead of hanging the apply.
sudo JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 timeout 300 /opt/spark/bin/spark-sql \
  --master '$masterUrl' \
  --name nexus-0L3-smoke \
  -e "`$SQL" 2>&1 | grep -E 'SMOKECOUNT=|Exception|ERROR|accepted any resources' | head -40
"@
      Write-Host "[spark-bootstrap] running Spark -> Iceberg -> MinIO write round-trip on $active ..."
      $out = ($job -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$active" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($out -notmatch 'SMOKECOUNT=2') {
        Write-Host $out.Trim()
        throw "[spark-bootstrap] Iceberg/S3 round-trip did not return SMOKECOUNT=2 (Spark -> Nessie -> MinIO write path)"
      }
      Write-Host "[spark-bootstrap] write path OK -- created nexus.lakehouse_demo.smoke (Iceberg via Nessie; Parquet in MinIO s3a://warehouse); count=2"
      Write-Host "[spark-bootstrap] Phase 0.L.3 exit gate PASSED"
    PWSH
  }
}
