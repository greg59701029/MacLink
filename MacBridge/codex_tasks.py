"""Codex task access over the paired companion's existing TLS channel."""
import queue
import subprocess
import sys
import json
import time
import sqlite3
import os
import shutil
import re
from pathlib import Path
import threading
import uuid
from agent_transport import AgentTransport, EngineRequestError


JARVIS_STATE_DB = Path.home() / 'Library' / 'Application Support' / 'JarvisMac' / 'state.db'


def resolve_codex_cli(app_roots=None):
    """Find the app-server binary across Codex/ChatGPT app layouts."""
    candidates = []
    override = os.environ.get('MACLINK_CODEX_CLI_PATH')
    if override:
        candidates.append(Path(override).expanduser())
    discovered = shutil.which('codex')
    if discovered:
        candidates.append(Path(discovered))

    roots = app_roots or (Path('/Applications'), Path.home() / 'Applications')
    for root in roots:
        for app_name in ('ChatGPT.app', 'Codex.app'):
            resources = Path(root) / app_name / 'Contents' / 'Resources'
            candidates.extend((
                resources / 'codex',
                resources / 'codex-cli' / 'CodexCLI.app' / 'Contents' / 'MacOS' / 'codex',
                resources / 'CodexCLI.app' / 'Contents' / 'MacOS' / 'codex',
            ))
        # Also cover renamed OpenAI apps and future bundle names while keeping
        # discovery within the standard per-machine and per-user app folders.
        try:
            candidates.extend(Path(root).glob('*.app/Contents/Resources/codex'))
            candidates.extend(Path(root).glob(
                '*.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'))
        except OSError:
            pass

    seen = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return str(resolved)
    raise RuntimeError('找不到 Codex 桌面 App 的 app-server 執行檔。請確認 Codex／ChatGPT App 已安裝，或設定 MACLINK_CODEX_CLI_PATH。')


