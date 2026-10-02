#!/usr/bin/env python3
"""Read-only MacLink checks. Never print pairing codes, tokens or certificates."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request

from server import APP_SUPPORT, JARVIS_RUNTIME, PORT_DEFAULT, tailscale_address


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def collect_checks(*, check_screen: bool = False) -> list[dict[str, str]]:
    checks = []

    def add(name: str, state: str, detail: str) -> None:
        checks.append({"name": name, "state": state, "detail": detail})

    if sys.version_info < (3, 10):
        add("Python 環境", "error",
            "此診斷需要 Python 3.10 以上；建議使用安裝服務時的 Python 3.13，或雙擊 check-connection.command。尚未檢查 Mac 連線。")
        return checks

    address = tailscale_address()
    add("私人網路", "ok" if address else "error",
        "這台 Mac 的 Tailscale 已連線。" if address else "請先讓這台 Mac 的 Tailscale 顯示已連線。")

    try:
        result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/com.adam.maclink"],
                                capture_output=True, text=True, timeout=5, check=False)
        running = result.returncode == 0 and any(line.strip() == "state = running" for line in result.stdout.splitlines())
        add("登入常駐服務", "ok" if running else "error",
            "MacLink 服務正在執行。" if running else "服務未執行；請執行 install_service.py，或檢查 MacLink 服務記錄。")
    except (OSError, subprocess.TimeoutExpired):
        add("登入常駐服務", "error", "無法確認服務狀態。")

    certificate = APP_SUPPORT / "server-cert.pem"
    token_path = APP_SUPPORT / "access-token"
    if not address or not certificate.is_file() or not token_path.is_file():
        add("安全連線", "error", "尚缺私人網路或服務憑證，無法檢查安全連線。")
    else:
        stage = "安全連線"
        try:
            context = ssl.create_default_context(cafile=str(certificate))
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                urllib.request.HTTPSHandler(context=context), NoRedirect())
            token = token_path.read_text(encoding="utf-8").strip()
            if not token:
                raise ValueError("missing token")

            def request(path: str, maximum: int) -> tuple[bytes, str]:
                req = urllib.request.Request(f"https://{address}:{PORT_DEFAULT}{path}",
                                             headers={"Authorization": f"Bearer {token}"})
                with opener.open(req, timeout=12) as response:
                    data = response.read(maximum + 1)
                    if len(data) > maximum:
                        raise ValueError("response too large")
                    return data, response.headers.get_content_type()

            raw, _ = request("/api/status", 64 * 1024)
            status = json.loads(raw)
            if not isinstance(status, dict) or status.get("platform") != "macOS":
                raise ValueError("invalid status")
            add("安全連線", "ok", "憑證、主機名稱及授權驗證成功。")
            add("桌面控制權限", "ok" if status.get("input_accessibility") is True else "error",
                "服務回報控制權限已授予。" if status.get("input_accessibility") is True
                else "請在 Mac 系統設定允許服務所使用的 Python 控制電腦，再重啟服務。")
            if check_screen:
                stage = "桌面畫面"
                screen, content_type = request("/api/screen", 12 * 1024 * 1024)
                valid = content_type == "image/jpeg" and screen.startswith(b"\xff\xd8") and screen.endswith(b"\xff\xd9")
                add("桌面畫面", "ok" if valid else "error",
                    "服務已回傳 JPEG；檢查畫面未寫入檔案。" if valid else "未收到有效的 JPEG 畫面。")
            else:
                add("桌面畫面", "unchecked", "尚未擷取畫面；加上 --screen 可檢查螢幕讀取，且不儲存畫面。")
        except urllib.error.HTTPError as exc:
            detail = "請確認 Mac 已允許服務錄製螢幕。" if stage == "桌面畫面" else "請檢查服務或重新配對。"
            add(stage, "error", f"MacLink 回傳 HTTP {exc.code}；{detail}")
        except (OSError, ValueError, ssl.SSLError, urllib.error.URLError):
            add(stage, "error", "讀取畫面失敗；請確認螢幕權限及連線。" if stage == "桌面畫面"
                else "連線或憑證驗證失敗；請確認服務、Tailscale 及 Mac 時間。")

    has_runtime = all((JARVIS_RUNTIME / filename).is_file() for filename in ("assistant_config.py", "local_provider.py"))
    add("本機助理", "unchecked", "Jarvis 程式已安裝；模型回覆尚未測試。" if has_runtime
        else "尚未安裝 Jarvis；桌面與檔案功能可獨立使用。")
    add("外出連線", "unchecked", "本機檢查無法證明手機行動網路可用；仍須用手機關閉 Wi-Fi 後實測。")
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description="檢查 MacLink，不修改權限、配對或網路設定。")
    parser.add_argument("--screen", action="store_true", help="讀取一張桌面 JPEG 以檢查螢幕權限，不儲存畫面")
    parser.add_argument("--json", action="store_true", help="輸出不含配對資料的 JSON")
    args = parser.parse_args()
    checks = collect_checks(check_screen=args.screen)
    if args.json:
        print(json.dumps({"checks": checks}, ensure_ascii=False, indent=2))
    else:
        labels = {"ok": "通過", "error": "需處理", "unchecked": "未驗證"}
        print("MacLink 連線檢查\n")
        for check in checks:
            print(f"[{labels[check['state']]}] {check['name']}：{check['detail']}")
    return int(any(check["state"] == "error" for check in checks))


if __name__ == "__main__":
    raise SystemExit(main())
