#!/usr/bin/env bash
# ==============================================================================
# check-acs-images.sh — Apache CloudStack KVM Image Health Checker
#
# Purpose:
#   - Scan KVM primary storage for qcow2/raw images
#   - Cross-reference with CloudStack DB (volumes, templates, VMs)
#   - Detect orphaned, unknown, or snapshot-based images
#   - Identify candidates for safe flattening
#   - Provide actionable cleanup commands
#
# Features:
#   - Color-coded status icons
#   - UUID + non-UUID file detection
#   - Snapshot chain analysis
#   - Base image parent marking
#   - Flatten command generator
#
# Author:  Antoine Boucher - Halton Data Center
# License: MIT License (see LICENSE file)
# SPDX-License-Identifier: MIT
#
# Usage:
#   ./check-acs-images.sh [directory] [--show-nonuuid|-n]
#
# Requirements:
#   - bash, qemu-img, virsh, mysql client
#   - Access to CloudStack DB
#   - Run on KVM host with primary storage mounted
#
# WARNING:
#   - DO NOT run `qemu-img convert` without stopping the VM and taking backups
#   - This script is READ-ONLY by default
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------- #
# UTILITIES
# --------------------------------------------------------------------------- #

# Pad string to 20 chars (for alignment in output)
_pad20() { printf "%-20s" "$1"; }

# Color helpers (fallback-safe)
_red()  { tput setaf 1 2>/dev/null || true; }
_grn()  { tput setaf 2 2>/dev/null || true; }
_gry()  { tput setaf 7 2>/dev/null || true; }
_miss() { (tput setaf 178 >/dev/null 2>&1 && tput setaf 178) || tput setaf 3; }
_rst()  { tput sgr0     2>/dev/null || true; }

# Status icons
RUN_ICON="$(_grn)■$(_rst)"           # Running VM
STOP_ICON="$(_red)■$(_rst)"          # Stopped VM
IDLE_KNOWN_ICON="$(_gry)■$(_rst)"    # Idle, known to ACS
IDLE_UNKNOWN_ICON="□"                # Idle, unknown to ACS
MISSING_ICON="$(_miss)■$(_rst)"      # Missing base

# Output formatting
FMT="%-40s  %8s  %-20s  %-2s  %-44s  %-1s  %s\n"
FMTH="%-40s  %8s  %-18s  %-2s  %-40s  %-1s  %s\n"
hr() { printf '─%.0s' {1..180}; echo; }

print_header() {
  hr
  printf "$FMTH" "Filename" "Size (GB)" "Base Image" "Type" "Name" "Status" "Notes"
  hr
}

# Helper: command exists?
have() { command -v "$1" >/dev/null 2>&1; }

# Helper: run SQL query (silent on error)
sql() {
  mysql -N -h "$CS_DB_HOST" -P "$CS_DB_PORT" -u "$CS_DB_USER" "-p$CS_DB_PASS" "$CS_DB_NAME" -e "$1" 2>/dev/null || true
}

# Helper: bytes → GB
bytes_to_gb() { awk -v b="$1" 'BEGIN{printf "%.1fG", b/(1024*1024*1024)}'; }

