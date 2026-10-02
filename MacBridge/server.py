#!/usr/bin/env python3
"""Private, TLS-pinned companion service for the MacLink iPhone app."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.server
import ipaddress
import json
import mimetypes
import os
import pathlib
import platform
import re
import secrets
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid

from screen_stream import ScreenStream
from assistant_actions import parse_action
from codex_tasks import CodexTasks

CODEX_TASKS = CodexTasks()


APP_SUPPORT = pathlib.Path.home() / "Library" / "Application Support" / "MacLink"
PAIRING_INFO = APP_SUPPORT / "pairing-info.json"
PAIRED_CLIENTS = APP_SUPPORT / "paired-clients.json"
JARVIS_RUNTIME = pathlib.Path.home() / "Library" / "Application Support" / "JarvisMac" / "runtime"
HOME_ROOT = pathlib.Path.home().resolve()
PORT_DEFAULT = 8766
MAX_JSON_BYTES = 256 * 1024
MAX_FILE_BYTES = 40 * 1024 * 1024
MAX_CHAT_CHARS = 12000
ASSISTANT_SYSTEM = ("你是 Mac 的 Jarvis 助理。以繁體中文回答。MacLink 可執行明確單步指令："
                    "開啟Safari、開啟記事本、輸入：文字、向下捲動、按下Enter。"
                    "程式會建立操作確認卡，使用者確認後才執行。一般文字回答不會操作電腦，"
                    "不可宣稱已完成尚未執行的動作。目前不能自主看畫面完成多步任務。"
                    "刪除、付款、對外傳送及權限變更仍須逐項確認。")
ALLOWED_APPS = {
    "safari": "Safari",
    "textedit": "TextEdit",
    "calculator": "Calculator",
    "finder": "Finder",
    "terminal": "Terminal",
    "notes": "Notes",
    "calendar": "Calendar",
    "mail": "Mail",
    "messages": "Messages",
    "activity monitor": "Activity Monitor",
}
ALLOWED_KEYS = {
    "return": ("return", None),
    "tab": ("tab", None),
    "escape": ("ESC", None),
    "delete": ("DELETE", None),
    "space": ("space", None),
    "up": ("UP ARROW", None),
    "down": ("DOWN ARROW", None),
    "left": ("LEFT ARROW", None),
    "right": ("RIGHT ARROW", None),
    "command+a": ("a", "command down"),
    "command+c": ("c", "command down"),
    "command+v": ("v", "command down"),
    "command+z": ("z", "command down"),
}
STARTED_AT = time.time()
_INPUT_HELPER_LOCK = threading.Lock()
_TYPE_LOCK = threading.Lock()
_JARVIS_IMPORT_LOCK = threading.Lock()


def run_capture(command: list[str], timeout: int = 10) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "命令失敗").strip()
        raise RuntimeError(detail[:300])
    return result.stdout.strip()


def local_addresses() -> list[str]:
    addresses = []
    for interface in ("en0", "en1", "en2", "en3"):
        try:
            value = run_capture(["/usr/sbin/ipconfig", "getifaddr", interface], timeout=2)
            address = ipaddress.ip_address(value)
            if address.version == 4 and address.is_private and not address.is_loopback and not address.is_link_local:
                addresses.append(str(address))
        except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired):
            continue
    if not addresses:
        raise RuntimeError("找不到私人網路位址。請先讓 Mac 和 iPhone 連上同一個私人 Wi-Fi。")
    return addresses


def tailscale_address() -> str | None:
    """Return this Mac's active tailnet IPv4 address, without changing Tailscale settings."""
    executable = next((candidate for candidate in (
        shutil.which("tailscale"), "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"
    ) if candidate and pathlib.Path(candidate).exists()), None)
    if not executable:
        return None
    try:
        status = subprocess.run([executable, "status", "--json"], capture_output=True,
                                text=True, timeout=4, check=True)
        if json.loads(status.stdout).get("BackendState") != "Running":
            return None
        value = run_capture([executable, "ip", "-4"], timeout=4)
        address = ipaddress.ip_address(value)
        if address in ipaddress.ip_network("100.64.0.0/10"):
            return str(address)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return None


def certificate_paths() -> tuple[pathlib.Path, pathlib.Path]:
    APP_SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    return APP_SUPPORT / "server-cert.pem", APP_SUPPORT / "server-key.pem"


