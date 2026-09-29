#!/bin/bash
# HRMS attendance — macOS installer.
#   ./install.sh              set up / change settings (safe to re-run)
#   ./install.sh --uninstall  stop the daily job
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
LABEL="local.hrms-attendance"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="hrms-attendance"

TIME_RE='^([01]?[0-9]|2[0-3])[:.][0-5][0-9]$'
EMAIL_RE='^[^@ ]+@[^@ ]+$'
URL_RE='^(https?://)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/.*)?$'
DAYNUM_RE='^[1-7]$'
DAYNAME_RE='^(mon|tue|wed|thu|fri|sat|sun)'

# Value of KEY in an existing .env, so re-runs default to the current settings.
current() { if [ -f "$ENV_FILE" ]; then grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; fi; }

ask() {  # ask "Prompt" "default" validator
    local answer
    while true; do
        read -r -p "$1 [$2]: " answer
        answer="${answer:-$2}"
        if "$3" "$answer"; then echo "$answer"; return; fi
        echo "  Invalid value, try again." >&2
    done
}

valid_email() { [[ "$1" =~ $EMAIL_RE ]]; }
valid_url()   { [[ "$1" =~ $URL_RE ]]; }
valid_time()  { [[ "$1" =~ $TIME_RE ]]; }
valid_workdays() { [ -n "$1" ] && [ "$1" != "-" ] && valid_days "$1"; }
valid_days() {
    [ -z "$1" ] || [ "$1" = "-" ] && return 0
    local d
    for d in $(echo "$1" | tr ',' ' '); do
        d=$(echo "$d" | tr 'A-Z' 'a-z')
        [[ "$d" =~ $DAYNUM_RE || "$d" =~ $DAYNAME_RE ]] || return 1
    done
}

if [ "${1:-}" = "--uninstall" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Daily job removed."
    user="$(current HRMS_USER)"
    if [ -n "$user" ] && security find-generic-password -s "$SERVICE" -a "$user" >/dev/null 2>&1; then
        read -r -p "Also delete the saved HRMS password from Keychain? [y/N]: " yn
        [[ "$yn" =~ ^[Yy] ]] && security delete-generic-password -s "$SERVICE" -a "$user" >/dev/null && echo "Password deleted."
    fi
    exit 0
fi

# --- Python 3.9+ ---
PY="$(command -v python3 || true)"
if [ -z "$PY" ] || ! "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
    echo "Python 3.9+ is needed. Run:  xcode-select --install   (or install from python.org), then re-run this."
    exit 1
fi

echo "HRMS attendance setup — press Enter to keep the value in [brackets]."
echo
HRMS_URL=$(ask "HRMS address (e.g. https://hrms.yourcompany.com)" "$(current HRMS_URL)" valid_url)
EMAIL=$(ask "HRMS login email" "$(current HRMS_USER)" valid_email)
WD_CUR="$(current WORK_DAYS)"
WORK_DAYS=$(ask "Days you work" "${WD_CUR:-Mon,Tue,Wed,Thu,Fri}" valid_workdays)
echo "Office days are filed as 'On Duty', all other work days as 'Work From Home'."
OFFICE_DAYS=$(ask "Office days (e.g. Mon,Tue,Fri; '-' if fully remote)" "$(current OFFICE_DAYS)" valid_days)
[ "$OFFICE_DAYS" = "-" ] && OFFICE_DAYS=""
IN_CUR="$(current IN_TIME)"; OUT_CUR="$(current OUT_TIME)"
IN_TIME=$(ask "In time, 24h" "${IN_CUR:-10:30}" valid_time)
OUT_TIME=$(ask "Out time, 24h" "${OUT_CUR:-19:30}" valid_time)

# --- password in Keychain (never written to .env) ---
echo
if security find-generic-password -s "$SERVICE" -a "$EMAIL" >/dev/null 2>&1; then
    read -r -p "A saved HRMS password exists for $EMAIL. Replace it? [y/N]: " yn
else
    yn=y
    echo "Enter your HRMS password (stored in macOS Keychain, not in any file)."
fi
if [[ "$yn" =~ ^[Yy] ]]; then
    security add-generic-password -U -s "$SERVICE" -a "$EMAIL" -w
fi

# --- .env (keeps optional values from a previous install) ---
cat > "$ENV_FILE" <<EOF
# Written by install.sh — re-run it to change these, or edit by hand.
HRMS_URL=$HRMS_URL
HRMS_API_KEY=$(current HRMS_API_KEY)
HRMS_API_SECRET=$(current HRMS_API_SECRET)
HRMS_USER=$EMAIL
WORK_DAYS=$WORK_DAYS
OFFICE_DAYS=$OFFICE_DAYS
IN_TIME=$IN_TIME
OUT_TIME=$OUT_TIME
ATTENDANCE_EXPLANATION=$(current ATTENDANCE_EXPLANATION)
NOTIFY=true
EOF
chmod 600 "$ENV_FILE"

# --- check login works before scheduling ---
echo
echo "Testing login (dry run, nothing is created)..."
if ! "$PY" "$DIR/attendance.py" --dry-run; then
    echo
    echo "Test failed — fix the problem above (usually the password) and re-run ./install.sh"
    exit 1
fi

# --- launchd job: at login + every 15 min (a slot missed during sleep fires on wake).
# attendance.py --scheduled stops for the day once today's draft exists, so repeats are cheap.
mkdir -p "$(dirname "$PLIST")"
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$DIR/attendance.py</string>
        <string>--scheduled</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Minute</key><integer>0</integer></dict>
        <dict><key>Minute</key><integer>15</integer></dict>
        <dict><key>Minute</key><integer>30</integer></dict>
        <dict><key>Minute</key><integer>45</integer></dict>
    </array>
    <!-- let the popup (a separate osascript process) outlive the script -->
    <key>AbandonProcessGroup</key><true/>
    <key>StandardOutPath</key><string>$DIR/attendance.log</string>
    <key>StandardErrorPath</key><string>$DIR/attendance.log</string>
</dict>
</plist>
EOF
launchctl load "$PLIST"

echo
echo "Done. Today's draft is created as soon as you log in / wake the Mac and are online"
echo "(checked every 15 minutes until it succeeds)."
echo "Log: $DIR/attendance.log"
