#!/usr/bin/env python3
"""SmartTimetable keeper: keeps one ЭИОС (portal.ulsu.ru) web session alive from a VPS.

The phone cannot run a timer in the background, a server can. The app sends its validated
portal cookies here; every 30-60 minutes (random, and never later than half of the portal's
own idle timeout) this service opens one protected page with them, which resets Moodle's idle
timer. No login, password or MAX code is ever sent here or stored.

Only Python's standard library. One owner, one session. API (HTTPS, header
"Authorization: Bearer <secret>"):
  GET    /status   -> state without cookies
  GET    /session  -> the cookies, only while the portal still accepts them (phone recovery)
  PUT    /session  {"cookies": {"name": "value", ...}} -> saves and checks at once
  DELETE /session  -> forgets the cookies (logout in the app)
"""
import hmac
import json
import os
import random
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORTAL = "https://portal.ulsu.ru"
PROBE = PORTAL + "/blocks/buttons/academic_progress.php"
STATE_DIR = os.environ.get("KEEPER_STATE_DIR", "/var/lib/smarttable-keeper")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SECRET_FILE = os.environ.get("KEEPER_SECRET_FILE", "/etc/smarttable-keeper/secret")
CERT = os.environ.get("KEEPER_CERT", "/root/cert/ip/fullchain.pem")
KEY = os.environ.get("KEEPER_KEY", "/root/cert/ip/privkey.pem")
PORT = int(os.environ.get("KEEPER_PORT", "49154"))
MIN_DELAY, MAX_DELAY = 30 * 60, 60 * 60
RETRY_DELAY = 5 * 60
COOKIE_NAME = re.compile(r"[A-Za-z0-9_\-.]{1,64}")  # used with fullmatch: "$" alone lets "\n" through
COOKIE_VALUE = re.compile(r"[A-Za-z0-9_\-.%=+/:~]{0,512}")
MAX_CONNECTIONS, MAX_PER_IP = 32, 4  # open connections at once: in total and from one address
USER_AGENT = "SmartTimetable keeper"

lock = threading.RLock()
wake = threading.Event()
failures = {}  # ip -> [timestamps] of rejected secrets
connections = {}  # ip -> open connections now


def valid_cookies(cookies):
    return (isinstance(cookies, dict) and 0 < len(cookies) <= 20
            and all(isinstance(k, str) and isinstance(v, str) and COOKIE_NAME.fullmatch(k) and COOKIE_VALUE.fullmatch(v)
                    for k, v in cookies.items()))


def note_failure(ip, now):
    """Remembers a rejected secret; forgets addresses that have been quiet for 10 minutes."""
    with lock:
        for other in [k for k, times in failures.items() if not times or now - times[-1] >= 600]:
            del failures[other]
        failures[ip] = [t for t in failures.get(ip, []) if now - t < 600] + [now]


def take_slot(ip):
    with lock:
        if sum(connections.values()) >= MAX_CONNECTIONS or connections.get(ip, 0) >= MAX_PER_IP:
            return False
        connections[ip] = connections.get(ip, 0) + 1
        return True


def free_slot(ip):
    with lock:
        left = connections.get(ip, 0) - 1
        if left > 0:
            connections[ip] = left
        else:
            connections.pop(ip, None)


def log(text):
    print(time.strftime("%Y-%m-%d %H:%M:%S ") + text, flush=True)


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


state = load_state()


def save_state():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def public_state():
    with lock:
        next_at = state.get("next_at")
        return {
            "has_session": bool(state.get("cookies")),
            "alive": state.get("alive", False),
            "last_ok": state.get("last_ok"),
            "last_check": state.get("last_check"),
            "error": state.get("error"),
            "timeout": state.get("timeout"),
            "next_in": max(0, int(next_at - time.time())) if next_at else None,
            "pings": state.get("pings", 0),
        }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(NoRedirect)


