/*
 * role-overlay-iceberg-pg-replication.tf -- Phase 0.L.2
 *
 * Stands up the dedicated catalog PostgreSQL master-replica HA pair:
 *   0. connect ethernet1 backplane on both (NO-CARRIER auto-fix; streaming
 *      replication rides VMnet10).
 *   1. PRIMARY (iceberg-pg-1): conf.d drop-in (wal_level=replica, ssl) + pg_hba
 *      (replication over backplane + nessie/admin over VMnet11 TLS) + roles
 *      (repluser, nessie) + the nessie DB.
 *   2. REPLICA (iceberg-pg-2): the NEXUS-ICEBERG-HBA block (so a PROMOTED standby
 *      admits Nessie -- pg_hba lives in /etc, NOT PGDATA, so pg_basebackup never
 *      carried it over; this was the 0.L.2 failover gap) + stop + wipe PGDATA +
 *      pg_basebackup -R from the primary's backplane IP + start as a hot standby.
 *   3. Fencing primitives on BOTH nodes (0.L.2.1 hardening -> makes the catalog-DB
 *      failover a real one-shot verb, LakehouseAdapter --direction iceberg-pg):
 *        - /usr/local/sbin/nexus-iceberg-reseed.sh <src-backplane> : guarded
 *          fence+re-seed (REFUSE if it holds the VIP or is already a streaming
 *          standby; require the source to be a reachable PRIMARY) -> stop, wipe
 *          PGDATA, pg_basebackup -R from the new primary, start as standby.
 *        - /etc/keepalived/nexus-iceberg-fence.sh : notify_fault hook -> detaches
 *          a best-effort self-heal reseed against the PEER (the adapter is the
 *          reliable orchestrated path; this covers an unattended PG crash).
 *   4. keepalived on both (VRRP VIP .151, unicast, state BACKUP + nopreempt so a
 *      recovered old-primary never flaps the VIP back; notify_master promotes a
 *      standby on failover; notify_fault self-fences a demoted old primary).
 *   5. verify pg_stat_replication shows the standby streaming.
 *
 * Hex KV passwords (openssl rand -hex) are inline-safe in SQL (no quoting traps).
 * All creds read on-node via the local Vault Agent token; never transit the host.
 *
 * Selective ops: var.enable_iceberg_pg_replication.
 */

resource "null_resource" "iceberg_pg_replication" {
  count = var.enable_iceberg_pg_replication ? 1 : 0

  triggers = {
    tls_pg_ids = join(",", [for k, r in null_resource.iceberg_tls : r.id if can(regex("iceberg-pg", k))])
    pg_repl_v  = "2" # 0.L.2.1: pg_hba on BOTH nodes + fence/re-seed primitives + notify_fault
    ssh_user   = var.lakehouse_node_user
  }

  depends_on = [null_resource.iceberg_tls]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.lakehouse_node_user}'
      $vmrunPath  = '${var.vmrun_path}'
      $vmOutRoot  = '${var.vm_output_dir_root}'
      $primaryIp  = '192.168.70.149'
      $replicaIp  = '192.168.70.150'
      $primaryBp  = '192.168.10.149'
      $replicaBp  = '192.168.10.150'
      $vip        = '${var.iceberg_db_vip}'
      $kvSuper    = '${var.kv_pg_superuser_password_path}'
      $kvRepl     = '${var.kv_pg_replication_password_path}'
      $kvNessie   = '${var.kv_nessie_db_password_path}'
      $nessieDb   = '${var.nessie_db_name}'
      $nessieUser = '${var.nessie_db_user}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      # ── 0. Connect the VMnet10 backplane (NO-CARRIER auto-fix) ───────────
      foreach ($n in @(@{h='iceberg-pg-1';ip=$primaryIp;bp=$primaryBp}, @{h='iceberg-pg-2';ip=$replicaIp;bp=$replicaBp})) {
        $vmx = Join-Path $vmOutRoot ("08-spark\{0}\{0}.vmx" -f $n.h)
        & $vmrunPath connectNamedDevice $vmx ethernet1 2>&1 | Out-Null
      }
      Start-Sleep -Seconds 3
      foreach ($n in @(@{ip=$primaryIp;bp=$primaryBp}, @{ip=$replicaIp;bp=$replicaBp})) {
        ssh @sshOpts "$sshUser@$($n.ip)" 'sudo systemctl restart systemd-networkd' 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(2); $up = $false
        while ((Get-Date) -lt $deadline) {
          $has = (ssh @sshOpts "$sshUser@$($n.ip)" "ip -4 -o addr show nic1 2>/dev/null | grep -c '$($n.bp)'" 2>&1 | Out-String).Trim()
          if ($has -match '(?m)^[1-9]') { $up = $true; break }
          Start-Sleep -Seconds 5
        }
        if (-not $up) { throw "[iceberg-pg] backplane nic1 never came up on $($n.ip)" }
      }
      Write-Host "[iceberg-pg] backplane up on both nodes"

      # ── 1. PRIMARY setup ────────────────────────────────────────────────
      $primaryScript = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
SUPERPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvSuper)
REPLPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRepl)
NESSIEPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvNessie)
[ -n "`$SUPERPW" ] && [ -n "`$REPLPW" ] && [ -n "`$NESSIEPW" ] || { echo "ERROR: empty PG creds from KV" >&2; exit 1; }
PGVER=17
CONF=/etc/postgresql/`$PGVER/main
sudo mkdir -p `$CONF/conf.d
sudo tee `$CONF/conf.d/nexus-iceberg.conf >/dev/null <<EOF
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/etc/nexus-iceberg-pg/tls/server.crt'
ssl_key_file = '/etc/nexus-iceberg-pg/tls/server.key'
ssl_ca_file = '/etc/nexus-iceberg-pg/tls/ca.crt'
EOF
grep -q "include_dir = 'conf.d'" `$CONF/postgresql.conf || echo "include_dir = 'conf.d'" | sudo tee -a `$CONF/postgresql.conf >/dev/null
if ! sudo grep -q 'NEXUS-ICEBERG-HBA' `$CONF/pg_hba.conf; then
  sudo tee -a `$CONF/pg_hba.conf >/dev/null <<EOF
# NEXUS-ICEBERG-HBA
host    replication   repluser   192.168.10.0/24   scram-sha-256
hostssl nessie        nessie     192.168.70.0/24   scram-sha-256
hostssl all           postgres   192.168.70.0/24   scram-sha-256
EOF
fi
sudo pg_ctlcluster `$PGVER main start 2>/dev/null || sudo systemctl start postgresql@`$PGVER-main || true
sudo systemctl enable postgresql@`$PGVER-main >/dev/null 2>&1 || true
for i in `$(seq 1 30); do sudo -u postgres pg_isready -q && break; sleep 2; done
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '`$SUPERPW'"
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='repluser'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE repluser WITH REPLICATION LOGIN PASSWORD '`$REPLPW'"
else
  sudo -u postgres psql -c "CREATE ROLE repluser WITH REPLICATION LOGIN PASSWORD '`$REPLPW'"
fi
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$nessieUser'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE $nessieUser WITH LOGIN PASSWORD '`$NESSIEPW'"
else
  sudo -u postgres psql -c "CREATE ROLE $nessieUser WITH LOGIN PASSWORD '`$NESSIEPW'"
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$nessieDb'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE $nessieDb OWNER $nessieUser"
sudo pg_ctlcluster `$PGVER main reload 2>/dev/null || sudo systemctl reload postgresql@`$PGVER-main || true
echo PRIMARY_OK
"@
      Write-Host "[iceberg-pg] configuring PRIMARY (iceberg-pg-1)"
      $out = ($primaryScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$primaryIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'PRIMARY_OK') { Write-Host $out.Trim(); throw "[iceberg-pg] primary setup failed (rc=$LASTEXITCODE)" }

      # ── 2. REPLICA setup (pg_basebackup from primary backplane) ─────────
      $replicaScript = @"
