#!/usr/bin/env python3
"""Exercise WebKit and Finder custom icons on disposable shortcuts."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
import zlib

ROOT = Path(__file__).resolve().parent.parent
EXECUTABLE = ROOT / "build/Webloc Thumbnails.app/Contents/MacOS/WeblocThumbnails"
PAGE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Capture fixture</title>
<style>html,body{margin:0;background:#e44832;color:white;font-family:system-ui}
main{padding:72px}h1{font-size:84px;max-width:950px;margin:0 0 40px}
section{height:280px;border-radius:24px;background:#245d49;padding:30px;font-size:32px}
</style></head><body><main><h1>Website previews,<br>right in Finder.</h1>
<section>This is a real WebKit screenshot.<br>1280 x 960 desktop viewport</section>
</main></body></html>"""


def solid_png():
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(
        b'IDAT', zlib.compress(bytes([0, 36, 93, 73, 255]))) + chunk(b'IEND', b'')


class Fixture(http.server.BaseHTTPRequestHandler):
    requests = 0
    path_requests = {}

    def respond(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        type(self).requests += 1
        type(self).path_requests[self.path] = type(self).path_requests.get(self.path, 0) + 1
        if self.path.startswith("/slow"):
            time.sleep(5)
        if self.path == '/critical-style':
            time.sleep(0.65)
            css = b'html,body{margin:0;min-height:100vh;background:#245d49;color:white;font:40px system-ui}'
            return self.respond(css, 'text/css')
        if self.path == '/delayed-image':
            time.sleep(0.65)
            return self.respond(solid_png(), 'image/png')
        page = PAGE
        if self.path.startswith('/hydration'):
            page = b'''<html><body style="margin:0;background:#e44832"><p>Loading...</p>
            <script>setTimeout(()=>{document.body.style.background='#245d49';document.body.innerHTML='<h1>Ready website</h1>'},450)</script></body></html>'''
        if self.path == '/dialogs':
            page = b'''<html><body style="margin:0"><script>alert('Alert');
            const cancelled = !confirm('Confirm') && prompt('Prompt') === null;
            document.body.style.background = cancelled ? '#245d49' : '#e44832';
            document.body.innerHTML = '<h1>Dialogs dismissed</h1>';</script></body></html>'''
        if self.path.startswith('/offscreen'):
            page = PAGE.replace(b'</main>', b'<img style="position:absolute;top:4000px" src="/slow/offscreen-image"></main>')
        if self.path == '/stylesheet':
            page = b'<html><head><link rel="stylesheet" href="/critical-style"></head><body><h1>Styled website</h1></body></html>'
        if self.path == '/zero-image':
            page = b'<html><body style="margin:0"><p style="margin:0;height:20px">Website image</p><img style="display:block;width:400px;height:auto" src="/delayed-image"></body></html>'
        if self.path == '/embedded-download':
            page = PAGE.replace(b'</main>', b'<iframe src="/download"></iframe></main>')
        status = 404 if self.path.startswith("/missing") else 200
        self.respond(page, "application/octet-stream" if self.path == '/download' else "text/html; charset=utf-8", status)

    def log_message(self, *args):
        pass


def custom_icon(path):
    info = bytes.fromhex(subprocess.check_output(["xattr", "-px", "com.apple.FinderInfo", str(path)], text=True))
    assert len(info) >= 10 and struct.unpack(">H", info[8:10])[0] & 0x0400, "Custom icon flag is missing"
    fork = bytes.fromhex(subprocess.check_output(["xattr", "-px", "com.apple.ResourceFork", str(path)], text=True))
    assert len(fork) > 100, "Custom icon resource fork is empty"
    return hashlib.sha256(fork).hexdigest()


def sample_rgb(path, x=256, y=200):
    """Read a sample from our non-interlaced 8-bit RGB/RGBA PNG, using stdlib."""
    png = path.read_bytes()
    width, height, bits, kind = struct.unpack('>IIBB', png[16:26])
    assert bits == 8 and kind in (2, 6) and png[28] == 0
    assert 0 <= x < width and 0 <= y < height
    channels = 4 if kind == 6 else 3
    compressed = bytearray()
    offset = 8
    while offset < len(png):
        length = struct.unpack('>I', png[offset:offset + 4])[0]
        if png[offset + 4:offset + 8] == b'IDAT':
            compressed.extend(png[offset + 8:offset + 8 + length])
        offset += length + 12
    pixels = zlib.decompress(compressed)
    stride = width * channels
    previous = bytearray(stride)
    offset = 0
    for _ in range(y + 1):
        filtering = pixels[offset]
        line = bytearray(pixels[offset + 1:offset + 1 + stride])
        for index in range(stride):
            left = line[index - channels] if index >= channels else 0
            up = previous[index]
            corner = previous[index - channels] if index >= channels else 0
            if filtering == 0: predictor = 0
            elif filtering == 1: predictor = left
            elif filtering == 2: predictor = up
            elif filtering == 3: predictor = (left + up) // 2
            else:
                assert filtering == 4
                estimate = left + up - corner
                a, b, c = abs(estimate - left), abs(estimate - up), abs(estimate - corner)
                predictor = left if a <= b and a <= c else up if b <= c else corner
            line[index] = (line[index] + predictor) & 255
        previous = line
        offset += stride + 1
    return tuple(previous[x * channels:x * channels + 3])


def main():
    if not EXECUTABLE.exists():
        raise SystemExit("Run bash scripts/build-app.sh first.")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        with tempfile.TemporaryDirectory(prefix="webloc-thumbnails-smoke-") as temporary:
            directory = Path(temporary)
            environment = dict(os.environ, WEBLOC_THUMBNAILS_CACHE_DIR=str(directory / "cache"))
            report = directory / "report.json"

            def shortcut(name, url, binary=False):
                file = directory / name
                file.write_bytes(plistlib.dumps({"URL": url}, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML))
                return file

            def run(*files, options=(), expected=0):
                process = subprocess.run([str(EXECUTABLE), "--generate", "--report", str(report),
                    *options, "--", *map(str, files)], env=environment, capture_output=True, text=True, timeout=60)
                if process.returncode != expected:
                    raise AssertionError(f"Exit {process.returncode}, expected {expected}\n{process.stdout}\n{process.stderr}")
                result = json.loads(process.stdout)
                assert json.loads(report.read_text()) == result
                return result

            def capture_preview(file):
                previous = set((directory / 'cache').glob('*.png'))
                run(file)
                fresh = set((directory / 'cache').glob('*.png')) - previous
                assert len(fresh) == 1
                return fresh.pop()

            xml = shortcut("A website with spaces.webloc", base + "/#first")
            binary = shortcut("Binary éxample.webloc", base + "/#second", binary=True)
            invalid = shortcut("Invalid.webloc", "file:///etc/hosts")
            missing = shortcut("Missing.webloc", base + "/missing")
            original_bytes = {file: file.read_bytes() for file in (xml, binary, invalid, missing)}
            first = run(xml, binary, invalid, missing, options=("--timeout", "8"), expected=1)
            assert [item["status"] for item in first["results"]] == ["success", "success", "failed", "failed"], first
            for file, data in original_bytes.items():
                assert file.read_bytes() == data, "Shortcut content changed"
            custom_icon(xml)
            custom_icon(binary)
            assert "com.apple.ResourceFork" not in subprocess.check_output(["xattr", str(invalid)], text=True)
            assert "com.apple.ResourceFork" not in subprocess.check_output(["xattr", str(missing)], text=True)
            thumbnails = list((directory / "cache").glob("*.png"))
            assert len(thumbnails) == 2, "Fragment URLs must have distinct cache entries"
            for thumbnail in thumbnails:
                data = thumbnail.read_bytes()
                assert data[:8] == b"\x89PNG\r\n\x1a\n"
                assert struct.unpack(">II", data[16:24]) == (512, 512)
            shutil.copy2(thumbnails[0], ROOT / "build/smoke-preview.png")
            print("PASS: XML/binary shortcuts, WebKit captures, Finder icon flags/resource forks, unchanged URLs, mixed failures")

            before = Fixture.requests
            second = run(xml)
            assert second["results"][0]["cached"] is True
            assert Fixture.requests == before, "Cache hit unexpectedly loaded the website"
            print("PASS: cached icon reuse without a page request")

            third = run(xml, options=("--refresh",))
            assert third["results"][0]["cached"] is False and Fixture.requests > before
            print("PASS: forced refresh")

            embedded = shortcut('Embedded download.webloc', base + '/embedded-download')
            download = shortcut('Download.webloc', base + '/download')
            downloads = run(embedded, download, expected=1)
            assert [item['status'] for item in downloads['results']] == ['success', 'failed']
            assert 'download' in downloads['results'][1]['message']
            custom_icon(embedded)
            print("PASS: embedded downloads are ignored, direct download links fail")

            # Preserve an existing thumbnail when a subsequent capture fails.
            icon_hash = custom_icon(xml)
            xml.write_bytes(plistlib.dumps({"URL": base + "/missing"}))
            failed = run(xml, expected=1)
            assert failed["results"][0]["status"] == "failed"
            assert custom_icon(xml) == icon_hash
            print("PASS: failed capture preserves the existing custom icon")

            slow = shortcut("Slow.webloc", base + "/slow")
            timeout = run(slow, binary, options=("--timeout", "1"), expected=1)
            assert [item["status"] for item in timeout["results"]] == ["failed", "success"]
            assert "1 seconds" in timeout["results"][0]["message"]
            print("PASS: page timeout and continued batch processing")

            duplicate_a = shortcut("Duplicate A.webloc", base + "/duplicate")
            duplicate_b = shortcut("Duplicate B.webloc", base + "/duplicate")
            duplicate = run(duplicate_a, duplicate_b)
            assert all(item['status'] == 'success' for item in duplicate['results'])
            assert Fixture.path_requests.get('/duplicate') == 1, 'Concurrent duplicate URLs should share one capture'
            print("PASS: concurrent duplicate URLs share one capture")

            offscreen = shortcut("Offscreen resource.webloc", base + "/offscreen")
            started = time.monotonic()
            run(offscreen)
            assert time.monotonic() - started < 4, 'Offscreen resources should not hold up a ready viewport'
            print("PASS: ready viewport captured before a slow offscreen resource finishes")

            hydrated = shortcut("Hydrated.webloc", base + "/hydration")
            preview = capture_preview(hydrated)
            red, green, blue = sample_rgb(preview)
            assert green > red and green > blue, 'Captured the loading screen instead of hydrated content'
            shutil.copy2(preview, ROOT / 'build/hydrated-preview.png')
            print("PASS: delayed client-rendered content verified in the screenshot pixels")

            styled = shortcut('Stylesheet.webloc', base + '/stylesheet')
            red, green, blue = sample_rgb(capture_preview(styled))
            assert green > red and green > blue, 'Captured an unstyled page before its CSS loaded'
            print("PASS: critical stylesheet is loaded before capturing")

            unsized = shortcut('Unsized image.webloc', base + '/zero-image')
            red, green, blue = sample_rgb(capture_preview(unsized), x=80, y=80)
            assert green > red and green > blue, 'An unloaded zero-height image was mistaken for an offscreen image'
            print("PASS: visible image without intrinsic dimensions is awaited")

            dialogs = shortcut('Script dialogs.webloc', base + '/dialogs')
            red, green, blue = sample_rgb(capture_preview(dialogs))
            assert green > red and green > blue, 'Default dialog handling should dismiss alerts and cancel prompts'
            print("PASS: page scripts cannot block generation with modal dialogs")

            # The second worker must finish a fast page while the first waits.
            blocked = shortcut('Blocked.webloc', base + '/slow/parallel')
            fast = shortcut('Fast alongside blocked.webloc', base + '/parallel-fast')
            command = [str(EXECUTABLE), '--generate', '--report', str(report), '--timeout', '4', '--', str(blocked), str(fast)]
            process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 2.5
            fast_ready = False
            while time.monotonic() < deadline:
                attributes = subprocess.check_output(['xattr', str(fast)], text=True)
                # setIcon writes the resource fork before setting the Finder flag.
                # Observe the completed commit, not its intermediate metadata.
                if 'com.apple.ResourceFork' in attributes and 'com.apple.FinderInfo' in attributes:
                    info = bytes.fromhex(subprocess.check_output(['xattr', '-px', 'com.apple.FinderInfo', str(fast)], text=True))
                    if struct.unpack('>H', info[8:10])[0] & 0x0400:
                        fast_ready = True
                        break
                time.sleep(0.03)
            still_waiting = process.poll() is None
            stdout, stderr = process.communicate(timeout=10)
            assert process.returncode == 1, stdout + stderr
            assert fast_ready and still_waiting, stdout + stderr
            custom_icon(fast)
            print("PASS: slow page does not block completion of another website")

            cancel_a = shortcut('Cancel A.webloc', base + '/slow/cancel-a')
            cancel_b = shortcut('Cancel B.webloc', base + '/slow/cancel-b')
            unstarted = shortcut('Never started.webloc', base + '/never-started')
            process = subprocess.Popen([str(EXECUTABLE), '--generate', '--report', str(report), '--',
                str(cancel_a), str(cancel_b), str(unstarted)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not all(Fixture.path_requests.get(path) for path in ('/slow/cancel-a', '/slow/cancel-b')):
                time.sleep(0.03)
            assert all(Fixture.path_requests.get(path) for path in ('/slow/cancel-a', '/slow/cancel-b')), 'Both workers should have started'
            started = time.monotonic()
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=5)
            cancelled = json.loads(stdout)
            assert process.returncode == 130 and cancelled['cancelled'], stdout + stderr
            assert all(item['status'] == 'cancelled' for item in cancelled['results'])
            assert time.monotonic() - started < 2
            assert not Fixture.path_requests.get('/never-started')
            for file in (cancel_a, cancel_b, unstarted):
                assert 'com.apple.ResourceFork' not in subprocess.check_output(['xattr', str(file)], text=True)
            print("PASS: cancellation stops both captures promptly and skips queued files")

            # A report failure must not look like a successful CLI invocation.
            process = subprocess.run([str(EXECUTABLE), '--generate', '--report', str(directory), '--', str(binary)],
                env=environment, capture_output=True, text=True, timeout=10)
            assert process.returncode == 1 and 'save the report' in process.stderr, process.stdout + process.stderr
            assert json.loads(process.stdout)['results'][0]['status'] == 'success'

            # Registration is a standalone mode, never a special option value.
            process = subprocess.run([str(EXECUTABLE), '--generate', '--report', '--register-services', '--', str(binary)],
                cwd=directory, env=environment, capture_output=True, text=True, timeout=10)
            assert process.returncode == 0, process.stdout + process.stderr
            assert json.loads((directory / '--register-services').read_text()) == json.loads(process.stdout)
            print("PASS: report failures set the exit status and option values are parsed literally")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
