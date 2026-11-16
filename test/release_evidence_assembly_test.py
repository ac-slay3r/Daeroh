"""Assembly consumes actual generator encoding, never changes JSON values."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/release'))
import validate_evidence_archive as validator


class EvidenceAssemblyTest(unittest.TestCase):
    def fixture(self, root):
        source = root / 'inputs'
        for relative in validator.REQUIRED_FILES:
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({'encoding': ['indented', 1, True, None]}, indent=2) + '\n')
        return source

    def invoke(self, source, output):
        return subprocess.run([sys.executable, str(ROOT / 'tool/release/assemble_evidence_archive.py'), '--input-directory', str(source), '--output-directory', str(output)], capture_output=True, text=True)

    def test_canonical_values_and_deterministic_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.fixture(root)
            for name in ('first', 'second'):
                result = self.invoke(source, root / name)
                self.assertEqual(result.returncode, 0, result.stderr)
            first = root / 'first/hermes-console-release-evidence.tar.gz'
            self.assertEqual(first.read_bytes(), (root / 'second' / first.name).read_bytes())
            with tarfile.open(first) as archive:
                names = archive.getnames()
                self.assertEqual(names, sorted(names))
                for member in archive:
                    self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 0))
                    self.assertTrue(member.isfile() or member.isdir())
                for relative in validator.REQUIRED_FILES:
                    raw = archive.extractfile('release-evidence/' + relative).read()
                    self.assertEqual(json.loads(raw), json.loads((source / relative).read_bytes()))
                    self.assertEqual(raw, (json.dumps(json.loads(raw), sort_keys=True, separators=(',', ':')) + '\n').encode())
                sums = validator.parse_manifest(archive.extractfile('release-evidence/SHA256SUMS').read())
                for relative, digest in sums.items():
                    self.assertEqual(digest, hashlib.sha256(archive.extractfile('release-evidence/' + relative).read()).hexdigest())

    def test_value_changes_are_not_hidden_and_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.fixture(root)
            self.assertEqual(self.invoke(source, root / 'first').returncode, 0)
            path = source / 'rebuild-comparison.json'
            path.write_text('{"changed":true}')
            self.assertEqual(self.invoke(source, root / 'second').returncode, 0)
            name = 'hermes-console-release-evidence.tar.gz'
            self.assertNotEqual((root / 'first' / name).read_bytes(), (root / 'second' / name).read_bytes())
            before = (root / 'first' / name).read_bytes()
            self.assertEqual(self.invoke(source, root / 'first').returncode, 1)
            self.assertEqual((root / 'first' / name).read_bytes(), before)

    def test_bad_inputs_fail_closed(self):
        for case in ('missing', 'extra', 'invalid', 'duplicate-key', 'symlink', 'extra-directory', 'nan'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = self.fixture(root)
                path = source / 'rebuild-comparison.json'
                if case == 'missing':
                    path.unlink()
                elif case == 'extra':
                    (source / 'unexpected.json').write_text('{}')
                elif case == 'extra-directory':
                    (source / 'unexpected').mkdir()
                elif case == 'symlink':
                    path.unlink()
                    path.symlink_to(source / next(x for x in validator.REQUIRED_FILES if x != path.name))
                else:
                    path.write_text({'invalid': '{', 'duplicate-key': '{"a":1,"a":2}', 'nan': '{"a":NaN}'}[case])
                result = self.invoke(source, root / 'output')
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('assembly', result.stderr)
                self.assertFalse((root / 'output').exists())


class ValidatorDiagnosticsTest(unittest.TestCase):
    def test_five_archive_json_failures_name_stage_and_member(self):
        import io
        import validate_public_apk_provenance as provenance
        name = 'release-evidence/artifacts/full/app-x86_64-full-release/fullRelease.license-review.json'
        for case, raw, reason in (
            ('missing', None, 'missing'),
            ('empty', b'', 'size'),
            ('nul', b'{"a":"\x00"}', 'NUL'),
            ('invalid', b'{', 'invalid JSON'),
            ('indented', b'{\n  "a": 1\n}\n', 'not canonical JSON'),
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / 'fixture.tar'
                with tarfile.open(path, 'w') as archive:
                    if raw is not None:
                        member = tarfile.TarInfo(name)
                        member.size = len(raw)
                        archive.addfile(member, io.BytesIO(raw))
                with tarfile.open(path) as archive:
                    with self.assertRaises(provenance.ProvenanceError) as raised:
                        provenance.read_archive_json(archive, name)
                self.assertIn('archive JSON', str(raised.exception))
                self.assertIn(name, str(raised.exception))
                self.assertIn(reason, str(raised.exception))


if __name__ == '__main__':
    unittest.main()
