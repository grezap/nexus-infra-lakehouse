#!/bin/bash
# lakehouse-node-firstboot.sh -- runs once at first boot per lakehouse-node clone.
#
# Linear port of analytics-node-firstboot.sh (nexus-infra-analytics), scaled to
# the 08-spark lakehouse tier. Same NIC discrimination by MAC OUI byte 5 (0x00
# primary VMnet11, 0x01 secondary VMnet10), same /etc/hosts pattern, same
# hostname renaming, same VMnet10 backplane .link MAC-match.
#
# IP-to-role map covers ALL lakehouse-tier clusters (Phase 0.L):
#   - MinIO:        4 nodes (.141-.144)         distributed erasure-coded object store
#   - Spark:        2 masters (.140/.153, HA) + 3 workers (.145/.146/.154)
#   - ZooKeeper:    3-node quorum (.155-.157)   coordinates Spark master HA election
#   - Iceberg REST: 2 catalog instances (.147-.148)
#   - Iceberg PG:   1 primary (.149) + 1 replica (.150)  dedicated catalog metadata DB
# A clone landing on an unmapped IP fails fast with a clear error.
#
# This script does NOT enable any role service. The Terraform role-overlays
# render per-host config (MinIO server peer set, Spark master/worker join,
# Iceberg REST catalog config, PG streaming replication + keepalived VIP) and
# enable exactly one role service per node post-apply.
#
# For Iceberg PG nodes it additionally parses primary/replica from the hostname
# (iceberg-pg-1 = primary, iceberg-pg-2 = replica) and emits NEXUS_PG_ROLE into
# node-identity.env so the replication overlay can configure each node without
# per-node SQL.
#
# Idempotent: marker at /var/lib/lakehouse-node-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/lakehouse-node-firstboot-done
LOG_PREFIX="[lakehouse-node-firstboot]"
IDENTITY_DIR=""
IDENTITY_FILE=""

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX ERROR: no secondary NIC (MAC pattern 00:50:56:*:01:*) found -- lakehouse tier requires the VMnet10 backplane" >&2
  ip -br link >&2
  exit 1
fi

# ─── 2. Ensure nic0 == primary, nic1 == secondary ──────────────────────────
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