class CodexTasks:
    def __init__(self):
        self.lock = threading.RLock()
        self.engine = None
        self.loaded = set()
        self.notices = {}
        self.approvals = {}
        self.calls = {}
        self.started_turns = {}
        self.running_turns = {}
        self.pending_stops = {}
        self.turn_statuses = {}

    def connect(self):
        with self.lock:
            if self.engine is None or self.engine._closed:
                engine = AgentTransport([resolve_codex_cli(), 'app-server', '--stdio'])
                try:
                    engine.start()
                except Exception:
                    engine.close()
                    raise
                self.running_turns.clear()
                self.pending_stops.clear()
                self.turn_statuses.clear()
                self.started_turns.clear()
                self.loaded.clear()
                self.approvals.clear()
                self.engine = engine
                threading.Thread(target=self.events, args=(engine,), daemon=True).start()
            return self.engine

    def events(self, engine):
        while not engine._closed:
            try:
                event = engine.events.get(timeout=1)
            except queue.Empty:
                continue
            if self.observe_turn_event(engine, event):
                continue
            if event.get('method') == 'serverRequest/resolved':
                params = event.get('params', {})
                with self.lock:
                    for token, entry in list(self.approvals.items()):
                        if (entry['engine'] is engine and entry['request'] == params.get('requestId')
                                and entry['thread'] == params.get('threadId')):
                            self.approvals.pop(token, None)
                continue
            if 'id' in event:
                params = event.get('params', {})
                thread = params.get('threadId', '')
                if (event.get('method') == 'item/commandExecution/requestApproval'
                        and isinstance(params.get('command'), str) and params['command']):
                    with self.lock:
                        token = str(uuid.uuid4())
                        self.approvals[token] = {'engine': engine, 'request': event['id'],
                            'thread': thread, 'turn': params.get('turnId'), 'created': time.monotonic(),
                            'details': json.dumps(params, ensure_ascii=False, indent=2)}
                    continue
                # Never silently approve a remote request. Until a typed mobile
                # approval UI exists, refuse and tell the user to use the Mac.
                self.notices[thread] = '此操作需要批准或補充資訊，手機尚不支援此確認；請在 Mac 接續處理。'
                try:
                    engine.reject_request(event['id'])
                except (RuntimeError, OSError, ValueError):
                    return

    def observe_turn_event(self, engine, event):
        method = event.get('method')
        if method not in ('turn/started', 'turn/completed'):
            return False
        params = event.get('params', {})
        thread = params.get('threadId')
        turn = params.get('turn', {})
        turn_id = turn.get('id')
        if not isinstance(thread, str) or not isinstance(turn_id, str):
            return True
        queued_stop = False
        with self.lock:
            if engine is not self.engine:
                return True
            if method == 'turn/started':
                self.started_turns[thread] = turn_id
                self.running_turns[thread] = turn_id
                self.turn_statuses[thread] = (turn_id, 'inProgress')
                queued_stop = self.pending_stops.get(thread) == turn_id
                if queued_stop:
                    self.pending_stops.pop(thread, None)
            else:
                # A completion for an old turn must not clear a newer turn.
                current = self.started_turns.get(thread)
                if current is None or current == turn_id:
                    self.turn_statuses[thread] = (turn_id, turn.get('status'))
                for records in (self.started_turns, self.running_turns, self.pending_stops):
                    if records.get(thread) == turn_id:
                        records.pop(thread, None)
            # Keep lifecycle memory bounded; active turns are retained.
            if len(self.turn_statuses) > 256:
                for key in list(self.turn_statuses):
                    if key not in self.started_turns:
                        self.turn_statuses.pop(key, None)
                        if len(self.turn_statuses) <= 256:
                            break
        if queued_stop:
            try:
                engine.interrupt(thread, turn_id)
            except (RuntimeError, TimeoutError, OSError):
                self.notices[thread] = '停止要求未確認；請查看回合狀態，必要時在 Mac 接續處理。'
        return True

    @staticmethod
    def identifier(value):
        if not isinstance(value, str):
            raise ValueError("Invalid task identifier.")
        return str(uuid.UUID(value))

    def pinned(self):
        # Read the desktop sidebar order; do not alter Codex storage.
        path = Path.home() / ".codex" / "state_5.sqlite"
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            rows = connection.execute(
                "SELECT t.id, COALESCE(NULLIF(t.name, ''), t.title) "
                "FROM threads t JOIN thread_sections s ON s.id=t.thread_section_id "
                "WHERE s.name='Pinned' AND t.archived=0 ORDER BY t.section_position, t.id"
            ).fetchall()
            return [{"id": row[0], "title": row[1] or "未命名任務"} for row in rows]
        finally:
            connection.close()

    def listing(self, cursor=None):
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) > 4096):
            raise ValueError('Invalid page cursor.')
        params = {'limit': 50, 'archived': False}
        if cursor:
            params['cursor'] = cursor
        result = self.connect().request('thread/list', params)
        warning = None
        try:
            pinned = self.pinned()
        except (sqlite3.Error, OSError):
            pinned = None
            warning = '暫時無法讀取置頂分類，仍可使用其他任務；請稍後重新整理。'
        return {'pinnedTasks': pinned, 'warning': warning, 'tasks': [{'id': t['id'], 'title': t.get('name') or t.get('preview') or '未命名任務',
                          'project': Path(t.get('cwd') or '').name or '一般任務'}
                          for t in result.get('data', [])], 'nextCursor': result.get('nextCursor')}

    def read(self, identifier):
        identifier = self.identifier(identifier)
        with self.lock:
            acknowledged_before_read = self.started_turns.get(identifier)
        try:
            page = self.connect().request('thread/turns/list', {
                'threadId': identifier, 'limit': 10, 'sortDirection': 'desc', 'itemsView': 'summary'})
        except EngineRequestError as error:
            # A new thread may not have a materialized history yet. Do not
            # infer completion or fetch its entire history as a fallback.
            if error.code != -32601 or not acknowledged_before_read:
                raise
            page = {'data': []}
        messages = []
        active = None
        for turn in reversed(page.get('data', [])):
            if turn.get('status') == 'inProgress':
                active = turn['id']
            for item in turn.get('items', []):
                if item.get('type') == 'agentMessage':
                    messages.append({'role': 'assistant', 'text': item.get('text', '')})
                elif item.get('type') == 'userMessage':
                    text = '\n'.join(c.get('text', '') for c in item.get('content', []) if c.get('type') == 'text')
                    messages.append({'role': 'user', 'text': text})
        with self.lock:
            acknowledged = self.started_turns.get(identifier)
            lifecycle = self.turn_statuses.get(identifier)
        if lifecycle and lifecycle[1] in ('completed', 'failed', 'interrupted') and active == lifecycle[0]:
            active = None
        latest_status = ('inProgress' if acknowledged else lifecycle[1] if lifecycle else
                         page.get('data', [{}])[0].get('status') if page.get('data') else None)
        return {'id': identifier, 'messages': messages[-60:], 'activeTurn': acknowledged or active,
                'latestTurnStatus': latest_status,
                'notice': self.notices.get(identifier) or ('目前顯示最近 10 回合對話。' if page.get('nextCursor') else None),
                'approvals': self.pending_approvals(identifier)}

    @staticmethod
    def call_history(thread, db_path=None):
        thread = CodexTasks.identifier(thread)
        path = Path(db_path) if db_path else JARVIS_STATE_DB
        try:
            connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
            connection.row_factory = sqlite3.Row
            try:
                rows = connection.execute('''SELECT id,thread,created,status,dial_status,
                    requested_at,connected_at,ended_at,detail,
                    (SELECT COUNT(*) FROM call_transcripts t WHERE t.call_id=c.id) AS transcriptTurns
                    FROM call_records c WHERE thread=? ORDER BY created DESC LIMIT 50''',
                    (thread,)).fetchall()
                return {'calls': [dict(row) for row in rows]}
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise RuntimeError('Mac 尚未提供通話紀錄；請更新 MacLink 與 Jarvis 後重試。') from error

    @staticmethod
    def call_transcript(call_id, thread, db_path=None):
        thread = CodexTasks.identifier(thread)
        if not isinstance(call_id, str) or not re.fullmatch(
                r'(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})', call_id):
            raise ValueError('通話識別碼格式無效。')
        path = Path(db_path) if db_path else JARVIS_STATE_DB
        try:
            connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
            connection.row_factory = sqlite3.Row
            try:
                call = connection.execute('SELECT id,thread,status,detail FROM call_records '
                                          'WHERE id=? AND thread=?', (call_id, thread)).fetchone()
                if not call:
                    raise ValueError('找不到這通電話，或它不屬於目前任務。')
                transcript = connection.execute('SELECT seq,role,content,created FROM call_transcripts '
                                                'WHERE call_id=? ORDER BY seq', (call_id,)).fetchall()
                result = dict(call)
                result['transcript'] = [dict(row) for row in transcript]
                return result
            finally:
                connection.close()
        except sqlite3.Error as error:
            raise RuntimeError('無法讀取本機通話逐字稿。') from error

    def models(self):
        models = []
        cursor = None
        seen = set()
        for _ in range(10):
            params = {'limit': 100, 'includeHidden': False}
            if cursor:
                params['cursor'] = cursor
            page = self.connect().request('model/list', params)
            for entry in page.get('data', []):
                model = entry.get('model')
                if isinstance(model, str) and model and not entry.get('hidden') and model not in seen:
                    seen.add(model)
                    models.append({'id': model, 'name': entry.get('displayName') or model})
            next_cursor = page.get('nextCursor')
            if not next_cursor:
                return {'models': models}
            if next_cursor == cursor:
                break
            cursor = next_cursor
        raise RuntimeError('模型目錄未完整載入，請稍後重試。')

    def send(self, identifier, message, model=None):
        identifier = self.identifier(identifier)
        if not isinstance(message, str) or not 0 < len(message.strip()) <= 12000:
            raise ValueError('請輸入 1–12000 字的任務。')
        with self.lock:
            engine = self.connect()
            if model is not None and (not isinstance(model, str) or
                    model not in {item['id'] for item in self.models()['models']}):
                raise ValueError('所選模型不在目前 Codex 目錄，請重新載入模型。')
            if identifier not in self.loaded:
                engine.request('thread/resume', {'threadId': identifier,
                    'approvalPolicy': 'on-request', 'sandbox': 'workspace-write', 'excludeTurns': True})
                self.loaded.add(identifier)
            if self.read(identifier)['activeTurn']:
                raise ValueError('任務正在執行，請等待或先停止。')
            self.notices.pop(identifier, None)
            params = {'threadId': identifier,
                'input': [{'type': 'text', 'text': message.strip()}], 'approvalPolicy': 'on-request'}
            if model is not None:
                params['model'] = model
            result = engine.request('turn/start', params)
            self.started_turns[identifier] = result['turn']['id']
            return {'message': '已送交 Codex', 'turnId': result['turn']['id']}

    def stop(self, identifier):
        identifier = self.identifier(identifier)
        with self.lock:
            acknowledged = self.started_turns.get(identifier)
            running = self.running_turns.get(identifier)
            if acknowledged and running != acknowledged:
                # turn/start acknowledgement can precede turn/started. Queue
                # the user's stop for that exact turn, never a later turn.
                self.pending_stops[identifier] = acknowledged
                return {'message': '已排入停止要求，等待回合啟動。'}
        if running:
            turn_id = running
        else:
            turn_id = self.read(identifier)['activeTurn']
        if not turn_id:
            return {'message': '目前沒有執行中的回合'}
        self.connect().interrupt(identifier, turn_id)
        # A successful interrupt acknowledgement is not proof it has ended.
        # Retain active state until the matching turn/completed event arrives.
        return {'message': '已送出停止要求'}

    def pending_approvals(self, identifier):
        with self.lock:
            return [{'id': key, 'details': value['details']} for key, value in self.approvals.items()
                    if value['thread'] == identifier and not value['engine']._closed]

    def answer_approval(self, identifier, approval_id, decision):
        identifier = self.identifier(identifier)
        if decision not in ('accept', 'decline', 'cancel'):
            raise ValueError('無效的批准選項。')
        with self.lock:
            entry = self.approvals.get(approval_id)
            if not entry or entry['thread'] != identifier or entry['engine']._closed:
                raise ValueError('此批准已失效，請重新整理。')
            if time.monotonic() - entry['created'] > 600:
                entry['engine'].answer_command_approval(entry['request'], 'decline')
                self.approvals.pop(approval_id, None)
                raise ValueError('批准已超過十分鐘，已拒絕；請重新提出操作。')
            self.approvals.pop(approval_id)
            entry['engine'].answer_command_approval(entry['request'], decision)
        return {'message': '已送出本次決定'}

    def request_call(self, identifier):
        identifier = self.identifier(identifier)
        self.read(identifier)  # Require a real accessible task before enqueueing.
        notifier = Path.home() / 'Documents' / 'jarvis-mac' / 'notify.py'
        if not notifier.is_file():
            raise ValueError('這台 Mac 尚未安裝小秘書通知程式。')
        with self.lock:
            now = time.monotonic()
            if now - self.calls.get(identifier, -60) < 60:
                raise ValueError('這個任務剛送出通話請求，請勿重複撥號。')
            self.calls[identifier] = now
        try:
            subprocess.run([sys.executable, str(notifier), '--thread', identifier,
                '--question', '你從 MacLink 要求通話，請問這個任務現在要交辦什麼？'],
                check=True, timeout=10, capture_output=True)
        except (subprocess.SubprocessError, OSError) as error:
            raise RuntimeError('來電請求未確認成功，請先查看小秘書狀態再重試。') from error
        return {'message': '已送出小秘書來電請求，尚未確認撥出；請留意 FaceTime。'}
