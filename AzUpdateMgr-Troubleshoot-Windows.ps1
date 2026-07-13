<#
.SYNOPSIS
    Read-only diagnostic collector for Azure Update Manager failures on Windows VMs.

.DESCRIPTION
    Designed to be pasted into Azure Run Command (RunPowerShellScript) or the
    Portal "Run command" blade. It:
      * Makes NO changes to the VM (no service restarts, no registry edits,
        no cache resets, no reboots). Every operation is read-only.
      * Writes a full report to C:\Windows\Temp\AzUpdateMgr-Diag-<timestamp>.log
        and a machine-readable summary to ...-summary.json alongside it.
      * Prints only a compact SUMMARY to stdout, because Azure Run Command
        truncates output to roughly the last 4 KB. Pull the full log off the
        VM afterwards (see "Retrieving the log" at the bottom).
      * Guards every check with try/catch and short timeouts so a single
        broken component cannot abort the run.

.NOTES
    Version        : 1.0.0
    Target         : Windows Server 2016/2019/2022/2025, Windows 10/11 Azure VMs
    Privilege      : Run Command executes as SYSTEM, which is what we need.
    Idempotent     : Yes. Safe to run repeatedly.
    Side effects   : None. If you spot anything that writes outside
                     C:\Windows\Temp\AzUpdateMgr-Diag-*, treat it as a bug.
#>

[CmdletBinding()]
param(
    [int]$TailLines           = 200,   # lines to tail from each large log
    [int]$RecentUpdateCount   = 25,    # hotfixes / update history entries to show
    [int]$EventCount          = 50,    # events per event-log query
    [int]$PerCommandTimeoutSec = 45    # per-external-command timeout
)

# --- Bootstrap ---------------------------------------------------------------
$ScriptVersion = '1.1.0'
$ErrorActionPreference = 'Continue'    # never let one failure kill the script
$ProgressPreference    = 'SilentlyContinue'
$startedUtc            = (Get-Date).ToUniversalTime()
$stamp                 = $startedUtc.ToString('yyyyMMdd-HHmmssZ')
$outDir                = 'C:\Windows\Temp'
$logPath               = Join-Path $outDir "AzUpdateMgr-Diag-$stamp.log"
$jsonPath              = Join-Path $outDir "AzUpdateMgr-Diag-$stamp-summary.json"
$summary               = [ordered]@{
    ScriptVersion      = $ScriptVersion
    StartedUtc         = $startedUtc.ToString('o')
    Hostname           = $env:COMPUTERNAME
    LogPath            = $logPath
    Warnings           = New-Object System.Collections.Generic.List[string]
    Errors             = New-Object System.Collections.Generic.List[string]
}

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Write-Section {
    param([string]$Title)
    $bar = '=' * 78
    Add-Content -LiteralPath $logPath -Value "`r`n$bar`r`n== $Title`r`n$bar" -Encoding UTF8
}

function Invoke-Safe {
    <#
        Runs a scriptblock, captures its output into the log file, and never
        throws. Adds an entry to $summary.Errors if it fails.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Script
    )
    Write-Section $Name
    Write-Log "BEGIN: $Name"
    try {
        # *>&1 merges every stream (errors, warnings, information) so nothing
        # bypasses the log; -Width stops Out-String truncating wide tables at
        # the host buffer (~120 chars), which silently dropped column data.
        $out = & $Script *>&1
        if ($null -ne $out) {
            # Count non-terminating error records that were merged into the
            # output stream so the summary's error count reflects reality.
            $errCount = ($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count
            if ($errCount -gt 0) {
                $summary.Errors.Add("$errCount non-terminating error(s) in section '$Name'")
            }
            $text = ($out | Out-String -Width 4096).TrimEnd()
            if ($text) { Add-Content -LiteralPath $logPath -Value $text -Encoding UTF8 }
        }
    } catch {
        $msg = "ERROR in '$Name': $($_.Exception.Message)"
        Write-Log $msg 'ERROR'
        $summary.Errors.Add($msg)
    }
    Write-Log "END:   $Name"
}

function Get-TailFile {
    param([string]$Path, [int]$Lines = $TailLines)
    if (-not (Test-Path -LiteralPath $Path)) { return "  <not found: $Path>" }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSIsContainer) {
            # A directory was passed (e.g. C:\WindowsAzure\Logs\AggregateStatus).
            # Tail the most recently modified file inside it instead of failing.
            $newest = Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $newest) { return "  <directory contains no files: $Path>" }
            $item = $newest
        }
        $header = "  >> $($item.FullName)  ($([math]::Round($item.Length/1KB,1)) KB, modified $($item.LastWriteTime.ToString('s')))"
        $tail = Get-Content -LiteralPath $item.FullName -Tail $Lines -ErrorAction Stop
        return @($header, '  ---- tail begin ----') + ($tail | ForEach-Object { '  ' + $_ }) + '  ---- tail end ----'
    } catch {
        return "  <cannot read '$Path': $($_.Exception.Message)>"
    }
}

