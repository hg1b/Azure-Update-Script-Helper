#!/usr/bin/env bash
# =============================================================================
#  azdiag.sh - Azure Update Manager diagnostics, az CLI only
# -----------------------------------------------------------------------------
#  Runs the read-only AzUpdateMgr diag script on a VM through Run Command,
#  prints the summary, then pulls the full log (and summary JSON) back over
#  the same Run Command channel: gzip on the VM, base64, chunked under the
#  ~4 KB stdout cap, reassembled and verified locally.
#
#  Why this way: Run Command rides the Azure host channel (WireServer), so it
#  works on fully locked-down VMs with zero outbound internet. No storage
#  account, no SAS tokens, no PowerShell needed on your workstation.
#
#  Works in Azure Cloud Shell (bash) and locally on macOS/Linux.
#
#  Requirements:
#    - az CLI, logged in (az login), correct subscription selected or -s flag
#    - RBAC: Microsoft.Compute/virtualMachines/runCommand/action on the VM
#      (Virtual Machine Contributor covers it)
#    - AzUpdateMgr-Troubleshoot-Windows.ps1 / -Linux.sh in the same folder
#      as this script (only needed when actually running diagnostics)
#
#  Usage:
#    ./azdiag.sh -g <resource-group> -n <vm-name> [options]
#
#  Options:
#    -g, --resource-group   Resource group (required)
#    -n, --name             VM name (required)
#    -o, --os               windows | linux   (default: auto-detect from Azure)
#    -s, --subscription     Subscription name or id (default: current context)
#    -d, --outdir           Where to save retrieved files (default: .)
#        --full             Fetch the full log without prompting
#        --no-fetch         Summary only, skip log retrieval
#        --fetch-only       Skip diagnostics, just pull the newest existing log
#        --pattern <p>      Fetch an arbitrary remote file/glob instead
#                           (generic file grab; skips the summary JSON)
#        --chunk <n>        base64 chars per Run Command call (default 3000)
#        --keep-remote      Leave the temp transfer file on the VM
#    -h, --help             Show this help
#
#  Examples:
#    ./azdiag.sh -g AZ-RG-SYD-BI -n PRD-AS-IR-02
#    ./azdiag.sh -g AZ-RG-SYD-BI -n PRD-AS-IR-02 --fetch-only --full
#    ./azdiag.sh -g SOME-RG -n LNX-VM-01 -o linux --full
#    ./azdiag.sh -g RG -n VM --fetch-only --pattern 'C:\Temp\somefile.txt'
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RG=""
VM=""
OS_TYPE=""
SUBSCRIPTION=""
OUTDIR="."
CHUNK=3000
DO_FULL=0
NO_FETCH=0
FETCH_ONLY=0
KEEP_REMOTE=0
CUSTOM_PATTERN=""
CMD_ID=""
REMOTE_RESOLVED=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
  sed -n '3,45p' "$0" | sed 's/^#  \{0,1\}//; s/^#//'
  exit "${1:-0}"
}

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RG="$2"; shift 2 ;;
    -n|--name)           VM="$2"; shift 2 ;;
    -o|--os)             OS_TYPE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    -s|--subscription)   SUBSCRIPTION="$2"; shift 2 ;;
    -d|--outdir)         OUTDIR="$2"; shift 2 ;;
    --full)              DO_FULL=1; shift ;;
    --no-fetch)          NO_FETCH=1; shift ;;
    --fetch-only)        FETCH_ONLY=1; shift ;;
    --pattern)           CUSTOM_PATTERN="$2"; shift 2 ;;
    --chunk)             CHUNK="$2"; shift 2 ;;
    --keep-remote)       KEEP_REMOTE=1; shift ;;
    -h|--help)           usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done

[ -z "$RG" ] && { err "-g/--resource-group is required"; usage 1; }
[ -z "$VM" ] && { err "-n/--name is required"; usage 1; }
case "$CHUNK" in ''|*[!0-9]*) err "--chunk must be a number"; exit 1 ;; esac
if [ "$CHUNK" -gt 3800 ]; then
  err "--chunk over 3800 risks hitting the ~4 KB stdout cap, capping at 3800"
  CHUNK=3800
fi

