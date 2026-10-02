import contextlib
import io
import pathlib
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import install_service


class InstallPreflightTests(unittest.TestCase):
    def test_check_mode_never_writes_or_restarts_service(self):
        with patch("sys.argv", ["install_service.py", "--check"]), \
             patch.object(install_service, "preflight", return_value=("/usr/bin/python3", [])), \
             patch.object(install_service.pathlib.Path, "mkdir") as mkdir, \
             patch.object(install_service.subprocess, "run") as run, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(install_service.main(), 0)
            mkdir.assert_not_called()
            run.assert_not_called()

    def test_missing_dependency_stops_before_any_installation(self):
        with patch("sys.argv", ["install_service.py"]), \
             patch.object(install_service, "preflight", return_value=("/usr/bin/python3", ["Tailscale unavailable"])), \
             patch.object(install_service.pathlib.Path, "mkdir") as mkdir, \
             patch.object(install_service.subprocess, "run") as run, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(install_service.main(), 1)
            mkdir.assert_not_called()
            run.assert_not_called()

    def test_preflight_reports_missing_network(self):
        good = MagicMock(returncode=0, stdout="-addext", stderr="")
        with patch.object(install_service.subprocess, "run", return_value=good), \
             patch.object(install_service, "tailscale_address", return_value=None):
            _, issues = install_service.preflight()
        self.assertTrue(any("Tailscale" in issue for issue in issues))

    def test_preflight_reports_unusable_tools(self):
        failure = MagicMock(returncode=1, stdout="", stderr="")
        with patch.object(install_service.subprocess, "run", return_value=failure), \
             patch.object(install_service, "tailscale_address", return_value="100.64.0.1"):
            _, issues = install_service.preflight()
        self.assertTrue(any("Python" in issue for issue in issues))
        self.assertTrue(any("Swift" in issue for issue in issues))

    def test_install_keeps_pairing_helpers_without_running_server(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            bridge = root / "Application Support" / "MacLink" / "Bridge"
            support = bridge.parent
            logs = root / "Logs" / "MacLink"
            plist = root / "LaunchAgents" / "com.adam.maclink.plist"
            with patch("sys.argv", ["install_service.py"]), \
                 patch.object(install_service, "preflight", return_value=("/usr/bin/python3", [])), \
                 patch.object(install_service, "SUPPORT", support), \
                 patch.object(install_service, "BRIDGE", bridge), \
                 patch.object(install_service, "LOGS", logs), \
                 patch.object(install_service, "PLIST", plist), \
                 patch.object(install_service.subprocess, "run", return_value=MagicMock(returncode=0)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(install_service.main(), 0)
            for name in install_service.HELPER_FILES:
                self.assertTrue((bridge / name).is_file(), name)
            self.assertFalse((support / "server-key.pem").exists())
            self.assertFalse((support / "access-token").exists())


if __name__ == "__main__":
    unittest.main()