# --- Header ------------------------------------------------------------------
Write-Section 'Azure Update Manager - Windows diagnostic'
Write-Log "Script version: $ScriptVersion"
Write-Log ("Script started {0} UTC on {1}" -f $startedUtc, $env:COMPUTERNAME)
Write-Log  "Read-only mode. No changes will be made to this VM."

# 1. OS + machine identity ----------------------------------------------------
Invoke-Safe 'OS and hardware' {
    Get-ComputerInfo -Property `
        CsName, CsDomain, OsName, OsVersion, OsBuildNumber, OsArchitecture, `
        OsInstallDate, OsLastBootUpTime, OsUptime, CsManufacturer, CsModel, `
        WindowsProductName, WindowsInstallationType, WindowsRegisteredOrganization |
        Format-List
}

# 2. Azure instance metadata (IMDS, no auth needed, 169.254.169.254) ----------
Invoke-Safe 'Azure Instance Metadata (IMDS)' {
    try {
        $imds = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
            -Headers @{ Metadata = 'true' } `
            -TimeoutSec 5 -Proxy $null
        $imds | ConvertTo-Json -Depth 6
        $summary.VmId          = $imds.compute.vmId
        $summary.ResourceId    = $imds.compute.resourceId
        $summary.SubscriptionId= $imds.compute.subscriptionId
        $summary.Location      = $imds.compute.location
        $summary.VmSize        = $imds.compute.vmSize
        $summary.VmName        = $imds.compute.name
        $summary.ResourceGroup = $imds.compute.resourceGroupName
    } catch {
        "IMDS unreachable: $($_.Exception.Message)"
    }
}

# 3. VM agent (WindowsAzureGuestAgent) health ---------------------------------
Invoke-Safe 'Azure VM Guest Agent' {
    $svcs = @('WindowsAzureGuestAgent','RdAgent','WindowsAzureNetAgentSvc')
    Get-Service -Name $svcs -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize

    # Search both well-known locations for guest agent version folders.
    $agentDirs = @('C:\WindowsAzure', 'C:\WindowsAzure\Packages')
    foreach ($agentDir in $agentDirs) {
        if (Test-Path $agentDir) {
            Get-ChildItem $agentDir -Filter 'GuestAgent_*' -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 3 Name, LastWriteTime | Format-Table -AutoSize
        }
    }

    $aggregate = 'C:\WindowsAzure\Logs\AggregateStatus'
    Get-TailFile -Path $aggregate -Lines 80
}

# 4. Update Manager extension state ------------------------------------------
Invoke-Safe 'Update Manager extensions on disk' {
    $pluginRoot = 'C:\Packages\Plugins'
    if (-not (Test-Path $pluginRoot)) {
        "  <no C:\Packages\Plugins directory - VM agent may never have installed extensions>"
        return
    }
    $wanted = @(
        'Microsoft.CPlat.Core.WindowsPatchExtension',
        'Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension',
        'Microsoft.CPlat.Core.RunCommandHandlerWindows',
        'Microsoft.CPlat.Core.RunCommandWindows'
    )
    foreach ($ext in $wanted) {
        # NB: do not name this $matches - that clobbers the automatic $Matches
        # variable and can be silently overwritten by any later -match operator.
        $extMatches = Get-ChildItem $pluginRoot -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "$ext*" }
        if (-not $extMatches) { "  <not installed: $ext>"; continue }
        foreach ($m in $extMatches) {
            "  {0}   (modified {1})" -f $m.FullName, $m.LastWriteTime
            $statusDir = Join-Path $m.FullName 'Status'
            if (Test-Path $statusDir) {
                Get-ChildItem $statusDir -Filter *.status -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
                    ForEach-Object {
                        "    status file: $($_.Name)  ($($_.LastWriteTime))"
                        try {
                            $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                            ($raw | ConvertFrom-Json -ErrorAction Stop) |
                                ConvertTo-Json -Depth 8
                        } catch {
                            "    (could not parse: $($_.Exception.Message))"
                        }
                    }
            }
        }
    }

    # Surface the newest patch-extension status into the summary. This .status
    # record is exactly what Azure Update Manager reads, so it is the single
    # fastest signal when an assessment or install "fails" in the portal.
    try {
        $statusFile = Get-ChildItem $pluginRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.CPlat.Core.WindowsPatchExtension*' -or
                           $_.Name -like 'Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension*' } |
            ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'Status') -Filter *.status -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($statusFile) {
            $st = Get-Content -LiteralPath $statusFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($st -is [array]) { $st = $st[0] }
            $extMsg = $null
            if ($st.status.formattedMessage.message) {
                $extMsg = ($st.status.formattedMessage.message -replace '\s+', ' ').Trim()
                if ($extMsg.Length -gt 300) { $extMsg = $extMsg.Substring(0, 300) + '...' }
            }
            $summary.PatchExtensionStatus = [pscustomobject]@{
                Status    = "$($st.status.status)"
                Operation = "$($st.status.operation)"
                Code      = $st.status.code
                Message   = $extMsg
                TimeUtc   = $statusFile.LastWriteTime.ToUniversalTime().ToString('s') + 'Z'
            }
            if ($st.status.status -and "$($st.status.status)" -notmatch '^(?i)(success|transitioning)') {
                $summary.Warnings.Add("Patch extension latest status is '$($st.status.status)' ($($statusFile.LastWriteTime)): $extMsg") | Out-Null
            }
        }
    } catch { }
}

