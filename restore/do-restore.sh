#!/usr/bin/env bash
set -euo pipefail

# Require root privileges
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)."
  echo "Run again with: sudo $0"
  exit 1
fi

# --------------------------------------------------
#  Restic disk restore (UUID-preserving, LUKS-aware)
#
#  Assumes backup script stored in /var/backups/system-meta:
#    - system_disk.txt
#    - disk-size-bytes.txt
#    - disk.gpt
#    - blkid.txt
#    - boot.tar         (from /boot)
#    - boot-efi.tar     (optional, from /boot/efi)
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/restore.conf"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

part_path() {
  # $1 = whole disk (/dev/nvme0n1 or /dev/sda)
  # $2 = partition number (1, 2, ...)
  local disk="$1"
  local num="$2"
  case "${disk}" in
    *nvme*|*mmcblk*|*nbd*)
      printf '%sp%s' "${disk}" "${num}"
      ;;
    *)
      printf '%s%s' "${disk}" "${num}"
      ;;
  esac
}

# ------------- Load config -------------
[[ -f "${CONFIG_FILE}" ]] || die "Config file ${CONFIG_FILE} not found."
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

BACKUP_SERVER_USER="${BACKUP_SERVER_USER:-}"
[[ -n "${BACKUP_SERVER_HOST:-}"    ]] || die "BACKUP_SERVER_HOST missing in config"
[[ -n "${BACKUP_BASE_PATH:-}"      ]] || die "BACKUP_BASE_PATH missing in config"
[[ -n "${REPO_NAME:-}"             ]] || die "REPO_NAME missing in config"
[[ -n "${TARGET_DISK:-}"           ]] || die "TARGET_DISK missing in config"
SNAPSHOT="${SNAPSHOT:-latest}"

# Build restic repo URL
if [[ -n "${BACKUP_SERVER_USER}" ]]; then
  RESTIC_REPO="sftp:${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}:${BACKUP_BASE_PATH}/${REPO_NAME}"
else
  RESTIC_REPO="sftp:${BACKUP_SERVER_HOST}:${BACKUP_BASE_PATH}/${REPO_NAME}"
fi

RESTORE_ROOT="/tmp/restic-system-restore"
META_DIR_REL="/var/backups/system-meta"
META_DIR="${RESTORE_ROOT}${META_DIR_REL}"

# Force interactive password prompt for restic
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND RESTIC_PASSWORD_FILE

# ------------- Safety checks -------------

[[ -b "${TARGET_DISK}" ]] || die "TARGET_DISK ${TARGET_DISK} is not a block device."

echo "=============================================================="
echo "  DANGER: YOU ARE ABOUT TO WIPE DISK: ${TARGET_DISK}"
echo "  All data on this disk will be destroyed and replaced with"
echo "  a restored system from:"
echo "      ${RESTIC_REPO}"
echo "  Snapshot: ${SNAPSHOT}"
echo "=============================================================="
read -r -p "Type EXACTLY 'YES' to continue: " answer
if [[ "${answer}" != "YES" ]]; then
  die "User aborted restore."
fi

log "Checking that ${TARGET_DISK} has no partitions..."

# Refuse if disk already has partitions
if lsblk -no NAME,TYPE "${TARGET_DISK}" | awk '$2=="part"' | grep -q .; then
  die "Target disk has partitions. Refusing. Use gparted or wipefs to clear them."
fi

log "No partitions detected on ${TARGET_DISK} (GPT/MBR leftovers ignored). Proceeding."

# ------------- Step 1: restore metadata only -------------

log "Cleaning restore root: ${RESTORE_ROOT}"
rm -rf "${RESTORE_ROOT}"
mkdir -p "${RESTORE_ROOT}"

log "Restoring metadata (${META_DIR_REL}) from restic snapshot=${SNAPSHOT}"
restic restore "${SNAPSHOT}" \
  -r "${RESTIC_REPO}" \
  --target "${RESTORE_ROOT}" \
  --include "${META_DIR_REL}"

[[ -d "${META_DIR}" ]] || die "Metadata directory ${META_DIR} not found after restore."

# Original system disk path
if [[ -f "${META_DIR}/system_disk.txt" ]]; then
  SYSTEM_DISK_ORIG="$(< "${META_DIR}/system_disk.txt")"
else
  die "system_disk.txt missing in metadata; backup script must write it."
fi

log "Original system disk (at backup time): ${SYSTEM_DISK_ORIG}"

