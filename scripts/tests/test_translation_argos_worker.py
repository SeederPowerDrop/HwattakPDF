# SPDX-License-Identifier: MPL-2.0
"""Standard-library tests; no Argos install, model download or PDF data needed."""
import http.client
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
import zipfile

WORKER_PATH = Path(__file__).resolve().parents[1] / "translation_argos_worker.py"
SPEC = importlib.util.spec_from_file_location("translation_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


def request(action="installed", **kwargs):
    return dict(requestID=str(uuid.uuid4()), action=action, **kwargs)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "model.argosmodel"

    def tearDown(self):
        self.temporary.cleanup()

    def make_archive(self, extra=None):
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("translate-en_ko/metadata.json", json.dumps({"from_code": "en", "to_code": "ko", "package_version": "1.9"}))
            if extra:
                archive.writestr(*extra)

    def test_valid_archive_metadata(self):
        self.make_archive(("translate-en_ko/model/model.bin", b"model"))
        root, metadata = worker.validate_archive(self.path)
        self.assertEqual(root, "translate-en_ko")
        self.assertEqual(metadata["to_code"], "ko")

    def test_rejects_traversal_and_absolute_members(self):
        for name in ("../outside", "translate-en_ko/../../outside", "/tmp/outside", "translate-en_ko/./outside", "translate-en_ko\\outside", "translate-en_ko//model.bin", "translate-en_ko/model//"):
            self.make_archive((name, "bad"))
            with self.assertRaises(worker.WorkerError) as raised:
                worker.validate_archive(self.path)
            self.assertEqual(raised.exception.code, "invalidArchive")

    def test_rejects_symlink(self):
        entry = zipfile.ZipInfo("translate-en_ko/model/link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.make_archive((entry, "/tmp/elsewhere"))
        with self.assertRaises(worker.WorkerError):
            worker.validate_archive(self.path)

    def test_rejects_multiple_package_roots(self):
        self.make_archive(("another/model.bin", "bad"))
        with self.assertRaises(worker.WorkerError):
            worker.validate_archive(self.path)


class BoundaryTests(unittest.TestCase):
    def test_text_cap_counts_scalars_including_combining_marks(self):
        value = request("translate", texts=["a" + "\u0301" * 16000], sourceLanguage="en", targetLanguage="ko")
        with self.assertRaises(worker.WorkerError) as raised:
            worker.validate_request(value)
        self.assertEqual(raised.exception.code, "inputTooLarge")

    def test_install_rejects_plugin_supplied_download_url(self):
        with self.assertRaises(worker.WorkerError):
            worker.validate_request(request("install", packID="en_ko@1", url="https://evil.example/model"))

    def test_download_redirect_policy_rejects_local_http_and_other_hosts(self):
        for url in ("http://argos-net.com/model", "https://127.0.0.1/model", "https://evil.example/model", "https://user@argos-net.com/model", "https://argos-net.com:444/model"):
            with self.assertRaises(worker.WorkerError):
                worker.validate_download_url(url, worker.DOWNLOAD_HOSTS)
        worker.validate_download_url("https://argos-net.com/v1/model.argosmodel", worker.DOWNLOAD_HOSTS)

    def test_offline_worker_blocks_network_before_socket_connect(self):
        code = """
import importlib.util, socket
spec = importlib.util.spec_from_file_location('worker', WORKER_PATH)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
worker.block_network()
try:
    socket.create_connection(('127.0.0.1', 9), timeout=0.1)
except worker.WorkerError as error:
    assert error.code == 'offlineResourcesMissing'
else:
    raise AssertionError('network was not blocked')
""".replace("WORKER_PATH", repr(str(WORKER_PATH)))
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_offline_translation_with_stub_runtime_preserves_paragraph_order(self):
        code = """
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location('worker', WORKER_PATH)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
class Language:
    def __init__(self, code): self.code = code
    def get_translation(self, target): return types.SimpleNamespace(translate=lambda text: 'translated:' + text)
module = types.ModuleType('argostranslate')
module.package = types.SimpleNamespace()
module.settings = types.SimpleNamespace()
module.translate = types.SimpleNamespace(get_installed_languages=lambda: [Language('en'), Language('ko')])
sys.modules['argostranslate'] = module
response = worker.execute_request({'requestID':'10000000-0000-0000-0000-000000000001','action':'translate','texts':['First','Second'],'sourceLanguage':'en','targetLanguage':'ko'})
assert response == {'ok': True, 'translations': ['translated:First', 'translated:Second']}
assert __import__('os').environ['ARGOS_MODEL_PROVIDER'] == 'OPENNMT'
""".replace("WORKER_PATH", repr(str(WORKER_PATH)))
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())


class StubController:
    def __init__(self):
        self.requests = []
        self.cancelled = []
    def run(self, value):
        self.requests.append(value)
        return {"ok": True, "packs": []}
    def cancel(self, request_id):
        self.cancelled.append(request_id)


class HTTPBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.controller = StubController()
        self.server = worker.TranslationServer(port=0, controller=self.controller)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def post(self, body=None, headers=None, path="/v1/translation"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        all_headers = {"Content-Type": "application/json"}
        all_headers.update(headers or {})
        connection.request("POST", path, body=json.dumps(body or request()), headers=all_headers)
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def test_native_loopback_request_works(self):
        self.assertEqual(self.post(), (200, {"ok": True, "packs": []}))
        self.assertEqual(len(self.controller.requests), 1)

    def test_rejects_browser_origin_and_fetch_metadata(self):
        for headers in ({"Origin": "https://example.com"}, {"Origin": "null"}, {"Sec-Fetch-Site": "same-origin"}):
            self.assertEqual(self.post(headers=headers)[0], 403)
        self.assertFalse(self.controller.requests)

    def test_rejects_rebinding_and_foreign_host(self):
        for host in ("evil.example", "localhost:" + str(self.server.server_port), "127.0.0.1:1"):
            self.assertEqual(self.post(headers={"Host": host})[0], 403)
        self.assertFalse(self.controller.requests)

    def test_rejects_simple_browser_content_type(self):
        self.assertEqual(self.post(headers={"Content-Type": "text/plain"})[0], 403)

    def test_rejects_oversized_request_before_dispatch(self):
        self.assertEqual(self.post(headers={"Content-Length": str(worker.MAX_REQUEST_BYTES + 1)})[0], 413)
        self.assertFalse(self.controller.requests)

    def test_cancel_is_separate_no_source_operation(self):
        request_id = str(uuid.uuid4())
        self.assertEqual(self.post(body={"requestID": request_id}, path="/v1/cancel"), (200, {"ok": True}))
        self.assertEqual(self.controller.cancelled, [request_id])


if __name__ == "__main__":
    unittest.main()
