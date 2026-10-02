import http.client
import http.server
import json
import pathlib
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import server
from assistant_actions import parse_action

class AssistantActionsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        self.state = server.CompanionState('fixture-token', '123456', time.time()+60,
            clients_path=root / 'paired-clients.json', token_path=root / 'access-token')
        with patch('socket.getfqdn', return_value='localhost'):
            self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1',0),server.make_handler(self.state,'test'))
        self.httpd.fingerprint = 'A'*64
        self.thread = threading.Thread(target=self.httpd.serve_forever,daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self,path,body,token='fixture-token'):
        conn=http.client.HTTPConnection('127.0.0.1',self.httpd.server_port,timeout=3)
        try:
            conn.request('POST',path,json.dumps(body),{'Authorization':'Bearer '+token,'Content-Type':'application/json'})
            r=conn.getresponse()
            return r.status,json.loads(r.read())
        finally: conn.close()

    def test_confirmation_required_and_single_use(self):
        with patch.object(server,'perform_input',return_value='fixture action') as execute:
            status,proposal=self.post('/api/assistant',{'message':'輸入：你好'})
            self.assertEqual(status,200)
            execute.assert_not_called()
            status,_=self.post('/api/assistant/confirm',{'action_id':proposal['action_id']})
            self.assertEqual(status,200)
            execute.assert_called_once_with({'action':'type','text':'你好'})
            status,_=self.post('/api/assistant/confirm',{'action_id':proposal['action_id']})
            self.assertEqual(status,410)
            self.assertEqual(execute.call_count,1)

    def test_expired_and_unauthenticated_confirmation_never_execute(self):
        _,proposal=self.post('/api/assistant',{'message':'向下捲動'})
        key=proposal['action_id']
        with patch.object(server,'perform_input') as execute:
            status,_=self.post('/api/assistant/confirm',{'action_id':key},token='wrong')
            self.assertEqual(status,401)
            action,_=self.state.pending_actions[key]
            self.state.pending_actions[key]=(action,time.time()-1)
            status,_=self.post('/api/assistant/confirm',{'action_id':key})
            self.assertEqual(status,410)
            execute.assert_not_called()

    def test_revoke_invalidates_pending_actions(self):
        self.post('/api/assistant',{'message':'開啟記事本'})
        with tempfile.TemporaryDirectory() as folder, patch.object(server,'APP_SUPPORT',pathlib.Path(folder)), patch.object(server,'write_pairing_info'):
            status,_=self.post('/api/revoke',{})
        self.assertEqual(status,200)
        self.assertFalse(self.state.pending_actions)

    def test_open_uses_fixed_app_name_and_no_shell(self):
        with patch.object(server.subprocess,'run') as execute:
            _,proposal=self.post('/api/assistant',{'message':'幫我開啟記事本'})
            execute.assert_not_called()
            status,_=self.post('/api/assistant/confirm',{'action_id':proposal['action_id']})
            self.assertEqual(status,200)
            execute.assert_called_once_with(['/usr/bin/open','-a','TextEdit'],check=True,timeout=10,capture_output=True)

    def test_unknown_commands_are_not_executable(self):
        for text in ['開啟Safari 然後付款','open Safari; rm -rf /','執行 shell','刪除所有檔案','輸入：'+ 'x'*1201]:
            self.assertIsNone(parse_action(text,server.ALLOWED_APPS))

if __name__ == '__main__': unittest.main()