Invoke-Safe 'Update extension logs (tails)' {
    $extLogRoot = 'C:\WindowsAzure\Logs\Plugins'
    if (-not (Test-Path $extLogRoot)) {
        "  <no $extLogRoot directory>"
        return
    }
    $extDirs = Get-ChildItem $extLogRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Patch|Update|Software' }
    foreach ($d in $extDirs) {
        "  ---- $($d.FullName) ----"
        Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.log$|\.txt$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6 |
            ForEach-Object { Get-TailFile -Path $_.FullName -Lines $TailLines }
    }
    # Azure Arc-enabled servers path
    $arcLogs = 'C:\ProgramData\GuestConfig\extension_logs\Microsoft.SoftwareUpdateManagement.WindowsOsUpdateExtension'
    if (Test-Path $arcLogs) {
        "  ---- Arc: $arcLogs ----"
        Get-ChildItem $arcLogs -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6 |
            ForEach-Object { Get-TailFile -Path $_.FullName -Lines $TailLines }
    }
}

# 5. Windows Update service stack + config -----------------------------------
Invoke-Safe 'Windows Update services (read-only, no restart)' {
    $svcs = 'wuauserv','bits','cryptsvc','trustedinstaller','msiserver','usosvc'
    Get-Service -Name $svcs -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
}

Invoke-Safe 'Windows Update / WSUS registry policy' {
    $keys = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update',
        'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    )
    foreach ($k in $keys) {
        "---- $k ----"
        if (Test-Path $k) {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS* | Format-List
        } else { "  <key not present>" }
    }
}

# 5a. WSUS client configuration (UseWUServer / WUServer / WUStatusServer) -----
Invoke-Safe 'WSUS client configuration' {
    $policyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $policyAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

    $wuServer       = (Get-ItemProperty -Path $policyKey   -Name WUServer       -ErrorAction SilentlyContinue).WUServer
    $wuStatusServer = (Get-ItemProperty -Path $policyKey   -Name WUStatusServer -ErrorAction SilentlyContinue).WUStatusServer
    $useWUServer    = (Get-ItemProperty -Path $policyAuKey -Name UseWUServer    -ErrorAction SilentlyContinue).UseWUServer

    [pscustomobject]@{
        UseWUServer    = if ($null -ne $useWUServer) { $useWUServer } else { '<not set>' }
        WUServer       = if ($wuServer)              { $wuServer }    else { '<not set>' }
        WUStatusServer = if ($wuStatusServer)        { $wuStatusServer } else { '<not set>' }
    } | Format-List

    $wsusConfigured = ($useWUServer -eq 1) -and -not [string]::IsNullOrWhiteSpace($wuServer)
    if ($wsusConfigured) {
        "WSUS is configured: this client is managed by $wuServer"
    } else {
        "WSUS is NOT configured: this client uses Microsoft Update directly."
    }

    $summary.WsusConfigured   = $wsusConfigured
    $summary.WsusUseWUServer  = $useWUServer
    $summary.WsusServer       = $wuServer
    $summary.WsusStatusServer = $wuStatusServer
}

# 5b. WSUS client registration (SusClientId / PingID) --------------------------
Invoke-Safe 'WSUS client registration (SusClientId)' {
    $idKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    $props = Get-ItemProperty -Path $idKey -ErrorAction SilentlyContinue
    $susClientId = $props.SusClientId
    $pingId      = $props.PingID

    [pscustomobject]@{
        SusClientId = if ($susClientId) { $susClientId } else { '<missing>' }
        PingID      = if ($pingId)      { $pingId }      else { '<not present>' }
    } | Format-List

    $summary.SusClientId = $susClientId
    $summary.PingID      = $pingId
    if ([string]::IsNullOrWhiteSpace($susClientId) -and $wsusConfigured) {
        $summary.Warnings.Add('SusClientId is missing or empty - this WSUS-configured client may not be registered.') | Out-Null
    }
}

