#!/usr/bin/env python3
"""Verify a real unstripped 901-source experimental build. Never repairs ELF bytes."""
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def read_config(path):
    values = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:-11]] = "n"
    return values


def verify(module, symvers, config):
    from elftools.elf.elffile import ELFFile
    target = json.loads((HERE / "target.json").read_text(encoding="utf-8"))
    data = Path(module).read_bytes()
    cfg = read_config(config)
    captured = read_config(HERE / "captured.config")
    required = ["CONFIG_MODVERSIONS", "CONFIG_CFI_CLANG", "CONFIG_CFI_CLANG_SHADOW",
                "CONFIG_LTO_CLANG_FULL", "CONFIG_DEBUG_INFO", "CONFIG_DEBUG_INFO_DWARF4",
                "CONFIG_SMP", "CONFIG_PREEMPT", "CONFIG_COMPAT", "CONFIG_ARM64_4K_PAGES"]
    for key in required:
        if cfg.get(key) != "y" or captured.get(key) != "y":
            raise ValueError("required captured configuration not preserved: " + key)
    for key in ["CONFIG_CFI_PERMISSIVE", "CONFIG_GCC_PLUGIN_RANDSTRUCT", "CONFIG_RANDSTRUCT_FULL"]:
        if cfg.get(key, "n") != "n":
            raise ValueError("unsupported configuration: " + key)
    exports = {}
    for line in Path(symvers).read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) >= 4:
            crc, name = int(fields[0], 16), fields[1]
            if name in exports and exports[name] != crc:
                raise ValueError("conflicting build symvers: " + name)
            exports[name] = crc
    if not exports:
        raise ValueError("empty Module.symvers; modules_prepare alone is insufficient")
    with Path(module).open("rb") as stream:
        elf = ELFFile(stream)
        if elf.header["e_machine"] != "EM_AARCH64" or elf.elfclass != 64 or not elf.little_endian:
            raise ValueError("expected little-endian AArch64 ELF")
        if elf.header["e_type"] != "ET_REL":
            raise ValueError("expected kernel module relocatable ELF")
        info = elf.get_section_by_name(".modinfo")
        if info is None:
            raise ValueError("missing .modinfo")
        modinfo = {}
        for raw in info.data().split(b"\0"):
            if b"=" in raw:
                key, value = raw.decode("utf-8").split("=", 1)
                modinfo.setdefault(key, []).append(value)
        def one(key):
            values = modinfo.get(key, [])
            if len(values) != 1:
                raise ValueError("expected one modinfo value: " + key)
            return values[0]
        if one("name") != "cpuinfo_spoof" or one("version") != target["revision"]:
            raise ValueError("wrong module name/revision")
        vermagic = one("vermagic")
        if vermagic.split()[0] != target["target_release"]:
            raise ValueError("wrong target release")
        if not {"SMP", "preempt", "mod_unload", "modversions", "aarch64"}.issubset(set(vermagic.split())):
            raise ValueError("incomplete vermagic flags")
        if one("source_basis") != "PHP110_901_EXPERIMENTAL" or one("source_commit") != target["source_commit"]:
            raise ValueError("source basis metadata mismatch")
        namespace = "VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver"
        if namespace not in modinfo.get("import_ns", []):
            raise ValueError("missing VFS namespace declaration")
        symbols = elf.get_section_by_name(".symtab")
        if symbols is None:
            raise ValueError("unstripped .symtab required")
        all_symbols = list(symbols.iter_symbols())
        undefined = sorted({s.name for s in all_symbols if s.name and s["st_shndx"] == "SHN_UNDEF"})
        versions_section = elf.get_section_by_name("__versions")
        if versions_section is None or not versions_section.data():
            raise ValueError("MODVERSIONS entries missing")
        raw = versions_section.data()
        if len(raw) % 64:
            raise ValueError("unexpected AArch64 modversion record size")
        versions = {}
        for offset in range(0, len(raw), 64):
            crc = struct.unpack_from("<Q", raw, offset)[0]
            name = raw[offset+8:offset+64].split(b"\0", 1)[0].decode("ascii")
            if not name or name in versions or crc > 0xffffffff:
                raise ValueError("invalid module version record")
            versions[name] = crc
        for name in set(undefined) | {"module_layout"}:
            if name not in versions:
                raise ValueError("no module CRC for import: " + name)
        for name, crc in versions.items():
            if name not in exports or exports[name] != crc:
                raise ValueError("CRC mismatch against this 901 build: " + name)
        sample_path = HERE / "sample_crc.json"
        sample_crc = json.loads(sample_path.read_text(encoding="utf-8"))
        overlap = {}
        for name, crc in versions.items():
            if name in sample_crc:
                if crc != int(sample_crc[name], 16):
                    raise ValueError("CRC conflicts with captured 1301 vendor sample: " + name)
                overlap[name] = sample_crc[name]
        # Keep material layout evidence even though this is explicitly experimental.
        candidates = [s for s in all_symbols if s.name == "php110_layout_values"]
        if len(candidates) != 1:
            raise ValueError("missing compiled 901 layout symbol")
        symbol = candidates[0]
        names = target["layout_names"]
        if symbol["st_size"] != 8 * len(names) or not isinstance(symbol["st_shndx"], int):
            raise ValueError("compiled layout record size mismatch")
        section = elf.get_section(symbol["st_shndx"])
        offset = symbol["st_value"] - section["sh_addr"]
        values = struct.unpack_from("<" + "Q" * len(names), section.data(), offset)
        layout = dict(zip(names, values))
        if layout["proc_inode_pde_offset"] >= layout["proc_inode_vfs_offset"]:
            raise ValueError("unexpected proc_inode layout")
        if layout["pde_ops_offset"] + 8 > layout["pde_size"]:
            raise ValueError("invalid PDE slot bounds")
        if not elf.has_dwarf_info():
            raise ValueError("DWARF required: keep the unstripped module")
        dwarf = elf.get_dwarf_info()
        def type_name(die):
            if die is None:
                return "void"
            if die.tag in ("DW_TAG_typedef", "DW_TAG_const_type", "DW_TAG_volatile_type", "DW_TAG_restrict_type"):
                return type_name(die.get_DIE_from_attribute("DW_AT_type"))
            if die.tag == "DW_TAG_pointer_type":
                return type_name(die.get_DIE_from_attribute("DW_AT_type") if "DW_AT_type" in die.attributes else None) + " *"
            name = die.attributes.get("DW_AT_name")
            name = name.value.decode() if name else die.tag
            if name in ("long long", "long long int", "long int", "long") and die.attributes.get("DW_AT_byte_size") and die.attributes["DW_AT_byte_size"].value == 8:
                return "s64"
            return name
        expected = {
            "fake_available": ["cpufreq_policy *", "char *"],
            "fake_cpu_mask": ["device *", "device_attribute *", "char *"],
            "fake_topology": ["device *", "device_attribute *", "char *"],
            "fake_cpuinfo_open": ["inode *", "file *"],
            "fake_cpuinfo_show": ["seq_file *", "void *"],
            "fake_cpuinfo_start": ["seq_file *", "s64 *"],
            "fake_cpuinfo_next": ["seq_file *", "void *", "s64 *"],
            "fake_cpuinfo_stop": ["seq_file *", "void *"],
        }
        found = {}
        for cu in dwarf.iter_CUs():
            for die in cu.iter_DIEs():
                if die.tag != "DW_TAG_subprogram":
                    continue
                name = die.attributes.get("DW_AT_name")
                if not name:
                    continue
                name = name.value.decode(errors="replace")
                if name not in expected:
                    continue
                children = [c for c in die.iter_children() if c.tag == "DW_TAG_formal_parameter"]
                if not children or any("DW_AT_type" not in c.attributes for c in children):
                    continue
                args = [type_name(c.get_DIE_from_attribute("DW_AT_type")) for c in children]
                if args != expected[name]:
                    raise ValueError(f"callback ABI mismatch: {name}: {args}")
                found[name] = args
        if set(found) != set(expected):
            raise ValueError("missing callback DWARF: " + ", ".join(sorted(set(expected) - set(found))))
        cfi = any(s.name == "__cfi_check" or s.name.startswith("__cfi_check.") for s in all_symbols)
        if not cfi:
            raise ValueError("Clang CFI check symbol missing")
    differences = {key: {"captured_1301": captured.get(key), "experimental_901_build": cfg.get(key)}
                   for key in sorted(set(captured) | set(cfg)) if captured.get(key) != cfg.get(key)}
    return {"file": Path(module).name, "revision": target["revision"], "target_id": target["target_id"],
            "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "vermagic": vermagic,
            "source_basis": "PHP110_901_EXPERIMENTAL", "source_commit": target["source_commit"],
            "source_firmware": target["source_firmware"], "target_firmware": target["target_firmware"],
            "callbacks": found, "dwarf": "passed", "cfi": "present", "layouts_from_901_build": layout,
            "import_namespaces": modinfo.get("import_ns", []),
            "build_crc_entries": {key: f"0x{value:08x}" for key, value in versions.items()},
            "crc_against_901_generated_symvers": "passed", "crc_overlap_with_1301_samples": overlap,
            "target_1301_full_crc_proof": False, "private_layout_1301_verified": False,
            "config_differences": differences, "runtime": "not tested"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--symvers", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        report = verify(args.module, args.symvers, args.config)
        Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
    except Exception as exc:
        raise SystemExit("verification failed: " + str(exc))


if __name__ == "__main__":
    main()
