# Azure Update Manager diagnostics

Troubleshoots Azure Update Manager assessment and install failures on any Azure VM. One command runs a read-only diagnostic on the VM, prints a health summary to your terminal, and pulls the full log back to your machine. Works on fully locked-down VMs with no outbound internet, because everything rides the Run Command channel through the Azure host.

## Files

| File | What it is |
|---|---|
| `azdiag.sh` | The tool you run. Handles everything. |
| `AzUpdateMgr-Troubleshoot-Windows.ps1` | Diagnostic collector, runs on Windows VMs |
| `AzUpdateMgr-Troubleshoot-Linux.sh` | Diagnostic collector, runs on Linux VMs |

Keep all three in the same folder. The collectors are strictly read-only: no installs, no restarts, no reboots, no config changes.

## Setup

### Option A: Azure Cloud Shell (nothing to install)

1. Go to https://portal.azure.com and click the Cloud Shell icon (>_) in the top bar
2. Pick Bash if asked
3. Upload the three files: Manage files > Upload, or clone the repo:
   ```
   git clone <repo-url>
   cd <repo-folder>
   chmod +x azdiag.sh
   ```
4. Cloud Shell is already logged in as you. Skip to "Pick your subscription".

### Option B: Local terminal (Mac, Linux, Windows)

1. Install the Azure CLI:
   ```
   # Mac
   brew install azure-cli

   # Ubuntu/Debian
   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

   # Windows
    winget install --id Microsoft.AzureCLI

   ```
2. Log in:
   ```
   az login
   ```
   A browser window opens. If it doesn't, use `az login --use-device-code` and follow the prompt.

3. Set Tenant Subscription
   ```
   az account set --subscription "subscription123"
   ```

4. Make the script executable (Mac Only!) (first time only):
   ```
   chmod +x azdiag.sh
   ```

### Pick your subscription

The tenant has many subscriptions, so set the one the VM lives in:

```
az account list --output table          # find it
az account set --subscription "SUB-NAME-OR-ID"
az account show --output table          # confirm
```

Or skip this and pass `-s "SUB-NAME-OR-ID"` on every azdiag run.

## Run it

Full diagnostic plus log retrieval, no prompts (Windows)
```
bash azdiag.sh -g <resource-group> -n <vm-name> --full
```

Full diagnostic plus log retrieval, no prompts (Mac)

```
./azdiag.sh -g <resource-group> -n <vm-name> --full
```

Example:

```
./azdiag.sh -g my-resource-group -n my-vm-01 --full
```

It auto-detects Windows vs Linux. Expect 8 to 10 minutes total. Almost all of that is Azure Run Command overhead (1 to 2 minutes per round trip), not data transfer. Progress prints as it goes.

### Other modes

```
# Summary only, don't pull the log
./azdiag.sh -g RG -n VM --no-fetch

# The log already exists on the VM from an earlier run, just pull it
./azdiag.sh -g RG -n VM --fetch-only

# Grab any arbitrary file off a VM (generic file grabber)
./azdiag.sh -g RG -n VM --fetch-only --pattern 'C:\Some\Path\file.txt'
./azdiag.sh -g RG -n VM --fetch-only --pattern '/var/log/syslog'

# Save retrieved files somewhere specific
./azdiag.sh -g RG -n VM --full -d ~/Desktop/myticket
```

All options: `./azdiag.sh -h`

## What you get

First, the summary prints straight to your terminal:

```
==============================================================================
 Azure Update Manager diagnostics  |  my-vm-01  (Windows)  v1.1.0
==============================================================================
 Verdict          : LOOKS HEALTHY
 OS               : Windows Server 2019 Datacenter  (build 17763.7009)
 Uptime           : 3.4 days  (booted 2026-07-09T03:11:02Z)
 Reboot pending   : No
 Disk free (C:)   : 70.7 GB
 WSUS             : Not configured (Microsoft Update direct)
 wuauserv         : Stopped / Manual
 Patch extension  : success  (as of 2026-07-12T04:26:31Z)
 Last install OK  : 2026-07-12T04:26:22Z  (KB5094123)
 Recent failures  : 0 in last 25 history entries
 Endpoints        : 7/7 reachable
 Warnings         : 0
 Errors           : 0
------------------------------------------------------------------------------
 Log file     : C:\Windows\Temp\AzUpdateMgr-Diag-20260712-102439Z.log  (146.2 KB)
 Summary JSON : C:\Windows\Temp\AzUpdateMgr-Diag-20260712-102439Z-summary.json
==============================================================================
```

The Verdict line is the quick read. LOOKS HEALTHY means nothing actionable was found. REVIEW WARNINGS means look at the listed warnings. NEEDS ATTENTION means something concrete is wrong: recent update failures, unreachable endpoints, a disabled Windows Update service, a failed patch extension, or errors during collection.

Then two files land in your current directory (or `-d` dir), prefixed with the VM name so nothing overwrites:

```
my-vm-01-AzUpdateMgr-Diag-20260712-102439Z.log            full diagnostic log
my-vm-01-AzUpdateMgr-Diag-20260712-102439Z-summary.json   machine-readable summary
```

## Reading the full log

Work through it in this order:

1. Summary block at the bottom: verdict inputs, warnings, disk, reboot state
2. Update Manager extensions on disk: the newest `.status` file is what Azure Update Manager actually reads. A failing operation shows its HRESULT and error text here
3. Update extension logs (tails): the underlying reason (network, permissions, WSUS, disk)
4. Windows Update client recent history: the actual failing KB with its HRESULT
5. Connectivity to update endpoints: any FAIL here means the fault is upstream of the VM (NSG, firewall, proxy, private endpoint)

## If it fails

**403 / AuthorizationFailed**: your account needs the `Microsoft.Compute/virtualMachines/runCommand/action` permission on the VM. Virtual Machine Contributor covers it. If your role is PIM-eligible, activate it first. The script prints this hint when it detects the error.

**Not logged in**: run `az login`, then `az account set --subscription ...`.

**File not found on VM (--fetch-only)**: no diagnostic log exists on that VM yet. Run without `--fetch-only` to generate one.

**A chunk fails mid-transfer**: the script retries each chunk 3 times. If it still aborts, re-run with `--fetch-only`. Every transfer is size-verified and CRC-checked, so a corrupted download fails loudly instead of silently giving you a broken file.

## How it works

The diagnostic script runs on the VM via `az vm run-command invoke` and writes its full report to disk on the VM (Run Command caps stdout at about 4 KB, far too small for a real log). To get the report back, the VM compresses the log and summary JSON into one archive, base64s it, and azdiag pulls it down in chunks sized under the stdout cap, then reassembles, decompresses, and verifies locally. No storage account, no SAS tokens, no network path to the VM needed. The VM agent being healthy is the only requirement.