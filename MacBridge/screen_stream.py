"""Demand-started screen stream. No listener, image files, or access credentials."""
from __future__ import annotations

import atexit
import pathlib
import subprocess
import threading
import time


class ScreenStream:
    def __init__(self, executable, *, idle_seconds=10, freshness_seconds=2):
        self.executable = executable
        self.idle_seconds = idle_seconds
        self.freshness_seconds = freshness_seconds
        self.condition = threading.Condition()
        self.process = None
        self.frame = None
        self.frame_time = 0.0
        self.last_request = 0.0
        atexit.register(self.close)

    def capture(self):
        with self.condition:
            self.last_request = time.monotonic()
            if self.process is None or self.process.poll() is not None:
                self._close_locked()
                self.process = subprocess.Popen([str(self.executable())], stdin=subprocess.DEVNULL,
                                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                process = self.process
                threading.Thread(target=self._read, args=(process,), daemon=True).start()
                threading.Thread(target=self._watch, args=(process,), daemon=True).start()
            deadline = time.monotonic() + 5
            while True:
                if self.frame is not None and time.monotonic() - self.frame_time < self.freshness_seconds:
                    return self.frame
                if self.process is None or self.process.poll() is not None:
                    raise RuntimeError("桌面串流未啟動；請確認 Mac 的螢幕錄製權限。")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._close_locked()
                    raise RuntimeError("桌面串流沒有新畫面，請重新連線。")
                self.condition.wait(min(remaining, .2))

    @staticmethod
    def _exact(pipe, size):
        parts = bytearray()
        while len(parts) < size:
            block = pipe.read(size - len(parts))
            if not block:
                raise EOFError()
            parts.extend(block)
        return bytes(parts)

    def _read(self, process):
        try:
            while True:
                header = self._exact(process.stdout, 5)
                status, size = header[0], int.from_bytes(header[1:], 'big')
                if status not in (1, 2, 3) or size > 12 * 1024 * 1024 or (status != 1 and size):
                    raise ValueError('invalid frame header')
                data = self._exact(process.stdout, size) if size else None
                if status == 1 and (not data or not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9')):
                    raise ValueError('invalid JPEG')
                with self.condition:
                    if self.process is not process:
                        return
                    if status == 1:
                        self.frame = data
                        self.frame_time = time.monotonic()
                    elif status == 2 and self.frame is not None:
                        self.frame_time = time.monotonic()
                    else:
                        self.frame = None
                    self.condition.notify_all()
        except (OSError, EOFError, ValueError):
            pass
        finally:
            with self.condition:
                if self.process is process:
                    self._close_locked()
            process.stdout.close()

    def _watch(self, process):
        while True:
            time.sleep(.5)
            with self.condition:
                if self.process is not process:
                    return
                if process.poll() is not None or time.monotonic() - self.last_request >= self.idle_seconds:
                    self._close_locked()
                    return

    def _close_locked(self):
        process = self.process
        self.process = None
        self.frame = None
        self.frame_time = 0.0
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
            else:
                process.wait()
        self.condition.notify_all()

    def close(self):
        with self.condition:
            self._close_locked()
