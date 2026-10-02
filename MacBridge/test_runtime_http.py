import http.client
import http.server
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
import server
from codex_tasks import CodexTasks

class RuntimeHTTPTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        state = server.CompanionState('synthetic-test-token', '123456', time.time()+60,
            clients_path=root/'clients.json', token_path=root/'token')
        self.tasks = CodexTasks()
        self.engine = Mock()
        self.engine._closed = False
        patcher = patch.object(self.tasks, 'connect', return_value=self.engine)
        patcher.start(); self.addCleanup(patcher.stop)
        patcher = patch.object(server, 'CODEX_TASKS', self.tasks)
        patcher.start(); self.addCleanup(patcher.stop)
        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1',0),server.make_handler(state,'test'))
        threading.Thread(target=self.httpd.serve_forever,daemon=True).start()
        self.addCleanup(self.httpd.server_close); self.addCleanup(self.httpd.shutdown)
        self.identifier = '11111111-1111-4111-8111-111111111111'

    def request(self, path, body=None, authorized=True):
        conn = http.client.HTTPConnection('127.0.0.1',self.httpd.server_port,timeout=3)
        headers = {'Content-Type':'application/json'}
        if authorized: headers['Authorization']='Bearer synthetic-test-token'
        try:
            conn.request('POST' if body is not None else 'GET',path,json.dumps(body) if body is not None else None,headers)
            response=conn.getresponse()
            return response.status,json.loads(response.read())
        finally: conn.close()

    def test_model_route_auth_and_catalog(self):
        self.engine.request.return_value={'data':[{'model':'fixture-model','displayName':'Fixture'}]}
        self.assertEqual(self.request('/api/codex/models',authorized=False)[0],401)
        self.assertEqual(self.request('/api/codex/models'),(200,{'models':[{'id':'fixture-model','name':'Fixture'}]}))

    def test_invalid_model_is_http_400_before_execution(self):
        self.engine.request.return_value={'data':[]}
        status,_=self.request('/api/codex/send',{'id':self.identifier,'message':'synthetic','model':'invalid'})
        self.assertEqual(status,400)
        self.assertTrue(all(call.args[0]=='model/list' for call in self.engine.request.call_args_list))

    def test_status_and_immediate_cancel_through_http(self):
        self.engine.request.return_value={'data':[{'id':'old-turn','status':'completed','items':[]}]}
        self.tasks.started_turns[self.identifier]='fresh-turn'
        status,result=self.request('/api/codex/task?id='+self.identifier)
        self.assertEqual(status,200); self.assertEqual(result['latestTurnStatus'],'inProgress')
        self.assertEqual(result['activeTurn'],'fresh-turn')
        status,result=self.request('/api/codex/stop',{'id':self.identifier})
        self.assertEqual(status,200);self.assertEqual(result['message'],'已排入停止要求，等待回合啟動。')
        self.engine.interrupt.assert_not_called()
        self.tasks.engine=self.engine
        self.tasks.observe_turn_event(self.engine,{'method':'turn/started','params':{'threadId':self.identifier,'turn':{'id':'fresh-turn'}}})
        self.engine.interrupt.assert_called_once_with(self.identifier,'fresh-turn')

    def test_approval_is_scoped_and_single_use(self):
        self.tasks.approvals['fixture-approval']={'thread':self.identifier,'engine':self.engine,
            'created':time.monotonic(),'request':7,'details':'synthetic command','turn':'fixture-turn'}
        wrong='22222222-2222-4222-8222-222222222222'
        self.assertEqual(self.request('/api/codex/approval',{'id':wrong,'approval':'fixture-approval','decision':'accept'})[0],400)
        self.engine.answer_command_approval.assert_not_called()
        self.assertEqual(self.request('/api/codex/approval',{'id':self.identifier,'approval':'fixture-approval','decision':'decline'})[0],200)
        self.engine.answer_command_approval.assert_called_once_with(7,'decline')
        self.assertEqual(self.request('/api/codex/approval',{'id':self.identifier,'approval':'fixture-approval','decision':'accept'})[0],400)
