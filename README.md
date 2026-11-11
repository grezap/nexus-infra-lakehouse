# nexus-infra-lakehouse

NexusPlatform **lakehouse tier** (`08-spark`) — Phase 0.L. Object storage, table
format, and compute for the medallion lakehouse: **MinIO** (S3-compatible,
distributed erasure-coded) + **Apache Iceberg** (REST catalog on a dedicated HA
Postgres) + **Apache Spark** (HA: 2 ZooKeeper-elected masters + 3 workers). Part of the
[NexusPlatform](https://github.com/grezap) portfolio; built on the per-cluster
Terraform state + per-engine Packer template canon.

> Status: **Phase 0.L lakehouse tier SEALED 2026-05-26 — `v0.1.0` tagged.**
> 0.L.1 (MinIO), 0.L.2 (Iceberg/Nessie + dedicated PG HA), 0.L.3 (Spark HA +
> ZooKeeper) all live-ratified + cold-rebuild-proven (smoke gates 41/41 ·
> 28/28 · 28/28 GREEN; ADRs 0033-0035). Harbor ships in the sibling repo
> [`nexus-infra-registry`](https://github.com/grezap/nexus-infra-registry)
> (`v0.1.0`). The StarRocks shared-data/CN tier extends
> [`nexus-infra-analytics`](https://github.com/grezap/nexus-infra-analytics)
> (`v0.2.0`, ADR-0037) — the lakehouse-minio env hosts its dedicated tenant
> (bucket `starrocks` + scoped policy).

## Sub-phases

| Sub-phase | Cluster | Nodes | VMnet11 | Exit gate |
|---|---|---|---|---|
| **0.L.1** | MinIO distributed EC | 4 (minio-1..4) | .141–.144 | buckets created · 4 online drives · object round-trip · node-loss tolerant |
| 0.L.2 | Iceberg REST catalog + dedicated PG HA | 2 REST + 2 PG (+VIP) | .147–.151 | namespace/table via REST · metadata in PG · warehouse in MinIO |
| 0.L.3 | Apache Spark HA + ZooKeeper | 2 masters + 3 workers + 3 ZK (8) | .140·.153 / .145·.146·.154 / .155–.157 | Spark job writes Iceberg table to MinIO · snapshot/time-travel query · ZK-elected master failover |

**Tier total: 16 VMs + 1 VIP** (4 MinIO + 2 Iceberg REST + 2 Iceberg PG + 2 Spark masters + 3 Spark workers + 3 ZooKeeper; catalog-DB VRRP VIP `.151`).

## Architecture (0.L.1 — MinIO)

- **4-node distributed erasure-coded** cluster (ADR-0033). Each node has a
  dedicated xfs data drive (`/mnt/minio/data`); the erasure set spans all 4
  (`MINIO_VOLUMES=https://192.168.10.{141...144}:9000/mnt/minio/data`). Default
  EC:2 — tolerates 1 node down read-write, 2 nodes down read-only.
- **Backplane/service split:** inter-node erasure/heal/lock traffic on the
  VMnet10 backplane; client S3 API (`minio.nexus.lab:9000`) + Console
  (`minio-N.nexus.lab:9001`) on VMnet11.
- **No VIP** — client front door is round-robin DNS `minio.nexus.lab` over the 4
  nodes (ADR-0031/0033). Per-host Vault PKI leaf certs carry `minio.nexus.lab`
  in their SANs so verify-full validates whichever node answers.
- **mTLS** via per-host Vault PKI (`minio-server` role); root + app S3 creds
  sticky-seeded in Vault KV (`nexus/lakehouse/minio/*`); the least-priv
  `nexus-lakehouse-app` service account is consumed by 0.L.2 + 0.L.3.

## Cross-tier prerequisites (run in `nexus-infra-vmware` FIRST)

1. **foundation** env apply — dhcp-host reservations for the 16 lakehouse MACs
   (`:99`–`:A3` for 0.L.1/0.L.2 + `:AA`–`:AE` for the 0.L.3 Spark-HA + ZooKeeper nodes)
   + round-robin DNS `minio.nexus.lab` / `iceberg.nexus.lab` + the catalog VIP `.151`.
2. **security** env apply — `minio-server` PKI role + 4 per-host AppRole sidecars
   + KV sticky-seeds at `nexus/lakehouse/minio/*`.

The 6 foundation VMs (`nexus-gateway`, `dc-nexus`, `vault-1/2/3`,
`vault-transit`) must be running.

## Quick start (0.L.1)

```powershell
# 1. cross-tier prereqs (in nexus-infra-vmware)
pwsh -File scripts\foundation.ps1 apply
pwsh -File scripts\security.ps1   apply

# 2. build the MinIO template
cd packer\lakehouse-minio-node; packer init .; packer build -var "iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso" .

# 3. bring up + verify the cluster
pwsh -File scripts\lakehouse-minio.ps1 apply
pwsh -File scripts\smoke-0.L.1.ps1
```

After 0.L.1, bring up 0.L.2 then 0.L.3 the same way — `pwsh -File scripts\lakehouse-iceberg.ps1 apply` + `smoke-0.L.2.ps1`, then `pwsh -File scripts\lakehouse-spark.ps1 apply` + `smoke-0.L.3.ps1` (full from-zero order in `docs/handbook.md`).

Selective ops: every node + overlay has an `enable_*` toggle (see
`docs/handbook.md` §1.5).

## Repo layout

```
packer/_shared/ansible/roles/       shared roles (incl. lakehouse_firstboot)
packer/lakehouse-minio-node/        MinIO per-engine template (0.L.1)
packer/lakehouse-iceberg-rest-node/ Iceberg/Nessie REST catalog template (0.L.2)
packer/lakehouse-iceberg-pg-node/   Iceberg catalog PostgreSQL HA template (0.L.2)
packer/lakehouse-spark-node/        Spark master/worker template (0.L.3)
packer/lakehouse-zookeeper-node/    ZooKeeper ensemble template (0.L.3)
terraform/modules/vm/               reusable vmrun clone driver
terraform/envs/lakehouse-minio/     MinIO per-cluster state + overlays (0.L.1)
terraform/envs/lakehouse-iceberg/   Iceberg REST + PG HA per-cluster state (0.L.2)
terraform/envs/lakehouse-spark/     Spark HA + ZooKeeper per-cluster state (0.L.3)
scripts/lakehouse-minio.ps1         MinIO operator wrapper (apply/destroy/smoke/cycle)
scripts/lakehouse-iceberg.ps1       Iceberg operator wrapper (0.L.2)
scripts/lakehouse-spark.ps1         Spark + ZooKeeper operator wrapper (0.L.3)
scripts/smoke-0.L.{1,2,3}.ps1       per-sub-phase exit-gate smokes
docs/handbook.md                    from-zero rebuild guide + runbooks
docs/adr/                           repo-local ADR index (shared ADRs in nexus-platform-plan)
```

## Links

- Master plan + canon: [`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan)
- Operator handbook: [`docs/handbook.md`](docs/handbook.md)
- Shared ADRs 0033–0037 (lakehouse): `nexus-platform-plan/docs/adr/`

License: MIT © Greg Zapantis