# 5c. Last successful update detection -----------------------------------------
Invoke-Safe 'Last successful update detection' {
    $detectKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect'
    $lastSuccess = (Get-ItemProperty -Path $detectKey -Name LastSuccessTime -ErrorAction SilentlyContinue).LastSuccessTime
    if ($lastSuccess) {
        "LastSuccessTime (detection): $lastSuccess"
        $summary.LastDetectSuccessTime = $lastSuccess
    } else {
        "  <no LastSuccessTime recorded under $detectKey>"
        $summary.LastDetectSuccessTime = $null
        $summary.Warnings.Add('No Windows Update detection LastSuccessTime found - the client may never have completed a scan.') | Out-Null
    }
}

# 5d. WSUS web service health (supplements the Test-NetConnection checks) ------
Invoke-Safe 'WSUS web service health (ClientWebService)' {
    # Re-read WSUS values locally to avoid a hidden dependency on section 5a's
    # $summary fields (defensive — ensures this section is self-contained).
    $wsusServerLocal    = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    -Name WUServer    -ErrorAction SilentlyContinue).WUServer
    $useWUServerLocal   = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
    $wsusConfiguredLocal = ($useWUServerLocal -eq 1) -and -not [string]::IsNullOrWhiteSpace($wsusServerLocal)

    if (-not $wsusConfiguredLocal -or [string]::IsNullOrWhiteSpace($wsusServerLocal)) {
        "  <WSUS not configured - skipping web service check>"
        return
    }
    $wsusUri = "$($wsusServerLocal.TrimEnd('/'))/ClientWebService/client.asmx"
    "Testing HTTP reachability of: $wsusUri"

    $result = [ordered]@{
        Uri            = $wsusUri
        HttpStatusCode = $null
        Responded      = $false
        Error          = $null
    }
    try {
        $resp = Invoke-WebRequest -Uri $wsusUri -UseBasicParsing -Method Get `
                    -TimeoutSec $PerCommandTimeoutSec -ErrorAction Stop
        $result.HttpStatusCode = [int]$resp.StatusCode
        $result.Responded      = $true
    } catch [System.Net.WebException] {
        $webResp = $_.Exception.Response
        if ($webResp) {
            # Server answered, just with a non-success code (e.g. 403/500).
            $result.HttpStatusCode = [int]$webResp.StatusCode
            $result.Responded      = $true
        }
        $result.Error = $_.Exception.Message
    } catch {
        # Covers SSL/TLS handshake failures, DNS errors, timeouts, etc.
        $result.Error = $_.Exception.Message
    }
    [pscustomobject]$result | Format-List

    # TCP-level check against the WSUS host/port, mirroring the endpoint checks
    # in the connectivity section (supplement, not a replacement).
    try {
        $u = [uri]$wsusUri
        $tnc = Test-NetConnection -ComputerName $u.Host -Port $u.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        "Test-NetConnection $($u.Host):$($u.Port) -> $tnc"
    } catch {
        "Test-NetConnection failed: $($_.Exception.Message)"
    }

    if (-not $result.Responded) {
        $summary.Warnings.Add("WSUS ClientWebService did not respond at $wsusUri : $($result.Error)") | Out-Null
    }
    $summary.WsusWebService = [pscustomobject]$result
}

# 6. Windows Update client health via COM (read-only, no scan triggered) -----
Invoke-Safe 'Windows Update client (recent history via COM, read-only)' {
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $total    = 0
        try { $total = $searcher.GetTotalHistoryCount() } catch { $total = 0 }
        "Total history entries known to Windows Update client: $total"
        if ($total -gt 0) {
            $take = [Math]::Min($RecentUpdateCount, $total)
            $hist = $searcher.QueryHistory(0, $take)
            $rows = for ($i = 0; $i -lt $hist.Count; $i++) {
                $h = $hist.Item($i)
                [pscustomobject]@{
                    Date        = $h.Date
                    Operation   = switch ($h.Operation) { 1 {'Install'} 2 {'Uninstall'} default {"Op$($h.Operation)"} }
                    ResultCode  = switch ($h.ResultCode) {
                                    0 {'NotStarted'} 1 {'InProgress'} 2 {'Succeeded'}
                                    3 {'SucceededWithErrors'} 4 {'Failed'} 5 {'Aborted'}
                                    default {"Code$($h.ResultCode)"}
                                  }
                    HResult     = ('0x{0:X8}' -f ($h.HResult -band 0xFFFFFFFF))
                    Title       = $h.Title
                }
            }
            $failed = $rows | Where-Object { $_.ResultCode -in 'Failed','SucceededWithErrors','Aborted' }
            $summary.RecentUpdateFailures = @($failed | Select-Object -First 10)
            $summary.RecentFailureCount   = @($failed).Count
            $lastOk = $rows | Where-Object { $_.Operation -eq 'Install' -and $_.ResultCode -eq 'Succeeded' } |
                      Sort-Object Date -Descending | Select-Object -First 1
            if ($lastOk) {
                $summary.LastInstallSuccessTime  = $lastOk.Date.ToUniversalTime().ToString('s') + 'Z'
                $summary.LastInstallSuccessTitle = $lastOk.Title
                # A recent successful install proves detection works even when
                # the legacy Results\Detect registry key is empty (normal on
                # USO-driven Server 2016+). Drop that warning as a false positive.
                if (((Get-Date) - $lastOk.Date).TotalDays -lt 35) {
                    $stale = @($summary.Warnings | Where-Object { $_ -like 'No Windows Update detection LastSuccessTime*' })
                    foreach ($w in $stale) { [void]$summary.Warnings.Remove($w) }
                }
            }
            $rows | Format-Table -AutoSize -Wrap
        }
    } catch {
        "Update COM API unavailable: $($_.Exception.Message)"
    }
}

Invoke-Safe 'Installed hotfixes (last set)' {
    Get-HotFix -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending |
        Select-Object -First $RecentUpdateCount HotFixID, Description, InstalledOn, InstalledBy |
        Format-Table -AutoSize
}

# 7. Reboot pending check (registry / WMI only, no reboot) -------------------
Invoke-Safe 'Pending reboot flags' {
    # Gather every signal Windows exposes; capture the *evidence* for each hit
    # so we can tell the caller *why* the machine believes a reboot is due.
    $details = [ordered]@{}

    # 1. Component Based Servicing (CBS) - main servicing engine
    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path $cbsKey) {
        # The subkeys under it are the KBs / component packages waiting
        $pkgs = @(Get-ChildItem $cbsKey -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
        $details['CBS RebootPending']       = if ($pkgs) { "packages waiting: $($pkgs -join ', ')" } else { 'key present (no sub-keys enumerated)' }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') {
        $pending = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
        if ($pending) { $details['CBS PackagesPending'] = "$($pending.Count) package(s): $(($pending | Select-Object -First 5) -join ', ')$(if($pending.Count -gt 5){' ...'})" }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress') {
        $details['CBS RebootInProgress'] = 'key present (an install is mid-flight)'
    }

    # 2. Windows Update Auto Update - classic "reboot required" flag
    $wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path $wuKey) {
        $svc = @(Get-ChildItem $wuKey -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
        $details['Windows Update RebootRequired'] = if ($svc) { "waiting service(s): $($svc -join ', ')" } else { 'key present' }
    }
    # PostRebootReporting - Windows Update finished install but hasn't booted yet
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting') {
        $details['WU PostRebootReporting'] = 'update installed, awaiting first boot to report'
    }

    # 3. Pending file rename operations - anything trying to replace a locked file at next boot
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) {
        # entries alternate: source, destination (may be empty = delete)
        $entries = @($pfro.PendingFileRenameOperations | Where-Object { $_ })
        $preview = $entries | Select-Object -First 4
        $details['PendingFileRenameOperations'] = "$($entries.Count) entr(y|ies), e.g. $(($preview -join '; '))$(if($entries.Count -gt 4){' ...'})"
    }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations2 -ErrorAction SilentlyContinue) {
        $details['PendingFileRenameOperations2'] = 'secondary rename queue present'
    }

    # 4. Domain / computer rename pending
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $target = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $target -and ($active -ne $target)) {
        $details['Pending computer rename'] = "active='$active' -> target='$target'"
    }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name JoinDomain -ErrorAction SilentlyContinue) {
        $details['Pending domain join'] = 'Netlogon\JoinDomain value present'
    }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name AvoidSpnSet -ErrorAction SilentlyContinue) {
        $details['Pending domain join'] = ($details['Pending domain join'] + '; Netlogon\AvoidSpnSet present').TrimStart('; ')
    }

    # 5. Windows Update client via COM (authoritative "is a reboot required?" answer)
    try {
        $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sysInfo.RebootRequired) {
            $details['Microsoft.Update.SystemInfo'] = 'RebootRequired = True (COM API)'
        }
    } catch {
        # COM not available, ignore
    }

    # 6. Configuration Manager / SCCM client, if installed
    try {
        $ccm = Invoke-CimMethod -Namespace 'ROOT\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' `
                    -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
        if ($ccm -and ($ccm.RebootPending -or $ccm.IsHardRebootPending)) {
            $details['SCCM/CCM client'] = "RebootPending=$($ccm.RebootPending), IsHardRebootPending=$($ccm.IsHardRebootPending)"
        }
    } catch {
        # Namespace absent = SCCM client not installed. Silent.
    }

    # 7. servermanagercmd / DISM staged for reboot
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts') {
        $details['Server Manager']  = 'CurrentRebootAttempts key present'
    }

    # Explicit per-indicator booleans so it is immediately obvious *which*
    # signal is driving RebootPending, not just that one exists.
    $indicators = [ordered]@{
        ComponentBasedServicing     = [bool](Test-Path $cbsKey)
        WindowsUpdateRebootRequired = [bool](Test-Path $wuKey)
        PendingFileRenameOperations = [bool]($pfro -and $pfro.PendingFileRenameOperations)
        PendingComputerRename       = [bool]($active -and $target -and ($active -ne $target))
    }
    "---- Individual reboot indicators ----"
    $indicators.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Indicator = $_.Key; Pending = $_.Value }
    } | Format-Table -AutoSize

    # Emit a readable table + populate summary
    if ($details.Count -gt 0) {
        $details.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Signal = $_.Key; Evidence = $_.Value }
        } | Format-Table -AutoSize -Wrap
    } else {
        "  <no pending-reboot signals detected>"
    }

    $summary.RebootPending           = [bool]($details.Count -gt 0)
    $summary.RebootPendingReasons    = @($details.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Signal = $_.Key; Evidence = $_.Value }
    })
    $summary.RebootPendingIndicators = [pscustomobject]$indicators
}