# Disk size check
if [[ -f "${META_DIR}/disk-size-bytes.txt" ]]; then
  ORIGINAL_SIZE_BYTES="$(< "${META_DIR}/disk-size-bytes.txt")"
  [[ "${ORIGINAL_SIZE_BYTES}" =~ ^[0-9]+$ ]] || die "Invalid original size in disk-size-bytes.txt"

  TARGET_SIZE_BYTES="$(blockdev --getsize64 "${TARGET_DISK}")"
  [[ "${TARGET_SIZE_BYTES}" =~ ^[0-9]+$ ]] || die "Could not read target disk size"

  log "Original disk size: ${ORIGINAL_SIZE_BYTES} bytes"
  log "Target   disk size: ${TARGET_SIZE_BYTES} bytes"

  if (( TARGET_SIZE_BYTES < ORIGINAL_SIZE_BYTES )); then
    die "Target disk is smaller than original. Refusing to restore."
  fi
else
  log "WARNING: No disk-size-bytes.txt in metadata; skipping size check."
fi

# GPT backup file
GPT_FILE="${META_DIR}/disk.gpt"
[[ -f "${GPT_FILE}" ]] || die "GPT backup file disk.gpt not found in metadata."

# ------------- Step 2: apply GPT to target disk -------------

log "Writing GPT layout from ${GPT_FILE} to ${TARGET_DISK}"
sgdisk --load-backup="${GPT_FILE}" "${TARGET_DISK}"

log "Reloading partition table"
partprobe "${TARGET_DISK}" || true
sleep 2

ROOT_PART_ORIG="$(part_path "${SYSTEM_DISK_ORIG}" 2)"
EFI_PART_ORIG="$(part_path "${SYSTEM_DISK_ORIG}" 1)"

ROOT_PART="$(part_path "${TARGET_DISK}" 2)"
EFI_PART="$(part_path "${TARGET_DISK}" 1)"

[[ -b "${EFI_PART}"  ]] || die "EFI partition ${EFI_PART} not found after GPT restore."
[[ -b "${ROOT_PART}" ]] || die "Root partition ${ROOT_PART} not found after GPT restore."

log "EFI partition (new):  ${EFI_PART}"
log "Root partition (new): ${ROOT_PART}"

# ------------- Step 3: read original UUIDs / FS types -------------

BLKID_META="${META_DIR}/blkid.txt"
[[ -f "${BLKID_META}" ]] || die "blkid.txt missing in metadata."

ROOT_LINE_ORIG="$(grep -E "^${ROOT_PART_ORIG}:" "${BLKID_META}" || true)"
[[ -n "${ROOT_LINE_ORIG}" ]] || die "Cannot find root partition ${ROOT_PART_ORIG} in blkid metadata."

