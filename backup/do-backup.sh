#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------
#  Static restic backup script:
#   - Loads all vars from config file
#   - Forces interactive password entry
#   - Includes EFI + GPT + disk metadata
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

# Require root privileges
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)."
  echo "Run again with: sudo $0"
  exit 1
fi


# Load config
[[ -f "${CONFIG_FILE}" ]] || die "Config file ${CONFIG_FILE} not found."
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# Validate
[[ -n "${BACKUP_SERVER_USER:-}" ]]  || die "BACKUP_SERVER_USER missing"
[[ -n "${BACKUP_SERVER_HOST:-}" ]]  || die "BACKUP_SERVER_HOST missing"
[[ -n "${BACKUP_BASE_PATH:-}"   ]]  || die "BACKUP_BASE_PATH missing"
[[ -n "${REPO_NAME:-}"          ]]  || die "REPO_NAME missing"
[[ -n "${BACKUP_PATHS:-}"       ]]  || die "BACKUP_PATHS missing"
[[ -n "${SYSTEM_DISK:-}"        ]]  || die "SYSTEM_DISK missing (needed for GPT backup)"

BACKUP_SERVER_PORT="${BACKUP_SERVER_PORT:-22}"
ONE_FILE_SYSTEM="${ONE_FILE_SYSTEM:-1}"
EXCLUDES="${EXCLUDES:-}"

# Repo
RESTIC_REPO="sftp:${BACKUP_SERVER_USER}@${BACKUP_SERVER_HOST}:${BACKUP_BASE_PATH}/${REPO_NAME}"

# Metadata dir (always overwritten)
META_DIR="/var/backups/system-meta"
rm -rf "${META_DIR}"
mkdir -p "${META_DIR}"

log "Collecting system metadata into ${META_DIR}"

efibootmgr -v > "${META_DIR}/efibootmgr.txt" 2>&1

# ----- GPT / partition table -----
log "Saving GPT of ${SYSTEM_DISK}"
sgdisk --backup="${META_DIR}/disk.gpt" "${SYSTEM_DISK}"

echo "${SYSTEM_DISK}" > "${META_DIR}/system_disk.txt"

# Save original disk size in bytes
blockdev --getsize64 "${SYSTEM_DISK}" > "${META_DIR}/disk-size-bytes.txt"


# ----- blkid & lsblk -----
blkid > "${META_DIR}/blkid.txt"
lsblk -O > "${META_DIR}/lsblk.json"

# ----- fstab / mounts -----
cp /etc/fstab "${META_DIR}/fstab"
findmnt -R / > "${META_DIR}/mount-tree.txt"

# ----- EFI & boot partitions (if mounted) -----
if mountpoint -q /boot; then
    log "Archiving /boot"
    tar --one-file-system -cpf "${META_DIR}/boot.tar" /boot
fi

if mountpoint -q /boot/efi; then
    log "Archiving /boot/efi"
    tar --one-file-system -cpf "${META_DIR}/boot-efi.tar" /boot/efi
fi

# EFI boot manager state
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -v > "${META_DIR}/efibootmgr.txt"
fi

# ----------------------------------------------------
# Prepare restic command
# ----------------------------------------------------

unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND

RESTIC_CMD=(restic backup)

# Add backup paths
# shellcheck disable=SC2206
BACKUP_PATHS_ARR=(${BACKUP_PATHS})
RESTIC_CMD+=("${BACKUP_PATHS_ARR[@]}")

# Include metadata dir explicitly
RESTIC_CMD+=("${META_DIR}")

# --one-file-system?
[[ "${ONE_FILE_SYSTEM}" == "1" ]] && RESTIC_CMD+=(--one-file-system)

# Add excludes
if [[ -n "${EXCLUDES}" ]]; then
  # shellcheck disable=SC2206
  EXC_ARR=(${EXCLUDES})
  for ex in "${EXC_ARR[@]}"; do RESTIC_CMD+=(--exclude="$ex"); done
fi

RESTIC_CMD+=(-r "${RESTIC_REPO}")

log "Running backup. You will enter password manually."
log "CMD: ${RESTIC_CMD[*]}"

# ----------------------------------------------------
# Execute
# ----------------------------------------------------
"${RESTIC_CMD[@]}"

log "Backup completed."