set -euo pipefail
export VAULT_ADDR=`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN=`$(sudo cat /var/run/nexus-vault-agent/token)
REPLPW=`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value $kvRepl)
[ -n "`$REPLPW" ] || { echo "ERROR: empty replication password from KV" >&2; exit 1; }
PGVER=17
CONF=/etc/postgresql/`$PGVER/main
DATA=/var/lib/postgresql/`$PGVER/main
# Render the replica's own conf.d (ssl + hot_standby) so it matches the primary.
sudo mkdir -p `$CONF/conf.d
sudo tee `$CONF/conf.d/nexus-iceberg.conf >/dev/null <<EOF
listen_addresses = '*'
wal_level = replica
hot_standby = on
password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/etc/nexus-iceberg-pg/tls/server.crt'
ssl_key_file = '/etc/nexus-iceberg-pg/tls/server.key'
ssl_ca_file = '/etc/nexus-iceberg-pg/tls/ca.crt'
EOF
grep -q "include_dir = 'conf.d'" `$CONF/postgresql.conf || echo "include_dir = 'conf.d'" | sudo tee -a `$CONF/postgresql.conf >/dev/null
# The NEXUS-ICEBERG-HBA block MUST exist on the REPLICA too: pg_hba.conf lives in
# /etc (not PGDATA), so pg_basebackup never copies the primary's version. Without
# it, a PROMOTED standby refuses the Nessie REST hosts -> the catalog front door
# lands on a PG Nessie cannot use (the 0.L.2 failover gap). Idempotent + reloaded.
if ! sudo grep -q 'NEXUS-ICEBERG-HBA' `$CONF/pg_hba.conf; then
  sudo tee -a `$CONF/pg_hba.conf >/dev/null <<EOF
# NEXUS-ICEBERG-HBA
host    replication   repluser   192.168.10.0/24   scram-sha-256
hostssl nessie        nessie     192.168.70.0/24   scram-sha-256
hostssl all           postgres   192.168.70.0/24   scram-sha-256
EOF
  sudo -u postgres psql -tAc 'SELECT pg_reload_conf()' >/dev/null 2>&1 || true
fi
# walreceiver needs the replication password to stream; pg_basebackup -R does
# NOT embed it in primary_conninfo, so authenticate via the postgres .pgpass.
# Written ALWAYS (also on the already-standby idempotent path).
echo "$${primaryBp}:5432:replication:repluser:`$REPLPW" | sudo tee /var/lib/postgresql/.pgpass >/dev/null
sudo chown postgres:postgres /var/lib/postgresql/.pgpass
sudo chmod 0600 /var/lib/postgresql/.pgpass
# Idempotent: if already a standby, only restart if NOT currently streaming
# (a restart triggers a slow walreceiver reconnect; avoid it when healthy).
if sudo test -f `$DATA/standby.signal; then
  if sudo -u postgres psql -tAc "SELECT status FROM pg_stat_wal_receiver" 2>/dev/null | grep -qi streaming; then
    echo "REPLICA_OK (already standby + streaming)"; exit 0
  fi
  sudo pg_ctlcluster `$PGVER main restart 2>/dev/null || sudo systemctl restart postgresql@`$PGVER-main || true
  echo "REPLICA_OK (already standby; .pgpass refreshed + restarted)"; exit 0
fi
sudo pg_ctlcluster `$PGVER main stop 2>/dev/null || sudo systemctl stop postgresql@`$PGVER-main || true
sudo rm -rf `$DATA
sudo install -d -m 0700 -o postgres -g postgres `$DATA
sudo -u postgres env PGPASSWORD="`$REPLPW" pg_basebackup -h $primaryBp -p 5432 -U repluser -D `$DATA -Fp -Xs -P -R
sudo pg_ctlcluster `$PGVER main start 2>/dev/null || sudo systemctl start postgresql@`$PGVER-main
sudo systemctl enable postgresql@`$PGVER-main >/dev/null 2>&1 || true
for i in `$(seq 1 30); do sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | grep -qi t && break; sleep 2; done
echo REPLICA_OK
"@
      Write-Host "[iceberg-pg] configuring REPLICA (iceberg-pg-2) via pg_basebackup"
      $out = ($replicaScript -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$replicaIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $out -notmatch 'REPLICA_OK') { Write-Host $out.Trim(); throw "[iceberg-pg] replica setup failed (rc=$LASTEXITCODE)" }

      # ── 3. keepalived on both (VRRP VIP, state BACKUP + nopreempt) ──────
      $promote = @'
