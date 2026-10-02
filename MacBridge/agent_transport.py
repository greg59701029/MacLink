"""Private stdio transport for a task engine; never exposes its control port.

This module is opt-in and is not started by the companion. Unanswered engine
requests remain pending; they are never interpreted as permission to proceed.
"""
import json
import queue
import subprocess
import threading


class EngineRequestError(RuntimeError):
    """Typed protocol error; default user-facing text never includes engine data."""
    def __init__(self, code):
        super().__init__('Task engine rejected request.')
        self.code = code


class AgentTransport:
    # Local engine response capacity, not a network bandwidth limit. Keep
    # history paginated so ordinary mobile reads remain small.
    MAX_RESPONSE_BYTES = 128 * 1024 * 1024
    MAX_REQUEST_BYTES = 1024 * 1024

    def __init__(self, command, max_events=256):
        self.command = list(command)
        self.events = queue.Queue(maxsize=max_events)
        self._lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._pending = {}
        self._approvals = {}
        self._sequence = 0
        self._process = None
        self._closed = False

    def start(self):
        with self._lock:
            if self._process is not None or self._closed:
                raise RuntimeError('Task engine transport cannot be restarted.')
            self._process = subprocess.Popen(
                self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=64 * 1024)
        threading.Thread(target=self._read, daemon=True).start()
        result = self.request('initialize', {
            'clientInfo': {'name': 'maclink', 'title': 'MacLink', 'version': '0.2.0'}})
        self._send({'method': 'initialized', 'params': {}})
        return result

    def _send(self, value):
        raw = json.dumps(value, ensure_ascii=False).encode() + b'\n'
        if len(raw) > self.MAX_REQUEST_BYTES:
            raise ValueError('Task message too large.')
        with self._write_lock:
            if self._closed or self._process is None:
                raise RuntimeError('Task engine disconnected.')
            self._process.stdin.write(raw)
            self._process.stdin.flush()

    def request(self, method, params, timeout=30):
        waiter = queue.Queue(maxsize=1)
        with self._lock:
            if self._closed:
                raise RuntimeError('Task engine disconnected.')
            self._sequence += 1
            rid = self._sequence
            self._pending[rid] = waiter
        try:
            self._send({'id': rid, 'method': method, 'params': params})
            try:
                response = waiter.get(timeout=timeout)
            except queue.Empty as exc:
                # An uncertain mutation is not automatically retried.
                raise TimeoutError('Task engine response timed out; outcome unknown.') from exc
            if 'error' in response:
                raise EngineRequestError(response['error'].get('code'))
            return response.get('result')
        finally:
            with self._lock:
                self._pending.pop(rid, None)

    def _read(self):
        try:
            while not self._closed:
                line = self._process.stdout.readline(self.MAX_RESPONSE_BYTES + 1)
                if not line:
                    break
                if len(line) > self.MAX_RESPONSE_BYTES:
                    raise ValueError('Oversized engine event.')
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError('Invalid engine event.')
                with self._lock:
                    if 'method' in value:
                        if 'id' in value:
                            if len(self._approvals) >= 32:
                                raise ValueError('Too many pending engine requests.')
                            self._approvals[value['id']] = value['method']
                        self.events.put_nowait(value)
                    elif value.get('id') in self._pending:
                        self._pending[value['id']].put_nowait(value)
        except (OSError, ValueError, queue.Full, TypeError):
            pass
        finally:
            self.close()

    def reject_request(self, request_id):
        """Unsupported requests fail closed; no generic approval shortcut."""
        with self._lock:
            if request_id not in self._approvals:
                raise ValueError('Unknown or already handled engine request.')
            self._approvals.pop(request_id)
        self._send({'id': request_id, 'error': {
            'code': -32601, 'message': 'This client does not support this request.'}})

    def answer_command_approval(self, request_id, decision):
        if decision not in ('accept', 'decline', 'cancel'):
            raise ValueError('Unsupported approval decision.')
        with self._lock:
            if self._approvals.get(request_id) != 'item/commandExecution/requestApproval':
                raise ValueError('Approval expired or already answered.')
            self._approvals.pop(request_id)
        self._send({'id': request_id, 'result': {'decision': decision}})

    def interrupt(self, thread_id, turn_id):
        return self.request('turn/interrupt', {'threadId': thread_id, 'turnId': turn_id})

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
            process = self._process
            self._approvals.clear()
            for waiter in self._pending.values():
                try:
                    waiter.put_nowait({'error': {'message': 'Disconnected'}})
                except queue.Full:
                    pass
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            for pipe in (process.stdin, process.stdout):
                try:
                    pipe.close()
                except OSError:
                    pass
