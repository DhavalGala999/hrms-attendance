# HRMS attendance - Windows installer.
#   powershell -ExecutionPolicy Bypass -File install.ps1              set up / change settings (safe to re-run)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   stop the daily job
param([switch]$Uninstall)
# Not "Stop": Windows PowerShell 5.1 turns harmless stderr output from python/pip into fatal errors.
# Native commands are checked via $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"

$Dir      = $PSScriptRoot
$EnvFile  = Join-Path $Dir ".env"
$Script   = Join-Path $Dir "attendance.py"
$Log      = Join-Path $Dir "attendance.log"
$TaskName = "HRMS Attendance"
$Service  = "hrms-attendance"

# Value of KEY in an existing .env, so re-runs default to the current settings.
function Current($key) {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match "^$key=" } | Select-Object -Last 1
        if ($line) { return $line.Substring($key.Length + 1) }
    }
    return ""
}

function Ask($prompt, $default, $validate) {
    while ($true) {
        $answer = Read-Host "$prompt [$default]"
        if (-not $answer) { $answer = $default }
        if (& $validate $answer) { return $answer }
        Write-Host "  Invalid value, try again." -ForegroundColor Yellow
    }
}

$EmailOk = { param($v) $v -match '^[^@\s]+@[^@\s]+$' }
$UrlOk   = { param($v) $v -match '^(https?://)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/.*)?$' }
$TimeOk  = { param($v) $v -match '^([01]?[0-9]|2[0-3])[:.][0-5][0-9]$' }
$DaysOk  = {
    param($v)
    if (-not $v -or $v -eq '-') { return $true }
    foreach ($d in $v.Split(',')) {
        $d = $d.Trim().ToLower()
        if ($d -and -not ($d -match '^[1-7]$' -or $d -match '^(mon|tue|wed|thu|fri|sat|sun)')) { return $false }
    }
    return $true
}
$WorkDaysOk = { param($v) $v -and $v -ne '-' -and (& $DaysOk $v) }

# Full path of a real Python 3.9+ (skips the Microsoft Store "python" stub).
function Find-Python {
    $found = @()
    try { if (Get-Command py -ErrorAction SilentlyContinue)     { $found += & py -3 -c "import sys; print(sys.executable)" 2>$null } } catch {}
    try { if (Get-Command python -ErrorAction SilentlyContinue) { $found += & python -c "import sys; print(sys.executable)" 2>$null } } catch {}
    foreach ($exe in $found) {
        if (-not $exe) { continue }
        $exe = "$exe".Trim()
        if (Test-Path $exe) {
            & $exe -c "import sys; sys.exit(sys.version_info < (3, 9))"
            if ($LASTEXITCODE -eq 0) { return $exe }
        }
    }
    return $null
}

$Py = Find-Python
if (-not $Py) {
    Write-Host "Python 3.9+ is needed. Install it from https://www.python.org/downloads/ (tick 'Add python.exe to PATH'), then re-run this." -ForegroundColor Red
    exit 1
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Daily job removed."
    $user = Current "HRMS_USER"
    if ($user -and (Read-Host "Also delete the saved HRMS password from Credential Manager? [y/N]") -match '^[Yy]') {
        & $Py -m keyring del $Service $user
        Write-Host "Password deleted."
    }
    exit 0
}

Write-Host "HRMS attendance setup - press Enter to keep the value in [brackets]."
Write-Host ""
$Url = Ask "HRMS address (e.g. https://hrms.yourcompany.com)" (Current "HRMS_URL") $UrlOk
$Email = Ask "HRMS login email" (Current "HRMS_USER") $EmailOk
$wd = Current "WORK_DAYS"; if (-not $wd) { $wd = "Mon,Tue,Wed,Thu,Fri" }
$WorkDays = Ask "Days you work" $wd $WorkDaysOk
Write-Host "Office days are filed as 'On Duty', all other work days as 'Work From Home'."
$OfficeDays = Ask "Office days (e.g. Mon,Tue,Fri; '-' if fully remote)" (Current "OFFICE_DAYS") $DaysOk
if ($OfficeDays -eq '-') { $OfficeDays = "" }
$in = Current "IN_TIME";   if (-not $in)  { $in  = "10:30" }
$out = Current "OUT_TIME"; if (-not $out) { $out = "19:30" }
$InTime  = Ask "In time, 24h" $in $TimeOk
$OutTime = Ask "Out time, 24h" $out $TimeOk

