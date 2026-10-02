import unittest
from unittest.mock import Mock, patch
from codex_tasks import CodexTasks
from agent_transport import EngineRequestError

class ModelSelectionTests(unittest.TestCase):
    def test_catalog_paginates_deduplicates_and_filters_hidden(self):
        tasks = CodexTasks()
        engine = Mock()
        engine.request.side_effect = [
            {'data': [{'model': 'fixture-a', 'displayName': 'A'}, {'model': 'hidden', 'hidden': True}], 'nextCursor': 'page2'},
            {'data': [{'model': 'fixture-a'}, {'model': 'fixture-b'}], 'nextCursor': None}]
        with patch.object(tasks, 'connect', return_value=engine):
            self.assertEqual(tasks.models(), {'models': [{'id': 'fixture-a', 'name': 'A'}, {'id': 'fixture-b', 'name': 'fixture-b'}]})
        self.assertEqual(engine.request.call_args.args[1]['cursor'], 'page2')

    def test_unlisted_model_never_starts_or_resumes_task(self):
        tasks = CodexTasks()
        engine = Mock()
        with patch.object(tasks, 'connect', return_value=engine), patch.object(tasks, 'models', return_value={'models': []}):
            with self.assertRaises(ValueError):
                tasks.send('11111111-1111-4111-8111-111111111111', 'fixture', 'unlisted')
        engine.request.assert_not_called()

    def test_selected_model_is_only_applied_to_requested_turn(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        tasks.loaded.add(identifier)
        engine = Mock()
        engine.request.return_value = {'turn': {'id': 'fixture-turn'}}
        with patch.object(tasks, 'connect', return_value=engine), patch.object(tasks, 'models', return_value={'models': [{'id': 'fixture-a'}]}), patch.object(tasks, 'read', return_value={'activeTurn': None}):
            self.assertEqual(tasks.send(identifier, 'fixture', 'fixture-a')['turnId'], 'fixture-turn')
        method, params = engine.request.call_args.args
        self.assertEqual(method, 'turn/start')
        self.assertEqual(params['model'], 'fixture-a')
        self.assertEqual(params['approvalPolicy'], 'on-request')

    def test_incomplete_catalog_fails_closed(self):
        tasks = CodexTasks()
        engine = Mock()
        engine.request.return_value = {'data': [], 'nextCursor': 'repeat'}
        with patch.object(tasks, 'connect', return_value=engine), self.assertRaises(RuntimeError):
            tasks.models()

    def test_early_stop_waits_for_started_event_and_uses_exact_id(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        tasks.started_turns[identifier] = 'just-started'
        engine = Mock()
        tasks.engine = engine
        with patch.object(tasks, 'read') as read:
            self.assertEqual(tasks.stop(identifier)['message'], '已排入停止要求，等待回合啟動。')
            read.assert_not_called()
        engine.interrupt.assert_not_called()
        event = {'method': 'turn/started', 'params': {'threadId': identifier, 'turn': {'id': 'just-started'}}}
        tasks.observe_turn_event(engine, event)
        tasks.observe_turn_event(engine, event)
        engine.interrupt.assert_called_once_with(identifier, 'just-started')
        self.assertEqual(tasks.started_turns[identifier], 'just-started')
        self.assertNotIn(identifier, tasks.pending_stops)

    def test_premature_terminal_history_cannot_end_live_turn(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        tasks.started_turns[identifier] = 'fresh'
        engine = Mock()
        tasks.engine = engine
        engine.request.return_value = {'data': [{'id': 'fresh', 'status': 'interrupted', 'items': []}]}
        with patch.object(tasks, 'connect', return_value=engine):
            self.assertEqual(tasks.read(identifier)['latestTurnStatus'], 'inProgress')
            tasks.observe_turn_event(engine, {'method': 'turn/completed', 'params': {'threadId': identifier, 'turn': {'id': 'fresh', 'status': 'interrupted'}}})
            self.assertEqual(tasks.read(identifier)['latestTurnStatus'], 'interrupted')
            self.assertEqual(tasks.stop(identifier)['message'], '目前沒有執行中的回合')
        engine.interrupt.assert_not_called()

    def test_old_completion_cannot_clear_newer_turn_or_queued_stop(self):
        tasks = CodexTasks()
        engine = Mock(); tasks.engine = engine
        tasks.started_turns['thread'] = 'new'
        tasks.pending_stops['thread'] = 'new'
        tasks.observe_turn_event(engine, {'method': 'turn/completed', 'params': {'threadId': 'thread', 'turn': {'id': 'old', 'status': 'completed'}}})
        self.assertEqual(tasks.started_turns['thread'], 'new')
        self.assertEqual(tasks.pending_stops['thread'], 'new')

    def test_interrupt_ack_is_not_treated_as_completion(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        engine = Mock(); tasks.engine = engine
        tasks.started_turns[identifier] = 'running'
        tasks.running_turns[identifier] = 'running'
        with patch.object(tasks, 'connect', return_value=engine):
            self.assertEqual(tasks.stop(identifier)['message'], '已送出停止要求')
        self.assertEqual(tasks.started_turns[identifier], 'running')

    def test_new_thread_unsupported_history_keeps_pending_state(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        tasks.started_turns[identifier] = 'pending'
        engine = Mock(); engine.request.side_effect = EngineRequestError(-32601)
        with patch.object(tasks, 'connect', return_value=engine):
            result = tasks.read(identifier)
        self.assertEqual(result['activeTurn'], 'pending')
        self.assertEqual(result['latestTurnStatus'], 'inProgress')

    def test_other_history_error_is_not_hidden(self):
        tasks = CodexTasks()
        identifier = '11111111-1111-4111-8111-111111111111'
        tasks.started_turns[identifier] = 'pending'
        engine = Mock(); engine.request.side_effect = EngineRequestError(-32000)
        with patch.object(tasks, 'connect', return_value=engine), self.assertRaises(EngineRequestError):
            tasks.read(identifier)

    def test_failed_queued_stop_does_not_retry_or_claim_completion(self):
        tasks = CodexTasks()
        engine = Mock(); engine.interrupt.side_effect = TimeoutError('synthetic timeout'); tasks.engine = engine
        tasks.started_turns['thread'] = 'turn'; tasks.pending_stops['thread'] = 'turn'
        tasks.observe_turn_event(engine, {'method': 'turn/started', 'params': {'threadId': 'thread', 'turn': {'id': 'turn'}}})
        self.assertIn('停止要求未確認', tasks.notices['thread'])
        self.assertEqual(tasks.started_turns['thread'], 'turn')
        self.assertEqual(engine.interrupt.call_count, 1)
