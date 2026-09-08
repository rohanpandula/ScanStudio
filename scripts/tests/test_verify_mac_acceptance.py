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

    def test_gate_socket_is_private_and_bounded(self):
        for _ in range(20):
            directory, socket_path = gate._gate_socket_directory()
            try:
                self.assertTrue(str(socket_path).startswith('/tmp/'))
                self.assertNotEqual(socket_path.parent, Path('/tmp'))
                self.assertLess(len(str(socket_path).encode()), 104)
                self.assertTrue(directory.is_dir())
            finally:
                directory.rmdir()

    def test_cli_json_reports_exit_and_output_context(self):
        completed = type('Completed', (), {'returncode': 1, 'stdout': 'bad', 'stderr': 'diagnostic'})()
        with patch.object(gate.subprocess, 'run', return_value=completed):
            with self.assertRaisesRegex(RuntimeError, 'scanstudio-cli.*stdout.*bad.*stderr.*diagnostic'):
                gate._cli_json(Path('/tmp/scanstudio-cli'), Path('/tmp/s.sock'), self.root, 'status')
            self.assertEqual(gate.subprocess.run.call_args.args[0],
                             ['/tmp/scanstudio-cli', 'status', '--socket', '/tmp/s.sock'])
            self.assertEqual(gate.subprocess.run.call_args.kwargs['env'], gate.isolated_environment(self.root))

    def test_non_simulator_device_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'real-device'):
            gate._require_simulator_devices({'result': {'devices': [{'deviceId': 'real-device'}]}})

    def test_bundle_engine_pid_check_ignores_other_engine_paths(self):
        output = ' 11 /Applications/Other.app/Contents/MacOS/scanstudio-engine\n 22 /tmp/Test App/scanstudio-engine --flag\n'
        completed = type('Completed', (), {'stdout': output})()
        with patch.object(gate.subprocess, 'run', return_value=completed):
            self.assertEqual(gate._bundle_engine_pids(Path('/tmp/Test App/scanstudio-engine')), {22})

    def test_cli_acceptance_stops_partial_batch_before_bounded_resume(self):
        cli = self.root / 'ScanStudio.app/Contents/MacOS/scanstudio-cli'
        cli.parent.mkdir(parents=True)
        cli.write_bytes(b'packaged cli')
        runtime = self.root / 'python3.13'
        calls = []
        statuses = iter([
            {'mode': 'attach-headless', 'hostPid': 42, 'result': {}},
            {'result': {'previewComplete': True}},
            {'result': {'jobId': 'job-1', 'jobState': 'scanning', 'pendingFrames': [2, 3, 4, 5, 6]}},
            {'result': {'jobId': None, 'jobState': 'stopped', 'pendingFrames': [2, 3, 4, 5, 6]}},
            {'result': {'previewComplete': True}},
        ])
        roll = self.root / 'packaged-roll'
        roll.mkdir()

        def cli_json(_cli, socket_path, _root, *arguments, expect_exit=0):
            calls.append((arguments, expect_exit, socket_path))
            if arguments[:2] == ('host', '--detach'):
                Path(arguments[-1]).touch()
                Path(f'{socket_path}.pid').touch()
                return {'result': {'hostPid': 42, 'logPath': arguments[-1]}}
            if arguments == ('status',):
                return next(statuses)
            if arguments == ('rescan',):
                return {'result': {'devices': [{'deviceId': 'sim-ls5000-0'}]}}
            if arguments == ('frames', 'list'):
                return {'result': {'frames': [{'index': index} for index in range(1, 7)]}}
            if arguments[:2] == ('roll', 'save'):
                return {'result': {'projectDirectory': str(roll)}}
            if arguments[:1] == ('resume',):
                return {'result': {'jobState': 'completed'}}
            if arguments == ('eject',) and expect_exit == 77:
                return {'error': {'code': 'CONFIRMATION_REQUIRED'}}
            return {'result': {}}

        preserved = {str(roll.resolve() / 'archive'): ['hash', 1, 2, 3]}
        snapshots = {**preserved, str(roll.resolve() / 'positive'): ['hash2', 1, 3, 4]}
        receipt_results = [({}, preserved, []), ({}, snapshots, [])]
        with patch.object(gate, '_cli_json', side_effect=cli_json), \
                patch.object(gate, '_bundle_engine_pids', side_effect=[{900}, {900, 901}, {900}]), \
                patch.object(gate, 'verify_receipts', side_effect=receipt_results) as verify, \
                patch.object(gate, 'decode_images'), patch.object(gate.time, 'sleep'):
            report = gate.cli_acceptance(cli, runtime, self.root)

        commands = [arguments for arguments, _, _ in calls]
        self.assertIn('--simulator', commands[0])
        save = next(command for command in commands if command[:2] == ('roll', 'save'))
        self.assertNotIn('--wait', save)
        self.assertLess(commands.index(save), commands.index(('stop',)))
        self.assertIn(('status',), commands[commands.index(save) + 1:commands.index(('stop',))])
        refresh = ('preview', '--film-loaded', '--intent', 'refreshSavedProject')
        self.assertLess(commands.index(('stop',)), commands.index(refresh))
        self.assertLess(commands.index(refresh), commands.index(('resume', '--confirm-motion', '--wait')))
        self.assertLess(commands.index(('eject',)), commands.index(('eject', '--confirm-motion')))
        self.assertLess(commands.index(('frames', 'exclude', '6')), commands.index(('frames', 'include', '6')))
        self.assertEqual(verify.call_args_list[0].args[1], [1])
        self.assertEqual(verify.call_args_list[1].args[1], list(range(1, 7)))
        self.assertEqual(report['outputs'][str(Path('positive'))]['sha256'], 'hash2')
        self.assertFalse(calls[0][2].parent.exists())


if __name__ == '__main__':
    unittest.main()
