#!/bin/bash
# ========================================================================================
#  check-acs-images.sh — KVM / Apache CloudStack Image Health Checker
# ----------------------------------------------------------------------------------------
#  Scans a local image directory (usually /var/lib/libvirt/images) and cross-references
#  it with the Apache CloudStack MySQL database to detect:
#     • Missing or orphaned images
#     • Snapshots whose base images are missing or unknown to ACS
#     • Flattening candidates (snapshots safe to commit or convert)
#
#  Displays a clean table of all images with their type, status, and notes.
#  Colorized output and icons indicate state (Running, Stopped, Missing, Idle, Unknown).
#
#  Author: Antoine Boucher (Halton Datacenter / WildFire Storage)
#  License: MIT
#  GitHub: https://github.com/haltondc/check-acs-images
#
#  Usage:
#     ./check-acs-images.sh [directory] [--show-nonuuid|-n]
#
#  Example:
#     ./check-acs-images.sh /var/lib/libvirt/images
#
#  Environment variables (override defaults as needed):
#     CS_DB_HOST     Database host (default: 127.0.0.1)
#     CS_DB_PORT     MySQL port (default: 3306)
#     CS_DB_USER     Database username (default: cloud)
#     CS_DB_PASS     Database password (default: change-me)
#     CS_DB_NAME     Database name   (default: cloud)
# ========================================================================================

set -euo pipefail
IFS=$'\n\t'

_pad20() { printf "%-20s" "$1"; }

# ---------- CONFIG ----------
CS_DB_HOST="${CS_DB_HOST:-127.0.0.1}"
CS_DB_PORT="${CS_DB_PORT:-3306}"
CS_DB_USER="${CS_DB_USER:-cloud}"
CS_DB_PASS="${CS_DB_PASS:-change-me}"
CS_DB_NAME="${CS_DB_NAME:-cloud}"

# ---------- ARGS ----------
SHOW_NONUUID=false
IMG_DIR="$(pwd)"

shopt -s nocasematch
if (( $# )); then
  first_dir_set=false
  for a in "$@"; do
    case "$a" in
      --show-nonuuid|-n) SHOW_NONUUID=true ;;
      -h|--help)
        echo "Usage: $0 [directory] [--show-nonuuid|-n]"
        exit 0 ;;
      -*)
        echo "ERROR: unknown option: $a"
        echo "Usage: $0 [directory] [--show-nonuuid|-n]"
        exit 1 ;;
      *)
        if ! $first_dir_set; then IMG_DIR="$a"; first_dir_set=true; fi ;;
    esac
  done
fi
shopt -u nocasematch

[[ -d "$IMG_DIR" ]] || { echo "ERROR: directory not found: $IMG_DIR"; exit 1; }

# ---------- COLORS ----------
_red()  { tput setaf 1 2>/dev/null || true; }
_grn()  { tput setaf 2 2>/dev/null || true; }
_gry()  { tput setaf 7 2>/dev/null || true; }
_rst()  { tput sgr0     2>/dev/null || true; }
_miss() { (tput setaf 178 >/dev/null 2>&1 && tput setaf 178) || tput setaf 3; }

RUN_ICON="$(_grn)■$(_rst)"
STOP_ICON="$(_red)■$(_rst)"
IDLE_KNOWN_ICON="$(_gry)■$(_rst)"
IDLE_UNKNOWN_ICON="□"
MISSING_ICON="$(_miss)■$(_rst)"

# ---------- FORMAT ----------
FMT="%-40s  %8s  %-20s  %-2s  %-44s  %-1s  %s\n"
FMTH="%-40s  %8s %-18s %-2s   %-40s %-1s  %s\n"
hr() { printf '─%.0s' {1..180}; echo; }
print_header() { hr; printf "$FMTH" "Filename" "Size (GB)" "Base Image" "Type" "Name" "Status" "Notes"; hr; }

