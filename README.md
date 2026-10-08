# HRMS Attendance Request automation

Creates your **draft Attendance Request** in [Frappe HRMS](https://frappe.io/hr) every work day, so you only need to review and submit it.

Each draft is filled with:

| Field | Value |
|---|---|
| Date | Today |
| Reason | **On Duty** on your office days, **Work From Home** on other work days |
| Start / End Time | Your in / out time, if your company's form has these fields |
| Shift | Your default shift from your Employee record |

No draft is created on weekends, company holidays, days you are on leave, or days that already have an Attendance Request or Attendance.

Your password is saved in the macOS Keychain or Windows Credential Manager. It is never written to a file.

## Requirements

- Python 3.9 or newer
  - **macOS:** the built-in `python3` works. If macOS asks, install the Command Line Tools.
  - **Windows:** install Python from [python.org](https://www.python.org/downloads/) and tick **"Add python.exe to PATH"**.
- Your HRMS address, email and password. If you sign in with Google, set an HRMS password first.

## Install

Put this folder somewhere permanent, such as your home folder, because the daily job runs from wherever the folder is. Then run the installer for your system.

**macOS** (Terminal):

```bash
cd ~/hrms-attendance
./install.sh
```

**Windows** (PowerShell):

```powershell
cd $HOME\hrms-attendance
powershell -ExecutionPolicy Bypass -File install.ps1
```

On Windows, use **PowerShell**, not WSL or Git Bash, and keep the folder on the Windows side (e.g. `C:\Users\<you>\hrms-attendance`), not inside WSL. `install.sh` is for macOS only. Python must be installed on Windows itself; Python inside WSL doesn't count.

The installer asks for:

1. **HRMS address**: the site you log in to, e.g. `https://hrms.yourcompany.com`
2. **HRMS login email**
3. **Days you work**: default `Mon,Tue,Wed,Thu,Fri`
4. **Office days**: e.g. `Mon,Tue,Fri`. These days are filed as On Duty. Enter `-` if you are fully remote.
5. **In time / out time**: 24-hour format, e.g. `10:30` and `19:30`
6. **Your HRMS password**: the characters don't show while you type

It then tests your login without creating anything, and sets up the automatic job.

## When it runs

- **As soon as you're up and online:** at login and on wake, and then every 15 minutes. It waits up to 5 minutes for Wi-Fi after the laptop wakes.
- **Once a day:** after today's draft is created, or today is a holiday, leave day or already filed, later runs exit without contacting HRMS.
- **Automatic retries:** if HRMS refuses, you get **one** popup. Your company may have its own rules, for example requiring the previous day's timesheet first. It keeps retrying every 15 minutes, so once you fix the problem, the draft is created within 15 minutes.
- **Popups:**
  - **Success:** says the draft was created, with an **Open in HRMS** button to review and submit it.
  - **Failure:** explains what went wrong.
- **Mac vs Windows:** both work the same way. On Windows you need to be logged in.

## Change your settings

Run the installer again. It shows your current values in `[brackets]`, so press Enter to keep a value. Re-run it after changing your HRMS password too.

You can also edit `.env` directly. Changes apply from the next run.

## Useful commands

| | macOS | Windows |
|---|---|---|
| Create today's draft now | `python3 attendance.py` | `python attendance.py` |
| Preview only (creates nothing) | `python3 attendance.py --dry-run` | `python attendance.py --dry-run` |
| File even on a holiday or weekend | `python3 attendance.py --force` | `python attendance.py --force` |
| See what happened | `cat attendance.log` | `type attendance.log` |
| Uninstall | `./install.sh --uninstall` | `powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall` |

The script can only file for **today**. It can't create requests for past or future dates.

## Troubleshooting

| Log says | Fix |
|---|---|
| `HTTP 401` / `Invalid login credentials` | Your password changed. Re-run the installer and replace the saved password. |
| `no saved password for ...` | Re-run the installer. |
| `config error: ...` | A value in `.env` is wrong. The message says which one. |
| `Attendance Request ... already exists` | Nothing to do: today already has a request. |
| Any other message from HRMS | It's a rule on your company's HRMS, such as a missing timesheet. Do what the message asks. The next check, within 15 minutes, creates the draft. |
| `set HRMS_URL …` | Re-run the installer and enter your HRMS address. |
| `No network … will retry on the next run` | Nothing to do: it tries again in 15 minutes. |
| Nothing ran | **Mac:** run `launchctl list \| grep hrms` and check the job is listed. **Windows:** check **HRMS Attendance** in Task Scheduler. Re-running the installer fixes both. |
| Need to re-run today after deleting the draft | Delete the `.state.json` file in this folder, or run `attendance.py` by hand. |

## Files

| File | Purpose |
|---|---|
| `attendance.py` | The script |
| `install.sh` / `install.ps1` | Installers for macOS and Windows |
| `.env` | Your settings, created by the installer. **Don't share this file.** |
| `.env.example` | Reference for all settings, for manual setup |
| `attendance.log` | What happened on each run |
