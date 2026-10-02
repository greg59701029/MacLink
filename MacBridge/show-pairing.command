#!/bin/zsh
python3 - <<'PY'
import json
import pathlib
import time

path = pathlib.Path.home() / "Library" / "Application Support" / "MacLink" / "pairing-info.json"
if not path.exists():
    print("目前沒有待配對資訊。請確認 MacLink 服務正在執行；已配對後會移除此檔。")
else:
    info = json.loads(path.read_text(encoding="utf-8"))
    if time.time() >= info["expires_at"]:
        print("配對碼正在更新，請稍等幾秒再開啟一次。")
    else:
        print(f"Mac Tailscale 位址：{info['address']}")
        print(f"連接埠：{info['port']}")
        print(f"一次性配對碼：{info['code']}")
        print(f"TLS SHA-256 指紋：{info['fingerprint']}")
        print("請只在你自己的 iPhone MacLink App 輸入這些資訊。")
PY
