#!/usr/bin/env bash
# =============================================================================
#  azdiag.sh v2 - Azure Update Manager diagnostics, az CLI only
# -----------------------------------------------------------------------------
#  Runs the read-only AzUpdateMgr diag script on a VM through Run Command,
#  prints the summary, then pulls the full log AND summary JSON back over the
#  same Run Command channel. Works on fully locked-down VMs (no outbound
#  internet needed), in Cloud Shell or locally. No PowerShell required.
#
#  v2 speed changes (each az Run Command call costs 1-2 min of Azure overhead,
#  so the whole game is fewer calls):
#    - log + summary JSON bundled into one archive on the VM (one transfer)
#    - Windows: stdout AND stderr used as two parallel channels per call,
#      ~7 KB of base64 per round trip instead of ~3.5 KB
#    - transfer temp file deletes itself on the final chunk (no cleanup call)
#    - with --full, the compress/encode prep is folded into the same call
#      that runs the diagnostics (no separate prep call)
#  Typical Windows full run: ~5 calls total instead of ~13.
#
#  Requirements:
#    - az CLI, logged in, correct subscription selected (or -s)
#    - RBAC: Microsoft.Compute/virtualMachines/runCommand/action on the VM
#    - unzip (for Windows targets) / tar (for Linux targets) locally
#    - AzUpdateMgr-Troubleshoot-Windows.ps1 / -Linux.sh next to this script
#      (not needed for --fetch-only)
#
#  Usage:
#    ./azdiag.sh -g <resource-group> -n <vm-name> [options]
#
#  Options:
#    -g, --resource-group   Resource group (required)
#    -n, --name             VM name (required)
#    -o, --os               windows | linux   (default: auto-detect)
#    -s, --subscription     Subscription name or id (default: current context)
#    -d, --outdir           Where to save retrieved files (default: .)
#        --full             Fetch the full log without prompting (fastest path)
#        --no-fetch         Summary only, skip retrieval
#        --fetch-only       Skip diagnostics, pull the newest existing log
#        --pattern <p>      Fetch an arbitrary remote file/glob instead
#        --chunk <n>        base64 chars per channel per call (default 3600)
#    -h, --help             Show this help
#
#  Examples:
#    ./azdiag.sh -g my-resource-group -n my-vm-01 --full
#    ./azdiag.sh -g my-resource-group -n my-vm-01 --fetch-only
#    ./azdiag.sh -g RG -n VM --fetch-only --pattern 'C:\Temp\somefile.txt'
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RG=""
VM=""
OS_TYPE=""
SUBSCRIPTION=""
OUTDIR="."
CHUNK=3600
DO_FULL=0
NO_FETCH=0
FETCH_ONLY=0
CUSTOM_PATTERN=""
CMD_ID=""
REMOTE_RESOLVED=""
META_LINE=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
  sed -n '3,49p' "$0" | sed 's/^#  \{0,1\}//; s/^#//'
  exit "${1:-0}"
}

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
    -h|--help)           usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done

[ -z "$RG" ] && { err "-g/--resource-group is required"; usage 1; }
[ -z "$VM" ] && { err "-n/--name is required"; usage 1; }
case "$CHUNK" in ''|*[!0-9]*) err "--chunk must be a number"; exit 1 ;; esac
if [ "$CHUNK" -gt 3800 ]; then
  err "--chunk over 3800 risks the ~4 KB stdout cap, capping at 3800"
  CHUNK=3800
fi

command -v az >/dev/null 2>&1 || { err "az CLI not found. Install it or use Cloud Shell."; exit 1; }

WORKDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORKDIR"' EXIT

azvm() {
  if [ -n "$SUBSCRIPTION" ]; then
    az "$@" --subscription "$SUBSCRIPTION"
  else
    az "$@"
  fi
}

# When bash runs on Windows (WSL or Git Bash) but az is the WINDOWS CLI, @file
# paths must be Windows-visible or az silently passes the literal '@...' text
# through as the script. Detect the combo and translate paths.
AZ_PATH_MODE=none
if command -v cygpath >/dev/null 2>&1; then
  AZ_PATH_MODE=cygpath   # Git Bash / MSYS: az there is always the Windows CLI
