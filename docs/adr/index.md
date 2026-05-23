# ADR index — nexus-infra-lakehouse

This repo's architectural decisions are **shared ADRs** owned by
[`nexus-platform-plan`](https://github.com/grezap/nexus-platform-plan/tree/main/docs/adr)
(the lakehouse tier touches cross-tier canon: networking, Vault PKI, vms.yaml).

| ID | Title | Status |
|---|---|---|
| [0031](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0031-analytics-client-front-door-round-robin-dns.md) | Client front door — round-robin DNS, no VRRP VIP | accepted |
| [0033](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0033-minio-distributed-erasure-coded-object-storage.md) | Phase 0.L.1: MinIO distributed erasure-coded object storage | accepted |
| 0034 | Phase 0.L.2: Iceberg REST catalog + dedicated PG master-replica HA | planned |
| 0035 | Phase 0.L.3: Spark Standalone topology + S3A/Iceberg integration | planned |

Per-repo notes, transient chronologies, and the from-zero rebuild guide live in
[`docs/handbook.md`](../handbook.md).