def ensure_certificate(addresses: list[str]) -> tuple[pathlib.Path, pathlib.Path, str]:
    cert_path, key_path = certificate_paths()
    address_path = APP_SUPPORT / "certificate-addresses.json"
    format_path = APP_SUPPORT / "certificate-format-version"
    previous_addresses: list[str] = []
    if address_path.exists():
        try:
            previous_addresses = json.loads(address_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            previous_addresses = []
    needs_new_certificate = (not cert_path.exists() or not key_path.exists()
                             or not set(addresses).issubset(set(previous_addresses))
                             or not format_path.exists() or format_path.read_text().strip() != "2")
    if needs_new_certificate:
        candidates = ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/bin/openssl"]
        openssl = next((candidate for candidate in candidates if pathlib.Path(candidate).exists()), None)
        if not openssl:
            raise RuntimeError("找不到 OpenSSL，無法為 MacLink 建立本機 TLS 憑證。")
        san = ",".join([*(f"IP:{address}" for address in addresses), "DNS:localhost"])
        command = [
            openssl, "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", str(key_path), "-out", str(cert_path), "-days", "825",
            "-subj", "/CN=MacLink Private Companion",
            "-config", "/dev/null",
            "-addext", f"subjectAltName={san}",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
            "-addext", "extendedKeyUsage=serverAuth",
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "憑證產生失敗").strip()
            raise RuntimeError(detail[:300])
        os.chmod(cert_path, 0o600)
        os.chmod(key_path, 0o600)
        address_path.write_text(json.dumps(addresses), encoding="utf-8")
        os.chmod(address_path, 0o600)
        format_path.write_text("2\n", encoding="utf-8")
        os.chmod(format_path, 0o600)
    os.chmod(cert_path, 0o600)
    os.chmod(key_path, 0o600)
    der = ssl.PEM_cert_to_DER_cert(cert_path.read_text(encoding="utf-8"))
    fingerprint = hashlib.sha256(der).hexdigest().upper()
    return cert_path, key_path, fingerprint


def app_state() -> tuple[str, str, float]:
    APP_SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    token_path = APP_SUPPORT / "access-token"
    if token_path.exists():
        token = token_path.read_text(encoding="utf-8").strip()
    else:
        token = secrets.token_urlsafe(36)
        token_path.write_text(token, encoding="utf-8")
    os.chmod(token_path, 0o600)
    os.chmod(APP_SUPPORT, 0o700)
    return token, f"{secrets.randbelow(1_000_000):06d}", time.time() + 600


def display_info() -> tuple[int, int, int]:
    value = run_capture([str(input_helper()), "display_info"], timeout=10)
    try:
        numbers = [int(item.strip()) for item in value.split(",")]
    except ValueError as exc:
        raise RuntimeError("無法讀取 Mac 主螢幕資訊。") from exc
    if len(numbers) != 3 or numbers[1] <= 0 or numbers[2] <= 0:
        raise RuntimeError("無法讀取 Mac 主螢幕資訊。")
    return numbers[0], numbers[1], numbers[2]


def display_size() -> tuple[int, int]:
    _, width, height = display_info()
    return width, height


def input_helper() -> pathlib.Path:
    source = pathlib.Path(__file__).with_name("input_helper.swift")
    bundled = source.with_name("input-helper")
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return bundled
    binary = APP_SUPPORT / "input-helper"
    with _INPUT_HELPER_LOCK:
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            APP_SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
            candidate = APP_SUPPORT / f"input-helper-{os.getpid()}"
            try:
                result = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-O",
                                         str(source), "-o", str(candidate)],
                                        capture_output=True, text=True, timeout=120, check=False)
                if result.returncode != 0:
                    raise RuntimeError(f"無法建立桌面控制工具：{result.stderr[:200]}")
                os.chmod(candidate, 0o700)
                os.replace(candidate, binary)
            finally:
                candidate.unlink(missing_ok=True)
    return binary


def input_accessibility() -> bool:
    return run_capture([str(input_helper()), "accessibility_status"], timeout=10).strip() == "granted"


def safe_path(raw: str) -> pathlib.Path:
    decoded = (raw or "").replace("\\", "/")
    if "\x00" in decoded:
        raise ValueError("路徑格式無效。")
    target = pathlib.Path(os.path.normpath(str(HOME_ROOT / decoded)))
    try:
        relative = target.relative_to(HOME_ROOT)
    except ValueError as exc:
        raise ValueError("目前只允許操作這個 Mac 使用者資料夾內的檔案。") from exc
    current = HOME_ROOT
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("為避免誤操作連結目標，請在 Mac 上處理符號連結。")
    return target


def relative_path(path: pathlib.Path) -> str:
    return path.relative_to(HOME_ROOT).as_posix()