# 8. Disk space (system drive + all fixed) -----------------------------------
Invoke-Safe 'Disk space (fixed drives)' {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Select-Object DeviceID,
            @{n='SizeGB';   e={[math]::Round($_.Size/1GB,1)}},
            @{n='FreeGB';   e={[math]::Round($_.FreeSpace/1GB,1)}},
            @{n='FreePct';  e={[math]::Round(($_.FreeSpace / [math]::Max($_.Size,1)) * 100,1)}} |
        Format-Table -AutoSize
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($c) {
        $summary.SystemDriveFreeGB = [math]::Round($c.FreeSpace/1GB,1)
        if ($summary.SystemDriveFreeGB -lt 5) {
            $summary.Warnings.Add("C: has less than 5 GB free ($($summary.SystemDriveFreeGB) GB). Windows Update needs headroom.") | Out-Null
        }
    }
}

# 9. SoftwareDistribution & CBS log sizes (do NOT clear them) ----------------
Invoke-Safe 'SoftwareDistribution + CBS state' {
    $sd = 'C:\Windows\SoftwareDistribution'
    if (Test-Path $sd) {
        $size = (Get-ChildItem $sd -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        "SoftwareDistribution size: $([math]::Round($size/1MB,1)) MB"
        Get-ChildItem $sd -Directory -ErrorAction SilentlyContinue |
            Select-Object Name, LastWriteTime | Format-Table -AutoSize
    }
    $wuLog  = 'C:\Windows\WindowsUpdate.log'
    $cbsLog = 'C:\Windows\Logs\CBS\CBS.log'
    Get-TailFile -Path $wuLog  -Lines 80
    Get-TailFile -Path $cbsLog -Lines 120
}

# 10. Network path to update endpoints ---------------------------------------
Invoke-Safe 'Connectivity to update endpoints (TCP 443, DNS only)' {
    $endpoints = @(
        'download.windowsupdate.com',
        'update.microsoft.com',
        'sls.update.microsoft.com',
        'fe3.delivery.mp.microsoft.com',
        'management.azure.com',
        'login.microsoftonline.com',
        'guestnotificationservice.azure.com'
    )

    # Read-only TCP connect probe with explicit timeout (honors PerCommandTimeoutSec).
    # Replaces Test-NetConnection which has no built-in timeout and can stall
    # for the full TCP stack timeout (~21 s each) on blackholed endpoints.
    function Test-TcpPort {
        param([string]$ComputerName, [int]$Port, [int]$TimeoutMs)
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async  = $client.BeginConnect($ComputerName, $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $client.EndConnect($async)
                $client.Close()
                return $true
            } else {
                $client.Close()
                return $false
            }
        } catch {
            return $false
        }
    }

    $timeoutMs = $PerCommandTimeoutSec * 1000
    $connResults = foreach ($e in $endpoints) {
        try {
            $t = Test-TcpPort -ComputerName $e -Port 443 -TimeoutMs $timeoutMs
            [pscustomobject]@{ Endpoint = $e; TCP443 = $t }
        } catch {
            [pscustomobject]@{ Endpoint = $e; TCP443 = $false }
        }
    }
    $connResults | Format-Table -AutoSize
    $badEndpoints = @($connResults | Where-Object { $_.TCP443 -ne $true } | ForEach-Object { $_.Endpoint })
    $summary.EndpointsChecked     = $endpoints.Count
    $summary.EndpointsUnreachable = $badEndpoints
    if ($badEndpoints.Count -gt 0) {
        $summary.Warnings.Add('Unreachable update endpoints on TCP 443: ' + ($badEndpoints -join ', ')) | Out-Null
    }

    "---- Proxy config (WinHTTP) ----"
    try { netsh winhttp show proxy 2>&1 } catch { $_.Exception.Message }
    "---- Proxy config (WinINET, per-user SYSTEM) ----"
    try {
        Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
            -ErrorAction SilentlyContinue |
            Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Format-List
    } catch { $_.Exception.Message }
}

