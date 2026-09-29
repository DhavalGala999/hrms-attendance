#!/usr/bin/env python3
"""
Creates a daily draft Attendance Request in Frappe HRMS.

Uses the Frappe REST API (no browser). Auth is either an API key/secret, or your
username + password read from the OS credential store (macOS Keychain /
Windows Credential Manager).
Safe to run multiple times a day: it skips weekends/holidays, days you're on
leave, and days that already have an Attendance Request or Attendance.

The installers run it with --scheduled at login/wake and every 15 minutes; once
today is handled (.state.json), those runs exit without contacting HRMS.

Usage:
    python3 attendance.py                 # create today's draft
    python3 attendance.py --dry-run       # show what would happen, change nothing
    python3 attendance.py --force         # ignore weekend/holiday check
"""
from __future__ import annotations  # keeps `str | None` hints working on Python 3.9 (macOS default)

import argparse
import datetime as dt
import http.cookiejar
import html
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8-sig").splitlines():  # -sig: tolerate a Windows BOM
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


load_env(HERE / ".env")

def site_url(value: str) -> str:
    """'hrms.example.com' or a pasted page URL -> 'https://hrms.example.com'."""
    value = value.strip()
    if not value:
        return ""
    parsed = urllib.parse.urlparse(value if "://" in value else f"https://{value}")
    return f"{parsed.scheme}://{parsed.netloc}"


