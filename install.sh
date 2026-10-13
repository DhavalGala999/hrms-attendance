#!/bin/bash
# HRMS attendance — installer for macOS and Ubuntu (normal desktop).
#   ./install.sh              set up / change settings (safe to re-run)
#   ./install.sh --uninstall  stop the daily job
set -euo pipefail

windows_help() {
    echo "On Windows (including WSL and Git Bash), use the Windows installer from PowerShell:"
    echo "  1. Put this folder on the Windows side (e.g. C:\\Users\\<you>\\hrms-attendance), not inside WSL."
    echo "  2. Open PowerShell in that folder and run:"
    echo "       powershell -ExecutionPolicy Bypass -File install.ps1"
}

# macOS uses Keychain + launchd; Ubuntu uses the desktop keyring + a systemd user timer.
case "$(uname -s)" in
    Darwin) OS=mac ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo "This is WSL (Linux inside Windows). It has no desktop keyring or popups."
            echo
            windows_help
            exit 1
        fi
        OS=linux ;;
    *)
        echo "install.sh supports macOS and Ubuntu."
        echo
        windows_help
        exit 1 ;;
esac

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
SERVICE="hrms-attendance"
# macOS
LABEL="local.hrms-attendance"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Ubuntu
UNIT="hrms-attendance"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

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

# --- password store: macOS Keychain / Ubuntu desktop keyring (never written to .env) ---
password_saved() {  # password_saved EMAIL
    if [ "$OS" = mac ]; then
        security find-generic-password -s "$SERVICE" -a "$1" >/dev/null 2>&1
    else
        command -v secret-tool >/dev/null 2>&1 &&
            [ -n "$(secret-tool lookup service "$SERVICE" username "$1" 2>/dev/null)" ]
    fi
}
save_password() {  # prompts for the password itself, without showing it
    if [ "$OS" = mac ]; then
        security add-generic-password -U -s "$SERVICE" -a "$1" -w
    else
        secret-tool store --label="HRMS attendance ($1)" service "$SERVICE" username "$1"
    fi
}
delete_password() {
    if [ "$OS" = mac ]; then
        security delete-generic-password -s "$SERVICE" -a "$1" >/dev/null
    else
        secret-tool clear service "$SERVICE" username "$1"
    fi
}

# --- scheduler: launchd job / systemd user timer ---
remove_job() {
    if [ "$OS" = mac ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
    else
        systemctl --user disable --now "$UNIT.timer" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT.service"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

install_job_mac() {
    # At login + every 15 min (a slot missed during sleep fires on wake).
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
}

# Quote a path for a systemd ExecStart= line: \ and " are escaped, % and $ are doubled.
systemd_quote() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')"; }

install_job_linux() {
    # 30s after login + every 15 min (a slot missed during suspend fires on resume).
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=HRMS attendance: create today's draft Attendance Request

[Service]
Type=oneshot
ExecStart=$(systemd_quote "$PY") $(systemd_quote "$DIR/attendance.py") --scheduled --log $(systemd_quote "$DIR/attendance.log")
# let the popup (a separate process) stay on screen after the script exits
KillMode=process
TimeoutStartSec=10min
EOF
    cat > "$UNIT_DIR/$UNIT.timer" <<EOF
[Unit]
Description=HRMS attendance: at login and every 15 minutes

[Timer]
OnActiveSec=30s
OnCalendar=*:0/15

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now --quiet "$UNIT.timer"
}

if [ "${1:-}" = "--uninstall" ]; then
    remove_job
    echo "Daily job removed."
    user="$(current HRMS_USER)"
    if [ -n "$user" ] && password_saved "$user"; then
        read -r -p "Also delete the saved HRMS password? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy] ]]; then delete_password "$user" && echo "Password deleted."; fi
    fi
    exit 0
fi

# --- prerequisites ---
if [ "$OS" = linux ]; then
    missing=""
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"
    command -v secret-tool >/dev/null 2>&1 || missing="$missing libsecret-tools"
    command -v zenity >/dev/null 2>&1 || missing="$missing zenity"
    if [ -n "$missing" ]; then
        echo "A few standard packages are needed first. Run this, then run ./install.sh again:"
        echo "  sudo apt install -y$missing"
        exit 1
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1 || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        echo "Run this from a terminal inside your normal desktop session (not over SSH)."
        echo "The keyring, the popups and the background timer all need the desktop."
        exit 1
    fi
fi

PY="$(command -v python3 || true)"
if [ -z "$PY" ] || ! "$PY" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
    if [ "$OS" = mac ]; then
        echo "Python 3.9+ is needed. Run:  xcode-select --install   (or install from python.org), then re-run this."
    else
        echo "Python 3.9+ is needed (Ubuntu 22.04 or newer has it). Then re-run this."
    fi
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

# --- password ---
echo
if password_saved "$EMAIL"; then
    read -r -p "A saved HRMS password exists for $EMAIL. Replace it? [y/N]: " yn
else
    yn=y
    if [ "$OS" = mac ]; then
        echo "Enter your HRMS password (stored in macOS Keychain, not in any file)."
    else
        echo "Enter your HRMS password (stored in your desktop keyring, not in any file)."
    fi
fi
if [[ "$yn" =~ ^[Yy] ]]; then
    save_password "$EMAIL"
fi

# --- .env (keeps optional values from a previous install) ---
# Read the old values first: "cat > file" empties the file before the lines below are filled in.
KEY_CUR="$(current HRMS_API_KEY)"; SECRET_CUR="$(current HRMS_API_SECRET)"
EXPLANATION_CUR="$(current ATTENDANCE_EXPLANATION)"
NOTIFY_CUR="$(current NOTIFY)"; REMIND_CUR="$(current REMIND_MINUTES)"
cat > "$ENV_FILE" <<EOF
# Written by install.sh — re-run it to change these, or edit by hand.
HRMS_URL=$HRMS_URL
HRMS_API_KEY=$KEY_CUR
HRMS_API_SECRET=$SECRET_CUR
HRMS_USER=$EMAIL
WORK_DAYS=$WORK_DAYS
OFFICE_DAYS=$OFFICE_DAYS
IN_TIME=$IN_TIME
OUT_TIME=$OUT_TIME
ATTENDANCE_EXPLANATION=$EXPLANATION_CUR
NOTIFY=${NOTIFY_CUR:-true}
REMIND_MINUTES=${REMIND_CUR:-15}
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

# --- scheduler. attendance.py --scheduled stops for the day once today's draft exists,
# so the repeats are cheap.
if [ "$OS" = mac ]; then
    install_job_mac
    computer="Mac"
else
    install_job_linux
    computer="computer"
fi

echo
echo "Done. Today's draft is created as soon as you log in / wake the $computer and are online"
echo "(checked every 15 minutes until it succeeds)."
echo "Log: $DIR/attendance.log"