# 11. TLS + .NET (0x80072F8F et al. often boil down to TLS 1.2) --------------
Invoke-Safe 'TLS configuration' {
    $tlsKeys = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client',
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server',
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
    )
    foreach ($k in $tlsKeys) {
        "---- $k ----"
        if (Test-Path $k) {
            Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Select-Object * -ExcludeProperty PS* | Format-List
        } else { "  <not present>" }
    }
    "Current process security protocol: $([Net.ServicePointManager]::SecurityProtocol)"
}

# 12. Event logs relevant to updates -----------------------------------------
Invoke-Safe 'System event log - recent Windows Update / servicing errors' {
    $providers = 'Microsoft-Windows-WindowsUpdateClient','Microsoft-Windows-Servicing','Microsoft-Windows-WUSA'
    foreach ($p in $providers) {
        "---- Provider: $p ----"
        try {
            Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName=$p } `
                -MaxEvents $EventCount -ErrorAction Stop |
                Where-Object { $_.Level -in 1,2,3 -or $_.Id -in 19,20,43,44 } |
                Select-Object TimeCreated, Id, LevelDisplayName, Message |
                Format-List
        } catch {
            "  (no events / provider not found: $($_.Exception.Message))"
        }
    }
}

Invoke-Safe 'Setup log - recent CBS/servicing failures' {
    try {
        Get-WinEvent -LogName Setup -MaxEvents $EventCount -ErrorAction Stop |
            Where-Object { $_.Level -in 1,2,3 } |
            Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Format-List
    } catch { "  (no Setup events readable)" }
}

# 13. Guest patching mode / auto-assessment flags ----------------------------
Invoke-Safe 'Guest patch settings (from IMDS)' {
    try {
        $c = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-12-13' `
            -Headers @{ Metadata = 'true' } -TimeoutSec 5 -Proxy $null
        [pscustomobject]@{
            OsProfile               = $c.osProfile
            PatchMode               = $c.osProfile.windowsConfiguration.patchSettings.patchMode
            AssessmentMode          = $c.osProfile.windowsConfiguration.patchSettings.assessmentMode
            EnableHotpatching       = $c.osProfile.windowsConfiguration.patchSettings.enableHotpatching
        } | Format-List
    } catch {
        "IMDS unreachable for patch settings: $($_.Exception.Message)"
    }
}

