# nexus-infra-lakehouse — operator handbook

The from-absolute-zero rebuild guide for the lakehouse tier (`08-spark`), Phase
0.L. Canon, not informal. An operator (or future-Greg after a break) can rebuild
this tier with no external knowledge from this document.

> Coverage: **0.L.1 (MinIO) + 0.L.2 (Iceberg REST catalog + dedicated PG HA) —
> complete + cold-rebuild proven.** §1.13 (Spark, 0.L.3) is added as that sub-phase
> lands.

---

## §0 Prerequisites

**Build host:** Windows 11 + VMware Workstation Pro 17.5+ (`10.0.70.101`), pwsh,
Packer ≥ 1.11, Terraform ≥ 1.9, `ssh`/`scp` on PATH, the `nexus_gateway_ed25519`
key configured for bare `ssh nexusadmin@<ip>` (see nexus-infra-vmware handbook §0.4).

**Other tiers that MUST already be alive** (the always-on 6-VM foundation):

| VM | IP | Verify |
|---|---|---|
| `nexus-gateway` | `192.168.70.1` | `ssh nexusadmin@192.168.70.1 'echo ok'` — dnsmasq (DHCP/DNS), nftables egress |
| `dc-nexus` | `192.168.70.10` | AD/DNS for `nexus.lab` |
| `vault-1/2/3` | `.121`–`.123` | `vault status` leader elected; PKI `pki_int/` live |
| `vault-transit` | `.124` | auto-unseal custodian |

**Cross-repo state this tier reads (provisioned by `nexus-infra-vmware`):**

- **foundation env** — dhcp-host reservations for the 11 lakehouse MACs
  (`:99`–`:A3` → `.140`–`.150`) + the catalog VIP (`:A?` → `.151`) + round-robin
  DNS `minio.nexus.lab`, `iceberg.nexus.lab` (→ `.147`/`.148`), and
  `iceberg-db.nexus.lab` (→ VIP `.151`) —
  `role-overlay-gateway-lakehouse-{reservations,dns}.tf`.
- **security env (MinIO, 0.L.1)** — `minio-server` PKI role + 4 per-host AppRole
  sidecars at `$HOME/.nexus/vault-agent-lakehouse-minio-minio-{1..4}.json` + KV
  sticky-seeds at
  `nexus/lakehouse/minio/{root-user,root-password,app-access-key,app-secret-key}`
  (field `value`) — `role-overlay-vault-pki-minio.tf`,
  `role-overlay-vault-agent-minio-{policies,approles}.tf`,
  `role-overlay-vault-minio-creds-seed.tf`.
- **security env (Iceberg, 0.L.2)** — `iceberg-server` PKI role + 4 per-host
  AppRole sidecars at
  `$HOME/.nexus/vault-agent-lakehouse-iceberg-iceberg-{pg-1,pg-2,rest-1,rest-2}.json`
  + KV sticky-seeds at `nexus/lakehouse/iceberg/{pg-superuser-password,
  pg-replication-password,nessie-db-password}` (field `value`) —
  `role-overlay-vault-pki-iceberg.tf`,
  `role-overlay-vault-agent-iceberg-{policies,approles}.tf`,
  `role-overlay-vault-iceberg-creds-seed.tf`. The Nessie S3 client reuses the
  MinIO `app-access-key`/`app-secret-key` KV seeds (0.L.1).

**Build-host cache:** `H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` (sha256
`95838884…`). MinIO + mc binaries pull from `dl.min.io` during bake (NAT egress).

---

## §1 Phase walkthrough

### §1.1 Build the MinIO template

```powershell
cd packer\lakehouse-minio-node
packer init .
packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → H:/VMS/NexusPlatform/_templates/lakehouse-minio-node/lakehouse-minio-node.vmx
# bake ~6-7 min. Debian 13 + MinIO server + mc; a 2nd VMDK is formatted xfs
# (label minio-data, /mnt/minio/data) for the erasure drive; nexus-minio.service
# delivered DISABLED.
```

### §1.2 Cross-env operator order (run FIRST, in nexus-infra-vmware)

Hard ordering — the cluster apply reads the AppRole sidecars + relies on the
gateway reservations/DNS + Vault PKI/KV:

