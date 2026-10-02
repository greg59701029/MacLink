"""Read-only diagnostics regression checks; no real network or Mac permissions."""

import contextlib
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

import diagnostics


class Response:
    def __init__(self, body, content_type="application/json"):
        self.body = body
        self.headers = MagicMock()
        self.headers.get_content_type.return_value = content_type

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, maximum):
        return self.body[:maximum]


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        directory = self.stack.enter_context(tempfile.TemporaryDirectory())
        support = pathlib.Path(directory)
        (support / "server-cert.pem").write_text("test certificate")
        (support / "access-token").write_text("TEST-SECRET-NEVER-PRINT")
        self.stack.enter_context(patch.object(diagnostics, "APP_SUPPORT", support))
        self.stack.enter_context(patch.object(diagnostics, "JARVIS_RUNTIME", support / "absent"))
        self.address = self.stack.enter_context(patch.object(diagnostics, "tailscale_address", return_value="100.64.0.1"))
        self.stack.enter_context(patch.object(diagnostics.subprocess, "run", return_value=MagicMock(returncode=0, stdout="state = running\n")))
        self.stack.enter_context(patch.object(diagnostics.ssl, "create_default_context", return_value=MagicMock()))
        self.opener = MagicMock()
        self.build_opener = self.stack.enter_context(patch.object(diagnostics.urllib.request, "build_opener", return_value=self.opener))
        self.opener.open.return_value = Response(json.dumps({"platform": "macOS", "input_accessibility": True}).encode())

    def test_default_does_not_capture_screen_or_claim_external_success(self):
        checks = diagnostics.collect_checks()
        self.assertEqual(self.opener.open.call_count, 1)
        by_name = {check["name"]: check for check in checks}
        self.assertEqual(by_name["桌面畫面"]["state"], "unchecked")
        self.assertEqual(by_name["外出連線"]["state"], "unchecked")
        self.assertEqual(by_name["安全連線"]["state"], "ok")
        self.assertNotIn("TEST-SECRET", json.dumps(checks))

    def test_unsupported_python_reports_environment_before_network(self):
        with patch.object(diagnostics.sys, "version_info", (3, 9, 6)):
            checks = diagnostics.collect_checks(check_screen=True)
        self.assertEqual(checks[0]["name"], "Python 環境")
        self.assertEqual(checks[0]["state"], "error")
        self.assertIn("尚未檢查", checks[0]["detail"])
        self.address.assert_not_called()
        self.build_opener.assert_not_called()

    def test_missing_tailnet_skips_all_network_requests(self):
        self.address.return_value = None
        checks = diagnostics.collect_checks(check_screen=True)
        self.build_opener.assert_not_called()
        self.assertTrue(any(item["state"] == "error" for item in checks))

    def test_screen_jpeg_and_disabled_control(self):
        self.opener.open.side_effect = [Response(b'{"platform":"macOS","input_accessibility":false}'),
                                       Response(b"\xff\xd8test\xff\xd9", "image/jpeg")]
        by_name = {item["name"]: item for item in diagnostics.collect_checks(check_screen=True)}
        self.assertEqual(by_name["桌面畫面"]["state"], "ok")
        self.assertEqual(by_name["桌面控制權限"]["state"], "error")

    def test_screen_failure_is_not_misreported_as_tls_failure(self):
        self.opener.open.side_effect = [Response(b'{"platform":"macOS","input_accessibility":true}'),
                                       urllib.error.HTTPError("https://private", 500, "TEST-SECRET", {}, None)]
        checks = diagnostics.collect_checks(check_screen=True)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(by_name["安全連線"]["state"], "ok")
        self.assertEqual(by_name["桌面畫面"]["state"], "error")
        self.assertNotIn("TEST-SECRET", json.dumps(checks))

    def test_invalid_response_and_network_error_are_redacted(self):
        for value in [Response(b'[]'), Response(b'not-json'), urllib.error.URLError("TEST-SECRET")]:
            self.opener.open.side_effect = [value]
            checks = diagnostics.collect_checks()
            self.assertTrue(any(item["state"] == "error" for item in checks))
            self.assertNotIn("TEST-SECRET", json.dumps(checks))

    def test_redirect_cannot_forward_authorization(self):
        self.assertIsNone(diagnostics.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example"))

    def test_json_cli_failure_exit_status(self):
        self.address.return_value = None
        output = io.StringIO()
        with patch("sys.argv", ["diagnostics.py", "--json"]), contextlib.redirect_stdout(output):
            result = diagnostics.main()
        self.assertEqual(result, 1)
        self.assertIsInstance(json.loads(output.getvalue())["checks"], list)


if __name__ == "__main__":
    unittest.main()