#!/bin/bash
# nexus-iceberg-promote.sh -- promote this PG node if it is a standby (failover).
if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
  /usr/bin/pg_ctlcluster 17 main promote
fi
'@
      $promoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($promote -replace "`r`n","`n")))

      # nexus-iceberg-reseed.sh -- the guarded fence + re-seed primitive (identical
      # on both nodes; the source primary is passed as $1). Drives the adapter's
      # `failover --direction iceberg-pg` AND the notify_fault self-heal.
      $reseed = @"
#!/bin/bash
# nexus-iceberg-reseed.sh <source_backplane_ip> -- fence + re-seed THIS node as a
# fresh streaming standby of the current primary. Installed by the 0.L.2.1 fencing
# hardening. Guarded so it can NEVER wipe the live primary.
set -uo pipefail
SRC="`$${1:-}"
VIP="$vip"; KVREPL="$kvRepl"; KVSUPER="$kvSuper"; PGVER=17
DATA="/var/lib/postgresql/`$PGVER/main"
log(){ echo "[iceberg-reseed] `$(date -Is) `$*"; }
[ -n "`$SRC" ] || { log "usage: nexus-iceberg-reseed.sh <source_backplane_ip>"; exit 2; }
SRCMGMT="`$(echo "`$SRC" | sed 's/^192\.168\.10\./192.168.70./')"
exec 9>/run/nexus-iceberg-reseed.lock || exit 0
flock -n 9 || { log "another reseed in progress; skip"; exit 0; }
# SAFETY 1: never re-seed the node that holds the catalog VIP (it IS the primary).
if ip -4 -o addr show 2>/dev/null | grep -q "`$VIP/"; then log "REFUSE: this node holds VIP `$VIP (it is the primary)"; exit 3; fi
export VAULT_ADDR="`$(grep -oP 'address\s*=\s*"\K[^"]+' /etc/vault-agent/00-base.hcl)"
export VAULT_CACERT=/etc/vault-agent/ca-bundle.crt
TOKEN="`$(sudo cat /var/run/nexus-vault-agent/token)"
REPLPW="`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value `$KVREPL)"
SUPERPW="`$(VAULT_TOKEN=`$TOKEN /usr/local/bin/vault kv get -field=value `$KVSUPER)"
[ -n "`$REPLPW" ] || { log "ERROR: empty replication password from KV"; exit 4; }
# SAFETY 2: the source must be reachable AND a primary (in_recovery=f).
if ! /usr/lib/postgresql/`$PGVER/bin/pg_isready -q -h "`$SRC" -p 5432; then log "REFUSE: source `$SRC not accepting connections"; exit 5; fi
SRCREC="`$(PGPASSWORD="`$SUPERPW" psql -h "`$SRCMGMT" -p 5432 -U postgres -d postgres -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null | tr -d '[:space:]')"
[ "`$SRCREC" = "f" ] || { log "REFUSE: source `$SRCMGMT is not a primary (pg_is_in_recovery=`$SRCREC)"; exit 6; }
# SAFETY 3: already a healthy streaming standby? nothing to do (idempotent).
if sudo test -f "`$DATA/standby.signal" && sudo -u postgres psql -tAc 'SELECT status FROM pg_stat_wal_receiver' 2>/dev/null | grep -qi streaming; then
  log "already a streaming standby; nothing to do"; exit 0