```powershell
# in nexus-infra-vmware
pwsh -File scripts\foundation.ps1 apply   # lands lakehouse reservations + minio.nexus.lab DNS
pwsh -File scripts\security.ps1   apply   # lands minio-server PKI + 4 AppRole sidecars + KV creds
```

Both are idempotent: re-applying only creates the new lakehouse `null_resource`s;
all other tiers' overlays are unchanged no-ops (and only touch the gateway/Vault,
never the stopped cluster VMs).

### §1.3 Apply the MinIO cluster

```powershell
# in nexus-infra-lakehouse
pwsh -File scripts\lakehouse-minio.ps1 apply
```

Apply graph (per `terraform/envs/lakehouse-minio/main.tf`):
1. `module.minio_1..4` — `vmrun clone` (full) → configure dual-NIC → power on; the
   baked firstboot self-selects hostname/role/backplane-IP from the DHCP IP.
2. `null_resource.minio_nftables_backplane` — push per-cluster nftables + `nft -f`.
3. `null_resource.minio_vault_agent` (×4) — install Vault Agent (reads each
   sidecar), AppRole auth, token sink.
4. `null_resource.minio_tls` (×4) — Vault Agent PKI template →
   `certs/{public.crt,private.key(PKCS#8),CAs/nexus-ca.crt}`.
5. `null_resource.minio_config` — **connect ethernet1 (zero-touch NO-CARRIER fix)**
   → render `/etc/nexus-minio/minio.conf` from Vault KV → start all 4 → wait for
   cluster health (quorum).
6. `null_resource.minio_bucket_bootstrap` — **exit gate**: mc alias → create
   buckets → `nexus-lakehouse-app` service account → erasure-health + object
   round-trip.

Wall-clock ~10-15 min (4 clones + firstboot + overlays).

### §1.4 Verify the exit gate

```powershell
pwsh -File scripts\smoke-0.L.1.ps1
# expect: "ALL 0.L.1 SMOKE CHECKS PASSED" (41 checks). -IncludeChaos adds a
# single-node-loss tolerance check (cluster stays read-write at 3/4).
```

Manual spot-checks: `mc admin info nexuslocal` on minio-1 (4 drives ok);
`dig +short minio.nexus.lab @192.168.70.1` (4 IPs).

### §1.5 Iterating (selective ops)

Every node + overlay has an `enable_*` toggle (steady-state default `true`):

```powershell
# bring up only minio-1/2 (e.g. partial debug):
pwsh -File scripts\lakehouse-minio.ps1 apply -Vars "enable_minio_3=false,enable_minio_4=false"
# re-run only the TLS overlay (after a cert change):
pwsh -File scripts\lakehouse-minio.ps1 apply -Vars "enable_minio_config=false,enable_minio_bucket_bootstrap=false"
# skip the exit-gate bootstrap (cluster bring-up only):
pwsh -File scripts\lakehouse-minio.ps1 apply -Vars "enable_minio_bucket_bootstrap=false"
```

### §1.6 Tear down

```powershell
pwsh -File scripts\lakehouse-minio.ps1 destroy   # removes the 4 MinIO VMs + overlay state
```

Survives teardown: the gateway reservations/DNS, the Vault PKI role + AppRoles +
KV creds (sticky), the built template. A subsequent `apply` re-clones from zero
and reuses the same KV creds — no KV wipe needed (the data disks are fresh xfs).

### §1.7 Build the Iceberg templates (0.L.2)

Two engines → two templates ([feedback_per_cluster_state_per_engine_template]):

```powershell
cd packer\lakehouse-iceberg-pg-node
packer init .; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → _templates/lakehouse-iceberg-pg-node — PostgreSQL 17 (PGDG) + keepalived;
#   both services delivered DISABLED. (libicu/libldap pulled with a bookworm
#   fallback when trixie lags PGDG.)

cd ..\lakehouse-iceberg-rest-node
packer init .; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → _templates/lakehouse-iceberg-rest-node — JDK21 + Project Nessie 0.107.5
#   uber-jar at /opt/nessie/nessie-quarkus-runner.jar (/opt/nessie is 0755 so
#   nexusadmin can traverse it — see §3.4 #1); nexus-nessie.service DISABLED.
```

### §1.8 Cross-env operator order (run FIRST, in nexus-infra-vmware)

