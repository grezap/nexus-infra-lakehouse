# Changelog

All notable changes to `nexus-infra-lakehouse` are documented here. Format per
[Keep a Changelog](https://keepachangelog.com/); this repo is the NexusPlatform
lakehouse tier (`08-spark`), Phase 0.L.

## [Unreleased]

### Added — Phase 0.L.1 (MinIO distributed erasure-coded object store)

- Repo scaffold on the per-cluster-state + per-engine-template canon: shared
  ansible roles (`nexus_identity`, `nexus_network`, `nexus_firewall`,
  `nexus_observability`, `lakehouse_firstboot`), reusable `terraform/modules/vm`
  clone driver, 5-job CI (`packer-validate.yml`).
- `lakehouse_firstboot` shared role — NIC discovery (MAC OUI byte-5), IP→role
  map for all 11 lakehouse nodes (MinIO .141–.144, Spark .140/.145/.146, Iceberg
  REST .147/.148, Iceberg PG .149/.150), VMnet10 backplane config, node-identity
  env, PG primary/replica derivation.
- `packer/lakehouse-minio-node` — Debian 13 + MinIO server + mc client; dedicated
  data VMDK formatted xfs (label `minio-data`, `/mnt/minio/data`);
  `nexus-minio.service` delivered DISABLED.
- `terraform/envs/lakehouse-minio` — 4-node MinIO cluster + 5 overlays:
  nftables-backplane, vault-agents, tls (`public.crt`/`private.key`/`CAs`),
  config (render `minio.conf` from Vault KV + start the erasure set), and
  bucket-bootstrap (warehouse/spark-events/lakehouse buckets + `nexus-lakehouse-app`
  service account + erasure-health + object round-trip exit gate).
- Operator wrapper `scripts/lakehouse-minio.ps1` + smoke gate `scripts/smoke-0.L.1.ps1`.
- Cross-tier overlays in `nexus-infra-vmware`: foundation
  (`role-overlay-gateway-lakehouse-{reservations,dns}.tf`) + security
  (`role-overlay-vault-pki-minio.tf`, `role-overlay-vault-agent-minio-{policies,approles}.tf`,
  `role-overlay-vault-minio-creds-seed.tf`).
- ADR-0033 (MinIO distributed EC object storage; supersedes ADR-0032's
  "MinIO deferred" note) in `nexus-platform-plan`.