if [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 DHCP ─────────────────────────────────────────────────
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  ip -br addr show nic0 >&2 || true
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map IP -> hostname + VMnet10 IP + role + cluster ─────────────────
# Canon: nexus-platform-plan/docs/infra/vms.yaml (cluster: minio + cluster:
# spark + cluster: iceberg). Convention: VMnet10 fourth octet matches VMnet11
# (the lakehouse tier shares the .14x decade across all three clusters).
HOSTNAME=""; VMNET10_IP=""; ROLE=""; CLUSTER=""
case "$VMNET11_IP" in
  # ─── 0.L.3 -- Spark HA masters (2 nodes, ZK-elected) ──────────────────
  192.168.70.140) HOSTNAME=spark-master-1; VMNET10_IP=192.168.10.140; ROLE=spark-master; CLUSTER=spark ;;
  192.168.70.153) HOSTNAME=spark-master-2; VMNET10_IP=192.168.10.153; ROLE=spark-master; CLUSTER=spark ;;

  # ─── 0.L.1 -- MinIO distributed erasure-coded cluster (4 nodes) ────────
  192.168.70.141) HOSTNAME=minio-1; VMNET10_IP=192.168.10.141; ROLE=minio; CLUSTER=minio ;;
  192.168.70.142) HOSTNAME=minio-2; VMNET10_IP=192.168.10.142; ROLE=minio; CLUSTER=minio ;;
  192.168.70.143) HOSTNAME=minio-3; VMNET10_IP=192.168.10.143; ROLE=minio; CLUSTER=minio ;;
  192.168.70.144) HOSTNAME=minio-4; VMNET10_IP=192.168.10.144; ROLE=minio; CLUSTER=minio ;;

  # ─── 0.L.3 -- Spark workers (3 nodes) ─────────────────────────────────
  192.168.70.145) HOSTNAME=spark-worker-1; VMNET10_IP=192.168.10.145; ROLE=spark-worker; CLUSTER=spark ;;
  192.168.70.146) HOSTNAME=spark-worker-2; VMNET10_IP=192.168.10.146; ROLE=spark-worker; CLUSTER=spark ;;
  192.168.70.154) HOSTNAME=spark-worker-3; VMNET10_IP=192.168.10.154; ROLE=spark-worker; CLUSTER=spark ;;

  # ─── 0.L.2 -- Iceberg REST catalog (2 HA instances) ───────────────────
  192.168.70.147) HOSTNAME=iceberg-rest-1; VMNET10_IP=192.168.10.147; ROLE=iceberg-rest; CLUSTER=iceberg ;;
  192.168.70.148) HOSTNAME=iceberg-rest-2; VMNET10_IP=192.168.10.148; ROLE=iceberg-rest; CLUSTER=iceberg ;;

  # ─── 0.L.2 -- Iceberg catalog PG (1 primary + 1 replica) ──────────────
  192.168.70.149) HOSTNAME=iceberg-pg-1; VMNET10_IP=192.168.10.149; ROLE=iceberg-pg; CLUSTER=iceberg ;;
  192.168.70.150) HOSTNAME=iceberg-pg-2; VMNET10_IP=192.168.10.150; ROLE=iceberg-pg; CLUSTER=iceberg ;;

  # ─── 0.L.3 -- ZooKeeper quorum (3 nodes, Spark master-HA coordination) ─
  192.168.70.155) HOSTNAME=zookeeper-1; VMNET10_IP=192.168.10.155; ROLE=zookeeper; CLUSTER=spark ;;
  192.168.70.156) HOSTNAME=zookeeper-2; VMNET10_IP=192.168.10.156; ROLE=zookeeper; CLUSTER=spark ;;
  192.168.70.157) HOSTNAME=zookeeper-3; VMNET10_IP=192.168.10.157; ROLE=zookeeper; CLUSTER=spark ;;

  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' -- not an 08-spark lakehouse tier IP" >&2
    echo "$LOG_PREFIX recognised IPs: spark-master-1/2 (.140/.153); minio-1..4 (.141-.144); spark-worker-1..3 (.145/.146/.154); iceberg-rest-1..2 (.147/.148); iceberg-pg-1..2 (.149/.150); zookeeper-1..3 (.155-.157)." >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME role=$ROLE cluster=$CLUSTER VMnet10=$VMNET10_IP/24"

# Derive per-ROLE identity dir + owning group. The owning group is created by
# the role's Packer task (minio for MinIO; spark for Spark; iceberg for the
# REST catalog; postgres for the catalog PG).
case "$ROLE" in
  minio)        IDENTITY_DIR=/etc/nexus-minio;        IDENTITY_GROUP=minio     ;;
  spark-master) IDENTITY_DIR=/etc/nexus-spark;        IDENTITY_GROUP=spark     ;;
  spark-worker) IDENTITY_DIR=/etc/nexus-spark;        IDENTITY_GROUP=spark     ;;
  zookeeper)    IDENTITY_DIR=/etc/nexus-zookeeper;    IDENTITY_GROUP=zookeeper ;;
  iceberg-rest) IDENTITY_DIR=/etc/nexus-iceberg-rest; IDENTITY_GROUP=iceberg   ;;
  iceberg-pg)   IDENTITY_DIR=/etc/nexus-iceberg-pg;   IDENTITY_GROUP=postgres  ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown ROLE '$ROLE' -- no identity dir mapping" >&2
    exit 1
    ;;
esac
IDENTITY_FILE="$IDENTITY_DIR/node-identity.env"

# For Iceberg catalog PG nodes, parse primary/replica from the hostname
# (iceberg-pg-1 = primary, iceberg-pg-2 = replica) so the replication overlay
# can configure each node without per-node SQL.
PG_ROLE=""
if [ "$ROLE" = "iceberg-pg" ]; then
  case "$HOSTNAME" in
    iceberg-pg-1) PG_ROLE=primary ;;
    iceberg-pg-2) PG_ROLE=replica ;;
    *)
      echo "$LOG_PREFIX ERROR: could not derive PG role from hostname '$HOSTNAME'" >&2
      exit 1
      ;;
  esac
  echo "$LOG_PREFIX iceberg catalog PG role: $PG_ROLE"
