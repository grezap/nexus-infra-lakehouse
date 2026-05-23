# nexus-infra-lakehouse — operator handbook

The from-absolute-zero rebuild guide for the lakehouse tier (`08-spark`), Phase
0.L. Canon, not informal. An operator (or future-Greg after a break) can rebuild
this tier with no external knowledge from this document.

> Coverage: **0.L.1 (MinIO) — complete + cold-rebuild proven.** §1.2/§1.3 (Iceberg
> REST + dedicated PG HA) and §1.4 (Spark) are added as those sub-phases land.

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
  (`:99`–`:A3` → `.140`–`.150`) + round-robin DNS `minio.nexus.lab`
  (`role-overlay-gateway-lakehouse-{reservations,dns}.tf`).
- **security env** — `minio-server` PKI role + 4 per-host AppRole sidecars at
  `$HOME/.nexus/vault-agent-lakehouse-minio-minio-{1..4}.json` + KV sticky-seeds
  at `nexus/lakehouse/minio/{root-user,root-password,app-access-key,app-secret-key}`
  (field `value`) — `role-overlay-vault-pki-minio.tf`,
  `role-overlay-vault-agent-minio-{policies,approles}.tf`,
  `role-overlay-vault-minio-creds-seed.tf`.

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

---

## §2 Phase status

| Sub-phase | Cluster | Closed | Smoke |
|---|---|---|---|
| 0.L.1 | MinIO distributed EC (4 nodes) | 2026-05-23 (live-ratified + cold-rebuild proven) | `smoke-0.L.1.ps1` 41/41 |
| 0.L.2 | Iceberg REST + dedicated PG HA | pending | — |
| 0.L.3 | Apache Spark | pending | — |

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