# Helper: shorten long paths (12...last4)
shorten_mid() {
  local s="${1:-}"
  [[ -z "$s" || "$s" == "-" ]] && { echo "-"; return; }
  s="$(basename "$s")"
  (( ${#s} > 17 )) && printf "%s...%s" "${s:0:12}" "${s:(-4)}" || echo "$s"
}

# Helper: clean NULL → "-"
clean_null() { local v="${1:-}"; [[ -z "$v" || "$v" == "NULL" ]] && echo "-" || echo "$v"; }

# --------------------------------------------------------------------------- #
# CONFIGURATION
# --------------------------------------------------------------------------- #

# CloudStack DB (override with env vars)
CS_DB_HOST="${CS_DB_HOST:-x.x.x.x}"
CS_DB_PORT="${CS_DB_PORT:-3306}"
CS_DB_USER="${CS_DB_USER:-username}"
CS_DB_PASS="${CS_DB_PASS:-password}"
CS_DB_NAME="${CS_DB_NAME:-cloud}"

# Runtime options
SHOW_NONUUID=false
IMG_DIR="$(pwd)"

# Parse args
shopt -s nocasematch
if (( $# )); then
  first_dir_set=false
  for a in "$@"; do
    case "$a" in
      --show-nonuuid|-n) SHOW_NONUUID=true ;;
      -h|--help)
        cat <<EOF
Usage: $0 [directory] [--show-nonuuid|-n]

Options:
  [directory]      Path to scan (default: current directory)
  --show-nonuuid   Show non-UUID files (e.g. .bak, ISOs)
  -h, --help       Show this help

Examples:
  $0 /var/lib/libvirt/images
  $0 --show-nonuuid
EOF
        exit 0
        ;;
      -*)
        echo "ERROR: unknown option: $a"
        echo "Try '$0 --help' for usage."
        exit 1
        ;;
      *)
        if ! $first_dir_set; then
          IMG_DIR="$a"
          first_dir_set=true
        fi
        ;;
    esac
  done
fi
shopt -u nocasematch

# Validate directory
[[ -d "$IMG_DIR" ]] || { echo "ERROR: directory not found: $IMG_DIR"; exit 1; }

# --------------------------------------------------------------------------- #
# HOST & POOL DETECTION
# --------------------------------------------------------------------------- #

HOSTNAME="$(hostname -s 2>/dev/null || echo unknown)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' | head -n1)"
POOL_ID=""
POOL_NAME=""

# Try to find storage pool by path + IP
POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL AND host_address='${HOST_IP}' AND path='${IMG_DIR}' LIMIT 1;")"
[[ -z "$POOL_ID" ]] && POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL AND host_address='${HOST_IP}' LIMIT 1;")"
[[ -z "$POOL_ID" ]] && POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL LIMIT 1;")"
POOL_NAME="$(sql "SELECT name FROM storage_pool WHERE id='${POOL_ID}' LIMIT 1;")"
[[ -z "$POOL_NAME" ]] && POOL_NAME="$(basename "$IMG_DIR")"

# --------------------------------------------------------------------------- #
# VIRSH: MAP UUID → VM NAME & STATE
# --------------------------------------------------------------------------- #

declare -A VM_MAP VM_STATE
if have virsh; then
  mapfile -t ALL_VMS < <(virsh list --all --name 2>/dev/null | grep -v '^$' || true)
  for vm in "${ALL_VMS[@]}"; do
    st="$(virsh domstate "$vm" 2>/dev/null | head -n1 || echo "")"
    [[ -n "$st" ]] && VM_STATE["$vm"]="${st,,}"  # lowercase
    while read -r src; do
      [[ "$src" =~ ^/ ]] || continue
      u="$(basename "$src")"; u="${u%%.*}"
      [[ "$u" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
      VM_MAP["$u"]="$vm"
    done < <(virsh domblklist "$vm" 2>/dev/null | awk 'NR>2 {print $NF}' || true)
  done
fi

# --------------------------------------------------------------------------- #
# CLOUDSTACK DB: VOLUMES & TEMPLATES
# --------------------------------------------------------------------------- #

declare -A VOL_DB TPL_ANY TPL_POOLS
declare -a FLATTEN_CMDS=()

# Load volumes
while IFS=$'\t' read -r path vtype vstate vm_disp vm_inst vm_state acct dom vpool vpool_id; do
  [[ -z "${path:-}" ]] && continue
  u="$(basename "$path")"; uuid_only="${u%%.*}"
  val="$(clean_null "$vtype")|$(clean_null "$vstate")|$(clean_null "$vm_disp")|$(clean_null "$vm_inst")|$(clean_null "$vm_state")|$(clean_null "$acct")|$(clean_null "$dom")|$(clean_null "$vpool")|$(clean_null "$vpool_id")"
  VOL_DB["$u"]="$val"; VOL_DB["$uuid_only"]="$val"
done < <(sql "
  SELECT v.path, v.volume_type, v.state,
         vm.display_name, vm.instance_name, vm.state,
         a.account_name, d.name,
         sp.name, sp.id
  FROM volumes v
  LEFT JOIN vm_instance vm ON v.instance_id=vm.id
  LEFT JOIN account a ON vm.account_id=a.id
  LEFT JOIN domain d ON a.domain_id=d.id
  LEFT JOIN storage_pool sp ON v.pool_id=sp.id
  WHERE v.removed IS NULL AND v.pool_id IS NOT NULL;
")

# Load templates
while IFS=$'\t' read -r uuid name ttype tformat tstate acct dom; do
  [[ -z "${uuid:-}" ]] && continue
  uuid_only="${uuid%%.*}"
  val="$(clean_null "$name")|$(clean_null "$ttype")|$(clean_null "$tformat")|$(clean_null "$tstate")|$(clean_null "$acct")|$(clean_null "$dom")"
  TPL_ANY["$uuid"]="$val"; TPL_ANY["$uuid_only"]="$val"
done < <(sql "
  SELECT t.uuid, t.name, t.type, t.format, t.state, a.account_name, d.name
  FROM vm_template t
  LEFT JOIN account a ON a.id=t.account_id
  LEFT JOIN domain d ON a.domain_id=d.id
  WHERE t.removed IS NULL;
")

# Template → pool mapping
while IFS=$'\t' read -r uuid pool_id; do
  [[ -z "${uuid:-}" ]] && continue
  uuid_only="${uuid%%.*}"
  cur="${TPL_POOLS[$uuid_only]:-}"
  [[ -z "$cur" ]] && TPL_POOLS["$uuid_only"]="$pool_id" || TPL_POOLS["$uuid_only"]="$cur,$pool_id"
done < <(sql "
  SELECT t.uuid, tsr.pool_id
  FROM template_spool_ref tsr
  JOIN vm_template t ON t.id=tsr.template_id
  WHERE tsr.state='Ready' AND t.removed IS NULL;
")

# --------------------------------------------------------------------------- #
# SCAN FILESYSTEM
# --------------------------------------------------------------------------- #

echo
echo "Host: $HOSTNAME (IP: $HOST_IP, pool: $POOL_NAME, pool_id: ${POOL_ID:-unknown})"
print_header

declare -a ROWS
declare -A SNAP_BASES

while IFS= read -r -d '' img; do
  fname="$(basename "$img")"
  NOTES=(); info=""; is_snapshot=false
  size_disp="-"; backing="-"; base_disp="-"; TYPE="I"; name_col="-"; icon="$IDLE_UNKNOWN_ICON"

  # Non-UUID files
  if [[ ! "$fname" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    if $SHOW_NONUUID; then
      printf -v row "$FMT" "$fname" "-" "-" "I?" "-" "$IDLE_UNKNOWN_ICON" "Non-UUID file (unknown to ACS)"
      ROWS+=("$row")
    fi
    continue
  fi

  # Get qemu-img info
  if have qemu-img; then
    info="$(qemu-img info --force-share "$img" 2>/dev/null || true)"
    [[ "$info" =~ \(([0-9]+)\ bytes\) ]] && size_disp="$(bytes_to_gb "${BASH_REMATCH[1]}")"

    if grep -q "^backing file:" <<<"$info"; then
      line="$(grep "^backing file:" <<<"$info" | head -n1 | sed 's/^backing file:[[:space:]]*//')"
      backing="${line%% (actual path:*}"; backing="${backing%%, format*}"; backing="${backing//\"/}"
      base_disp="$(shorten_mid "$backing")"
      is_snapshot=true
    fi
  fi

  # Snapshot detection
  if $is_snapshot; then
    base_uuid="$(basename "$backing")"; base_uuid="${base_uuid%%.*}"

    if [[ ! -f "$IMG_DIR/$base_uuid" ]]; then
      TYPE="S!"
      NOTES+=("Snapshot base missing (FS)")
    else
      base_known=$([[ -n "${VOL_DB[$base_uuid]:-}" || -n "${TPL_ANY[$base_uuid]:-}" ]] && echo true || echo false)
      snap_known=$([[ -n "${VOL_DB[$fname]:-}" || -n "${TPL_ANY[$fname]:-}" ]] && echo true || echo false)

      if ! $base_known; then
        if ! $snap_known; then
          TYPE="S?"
          NOTES+=("Snapshot and base both unknown to ACS (flatten candidate)")
        else
          TYPE="S"
          NOTES+=("Snapshot of base unknown to ACS (flatten candidate)")
        fi
        FLATTEN_CMDS+=("qemu-img convert -O qcow2 \"$IMG_DIR/$fname\" \"$IMG_DIR/$fname.flat\"")
      else
        TYPE="S"
      fi
    fi
    SNAP_BASES["$base_uuid"]="$TYPE"
  fi

  # Classification
  if [[ -n "${VOL_DB[$fname]:-}" ]]; then
    IFS='|' read -r vtype vstate vm_disp vm_inst vm_state acct dom vpool_name vpool_id <<<"${VOL_DB[$fname]}"

    if ! $is_snapshot; then
      case "$vtype" in
        ROOT)      TYPE="R" ;;
        DATADISK)  TYPE="D" ;;
        TEMPLATE)  TYPE="T" ;;
        *)         TYPE="I" ;;
      esac
    fi

    vm_name="$(clean_null "$vm_disp")"
    [[ "$vm_name" == "-" ]] && vm_name="$(clean_null "$vm_inst")"
    [[ "$vm_name" == "-" && -n "${VM_MAP[$fname]:-}" ]] && vm_name="${VM_MAP[$fname]}"
    acc="$(clean_null "$acct")"
    name_col="$(printf "%s (%s)" "$vm_name" "$acc")"

    st_lc="${vm_state,,}"
    if [[ "$st_lc" == "running" ]]; then
      icon="$RUN_ICON"
    elif [[ "$st_lc" =~ stop|shut ]]; then
      icon="$STOP_ICON"
    else
      icon="$IDLE_KNOWN_ICON"
    fi

  elif [[ -n "${TPL_ANY[$fname]:-}" ]]; then
    TYPE="T"
    IFS='|' read -r tname ttype tformat tstate tacct tdom <<<"${TPL_ANY[$fname]}"
    name_col="$(printf "%s (%s)" "$(clean_null "$tname")" "$(clean_null "$tacct")")"
    NOTES+=("$(clean_null "$tformat") [$(clean_null "$tstate")]")
    pools_csv="${TPL_POOLS[${fname%%.*}]:-}"
    icon="$IDLE_KNOWN_ICON"
    if [[ -n "$POOL_ID" && -n "$pools_csv" && ",$pools_csv," != *",${POOL_ID},"* ]]; then
      NOTES+=("Not registered in this pool")
    fi

  else
    vm_name="-"; [[ -n "${VM_MAP[$fname]:-}" ]] && vm_name="${VM_MAP[$fname]}"
    name_col="$(printf "%s (%s)" "$vm_name" "-")"
    fmt="$(grep -m1 '^file format:' <<<"$info" | awk '{print $3}' || echo "")"
    case "$fmt" in
      qcow2)  [[ "$backing" != "-" ]] && TYPE="S?" NOTES+=("Snapshot (unknown to ACS)") || TYPE="I?" NOTES+=("qcow2 volume (unknown to ACS)") ;;
      raw)    TYPE="R?" NOTES+=("Raw image (unknown to ACS)") ;;
      *)      TYPE="I?" NOTES+=("Unknown format (unknown to ACS)") ;;
    esac
    icon="$IDLE_UNKNOWN_ICON"
  fi

  note_str=""; (( ${#NOTES[@]} )) && note_str="$(IFS=', '; echo "${NOTES[*]}")"
  printf -v row "$FMT" "$fname" "$size_disp" "$base_disp" "$TYPE" "$name_col" "$icon" "$note_str"
  ROWS+=("$row")

done < <(find "$IMG_DIR" -maxdepth 1 -type f -print0 | sort -z)

# Mark base images of snapshots
for base_uuid in "${!SNAP_BASES[@]}"; do
  stype="${SNAP_BASES[$base_uuid]}"
  for i in "${!ROWS[@]}"; do
    [[ "${ROWS[$i]}" =~ ^$base_uuid[[:space:]] ]] || continue
    prefix="${ROWS[$i]:0:52}"
    suffix="${ROWS[$i]:72}"
    case "$stype" in
      S)  label="Parent" ;;
      S!) label="Parent (missing)" ;;
      S?) label="Parent (unknown)" ;;
      *)  label="Parent" ;;
    esac
    ROWS[$i]="${prefix}$(_pad20 "$label")${suffix}"
  done