```powershell
# in nexus-infra-vmware (idempotent — only the new iceberg null_resources apply)
pwsh -File scripts\foundation.ps1 apply   # iceberg.nexus.lab → .147/.148 + iceberg-db.nexus.lab → VIP .151
pwsh -File scripts\security.ps1   apply   # iceberg-server PKI + 4 AppRole sidecars + KV seeds nexus/lakehouse/iceberg/*
```

### §1.9 Apply the Iceberg cluster

```powershell
# in nexus-infra-lakehouse — MinIO (0.L.1) MUST be up (the s3://warehouse)
pwsh -File scripts\lakehouse-iceberg.ps1 apply
```

Apply graph (per `terraform/envs/lakehouse-iceberg/main.tf`):
1. `module.iceberg_pg_1/2` + `module.iceberg_rest_1/2` — clone → dual-NIC → power
   on; baked firstboot self-selects hostname/role/backplane-IP (and emits
   `NEXUS_PG_ROLE=primary|replica` for the PG pair).
2. `null_resource.iceberg_nftables_backplane` — per-cluster nftables + `nft -f`.
3. `null_resource.iceberg_vault_agent` (×4) — Vault Agent install + AppRole auth.
4. `null_resource.iceberg_tls` (×4) — PKI templates → PG `server.{crt,key}`+`ca.crt`
   / REST `cert.pem`+`key.pem`+`ca.crt`; SANs carry `iceberg-db.nexus.lab` (PG VIP)
   and `iceberg.nexus.lab` (REST round-robin).
5. `null_resource.iceberg_pg_replication` — **connect ethernet1** → PRIMARY
   conf.d/pg_hba/roles + `nessie` DB → REPLICA `pg_basebackup -R` hot standby →
   keepalived (VRRP VIP `.151`, BACKUP+nopreempt, promote hook) → verify
   `pg_stat_replication` + VIP bound.
6. `null_resource.nessie_config` — import Vault CA into the JVM truststore →
   render `nessie.env` (JDBC2 named-`postgresql` datasource → VIP `.151`) +
   `nessie.properties` (S3 urn-secret) → start both Nessie → health on `:9000`.
7. `null_resource.iceberg_catalog_bootstrap` — **exit gate**: Iceberg REST
   `/v1/config` + Nessie `/api/v2/config` + namespace round-trip (hard);
   table-create + MinIO warehouse verify (best-effort).

Wall-clock ~12-18 min (4 clones + firstboot + basebackup + overlays).

### §1.10 Verify the exit gate (0.L.2)

```powershell
pwsh -File scripts\smoke-0.L.2.ps1
# expect: "ALL 0.L.2 SMOKE CHECKS PASSED" (28 checks): reachability, firstboot,
# identity (incl. NEXUS_PG_ROLE==primary), Vault Agent, mTLS SANs, nftables,
# PG streaming replication, VRRP VIP bound on exactly one node, 2× Nessie health
# (mgmt :9000), Iceberg REST /v1/config + Nessie /api/v2/config == 200,
# round-robin + VIP DNS, namespace round-trip.
```

Manual spot-checks: on iceberg-pg-1
`sudo -u postgres psql -tAc 'SELECT count(*) FROM pg_stat_replication'` (= 1);
`ip -4 -o addr show nic0 | grep 192.168.70.151` (VIP on the primary);
`dig +short iceberg.nexus.lab @192.168.70.1` (2 IPs).

### §1.11 Iterating (selective ops, 0.L.2)

```powershell
# re-run only the Nessie config overlay (after a property change):
pwsh -File scripts\lakehouse-iceberg.ps1 apply -Vars "enable_iceberg_pg_replication=false,enable_iceberg_catalog_bootstrap=false"
# bring up only the PG pair (no Nessie):
pwsh -File scripts\lakehouse-iceberg.ps1 apply -Vars "enable_nessie_config=false,enable_iceberg_catalog_bootstrap=false"
# skip the exit-gate bootstrap (cluster bring-up only):
pwsh -File scripts\lakehouse-iceberg.ps1 apply -Vars "enable_iceberg_catalog_bootstrap=false"
```

> **Trap** ([feedback_terraform_partial_apply_destroys_resources]): every `-Vars`
> override is the *full* set — vars you don't pass revert to their `true`
> defaults. To pin one overlay off, pass *only* that `false`.

### §1.12 Tear down (0.L.2)

