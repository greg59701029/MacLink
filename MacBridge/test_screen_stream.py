import io
import pathlib
import sys
import tempfile
import time
import unittest
from screen_stream import ScreenStream


class ScreenStreamTests(unittest.TestCase):
    def helper(self, body, **options):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = pathlib.Path(directory.name) / 'fixture'
        path.write_text('#!' + sys.executable + '\nimport sys,time\n' + body)
        path.chmod(0o700)
        stream = ScreenStream(lambda: path, **options)
        self.addCleanup(stream.close)
        return stream

    def test_partial_reads_and_eof(self):
        class Pipe:
            def __init__(self): self.data = io.BytesIO(b'12345')
            def read(self, size): return self.data.read(min(2, size))
        pipe = Pipe()
        self.assertEqual(ScreenStream._exact(pipe, 5), b'12345')
        with self.assertRaises(EOFError): ScreenStream._exact(pipe, 1)

    def test_oversized_header_rejected(self):
        stream = self.helper("sys.stdout.buffer.write(bytes([1])+(13*1024*1024).to_bytes(4,'big'));sys.stdout.flush();time.sleep(3)\n")
        with self.assertRaises(RuntimeError): stream.capture()
        self.assertIsNone(stream.frame)

    def test_frame_idle_shutdown_and_restart(self):
        stream = self.helper("sys.stdout.buffer.write(bytes([1])+bytes([0,0,0,4])+b'\\xff\\xd8\\xff\\xd9');sys.stdout.flush();time.sleep(5)\n",idle_seconds=1.5)
        self.assertEqual(stream.capture(), b'\xff\xd8\xff\xd9')
        process = stream.process
        deadline = time.monotonic()+4
        while process.poll() is None and time.monotonic()<deadline: time.sleep(.02)
        self.assertIsNotNone(process.poll())
        self.assertIsNone(stream.frame)
        self.assertEqual(stream.capture(), b'\xff\xd8\xff\xd9')
        self.assertIsNot(stream.process, process)

    def test_invalidated_frame_is_not_reused(self):
        stream = self.helper("sys.stdout.buffer.write(bytes([1])+bytes([0,0,0,4])+b'\\xff\\xd8\\xff\\xd9');sys.stdout.flush();time.sleep(.15);sys.stdout.buffer.write(bytes([3,0,0,0,0]));sys.stdout.flush();time.sleep(.15)\n")
        self.assertEqual(stream.capture(), b'\xff\xd8\xff\xd9')
        time.sleep(.2)
        with self.assertRaises(RuntimeError): stream.capture()
        self.assertIsNone(stream.frame)

if __name__ == '__main__': unittest.main()
