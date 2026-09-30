#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""User-launched, loopback-only Argos Translate helper for HwattakPDF.

Run with the Python environment containing argostranslate:
    python3 translation_argos_worker.py --serve
No dependency installation, model download, or HTTP server starts on import.
"""

import argparse
import functools
import http.server
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

MAX_REQUEST_BYTES = 128 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_TEXT_SCALARS = 16000
MAX_PARAGRAPHS = 256
MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
OFFICIAL_INDEX = "https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json"
DOWNLOAD_HOSTS = frozenset(("argos-net.com", "www.argos-net.com"))
LANGUAGE_PATTERN = re.compile(r"[A-Za-z0-9-]{2,24}\Z")
OPERATION_TIMEOUTS = {"translate": 180, "installed": 60, "available": 90, "install": 600, "import": 180}


class WorkerError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def error_response(code):
    # Never echo exception details, paths or PDF text to logs/HTTP clients.
    return {"ok": False, "error": code}


def validate_request(request):
    if not isinstance(request, dict) or request.get("action") not in OPERATION_TIMEOUTS:
        raise WorkerError("invalidInput")
    try:
        uuid.UUID(request.get("requestID", ""))
    except (ValueError, TypeError, AttributeError):
        raise WorkerError("invalidInput")
    action = request["action"]
    permitted = {"requestID", "action"}
    if action == "translate":
        permitted |= {"texts", "sourceLanguage", "targetLanguage"}
        texts = request.get("texts")
        if not isinstance(texts, list) or not 1 <= len(texts) <= MAX_PARAGRAPHS:
            raise WorkerError("invalidInput")
        if any(not isinstance(value, str) for value in texts):
            raise WorkerError("invalidInput")
        if not 1 <= sum(len(value) for value in texts) <= MAX_TEXT_SCALARS:
            raise WorkerError("inputTooLarge")
        for key in ("sourceLanguage", "targetLanguage"):
            if not isinstance(request.get(key), str) or not LANGUAGE_PATTERN.fullmatch(request[key]):
                raise WorkerError("invalidInput")
    elif action == "install":
        permitted.add("packID")
        if not isinstance(request.get("packID"), str) or not 1 <= len(request["packID"]) <= 160:
            raise WorkerError("invalidInput")
    elif action == "import":
        permitted.add("archivePath")
        if not isinstance(request.get("archivePath"), str) or not 1 <= len(request["archivePath"]) <= 4096:
            raise WorkerError("invalidInput")
        path = Path(request["archivePath"])
        if not path.is_absolute() or path.suffix.lower() != ".argosmodel":
            raise WorkerError("invalidInput")
    if set(request) - permitted:
        raise WorkerError("invalidInput")


def block_network():
    """Deny Python socket connections before importing any model/runtime code.

    Runs only inside a disposable worker, never in the listening HTTP server.
    Argos is forced to its local OpenNMT provider, even if the user's settings
    previously selected OpenAI or LibreTranslate.
    """
    def audit(event, _arguments):
        if event in {"socket.connect", "socket.connect_ex", "socket.getaddrinfo", "socket.sendto", "socket.bind"}:
            raise WorkerError("offlineResourcesMissing")
    sys.addaudithook(audit)


def load_argos():
    os.environ.update({
        "ARGOS_MODEL_PROVIDER": "OPENNMT",
        "ARGOS_PACKAGE_INDEX": OFFICIAL_INDEX.rsplit("/", 1)[0] + "/",
        "ARGOS_DEBUG": "0", "ARGOS_DEV_MODE": "0", "ARGOS_DEVICE_TYPE": "cpu",
        "ARGOS_CHUNK_TYPE": "DEFAULT", "ARGOS_INTER_THREADS": "1", "ARGOS_INTRA_THREADS": "2",
    })
    try:
        from argostranslate import package, settings
    except ImportError:
        raise WorkerError("runtimeMissing")
    return package, settings


def pack_record(package):
    source = getattr(package, "from_code", None)
    target = getattr(package, "to_code", None)
    if getattr(package, "type", "translate") != "translate" or not isinstance(source, str) or not isinstance(target, str):
        return None
    if not LANGUAGE_PATTERN.fullmatch(source) or not LANGUAGE_PATTERN.fullmatch(target):
        return None
    version = str(getattr(package, "package_version", ""))
    if len(version.encode("utf-8")) > 64:
        return None
    return {
        "id": source + "_" + target + "@" + version,
        "sourceLanguage": source, "targetLanguage": target,
        "sourceName": str(getattr(package, "from_name", source))[:64],
        "targetName": str(getattr(package, "to_name", target))[:64],
        "version": version,
    }


def pack_records(packages):
    records = {}
    for package in packages:
        record = pack_record(package)
        if record:
            records[record["id"]] = record
    if len(records) > 2048:
        raise WorkerError("invalidResponse")
    return sorted(records.values(), key=lambda value: (value["sourceName"], value["targetName"], value["version"]))


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_hosts):
        self.allowed_hosts = allowed_hosts

    def redirect_request(self, request, response, code, message, headers, new_url):
        validate_download_url(new_url, self.allowed_hosts)
        return super().redirect_request(request, response, code, message, headers, new_url)


def validate_download_url(url, allowed_hosts):
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = parsed.scheme == "https" and parsed.hostname in allowed_hosts and parsed.port in (None, 443)
        valid = valid and parsed.username is None and parsed.password is None and not parsed.fragment
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise WorkerError("downloadFailed")


def download_into(url, output, maximum_bytes, allowed_hosts):
    validate_download_url(url, allowed_hosts)
    # Ignore system proxy settings for the explicitly approved public hosts.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), SafeRedirectHandler(allowed_hosts))
    request = urllib.request.Request(url, headers={"User-Agent": "HwattakPDF-LocalTranslation/1"})
    with opener.open(request, timeout=30) as response:
        validate_download_url(response.url, allowed_hosts)
        size_header = response.headers.get("Content-Length")
        if size_header and int(size_header) > maximum_bytes:
            raise WorkerError("downloadFailed")
        total = 0
        while True:
            data = response.read(min(64 * 1024, maximum_bytes - total + 1))
            if not data:
                break
            total += len(data)
            if total > maximum_bytes:
                raise WorkerError("downloadFailed")
            output.write(data)


def official_catalog(package):
    import io
    output = io.BytesIO()
    try:
        download_into(OFFICIAL_INDEX, output, MAX_CATALOG_BYTES, frozenset(("raw.githubusercontent.com",)))
        metadata = json.loads(output.getvalue())
        if not isinstance(metadata, list) or len(metadata) > 2048:
            raise ValueError()
        return [package.AvailablePackage(value) for value in metadata if isinstance(value, dict)]
    except Exception:
        raise WorkerError("catalogFailed")


def validate_archive(path):
    """Validate before extraction; no symlinks, traversal or zip bombs."""
    try:
        if not path.is_file() or path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise ValueError()
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > 10000:
                raise ValueError()
            roots, names, total = set(), set(), 0
            for entry in entries:
                name = entry.filename
                parts = PurePosixPath(name).parts
                mode = entry.external_attr >> 16
                if (not parts or name.startswith("/") or "\\" in name or "\x00" in name
                        or any(part in ("", ".", "..") for part in name.removesuffix("/").split("/"))
                        or stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))
                        or name in names or len(name.encode("utf-8")) > 1024):
                    raise ValueError()
                if not re.fullmatch(r"[A-Za-z0-9_.-]{1,160}", parts[0]) or parts[0].startswith("."):
                    raise ValueError()
                names.add(name)
                roots.add(parts[0])
                total += entry.file_size
                if total > MAX_EXPANDED_BYTES or entry.file_size > MAX_ARCHIVE_BYTES:
                    raise ValueError()
                if entry.file_size > 1024 * 1024 and entry.file_size > max(entry.compress_size, 1) * 200:
                    raise ValueError()
            if len(roots) != 1:
                raise ValueError()
            root = next(iter(roots))
            metadata_info = archive.getinfo(root + "/metadata.json")
            if metadata_info.file_size > 128 * 1024:
                raise ValueError()
            metadata = json.loads(archive.read(metadata_info))
            if (not isinstance(metadata, dict) or metadata.get("type", "translate") != "translate"
                    or not LANGUAGE_PATTERN.fullmatch(str(metadata.get("from_code", "")))
                    or not LANGUAGE_PATTERN.fullmatch(str(metadata.get("to_code", "")))):
                raise ValueError()
            return root, metadata
    except Exception:
        raise WorkerError("invalidArchive")


def install_archive(path, package, settings, expected_id=None):
    root, metadata = validate_archive(path)
    record = pack_record(package.AvailablePackage(metadata))
    if not record or (expected_id is not None and record["id"] != expected_id):
        raise WorkerError("invalidArchive")
    destination_parent = Path(settings.package_data_dir)
    destination_parent.mkdir(parents=True, exist_ok=True)
    destination = destination_parent / root
    if destination.exists() or destination.is_symlink():
        if not destination.is_symlink():
            try:
                existing = pack_record(package.Package(destination))
                if existing and existing["id"] == record["id"]:
                    return record
            except Exception:
                pass
        raise WorkerError("archiveConflict")
    # Staging is a sibling of the package directory so Argos does not enumerate
    # partial packages. Rename publishes only a completely extracted pack.
    with tempfile.TemporaryDirectory(prefix=".hwattak-argos-", dir=destination_parent.parent) as staging:
        previous_directory = settings.package_data_dir
        try:
            settings.package_data_dir = Path(staging)
            package.install_from_path(path)
        finally:
            settings.package_data_dir = previous_directory
        staged = Path(staging) / root
        if not staged.is_dir() or destination.exists() or destination.is_symlink():
            raise WorkerError("archiveConflict")
        staged.rename(destination)
    return record


def translate_texts(request):
    # Prevent Stanza from rechecking remote resource catalogs when its packaged
    # tokenizer is already present. MiniSBD downloads remain blocked by audit.
    try:
        import stanza
        original_pipeline = stanza.Pipeline
        def offline_pipeline(*args, **kwargs):
            kwargs["download_method"] = stanza.DownloadMethod.NONE
            return original_pipeline(*args, **kwargs)
        stanza.Pipeline = offline_pipeline
    except ImportError:
        pass
    try:
        from argostranslate import translate
        languages = translate.get_installed_languages()
        source = next((value for value in languages if value.code == request["sourceLanguage"]), None)
        target = next((value for value in languages if value.code == request["targetLanguage"]), None)
        translator = source.get_translation(target) if source is not None and target is not None else None
        if translator is None:
            raise WorkerError("pairMissing")
        values = [translator.translate(text) if text.strip() else text for text in request["texts"]]
        if any(not isinstance(value, str) or len(value.encode("utf-8")) > 128000 for value in values):
            raise WorkerError("invalidResponse")
        return {"ok": True, "translations": values}
    except WorkerError:
        raise
    except (ImportError, ModuleNotFoundError):
        raise WorkerError("runtimeMissing")
    except Exception:
        raise WorkerError("offlineResourcesMissing")


def execute_request(request):
    validate_request(request)
    action = request["action"]
    if action in ("translate", "installed", "import"):
        block_network()
    package, settings = load_argos()
    if action == "translate":
        return translate_texts(request)
    if action == "installed":
        return {"ok": True, "packs": pack_records(package.get_installed_packages())}
    if action == "available":
        return {"ok": True, "packs": pack_records(official_catalog(package))}
    if action == "import":
        install_archive(Path(request["archivePath"]), package, settings)
        return {"ok": True}
    packages = official_catalog(package)
    selected = next((value for value in packages if pack_record(value) and pack_record(value)["id"] == request["packID"]), None)
    if selected is None:
        raise WorkerError("packMissing")
    links = getattr(selected, "links", [])
    valid_links = []
    for link in links if isinstance(links, list) else []:
        try:
            validate_download_url(link, DOWNLOAD_HOSTS)
            valid_links.append(link)
        except WorkerError:
            continue
    if not valid_links:
        raise WorkerError("downloadFailed")
    with tempfile.TemporaryDirectory(prefix="hwattak-argos-download-") as temporary:
        archive_path = Path(temporary) / "download.argosmodel"
        downloaded = False
        for link in valid_links[:4]:
            try:
                with archive_path.open("wb") as output:
                    download_into(link, output, MAX_ARCHIVE_BYTES, DOWNLOAD_HOSTS)
                downloaded = True
                break
            except Exception:
                continue
        if not downloaded:
            raise WorkerError("downloadFailed")
        record = install_archive(archive_path, package, settings, request["packID"])
    # Explicit install may prepare the runtime's sentence tokenizer. The only
    # input here is a fixed test string; no document text enters this operation.
    from argostranslate import translate
    if hasattr(translate.get_installed_languages, "cache_clear"):
        translate.get_installed_languages.cache_clear()
    translate.translate("Hello.", record["sourceLanguage"], record["targetLanguage"])
    return {"ok": True}


def worker_main():
    # Preserve one private output descriptor, discard both Python and native
    # model logs before imports. Source text never appears in argv or logs.
    output_fd = os.dup(sys.stdout.fileno())
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), sys.stdout.fileno())
        os.dup2(sink.fileno(), sys.stderr.fileno())
        try:
            data = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
            if len(data) > MAX_REQUEST_BYTES:
                raise WorkerError("inputTooLarge")
            response = execute_request(json.loads(data))
        except WorkerError as error:
            response = error_response(error.code)
        except Exception:
            response = error_response("failed")
        encoded = json.dumps(response, ensure_ascii=False).encode("utf-8")
        if len(encoded) > MAX_RESPONSE_BYTES:
            encoded = json.dumps(error_response("invalidResponse")).encode("utf-8")
        with os.fdopen(output_fd, "wb") as output:
            output.write(encoded)


class WorkerController:
    def __init__(self):
        self.lock = threading.Lock()
        self.slot = threading.BoundedSemaphore(1)
        self.active = {}
        self.cancelled = {}

    def cancel(self, request_id):
        with self.lock:
            now = time.monotonic()
            self.cancelled = {key: value for key, value in self.cancelled.items() if now - value < 60}
            if len(self.cancelled) < 128:
                self.cancelled[request_id] = now
            process = self.active.get(request_id)
            if process and process.poll() is None:
                process.kill()

    def run(self, request):
        if not self.slot.acquire(blocking=False):
            return error_response("busy")
        request_id = request["requestID"]
        try:
            with self.lock:
                if request_id in self.cancelled:
                    return error_response("cancelled")
                process = subprocess.Popen(
                    [sys.executable, "-I", str(Path(__file__).resolve()), "--worker"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
                self.active[request_id] = process
            try:
                output, _ = process.communicate(json.dumps(request).encode("utf-8"), timeout=OPERATION_TIMEOUTS[request["action"]])
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                return error_response("timedOut")
            with self.lock:
                if request_id in self.cancelled:
                    return error_response("cancelled")
            if len(output) > MAX_RESPONSE_BYTES or process.returncode != 0:
                return error_response("failed")
            return json.loads(output)
        except Exception:
            return error_response("failed")
        finally:
            with self.lock:
                self.active.pop(request_id, None)
                self.cancelled.pop(request_id, None)
            self.slot.release()


class TranslationHandler(http.server.BaseHTTPRequestHandler):
    server_version = "HwattakLocalTranslation/1"

    def log_message(self, _format, *_args):
        pass

    def send_json(self, value, status=200):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        self.close_connection = True

    def do_POST(self):
        self.connection.settimeout(10)
        expected_host = "127.0.0.1:" + str(self.server.server_port)
        hosts = self.headers.get_all("Host", [])
        if (hosts != [expected_host] or self.headers.get("Origin") is not None
                or any(name.lower().startswith("sec-fetch-") for name in self.headers)
                or self.headers.get("Transfer-Encoding") is not None
                or len(self.headers.get_all("Content-Length", [])) != 1
                or self.headers.get_content_type() != "application/json"):
            self.send_json(error_response("forbidden"), 403)
            return
        if self.path not in ("/v1/translation", "/v1/cancel"):
            self.send_json(error_response("invalidInput"), 404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_REQUEST_BYTES:
                self.send_json(error_response("inputTooLarge"), 413)
                return
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError()
            request = json.loads(data)
            if self.path == "/v1/cancel":
                if not isinstance(request, dict) or set(request) != {"requestID"}:
                    raise ValueError()
                uuid.UUID(request["requestID"])
                self.server.controller.cancel(request["requestID"])
                self.send_json({"ok": True})
                return
            validate_request(request)
        except WorkerError as error:
            self.send_json(error_response(error.code), 400)
            return
        except (ValueError, TypeError, AttributeError, TimeoutError):
            self.send_json(error_response("invalidInput"), 400)
            return
        self.send_json(self.server.controller.run(request))


class TranslationServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, port=17862, controller=None):
        self.controller = controller or WorkerController()
        super().__init__(("127.0.0.1", port), TranslationHandler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="Start the loopback helper")
    parser.add_argument("--port", type=int, default=17862)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.worker:
        worker_main()
    elif arguments.serve and 1 <= arguments.port <= 65535:
        with TranslationServer(arguments.port) as server:
            print("HwattakPDF local translation: http://127.0.0.1:" + str(server.server_port), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