done

# --------------------------------------------------------------------------- #
# OUTPUT
# --------------------------------------------------------------------------- #

printf "%s\n" "${ROWS[@]}" | sed '/^[[:space:]]*$/d' | sort -f -k5,5

hr
echo "Legend: D=Data  T=Template  I=Image  R=Root  S=Snapshot  P=Base Image  (?=unknown ACS, !=missing FS)"
echo "        $RUN_ICON=Running  $STOP_ICON=Stopped  $MISSING_ICON=Missing  $IDLE_KNOWN_ICON=Idle  $IDLE_UNKNOWN_ICON=Unknown"
hr

echo
echo "SUMMARY"
hr
echo "  Host: $HOSTNAME (IP: $HOST_IP, pool: $POOL_NAME, pool_id: ${POOL_ID:-unknown})"
echo "  Scanned directory: $IMG_DIR"
echo "  UUID files scanned: $(find "$IMG_DIR" -maxdepth 1 -type f -name '[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[^ ]*' | wc -l)"
echo "  Flatten candidates: ${#FLATTEN_CMDS[@]}"
hr

if (( ${#FLATTEN_CMDS[@]} > 0 )); then
  echo
  echo "FLATTENING CANDIDATES  CAUTION"
  hr
  echo "The following snapshots can likely be safely flattened:"
  echo
  for c in "${FLATTEN_CMDS[@]}"; do
    echo "   $c"
  done
  echo
  echo "Steps:"
  echo "  1. Stop the VM"
  echo "  2. Backup the snapshot"
  echo "  3. Run the command above"
  echo "  4. Delete original, rename .flat → original"
  echo "  5. Restart VM"
  hr
fi

echo
