"""Focused failure checks for the packaged Mac acceptance gate (stdlib only)."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import queue
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'mac_acceptance', Path(__file__).resolve().parents[1] / 'verify_mac_acceptance.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class MacAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.outputs = {'metadataBindings': {}}
        for role in ('archive', 'positive', 'preview'):
            path = self.root / role
            path.write_bytes(b'fixture contents: hash checking is independent of decoding')
            stat = path.stat()
            self.outputs[role + 'Path'] = str(path)
            self.outputs['metadataBindings'][role] = {
                'relativePath': role, 'sha256': gate.digest(path), 'byteLength': stat.st_size,
                'fileId': stat.st_ino, 'volumeId': stat.st_dev}
        self.receipt = {'simulated': True, 'deviceId': 'sim-ls5000-0', 'frameIndex': 1,
                        'resolutionDpi': 100, 'bitDepth': 16, 'outputs': self.outputs}
        self.project = {'frames': [{'index': 1, 'receipts': [self.receipt]},
                                   {'index': 2, 'receipts': []}]}
        self.save()

    def save(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.project))

    def test_hash_and_identity_reject_changed_or_replaced_completed_output(self):
        _, before, _ = gate.verify_receipts(self.root, [1])
        path = self.root / 'archive'
        original = path.read_bytes()
        path.write_bytes(b'X' * len(original))
        with self.assertRaisesRegex(RuntimeError, 'hash/length mismatch'):
            gate.verify_receipts(self.root, [1])
        replacement = self.root / 'replacement'
        replacement.write_bytes(original)
        replacement.replace(path)
        with self.assertRaisesRegex(RuntimeError, 'file identity mismatch'):
            gate.verify_receipts(self.root, [1])
        self.assertIn(str(path), before)

    def test_missing_duplicate_and_false_completion_fail(self):
        with self.assertRaisesRegex(RuntimeError, 'completion mismatch'):
            gate.verify_receipts(self.root, [1, 2])
        self.project['frames'][0]['receipts'].append(copy.deepcopy(self.receipt))
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'rescanned'):
            gate.verify_receipts(self.root, [1])

    def test_symlink_output_and_missing_binding_fail(self):
        path = self.root / 'archive'
        path.unlink()
        path.symlink_to(self.root / 'positive')
        with self.assertRaisesRegex(RuntimeError, 'escaped project'):
            gate.verify_receipts(self.root, [1])
        del self.outputs['metadataBindings']['archive']
        self.save()
        with self.assertRaises(KeyError):
            gate.verify_receipts(self.root, [1])

    def test_interleaved_event_is_retained_and_timeout_is_bounded(self):
        client = gate.Engine.__new__(gate.Engine)
        client.lines, client.events, client.stderr = queue.Queue(), [], []
        client.sequence = 0
        client.process = type('FakeProcess', (), {'stdin': io.StringIO()})()
        client.lines.put(json.dumps({'event': 'scan.frameState', 'payload': {'frameIndex': 1}}))
        client.lines.put(json.dumps({'id': 1, 'result': {'jobId': 'job-1'}}))
        self.assertEqual(client.call('scan.start')['jobId'], 'job-1')
        self.assertEqual(client.event('scan.frameState', frameIndex=1), {'frameIndex': 1})
        with patch.object(gate, 'TIMEOUT', 0):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                client.event('scan.completed')
        client.lines.put(None)
        with self.assertRaisesRegex(RuntimeError, 'exited early'):
            client.receive(0)

    def test_inherited_hardware_and_python_settings_are_not_forwarded(self):
        with patch.dict(gate.os.environ, {'SCANSTUDIO_BRIDGE_CMD': 'physical-bridge',
                                         'SCANSTUDIO_HW_MOTION': '1', 'PYTHONPATH': '/host'}):
            env = gate.isolated_environment(self.root)
        self.assertFalse(any(k.startswith(('SCANSTUDIO_', 'PYTHON')) for k in env))
        self.assertEqual(env['HOME'], str(self.root))

    def test_intel_and_universal_packages_are_refused(self):
        with patch.object(gate.platform, 'system', return_value='Darwin'), \
                patch.object(gate.platform, 'machine', return_value='x86_64'):
            with self.assertRaisesRegex(RuntimeError, 'Apple Silicon'):
                gate.verify_app(self.root)
        with patch.object(gate.platform, 'system', return_value='Darwin'), \
                patch.object(gate.platform, 'machine', return_value='arm64'), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(gate.subprocess, 'run') as run:
            run.return_value.stdout = 'x86_64 arm64\n'
            with self.assertRaisesRegex(RuntimeError, 'arm64 only'):
                gate.verify_app(self.root)


if __name__ == '__main__':
    unittest.main()
