import json
import os
import sys
import threading
import unittest
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import app  # noqa: E402


class HealthTest(unittest.TestCase):
    def test_health_body(self):
        self.assertEqual(app.health()["status"], "ok")

    def test_healthz_endpoint(self):
        server = app.serve(0)
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{port}/healthz"
            with urllib.request.urlopen(url, timeout=5) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(json.load(resp)["status"], "ok")
        finally:
            server.shutdown()
            server.server_close()

    def test_forced_failure_switch(self):
        # STEP 16 '테스트 실패' 시나리오: Jenkins 파라미터 FORCE_TEST_FAIL=true
        if os.environ.get("FORCE_TEST_FAIL") == "true":
            self.fail("FORCE_TEST_FAIL=true (의도한 실패)")


if __name__ == "__main__":
    unittest.main()