def request(url, cookies, body=None, content_type=None):
    """One request with the stored cookies. Returns (status, headers, text)."""
    headers = {"User-Agent": USER_AGENT, "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    try:
        with opener.open(req, timeout=25) as response:
            return response.status, response.headers, response.read(4_000_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as error:  # 3xx (not followed) and 4xx/5xx
        return error.code, error.headers, ""


def is_login(status, headers, html):
    """True only when the portal clearly asks to sign in. A 5xx/4xx error page has no logout
    link either, but it is a portal failure, not a logout: that is verdict() == None."""
    if status == 401:
        return True
    if 300 <= status < 400:
        # A relative Location ("/my/") points to the portal itself, so resolve it first.
        location = urllib.parse.urljoin(PROBE, headers.get("Location") or "").lower()
        return "login" in location or "auth" in location or "sso" in location or not location.startswith(PORTAL)
    if status != 200:
        return False
    # A signed-in Moodle page always links to logout; a guest or login page does not.
    return bool(re.search(r"<body[^>]*\bnotloggedin\b", html)) or "login/logout.php" not in html


def verdict(status, headers, html):
    """True: the session works. False: the portal asks to sign in. None: cannot tell now."""
    if is_login(status, headers, html):
        return False
    return True if status == 200 else None


def time_remaining(cookies, html):
    """Moodle's own idle timeout (seconds), as its session-timeout warning reads it."""
    match = re.search(r'"sesskey":"(\w+)"', html)
    if not match:
        return None
    url = f"{PORTAL}/lib/ajax/service.php?sesskey={match.group(1)}&info=core_session_time_remaining"
    payload = json.dumps([{"index": 0, "methodname": "core_session_time_remaining", "args": {}}]).encode()
    try:
        status, _, text = request(url, cookies, payload, "application/json")
        data = json.loads(text)[0]
        if status == 200 and not data.get("error"):
            value = data["data"].get("timeremaining")
            return int(value) if value else None
    except (ValueError, KeyError, IndexError, TypeError, OSError):
        pass
    return None


def check():
    """One keep-alive. Returns True when the portal still accepts the session."""
    with lock:
        cookies = dict(state.get("cookies") or {})
    if not cookies:
        return False
    now = int(time.time())
    try:
        status, headers, html = request(PROBE, cookies)
    except (OSError, ValueError) as error:  # ValueError: http.client refused to send a header
        with lock:
            state.update(last_check=now, error=f"нет связи с ЭИОС: {error.__class__.__name__}")
            save_state()
        log(f"ping failed: {error}")
        return state.get("alive", False)
    if is_login(status, headers, html):
        with lock:
            if state.get("cookies") == cookies:
                state.update(alive=False, last_check=now, error="ЭИОС завершила сессию: нужен новый вход в приложении")
                save_state()
        log(f"session lost (HTTP {status}), last ok {state.get('last_ok')}")
        return False
    if status != 200:
        with lock:
            state.update(last_check=now, error=f"ЭИОС ответила HTTP {status}")
            save_state()
        log(f"ping http {status}")
        return state.get("alive", False)
    timeout = time_remaining(cookies, html)
    with lock:
        if state.get("cookies") == cookies:
            state.update(alive=True, last_ok=now, last_check=now, error=None, pings=state.get("pings", 0) + 1)
            if timeout:
                state["timeout"] = timeout
            save_state()
    log("ping ok" + (f", portal idle timeout {timeout}s" if timeout else ""))
    return True


def next_delay(alive):
    if not alive:
        return None  # the portal ended the session: wait for new cookies from the app
    if state.get("error"):
        return RETRY_DELAY  # network or portal failure: the session is probably fine, check again soon
    delay = random.uniform(MIN_DELAY, MAX_DELAY)
    timeout = state.get("timeout")
    if timeout:
        delay = min(delay, max(300, timeout * 0.5))  # a short portal timeout wins over the random range
    return delay


cert_mtime = 0.0
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2


def reload_cert():
    """acme.sh renews the short-lived IP certificate; pick it up without a restart."""
    global cert_mtime
    try:
        mtime = os.path.getmtime(CERT)
        if mtime != cert_mtime:
            context.load_cert_chain(CERT, KEY)
            cert_mtime = mtime
            log("certificate loaded")
    except (OSError, ssl.SSLError) as error:
        log(f"certificate reload failed: {error}")


def loop():
    while True:
        reload_cert()
        with lock:
            has = bool(state.get("cookies")) and state.get("alive", True)
        delay = None
        if has:
            alive = check()
            delay = next_delay(alive)
        with lock:
            state["next_at"] = time.time() + delay if delay else None
            save_state()
        wake.clear()
        wake.wait(timeout=min(delay or 3600, 3600))


def read_secret():
    with open(SECRET_FILE) as f:
        return f.read().strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "keeper"
    sys_version = ""

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")

    def reply(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        ip = self.client_address[0]
        now = time.time()
        with lock:
            recent = [t for t in failures.get(ip, []) if now - t < 600]
        if len(recent) >= 10:
            self.reply(429, {"error": "слишком много неверных ключей, подождите 10 минут"})
            return False
        given = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        if given and hmac.compare_digest(given.encode(), read_secret().encode()):
            return True
        note_failure(ip, now)
        time.sleep(1)
        self.reply(401, {"error": "неверный ключ"})
        return False

    def do_GET(self):
        if self.path not in ("/status", "/session"):
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return
        if self.path == "/status":
            return self.reply(200, public_state())
        # The phone lost its cookies but the session may still be alive here: check it now and
        # hand the cookies back only if the portal accepts them.
        alive = check()
        with lock:
            cookies = dict(state.get("cookies") or {})
        if not alive or not cookies:
            return self.reply(404, {"error": "на сервере нет живой сессии"})
        log("session handed back to the app")
        self.reply(200, {"cookies": cookies, "alive": True})

    def do_DELETE(self):
        if self.path != "/session":
            return self.reply(404, {"error": "not found"})
        if self.authorized():
            with lock:
                state.clear()
                save_state()
            log("session forgotten")
            self.reply(200, public_state())

    def do_PUT(self):
        if self.path != "/session":
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= 16_384:
            return self.reply(413, {"error": "bad size"})
        try:
            cookies = json.loads(self.rfile.read(length))["cookies"]
        except (ValueError, KeyError, TypeError):
            cookies = None
        if not valid_cookies(cookies):
            return self.reply(400, {"error": "bad cookies"})
        code, payload = accept_cookies(cookies)
        self.reply(code, payload)


def accept_cookies(cookies):
    """PUT /session. New cookies replace the stored ones only when that cannot lose a working
    session: they are checked first, and while the portal cannot be reached a live session
    is kept (the app gets 503 and tries again later)."""
    with lock:
        if state.get("cookies") == cookies and state.get("alive"):
            return 200, public_state()
    try:
        status, headers, html = request(PROBE, cookies)
        accepted = verdict(status, headers, html)
    except (OSError, ValueError):
        accepted = None
    with lock:
        current_alive = bool(state.get("cookies")) and state.get("alive")
    if current_alive and accepted is not True:
        if accepted is False:
            log("new session rejected by the portal; keeping the live one")
            return 200, public_state()
        log("cannot verify the new session now; keeping the live one")
        return 503, {"error": "ЭИОС сейчас недоступна, сессия на сервере не заменена. Приложение повторит позже."}
    with lock:
        state.clear()
        state.update(cookies=cookies, saved_at=int(time.time()), alive=accepted is not False)
        save_state()
    log("new session received")
    check()
    wake.set()  # reschedule from now
    return 200, public_state()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def get_request(self):
        sock, addr = self.socket.accept()
        sock.settimeout(20)
        # The TLS handshake happens in the handler thread, not in the accept loop.
        return context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address):
        pass  # scanners and failed handshakes: nothing to log

    def process_request(self, request, client_address):
        """One thread per connection, but a bounded number of them: a flood of idle
        connections is dropped at once instead of piling up threads."""
        ip = client_address[0]
        if not take_slot(ip):
            return self.shutdown_request(request)
        try:
            super().process_request(request, client_address)
        except Exception:
            free_slot(ip)
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            free_slot(client_address[0])


def main():
    read_secret()  # fail fast without a secret
    reload_cert()
    threading.Thread(target=loop, daemon=True).start()
    server = Server(("0.0.0.0", PORT), Handler)
    log(f"keeper listening on {PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
