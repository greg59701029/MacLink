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


class PerDevicePairingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = pathlib.Path(self.temporary.name)
        self.clients_path = root / "paired-clients.json"
        self.token_path = root / "access-token"
        self.admin_token = "local-admin-fixture"

    def new_state(self):
        return server.CompanionState(
            self.admin_token, "123456", time.time() + 600,
            clients_path=self.clients_path, token_path=self.token_path,
        )

    def test_each_pairing_gets_individual_persistent_token_and_revoke_is_scoped(self):
        state = self.new_state()
        first_code = state.pair_code
        first_token, first_id = state.issue_pairing(first_code)
        second_code = state.pair_code
        self.assertNotEqual(first_code, second_code)
        second_token, second_id = state.issue_pairing(second_code)
        self.assertNotEqual(first_token, second_token)
        self.assertNotEqual(first_id, second_id)

        restarted = self.new_state()
        self.assertIsNotNone(restarted.authenticate(first_token))
        self.assertIsNotNone(restarted.authenticate(second_token))
        legacy, admin = restarted.revoke(first_token)
        self.assertFalse(legacy)
        self.assertFalse(admin)
        self.assertIsNone(restarted.authenticate(first_token))
        self.assertIsNotNone(restarted.authenticate(second_token))

    def test_http_pair_endpoint_issues_distinct_tokens_and_revoke_keeps_other_phone(self):
        state = self.new_state()
        with patch("socket.getfqdn", return_value="localhost"):
            httpd = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0), server.make_handler(state, "test")
            )
        httpd.fingerprint = "A" * 64
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)

        def post(path, body, token=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            connection = http.client.HTTPConnection(
                "127.0.0.1", httpd.server_port, timeout=3
            )
            try:
                connection.request("POST", path, json.dumps(body), headers)
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        with patch("server.write_pairing_info"):
            first_status, first = post("/api/pair", {"pair_code": state.pair_code})
            second_status, second = post("/api/pair", {"pair_code": state.pair_code})
            self.assertEqual(first_status, 200)
            self.assertEqual(second_status, 200)
            self.assertNotEqual(first["token"], second["token"])
            self.assertNotEqual(first["client_id"], second["client_id"])

            status, _ = post("/api/revoke", {}, first["token"])
            self.assertEqual(status, 200)

            connection = http.client.HTTPConnection(
                "127.0.0.1", httpd.server_port, timeout=3
            )
            try:
                connection.request(
                    "GET", "/api/not-a-route",
                    headers={"Authorization": f"Bearer {second['token']}"},
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 404)
            finally:
                connection.close()

            connection = http.client.HTTPConnection(
                "127.0.0.1", httpd.server_port, timeout=3
            )
            try:
                connection.request(
                    "GET", "/api/not-a-route",
                    headers={"Authorization": f"Bearer {first['token']}"},
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 401)
            finally:
                connection.close()


if __name__ == "__main__":
    unittest.main()