elif command -v wslpath >/dev/null 2>&1; then
  case "$(command -v az 2>/dev/null)" in /mnt/*) AZ_PATH_MODE=wslpath ;; esac
fi

native_path() {
  case "$AZ_PATH_MODE" in
    wslpath) wslpath -w "$1" ;;
    cygpath) cygpath -w "$1" ;;
    *)       printf '%s' "$1" ;;
  esac
}

az_fail() {
  err "az vm run-command invoke failed:"
  sed 's/^/  /' "$WORKDIR/az.err" >&2
  if grep -qi 'authorization\|AuthorizationFailed' "$WORKDIR/az.err"; then
    err "RBAC: you need Microsoft.Compute/virtualMachines/runCommand/action on this VM (Virtual Machine Contributor covers it). If it's PIM-eligible, activate first."
  fi
}

# Single-channel remote exec: returns clean stdout. Used for diag run and prep.
# Pulls both stdout and stderr in one call (joined with a delimiter via JMESPath)
# so that when a remote script fails silently, the stderr is actually shown
# instead of azdiag printing nothing.
run_remote() {
  local raw out errp
  raw=$(azvm vm run-command invoke -g "$RG" -n "$VM" \
          --command-id "$CMD_ID" --scripts "$1" \
          --query "join('__AZDIAG_SPLIT__', value[].message)" -o tsv 2>"$WORKDIR/az.err") || { az_fail; return 1; }
  raw=$(printf '%s\n' "$raw" | tr -d '\r')
  case "$raw" in
    *__AZDIAG_SPLIT__*)
      out="${raw%%__AZDIAG_SPLIT__*}"
      errp="${raw#*__AZDIAG_SPLIT__}"
      ;;
    *)
      out="$raw"
      errp=""
      ;;
  esac
  if [ "$OS_TYPE" = "linux" ]; then
    # Linux returns one message containing [stdout]/[stderr] sections
    errp=$(printf '%s\n' "$out" | sed -n '/^\[stderr\]/,$p' | sed '1d')
    out=$(printf '%s\n' "$out" | sed -n '/^\[stdout\]/,/^\[stderr\]/p' | sed '1d;$d')
  fi
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] && [ -n "$(printf '%s' "$errp" | tr -d '[:space:]')" ]; then
    err "Remote script produced no stdout. Remote stderr was:"
    printf '%s\n' "$errp" | sed 's/^/  | /' >&2
    if printf '%s' "$errp" | grep -qi 'RunCommand.*denied\|Access to the path.*script[0-9]*\.ps1'; then
      err "Hint: access denied on the Run Command extension's own script path usually means antivirus/ASR is blocking the script (large scripts with base64 can trip 'obfuscated script' rules), or the extension is wedged. Try a trivial script first (--scripts \"whoami\"), and if that also fails, reset the extension: az vm run-command invoke --command-id RemoveRunCommandWindowsExtension -g <rg> -n <vm>"
    fi
  fi
  printf '%s\n' "$out"
}

# Dual-channel chunk fetch (Windows): reads both stdout and stderr messages,
# extracts sentinel-wrapped base64 from each, returns them concatenated.
run_chunk_win() {
  local raw flat a b
  raw=$(azvm vm run-command invoke -g "$RG" -n "$VM" \
          --command-id "$CMD_ID" --scripts "$1" \
          --query 'value[].message' -o tsv 2>"$WORKDIR/az.err") || { az_fail; return 1; }
  flat=$(printf '%s' "$raw" | tr -d ' \t\r\n')
  a=$(printf '%s' "$flat" | sed -n 's|.*A>\([A-Za-z0-9+/=]*\)<A.*|\1|p')
  b=$(printf '%s' "$flat" | sed -n 's|.*B>\([A-Za-z0-9+/=]*\)<B.*|\1|p')
  printf '%s%s' "$a" "$b"
}

# Single-channel chunk fetch (Linux).
run_chunk_lin() {
  local out
  out=$(run_remote "$1") || return 1
  printf '%s' "$out" | tr -cd 'A-Za-z0-9+/='
}

# ---- remote script templates --------------------------------------------------
# Prep: resolve newest match of pattern, bundle it (plus its -summary.json if
# one exists) into an archive, base64 it to a transfer file, emit META.
# META|<resolved path>|<total original bytes>|<b64 length>|<file count>

read -r -d '' WIN_PREP <<'EOS'
$f = Get-ChildItem '__PATTERN__' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $f) { Write-Output 'META-NONE' }
else {
  $files = @($f.FullName)
  $j = $f.FullName -replace '\.log$', '-summary.json'
  if (($j -ne $f.FullName) -and (Test-Path -LiteralPath $j)) { $files += $j }
  $zip = 'C:\Windows\Temp\azdiag-transfer.zip'
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Compress-Archive -LiteralPath $files -DestinationPath $zip -Force
  $s = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  [System.IO.File]::WriteAllText('C:\Windows\Temp\azdiag-transfer.b64', $s)
  $tot = 0
  foreach ($x in $files) { $tot += (Get-Item -LiteralPath $x).Length }
  Write-Output ('META|' + $f.FullName + '|' + $tot + '|' + $s.Length + '|' + $files.Count)
}
EOS

# Dual-channel chunk with sentinels; self-deletes the transfer file once the
# requested range reaches EOF. Sentinels (>, < are not base64 chars) keep any
# stray stderr noise from corrupting the stream.
read -r -d '' WIN_CHUNK <<'EOS'
try {
  $p = 'C:\Windows\Temp\azdiag-transfer.b64'
  $s = [System.IO.File]::ReadAllText($p)
  $o = __START__
  $c = __COUNT__
  if ($o -lt $s.Length) { Write-Output ('A>' + $s.Substring($o, [Math]::Min($c, $s.Length - $o)) + '<A') }
  $o2 = $o + $c
  if ($o2 -lt $s.Length) { [Console]::Error.Write('B>' + $s.Substring($o2, [Math]::Min($c, $s.Length - $o2)) + '<B') }
  if (($o + $c) -ge $s.Length) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
} catch { }
EOS

read -r -d '' LIN_PREP <<'EOS'
f=$(ls -t __PATTERN__ 2>/dev/null | head -n 1)
if [ -z "$f" ]; then echo 'META-NONE'
else
  d=$(dirname "$f")
  set -- "$(basename "$f")"
  j="${f%.log}-summary.json"
  if [ "$j" != "$f" ] && [ -f "$j" ]; then set -- "$@" "$(basename "$j")"; fi
  tar -czf /tmp/azdiag-transfer.tgz -C "$d" "$@"
  base64 -w0 /tmp/azdiag-transfer.tgz > /tmp/azdiag-transfer.b64
  rm -f /tmp/azdiag-transfer.tgz
  tot=0
  for x in "$@"; do tot=$(( tot + $(wc -c < "$d/$x") )); done
  printf 'META|%s|%s|%s|%s\n' "$f" "$tot" "$(wc -c < /tmp/azdiag-transfer.b64 | tr -d ' ')" "$#"
fi
EOS

read -r -d '' LIN_CHUNK <<'EOS'
tail -c +__START__ /tmp/azdiag-transfer.b64 | head -c __COUNT__
sz=$(wc -c < /tmp/azdiag-transfer.b64 | tr -d ' ')
if [ $(( __START__ - 1 + __COUNT__ )) -ge "$sz" ]; then rm -f /tmp/azdiag-transfer.b64; fi
EOS

# ---- base64 decode portability (GNU vs BSD/macOS) -----------------------------
if printf 'dGVzdA==' | base64 -d >/dev/null 2>&1; then
  b64dec() { base64 -d; }
else
  b64dec() { base64 -D; }
fi

# ---- transfer: chunk loop + decode + extract + verify --------------------------
have_zip_extractor() {
  command -v unzip   >/dev/null 2>&1 && return 0
  command -v python3 >/dev/null 2>&1 && return 0
  return 1
}

extract_zip() {  # $1 = zip file, $2 = dest dir
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -qq "$1" -d "$2"
  else
    python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  fi
}

# Uses META_LINE (already parsed by caller into args). Extracted files land in
# OUTDIR prefixed with the VM name.
do_transfer() {
  local osize="$1" b64size="$2" fcount="$3"
  local channels=1 per_call
  [ "$OS_TYPE" = "windows" ] && channels=2
  per_call=$(( CHUNK * channels ))
  local total=$(( (b64size + per_call - 1) / per_call ))

  # Fail fast BEFORE spending round trips if we can't extract at the end
  if [ "$OS_TYPE" = "windows" ] && ! have_zip_extractor; then
    err "No zip extractor found locally (need unzip or python3)."
    err "Install one first, e.g.: sudo apt install unzip"
    return 1
  fi

  log "Transfer    : $osize bytes in $fcount file(s), $b64size b64 chars, $total round trips (each 1-2 min of Azure overhead)"

  local tmpb64="$WORKDIR/transfer.b64"
  local tmparc="$WORKDIR/transfer.arc"
  : > "$tmpb64"

  local offset=0 i=0 chunk script tries
  while [ "$offset" -lt "$b64size" ]; do
    i=$((i + 1))
    printf '\r  chunk %d/%d ' "$i" "$total"
    if [ "$OS_TYPE" = "windows" ]; then
      script="${WIN_CHUNK//__START__/$offset}"
    else
      script="${LIN_CHUNK//__START__/$(( offset + 1 ))}"
    fi
    script="${script//__COUNT__/$CHUNK}"

    tries=0
    while :; do
      if [ "$OS_TYPE" = "windows" ]; then
        chunk=$(run_chunk_win "$script")
      else
        chunk=$(run_chunk_lin "$script")
      fi
      [ $? -eq 0 ] && [ -n "$chunk" ] && break
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

  if ! b64dec < "$tmpb64" > "$tmparc" 2>/dev/null; then
    err "base64 decode failed, transfer corrupted. Re-run with --fetch-only."
    return 1
  fi

  local exdir="$WORKDIR/extract"
  mkdir -p "$exdir"
  if [ "$OS_TYPE" = "windows" ]; then
    if ! extract_zip "$tmparc" "$exdir"; then
      cp "$tmparc" "$OUTDIR/${VM}-diag-transfer.zip"
      err "Extraction failed, but the transfer is saved: $OUTDIR/${VM}-diag-transfer.zip"
      err "Extract it manually (unzip / Expand-Archive) - no need to re-transfer."
      return 1
    fi
  else
    if ! tar -xzf "$tmparc" -C "$exdir"; then
      cp "$tmparc" "$OUTDIR/${VM}-diag-transfer.tgz"
      err "Extraction failed, but the transfer is saved: $OUTDIR/${VM}-diag-transfer.tgz"
      err "Extract it manually (tar -xzf) - no need to re-transfer."
      return 1
    fi
  fi

  local got=0 fn sz saved=""
  for fn in "$exdir"/*; do
    [ -f "$fn" ] || continue
    sz=$(wc -c < "$fn" | tr -d ' ')
    got=$(( got + sz ))
    mv "$fn" "$OUTDIR/${VM}-$(basename "$fn")"
    saved="$saved
  $OUTDIR/${VM}-$(basename "$fn") ($sz bytes)"
  done

  if [ "$got" -ne "$osize" ]; then
    err "Size mismatch: extracted $got bytes, VM reported $osize. Treat files as suspect."
    return 1
  fi
  log "Saved (size verified):$saved"
  return 0
}

# parse_meta <text> -> sets REMOTE_RESOLVED, M_OSIZE, M_B64, M_COUNT. rc 1 if absent.
parse_meta() {
  local m
  m=$(printf '%s\n' "$1" | grep '^META' | tail -n 1)
  [ -z "$m" ] || [ "$m" = "META-NONE" ] && return 1
  REMOTE_RESOLVED=$(printf '%s' "$m" | cut -d'|' -f2)
  M_OSIZE=$(printf '%s' "$m" | cut -d'|' -f3)
  M_B64=$(printf '%s' "$m" | cut -d'|' -f4)
  M_COUNT=$(printf '%s' "$m" | cut -d'|' -f5)
  case "$M_OSIZE$M_B64$M_COUNT" in *[!0-9]*|'') return 1 ;; esac
  return 0
}

fetch_via_prep() {
  local pattern="$1" prep out
  if [ "$OS_TYPE" = "windows" ]; then
    prep="${WIN_PREP//__PATTERN__/$pattern}"
  else
    prep="${LIN_PREP//__PATTERN__/$pattern}"
  fi
  log "Preparing transfer on VM: $pattern"
  out=$(run_remote "$prep") || return 1
  if ! parse_meta "$out"; then
    err "File not found on VM (or bad META): $pattern"
    return 1
  fi
  log "Remote file : $REMOTE_RESOLVED"
  do_transfer "$M_OSIZE" "$M_B64" "$M_COUNT"
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
PATTERN="$DEFAULT_PATTERN"
[ -n "$CUSTOM_PATTERN" ] && PATTERN="$CUSTOM_PATTERN"

HAVE_META=0

# Step 1: run diagnostics (unless --fetch-only). With --full and the default
# pattern, the prep is appended to the same call, saving a full round trip.
if [ "$FETCH_ONLY" -eq 0 ]; then
  [ -f "$DIAG_FILE" ] || { err "Diag script not found: $DIAG_FILE (keep it next to azdiag.sh, or use --fetch-only)"; exit 1; }

  FOLD_PREP=0
  if [ "$DO_FULL" -eq 1 ] && [ -z "$CUSTOM_PATTERN" ] && [ "$NO_FETCH" -eq 0 ]; then
    FOLD_PREP=1
  fi

  log ""
  log "=== Running diagnostics on $VM ==="
  if [ "$FOLD_PREP" -eq 1 ]; then
    # Write the combined script to a temp file and send it via @file. Large
    # inline script strings have been observed silently not executing through
    # az vm run-command invoke; the @file path is the transport that is
    # proven to work for the full-size diag script.
    COMBINED_FILE="$WORKDIR/combined-diag"
    if [ "$OS_TYPE" = "windows" ]; then
      { cat "$DIAG_FILE"; printf '\n'; printf '%s\n' "${WIN_PREP//__PATTERN__/$PATTERN}"; } > "$COMBINED_FILE"
    else
      { cat "$DIAG_FILE"; printf '\n'; printf '%s\n' "${LIN_PREP//__PATTERN__/$PATTERN}"; } > "$COMBINED_FILE"
    fi
    OUT=$(run_remote "@$(native_path "$COMBINED_FILE")") || exit 1
    if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
      # Combined call produced nothing at all: the script likely never ran.
      # Fall back to the plain standalone diag call, then prep separately.
      err "Combined diagnostics call returned no output. Falling back to standalone diagnostics run."
      OUT=$(run_remote "@$(native_path "$DIAG_FILE")") || exit 1
      printf '%s\n' "$OUT"
    else
      printf '%s\n' "$OUT" | grep -v '^META'
      if parse_meta "$OUT"; then
        HAVE_META=1
        log "Remote file : $REMOTE_RESOLVED"
      fi
    fi
  else
    OUT=$(run_remote "@$(native_path "$DIAG_FILE")") || exit 1
    printf '%s\n' "$OUT"
  fi
  log ""
fi

# Step 2: decide whether to fetch
if [ "$NO_FETCH" -eq 1 ]; then
  log "Skipping retrieval (--no-fetch)."
  exit 0
fi
if [ "$DO_FULL" -eq 0 ] && [ "$FETCH_ONLY" -eq 0 ] && [ -t 0 ]; then
  printf 'Fetch the full log now? [Y/n] '
  read -r ans
  case "$ans" in [Nn]*) log "Done. Re-run with --fetch-only later to pull the log."; exit 0 ;; esac
fi

# Step 3: fetch
log ""
log "=== Retrieving from $VM ==="
if [ "$HAVE_META" -eq 1 ]; then
  do_transfer "$M_OSIZE" "$M_B64" "$M_COUNT" || exit 1
else
  fetch_via_prep "$PATTERN" || exit 1
fi

ELAPSED=$(( SECONDS - START_TS ))
log ""
log "Done in ${ELAPSED}s."
log "Read order: Summary block at the bottom of the log, then extension .status"
log "files, extension log tails, WU/package history, connectivity checks."