fi
log "re-seeding as a standby of `$SRC ..."
echo "*:*:replication:repluser:`$REPLPW" | sudo tee /var/lib/postgresql/.pgpass >/dev/null
sudo chown postgres:postgres /var/lib/postgresql/.pgpass; sudo chmod 0600 /var/lib/postgresql/.pgpass
sudo pg_ctlcluster `$PGVER main stop 2>/dev/null || sudo systemctl stop postgresql@`$PGVER-main || true
sudo rm -rf "`$DATA"
sudo install -d -m 0700 -o postgres -g postgres "`$DATA"
sudo -u postgres env PGPASSWORD="`$REPLPW" pg_basebackup -h "`$SRC" -p 5432 -U repluser -D "`$DATA" -Fp -Xs -P -R
sudo pg_ctlcluster `$PGVER main start 2>/dev/null || sudo systemctl start postgresql@`$PGVER-main
sudo systemctl enable postgresql@`$PGVER-main >/dev/null 2>&1 || true
for i in `$(seq 1 30); do sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null | grep -qi t && break; sleep 2; done
log "RESEED_OK"
"@
      $reseedB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($reseed -replace "`r`n","`n")))

      foreach ($n in @(@{ip=$primaryIp;src=$primaryIp;peer=$replicaIp;peer_bp=$replicaBp;prio=110}, @{ip=$replicaIp;src=$replicaIp;peer=$primaryIp;peer_bp=$primaryBp;prio=100})) {
        # nexus-iceberg-fence.sh -- keepalived notify_fault hook (per-node peer).
        $fence = @"
#!/bin/bash
# nexus-iceberg-fence.sh -- keepalived notify_fault hook (best-effort self-heal).
# Local PG is down + keepalived released the VIP -> detach a re-seed against the
# PEER (the node that has taken the VIP / been promoted). The adapter's
# `failover --direction iceberg-pg` is the RELIABLE orchestrated path; this only
# covers an UNATTENDED PG crash. All safety guards live in the reseed helper.
PEER_BP="$($n.peer_bp)"
nohup bash -c "sleep 6; /usr/local/sbin/nexus-iceberg-reseed.sh `$PEER_BP" >> /var/log/nexus-iceberg-reseed.log 2>&1 &
exit 0
"@
        $fenceB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($fence -replace "`r`n","`n")))
        $kaConf = @"
global_defs {
  script_user root
}
vrrp_script chk_pg {
  script "/usr/local/sbin/nexus-pg-check.sh"
  interval 5
  fall 2
  rise 2
}
vrrp_instance VI_ICEBERG_DB {
  state BACKUP
  nopreempt
  interface nic0
  virtual_router_id 71
  priority $($n.prio)
  advert_int 1
  unicast_src_ip $($n.src)
  unicast_peer {
    $($n.peer)
  }
  authentication {
    auth_type PASS
    auth_pass icebrgvr
  }
  virtual_ipaddress {
    $vip/24 dev nic0
  }
  notify_master "/etc/keepalived/nexus-iceberg-promote.sh"
  notify_fault "/etc/keepalived/nexus-iceberg-fence.sh"
  track_script {
    chk_pg
  }
}
"@
        $kaB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kaConf -replace "`r`n","`n")))
        $kaStage = @"
