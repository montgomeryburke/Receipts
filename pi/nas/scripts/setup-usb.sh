#!/usr/bin/env bash
# Mount the attached USB drive at /srv/nas and make the mount survive reboots.
#
# This script never formats a drive unless you pass --format and confirm at the
# prompt. Whatever filesystem is already on the stick is used as-is.
set -euo pipefail

MOUNT_POINT=${MOUNT_POINT:-/srv/nas}
SERVICE_USER=${SERVICE_USER:-pinas}
DO_FORMAT=0
DEVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --format) DO_FORMAT=1; shift ;;
    --device) DEVICE=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"

# ---------------------------------------------------------------- find the stick
# A USB partition is one whose parent disk reports TRAN=usb. Picking the largest
# such partition is right for the common case of a single-partition drive and
# for a drive with a small EFI/boot partition alongside the data one.
find_usb_partition() {
  lsblk -rpno NAME,TYPE,TRAN,SIZE,MOUNTPOINT |
    awk '$2=="disk" && $3=="usb" {disk=$1} $2=="part" && index($1,disk)==1 {print $1, $4}' |
    sort -k2 -h | tail -1 | awk '{print $1}'
}

if [[ -z $DEVICE ]]; then
  DEVICE=$(find_usb_partition || true)
  [[ -n $DEVICE ]] || die "No USB partition found. Plug the drive in, wait 5s, and rerun.
Devices currently seen:
$(lsblk -o NAME,SIZE,TRAN,FSTYPE,MOUNTPOINT)"
fi

[[ -b $DEVICE ]] || die "$DEVICE is not a block device"

# Refuse to touch the disk the Pi booted from — the single most costly mistake
# this script could make.
ROOT_SOURCE=$(findmnt -no SOURCE / || true)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null || true)
TARGET_DISK=$(lsblk -no PKNAME "$DEVICE" 2>/dev/null || true)
if [[ -n $ROOT_DISK && $ROOT_DISK == "$TARGET_DISK" ]]; then
  die "$DEVICE lives on the boot disk ($ROOT_DISK). Refusing to use it."
fi

say "Using $DEVICE ($(lsblk -no SIZE "$DEVICE" | tr -d ' '))"

# ---------------------------------------------------------------------- format
if [[ $DO_FORMAT -eq 1 ]]; then
  warn "This ERASES everything on $DEVICE."
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
  read -rp "Type ERASE to continue: " confirm
  [[ $confirm == "ERASE" ]] || die "aborted"
  umount "$DEVICE" 2>/dev/null || true
  apt-get install -y -qq e2fsprogs
  # ext4 is the right choice here: native permissions and no fsck-on-every-boot
  # surprises. The drive is only ever read over the network, not plugged into a
  # Windows machine, so cross-platform formats buy nothing.
  mkfs.ext4 -F -L NAS "$DEVICE"
fi

FSTYPE=$(blkid -o value -s TYPE "$DEVICE" || true)
UUID=$(blkid -o value -s UUID "$DEVICE" || true)
[[ -n $FSTYPE ]] || die "$DEVICE has no filesystem. Rerun with --format to create one."
[[ -n $UUID ]] || die "$DEVICE has no UUID; cannot write a stable fstab entry."

say "Filesystem: $FSTYPE  UUID: $UUID"

# --------------------------------------------------------- filesystem packages
case $FSTYPE in
  exfat) apt-get install -y -qq exfatprogs ;;
  ntfs|ntfs3) apt-get install -y -qq ntfs-3g ;;
  vfat)  apt-get install -y -qq dosfstools ;;
esac

# ------------------------------------------------------------------ mount opts
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
UID_N=$(id -u "$SERVICE_USER")
GID_N=$(id -g "$SERVICE_USER")

case $FSTYPE in
  # These filesystems carry no Unix ownership, so it is assigned at mount time.
  exfat|vfat|ntfs|ntfs3)
    OPTS="uid=$UID_N,gid=$GID_N,umask=0007,nofail,x-systemd.device-timeout=30" ;;
  *)
    OPTS="defaults,noatime,nofail,x-systemd.device-timeout=30" ;;
esac

mkdir -p "$MOUNT_POINT"

# ---------------------------------------------------------------------- fstab
# Keyed by UUID so the mount is stable no matter which USB port is used or what
# order devices enumerate in.
FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  $FSTYPE  $OPTS  0  2"
cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
if grep -q "[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab; then
  say "Replacing existing $MOUNT_POINT entry in /etc/fstab"
  sed -i "\|[[:space:]]$MOUNT_POINT[[:space:]]|d" /etc/fstab
fi
echo "$FSTAB_LINE" >> /etc/fstab
say "Added to /etc/fstab: $FSTAB_LINE"

systemctl daemon-reload
mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT"
mount "$MOUNT_POINT" || die "mount failed — /etc/fstab has been restored to a backup in /etc/"

# Ownership only applies to filesystems that store it.
case $FSTYPE in
  exfat|vfat|ntfs|ntfs3) : ;;
  *) chown "$SERVICE_USER:$SERVICE_USER" "$MOUNT_POINT"; chmod 0770 "$MOUNT_POINT" ;;
esac

say "Mounted:"
df -h "$MOUNT_POINT" | tail -1