```powershell
pwsh -File scripts\lakehouse-iceberg.ps1 destroy   # removes the 4 iceberg VMs + overlay state
```

Survives teardown: gateway reservations/DNS, the `iceberg-server` PKI role +
AppRoles + KV creds (sticky), both templates. A subsequent `apply` re-clones from
zero, rebuilds the replica via fresh `pg_basebackup`, and recreates the `nessie`
DB — the catalog metadata is rebuilt by the bootstrap namespace round-trip.

### §1.13 Build the Spark + ZooKeeper templates (0.L.3)

Two engines → two templates ([feedback_per_cluster_state_per_engine_template]):

```powershell
cd packer\lakehouse-spark-node
packer init .; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → _templates/lakehouse-spark-node — JDK21 + Apache Spark 3.5.3 (bin-hadoop3) +
#   the S3A connector (hadoop-aws 3.3.4 + aws-java-sdk-bundle 1.12.262) + Iceberg
#   Spark runtime 1.7.1 + iceberg-aws-bundle 1.7.1 (AWS SDK v2 for S3FileIO).
#   nexus-spark-master.service AND nexus-spark-worker.service both DISABLED.

cd ..\lakehouse-zookeeper-node
packer init .; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .
# → _templates/lakehouse-zookeeper-node — JDK21 + Apache ZooKeeper 3.9.3;
#   nexus-zookeeper.service DISABLED.
```

### §1.14 Cross-env operator order (run FIRST, in nexus-infra-vmware)

```powershell
# in nexus-infra-vmware (idempotent — only the new spark null_resources apply)
pwsh -File scripts\foundation.ps1 apply   # +5 reservations (:AA-:AE -> .153/.154/.155/.156/.157) + spark-master.nexus.lab -> .140/.153
pwsh -File scripts\security.ps1   apply   # spark-server PKI + 5 AppRole sidecars + KV seed nexus/lakehouse/spark/auth-secret
```

### §1.15 Apply the Spark cluster

```powershell
# in nexus-infra-lakehouse — MinIO (0.L.1) + Iceberg (0.L.2) MUST be up
pwsh -File scripts\lakehouse-spark.ps1 apply
```

Apply graph (per `terraform/envs/lakehouse-spark/main.tf`):
1. `module.spark_master_1/2`, `module.spark_worker_1/2/3`, `module.zookeeper_1/2/3`
   — 8 clones → dual-NIC → power on; firstboot self-selects hostname/role +
   emits `NEXUS_ZK_ID` for ZK nodes.
