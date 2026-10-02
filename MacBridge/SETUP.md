# MacLink Mac 端安裝

這個套件讓 iPhone 上的「我的 Mac」連線到自己的 Mac。它不是 iPhone 安裝檔，也不會啟用 Apple 開發者會員。

## 準備

- Mac 必須已登入使用者桌面，使用時保持開機且未休眠。
- 安裝 Python 3.10 以上，並具備支援 `req -addext` 的 OpenSSL。正式 App 內含預編譯桌面工具，不需 Xcode；若直接從未編譯的原始碼安裝，才需要 Xcode 或 Command Line Tools。套件不自動下載或購買依賴。
- Mac 及 iPhone 的 Tailscale 加入同一個私人網路並顯示已連線。
- 桌面與檔案功能不需要 Jarvis。助理一般問答需要在 Mac 另行安裝及設定相容的 Jarvis 本機模型；此套件未包含 Jarvis 或模型。

## 安裝與配對

1. 將已簽章並經 Apple 公證的套件解壓縮到自己的 Mac，開啟 `MacLink Companion` App。
2. 在 App 先按「檢查環境」，再按「安裝／更新」。安裝會建立目前使用者的登入常駐服務；不需要管理員密碼，也不開放公網連接埠。原始碼安裝時才雙擊 `install.command`。
3. 在 App 按「檢查連線與權限」查看結果。若權限未授予，在系統設定依實際需要允許服務使用的 Python 螢幕錄製及控制權限；完成後再按「安裝／更新」。原始碼安裝時可雙擊 `check-connection.command`。
4. 在 App 按「顯示配對資訊」，在自己的 iPhone App 輸入顯示的私人位址、連接埠、一次性配對碼及憑證指紋。請勿將配對資訊傳給其他人。原始碼安裝時可雙擊 `show-pairing.command`。
5. 完成配對後，先在本地驗證桌面、檔案與需要的助理功能，再關閉 iPhone Wi-Fi、使用行動網路測試。

只有未使用的配對碼會定時輪換。若配對碼已被使用而需要重新配對，可重新執行 `install.command` 產生新的待配對資訊；既有授權不因此自動撤銷。

## 安裝內容

服務程式與 `show-pairing.command`、`check-connection.command`、`install.command` 等操作指令位於 `~/Library/Application Support/MacLink/Bridge/`；即使移除下載的安裝壓縮檔，仍可從此資料夾檢查與重新配對。使用者登入啟動項目為 `~/Library/LaunchAgents/com.adam.maclink.plist`。憑證及配對資料只在安裝後於本機建立，不包含在套件內。

檔案功能可讀寫目前 Mac 使用者資料夾內的檔案。手機移到垃圾桶前會確認，單檔傳輸限制為 40 MB。Mac 權限仍由 macOS 管理。

## 檢查及停止

在套件資料夾執行 `python3 install_service.py --check` 可只檢查依賴，不安裝或重啟。

`python3.13 diagnostics.py --screen` 可額外檢查螢幕 JPEG，檢查畫面不會寫入檔案。診斷結果不包含權杖、配對碼或憑證指紋。

要停止目前使用者的服務：

```sh
launchctl bootout gui/$(id -u)/com.adam.maclink
```

停止不會刪除設定。正式 App 可按「安裝／更新」恢復服務；原始碼安裝時可再次執行 `install.command`。服務停止或 Mac 休眠期間，手機無法遠端操作。

若 Gatekeeper 阻擋下載的 App，請向提供者取得已完成 Apple 公證的正式版本；不要停用 Gatekeeper 來略過 macOS 的阻擋。發布前仍須在全新 Mac 驗證下載、安裝與完整功能。

## 桌面串流

macOS 14 以上會在收到已授權的畫面請求時啟動畫面串流，僅在記憶體保留最新 JPEG；沒有畫面請求約 10 秒後自動停止。離開桌面頁後，macOS 的螢幕擷取指示可能短暫持續。較舊 macOS 使用原本的單張截圖方式，更新速度較慢。