ORIGINAL_PART_TYPE="$(sed -E 's/.*TYPE="([^"]+)".*/\1/' <<< "${ROOT_LINE_ORIG}")"
[[ -n "${ORIGINAL_PART_TYPE}" ]] || die "Cannot extract TYPE from blkid line for root partition."

log "Original root partition TYPE: ${ORIGINAL_PART_TYPE}"

ENCRYPTED_ROOT=0
ORIGINAL_FS_TYPE=""
ORIG_ROOT_FS_UUID=""
ORIG_LUKS_UUID=""
CRYPT_NAME=""

if [[ "${ORIGINAL_PART_TYPE}" == "crypto_LUKS" ]]; then
  ENCRYPTED_ROOT=1
  ORIG_LUKS_UUID="$(sed -E 's/.*UUID="([^"]+)".*/\1/' <<< "${ROOT_LINE_ORIG}" || true)"
  log "Detected encrypted root (LUKS), original LUKS UUID=${ORIG_LUKS_UUID}"

  FSTAB_META="${META_DIR}/fstab"
  [[ -f "${FSTAB_META}" ]] || die "fstab missing in metadata; needed to resolve root mapper name."

  CRYPT_NAME="$(awk '$2=="/" && $1 ~ "^/dev/mapper/" {gsub("/dev/mapper/","",$1); print $1}' "${FSTAB_META}" | head -n1)"
  [[ -n "${CRYPT_NAME}" ]] || die "Cannot determine encrypted root mapper name from fstab."

  ROOT_MAPPER_ORIG="/dev/mapper/${CRYPT_NAME}"
  log "Original encrypted root mapper: ${ROOT_MAPPER_ORIG} (name: ${CRYPT_NAME})"

  ROOT_MAPPER_LINE="$(grep -E "^${ROOT_MAPPER_ORIG}:" "${BLKID_META}" || true)"
  [[ -n "${ROOT_MAPPER_LINE}" ]] || die "Cannot find ${ROOT_MAPPER_ORIG} in blkid metadata."

  ORIGINAL_FS_TYPE="$(sed -E 's/.*TYPE="([^"]+)".*/\1/' <<< "${ROOT_MAPPER_LINE}")"
  [[ -n "${ORIGINAL_FS_TYPE}" ]] || die "Cannot extract TYPE from blkid line for mapped root."

  ORIG_ROOT_FS_UUID="$(sed -E 's/.*UUID="([^"]+)".*/\1/' <<< "${ROOT_MAPPER_LINE}" || true)"

  log "Encrypted root contains FS type ${ORIGINAL_FS_TYPE}, FS UUID=${ORIG_ROOT_FS_UUID}"
else
  ORIGINAL_FS_TYPE="${ORIGINAL_PART_TYPE}"
  ORIG_ROOT_FS_UUID="$(sed -E 's/.*UUID="([^"]+)".*/\1/' <<< "${ROOT_LINE_ORIG}" || true)"
  log "Plain root filesystem type: ${ORIGINAL_FS_TYPE}, FS UUID=${ORIG_ROOT_FS_UUID}"
fi

# ------------- Step 4: recreate EFI+root (UUID-preserving where possible) -------------

log "Creating EFI filesystem (vfat) on ${EFI_PART} (FAT volume ID not important; PARTUUID restored by GPT)"
mkfs.vfat -F32 "${EFI_PART}"

ROOT_MOUNT_DEV=""

if [[ "${ENCRYPTED_ROOT}" -eq 1 ]]; then
  [[ -n "${CRYPT_NAME}" ]] || die "CRYPT_NAME is empty for encrypted root."

  log "Creating LUKS container on ${ROOT_PART} with original UUID ${ORIG_LUKS_UUID}"
  if [[ -n "${ORIG_LUKS_UUID}" ]]; then
    cryptsetup luksFormat --uuid="${ORIG_LUKS_UUID}" "${ROOT_PART}"
  else
    cryptsetup luksFormat "${ROOT_PART}"
  fi

  log "Opening LUKS container as ${CRYPT_NAME}"
  cryptsetup open "${ROOT_PART}" "${CRYPT_NAME}"

  ROOT_MOUNT_DEV="/dev/mapper/${CRYPT_NAME}"

  log "Creating filesystem ${ORIGINAL_FS_TYPE} inside LUKS on ${ROOT_MOUNT_DEV} with original UUID ${ORIG_ROOT_FS_UUID}"
  case "${ORIGINAL_FS_TYPE}" in
    ext4)
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        mkfs.ext4 -F -U "${ORIG_ROOT_FS_UUID}" "${ROOT_MOUNT_DEV}"
      else
        mkfs.ext4 -F "${ROOT_MOUNT_DEV}"
      fi
      ;;
    btrfs)
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        mkfs.btrfs -f -U "${ORIG_ROOT_FS_UUID}" "${ROOT_MOUNT_DEV}"
      else
        mkfs.btrfs -f "${ROOT_MOUNT_DEV}"
      fi
      ;;
    xfs)
      mkfs.xfs -f "${ROOT_MOUNT_DEV}"
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        xfs_admin -U "${ORIG_ROOT_FS_UUID}" "${ROOT_MOUNT_DEV}"
      fi
      ;;
    *)
      die "Unsupported inner FS type ORIGINAL_FS_TYPE=${ORIGINAL_FS_TYPE} inside LUKS. Extend script."
      ;;
  esac
else
  ROOT_MOUNT_DEV="${ROOT_PART}"

  log "Creating filesystem ${ORIGINAL_FS_TYPE} on ${ROOT_PART} with original UUID ${ORIG_ROOT_FS_UUID}"
  case "${ORIGINAL_FS_TYPE}" in
    ext4)
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        mkfs.ext4 -F -U "${ORIG_ROOT_FS_UUID}" "${ROOT_PART}"
      else
        mkfs.ext4 -F "${ROOT_PART}"
      fi
      ;;
    btrfs)
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        mkfs.btrfs -f -U "${ORIG_ROOT_FS_UUID}" "${ROOT_PART}"
      else
        mkfs.btrfs -f "${ROOT_PART}"
      fi
      ;;
    xfs)
      mkfs.xfs -f "${ROOT_PART}"
      if [[ -n "${ORIG_ROOT_FS_UUID}" ]]; then
        xfs_admin -U "${ORIG_ROOT_FS_UUID}" "${ROOT_PART}"
      fi
      ;;
    *)
      die "Unsupported ORIGINAL_FS_TYPE=${ORIGINAL_FS_TYPE}. Extend script if needed."
      ;;
  esac
fi

# ------------- Step 5: mount and restore full system -------------

log "Mounting new root filesystem on /mnt/target"
mkdir -p /mnt/target
mount "${ROOT_MOUNT_DEV}" /mnt/target

log "Mounting EFI partition on /mnt/target/boot/efi"
mkdir -p /mnt/target/boot/efi
mount "${EFI_PART}" /mnt/target/boot/efi

log "Restoring full system from restic to /mnt/target"
restic restore "${SNAPSHOT}" \
  -r "${RESTIC_REPO}" \
  --target /mnt/target

log "Filesystem restored onto ${TARGET_DISK}"

# ------------- Step 5.5: reapply boot tarballs from metadata (if present) -------------

if [[ -f "${META_DIR}/boot.tar" ]]; then
  log "Reapplying boot.tar from metadata onto /mnt/target"
  tar -xpf "${META_DIR}/boot.tar" -C /mnt/target
else
  log "No boot.tar in metadata; assuming /boot was included in restic backup."
fi

if [[ -f "${META_DIR}/boot-efi.tar" ]]; then
  log "Reapplying boot-efi.tar from metadata onto /mnt/target"
  tar -xpf "${META_DIR}/boot-efi.tar" -C /mnt/target
else
  log "No boot-efi.tar in metadata; relying on boot.tar/backup for ESP contents."
fi

# ------------- Step 6: ensure UEFI fallback loader (EFI/BOOT/BOOTX64.EFI) -------------

ESP_EFI_ROOT="/mnt/target/boot/efi/EFI"
FALLBACK_DIR="${ESP_EFI_ROOT}/BOOT"
FALLBACK_PATH="${FALLBACK_DIR}/BOOTX64.EFI"

log "Ensuring UEFI fallback loader at EFI/BOOT/BOOTX64.EFI (if possible)"

if [[ -f "${FALLBACK_PATH}" ]]; then
  log "Fallback loader already present at EFI/BOOT/BOOTX64.EFI; leaving it unchanged."
else
  CANDIDATES=(
    "${ESP_EFI_ROOT}/systemd/systemd-bootx64.efi"
    "${ESP_EFI_ROOT}/Linux/BOOTX64.EFI"
  )

  FALLBACK_SRC=""

  for c in "${CANDIDATES[@]}"; do
    if [[ -f "${c}" ]]; then
      FALLBACK_SRC="${c}"
      log "Selected fallback source: ${FALLBACK_SRC}"
      break
    fi
  done

  if [[ -z "${FALLBACK_SRC}" ]]; then
    FALLBACK_SRC="$(find "${ESP_EFI_ROOT}" -maxdepth 3 -type f -iname '*.efi' | head -n1 || true)"
    if [[ -n "${FALLBACK_SRC}" ]]; then
      log "No known loaders matched; using first EFI binary found: ${FALLBACK_SRC}"
    fi
  fi

  if [[ -n "${FALLBACK_SRC}" ]]; then
    mkdir -p "${FALLBACK_DIR}"
    cp -f "${FALLBACK_SRC}" "${FALLBACK_PATH}"
    log "Installed fallback loader: EFI/BOOT/BOOTX64.EFI copied from ${FALLBACK_SRC}"
  else
    log "WARNING: No EFI loaders found to use as fallback; disk may still rely on firmware-specific behaviour."
  fi
fi

cat <<'EOF'

==============================================================
Restore complete.

What this script did:
  - Ensured target disk had no partitions and wasn't smaller than original
  - Restored original GPT (partition layout and PARTUUIDs)
  - Recreated LUKS container (if any) and filesystems with original UUIDs
  - Restored all files via restic
  - Reapplied boot.tar and boot-efi.tar (boot and ESP contents)
  - Ensured a generic UEFI fallback loader EFI/BOOT/BOOTX64.EFI if possible

Because UUIDs for root FS and LUKS were preserved, your existing:
  - /etc/fstab
  - /etc/crypttab
  - systemd-boot loader entries
  - kernel cmdline

should remain valid, like a dd clone.

On the target machine, the disk will often boot immediately.
If not, use firmware's "Boot from file" to select:
  EFI/BOOT/BOOTX64.EFI

Once booted into the restored system, you can still run:
  - bootctl install        # or grub-install
  - mkinitcpio -P          # or your initramfs tool
to refresh bootloader/initramfs if you change kernels/hooks later.
==============================================================
EOF