command -v az >/dev/null 2>&1 || { err "az CLI not found. Install it or use Cloud Shell."; exit 1; }

WORKDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORKDIR"' EXIT

# ---- az helpers ---------------------------------------------------------------
azvm() {
  if [ -n "$SUBSCRIPTION" ]; then
    az "$@" --subscription "$SUBSCRIPTION"
  else
    az "$@"
  fi
}

# Run a script string (or @file) on the VM, return clean stdout.
run_remote() {
  local raw rc
  raw=$(azvm vm run-command invoke -g "$RG" -n "$VM" \
          --command-id "$CMD_ID" --scripts "$1" \
          --query 'value[0].message' -o tsv 2>"$WORKDIR/az.err")
  rc=$?
  if [ $rc -ne 0 ]; then
    err "az vm run-command invoke failed:"
    sed 's/^/  /' "$WORKDIR/az.err" >&2
    if grep -qi 'authorization\|AuthorizationFailed' "$WORKDIR/az.err"; then
      err "RBAC: your account needs Microsoft.Compute/virtualMachines/runCommand/action on this VM (Virtual Machine Contributor covers it). If it's PIM-eligible, activate it first."
    fi
    return 1
  fi
  if [ "$OS_TYPE" = "linux" ]; then
    printf '%s\n' "$raw" | tr -d '\r' | sed -n '/^\[stdout\]/,/^\[stderr\]/p' | sed '1d;$d'
  else
    printf '%s\n' "$raw" | tr -d '\r'
  fi
  return 0
}

# ---- remote script templates --------------------------------------------------
# __PATTERN__ / __START__ / __COUNT__ get substituted before sending.

read -r -d '' WIN_PREP <<'EOS'
$f = Get-ChildItem '__PATTERN__' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $f) { Write-Output 'META-NONE' }
else {
  $b  = [System.IO.File]::ReadAllBytes($f.FullName)
  $ms = New-Object System.IO.MemoryStream
  $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
  $gz.Write($b, 0, $b.Length)
  $gz.Close()
  $s = [Convert]::ToBase64String($ms.ToArray())
  [System.IO.File]::WriteAllText('C:\Windows\Temp\azdiag-transfer.b64', $s)
  Write-Output ('META|' + $f.FullName + '|' + $b.Length + '|' + $s.Length)
}
EOS

read -r -d '' WIN_CHUNK <<'EOS'
$s = [System.IO.File]::ReadAllText('C:\Windows\Temp\azdiag-transfer.b64')
$o = __START__
$c = __COUNT__
if ($o -lt $s.Length) { Write-Output $s.Substring($o, [Math]::Min($c, $s.Length - $o)) }
EOS

WIN_CLEAN="Remove-Item 'C:\Windows\Temp\azdiag-transfer.b64' -Force -ErrorAction SilentlyContinue; Write-Output 'CLEANED'"

read -r -d '' LIN_PREP <<'EOS'
f=$(ls -t __PATTERN__ 2>/dev/null | head -n 1)
if [ -z "$f" ]; then echo 'META-NONE'
else
  gzip -c "$f" | base64 -w0 > /tmp/azdiag-transfer.b64
  o=$(wc -c < "$f" | tr -d ' ')
  b=$(wc -c < /tmp/azdiag-transfer.b64 | tr -d ' ')
  printf 'META|%s|%s|%s\n' "$f" "$o" "$b"
fi
EOS

LIN_CHUNK="tail -c +__START__ /tmp/azdiag-transfer.b64 | head -c __COUNT__"
LIN_CLEAN="rm -f /tmp/azdiag-transfer.b64; echo CLEANED"

# ---- base64 decode portability (GNU vs BSD/macOS) -----------------------------
if printf 'dGVzdA==' | base64 -d >/dev/null 2>&1; then
  b64dec() { base64 -d; }
else
  b64dec() { base64 -D; }
fi