set -euo pipefail
# keepalived's track_script must call the VERSIONED pg_isready binary, NOT the
# /usr/bin/pg_isready pg_wrapper symlink (which fails under keepalived's exec
# context -> chk_pg returns 1 -> no MASTER -> no VIP). Proven 2026-05-24.
sudo tee /usr/local/sbin/nexus-pg-check.sh >/dev/null <<'EOS'
#!/bin/bash
exec /usr/lib/postgresql/17/bin/pg_isready -q -h 127.0.0.1 -p 5432
EOS
sudo chmod 0755 /usr/local/sbin/nexus-pg-check.sh
echo '$promoteB64' | base64 -d | sudo tee /etc/keepalived/nexus-iceberg-promote.sh >/dev/null
sudo chmod 0755 /etc/keepalived/nexus-iceberg-promote.sh
echo '$reseedB64' | base64 -d | sudo tee /usr/local/sbin/nexus-iceberg-reseed.sh >/dev/null
sudo chmod 0755 /usr/local/sbin/nexus-iceberg-reseed.sh
echo '$fenceB64' | base64 -d | sudo tee /etc/keepalived/nexus-iceberg-fence.sh >/dev/null
sudo chmod 0755 /etc/keepalived/nexus-iceberg-fence.sh
echo '$kaB64' | base64 -d | sudo tee /etc/keepalived/keepalived.conf >/dev/null
sudo systemctl enable keepalived >/dev/null 2>&1 || true
sudo systemctl restart keepalived
echo KA_OK
"@
        $out = ($kaStage -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$($n.ip)" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'KA_OK') { Write-Host $out.Trim(); throw "[iceberg-pg] keepalived setup failed on $($n.ip) (rc=$LASTEXITCODE)" }
      }

      # ── 4. Verify replication + VIP (retry -- the standby connects async) ─
      $rep = "0"
      $vdeadline = (Get-Date).AddMinutes(4)
      while ((Get-Date) -lt $vdeadline) {
        $rep = (ssh @sshOpts "$sshUser@$primaryIp" "sudo -u postgres psql -tAc 'SELECT count(*) FROM pg_stat_replication'" 2>&1 | Out-String).Trim()
        if ($rep -match '(?m)^[1-9]') { break }
        Start-Sleep -Seconds 5
      }
      if ($rep -notmatch '(?m)^[1-9]') {
        $diag = (ssh @sshOpts "$sshUser@192.168.70.150" "sudo journalctl -u postgresql@17-main --no-pager -n 15" 2>&1 | Out-String)
        Write-Host "pg_stat_replication=$rep`n--- replica PG log ---`n$diag"
        throw "[iceberg-pg] primary shows no streaming standby"
      }
      # VIP binds ~10-15s after keepalived starts (rise 2 x interval 5 + MASTER
      # transition); poll for it on either PG node.
      $vipUp = $false
      $vdeadline2 = (Get-Date).AddMinutes(2)
      while ((Get-Date) -lt $vdeadline2) {
        $cnt = 0
        foreach ($pgip in @($primaryIp, $replicaIp)) {
          $h = (ssh @sshOpts "$sshUser@$pgip" "ip -4 -o addr show nic0 | grep -c '$vip'" 2>&1 | Out-String).Trim()
          if ($h -match '(?m)^[1-9]') { $cnt++ }
        }
        if ($cnt -eq 1) { $vipUp = $true; break }
        Start-Sleep -Seconds 5
      }
      if (-not $vipUp) {
        $kj = (ssh @sshOpts "$sshUser@$primaryIp" "sudo journalctl -u keepalived --no-pager -n 15" 2>&1 | Out-String)
        Write-Host "--- keepalived (pg-1) ---`n$kj"
        throw "[iceberg-pg] VRRP VIP $vip not bound on exactly one PG node"
      }
      Write-Host "[iceberg-pg] HA pair up -- streaming standby count=$rep; VIP $vip bound"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser = '${self.triggers.ssh_user}'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      foreach ($ip in @('192.168.70.149','192.168.70.150')) {
        ssh @sshOpts "$sshUser@$ip" "sudo systemctl disable --now keepalived 2>/dev/null; sudo systemctl disable --now postgresql@17-main 2>/dev/null; sudo rm -f /etc/keepalived/keepalived.conf /etc/keepalived/nexus-iceberg-promote.sh /etc/keepalived/nexus-iceberg-fence.sh /usr/local/sbin/nexus-iceberg-reseed.sh /etc/postgresql/17/main/conf.d/nexus-iceberg.conf" 2>$null
      }
      exit 0
    PWSH
  }
}
