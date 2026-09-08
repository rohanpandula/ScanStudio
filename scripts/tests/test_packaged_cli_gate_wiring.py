import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class PackagedCLIGateWiringError(AssertionError):
    pass


def source(path):
    lines = path.read_text().splitlines()
    return '\n'.join(line for line in lines if not line.lstrip().startswith('#'))


class PackagedCLIGateWiringTests(unittest.TestCase):
    def require(self, path, token):
        text = source(ROOT / path)
        if token not in text:
            raise PackagedCLIGateWiringError(f'{path} is missing {token}')

    def test_packaged_bridge_invokes_gate_and_checks_cli(self):
        path = 'app/ScanStudio/scripts/test_packaged_bridge.sh'
        self.require(path, 'verify_mac_acceptance.py')
        self.require(path, 'scanstudio-cli')
        self.require(path, 'TeamIdentifier')

    def test_packaging_builds_installs_and_signs_cli_before_bundle(self):
        text = source(ROOT / 'app/ScanStudio/scripts/package_app.sh')
        self.assertRegex(text, r'swift build -c release[\s\\]')
        self.assertIn('.build/release/scanstudio-cli', text)
        signing = re.search(
            r'codesign --force --sign\b(?:(?!\ncodesign).)*Contents/MacOS/scanstudio-cli',
            text,
            re.DOTALL,
        )
        self.assertIsNotNone(signing, 'package_app.sh does not explicitly sign scanstudio-cli')
        bundle = text.index('codesign --force --deep --sign')
        self.assertLess(signing.start(), bundle)
        self.assertIn('codesign --verify --strict "$staged_app/Contents/MacOS/scanstudio-cli"', text)

    def test_packaging_resolves_argument_parser_version_and_license(self):
        text = source(ROOT / 'app/ScanStudio/scripts/package_app.sh')
        self.assertIn('json.load(stream)', text)
        self.assertIn('$swift_argument_parser_version', text)
        self.assertIn('.build/checkouts/swift-argument-parser/LICENSE.txt', text)
        self.assertIn('swift-argument-parser-Apache-2.0.txt', text)

    def test_make_package_keeps_both_packaging_steps(self):
        text = source(ROOT / 'app/ScanStudio/Makefile')
        self.assertIn('package_app.sh', text)
        self.assertIn('test_packaged_bridge.sh', text)

    def test_ci_and_release_reach_make_package(self):
        for workflow in ('.github/workflows/ci.yml', '.github/workflows/release.yml'):
            self.require(workflow, 'make package')


if __name__ == '__main__':
    unittest.main()