# ---- generic file fetch over Run Command --------------------------------------
# fetch_file <remote pattern or path> <local output path>
# Sets REMOTE_RESOLVED to the resolved remote path on success.
fetch_file() {
  local pattern="$1" outfile="$2"
  local prep chunk_tpl meta path osize b64size
  REMOTE_RESOLVED=""

  if [ "$OS_TYPE" = "windows" ]; then
    prep="${WIN_PREP//__PATTERN__/$pattern}"
    chunk_tpl="$WIN_CHUNK"
  else
    prep="${LIN_PREP//__PATTERN__/$pattern}"
    chunk_tpl="$LIN_CHUNK"
  fi

  log "Preparing transfer on VM (gzip + base64): $pattern"
  meta=$(run_remote "$prep") || return 1
  meta=$(printf '%s\n' "$meta" | grep '^META' | tail -n 1)
  if [ -z "$meta" ] || [ "$meta" = "META-NONE" ]; then
    err "File not found on VM: $pattern"
    return 1
  fi

  path=$(printf '%s' "$meta" | cut -d'|' -f2)
  osize=$(printf '%s' "$meta" | cut -d'|' -f3)
  b64size=$(printf '%s' "$meta" | cut -d'|' -f4)
  case "$osize$b64size" in *[!0-9]*) err "Bad META from VM: $meta"; return 1 ;; esac

  local total=$(( (b64size + CHUNK - 1) / CHUNK ))
  log "Remote file : $path"
  log "Size        : $osize bytes (${b64size} b64 chars compressed, $total chunks, ~20-40s per chunk)"

  local tmpb64="$WORKDIR/transfer.b64"
  local tmpgz="$WORKDIR/transfer.gz"
  : > "$tmpb64"

  local offset=0 i=0 chunk script tries
  while [ "$offset" -lt "$b64size" ]; do
    i=$((i + 1))
    printf '\r  chunk %d/%d ' "$i" "$total"
    # Windows Substring is 0-based, tail -c + is 1-based
    if [ "$OS_TYPE" = "windows" ]; then
      script="${chunk_tpl//__START__/$offset}"
    else
      script="${chunk_tpl//__START__/$(( offset + 1 ))}"
    fi
    script="${script//__COUNT__/$CHUNK}"

    tries=0
    while :; do
      chunk=$(run_remote "$script")
      if [ $? -eq 0 ]; then
        chunk=$(printf '%s' "$chunk" | tr -cd 'A-Za-z0-9+/=')
        [ -n "$chunk" ] && break
      fi
      tries=$((tries + 1))
      if [ "$tries" -ge 3 ]; then
        printf '\n'
        err "Chunk at offset $offset failed after 3 attempts. Re-run with --fetch-only to retry."
        return 1
      fi
      printf '\r  chunk %d/%d (retry %d) ' "$i" "$total" "$tries"
      sleep 3
    done

    printf '%s' "$chunk" >> "$tmpb64"
    offset=$(( offset + ${#chunk} ))
  done
  printf '\n'

  if ! b64dec < "$tmpb64" > "$tmpgz" 2>/dev/null; then
    err "base64 decode failed, transfer corrupted. Re-run with --fetch-only."
    return 1
  fi
  if ! gunzip -c "$tmpgz" > "$outfile" 2>/dev/null; then
    err "gunzip failed (CRC error), transfer corrupted. Re-run with --fetch-only."
    return 1
  fi

  local got
  got=$(wc -c < "$outfile" | tr -d ' ')
  if [ "$got" -ne "$osize" ]; then
    err "Size mismatch: got $got bytes, VM reported $osize. Treat the file as suspect."
    return 1
  fi

  log "  transfer OK ($got bytes, size verified)"
  REMOTE_RESOLVED="$path"
  return 0
}

cleanup_remote() {
  [ "$KEEP_REMOTE" -eq 1 ] && { log "Leaving transfer file on VM (--keep-remote)."; return 0; }
  local script="$LIN_CLEAN"
  [ "$OS_TYPE" = "windows" ] && script="$WIN_CLEAN"
  log "Cleaning up transfer file on VM..."
  run_remote "$script" >/dev/null 2>&1
}

# ---- main ---------------------------------------------------------------------
az account show -o none 2>/dev/null || { err "Not logged in. Run: az login"; exit 1; }

if [ -z "$OS_TYPE" ]; then
  log "Detecting OS type for $VM..."
  OS_TYPE=$(azvm vm show -g "$RG" -n "$VM" \
    --query 'storageProfile.osDisk.osType' -o tsv 2>"$WORKDIR/az.err" \
    | tr -d '\r' | tr '[:upper:]' '[:lower:]')
  if [ -z "$OS_TYPE" ]; then
    err "Could not detect OS type:"
    sed 's/^/  /' "$WORKDIR/az.err" >&2
    exit 1
  fi
  log "OS type: $OS_TYPE"
fi

case "$OS_TYPE" in
  windows)
    CMD_ID="RunPowerShellScript"
    DIAG_FILE="$SCRIPT_DIR/AzUpdateMgr-Troubleshoot-Windows.ps1"
    DEFAULT_PATTERN='C:\Windows\Temp\AzUpdateMgr-Diag-*.log'
    ;;
  linux)
    CMD_ID="RunShellScript"
    DIAG_FILE="$SCRIPT_DIR/AzUpdateMgr-Troubleshoot-Linux.sh"
    DEFAULT_PATTERN='/var/log/azupdatemgr-diag-*.log /tmp/azupdatemgr-diag-*.log'
    ;;
  *) err "OS must be windows or linux, got: $OS_TYPE"; exit 1 ;;