# --- Summary enrichment (cheap, independent, best-effort) ---------------------
try {
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $ubr = if ($null -ne $cv.UBR) { ".$($cv.UBR)" } else { '' }
    $summary.OsName  = $cv.ProductName
    $summary.OsBuild = "$($cv.CurrentBuildNumber)$ubr"
} catch { }
try {
    $osci = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $summary.LastBootUtc = $osci.LastBootUpTime.ToUniversalTime().ToString('s') + 'Z'
    $summary.UptimeDays  = [math]::Round(((Get-Date) - $osci.LastBootUpTime).TotalDays, 1)
    if ($summary.UptimeDays -gt 60) {
        $summary.Warnings.Add("Uptime is $($summary.UptimeDays) days - long-running servicing stacks are a common source of install failures. Consider a reboot window.") | Out-Null
    }
} catch { }
try {
    $wu = Get-Service wuauserv -ErrorAction Stop
    $summary.WuauservStatus    = "$($wu.Status)"
    $summary.WuauservStartType = "$($wu.StartType)"
    if ("$($wu.StartType)" -eq 'Disabled') {
        $summary.Warnings.Add('wuauserv (Windows Update service) start type is DISABLED - scans and installs cannot run. Common root cause.') | Out-Null
    }
} catch { }

# --- Summary block -----------------------------------------------------------
Write-Section 'Summary'
$summary.FinishedUtc = (Get-Date).ToUniversalTime().ToString('o')
$summaryJsonText = $summary | ConvertTo-Json -Depth 6
# Write BOM-less UTF-8 to avoid tripping strict JSON parsers.
[System.IO.File]::WriteAllText($jsonPath, $summaryJsonText, (New-Object System.Text.UTF8Encoding($false)))
# Mirror the summary into the log file too - previously the 'Summary' section
# header was written but no content ever followed it in the log.
Add-Content -LiteralPath $logPath -Value $summaryJsonText -Encoding UTF8

