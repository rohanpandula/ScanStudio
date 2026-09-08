#!/usr/bin/env python3
"""Bounded, hardware-free acceptance against an Apple Silicon packaged app."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import queue
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time


TIMEOUT = 30
RECIPE = {"resolutionDpi": 100, "bitDepth": 16,
          "multisamplePasses": 1, "channels": "rgb"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def isolated_environment(root):
    # Never inherit bridge commands, arming, Python hooks, or developer output paths.
    return {"HOME": str(root), "CFFIXED_USER_HOME": str(root), "TMPDIR": str(root), "PATH": "/usr/bin:/bin",
            "LANG": "C", "LC_ALL": "C"}


class Engine:
    """Same NDJSON seam as smoke_project_persistence; retain interleaved events."""

    def __init__(self, executable, root):
        self.process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=isolated_environment(root), cwd=root)
        self.lines = queue.Queue()
        self.events = []
        self.sequence = 0
        self.stderr = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.error_reader = threading.Thread(target=self._errors, daemon=True)
        self.error_reader.start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _errors(self):
        for line in self.process.stderr:
            self.stderr[:] = (self.stderr + [line])[-20:]

    def receive(self, deadline):
        try:
            line = self.lines.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty:
            raise RuntimeError("engine timed out; " + ''.join(self.stderr)) from None
        require(line is not None, "engine exited early; " + ''.join(self.stderr))
        message = json.loads(line)
        if 'event' in message:
            self.events.append(message)
        return message

    def call(self, method, params=None, error=False):
        self.sequence += 1
        self.process.stdin.write(json.dumps(
            {"id": self.sequence, "method": method, "params": params or {}}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + TIMEOUT
        while True:
            message = self.receive(deadline)
            if message.get('id') == self.sequence:
                if error:
                    require(bool(message.get('error')), f"{method} must refuse: {message}")
                    return message['error']
                require('result' in message and not message.get('error'),
                        f"{method}: {message}")
                return message['result']

    def event(self, name, **fields):
        deadline = time.monotonic() + TIMEOUT
        while True:
            for index, message in enumerate(self.events):
                payload = message['payload']
                if message['event'] == name and all(payload.get(k) == v for k, v in fields.items()):
                    self.events.pop(index)
                    return payload
            self.receive(deadline)

    def connect(self):
        self.call('engine.hello', {"clientName": "mac-acceptance", "protocolVersion": 1})
        devices = self.call('scanner.list')['devices']
        require(devices and all(d['deviceId'].startswith('sim-') for d in devices),
                f"non-simulator backend exposed: {devices}")
        self.call('scanner.connect', {"deviceId": "sim-ls5000-0",
                                      "options": {"timeScale": 0.5, "faultInjection": "none"}})
        self.call('sim.loadMedia', {"carrier": "strip6"})

    def close(self, graceful=False):
        try:
            if graceful and self.process.poll() is None:
                self.call('engine.shutdown')
                self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=5)
            self.reader.join(timeout=5)
            self.error_reader.join(timeout=5)
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                stream.close()


def scan_params(root, frames):
    output = {role: {"enabled": True, "destination": str(root / role),
                     "filenameTemplate": "Acceptance#"}
              for role in ('archive', 'positive', 'preview')}
    output['archive']['fullCapturePackage'] = False
    output['preview']['maxLongEdgePx'] = 149
    return {"frames": frames, "recipe": RECIPE, "output": output}


def verify_receipts(root, expected, device_id='sim-ls5000-0'):
    project = json.loads((root / 'manifest.json').read_text())
    completed = [f['index'] for f in project['frames'] if f['receipts']]
    require(completed == expected, f"persisted completion mismatch: {completed} != {expected}")
    snapshots, images = {}, []
    for frame in project['frames']:
        if not frame['receipts']:
            continue
        require(len(frame['receipts']) == 1, f"frame was rescanned: {frame['index']}")
        receipt = frame['receipts'][0]
        require(receipt['simulated'] is True and receipt['deviceId'] == device_id,
                'receipt must identify simulated capture')
        if device_id == 'sim-ls50-0':
            require(receipt.get('hardwareVerification') == 'unverified'
                    and 'LS-50' in receipt.get('deviceModel', ''),
                    'unverified receipt lost model or verification provenance')
        require(receipt['frameIndex'] == frame['index'] and receipt['resolutionDpi'] == 100
                and receipt['bitDepth'] == 16, 'receipt capture settings mismatch')
        outputs = receipt['outputs']
        bindings = outputs['metadataBindings']
        for role in ('archive', 'positive', 'preview'):
            binding = bindings[role]
            path = root / binding['relativePath']
            require(not path.is_symlink() and path.is_file() and
                    path.resolve().is_relative_to(root.resolve()), 'output escaped project')
            require(path.resolve() == Path(outputs[role + 'Path']).resolve(),
                    'receipt display path differs from hash binding')
            stat = path.stat()
            require(0 < stat.st_size < 2_000_000, f"unbounded/empty output: {path}")
            sha = digest(path)
            require(sha == binding['sha256'] and stat.st_size == binding['byteLength'],
                    f"receipt hash/length mismatch: {path}")
            require(stat.st_ino == binding['fileId'] and stat.st_dev == binding['volumeId'],
                    f"receipt file identity mismatch: {path}")
            snapshots[str(path)] = [sha, stat.st_size, stat.st_ino, stat.st_mtime_ns]
            images.append({"path": str(path), "width": 99, "height": 149,
                           "dtype": "uint8" if role == 'preview' else 'uint16'})
            if role == 'positive' and device_id == 'sim-ls50-0':
                images[-1]['deviceModel'] = receipt['deviceModel']
    return project, snapshots, images


def decode_images(runtime, images, root):
    # Use the shipped OpenCV decoder, not host Pillow or a header-only parser.
    code = '''import json, sys
from pathlib import Path
import cv2
if not Path(cv2.__file__).resolve().is_relative_to(Path(sys.argv[1]).resolve()):
    raise SystemExit('image decoder did not load from bundled site-packages')
for item in json.load(sys.stdin):
    image = cv2.imread(item['path'], cv2.IMREAD_UNCHANGED)
    if image is None or image.shape != (item['height'], item['width'], 3):
        raise SystemExit('unreadable image or wrong dimensions: ' + item['path'])
    if str(image.dtype) != item['dtype']:
        raise SystemExit('wrong image bit depth: ' + item['path'])
    if 'deviceModel' in item:
        import tifffile
        with tifffile.TiffFile(item['path']) as tiff:
            tags = tiff.pages[0].tags
            if tags.get('Model') is None or tags['Model'].value != item['deviceModel']:
                raise SystemExit('TIFF lost device model: ' + item['path'])
            if tags.get('Software') is None or 'hardwareVerification=unverified' not in tags['Software'].value:
                raise SystemExit('TIFF lost unverified provenance: ' + item['path'])
'''
    subprocess.run([str(runtime), '-I', '-B', '-c', code,
                    str(runtime.parents[2] / 'site-packages')],
                   input=json.dumps(images), text=True, check=True, timeout=TIMEOUT,
                   env=isolated_environment(root), cwd=root, capture_output=True)


def verify_app(app):
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64',
            'Acceptance requires native Apple Silicon (M-series) macOS; Rosetta is not supported')
    engine = app / 'Contents/MacOS/scanstudio-engine'
    cli = app / 'Contents/MacOS/scanstudio-cli'
    runtime = app / 'Contents/Resources/BridgeRuntime/python/bin/python3.13'
    for executable in (app / 'Contents/MacOS/ScanStudio', engine, cli, runtime):
        require(executable.is_file(), f"missing packaged executable: {executable}")
        result = subprocess.run(['/usr/bin/lipo', '-archs', str(executable)],
                                text=True, capture_output=True, check=True, timeout=10)
        require(result.stdout.strip() == 'arm64', f"expected arm64 only: {executable}")
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    require(info.get('LSMinimumSystemVersion') == '14.0', 'expected supported macOS floor 14.0')
    return engine, cli, runtime, info


def _cli_json(cli, socket_path, root, *arguments, expect_exit=0):
    argv = [str(cli), *arguments, '--socket', str(socket_path)]
    # A six-frame job wait needs an aggregate budget, unlike a single reply.
    timeout = TIMEOUT * 6 if '--wait' in arguments else TIMEOUT
    completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                               env=isolated_environment(root), cwd=root)
    if completed.returncode != expect_exit:
        raise RuntimeError(f"CLI {' '.join(argv)} exited {completed.returncode}, expected {expect_exit}; stdout={completed.stdout!r}; stderr={completed.stderr!r}")
    text = completed.stdout.strip()
    try:
        decoder = json.JSONDecoder()
        value, end = decoder.raw_decode(text)
        require(not text[end:].strip(), f"CLI {' '.join(argv)} did not print exactly one JSON object: {text!r}")
        require(isinstance(value, dict), f"CLI {' '.join(argv)} printed non-object JSON: {text!r}")
        return value
    except (ValueError, RuntimeError) as error:
        raise RuntimeError(f"CLI {' '.join(argv)} output was not exactly one JSON object: {error}; stdout={completed.stdout!r}; stderr={completed.stderr!r}") from None


def _require_simulator_devices(envelope):
    devices = (envelope.get('result') or {}).get('devices', [])
    ids = [device.get('deviceId', '') for device in devices]
    require(devices and all(device_id.startswith('sim-') for device_id in ids),
            f"non-simulator backend exposed: {ids}")


def _gate_socket_directory():
    directory = Path(tempfile.mkdtemp(prefix='ss-pkg-', dir='/tmp'))
    socket_path = directory / 's.sock'
    require(len(str(socket_path).encode()) < 104, f"socket path is too long: {socket_path}")
    return directory, socket_path


def _bundle_engine_pids(engine_path):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], text=True,
                            capture_output=True, check=True, timeout=10)
    pids = set()
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and str(engine_path) in fields[1]:
            pids.add(int(fields[0]))
    return pids


def cli_acceptance(cli, runtime, root, device_id='sim-ls5000-0'):
    started = time.monotonic()
    socket_directory, socket_path = _gate_socket_directory()
    host_log = socket_directory / 'host.log'
    engine_path = (cli.parent / 'scanstudio-engine').resolve()
    engine_pids_before = _bundle_engine_pids(engine_path)
    host_pid = None
    remove_socket_directory = True
    steps = []
    modes = []
    roll = None

    def step(*arguments, expect_exit=0):
        envelope = _cli_json(cli, socket_path, root, *arguments, expect_exit=expect_exit)
        steps.append({'name': ' '.join(arguments), 'exitCode': expect_exit})
        if envelope.get('mode') is not None:
            modes.append(envelope['mode'])
        return envelope

    def wait_for_status(predicate, description):
        deadline = time.monotonic() + TIMEOUT
        while True:
            status = step('status')
            result = status.get('result') or {}
            if predicate(result):
                return result
            require(time.monotonic() < deadline,
                    f"{description} did not complete within {TIMEOUT}s: {status}")
            time.sleep(0.1)

    try:
        host = step('host', '--detach', '--simulator', '--log', str(host_log))
        remove_socket_directory = False
        host_pid = (host.get('result') or {}).get('hostPid')
        require(isinstance(host_pid, int) and host_pid > 0, f"detached host did not report a pid: {host}")
        require((host.get('result') or {}).get('logPath') == str(host_log),
                f"detached host log escaped the gate directory: {host}")
        require(host_log.is_file() and Path(f'{socket_path}.pid').is_file(),
                'detached host did not create its private log and pidfile')
        status = step('status')
        require(status.get('mode') == 'attach-headless', f"packaged CLI did not attach headlessly: {status}")
        require(status.get('hostPid') == host_pid, f"attached host pid mismatch: {status}")

        _require_simulator_devices(step('rescan'))
        if device_id == 'sim-ls50-0':
            refusal = step('connect', '--device', device_id, expect_exit=65)
            require((refusal.get('error') or {}).get('code') == 'NOT_SUPPORTED',
                    f"unverified device opened without opt-in: {refusal}")
            connected = step('connect', '--device', device_id, '--allow-unverified-hardware')
            require(connected.get('hardwareVerification') == 'unverified',
                    f"connect lost live unverified provenance: {connected}")
            current = step('status')
            require(current.get('hardwareVerification') == 'unverified',
                    f"status lost live unverified provenance: {current}")
        else:
            step('connect', '--device', device_id)
        step('sim', 'load-media', '--carrier', 'strip6')
        step('preview', '--film-loaded')
        wait_for_status(lambda result: result.get('previewComplete') is True, 'preview')
        frames = step('frames', 'list')
        require(len((frames.get('result') or {}).get('frames', [])) == 6,
                f"previewed strip did not list six frames: {frames}")
        step('frames', 'select', '--all')
        step('settings', 'set', '--resolution', '100')
        saved = step('roll', 'save', '--name', 'packaged-acceptance', '--carrier', 'strip6',
                     '--frame-count', '6', '--film-process', 'c41ColorNegative',
                     '--confirm-motion', '--auto-approve')
        project_directory = (saved.get('result') or {}).get('projectDirectory')
        require(project_directory, f"roll save did not report projectDirectory: {saved}")
        roll = Path(project_directory).resolve()
        require(roll.is_relative_to(root.resolve()), f"CLI project escaped gate root: {roll}")
        wait_for_status(
            lambda result: result.get('jobId') is not None
            and 0 < len(result.get('pendingFrames', [])) < 6,
            'first durable frame')
        step('stop')
        stopped = wait_for_status(
            lambda result: result.get('jobId') is None and result.get('jobState') == 'stopped',
            'partial stop')
        pending = stopped.get('pendingFrames', [])
        require(pending and len(pending) < 6,
                f"stop did not preserve a partial batch for resume: {stopped}")
        completed = [index for index in range(1, 7) if index not in pending]
        _, preserved, images = verify_receipts(roll, completed, device_id)
        decode_images(runtime, images, root)
        step('frames', 'exclude', '6')
        step('frames', 'include', '6')
        step('preview', '--film-loaded', '--intent', 'refreshSavedProject')
        wait_for_status(lambda result: result.get('scanReadiness') == 'ready', 'refreshed scan readiness')
        resumed = step('resume', '--confirm-motion', '--wait')
        require((resumed.get('result') or {}).get('jobState') == 'completed',
                f"resume did not complete the partial batch: {resumed}")
        refusal = step('eject', expect_exit=77)
        require((refusal.get('error') or {}).get('code') == 'CONFIRMATION_REQUIRED',
                f"missing confirmation was not refused: {refusal}")
        step('eject', '--confirm-motion')
        require(roll is not None, 'CLI roll path was not captured')
        _, snapshots, images = verify_receipts(roll, list(range(1, 7)), device_id)
        require(all(snapshots[path] == snapshot for path, snapshot in preserved.items()),
                'resume overwrote completed output')
        decode_images(runtime, images, root)
        return {
            'cliSha256': digest(cli), 'socketPath': str(socket_path), 'modes': modes,
            'steps': steps, 'hostPid': host_pid, 'elapsedSeconds': time.monotonic() - started,
            'outputs': {str(Path(path).relative_to(roll)): {'sha256': item[0], 'byteLength': item[1], 'fileId': item[2], 'mtimeNs': item[3]} for path, item in snapshots.items()}
        }
    finally:
        try:
            if host_pid is not None:
                _cli_json(cli, socket_path, root, 'host', 'stop')
                deadline = time.monotonic() + 5
                while True:
                    survivors = _bundle_engine_pids(engine_path) - engine_pids_before
                    if not survivors:
                        break
                    require(time.monotonic() < deadline,
                            f"packaged engine survived CLI gate: {engine_path} pids={sorted(survivors)}")
                    time.sleep(0.1)
                remove_socket_directory = True
        finally:
            if remove_socket_directory:
                shutil.rmtree(socket_directory, ignore_errors=False)


def acceptance(app, root):
    engine_path, cli_path, runtime, info = verify_app(app)
    roll = root / 'Saved roll # 1'
    client = None
    try:
        client = Engine(engine_path, root)
        client.connect()
        created = client.call('project.create', {"name": "Mac acceptance", "carrier": "strip6",
                              "frameCount": 3, "filmProcess": "c41ColorNegative", "directory": str(roll)})
        original_id = created['project']['id']
        client.call('scanner.acquireThumbnails', {"frames": [1, 2, 3],
                    "filmProcess": "c41ColorNegative", "operationId": "acceptance-preview"})
        for frame in (1, 2, 3):
            client.event('scanner.thumbnail', frameIndex=frame, operationId='acceptance-preview')
        require(client.event('scanner.thumbnailsComplete', operationId='acceptance-preview')['count'] == 3,
                'preview count mismatch')
        status = client.event('scanner.status', operationId='acceptance-preview')['status']
        require(status['transport'] == 'idle', 'preview did not release transport')
        strip = client.call('roll.previewStrip')
        strip_path = Path(strip['imagePath'])
        require(strip_path.resolve().is_relative_to(root.resolve()) and
                strip['rowCount'] == 810 and strip['pixelsPerRow'] == 1,
                'unexpected synthetic strip geometry or destination')
        decode_images(runtime, [{"path": str(strip_path), "width": 810, "height": 96,
                                 "dtype": "uint8"}], root)
        job = client.call('scan.start', scan_params(roll, [1, 2, 3]))['jobId']
        client.event('scan.frameState', jobId=job, frameIndex=1, state='active')
        require(client.call('scan.stop', {"jobId": job, "mode": "afterCurrentFrame"})['acknowledged'],
                'stop was not acknowledged')
        summary = client.event('scan.completed', jobId=job)['summary']
        require(summary['completed'] == [1] and summary['stopped'] and not summary['failed'],
                f"partial stop mismatch: {summary}")
        _, preserved, images = verify_receipts(roll, [1])
        decode_images(runtime, images, root)
        client.close(graceful=True)
        client = Engine(engine_path, root)
        client.connect()
        reopened = client.call('project.open', {"directory": str(roll)})['project']
        require(reopened['id'] == original_id, 'project identity changed after reopen')
        pending = client.call('project.pendingFrames')['frames']
        require(pending == [2, 3], f"wrong pending frames after stop: {pending}")
        job = client.call('scan.start', scan_params(roll, pending))['jobId']
        client.event('scan.frameState', jobId=job, frameIndex=2, state='active')
        # Deliberately SIGKILL this simulator process mid-frame, not a graceful EOF.
        client.close()
        client = Engine(engine_path, root)
        client.connect()
        reopened = client.call('project.open', {"directory": str(roll)})['project']
        require(reopened['id'] == original_id, 'project identity changed after interruption')
        _, recovered, _ = verify_receipts(roll, [1])
        require(recovered == preserved, 'completed output changed after interruption')
        pending = client.call('project.pendingFrames')['frames']
        require(pending == [2, 3], f"interrupted frame incorrectly completed: {pending}")
        blocker = roll / 'unusable-output'
        blocker.write_text('acceptance sentinel: preserve me\n')
        refused = scan_params(roll, pending)
        refused['output']['archive']['destination'] = str(blocker / 'child')
        error = client.call('scan.start', refused, error=True)
        require(error['code'] in ('IO_ERROR', 'INVALID_PARAMS'), f"unexpected destination refusal: {error}")
        require(blocker.read_text() == 'acceptance sentinel: preserve me\n', 'destination sentinel changed')
        require(client.call('project.pendingFrames')['frames'] == pending, 'refusal mutated completion')
        job = client.call('scan.start', scan_params(roll, pending))['jobId']
        summary = client.event('scan.completed', jobId=job)['summary']
        require(summary['completed'] == pending and not summary['stopped'] and not summary['failed'],
                f"resume did not finish: {summary}")
        require(client.call('project.pendingFrames')['frames'] == [], 'resume left pending frames')
        final, snapshots, images = verify_receipts(roll, [1, 2, 3])
        require(all(snapshots[path] == snapshot for path, snapshot in preserved.items()),
                'resume overwrote completed output')
        require(final['frames'][0]['receipts'] == reopened['frames'][0]['receipts'],
                'resume altered completed receipt')
        decode_images(runtime, images, root)
        client.close(graceful=True)
        client = None
        cli_report = cli_acceptance(cli_path, runtime, root, device_id='sim-ls50-0')
        return {"status": "passed", "scope": "simulator software only", "architecture": "arm64",
                "appVersion": info.get('CFBundleShortVersionString'), "macOS": platform.mac_ver()[0],
                "minimumMacOS": info['LSMinimumSystemVersion'], "engineSha256": digest(engine_path),
                "runtimeSha256": digest(runtime), "projectId": original_id, "outputs": {str(Path(path).relative_to(roll)): {
                    "sha256": snapshot[0], "byteLength": snapshot[1],
                    "fileId": snapshot[2], "mtimeNs": snapshot[3],
                    "width": 99, "height": 149}
                    for path, snapshot in snapshots.items()},
                "checks": ["explicit preview and decoded synthetic strip", "partial batch stop", "reopen", "SIGKILL recovery",
                           "unusable destination refusal", "resume preserves completed output",
                           "decoded dimensions and bit depth", "receipt hashes and file identities",
                           "packaged CLI simulator acceptance"], "cli": cli_report,
                "hardwareAcceptance": "NOT RUN"}
    finally:
        if client is not None:
            client.close()


def deadline_expired(signum, frame):
    raise RuntimeError('acceptance exceeded its 180-second wall-clock budget, including packaged CLI leg')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='exact packaged ScanStudio.app under test')
    parser.add_argument('--report', type=Path, help='new JSON evidence path (never overwritten)')
    args = parser.parse_args()
    require(args.report is None or not args.report.exists(), 'report already exists; choose a new path')
    signal.signal(signal.SIGALRM, deadline_expired)
    signal.alarm(180)
    try:
        with tempfile.TemporaryDirectory(prefix='ScanStudio acceptance # ') as directory:
            report = acceptance(args.app.resolve(), Path(directory))
    finally:
        signal.alarm(0)
    if args.report:
        with args.report.open('x') as stream:
            json.dump(report, stream, indent=2)
            stream.write('\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'Mac acceptance FAILED: {error}', file=sys.stderr)
        sys.exit(1)
