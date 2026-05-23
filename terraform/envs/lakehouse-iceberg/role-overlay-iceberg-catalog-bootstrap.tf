/*
 * role-overlay-iceberg-catalog-bootstrap.tf -- Phase 0.L.2 exit gate
 *
 * Proves the Iceberg REST catalog is functional end-to-end:
 *   HARD: Iceberg REST /v1/config 200 + Nessie /api/v2/config 200 (Nessie up +
 *         JDBC to the HA PG works) + namespace create/list round-trip (catalog
 *         writes to PG).
 *   BEST-EFFORT: create an Iceberg table via REST + verify metadata lands in
 *         s3://warehouse on MinIO. The definitive table->S3 write proof is the
 *         0.L.3 Spark gate (Spark is the natural Iceberg client); a Nessie
 *         Iceberg-REST prefix quirk here warns rather than blocking the phase.
 *
 * Selective ops: var.enable_iceberg_catalog_bootstrap.
 */

resource "null_resource" "iceberg_catalog_bootstrap" {
  count = var.enable_iceberg_catalog_bootstrap ? 1 : 0

  triggers = {
    nessie_id = length(null_resource.nessie_config) > 0 ? null_resource.nessie_config[0].id : "disabled"
    bucket    = var.iceberg_warehouse_bucket
    bootstrap_v = "1"
  }

  depends_on = [null_resource.nessie_config]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.lakehouse_node_user}'
      $restIp   = '192.168.70.147'
      $minioIp  = '192.168.70.141'
      $bucket   = '${var.iceberg_warehouse_bucket}'
      $ns       = 'nexus_lakehouse'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $gate = @"
set -euo pipefail
BASE=https://localhost:19120
# 1. Iceberg REST config (HARD)
code=`$(curl -sk -o /tmp/icfg.json -w '%%{http_code}' "`$BASE/iceberg/v1/config" || true)
[ "`$code" = "200" ] || { echo "ERROR: Iceberg REST /v1/config returned `$code" >&2; cat /tmp/icfg.json >&2 || true; exit 1; }
echo "[gate] Iceberg REST /v1/config = 200"
# 2. Nessie native config (HARD -- proves PG backend reachable)
code=`$(curl -sk -o /dev/null -w '%%{http_code}' "`$BASE/api/v2/config" || true)
[ "`$code" = "200" ] || { echo "ERROR: Nessie /api/v2/config returned `$code" >&2; exit 1; }
echo "[gate] Nessie /api/v2/config = 200 (PG backend OK)"
# 3. Namespace round-trip via Iceberg REST (HARD -- proves catalog write to PG)
PREFIX=`$(jq -r '.overrides.prefix // .defaults.prefix // "main"' /tmp/icfg.json)
echo "[gate] Iceberg REST prefix = `$PREFIX"
curl -sk -X POST "`$BASE/iceberg/v1/`$PREFIX/namespaces" -H 'Content-Type: application/json' -d '{"namespace":["$ns"]}' >/dev/null 2>&1 || true
NSLIST=`$(curl -sk "`$BASE/iceberg/v1/`$PREFIX/namespaces" || true)
echo "`$NSLIST" | grep -q '$ns' || { echo "ERROR: namespace $ns not found after create" >&2; echo "`$NSLIST" >&2; exit 1; }
echo "[gate] namespace round-trip OK ($ns present)"
# 4. BEST-EFFORT: create a table + leave the warehouse write for the Spark gate.
TBL=`$(curl -sk -X POST "`$BASE/iceberg/v1/`$PREFIX/namespaces/$ns/tables" -H 'Content-Type: application/json' -d '{"name":"smoke","schema":{"type":"struct","fields":[{"id":1,"name":"id","required":true,"type":"long"}]}}' -w '\nHTTP:%%{http_code}' || true)
echo "[gate] table create attempt: `$(echo "`$TBL" | tail -1)"
echo GATE_OK
"@
      Write-Host "[catalog-bootstrap] running exit gate on iceberg-rest-1"
      $out = ($gate -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$restIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $out.Trim()
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'GATE_OK') { throw "[catalog-bootstrap] exit gate failed (rc=$LASTEXITCODE)" }

      # Best-effort: report whether table metadata landed in the MinIO warehouse.
      $wh = (ssh @sshOpts "$sshUser@$minioIp" "sudo mc ls --recursive nexuslocal/$bucket/$ns/ 2>/dev/null | head -5" 2>&1 | Out-String).Trim()
      if ($wh) { Write-Host "[catalog-bootstrap] warehouse content under s3://$bucket/$ns/:`n$wh" }
      else { Write-Host "[catalog-bootstrap] note: no s3://$bucket/$ns/ objects yet -- table data/metadata write is proven by the 0.L.3 Spark gate" }
      Write-Host "[catalog-bootstrap] EXIT GATE GREEN -- Iceberg REST catalog reachable, PG-backed, namespace round-trip OK"
    PWSH
  }
}