fi

# For ZooKeeper nodes, derive the ensemble member id from the hostname
# (zookeeper-N -> myid N) so the ensemble overlay can write /var/lib/zookeeper/myid
# without per-node config.
ZK_ID=""
if [ "$ROLE" = "zookeeper" ]; then
  ZK_ID="${HOSTNAME##*-}"
  case "$ZK_ID" in
    1|2|3) ;;
    *)
      echo "$LOG_PREFIX ERROR: could not derive ZooKeeper id from hostname '$HOSTNAME'" >&2
      exit 1
      ;;
  esac
  echo "$LOG_PREFIX ZooKeeper ensemble id: $ZK_ID"
fi

# ─── 5. Hostname + /etc/hosts ──────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
fi

# Per memory/feedback_smoke_gate_probe_robustness.md: every Linux first-boot
# must write /etc/hosts entry for the new hostname or sudo emits "unable to
# resolve host" stderr noise on every invocation.
HOSTS_LINE="127.0.1.1 $HOSTNAME.nexus.lab $HOSTNAME"
sed -i '/^127\.0\.1\.1\s/d' /etc/hosts
echo "$HOSTS_LINE" >> /etc/hosts
echo "$LOG_PREFIX wrote /etc/hosts entry: $HOSTS_LINE"

# ─── 6. VMnet10 backplane config (.link MAC-match + .network static) ───────
echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

# Per memory/feedback_systemd_link_precedence_multi_nic.md -- rewrite the
# baseline 10-nic0.link to MAC-match the primary NIC instead of the greedy
# OriginalName=en* match. Without this, on every reboot AFTER firstboot the
# udev lex-order match leaves nic1 on its kernel-default name, the static
# .network never applies, the backplane has no IP.
if [ -f /etc/systemd/network/10-nic0.link ] && ! grep -q "^MACAddress=$PRIMARY_MAC" /etc/systemd/network/10-nic0.link; then
  echo "$LOG_PREFIX rewriting 10-nic0.link to MAC-match primary"
  cat > /etc/systemd/network/10-nic0.link <<EOF
[Match]
MACAddress=$PRIMARY_MAC

[Link]
Name=nic0
EOF
  udevadm control --reload 2>/dev/null || true
fi

ip link set nic1 up 2>/dev/null || true
if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
  ip addr add "$VMNET10_IP/24" dev nic1 || true
fi
systemctl restart systemd-networkd
sleep 3

# ─── 7. Write the node-identity env file for the Terraform role-overlays ───
mkdir -p "$IDENTITY_DIR"
{
  echo "# Generated by lakehouse-node-firstboot.sh -- do not edit by hand."
  echo "NEXUS_HOSTNAME=$HOSTNAME"
  echo "NEXUS_ROLE=$ROLE"
  echo "NEXUS_CLUSTER=$CLUSTER"
  echo "NEXUS_VMNET11_IP=$VMNET11_IP"
  echo "NEXUS_VMNET10_IP=$VMNET10_IP"
  if [ "$ROLE" = "iceberg-pg" ]; then
    echo "NEXUS_PG_ROLE=$PG_ROLE"
  fi
  if [ "$ROLE" = "zookeeper" ]; then
    echo "NEXUS_ZK_ID=$ZK_ID"
  fi
} > "$IDENTITY_FILE"
chown "root:$IDENTITY_GROUP" "$IDENTITY_FILE"
chmod 640 "$IDENTITY_FILE"
echo "$LOG_PREFIX wrote $IDENTITY_FILE (group=$IDENTITY_GROUP)"

# ─── 8. Mark complete ──────────────────────────────────────────────────────
# No role service is enabled here -- the Terraform role-overlays render the
# per-host config (MinIO server peer set, Spark master/worker join, Iceberg
# REST catalog config, PG streaming replication + keepalived VIP) then enable
# exactly one role service per node post-apply.
touch "$MARKER"
echo "$LOG_PREFIX done -- $HOSTNAME ready ($ROLE role in $CLUSTER cluster on VMnet11 $VMNET11_IP / VMnet10 $VMNET10_IP)"
