#!/usr/bin/env python3
"""Test against a generated, local video. No third-party media or network required."""
import functools
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="flow-fixture-") as directory:
    fixture = Path(directory) / "sample.mp4"
    subprocess.run([
        "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=0x245e49:s=320x180:r=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", str(fixture)
    ], check=True)
    resume_fixture = Path(directory) / "resume.mp4"
    resume_fixture.write_bytes(fixture.read_bytes() + bytes(4 * 1024 * 1024))

    class Handler(http.server.SimpleHTTPRequestHandler):
        ranges = 0

        def do_GET(self):
            if self.path != "/resume.mp4":
                return super().do_GET()
            size = resume_fixture.stat().st_size
            start = 0
            request_range = self.headers.get("Range")
            if request_range:
                start = int(request_range.removeprefix("bytes=").split("-")[0])
                type(self).ranges += 1
            self.send_response(206 if request_range else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(size - start))
            if request_range:
                self.send_header("Content-Range", f"bytes {start}-{size-1}/{size}")
            self.end_headers()
            try:
                with resume_fixture.open("rb") as file:
                    file.seek(start)
                    while data := file.read(64 * 1024):
                        self.wfile.write(data)
                        self.wfile.flush()
                        time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass

    handler = functools.partial(Handler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(os.environ, FLOW_INTEGRATION_URL=f"http://127.0.0.1:{server.server_port}/sample.mp4")
        env["FLOW_RESUME_URL"] = f"http://127.0.0.1:{server.server_port}/resume.mp4"
        env["FLOW_RESUME_FIXTURE"] = str(resume_fixture)
        subprocess.run(["swift", "run", "FlowChecks"], cwd=root, env=env, check=True)
        assert Handler.ranges > 0, "Resume did not send an HTTP Range request"
    finally:
        server.shutdown()
