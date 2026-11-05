#!/usr/bin/env python3
"""Run on a disposable emulator: upgrade, native engine, UI, video/MP3 and MediaStore."""
import argparse
import functools
import http.server
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "app.flow.downloader"
parser = argparse.ArgumentParser()
parser.add_argument("--adb", default="adb")
parser.add_argument("--port", default="5037")
parser.add_argument("--legacy-apk")
args = parser.parse_args()


def adb(*parts, check=True, input=None):
    return subprocess.run([args.adb, "-P", args.port, *parts], input=input, capture_output=True, check=check, timeout=40).stdout


def shell(*parts, **kwargs):
    return adb("shell", shlex.join(parts), **kwargs)


def wait_for(action, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            result = action()
            if result:
                return result
        except (subprocess.CalledProcessError, ValueError, zipfile.BadZipFile, ET.ParseError):
            pass
        time.sleep(0.4)
    raise RuntimeError("Timed out waiting for emulator assertion")


def tree():
    shell("uiautomator", "dump", "/sdcard/flow-smoke.xml")
    return ET.fromstring(shell("cat", "/sdcard/flow-smoke.xml"))


def tap_node(predicate):
    node = next((n for n in tree().iter("node") if predicate(n)), None)
    if node is None:
        raise RuntimeError("UI element missing")
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
    shell("input", "tap", str((x1+x2)//2), str((y1+y2)//2))


def tap(text):
    tap_node(lambda n: text in n.attrib.get("text", ""))


def engine_version():
    binary = shell("run-as", PACKAGE, "cat", "no_backup/youtubedl-android/yt-dlp/yt-dlp")
    with zipfile.ZipFile(io.BytesIO(binary)) as zip:
        return re.search(r"__version__\s*=\s*['\"]([^'\"]+)", zip.read("yt_dlp/version.py").decode())[1]


def jobs():
    xml = shell("run-as", PACKAGE, "cat", "shared_prefs/flow.xml")
    return json.loads(ET.fromstring(xml).find("string[@name='jobs']").text)


def start():
    shell("pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS")
    shell("am", "start", "-n", PACKAGE+"/.MainActivity")


def share(value):
    shell("am", "start", "-n", PACKAGE+"/.MainActivity", "-a", "android.intent.action.SEND", "-t", "text/plain", "--es", "android.intent.extra.TEXT", value)


adb("wait-for-device")
for setting in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]:
    shell("settings", "put", "global", setting, "0")
shell("input", "keyevent", "82")
sentinel_id = str(uuid.uuid4())
if args.legacy_apk:
    adb("install", "-r", args.legacy_apk)
    start()
    old_version = wait_for(engine_version)
    print("Legacy engine:", old_version, flush=True)
    shell("am", "force-stop", PACKAGE)
    sentinel = {"id": sentinel_id, "url": "https://example.com/saved", "title": "升级保留测试", "quality": 0, "status": "paused", "progress": 0.2, "detail": "", "contentUri": ""}
    preferences = ET.Element("map")
    ET.SubElement(preferences, "string", name="jobs").text = json.dumps([sentinel], ensure_ascii=False)
    shell("run-as", PACKAGE, "sh", "-c", "cat > shared_prefs/flow.xml", input=ET.tostring(preferences))

adb("install", "-r", str(ROOT/"android/app/build/outputs/apk/debug/app-debug.apk"))
start()
assert wait_for(lambda: engine_version() == "2026.10.26")
if args.legacy_apk:
    assert any(j["id"] == sentinel_id and j["progress"] == 0.2 for j in jobs())
print("PASS upgrade preserves jobs and replaces old engine with 2026.10.26", flush=True)

with tempfile.TemporaryDirectory(prefix="flow-android-") as folder:
    fixture = Path(folder)/"video.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=0x245e49:s=320x180:r=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", str(fixture)], check=True)
    (Path(folder)/"audio.mp4").write_bytes(fixture.read_bytes())
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=folder))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for audio in [False, True]:
            url = f"http://10.0.2.2:{server.server_port}/{'audio' if audio else 'video'}.mp4"
            share("复制分享视频 " + url + " 一起看看")
            tap_node(lambda n: n.attrib.get("class") == "android.widget.Spinner")
            tap("仅音频 · MP3" if audio else "最佳画质")
            if not audio:
                tap("解析链接")
                wait_for(lambda: any(n.attrib.get("text", "").startswith("video") for n in tree().iter("node")), timeout=30)
            tap("加入下载队列")
            def finished():
                job = next((j for j in jobs() if j["url"] == url), None)
                if job and job["status"] == "failed":
                    raise RuntimeError(job["detail"])
                return job if job and job["status"] == "completed" else None
            job = wait_for(finished, timeout=30)
            assert job["contentUri"].startswith("content://media/")
            filename = job["title"] + (".mp3" if audio else ".mp4")
            data = shell("cat", "/sdcard/Download/拾流/" + filename)
            if not audio:
                assert data == fixture.read_bytes()
            else:
                target = Path(folder)/"verified.mp3"; target.write_bytes(data)
                probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name", "-of", "json", str(target)], capture_output=True, check=True)
                assert json.loads(probe.stdout)["streams"][0]["codec_name"] == "mp3"
            print("PASS", "MP3 conversion" if audio else "video parse and download", "and public MediaStore export", flush=True)
        output = ROOT/"dist/Flow-Android-1.0.1.png"
        output.write_bytes(adb("exec-out", "screencap", "-p"))
        print("Screenshot:", output, flush=True)
    finally:
        server.shutdown()
print("Android emulator smoke checks passed.", flush=True)