esac

mkdir -p "$OUTDIR" || exit 1
START_TS=$SECONDS

# Step 1: run diagnostics (unless --fetch-only)
if [ "$FETCH_ONLY" -eq 0 ]; then
  [ -f "$DIAG_FILE" ] || { err "Diag script not found: $DIAG_FILE (keep it next to azdiag.sh, or use --fetch-only)"; exit 1; }
  log ""
  log "=== Running diagnostics on $VM (this takes 20-60s plus Run Command overhead) ==="
  SUMMARY=$(run_remote "@$DIAG_FILE") || exit 1
  log ""
  printf '%s\n' "$SUMMARY"
  log ""
fi

# Step 2: decide whether to fetch
if [ "$NO_FETCH" -eq 1 ]; then
  log "Skipping log retrieval (--no-fetch)."
  exit 0
fi
if [ "$DO_FULL" -eq 0 ] && [ "$FETCH_ONLY" -eq 0 ]; then
  if [ -t 0 ]; then
    printf 'Fetch the full log now? [Y/n] '
    read -r ans
    case "$ans" in [Nn]*) log "Done. Re-run with --fetch-only later to pull the log."; exit 0 ;; esac
  fi
fi

# Step 3: fetch the log (and summary JSON when using the default pattern)
PATTERN="$DEFAULT_PATTERN"
FETCH_JSON=1
if [ -n "$CUSTOM_PATTERN" ]; then
  PATTERN="$CUSTOM_PATTERN"
  FETCH_JSON=0
fi

log ""
log "=== Retrieving full log from $VM ==="
TMP_OUT="$WORKDIR/fetched.bin"
fetch_file "$PATTERN" "$TMP_OUT" || { cleanup_remote; exit 1; }

# Name the local file after the VM + the remote filename
if [ "$OS_TYPE" = "windows" ]; then
  BASE="${REMOTE_RESOLVED##*\\}"
else
  BASE="${REMOTE_RESOLVED##*/}"
fi
LOG_LOCAL="$OUTDIR/${VM}-${BASE}"
mv "$TMP_OUT" "$LOG_LOCAL"
log "Full log    : $LOG_LOCAL"

# Summary JSON sits next to the log with the same stem
if [ "$FETCH_JSON" -eq 1 ]; then
  JSON_REMOTE="${REMOTE_RESOLVED%.log}-summary.json"
  if [ "$OS_TYPE" = "windows" ]; then
    JSON_BASE="${JSON_REMOTE##*\\}"
  else
    JSON_BASE="${JSON_REMOTE##*/}"
  fi
  JSON_LOCAL="$OUTDIR/${VM}-${JSON_BASE}"
  log ""
  log "=== Retrieving summary JSON ==="
  if fetch_file "$JSON_REMOTE" "$JSON_LOCAL"; then
    log "Summary JSON: $JSON_LOCAL"
  else
    log "Summary JSON not retrieved (log still fine)."
  fi
fi

cleanup_remote

ELAPSED=$(( SECONDS - START_TS ))
log ""
log "Done in ${ELAPSED}s."
log "Read order: Summary block at the bottom of the log, then the extension"
log ".status files, extension log tails, WU/package history, connectivity checks."