class CompanionState:
    def __init__(self, token: str, pair_code: str, code_expires: float,
                 clients_path: pathlib.Path | None = None, token_path: pathlib.Path | None = None):
        self.admin_token = token
        self.clients_path = pathlib.Path(clients_path) if clients_path else PAIRED_CLIENTS
        self.token_path = pathlib.Path(token_path) if token_path else APP_SUPPORT / "access-token"
        self.clients: dict[str, dict] = {}
        self.lock = threading.RLock()
        self._load_clients()
        self.pair_code = pair_code
        self.code_expires = code_expires
        self.pair_used = False
        self.pair_failures = 0
        self.locked_until = 0.0
        self.pending_actions: dict[str, tuple[dict, float]] = {}

    @staticmethod
    def token_digest(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def _load_clients(self) -> None:
        if not self.clients_path.exists():
            # Preserve existing installations as one legacy shared credential;
            # every new pairing receives an independent token.
            self.clients[self.token_digest(self.admin_token)] = {
                "id": "legacy-shared", "created_at": time.time(), "legacy": True,
            }
            self._save_clients()
            return
        try:
            value = json.loads(self.clients_path.read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                raise ValueError("invalid client index")
            records = value.get("clients")
            if value.get("version") != 1 or not isinstance(records, list):
                raise ValueError("invalid client index")
            for item in records:
                if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                        or not isinstance(item.get("token_sha256"), str)
                        or not re.fullmatch(r"[0-9a-f]{64}", item["token_sha256"])):
                    raise ValueError("invalid client entry")
                self.clients[item["token_sha256"]] = {
                    "id": item["id"], "created_at": float(item.get("created_at", 0)),
                    "legacy": item.get("legacy") is True,
                }
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            raise RuntimeError("MacLink 配對裝置清單無法安全讀取；為避免意外恢復已撤銷權杖，服務未啟動。") from error

    def _save_clients(self) -> None:
        self.clients_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = self.clients_path.with_name(f".{self.clients_path.name}.{os.getpid()}.tmp")
        records = [{"id": value["id"], "token_sha256": digest,
                    "created_at": value["created_at"], "legacy": value["legacy"]}
                   for digest, value in sorted(self.clients.items())]
        try:
            with temporary.open("w", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                json.dump({"version": 1, "clients": records}, handle, separators=(",", ":"))
            os.replace(temporary, self.clients_path)
            os.chmod(self.clients_path, 0o600)
        finally:
            temporary.unlink(missing_ok=True)

    def authenticate(self, supplied: str) -> dict | None:
        if not isinstance(supplied, str) or not supplied:
            return None
        with self.lock:
            digest = self.token_digest(supplied)
            match = None
            for saved_digest, client in self.clients.items():
                if hmac.compare_digest(digest, saved_digest):
                    match = client
            admin = hmac.compare_digest(digest, self.token_digest(self.admin_token))
            if match is None and not admin:
                return None
            return {"id": match["id"] if match else "local-admin",
                    "legacy": match["legacy"] if match else False, "admin": admin}

    def issue_pairing(self, code: str, now: float | None = None) -> tuple[str, str]:
        with self.lock:
            now = time.time() if now is None else now
            if now < self.locked_until:
                raise PermissionError("配對嘗試過多，請稍後再試。")
            valid = (not self.pair_used and now < self.code_expires
                     and isinstance(code, str) and hmac.compare_digest(code, self.pair_code))
            if not valid:
                self.pair_failures += 1
                if self.pair_failures >= 5:
                    self.locked_until = now + 300
                raise ValueError("配對碼錯誤、過期，或已使用。")
            token = secrets.token_urlsafe(36)
            client_id = uuid.uuid4().hex
            self.clients[self.token_digest(token)] = {
                "id": client_id, "created_at": now, "legacy": False,
            }
            self._save_clients()
            # Immediately publish a fresh one-time code so another phone can pair.
            self.pair_code = f"{secrets.randbelow(1_000_000):06d}"
            self.code_expires = now + 600
            self.pair_used = False
            self.pair_failures = 0
            self.locked_until = 0.0
            return token, client_id

    def revoke(self, supplied: str) -> tuple[bool, bool]:
        with self.lock:
            principal = self.authenticate(supplied)
            if principal is None or principal["id"] == "local-admin":
                raise PermissionError("此裝置的配對權杖已失效。")
            for digest, client in list(self.clients.items()):
                if client["id"] == principal["id"]:
                    self.clients.pop(digest)
                    break
            legacy = principal["legacy"]
            self._save_clients()
            if legacy and principal["admin"]:
                # The old shared token also served local diagnostics. Rotate that
                # local-only token so revoking it cannot leave old phones authorized.
                self.admin_token = secrets.token_urlsafe(36)
                temporary = self.token_path.with_name(f".{self.token_path.name}.{os.getpid()}.tmp")
                try:
                    with temporary.open("w", encoding="utf-8") as handle:
                        os.chmod(temporary, 0o600)
                        handle.write(self.admin_token)
                    os.replace(temporary, self.token_path)
                    os.chmod(self.token_path, 0o600)
                finally:
                    temporary.unlink(missing_ok=True)
            self.pending_actions.clear()
            return legacy, principal["admin"]


def write_pairing_info(state: CompanionState, address: str, port: int, fingerprint: str) -> None:
    APP_SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = PAIRING_INFO.with_name(f".pairing-{os.getpid()}.tmp")
    payload = {"address": address, "port": port, "fingerprint": fingerprint,
               "code": state.pair_code, "expires_at": state.code_expires}
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            os.chmod(temporary, 0o600)
            json.dump(payload, handle)
        os.replace(temporary, PAIRING_INFO)
    finally:
        temporary.unlink(missing_ok=True)


def rotate_pairing_codes(state: CompanionState, address: str, port: int,
                         fingerprint: str, stop: threading.Event) -> None:
    while not stop.wait(5):
        with state.lock:
            if state.pair_used or time.time() < state.code_expires:
                continue
            state.pair_code = f"{secrets.randbelow(1_000_000):06d}"
            state.code_expires = time.time() + 600
            state.pair_failures = 0
            state.locked_until = 0.0
            write_pairing_info(state, address, port, fingerprint)


def make_handler(state: CompanionState, connection_mode: str):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "MacLink/1.0"

        def log_message(self, _format: str, *_args: object) -> None:
            # Requests can contain private filenames. Do not write request logs.
            return

        def send_json(self, status: int, value: object) -> None:
            body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def send_bytes(self, status: int, body: bytes, content_type: str, filename: str | None = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if filename:
                safe_name = urllib.parse.quote(filename, safe="")
                self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{safe_name}")
            self.end_headers()
            self.wfile.write(body)

        def send_stream_event(self, value: dict) -> None:
            self.wfile.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n")
            self.wfile.flush()

        def read_body(self, limit: int = MAX_JSON_BYTES) -> bytes:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as exc:
                raise ValueError("請求格式無效。") from exc
            if length < 0 or length > limit:
                raise ValueError("資料超過允許大小。")
            return self.rfile.read(length) if length else b""

        def read_json(self, limit: int = MAX_JSON_BYTES) -> dict:
            raw = self.read_body(limit)
            try:
                value = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError("JSON 格式無效。") from exc
            if not isinstance(value, dict):
                raise ValueError("請求資料格式無效。")
            return value

        def authorized(self) -> bool:
            header = self.headers.get("Authorization", "")
            supplied = header[7:].strip() if header.startswith("Bearer ") else ""
            return state.authenticate(supplied) is not None

        def bearer_token(self) -> str:
            header = self.headers.get("Authorization", "")
            return header[7:].strip() if header.startswith("Bearer ") else ""

        def require_auth(self) -> bool:
            if not self.authorized():
                self.send_json(401, {"error": "尚未配對或連線憑證已失效。"})
                return False
            return True

        def do_GET(self) -> None:
            try:
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                if parsed.path == "/api/health":
                    self.send_json(200, {"healthy": True, "service": "MacLink"})
                    return
                if not self.require_auth():
                    return
                if parsed.path == "/api/status":
                    width, height = display_size()
                    self.send_json(200, {
                        "name": socket.gethostname(),
                        "platform": "macOS",
                        "connection_mode": connection_mode,
                        "uptime_seconds": max(int(time.time() - STARTED_AT), 0),
                        "screen_width": width,
                        "screen_height": height,
                        "input_accessibility": input_accessibility(),
                        "assistant_runtime_available": all((JARVIS_RUNTIME / name).is_file()
                                                           for name in ("assistant_config.py", "local_provider.py")),
                    })
                elif parsed.path == "/api/codex/models":
                    self.send_json(200, CODEX_TASKS.models())
                elif parsed.path == "/api/codex/tasks":
                    self.send_json(200, CODEX_TASKS.listing(query.get("cursor", [None])[0]))
                elif parsed.path == "/api/codex/task":
                    self.send_json(200, CODEX_TASKS.read(query.get("id", [""])[0]))
                elif parsed.path == "/api/codex/calls":
                    self.send_json(200, CODEX_TASKS.call_history(query.get("thread", [""])[0]))
                elif parsed.path == "/api/codex/call":
                    self.send_json(200, CODEX_TASKS.call_transcript(
                        query.get("id", [""])[0], query.get("thread", [""])[0]))
                elif parsed.path == "/api/files":
                    target = safe_path(query.get("path", [""])[0])
                    if not target.is_dir():
                        self.send_json(400, {"error": "指定路徑不是資料夾。"})
                        return
                    entries = []
                    for item in target.iterdir():
                        if item.is_symlink():
                            continue
                        try:
                            stat = item.stat()
                        except OSError:
                            continue
                        entries.append({
                            "name": item.name,
                            "path": relative_path(item),
                            "is_directory": item.is_dir(),
                            "size": stat.st_size,
                            "modified": stat.st_mtime,
                        })
                    entries.sort(key=lambda item: (not item["is_directory"], item["name"].casefold()))
                    self.send_json(200, {"path": relative_path(target), "entries": entries})
                elif parsed.path == "/api/file":
                    target = safe_path(query.get("path", [""])[0])
                    if not target.is_file():
                        self.send_json(404, {"error": "找不到這個檔案。"})
                        return
                    if target.stat().st_size > MAX_FILE_BYTES:
                        self.send_json(413, {"error": "檔案超過 40 MB，請在 Mac 上直接操作。"})
                        return
                    content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
                    self.send_bytes(200, target.read_bytes(), content_type, target.name)
                elif parsed.path == "/api/screen":
                    self.send_bytes(200, capture_screen(), "image/jpeg")
                else:
                    self.send_json(404, {"error": "找不到這個 MacLink 功能。"})
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                self.send_json(400, {"error": str(exc)[:300]})

        def do_POST(self) -> None:
            try:
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == "/api/pair":
                    body = self.read_json()
                    with state.lock:
                        try:
                            token, client_id = state.issue_pairing(body.get("pair_code", ""))
                        except PermissionError as exc:
                            self.send_json(429, {"error": str(exc)})
                            return
                        except ValueError as exc:
                            self.send_json(401, {"error": str(exc)})
                            return
                        write_pairing_info(state, self.server.server_address[0],
                                           self.server.server_address[1], self.server.fingerprint)
                    self.send_json(200, {"token": token, "name": socket.gethostname(),
                                         "client_id": client_id})
                    return
                if not self.require_auth():
                    return
                if parsed.path == "/api/codex/call":
                    self.send_json(200, CODEX_TASKS.request_call(self.read_json().get("id", "")))
                elif parsed.path == "/api/codex/approval":
                    body = self.read_json()
                    self.send_json(200, CODEX_TASKS.answer_approval(body.get("id", ""), body.get("approval", ""), body.get("decision", "")))
                elif parsed.path == "/api/codex/send":
                    body = self.read_json()
                    self.send_json(200, CODEX_TASKS.send(body.get("id", ""), body.get("message", ""), body.get("model")))
                elif parsed.path == "/api/codex/stop":
                    self.send_json(200, CODEX_TASKS.stop(self.read_json().get("id", "")))
                elif parsed.path == "/api/revoke":
                    with state.lock:
                        legacy, _admin = state.revoke(self.bearer_token())
                    message = "已撤銷這支手機的連線憑證。"
                    if legacy:
                        message += "此為舊版共用憑證，使用相同舊憑證的其他裝置也已失效。"
                    self.send_json(200, {"message": message})
                elif parsed.path == "/api/folders":
                    body = self.read_json()
                    target = safe_path(str(body.get("path", "")))
                    if target == HOME_ROOT or target.exists():
                        self.send_json(409, {"error": "資料夾已存在或名稱無效。"})
                        return
                    if not target.parent.is_dir():
                        self.send_json(400, {"error": "上層資料夾不存在。"})
                        return
                    target.mkdir()
                    self.send_json(200, {"message": "資料夾已建立。"})
                elif parsed.path == "/api/input":
                    body = self.read_json()
                    self.send_json(200, {"message": perform_input(body)})
                elif parsed.path == "/api/assistant":
                    body = self.read_json()
                    self.send_json(200, assistant_reply(body, state))
                elif parsed.path == "/api/assistant/stream":
                    body = self.read_json()
                    stream = assistant_stream(body, state)
                    first = next(stream)  # Validate and connect to the local model before committing a 200 response.
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("X-Content-Type-Options", "nosniff")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    try:
                        self.send_stream_event(first)
                        for event in stream:
                            self.send_stream_event(event)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as exc:
                        try:
                            self.send_stream_event({"type": "error", "text": str(exc)[:300]})
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                elif parsed.path == "/api/assistant/confirm":
                    body = self.read_json()
                    action_id = str(body.get("action_id", ""))
                    with state.lock:
                        pending = state.pending_actions.pop(action_id, None)
                    if not pending or time.time() > pending[1]:
                        self.send_json(410, {"error": "操作確認已過期，請重新下指令。"})
                        return
                    action = pending[0]
                    if action["kind"] == "open":
                        app = action["app"]
                        if app not in ALLOWED_APPS:
                            raise ValueError("這個 app 不在允許清單中。")
                        subprocess.run(["/usr/bin/open", "-a", ALLOWED_APPS[app]], check=True, timeout=10, capture_output=True)
                        result = f"已送出開啟 {ALLOWED_APPS[app]} 的指令，請在桌面查看結果。"
                    elif action["kind"] == "input":
                        result = perform_input(action["body"])
                    else:
                        raise ValueError("未知的助理操作。")
                    self.send_json(200, {"message": result})
                else:
                    self.send_json(404, {"error": "找不到這個 MacLink 功能。"})
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                self.send_json(400, {"error": str(exc)[:300]})

        def do_PUT(self) -> None:
            try:
                if not self.require_auth():
                    return
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path != "/api/files":
                    self.send_json(404, {"error": "找不到這個 MacLink 功能。"})
                    return
                query = urllib.parse.parse_qs(parsed.query)
                target = safe_path(query.get("path", [""])[0])
                if target == HOME_ROOT or target.exists() or not target.parent.is_dir():
                    self.send_json(409, {"error": "檔案已存在或上層資料夾不存在。"})
                    return
                data = self.read_body(MAX_FILE_BYTES)
                if not data:
                    self.send_json(400, {"error": "上傳檔案是空的。"})
                    return
                temporary = target.with_name(f".{target.name}.{secrets.token_hex(4)}.part")
                try:
                    with temporary.open("xb") as handle:
                        handle.write(data)
                    os.chmod(temporary, 0o600)
                    try:
                        os.link(temporary, target)
                    except FileExistsError:
                        self.send_json(409, {"error": "檔案已存在。"})
                        return
                finally:
                    temporary.unlink(missing_ok=True)
                self.send_json(200, {"message": "檔案已上傳。"})
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                self.send_json(400, {"error": str(exc)[:300]})

        def do_DELETE(self) -> None:
            try:
                if not self.require_auth():
                    return
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path != "/api/files":
                    self.send_json(404, {"error": "找不到這個 MacLink 功能。"})
                    return
                body = self.read_json()
                if body.get("confirm") is not True:
                    self.send_json(400, {"error": "刪除操作需要明確確認。"})
                    return
                query = urllib.parse.parse_qs(parsed.query)
                target = safe_path(query.get("path", [""])[0])
                if target == HOME_ROOT or not target.exists():
                    self.send_json(404, {"error": "找不到可刪除的檔案。"})
                    return
                run_capture([str(input_helper()), "trash", str(target)], timeout=20)
                self.send_json(200, {"message": "項目已移到 Mac 垃圾桶。"})
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                self.send_json(400, {"error": str(exc)[:300]})

    return Handler


class ReusableThreadingServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


_SCREEN_HELPER_LOCK = threading.Lock()


def screen_helper() -> pathlib.Path:
    source = pathlib.Path(__file__).with_name("screen_stream.swift")
    bundled = source.with_name("screen-stream")
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return bundled
    binary = APP_SUPPORT / "screen-stream"
    with _SCREEN_HELPER_LOCK:
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            candidate = APP_SUPPORT / f"screen-stream-{os.getpid()}"
            try:
                result = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-O", "-parse-as-library",
                                         str(source), "-o", str(candidate)], capture_output=True, timeout=120)
                if result.returncode:
                    raise RuntimeError("無法建立桌面串流工具；請確認 Xcode 命令列工具。")
                os.chmod(candidate, 0o700)
                os.replace(candidate, binary)
            finally:
                candidate.unlink(missing_ok=True)
    return binary


_SCREEN_STREAM = ScreenStream(screen_helper)


def capture_screen() -> bytes:
    if int(platform.mac_ver()[0].split(".")[0]) >= 14:
        return _SCREEN_STREAM.capture()
    return capture_screen_legacy()


def capture_screen_legacy() -> bytes:
    with tempfile.TemporaryDirectory(prefix="maclink-") as directory:
        image_path = pathlib.Path(directory) / "screen.jpg"
        display_id, _, _ = display_info()
        try:
            run_capture(["/usr/sbin/screencapture", "-D", str(display_id), "-x", "-t", "jpg", str(image_path)], timeout=15)
        except RuntimeError as exc:
            if "could not create image from display" in str(exc).lower():
                raise RuntimeError("請在 Mac 的『系統設定 → 隱私權與安全性 → 螢幕與系統錄音』允許 python3.13，然後重新連線。") from exc
            raise
        run_capture(["/usr/bin/sips", "-Z", "1920", "-s", "formatOptions", "72", str(image_path)], timeout=10)
        return image_path.read_bytes()


def run_input_command(command: list[str], timeout: int = 10) -> None:
    try:
        subprocess.run(command, check=True, timeout=timeout, capture_output=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError("桌面操作失敗。請檢查 macOS 的輔助使用與自動化權限。") from exc


def perform_input(body: dict) -> str:
    action = body.get("action")
    if action in ("drag", "scroll_up", "scroll_down", "click", "double_click", "right_click") and not input_accessibility():
        raise RuntimeError("Mac 尚未允許桌面控制工具使用「輔助使用」。請在系統設定中啟用後重試。")
    if action == "drag":
        try:
            coordinates = [float(body.get(name, -1)) for name in ("x", "y", "endX", "endY")]
        except (TypeError, ValueError) as exc:
            raise ValueError("拖曳位置格式無效。") from exc
        if any(not 0 <= value <= 1 for value in coordinates):
            raise ValueError("拖曳位置超出畫面。")
        width, height = display_size()
        x1, y1, x2, y2 = coordinates
        points = [round(x1 * width), round(y1 * height), round(x2 * width), round(y2 * height)]
        run_input_command([str(input_helper()), "drag", *(str(point) for point in points)])
        return "已拖曳 Mac 畫面。"
    if action in ("scroll_up", "scroll_down"):
        amount = "500" if action == "scroll_up" else "-500"
        run_input_command([str(input_helper()), "scroll", amount])
        return "已捲動 Mac 畫面。"
    if action in ("click", "double_click", "right_click"):
        x = float(body.get("x", -1))
        y = float(body.get("y", -1))
        if not (0 <= x <= 1 and 0 <= y <= 1):
            raise ValueError("點擊位置超出畫面。")
        width, height = display_size()
        px, py = min(round(width * x), width - 1), min(round(height * y), height - 1)
        run_input_command([str(input_helper()), action, str(px), str(py)])
        return "已在 Mac 畫面操作滑鼠。"
    if action == "type":
        value = body.get("text")
        if not isinstance(value, str) or not value or len(value) > 1200 or any(ord(ch) < 32 and ch not in "\n\t" for ch in value):
            raise ValueError("輸入文字格式無效或超過 1200 個字元。")
        if not input_accessibility():
            raise RuntimeError("Mac 尚未允許桌面控制工具使用「輔助使用」。請在系統設定中啟用後重試。")
        with _TYPE_LOCK:
            run_input_command([str(input_helper()), "type", value], timeout=15)
        return "文字已送到 Mac 前景 app。"
    if action == "key":
        key = str(body.get("key", "")).lower()
        if key not in ALLOWED_KEYS:
            raise ValueError("這個按鍵組合不在允許清單中。")
        name, modifier = ALLOWED_KEYS[key]
        # AppleScript key code names differ across macOS releases. Use direct key strokes for common controls.
        key_scripts = {
            "return": "key code 36", "tab": "key code 48", "escape": "key code 53",
            "delete": "key code 51", "space": 'keystroke " "', "up": "key code 126",
            "down": "key code 125", "left": "key code 123", "right": "key code 124",
        }
        if modifier:
            command = f"keystroke \"{name}\" using {{{modifier}}}"
        else:
            command = key_scripts[key]
        script = f"tell application \"System Events\" to {command}"
        run_input_command(["/usr/bin/osascript", "-e", script])
        return "快捷鍵已送到 Mac。"
    raise ValueError("未知的桌面操作。")


def assistant_request(body: dict) -> tuple[str, list]:
    message = body.get("message")
    history = body.get("history", [])
    if not isinstance(message, str) or not message.strip() or len(message) > 4000:
        raise ValueError("訊息不可為空，且最多 4000 個字元。")
    if not isinstance(history, list) or len(history) > 24:
        raise ValueError("對話歷史格式無效。")
    return message, history


def assistant_quick_reply(message: str, state: CompanionState) -> dict | None:
    if any(term in message.casefold() for term in ("mac 狀態", "電腦狀態", "電腦狀況", "主機狀態", "computer status")):
        width, height = display_size()
        return {
            "reply": f"MacLink 已連線到 {socket.gethostname()}。系統：macOS；主螢幕：{width} × {height}。",
            "action_id": None,
            "action_summary": None,
        }

    parsed = parse_action(message, ALLOWED_APPS)
    if parsed:
        action, summary = parsed
        action_id = secrets.token_urlsafe(18)
        with state.lock:
            state.pending_actions = {key: value for key, value in state.pending_actions.items() if value[1] > time.time()}
            if len(state.pending_actions) >= 32:
                raise ValueError("待確認操作過多，請稍後再試。")
            state.pending_actions[action_id] = (action, time.time() + 60)
        return {"reply": "請核對操作內容後確認執行。\n" + summary, "action_id": action_id, "action_summary": summary}

    if any(term in message for term in ("操作電腦", "控制電腦", "你會做什麼", "你能做什麼")):
        return {"reply": "可以執行單步操作：開啟Safari、開啟記事本、輸入：你好、向下捲動、按下Enter。確認操作卡後才會執行。請先在桌面頁確認前景程式；目前還不能自主看畫面完成多步任務。", "action_id": None, "action_summary": None}

    if any(term in message.casefold() for term in ("刪除", "寄信", "傳送", "付款", "購買", "解除權限")):
        return {"reply": "這類操作需要在對應畫面逐項確認。你可以到「檔案」頁刪除檔案，或在桌面頁親自操作。", "action_id": None, "action_summary": None}
    return None


def assistant_context(message: str, history: list) -> tuple[object, dict, list[dict]]:
    if not JARVIS_RUNTIME.is_dir():
        raise RuntimeError("這台 Mac 尚未安裝 Jarvis 本機助理；桌面與檔案仍可使用，也可以先查詢電腦狀態。")
    with _JARVIS_IMPORT_LOCK:
        sys.path.insert(0, str(JARVIS_RUNTIME))
        try:
            from assistant_config import load as load_assistant_config
            from local_provider import OllamaProvider
        finally:
            sys.path.remove(str(JARVIS_RUNTIME))
    settings = load_assistant_config()
    active = settings["profiles"][settings["active_profile"]]
    if active.get("provider") != "ollama":
        raise RuntimeError("MacLink 助理只連接這台 Mac 的本機模型；請切換 Jarvis 本機設定。")
    config = active["llm"]
    provider = OllamaProvider(config)
    provider.check()  # Refuses missing or cloud-backed models; never downloads a model or falls back to a remote service.
    recent_history = []
    total_chars = 0
    for item in reversed(history):
        if not isinstance(item, dict):
            continue
        role = item.get("role")
        content = item.get("content")
        if role in ("user", "assistant") and isinstance(content, str) and len(content) <= 4000:
            remaining = MAX_CHAT_CHARS - total_chars
            if remaining <= 0:
                break
            content = content[-remaining:]
            recent_history.append({"role": role, "content": content})
            total_chars += len(content)
    safe_history = list(reversed(recent_history))
    if not safe_history or safe_history[-1].get("role") != "user" or safe_history[-1].get("content") != message:
        safe_history.append({"role": "user", "content": message})
    return provider, config, [{"role": "system", "content": ASSISTANT_SYSTEM}, *safe_history[-16:]]


def assistant_payload(config: dict, messages: list[dict], stream: bool) -> dict:
    return {
        "model": config["model"], "messages": messages, "stream": stream,
        "think": config.get("think", False), "keep_alive": "10m",
        "options": {"temperature": 0.2, "num_predict": 320, "num_ctx": 8192},
    }


def assistant_reply(body: dict, state: CompanionState) -> dict:
    message, history = assistant_request(body)
    quick = assistant_quick_reply(message, state)
    if quick is not None:
        return quick
    try:
        provider, config, messages = assistant_context(message, history)
        result = provider.request("/api/chat", assistant_payload(config, messages, False),
                                  timeout=max(config["timeout_seconds"], 90))
        content = result.get("message", {}).get("content", "")
        if not isinstance(content, str) or not content.strip():
            raise RuntimeError("Jarvis 本機模型回傳空白內容。")
        return {"reply": content.strip()[:1800], "action_id": None, "action_summary": None}
    except (KeyError, TypeError, ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Jarvis 本機模型目前無法使用：{str(exc)[:220]}") from exc


def assistant_stream(body: dict, state: CompanionState):
    message, history = assistant_request(body)
    quick = assistant_quick_reply(message, state)
    if quick is not None:
        yield {"type": "delta", "text": quick["reply"]}
        yield {"type": "done", "action_id": quick["action_id"], "action_summary": quick["action_summary"]}
        return
    provider, config, messages = assistant_context(message, history)
    request = urllib.request.Request(
        provider.base + "/api/chat",
        data=json.dumps(assistant_payload(config, messages, True)).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    total = 0
    # A cold local model can take longer than the normal reply deadline to load.
    with provider.opener.open(request, timeout=max(config["timeout_seconds"], 90)) as response:
        for line in response:
            if len(line) > MAX_JSON_BYTES:
                raise RuntimeError("本機助理回覆超過單段大小限制。")
            part = json.loads(line)
            chunk = part.get("message", {}).get("content", "")
            if not isinstance(chunk, str):
                raise RuntimeError("本機助理回覆格式無效。")
            if chunk and total < 1800:
                piece = chunk[:1800 - total]
                total += len(piece)
                yield {"type": "delta", "text": piece}
            if part.get("done") or total >= 1800:
                break
    if total == 0:
        raise RuntimeError("Jarvis 本機模型回傳空白內容。")
    yield {"type": "done", "action_id": None, "action_summary": None}


def main() -> int:
    parser = argparse.ArgumentParser(description="Run MacLink over Tailscale or a private LAN.")
    parser.add_argument("--port", type=int, default=PORT_DEFAULT)
    parser.add_argument("--network", choices=("auto", "tailnet", "lan"), default="auto",
                        help="Auto prefers Tailscale when it is connected; tailnet requires it; lan stays local.")
    parser.add_argument("--host", default=None, help="Choose one of this Mac's detected private network addresses.")
    args = parser.parse_args()
    if not (1 <= args.port <= 65535):
        parser.error("port must be between 1 and 65535")
    try:
        tailnet = tailscale_address()
        lan_addresses: list[str] = []
        if args.network == "lan" or (args.network == "auto" and (not tailnet or args.host)):
            try:
                lan_addresses = local_addresses()
            except RuntimeError:
                if not tailnet or args.network == "lan":
                    raise
        addresses = [*([tailnet] if tailnet else []), *lan_addresses]
        if args.network == "tailnet" and not tailnet:
            raise RuntimeError("Tailscale 尚未連線；請在 Mac 上先啟動 Tailscale。")
        address = args.host or (tailnet if args.network != "lan" and tailnet else lan_addresses[0])
        if address not in addresses or (args.network == "lan" and address == tailnet):
            raise RuntimeError("指定的位址不是這台 Mac 偵測到的私人網路位址。")
        connection_mode = "tailnet" if address == tailnet else "lan"
        cert, key, fingerprint = ensure_certificate([address])
        token, pair_code, expires = app_state()
        state = CompanionState(token, pair_code, expires)
        server = ReusableThreadingServer((address, args.port), make_handler(state, connection_mode))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(cert), str(key))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.fingerprint = fingerprint
        write_pairing_info(state, address, args.port, fingerprint)
    except (OSError, RuntimeError, ssl.SSLError, subprocess.TimeoutExpired) as exc:
        print(f"MacLink 無法啟動：{exc}", file=sys.stderr)
        return 1

    print(f"MacLink companion 已在{'Tailscale 私人網路' if connection_mode == 'tailnet' else '私人區域網路'}啟動。")
    print(f"Mac 位址：{address}")
    print(f"連接埠：{args.port}")
    if sys.stdout.isatty():
        print(f"一次性配對碼：{pair_code}（10 分鐘內有效）")
    else:
        print("一次性配對碼已寫入 Mac 使用者專屬的 pairing-info.json。")
    print(f"TLS SHA-256 指紋：{fingerprint}")
    print("配對碼使用一次後失效。按 Control-C 停止服務。")
    stop_rotation = threading.Event()
    rotation = threading.Thread(target=rotate_pairing_codes,
                                args=(state, address, args.port, fingerprint, stop_rotation),
                                daemon=True)
    rotation.start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        print("\nMacLink companion 已停止。")
    finally:
        stop_rotation.set()
        server.server_close()
        PAIRING_INFO.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