# ---------- HELPERS ----------
have() { command -v "$1" >/dev/null 2>&1; }
sql() { mysql -N -h "$CS_DB_HOST" -P "$CS_DB_PORT" -u "$CS_DB_USER" "-p$CS_DB_PASS" "$CS_DB_NAME" -e "$1" 2>/dev/null || true; }
bytes_to_gb() { awk -v b="$1" 'BEGIN{printf "%.1fG", b/(1024*1024*1024)}'; }
shorten_mid() { local s="${1:-}"; [[ -z "$s" || "$s" == "-" ]] && { echo "-"; return; }; s="$(basename "$s")"; local n=${#s}; (( n > 17 )) && printf "%s...%s" "${s:0:12}" "${s:(-4)}" || printf "%s" "$s"; }
clean_null() { local v="${1:-}"; [[ -z "$v" || "$v" == "NULL" ]] && echo "-" || echo "$v"; }

# ---------- HOST / POOL ----------
HOSTNAME="$(hostname -s 2>/dev/null || echo unknown)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL AND host_address='${HOST_IP}' AND path='${IMG_DIR}' LIMIT 1;")"
[[ -z "$POOL_ID" ]] && POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL AND host_address='${HOST_IP}' LIMIT 1;")"
[[ -z "$POOL_ID" ]] && POOL_ID="$(sql "SELECT id FROM storage_pool WHERE removed IS NULL LIMIT 1;")"
POOL_NAME="$(sql "SELECT name FROM storage_pool WHERE id='${POOL_ID}' LIMIT 1;")"
[[ -z "$POOL_NAME" ]] && POOL_NAME="$(basename "$IMG_DIR")"

# ---------- VIRSH MAP ----------
declare -A VM_MAP VM_STATE
if have virsh; then
  mapfile -t ALL_VMS < <(virsh list --all --name 2>/dev/null | sed '/^$/d' || true)
  for vm in "${ALL_VMS[@]:-}"; do
    st="$(virsh domstate "$vm" 2>/dev/null | awk '{print $1}')"
    [[ -n "$st" ]] && VM_STATE["$vm"]="${st^}"
    while read -r src; do
      [[ "$src" =~ ^/ ]] || continue
      u="$(basename "$src")"; u="${u%%.*}"
      [[ "$u" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
      VM_MAP["$u"]="$vm"
    done < <(virsh domblklist "$vm" 2>/dev/null | awk 'NR>2 {print $NF}')
  done
fi

# ---------- LOAD ACS ----------
declare -A VOL_DB TPL_ANY TPL_POOLS SNAP_BASES

# Volumes
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
  LEFT JOIN domain  d ON a.domain_id=d.id
  LEFT JOIN storage_pool sp ON v.pool_id=sp.id
  WHERE v.removed IS NULL AND v.pool_id IS NOT NULL;
")

# Templates
while IFS=$'\t' read -r uuid name ttype tformat tstate acct dom; do
  [[ -z "${uuid:-}" ]] && continue
  uuid_only="${uuid%%.*}"
  val="$(clean_null "$name")|$(clean_null "$ttype")|$(clean_null "$tformat")|$(clean_null "$tstate")|$(clean_null "$acct")|$(clean_null "$dom")"
  TPL_ANY["$uuid"]="$val"; TPL_ANY["$uuid_only"]="$val"
done < <(sql "
  SELECT t.uuid, t.name, t.type, t.format, t.state, a.account_name, d.name
  FROM vm_template t
  LEFT JOIN account a ON a.id=t.account_id
  LEFT JOIN domain  d ON a.domain_id=d.id
  WHERE t.removed IS NULL;
")

# Template-to-pool map
while IFS=$'\t' read -r uuid pool_id; do
  [[ -z "${uuid:-}" ]] && continue
  uuid_only="${uuid%%.*}"
  cur="${TPL_POOLS[$uuid_only]:-}"
  [[ -z "$cur" ]] && TPL_POOLS["$uuid_only"]="${pool_id}" || TPL_POOLS["$uuid_only"]="$cur,${pool_id}"
done < <(sql "
  SELECT t.uuid, tsr.pool_id
  FROM template_spool_ref tsr
  JOIN vm_template t ON t.id=tsr.template_id
  WHERE tsr.state='Ready' AND t.removed IS NULL;
")

# ---------- OUTPUT ----------
echo
echo "Host: $HOSTNAME (IP: $HOST_IP, pool: $POOL_NAME, pool_id: ${POOL_ID:-unknown})"
print_header
declare -a ROWS FLATTEN_CMDS

# ---------- SCAN FILESYSTEM ----------
while IFS= read -r -d '' img; do
  fname="$(basename "$img")"
  if [[ ! "$fname" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    if $SHOW_NONUUID; then
      printf -v row "$FMT" "$fname" "-" "-" "I?" "-" "$IDLE_UNKNOWN_ICON" "Non-UUID file (unknown to ACS)"
      [[ -n "${row// /}" ]] && ROWS+=("$row")
    fi
    continue
  fi

  NOTES=(); info=""; is_snapshot=false
  [[ "$(have qemu-img && echo ok)" == "ok" ]] && info="$(qemu-img info --force-share "$img" 2>/dev/null || true)"
  size_disp="-" ; [[ "$info" =~ \(([0-9]+)\ bytes\) ]] && size_disp="$(bytes_to_gb "${BASH_REMATCH[1]}")"
  backing="-"
  if grep -q "^backing file:" <<<"$info"; then
    line="$(grep "^backing file:" <<<"$info" | head -n1 | sed 's/^backing file:[[:space:]]*//')"
    backing="${line%% (actual path:*}"; backing="${backing%%, format*}"; backing="${backing//\"/}"
  fi
  base_disp="$(shorten_mid "$backing")"
  TYPE="I"; name_col="-"; icon="$IDLE_UNKNOWN_ICON"

 # ----- SNAPSHOT DETECTION -----
 if [[ "$backing" != "-" && -n "$backing" ]]; then
  is_snapshot=true
  base_uuid="$(basename "$backing")"; base_uuid="${base_uuid%%.*}"

  if [[ ! -f "$IMG_DIR/$base_uuid" ]]; then
    TYPE="S!"
    NOTES+=("Snapshot base missing (FS)")

  else
    # base exists
    base_known=false
    [[ -n "${VOL_DB[$base_uuid]:-}" || -n "${TPL_ANY[$base_uuid]:-}" ]] && base_known=true

    snap_known=false
    [[ -n "${VOL_DB[$fname]:-}" || -n "${TPL_ANY[$fname]:-}" ]] && snap_known=true

    if ! $base_known; then
      # base unknown to ACS
      if ! $snap_known; then
        TYPE="S?"
        NOTES+=("Snapshot and base both unknown to ACS (flatten candidate)")
      else
        TYPE="S"
        NOTES+=("Snapshot of base unknown to ACS (flatten candidate)")
      fi
      FLATTEN_CMDS+=("qemu-img convert -O qcow2 $IMG_DIR/$fname $IMG_DIR/$fname.flat")
    else
      TYPE="S"
    fi
  fi

  # Register base image for later parent marking
  SNAP_BASES["$base_uuid"]="$TYPE"
fi


  # ----- CLASSIFICATION -----
  if [[ -n "${VOL_DB[$fname]:-}" ]]; then
    IFS='|' read -r vtype vstate vm_disp vm_inst vm_state acct dom vpool_name vpool_id <<<"${VOL_DB[$fname]}"

    if ! $is_snapshot; then
      case "$vtype" in
        ROOT) TYPE="R";;
        DATADISK) TYPE="D";;
        TEMPLATE) TYPE="T";;
        *) TYPE="${TYPE:-I}";;
      esac
    fi

    if $is_snapshot; then
      [[ "$TYPE" == "S"  ]] && TYPE="S"
      [[ "$TYPE" == "S!" ]] && TYPE="S!"
      [[ "$TYPE" == "S?" ]] && TYPE="S?"
    fi

    vm_name="$(clean_null "$vm_disp")"
    [[ "$vm_name" == "-" ]] && vm_name="$(clean_null "$vm_inst")"
    [[ "$vm_name" == "-" && -n "${VM_MAP[$fname]:-}" ]] && vm_name="${VM_MAP[$fname]}"
    acc="$(clean_null "$acct")"
    name_col="$(printf "%s (%s)" "$vm_name" "$acc")"

    st_lc="$(tr 'A-Z' 'a-z' <<<"$(clean_null "$vm_state")")"
    if [[ "$st_lc" == "running" ]]; then icon="$RUN_ICON"
    elif [[ "$st_lc" =~ stop|shut ]]; then icon="$STOP_ICON"
    else icon="$IDLE_KNOWN_ICON"; fi

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
    # UNKNOWN TO ACS
    vm_name="-"; [[ -n "${VM_MAP[$fname]:-}" ]] && vm_name="${VM_MAP[$fname]}"
    name_col="$(printf "%s (%s)" "$vm_name" "-")"
    fmt="$(grep -m1 '^file format:' <<<"$info" | awk '{print $3}')"
    if [[ "$fmt" == "qcow2" ]]; then
      if [[ "$backing" != "-" && -n "$backing" ]]; then TYPE="S?"; NOTES+=("Snapshot (unknown to ACS)")
      else TYPE="I?"; NOTES+=("qcow2 volume (unknown to ACS)"); fi
    elif [[ "$fmt" == "raw" ]]; then TYPE="R?"; NOTES+=("Raw image (unknown to ACS)")
    else TYPE="I?"; NOTES+=("Unknown format (unknown to ACS)"); fi
    icon="$IDLE_UNKNOWN_ICON"
  fi

  note_str=""; (( ${#NOTES[@]} )) && note_str="$(IFS=', '; echo "${NOTES[*]}")"
  printf -v row "$FMT" "$fname" "$size_disp" "$base_disp" "$TYPE" "$name_col" "$icon" "$note_str"
  [[ -n "${row// /}" ]] && ROWS+=("$row")
done < <(find "$IMG_DIR" -maxdepth 1 -type f -print0 | sort -z)

# ---------- MARK BASE IMAGES OF SNAPSHOTS (show "Parent" in Base Image col) ----------
for base_uuid in "${!SNAP_BASES[@]}"; do
  stype="${SNAP_BASES[$base_uuid]}"
  for i in "${!ROWS[@]}"; do
    row="${ROWS[$i]}"
    # match the UUID at the start of the row
    [[ "$row" =~ ^$base_uuid[[:space:]] ]] || continue

    prefix="${row:0:52}"   # everything before Base Image col
    suffix="${row:72}"     # everything after Base Image col

    case "$stype" in
      S)  label="Parent" ;;
      S!) label="Parent (missing)" ;;
      S?) label="Parent (unknown)" ;;
      *)  label="Parent" ;;
    esac

    ROWS[$i]="${prefix}$(_pad20 "$label")${suffix}"
  done
done


# ---------- PRINT ----------
printf "%s\n" "${ROWS[@]}" | sed '/^[[:space:]]*$/d' | sort -f -k5,5

# ---------- FOOTER ----------
hr
echo "Legend: D=Data  T=Template  I=Image  R=Root  S=Snapshot  P=Base Image  (?=unknown ACS, !=missing FS)   $RUN_ICON=Running  $STOP_ICON=Stopped  $MISSING_ICON=Missing  $IDLE_KNOWN_ICON=Idle  $IDLE_UNKNOWN_ICON=Unknown to ACS"
hr
echo
echo "SUMMARY"
hr
echo "  Host: $HOSTNAME (IP: $HOST_IP, pool: $POOL_NAME, pool_id: ${POOL_ID:-unknown})"
echo "  Scanned directory: $IMG_DIR"
echo "  Local UUID files scanned: $(find "$IMG_DIR" -maxdepth 1 -type f -printf '%f\n' | grep -E '^[0-9a-fA-F-]{36}$' | wc -l)"
echo "  Candidate for flattening: ${#FLATTEN_CMDS[@]}"
hr

if (( ${#FLATTEN_CMDS[@]} > 0 )); then
  echo
  echo "FLATTENING OF IMAGES  ⚠️  CAUTION"
  hr
  echo "One or more snapshots appear to be flatten root candidates according to ACS."
  echo "If left unresolved, this may cause inconsistencies or storage errors later."
  echo "Follow these steps carefully for each candidate:"
  echo
  echo "1. Shut down the associated VM(s)."
  echo "2. Make a backup of the snapshot image(s)."
  echo "3. Flatten the snapshot into a standalone image:"
  echo
  for c in "${FLATTEN_CMDS[@]}"; do
    echo "   $c"
  done
  echo
  echo "4. Delete the original snapshot file (you already have a backup)."
  echo "5. Rename the flattened file to replace the original."
  echo "6. Restart your VM and verify that it boots and operates correctly."
  echo
  hr
fi

echo
