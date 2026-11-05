#!/usr/bin/env python3
"""Check the native app with isolated data; downloads the official engine unless --engine is supplied."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=root / 'dist/拾流.app')
parser.add_argument('--output', type=Path, default=root / '.tools' / ('macos-smoke-' + uuid.uuid4().hex))
parser.add_argument('--engine', type=Path, help='Copy an existing standalone engine into the isolated test directory')
args = parser.parse_args()
base = args.output.resolve()
base.mkdir(parents=True, exist_ok=False)
if args.engine:
    bin_dir = base / 'engines/bin'
    bin_dir.mkdir(parents=True)
    shutil.copy2(args.engine, bin_dir / 'yt-dlp')

with tempfile.TemporaryDirectory(prefix='flow-mac-fixture-') as folder:
    fixture = Path(folder) / 'first-launch.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x245e49:s=320x180:r=24',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '2', '-c:v', 'libx264',
                    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', str(fixture)], check=True)
    fixture.write_bytes(fixture.read_bytes() + bytes(4 * 1024 * 1024))
    shutil.copy2(fixture, Path(folder) / 'relaunch.mp4')

    class Handler(http.server.SimpleHTTPRequestHandler):
        def copyfile(self, source, outputfile):
            try:
                while data := source.read(64 * 1024):
                    outputfile.write(data)
                    outputfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=folder))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for attempt in ['fresh', 'relaunch']:
            command = [str(args.app.resolve() / 'Contents/MacOS/Flow'), '--smoke-test-root', str(base),
                       '--smoke-fixture-url', f'http://127.0.0.1:{server.server_port}/' + ('first-launch.mp4' if attempt == 'fresh' else 'relaunch.mp4')]
            if attempt == 'fresh':
                command += ['--smoke-enqueue-during-parse']
            with (base / f'{attempt}.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                               env={**os.environ, 'PATH': '/usr/bin:/bin'}, timeout=420, check=True)
            report = json.loads((base / 'result.json').read_text())
            (base / f'result-{attempt}.json').write_text(json.dumps(report, indent=2))
            assert report['status'] == 'passed', report
            assert report['isolatedSystemPaths']
            assert report['alreadyInstalled'] == (attempt == 'relaunch' or args.engine is not None)
            assert Path(report['output']).read_bytes() == fixture.read_bytes()
            if attempt == 'fresh':
                assert report['enqueueMilliseconds'] < 200, report
            print('PASS native app', attempt, 'enqueue milliseconds:', report.get('enqueueMilliseconds', 'cached preview'),
                  'progress samples:', len(report['progressSamples']), flush=True)
    finally:
        server.shutdown()
print('Screenshots and reports:', base)
