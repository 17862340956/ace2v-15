#!/usr/bin/env python3
"""Verify pinned 901 vendor sources and assemble the official external vendor link."""
import argparse
import glob
import hashlib
import json
import os
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_vendor(modules, manifest):
    modules = Path(modules).resolve()
    for item in manifest['module_files']:
        p = modules / item['path']
        if not p.is_file():
            raise ValueError('901 vendor source missing: ' + str(p))
        if sha(p) != item['sha256']:
            raise ValueError('901 vendor source hash mismatch: ' + item['path'])
    return modules


def assemble(kernel, modules, manifest):
    kernel = Path(kernel).resolve()
    modules = verify_vendor(modules, manifest)
    init = kernel / 'init/Kconfig'
    if sha(init) != manifest['kernel_init_kconfig_sha256']:
        raise ValueError('Pinned 901 init/Kconfig hash mismatch')
    for item in manifest['kernel_links']:
        p = kernel / item['path']
        if not p.is_symlink() or os.readlink(p) != item['target']:
            raise ValueError('Expected original vendor symlink: ' + str(p))
    # The original links use ../../vendor/...; vendor must be beside kernel source.
    target = modules / 'vendor'
    if not target.is_dir():
        raise ValueError('Modules repository vendor directory missing')
    dest = kernel.parent / 'vendor'
    if os.path.lexists(dest):
        if dest.resolve() != target.resolve():
            raise ValueError('Existing vendor path points elsewhere; keeping it unchanged: ' + str(dest))
    else:
        dest.symlink_to(target, target_is_directory=True)
    for item in manifest['module_files']:
        expected = modules / item['path']
        # Verify the exact source path from the user's failure resolves correctly.
        if item['path'].startswith('vendor/oplus/kernel/cpu/'):
            linked = kernel / 'kernel/oplus_cpu' / item['path'].split('vendor/oplus/kernel/cpu/', 1)[1]
            if not linked.is_file() or sha(linked) != sha(expected):
                raise ValueError('Oplus source link did not resolve: ' + str(linked))
    return {'vendor_path': str(dest), 'resolved_vendor': str(dest.resolve()),
            'modules_commit': manifest['modules_commit'],
            'module_files': manifest['module_files']}


def audit_kconfig(kernel):
    """Traverse literal Kconfig source directives; comments (#ifdef) are not conditions."""
    kernel = Path(kernel).resolve()
    pending = [kernel / 'Kconfig']
    seen = set()
    missing = []
    unresolved = []
    directives = re.compile(r'^\s*(source|rsource|osource|orsource)\s+[\"\']([^\"\']+)[\"\']')
    while pending:
        p = pending.pop()
        resolved = p.resolve()
        if resolved in seen:
            continue
        if len(seen) >= 20000:
            raise ValueError('Kconfig traversal limit exceeded')
        seen.add(resolved)
        if not p.is_file():
            missing.append({'file': str(p), 'reason': 'missing entry'})
            continue
        text = p.read_text(encoding='utf-8', errors='replace')
        for number, line in enumerate(text.splitlines(), 1):
            m = directives.match(line)
            if not m:
                continue
            kind, name = m.groups()
            for variable, value in [('SRCARCH', 'arm64'), ('ARCH', 'arm64'), ('srctree', str(kernel))]:
                name = name.replace('$(' + variable + ')', value).replace('${' + variable + '}', value)
                name = name.replace('$' + variable, value)
            if '$' in name:
                unresolved.append({'file': str(p), 'line': number, 'directive': line.strip()})
                continue
            base = p.parent if kind in ('rsource', 'orsource') else kernel
            full = base / name
            paths = [Path(x) for x in glob.glob(str(full))] if glob.has_magic(str(full)) else [full]
            paths = [x for x in paths if x.is_file()]
            if not paths and kind not in ('osource', 'orsource'):
                missing.append({'file': str(p), 'line': number, 'source': name})
            pending.extend(paths)
    return {'files_checked': len(seen), 'missing_sources': missing,
            'unresolved_variable_sources': unresolved}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', required=True, type=Path)
    parser.add_argument('--modules', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads((Path(__file__).parent / 'vendor_reference.json').read_text(encoding='utf-8'))
    try:
        report = assemble(args.kernel, args.modules, manifest)
        report['kconfig'] = audit_kconfig(args.kernel)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if report['kconfig']['missing_sources']:
            for item in report['kconfig']['missing_sources'][:20]:
                print('Missing Kconfig source:', item)
            raise ValueError('Kconfig source dependency preflight failed; see ' + str(args.output))
        print('901 vendor sources assembled and verified; Kconfig files:', report['kconfig']['files_checked'])
        if report['kconfig']['unresolved_variable_sources']:
            print('Variable Kconfig expressions left to actual olddefconfig:', len(report['kconfig']['unresolved_variable_sources']))
    except (ValueError, OSError) as exc:
        raise SystemExit('vendor source preparation failed: ' + str(exc))


if __name__ == '__main__':
    main()