2. `null_resource.spark_nftables_backplane` — per-cluster nftables: backplane
   trust + Spark UI/RPC ports + **the Spark cluster-peer RPC accept** (the 5
   Spark IPs — executors dial the driver's dynamic ports; see §3.6 #8).
3. `null_resource.spark_vault_agent` (×5 spark nodes) — Vault Agent + AppRole auth.
4. `null_resource.spark_tls` (×5) — `spark-server` PKI certs (UI TLS material).
5. `null_resource.zk_ensemble` — render `zoo.cfg` (server.1/2/3 on the backplane)
   + `myid` from `NEXUS_ZK_ID`; enable + start all 3; verify quorum.
6. `null_resource.spark_config` — import Vault CA into the JVM truststore; render
   `spark-env.sh` (recoveryMode=ZOOKEEPER) + `spark-defaults.conf`
   (authenticate + AES crypto, **driver.host pinned to node IP**, in-memory
   session catalog, Nessie REST catalog with **warehouse-by-name** + S3FileIO);
   start 2 masters then 3 workers.
7. `null_resource.spark_cluster_bootstrap` — **exit gate**: 1 ALIVE + 1 STANDBY
   master, 3 ALIVE workers, `/spark` election state in ZK, and a Spark→Nessie→
   MinIO Iceberg **write round-trip** (CREATE TABLE + INSERT + SELECT count=2).

Wall-clock ~20-28 min (8 clones + firstboot + overlays).

### §1.16 Verify the exit gate (0.L.3)

```powershell
pwsh -File scripts\smoke-0.L.3.ps1
# expect: "ALL 0.L.3 SMOKE CHECKS PASSED" (28 checks): reachability, firstboot,
# identity (incl. NEXUS_ZK_ID), Vault Agent (5 spark nodes), nftables, ZK quorum
# (1 leader + 2 followers), Spark HA (exactly 1 ALIVE + 1 STANDBY master, 3 ALIVE
# workers), RPC security (authenticate + AES), /spark election state in ZK,
# Iceberg namespace via Nessie REST, round-robin DNS. -IncludeChaos kills the
# active master and asserts the standby auto-promotes.
```

Manual spot-checks: `curl -s http://192.168.70.140:8080/json/ | jq .aliveworkers`
(= 3, **query the node IP, not localhost** — the UI binds to SPARK_LOCAL_IP);
ZK: `/opt/zookeeper/bin/zkServer.sh status` on a zk node (1 leader + 2 followers).

### §1.17 Iterating (selective ops, 0.L.3)

```powershell
# re-run only the Spark config overlay (after a spark-defaults change):
pwsh -File scripts\lakehouse-spark.ps1 apply -Vars "enable_spark_cluster_bootstrap=false"
# bring up only the ZooKeeper ensemble:
pwsh -File scripts\lakehouse-spark.ps1 apply -Vars "enable_spark_config=false,enable_spark_cluster_bootstrap=false"
```

> **Trap** ([feedback_terraform_partial_apply_destroys_resources]): every `-Vars`
> override is the *full* set; pass *only* the overlay you want off.

### §1.18 Tear down (0.L.3)

```powershell
pwsh -File scripts\lakehouse-spark.ps1 destroy   # removes the 8 spark/zk VMs + overlay state
```

Survives teardown: gateway reservations/DNS, the `spark-server` PKI role +
AppRoles + the `auth-secret` KV (sticky), both templates. A subsequent `apply`
re-clones from zero; the ZK ensemble + Spark HA re-form and the bootstrap
re-creates the demo Iceberg table.

---

## §2 Phase status

| Sub-phase | Cluster | Closed | Smoke |
|---|---|---|---|
| 0.L.1 | MinIO distributed EC (4 nodes) | 2026-05-23 (live-ratified + cold-rebuild proven) | `smoke-0.L.1.ps1` 41/41 |
| 0.L.2 | Iceberg REST (Nessie ×2) + dedicated PG HA (master-replica + VRRP VIP) | 2026-05-24 (live-ratified + cold-rebuild proven) | `smoke-0.L.2.ps1` 28/28 |
| 0.L.3 | Apache Spark HA (2 masters + 3 workers) + 3-node Apache ZooKeeper | 2026-05-24 (live-ratified + cold-rebuild proven) | `smoke-0.L.3.ps1` 28/28 |

---

## §3 Operator runbooks

### §3.1 Cold-rebuild canon (PROVEN 2026-05-23)

Zero operator hot-state between destroy and smoke:

```powershell
# (templates already built; cross-tier prereqs sticky)
pwsh -File scripts\lakehouse-minio.ps1 cycle   # destroy → apply → smoke
# → "ALL 0.L.1 SMOKE CHECKS PASSED"; the ethernet1 NO-CARRIER auto-fix runs
#   on the fresh clones with no manual step (see §3.2 #2).
```

### §3.2 Apply-time transient chronology

| # | Symptom | Diagnosis | Recovery (now in source) |
|---|---|---|---|
| 1 | `packer build` → `Timeout waiting for SSH` after 30 min; install never finishes | The dedicated 2nd data VMDK makes Debian `partman` stall on the multi-disk layout / the post-install reboot tries the blank disk | Preseed `partman/early_command` pins `/dev/sda` + zaps `/dev/sdb`'s label; `boot_wait` 20s, `ssh_timeout` 45m. Next build: 6m35s. ([feedback_debian_preseed_multidisk_stall]) |
| 2 | MinIO crash-loops: `grid: local host () not found in cluster setup`; `nic1 DOWN … NO-CARRIER` | VMware left `ethernet1` (VMnet10 backplane) disconnected at power-on despite `startConnected=TRUE`, so the static backplane IP never applied and MinIO can't match a local `MINIO_VOLUMES` host | `role-overlay-minio-config.tf` §0: `vmrun connectNamedDevice <vmx> ethernet1` + `systemctl restart systemd-networkd` + wait-for-backplane-IP, before rendering/starting MinIO. Zero-touch. (Same flake as analytics §3.x #9.) |

### §3.3 Cold-rebuild canon — 0.L.2 (PROVEN 2026-05-24)

```powershell
# (both iceberg templates built; MinIO 0.L.1 up; cross-tier prereqs sticky)
pwsh -File scripts\lakehouse-iceberg.ps1 cycle   # destroy → apply → smoke
# → "ALL 0.L.2 SMOKE CHECKS PASSED" (28). The replica is rebuilt from a fresh
#   pg_basebackup; the nessie DB + namespace are recreated by the bootstrap.
```

### §3.4 Apply-time transient chronology — 0.L.2

All eight were diagnosed on the live node before any code change
([feedback_diagnose_before_rewriting]) and are now fixed in source — the cold
rebuild above hits none of them.

| # | Symptom | Diagnosis | Recovery (now in source) |
|---|---|---|---|
| 1 | Nessie template post-install check fails: `nexusadmin` can't `stat /opt/nessie/nessie-quarkus-runner.jar` | `useradd` for the `nessie` system user set `HOME_MODE 0700` on `/opt/nessie`, blocking traversal | Ansible `file: path=/opt/nessie mode=0755` after the JAR lands (`lakehouse-iceberg-rest-node` role). |
| 2 | pg-replication overlay aborts rendering the verify SQL; PG role SQL malformed | PowerShell does **not** treat `\"` as an escape inside double-quoted strings — `\` terminated the string ([feedback_powershell_backslash_quote]) | Use single-quoted SQL literals (`'SELECT count(*) FROM pg_stat_replication'`); hex KV passwords are inline-safe so no inner quoting is needed. |
| 3 | `keepalived` refuses to start: parse error in `authentication { auth_type PASS; auth_pass … }` | keepalived's config grammar rejects semicolon-joined one-liners inside a block | Render the `authentication {}` block multi-line (one directive per line). |
| 4 | VRRP VIP `.151` never binds; `chk_pg` permanently DOWN though `pg_isready` works at the shell | keepalived's `vrrp_script` exec context can't run the `/usr/bin/pg_isready` `pg_wrapper` perl symlink → non-zero → no node takes MASTER | Wrapper `/usr/local/sbin/nexus-pg-check.sh` → `exec /usr/lib/postgresql/17/bin/pg_isready` (the **versioned** binary). ([feedback_keepalived_check_versioned_binary]) |
| 5 | Nessie JDBC URL renders as `jdbc:postgresql://…` with the host dropped; replica `.pgpass` host blank | `$dbHost:5432` / `$primaryBp:5432` parsed as a PowerShell scope-qualified variable ([feedback_powershell_url_scope_qualifier]) | `${dbHost}:5432` / `$${primaryBp}:5432` (the `$${}` survives the terraform heredoc). |
| 6 | Nessie starts but `/api/v2/config` 500s; logs show the default datasource is inactive / no JDBC | Nessie bundles a **named** `postgresql` datasource shipped `active=false`; the inert default datasource was being used | `QUARKUS_DATASOURCE_POSTGRESQL_ACTIVE=true` + `NESSIE_VERSION_STORE_PERSIST_JDBC_DATASOURCE=postgresql` (select the named DS). |
| 7 | Health poll on `https://…:19120/q/health` never 200; service is actually up | Quarkus serves `/q/health` on the **management** interface (`http :9000`), not the app port (`https :19120`) | Probe `http://localhost:9000/q/health`; smoke + apply gate both corrected. |
| 8 | Nessie won't boot: `SRCFG00050` on the S3 access-key | The inline `…access-key.name`/`.secret` form fails Quarkus config validation | Secret-URN form: `…access-key=urn:nessie-secret:quarkus:lakehouse-s3-creds` + `lakehouse-s3-creds.name`/`.secret` in `nessie.properties` via `QUARKUS_CONFIG_LOCATIONS`. ([feedback_nessie_jdbc2_s3_quarkus]) |

### §3.5 Cold-rebuild canon — 0.L.3 (PROVEN 2026-05-24)

```powershell
# (both spark/zk templates built incl. iceberg-aws-bundle; MinIO 0.L.1 + Iceberg
#  0.L.2 up; cross-tier prereqs sticky)
pwsh -File scripts\lakehouse-spark.ps1 cycle   # destroy → apply → smoke
# → "ALL 0.L.3 SMOKE CHECKS PASSED" (28). The ZK ensemble + Spark HA re-form from
#   zero; the bootstrap re-runs the Spark → Nessie → MinIO Iceberg write round-trip.
```

### §3.6 Apply-time transient chronology — 0.L.3

The Spark write path is a notoriously layered integration; #8 (the firewall gap)
masqueraded as every other symptom. **Lesson: "Initial job has not accepted any
resources" with free cores ≠ a resources problem — it means executors launch and
die.** All fixed in source; the cold rebuild above hits none of them.

| # | Symptom | Diagnosis | Recovery (now in source) |
|---|---|---|---|
| 1 | Spark worker crash-loops: `ERROR Utils: Failed to create directory /opt/spark/work` (`AccessDeniedException`) | The worker work dir defaults under `$SPARK_HOME` = `/opt/spark` (root-owned symlinked install); the worker runs as `spark` | `spark-env.sh`: `export SPARK_WORKER_DIR=/var/lib/spark/work` (the spark-owned data dir). |
| 2 | Bootstrap/smoke "no ALIVE master"/UI checks fail though the master is up | The Master/Worker Web UI binds to `SPARK_LOCAL_IP` (the node VMnet11 IP), **not** localhost | Query the master UI by node IP (`http://<ip>:8080/json/`), not `localhost`. |
| 3 | SparkContext init: `java.lang.IllegalArgumentException: path must be absolute` (S3Guard `PathMetadata`) | `spark.eventLog.dir=s3a://spark-events` (bucket-root via hadoop-S3A) hits an S3Guard root-path quirk | eventLog disabled (`spark.eventLog.enabled=false`); the deliverable is the Iceberg write, history-server is deferred. |
| 4 | Nessie REST: `Server error: IllegalStateException: Warehouse 's3a://warehouse' is not known` | The Iceberg REST `warehouse` config must be the **name** Nessie registered, not a URI | `spark.sql.catalog.nexus.warehouse=warehouse` (the name); Nessie owns the location + server-side S3 config. |
| 5 | `Cannot initialize FileIO … S3FileIO … NoClassDefFoundError software/amazon/awssdk/.../S3Exception` | Iceberg `S3FileIO` needs **AWS SDK v2**; only `aws-java-sdk-bundle` (v1, for hadoop-S3A) was installed | Bake `iceberg-aws-bundle-1.7.1.jar` into the spark template's `/opt/spark/jars`. |
| 6 | INSERT fails booting an embedded Apache Derby Hive metastore | spark-sql defaults `spark.sql.catalogImplementation=hive` for the *default* catalog (`spark_catalog`) even when all tables live in `nexus` | `spark.sql.catalogImplementation=in-memory` (no Hive/Derby; the `nexus` Iceberg catalog is unaffected). |
| 7 | Executors exit code 1; driver-url is `…@spark-master.nexus.lab:<port>` | The node's reverse DNS resolves to the **round-robin** `spark-master.nexus.lab` (both masters), so executors dialed the wrong master | `spark.driver.host`/`spark.driver.bindAddress` = the node's own VMnet11 IP (`SPARK_LOCAL_IP`). |
| 8 | **Every job hangs**: "Initial job has not accepted any resources" with 6 cores free; executors launch + exit 1 (empty stderr); `nft` drop counter climbing | nftables opened only the *fixed* Spark ports (7077/8080/8081), not the **dynamic** `spark.driver.port`/`blockManager.port` executors dial back on → executors can't register | nftables: accept all TCP between the 5 Spark-node VMnet11 IPs (one trust domain). ([feedback_spark_standalone_executor_rpc_firewall]) |
| 9 | `nft -f` fails: `Error: comment too long, 128 characters maximum allowed` | An nftables rule `comment` exceeded the 128-char cap | Shortened the peer-rule comment. |
| 10 | Smoke "namespace not present via Iceberg REST" though the table exists | Nessie scopes Iceberg-REST namespaces under the prefix `{ref}|{warehouse}` (`main%7Cwarehouse`); a bare `/v1/namespaces` is empty; curl also needs `--cacert` | Smoke queries `/iceberg/v1/main%7Cwarehouse/namespaces` with `--cacert` the Vault Agent CA bundle. |
| — | `vmrun start` sporadic `Unknown error` on fresh clones | VMware-under-load flake | Re-run apply; tainted clones retry cleanly. ([feedback_vmrun_unknown_error_transient]) |
