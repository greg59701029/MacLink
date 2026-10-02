"""Explicit user commands only; model text never becomes an executable action."""
import re

APP_ALIASES = {'瀏覽器': 'safari', '檔案總管': 'finder', '備忘錄': 'notes',
               '記事本': 'textedit', '文字編輯': 'textedit', '行事曆': 'calendar',
               '計算機': 'calculator', '終端機': 'terminal'}
KEYS = {'enter': 'return', 'return': 'return', '返回': 'return', '換行': 'return',
        'esc': 'escape', 'escape': 'escape', 'tab': 'tab', '空白鍵': 'space',
        '上鍵': 'up', '下鍵': 'down', '左鍵': 'left', '右鍵': 'right',
        '全選': 'command+a', '複製': 'command+c', '貼上': 'command+v', '復原': 'command+z'}


def parse_action(message, allowed_apps):
    text = re.sub(r'^(?:請幫我|幫我|請)\s*', '', message.strip())
    opened = re.fullmatch(r'(?:打開|開啟|open)\s*(.+)', text, re.I)
    if opened:
        name = opened.group(1).strip().casefold()
        name = APP_ALIASES.get(name, name)
        if name in allowed_apps:
            return {'kind': 'open', 'app': name}, f'在 Mac 開啟 {allowed_apps[name]}'
    typed = re.fullmatch(r'(?:輸入文字|輸入|打字)\s*[:：]\s*([\s\S]+)', text)
    if typed:
        value = typed.group(1)
        if 0 < len(value) <= 1200 and all(ord(c) >= 32 or c in '\n\t' for c in value):
            return {'kind': 'input', 'body': {'action': 'type', 'text': value}}, '在 Mac 目前焦點欄位輸入以下文字（請先確認前景程式）：\n' + value
    scroll = {'向上捲動': 'scroll_up', '往上捲動': 'scroll_up', '向下捲動': 'scroll_down', '往下捲動': 'scroll_down'}
    if text in scroll:
        return {'kind': 'input', 'body': {'action': scroll[text]}}, '在 Mac 目前游標所在位置' + text
    pressed = re.fullmatch(r'(?:按下|按)\s*(.+)', text)
    if pressed and pressed.group(1).strip().casefold() in KEYS:
        key = KEYS[pressed.group(1).strip().casefold()]
        return {'kind': 'input', 'body': {'action': 'key', 'key': key}}, f'對 Mac 前景程式送出 {key}；可能提交目前表單或執行目前指令，請先確認畫面'
    return None