$logSize = (Get-Item $logPath).Length

# --- Compact stdout summary ----------------------------------------------------
# This is the only stdout the script produces (Run Command caps stdout at
# ~4 KB). Retrieval of the full log is handled by azdiag.sh.

$verdict = 'LOOKS HEALTHY'
if ($summary.Warnings.Count -gt 0) { $verdict = "REVIEW WARNINGS ($($summary.Warnings.Count))" }
$needsAttention = $false
if ($summary.Errors.Count -gt 0)                                                          { $needsAttention = $true }
if ($summary.Contains('RecentFailureCount') -and $summary.RecentFailureCount -gt 0)       { $needsAttention = $true }
if ($summary.Contains('EndpointsUnreachable') -and @($summary.EndpointsUnreachable).Count -gt 0) { $needsAttention = $true }
if ($summary.Contains('WuauservStartType') -and $summary.WuauservStartType -eq 'Disabled') { $needsAttention = $true }
if ($summary.Contains('PatchExtensionStatus') -and "$($summary.PatchExtensionStatus.Status)" -match '^(?i)error|fail') { $needsAttention = $true }
if ($needsAttention) { $verdict = 'NEEDS ATTENTION' }

$sep  = '=' * 78
$thin = '-' * 78
$L = New-Object System.Collections.Generic.List[string]
$L.Add($sep)
$L.Add(" Azure Update Manager diagnostics  |  $env:COMPUTERNAME  (Windows)  v$ScriptVersion")
$L.Add($sep)
$L.Add(" Verdict          : $verdict")
if ($summary.Contains('OsName')) {
    $L.Add(" OS               : $($summary.OsName)  (build $($summary.OsBuild))")
}
if ($summary.Contains('UptimeDays')) {
    $L.Add(" Uptime           : $($summary.UptimeDays) days  (booted $($summary.LastBootUtc))")
}
$L.Add(" Reboot pending   : $(if ($summary.RebootPending) { 'YES' } else { 'No' })")
if ($summary.RebootPending -and $summary.RebootPendingReasons) {
    $summary.RebootPendingReasons | ForEach-Object { $L.Add("                      - $($_.Signal): $($_.Evidence)") }
}
$L.Add(" Disk free (C:)   : $($summary.SystemDriveFreeGB) GB")
$L.Add(" WSUS             : $(if ($summary.WsusConfigured) { $summary.WsusServer } else { 'Not configured (Microsoft Update direct)' })")
if ($summary.Contains('WuauservStatus')) {
    $L.Add(" wuauserv         : $($summary.WuauservStatus) / $($summary.WuauservStartType)")
}
if ($summary.Contains('PatchExtensionStatus')) {
    $L.Add(" Patch extension  : $($summary.PatchExtensionStatus.Status)  (as of $($summary.PatchExtensionStatus.TimeUtc))")
} else {
    $L.Add(" Patch extension  : <no .status file found>")
}
if ($summary.Contains('LastInstallSuccessTime')) {
    $kb = ''
    if ($summary.LastInstallSuccessTitle -match 'KB\d+') { $kb = "  ($($Matches[0]))" }
    $L.Add(" Last install OK  : $($summary.LastInstallSuccessTime)$kb")
}
if ($summary.Contains('RecentFailureCount')) {
    $L.Add(" Recent failures  : $($summary.RecentFailureCount) in last $RecentUpdateCount history entries")
}
if ($summary.Contains('EndpointsChecked')) {
    $bad = @($summary.EndpointsUnreachable)
    $L.Add(" Endpoints        : $($summary.EndpointsChecked - $bad.Count)/$($summary.EndpointsChecked) reachable$(if ($bad.Count) { '  (FAIL: ' + ($bad -join ', ') + ')' })")
}
$L.Add(" Warnings         : $($summary.Warnings.Count)")
$summary.Warnings | ForEach-Object { $L.Add("   - $_") }
$L.Add(" Errors           : $($summary.Errors.Count)")
$summary.Errors | ForEach-Object { $L.Add("   - $_") }
$L.Add($thin)
$L.Add(" Log file     : $logPath  ($([math]::Round($logSize/1KB,1)) KB)")
$L.Add(" Summary JSON : $jsonPath")
$L.Add($sep)
Write-Output ($L -join "`r`n")