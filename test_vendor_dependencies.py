#!/usr/bin/env python3
"""Dependency regression tests; no compiler, downloads or target kernel load."""
from pathlib import Path
import hashlib
import json
import tempfile
import unittest
import prepare_vendor as vendor


class VendorDependencies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ace2v-vendor-test-')
        self.base = Path(self.temp.name)
        self.kernel = self.base / 'kernel-901'
        self.modules = self.base / 'modules-901'
        (self.kernel / 'init').mkdir(parents=True)
        (self.kernel / 'kernel').mkdir()
        (self.kernel / 'mm').mkdir()
        self.kconfig = b'#ifdef FEATURE\nsource "kernel/oplus_cpu/sched/Kconfig"\n#endif\n'
        (self.kernel / 'Kconfig').write_text('source "init/Kconfig"\n')
        (self.kernel / 'init/Kconfig').write_bytes(self.kconfig)
        target = self.modules / 'vendor/oplus/kernel/cpu/sched'
        target.mkdir(parents=True)
        (target / 'Kconfig').write_text('config OPLUS_TEST\n\tbool\n')
        (self.modules / 'vendor/oplus/kernel/mm').mkdir(parents=True)
        self.manifest = {
            'modules_commit': 'fixture-pinned-commit',
            'kernel_init_kconfig_sha256': hashlib.sha256(self.kconfig).hexdigest(),
            'kernel_links': [
                {'path': 'kernel/oplus_cpu', 'target': '../../vendor/oplus/kernel/cpu'},
                {'path': 'mm/oplus_mm', 'target': '../../vendor/oplus/kernel/mm'},
            ],
            'module_files': [{'path': 'vendor/oplus/kernel/cpu/sched/Kconfig',
                              'sha256': vendor.sha(target / 'Kconfig')}],
        }
        try:
            for item in self.manifest['kernel_links']:
                (self.kernel / item['path']).symlink_to(item['target'], target_is_directory=True)
        except OSError as exc:
            self.skipTest('Host lacks symbolic-link support: ' + str(exc))

    def tearDown(self):
        self.temp.cleanup()

    def test_old_layout_reproduces_screenshot(self):
        audit = vendor.audit_kconfig(self.kernel)
        self.assertEqual(len(audit['missing_sources']), 1)
        self.assertEqual(audit['missing_sources'][0]['source'], 'kernel/oplus_cpu/sched/Kconfig')

    def test_assembled_layout_resolves_and_preserves_source(self):
        before = (self.kernel / 'init/Kconfig').read_bytes()
        report = vendor.assemble(self.kernel, self.modules, self.manifest)
        self.assertEqual(vendor.audit_kconfig(self.kernel)['missing_sources'], [])
        self.assertEqual((self.kernel / 'init/Kconfig').read_bytes(), before)
        self.assertTrue((self.kernel / 'kernel/oplus_cpu/sched/Kconfig').is_file())
        self.assertEqual(vendor.assemble(self.kernel, self.modules, self.manifest), report)

    def test_wrong_vendor_version_stops(self):
        p = self.modules / self.manifest['module_files'][0]['path']
        p.write_text('different source')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            vendor.assemble(self.kernel, self.modules, self.manifest)

    def test_existing_unrelated_vendor_is_preserved(self):
        p = self.kernel.parent / 'vendor'
        p.mkdir()
        keep = p / 'keep.txt'
        keep.write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'Existing vendor path'):
            vendor.assemble(self.kernel, self.modules, self.manifest)
        self.assertEqual(keep.read_text(), 'preserve')

    def test_additional_missing_dependency_is_reported(self):
        vendor.assemble(self.kernel, self.modules, self.manifest)
        p = self.modules / self.manifest['module_files'][0]['path']
        p.write_text('source "kernel/oplus_cpu/sched/absent/Kconfig"\n')
        audit = vendor.audit_kconfig(self.kernel)
        self.assertEqual(len(audit['missing_sources']), 1)
        self.assertEqual(audit['missing_sources'][0]['source'], 'kernel/oplus_cpu/sched/absent/Kconfig')


class PortableChecks(unittest.TestCase):
    def test_comments_do_not_hide_missing_source(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'Kconfig').write_text('#ifdef FEATURE\nsource "missing/Kconfig"\n#endif\n')
            self.assertEqual(vendor.audit_kconfig(root)['missing_sources'][0]['source'], 'missing/Kconfig')

    def test_source_present_and_missing_nested_are_distinguished(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'Kconfig').write_text('source "child/Kconfig"\n')
            (root / 'child').mkdir()
            (root / 'child/Kconfig').write_text('config TEST\n bool\n')
            self.assertEqual(vendor.audit_kconfig(root)['missing_sources'], [])
            (root / 'child/Kconfig').write_text('source "missing/Kconfig"\n')
            self.assertEqual(len(vendor.audit_kconfig(root)['missing_sources']), 1)

    def test_vendor_hash_and_missing_file_fail_before_assembly(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'anchor').write_bytes(b'901')
            manifest = {'module_files': [{'path': 'anchor', 'sha256': vendor.sha(root / 'anchor')}]}
            self.assertEqual(vendor.verify_vendor(root, manifest), root.resolve())
            (root / 'anchor').write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                vendor.verify_vendor(root, manifest)
            manifest['module_files'][0]['path'] = 'missing'
            with self.assertRaisesRegex(ValueError, 'source missing'):
                vendor.verify_vendor(root, manifest)


if __name__ == '__main__':
    unittest.main(verbosity=2)