BASE_URL = site_url(os.environ.get("HRMS_URL", ""))
API_KEY = os.environ.get("HRMS_API_KEY", "")
API_SECRET = os.environ.get("HRMS_API_SECRET", "")
# Fallback when you can't generate API keys: log in as this user, password read from the OS credential store
HRMS_USER = os.environ.get("HRMS_USER", "")
KEYCHAIN_SERVICE = os.environ.get("KEYCHAIN_SERVICE", "hrms-attendance")
EXPLANATION = os.environ.get("ATTENDANCE_EXPLANATION", "")
DAY_NAMES = {"mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6, "sun": 7}


def parse_days(name: str, default: str) -> set[int]:
    """'Mon,Tue' or '1,2' (ISO weekday numbers, 1=Mon) -> {1, 2}."""
    days = set()
    for part in os.environ.get(name, default).split(","):
        part = part.strip().lower()
        if not part:
            continue
        if part.isdigit() and 1 <= int(part) <= 7:
            days.add(int(part))
        elif part[:3] in DAY_NAMES:
            days.add(DAY_NAMES[part[:3]])
        else:
            sys.exit(f"config error: {name} has '{part}' — use day names like Mon,Tue or numbers 1-7")
    return days


def parse_time(name: str, default: str) -> str:
    """'10:30' / '9:30' / '10.30' -> '10:30:00' (24h)."""
    value = os.environ.get(name, default).strip()
    try:
        return dt.datetime.strptime(value.replace(".", ":"), "%H:%M").strftime("%H:%M:%S")
    except ValueError:
        sys.exit(f"config error: {name}='{value}' — use 24h HH:MM, e.g. 10:30 or 19:30")


WORK_DAYS = parse_days("WORK_DAYS", "Mon,Tue,Wed,Thu,Fri")
# Days you're in office are filed as "On Duty"; every other work day as "Work From Home".
OFFICE_DAYS = parse_days("OFFICE_DAYS", "")
IN_TIME = parse_time("IN_TIME", "10:30")
OUT_TIME = parse_time("OUT_TIME", "19:30")
NOTIFY = os.environ.get("NOTIFY", "true").lower() == "true"


class HRMSError(Exception):
    """str(e) is the human-readable message (shown in the popup); `detail` is the
    technical context (request, HTTP status) that only goes to the log."""

    def __init__(self, message: str, detail: str = ""):
        super().__init__(message)
        self.detail = detail


def plain_text(value: str) -> str:
    """Frappe messages/descriptions are HTML: '<b>24-09-2026</b><br>' -> '24-09-2026'."""
    value = " ".join(value.split())  # raw newlines in HTML are just spaces
    value = re.sub(r"<br\s*/?>|</p>|</div>", "\n", value, flags=re.I)
    value = html.unescape(re.sub(r"<[^>]+>", "", value))
    lines = (" ".join(line.split()) for line in value.splitlines())
    return "\n".join(line for line in lines if line)


# Session cookies (sid) are kept here after a password login.
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def api(method: str, path: str, params: dict | None = None, body: dict | None = None):
    url = BASE_URL + urllib.parse.quote(path, safe="/")  # doctype/doc names contain spaces
    if params:
        url += "?" + urllib.parse.urlencode(
            {k: json.dumps(v) if isinstance(v, (list, dict)) else v for k, v in params.items()}
        )
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if API_KEY and API_SECRET:
        req.add_header("Authorization", f"token {API_KEY}:{API_SECRET}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with OPENER.open(req, timeout=30) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise HRMSError(frappe_error(e.read()), f"{method} {path} -> HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise HRMSError(f"Could not connect to HRMS ({e.reason})", f"{method} {path}") from None


def frappe_error(raw: bytes) -> str:
    """Pull the human-readable message out of a Frappe error response."""
    try:
        payload = json.loads(raw)
    except ValueError:
        return raw[:300].decode(errors="replace")
    msgs = []
    for m in json.loads(payload.get("_server_messages", "[]") or "[]"):
        try:
            msgs.append(json.loads(m).get("message", m))
        except (ValueError, AttributeError):
            msgs.append(str(m))
    if msgs:
        return plain_text("\n".join(map(str, msgs)))
    exc = payload.get("exception") or payload.get("exc_type") or payload.get("message")
    return plain_text(str(exc))[:300]


def stored_password() -> str:
    """Password from the OS credential store: `keyring` if installed (Windows Credential
    Manager / macOS Keychain / Linux Secret Service), else the macOS `security` tool."""
    try:
        import keyring
        if pwd := keyring.get_password(KEYCHAIN_SERVICE, HRMS_USER):
            return pwd
    except ImportError:
        pass
    if sys.platform == "darwin":
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", HRMS_USER, "-w"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            return result.stdout.rstrip("\n")
        hint = f"security add-generic-password -s {KEYCHAIN_SERVICE} -a {HRMS_USER} -w"
    else:
        hint = f"pip install keyring  then  python -m keyring set {KEYCHAIN_SERVICE} {HRMS_USER}"
    raise HRMSError(f"no saved password for {HRMS_USER} — save it with: {hint}")


def login() -> None:
    """Password login; the session cookie is stored in OPENER for later calls."""
    api("POST", "/api/method/login", body={"usr": HRMS_USER, "pwd": stored_password()})


def get_list(doctype: str, filters: list, fields: list, parent: str | None = None,
             order_by: str | None = None) -> list:
    params = {"doctype": doctype, "filters": filters, "fields": fields, "limit_page_length": 50}
    if parent:
        params["parent"] = parent
    if order_by:
        params["order_by"] = order_by
    return api("GET", "/api/method/frappe.client.get_list", params=params).get("message", [])


def get_employee() -> dict:
    user = api("GET", "/api/method/frappe.auth.get_logged_user")["message"]
    rows = get_list(
        "Employee",
        [["user_id", "=", user], ["status", "=", "Active"]],
        ["name", "employee_name", "company", "holiday_list", "default_shift"],
    )
    if not rows:
        raise HRMSError(f"No active Employee linked to user {user}")
    return rows[0]


def is_holiday(emp: dict, day: dt.date) -> str | None:
    """Return a reason string if `day` is a non-working day, else None."""
    if day.isoweekday() not in WORK_DAYS:
        return f"{day:%A} is not in WORK_DAYS"

    holiday_list = emp.get("holiday_list")
    try:
        if not holiday_list:
            company = api("GET", f"/api/resource/Company/{emp['company']}")
            holiday_list = company["data"].get("default_holiday_list")
        if holiday_list:
            rows = get_list(
                "Holiday",
                [["parent", "=", holiday_list], ["holiday_date", "=", day.isoformat()]],
                ["description"],
                parent="Holiday List",
            )
            if rows:
                desc = plain_text(rows[0].get("description") or "")
                return f"holiday: {desc or holiday_list}"
    except HRMSError as e:
        # Employees sometimes can't read the Holiday List; fall back to WORK_DAYS only.
        log(f"warning: could not check holiday list ({e}); using WORK_DAYS only")
    return None


def already_covered(emp: str, day: dt.date) -> str | None:
    d = day.isoformat()
    checks = [
        ("Leave Application",
         [["employee", "=", emp], ["from_date", "<=", d], ["to_date", ">=", d],
          ["docstatus", "!=", 2], ["status", "not in", ["Rejected", "Cancelled"]]]),
        ("Attendance Request",
         [["employee", "=", emp], ["from_date", "<=", d], ["to_date", ">=", d], ["docstatus", "!=", 2]]),
        ("Attendance",
         [["employee", "=", emp], ["attendance_date", "=", d], ["docstatus", "!=", 2]]),
    ]
    for doctype, filters in checks:
        rows = get_list(doctype, filters, ["name"])
        if rows:
            return f"{doctype} {rows[0]['name']} already exists for {d}"
    return None


def reason_for(day: dt.date) -> str:
    return "On Duty" if day.isoweekday() in OFFICE_DAYS else "Work From Home"


def request_body(emp: dict, day: dt.date) -> dict:
    return {
        "employee": emp["name"],
        "company": emp["company"],
        "from_date": day.isoformat(),
        "to_date": day.isoformat(),
        "start_time": IN_TIME,
        "end_time": OUT_TIME,
        "shift": emp.get("default_shift"),
        "reason": reason_for(day),
        "explanation": EXPLANATION,
    }


def create_request(emp: dict, day: dt.date) -> dict:
    """Creates the request as a draft; submitting/approval happens in HRMS as usual."""
    return api("POST", "/api/resource/Attendance Request", body=request_body(emp, day))["data"]


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


class NetworkNotReady(HRMSError):
    pass


def wait_for_network(timeout: int = 600, interval: int = 15) -> None:
    """Right after the laptop wakes, Wi-Fi may not be back yet — wait for DNS instead of failing."""
    host = urllib.parse.urlparse(BASE_URL).hostname
    deadline = time.monotonic() + timeout
    logged = False
    while True:
        try:
            socket.getaddrinfo(host, 443)
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise NetworkNotReady(f"No network: could not reach {host} for {timeout // 60} minutes")
            if not logged:
                log("network not ready, waiting...")
                logged = True
            time.sleep(interval)


# Per-day state for scheduled runs: once today is handled, later runs exit without
# contacting HRMS, and each distinct failure pops up only once a day.
STATE_FILE = HERE / ".state.json"


def load_state(today: dt.date) -> dict:
    try:
        state = json.loads(STATE_FILE.read_text())
        if state.get("date") == today.isoformat():
            return state
    except (OSError, ValueError):
        pass
    return {"date": today.isoformat(), "done": None, "alerted": []}


def save_state(state: dict) -> None:
    try:
        STATE_FILE.write_text(json.dumps(state))
    except OSError as e:
        log(f"warning: could not save {STATE_FILE.name}: {e}")


def popup(title: str, body: str, url: str, error: bool = False) -> None:
    """Popup with an "Open in HRMS" button. Unlike notifications, it can't be silently
    hidden by notification settings / Focus; it stays until dismissed (max 8h).
    Runs as a separate process so this script (and the scheduler's next run) isn't blocked."""
    if sys.platform == "darwin":
        show = (f"set r to display alert {json.dumps(title)} message {json.dumps(body)}"
                f"{' as critical' if error else ''} buttons {{\"OK\", \"Open in HRMS\"}} "
                f"default button \"Open in HRMS\" giving up after 28800")
        open_url = f"if button returned of r is \"Open in HRMS\" then open location {json.dumps(url)}"
        subprocess.Popen(["osascript", "-e", show, "-e", open_url], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif sys.platform == "win32":
        icon = 0x10 if error else 0x40  # error / information
        code = (
            "import ctypes, webbrowser\n"
            # MB_YESNO | icon | MB_TOPMOST; 6 = "Yes"
            f"if ctypes.windll.user32.MessageBoxW(0, {body + chr(10) * 2 + 'Open in HRMS?'!r}, {title!r}, "
            f"{0x4 | icon | 0x40000}) == 6:\n"
            f"    webbrowser.open({url!r})\n"
        )
        subprocess.Popen([sys.executable, "-c", code],
                         creationflags=0x00000008 | 0x00000200)  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def notify_success(doc: dict) -> None:
    if NOTIFY:
        popup("Attendance Request created",
              f"Draft {doc['name']} ({doc['reason']}, {doc['from_date']}) was created.\n\n"
              "Review and submit it in HRMS.",
              f"{BASE_URL}/app/attendance-request/{doc['name']}")


def alert_failure(msg: str, retrying: bool = False) -> None:
    next_step = ("It will retry automatically every 15 minutes once you fix this."
                 if retrying else "Fix the issue and run attendance.py again, or fill it in HRMS.")
    popup("Attendance Request FAILED",
          f"{msg}\n\nToday's draft was NOT created. {next_step}",
          f"{BASE_URL}/app/attendance-request", error=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="skip the weekend/holiday check")
    ap.add_argument("--log", help="append output to this file (used by the Windows scheduled task)")
    ap.add_argument("--scheduled", action="store_true",
                    help="used by the scheduler: stop once today is done, retry quietly, pop up each failure once a day")
    args = ap.parse_args()
    if args.log:  # pythonw.exe has no console, so write straight to the file
        sys.stdout = sys.stderr = open(args.log, "a", encoding="utf-8")
    elif hasattr(sys.stdout, "reconfigure"):  # Windows console defaults to cp1252
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    today = dt.date.today()  # HRMS only accepts a request for the current day

    if not BASE_URL:
        log("set HRMS_URL (your HRMS address, e.g. https://hrms.yourcompany.com) — see .env.example")
        return 2
    if not ((API_KEY and API_SECRET) or HRMS_USER):
        log("set HRMS_API_KEY + HRMS_API_SECRET, or HRMS_USER (password in Keychain / Credential Manager) — see .env.example")
        return 2

    state = load_state(today)
    if args.scheduled and state["done"]:
        return 0  # today already handled; don't touch HRMS again

    def finish(reason: str) -> int:
        log(reason)
        if not args.dry_run:
            state["done"] = reason
            save_state(state)
        return 0

    if not args.force and today.isoweekday() not in WORK_DAYS:
        return finish(f"skip: {today:%A} is not in WORK_DAYS")

    try:
        # Scheduled runs repeat every 15 min, so don't wait long for Wi-Fi here.
        wait_for_network(timeout=300 if args.scheduled else 600)
        if not (API_KEY and API_SECRET):
            login()
        emp = get_employee()
        log(f"employee: {emp['name']} ({emp['employee_name']}), date: {today}")

        if not args.force and (why := is_holiday(emp, today)):
            return finish(f"skip: {why}")
        if why := already_covered(emp["name"], today):
            return finish(f"skip: {why}")

        if args.dry_run:
            b = request_body(emp, today)
            log(f"dry-run: would create Attendance Request: {b['reason']}, "
                f"{b['start_time']}-{b['end_time']}, shift={b['shift']} (draft)")
            return 0

        doc = create_request(emp, today)
        finish(f"created draft {doc['name']} ({doc['reason']})")
        notify_success(doc)
        return 0
    except NetworkNotReady as e:
        log(f"{e}" + ("; will retry on the next run" if args.scheduled else ""))
        if not args.scheduled:
            alert_failure(str(e))
        return 1
    except HRMSError as e:
        log(f"error: {e.detail + ': ' if e.detail else ''}{e}")
        message = str(e)[:300]
        if args.scheduled and message in state["alerted"]:
            return 1  # already shown today; keep retrying quietly
        if args.scheduled:
            state["alerted"].append(message)
            save_state(state)
        alert_failure(message, retrying=args.scheduled)
        return 1


if __name__ == "__main__":
    sys.exit(main())
