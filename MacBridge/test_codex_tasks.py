import os
import sqlite3
import http.client
import http.server
import json
import pathlib
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from codex_tasks import CodexTasks, resolve_codex_cli
import server


class ResolveCodexCliTests(unittest.TestCase):
    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nexit 0\n', encoding='utf-8')
        path.chmod(0o700)
        return path

    def test_finds_current_nested_chatgpt_codex_cli_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.executable(root / 'ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex')
            with patch.dict(os.environ, {}, clear=True), patch('codex_tasks.shutil.which', return_value=None):
                self.assertEqual(resolve_codex_cli([root]), str(binary.resolve()))

    def test_finds_codex_cli_in_user_applications(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.executable(root / 'Codex.app/Contents/Resources/codex')
            with patch.dict(os.environ, {}, clear=True), patch('codex_tasks.shutil.which', return_value=None):
                self.assertEqual(resolve_codex_cli([root]), str(binary.resolve()))

    def test_explicit_executable_override_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = self.executable(Path(directory) / 'custom/codex')
            with patch.dict(os.environ, {'MACLINK_CODEX_CLI_PATH': str(binary)}), patch('codex_tasks.shutil.which', return_value=None):
                self.assertEqual(resolve_codex_cli([]), str(binary.resolve()))

    def test_missing_binary_has_actionable_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {}, clear=True), patch('codex_tasks.shutil.which', return_value=None):
                with self.assertRaisesRegex(RuntimeError, '找不到 Codex 桌面 App'):
                    resolve_codex_cli([Path(directory)])


class CodexCallHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / 'state.db'
        self.thread = 'b3245235-61aa-4df8-bc2e-716cebbdc127'
        with sqlite3.connect(self.db) as connection:
            connection.executescript('''
                CREATE TABLE call_records (
                    id TEXT PRIMARY KEY, event_id TEXT, thread TEXT NOT NULL,
                    created REAL NOT NULL, status TEXT NOT NULL, dial_status TEXT,
                    requested_at REAL, connected_at REAL, ended_at REAL, detail TEXT NOT NULL DEFAULT '');
                CREATE TABLE call_transcripts (
                    call_id TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL,
                    content TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY(call_id, seq));
            ''')
            connection.execute('INSERT INTO call_records(id,thread,created,status,connected_at) VALUES(?,?,?,?,?)',
                               ('a' * 32, self.thread, 123.0, 'connected', 124.0))
            connection.execute('INSERT INTO call_records(id,thread,created,status) VALUES(?,?,?,?)',
                               ('b' * 32, '7f552a8f-fb5d-480e-ace0-e98b76fc2e1d', 125.0, 'ended'))
            connection.execute('INSERT INTO call_transcripts VALUES(?,?,?,?,?)',
                               ('a' * 32, 1, 'assistant', '請問有聽到嗎？', 124.0))

    def tearDown(self):
        self.temp.cleanup()

    def test_history_and_transcript_are_scoped_to_thread(self):
        result = CodexTasks.call_history(self.thread, self.db)
        self.assertEqual([item['id'] for item in result['calls']], ['a' * 32])
        self.assertEqual(result['calls'][0]['transcriptTurns'], 1)
        transcript = CodexTasks.call_transcript('a' * 32, self.thread, self.db)
        self.assertEqual(transcript['transcript'][0]['content'], '請問有聽到嗎？')
        with self.assertRaisesRegex(ValueError, '找不到這通電話'):
            CodexTasks.call_transcript('b' * 32, self.thread, self.db)

    def test_http_call_endpoints_require_pairing_authentication(self):
        with patch.object(server, 'CODEX_TASKS') as codex:
            codex.call_history.return_value = {'calls': []}
            codex.call_transcript.return_value = {'id': 'a' * 32, 'transcript': []}
            temporary = tempfile.TemporaryDirectory()
            self.addCleanup(temporary.cleanup)
            root = pathlib.Path(temporary.name)
            state = server.CompanionState('fixture-token', '123456', time.time() + 60,
                clients_path=root / 'paired-clients.json', token_path=root / 'access-token')
            httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), server.make_handler(state, 'test'))
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(httpd.server_close)
            self.addCleanup(httpd.shutdown)

            def get(path, token=None):
                connection = http.client.HTTPConnection('127.0.0.1', httpd.server_port, timeout=3)
                try:
                    headers = {'Authorization': f'Bearer {token}'} if token else {}
                    connection.request('GET', path, headers=headers)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()

            status, _ = get('/api/codex/calls?thread=' + self.thread)
            self.assertEqual(status, 401)
            status, body = get('/api/codex/calls?thread=' + self.thread, 'fixture-token')
            self.assertEqual(status, 200)
            self.assertEqual(body, {'calls': []})
            status, _ = get('/api/codex/call?id=' + 'a' * 32 + '&thread=' + self.thread, 'fixture-token')
            self.assertEqual(status, 200)
            codex.call_transcript.assert_called_once_with('a' * 32, self.thread)


if __name__ == '__main__':
    unittest.main()
