#!/usr/bin/env python3
"""Install the MacLink companion as a private per-user login service."""

from __future__ import annotations

import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import time

from server import JARVIS_RUNTIME, tailscale_address


LABEL = "com.adam.maclink"
SOURCE = pathlib.Path(__file__).resolve().parent
SUPPORT = pathlib.Path.home() / "Library" / "Application Support" / "MacLink"
BRIDGE = SUPPORT / "Bridge"
LOGS = pathlib.Path.home() / "Library" / "Logs" / "MacLink"
PLIST = pathlib.Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
RUNTIME_FILES = ("server.py", "assistant_actions.py", "agent_transport.py", "codex_tasks.py",
                 "input_helper.swift", "screen_stream.py", "screen_stream.swift", "diagnostics.py")
HELPER_FILES = ("install_service.py", "install.command", "run.command",
                "check-connection.command", "show-pairing.command", "SETUP.md")
NATIVE_FILES = ("input-helper", "screen-stream")


def preflight() -> tuple[str, list[str]]:
    python = shutil.which("python3.13") or sys.executable
    issues = []
    if sys.platform != "darwin":
        issues.append("MacLink companion 需要在 macOS 執行。")
    if not pathlib.Path(python).is_absolute():
        issues.append("找不到可用的 Python 執行檔。")
    else:
        try:
            result = subprocess.run([python, "-c", "import sys, ssl; sys.exit(0 if sys.version_info >= (3, 10) else 1)"],
                                    capture_output=True, timeout=5, check=False)
            if result.returncode != 0:
                issues.append("需要 Python 3.10 以上及可用的 SSL 模組。")
        except (OSError, subprocess.TimeoutExpired):
            issues.append("Python 無法執行。")
    if not all((SOURCE / name).is_file() and os.access(SOURCE / name, os.X_OK) for name in NATIVE_FILES):
        try:
            result = subprocess.run(["/usr/bin/xcrun", "--find", "swiftc"], capture_output=True, timeout=10, check=False)
            if result.returncode != 0:
                issues.append("需要 Xcode 或 Command Line Tools 的 Swift 編譯器。")
        except (OSError, subprocess.TimeoutExpired):
            issues.append("找不到 Xcode／Command Line Tools。")
    openssl = next((path for path in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/bin/openssl")
                    if pathlib.Path(path).is_file()), None)
    if not openssl:
        issues.append("找不到產生本機加密憑證所需的 OpenSSL。")
    else:
        try:
            result = subprocess.run([openssl, "req", "-help"], capture_output=True, text=True, timeout=5, check=False)
            if "-addext" not in result.stdout + result.stderr:
                issues.append("OpenSSL 版本不支援建立主機憑證，請安裝 OpenSSL 3。")
        except (OSError, subprocess.TimeoutExpired):
            issues.append("OpenSSL 無法執行。")
    if not tailscale_address():
        issues.append("請先安裝並連線 Tailscale，再安裝 MacLink 常駐服務。")
    for name in (*RUNTIME_FILES, *HELPER_FILES):
        if not (SOURCE / name).is_file():
            issues.append(f"安裝檔案不完整：缺少 {name}。")
    return python, issues


def main() -> int:
    parser = argparse.ArgumentParser(description="安裝私人 MacLink 常駐服務。")
    parser.add_argument("--check", action="store_true", help="只檢查依賴，不安裝、不重啟服務")
    args = parser.parse_args()
    python, issues = preflight()
    if issues:
        print("安裝前需要處理：", file=sys.stderr)
        for issue in issues:
            print(f"- {issue}", file=sys.stderr)
        return 1
    print("安裝依賴檢查通過：Python、桌面工具、OpenSSL 與 Tailscale。")
    if not all((JARVIS_RUNTIME / name).is_file() for name in ("assistant_config.py", "local_provider.py")):
        print("尚未安裝 Jarvis；桌面與檔案仍可使用，本機模型問答需另外設定。")
    if args.check:
        return 0
    for directory in (SUPPORT, BRIDGE, LOGS, PLIST.parent):
        directory.mkdir(parents=True, exist_ok=True)
    for directory in (SUPPORT, BRIDGE, LOGS):
        os.chmod(directory, 0o700)
    for name in (*RUNTIME_FILES, *HELPER_FILES, *(name for name in NATIVE_FILES if (SOURCE / name).is_file())):
        target = BRIDGE / name
        shutil.copy2(SOURCE / name, target)
        os.chmod(target, 0o700 if name.endswith(".command") or name in NATIVE_FILES else 0o600)

    data = {
        "Label": LABEL,
        "ProgramArguments": [python, "-B", str(BRIDGE / "server.py"), "--network", "tailnet"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "StandardOutPath": str(LOGS / "bridge.out.log"),
        "StandardErrorPath": str(LOGS / "bridge.err.log"),
        "EnvironmentVariables": {
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        },
    }
    temporary = PLIST.with_suffix(".plist.tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(data, handle)
    os.chmod(temporary, 0o600)
    os.replace(temporary, PLIST)

    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"],
                   capture_output=True, check=False)
    for attempt in range(4):
        result = subprocess.run(["/bin/launchctl", "bootstrap", domain, str(PLIST)],
                                capture_output=True, text=True, check=False)
        if result.returncode == 0:
            break
        if attempt == 3:
            raise RuntimeError((result.stderr or result.stdout or "MacLink 常駐服務無法啟動").strip())
        time.sleep(0.3 * (attempt + 1))
    print("MacLink 已設定為登入後自動啟動，並只監聽這台 Mac 的 Tailscale 私人位址。")
    print("首次配對資訊可在 Mac 上開啟 MacBridge/show-pairing.command 查看。")
    print("若手機無法連線，可雙擊 MacBridge/check-connection.command 檢查。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