# --- password in Windows Credential Manager via `keyring` (never written to .env) ---
Write-Host ""
Write-Host "Installing the 'keyring' Python package (stores your password in Windows Credential Manager)..."
& $Py -m pip install --user --quiet --disable-pip-version-check keyring
if ($LASTEXITCODE -ne 0) { Write-Host "pip install keyring failed - see the error above." -ForegroundColor Red; exit 1 }

& $Py -c "import keyring, sys; sys.exit(0 if keyring.get_password('$Service', '$Email') else 1)"
$replace = 'y'
if ($LASTEXITCODE -eq 0) { $replace = Read-Host "A saved HRMS password exists for $Email. Replace it? [y/N]" }
if ($replace -match '^[Yy]') {
    Write-Host "Enter your HRMS password (typing is hidden):"
    & $Py -m keyring set $Service $Email
    if ($LASTEXITCODE -ne 0) { Write-Host "Saving the password failed." -ForegroundColor Red; exit 1 }
}

# --- .env (keeps optional values from a previous install); written without a BOM ---
$lines = @(
    "# Written by install.ps1 - re-run it to change these, or edit by hand.",
    "HRMS_URL=$Url",
    "HRMS_API_KEY=$(Current 'HRMS_API_KEY')",
    "HRMS_API_SECRET=$(Current 'HRMS_API_SECRET')",
    "HRMS_USER=$Email",
    "WORK_DAYS=$WorkDays",
    "OFFICE_DAYS=$OfficeDays",
    "IN_TIME=$InTime",
    "OUT_TIME=$OutTime",
    "ATTENDANCE_EXPLANATION=$(Current 'ATTENDANCE_EXPLANATION')",
    "NOTIFY=true"
)
[IO.File]::WriteAllLines($EnvFile, $lines)

# --- check login works before scheduling ---
Write-Host ""
Write-Host "Testing login (dry run, nothing is created)..."
& $Py $Script --dry-run
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Test failed - fix the problem above (usually the password) and re-run install.ps1" -ForegroundColor Red
    exit 1
}

# --- scheduled task: at logon + every 15 min. attendance.py --scheduled stops for the day
# once today's draft exists, so repeats are cheap. pythonw = no console window popping up.
$Pyw = Join-Path (Split-Path $Py) "pythonw.exe"
if (-not (Test-Path $Pyw)) { $Pyw = $Py }

$Action  = New-ScheduledTaskAction -Execute $Pyw -Argument "`"$Script`" --scheduled --log `"$Log`"" -WorkingDirectory $Dir
$Every15 = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today)
$Every15.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::Today) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 59)).Repetition
$AtLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# StartWhenAvailable: a run missed while asleep/off happens as soon as possible.
# Battery flags: laptops default to "don't run on battery". 10 min limit covers the network wait.
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger @($AtLogon, $Every15) -Settings $Settings -Force -ErrorAction Stop | Out-Null
} catch {
    # Some setups don't allow logon triggers without admin rights; every-15-min alone still works.
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Every15 -Settings $Settings -Force -ErrorAction Stop | Out-Null
        Write-Host "Note: couldn't add the at-logon trigger (needs admin); the 15-minute check is set up." -ForegroundColor Yellow
    } catch {
        Write-Host "Could not create the scheduled task: $_" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Done. Today's draft is created as soon as you log in / wake the PC and are online" -ForegroundColor Green
Write-Host "(checked every 15 minutes until it succeeds)."
Write-Host "Log: $Log"
