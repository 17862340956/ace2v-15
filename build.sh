#!/usr/bin/env bash
# PHP110 / MT6983 / 5.10.226 experimental builder.
# Baseline: OnePlusOSS/android_kernel_5.10_oneplus_mt6983
#           commit cd19560616750906a568aa271d8b49ac17f13914 (PHP110 15.0.0.901)
# This produces an experiment for the PHP110 1301 target; it is not an OEM build.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly ROOT
readonly SOURCE_COMMIT="cd19560616750906a568aa271d8b49ac17f13914"
readonly SOURCE_URL="https://github.com/OnePlusOSS/android_kernel_5.10_oneplus_mt6983/archive/${SOURCE_COMMIT}.tar.gz"
readonly CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/clang-r416183b.tar.gz"
readonly TARGET_RELEASE="5.10.226-android12-9-o-g104a939c0e3e"
readonly TARGET_BASE="5.10.226"
readonly TARGET_CLANG="clang-r416183b"
readonly BUILD_ID="php110-901-buildfix-r2"
readonly MODULES_COMMIT="749b101b1a1487f1b1f8a5b4b3319e7ba6ed0a5d"
readonly MODULES_URL="https://codeload.github.com/OnePlusOSS/android_kernel_modules_oneplus_mt6983/tar.gz/${MODULES_COMMIT}"
readonly JOBS="${QILIN_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

CACHE_ROOT=${QILIN_CACHE_DIR:-"$ROOT/.cache"}
WORK_ROOT=${QILIN_BUILD_DIR:-"$ROOT/build"}
DIST="$ROOT/dist"
LOGS="$WORK_ROOT/logs"
SRC_DIR=${QILIN_KERNEL_DIR:-}
CLANG_DIR=${QILIN_CLANG_DIR:-}
archive=''
clang_archive=''
modules_archive=''
MODULES_DIR=${QILIN_MODULES_DIR:-}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mkdir -p "$CACHE_ROOT" "$WORK_ROOT"
[ ! -e "$DIST" ] || fail "dist 已存在；为保留旧证据，请在新的源码包目录构建，或先保留并另存旧 dist。"
mkdir -p "$DIST"
RUN_ROOT=$(mktemp -d "$WORK_ROOT/run.XXXXXX")
KOUT="$RUN_ROOT/kernel-out"
LOGS="$RUN_ROOT/logs"
mkdir -p "$LOGS"
LOG="$LOGS/build.log"
exec > >(tee -a "$LOG") 2>&1

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup_on_error() { rc=$?; if [ "$rc" -ne 0 ]; then printf 'FAILED exit=%s; first actionable error is above.\n' "$rc" >&2; fi; }
trap cleanup_on_error EXIT
trap 'printf "ERROR: command failed at %s:%s: %s\n" "${BASH_SOURCE[0]}" "${LINENO}" "$BASH_COMMAND" >&2' ERR

[ "$(uname -s)" = Linux ] || fail '需要 Linux x86_64；当前环境不是 Linux。'
[ "$(uname -m)" = x86_64 ] || fail '需要 Linux x86_64；当前架构不是 x86_64。'
for tool in awk cmp cp curl find grep make mkdir mktemp python3 sha256sum tar tr; do command -v "$tool" >/dev/null 2>&1 || fail "缺少构建工具：$tool"; done
for tool in aarch64-linux-gnu-ld aarch64-linux-gnu-as arm-linux-gnueabi-ld; do command -v "$tool" >/dev/null 2>&1 || fail "缺少交叉工具：$tool"; done
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-arm-linux-gnueabi-}"
[ -f "$ROOT/captured.config" ] || fail "缺少目标配置：$ROOT/captured.config"
[ -f "$ROOT/Makefile" ] || fail "缺少外部模块 Makefile：$ROOT/Makefile"
[ -f "$ROOT/cpuinfo_spoof.c" ] || fail "缺少外部模块源文件：$ROOT/cpuinfo_spoof.c"
[ -f "$ROOT/verify_module.py" ] || fail "缺少验证器：$ROOT/verify_module.py"
[ -f "$ROOT/verify_source.py" ] || fail "缺少源码验证器：$ROOT/verify_source.py"
[ -f "$ROOT/source_reference.json" ] || fail "缺少源码参考清单：$ROOT/source_reference.json"
[ -f "$ROOT/run.sh" ] || fail "缺少手机入口：$ROOT/run.sh"

resolve_clang() {
    local c="$1"
    if [ -x "$c/bin/clang" ]; then printf '%s\n' "$c"; return 0; fi
    if [ -x "$c/clang" ] && [ -x "$c/ld.lld" ]; then printf '%s\n' "$(dirname -- "$c")"; return 0; fi
    return 1
}
verify_clang() {
    local c="$1" version
    [ -x "$c/bin/clang" ] || fail "QILIN_CLANG_DIR 缺少 bin/clang：$c"
    [ -x "$c/bin/ld.lld" ] || fail "QILIN_CLANG_DIR 缺少 bin/ld.lld：$c"
    version=$("$c/bin/clang" --version 2>&1 | head -n 1) || fail '无法读取 clang 版本。'
    printf 'clang=%s\n' "$version"
    printf '%s\n' "$version" | grep -q 'clang version 12\.0\.5' || fail "clang 版本不是 12.0.5：$version"
    printf '%s\n' "$version" | grep -q 'based on r416183b' || fail "clang 构建标识不是 r416183b：$version"
    [ -x "$c/bin/clang" ]
}

validate_url() {
    local url="$1" code
    code=$(curl -fsSLI --max-time 60 --retry 2 --retry-delay 2 -o /dev/null -w '%{http_code}' "$url") || fail "固定 URL 无法验证：$url"
    case "$code" in 2??|3??) printf 'URL_OK %s HTTP=%s\n' "$url" "$code" ;; *) fail "固定 URL 返回 HTTP $code：$url" ;; esac
}

download_once() {
    local url="$1" dst="$2" tmp
    tmp=$(mktemp "$dst.tmp.XXXXXX")
    trap 'rm -f -- "$tmp"' RETURN
    validate_url "$url"
    curl -fL --retry 2 --retry-delay 2 --connect-timeout 30 --max-time 3600 "$url" -o "$tmp" || fail "下载失败：$url"
    [ -s "$tmp" ] || fail "下载结果为空：$url"
    mv -f -- "$tmp" "$dst"
    trap - RETURN
}

if [ -n "$SRC_DIR" ]; then
    SRC_DIR=$(CDPATH= cd -- "$SRC_DIR" && pwd -P)
    [ -f "$SRC_DIR/Makefile" ] || fail "QILIN_KERNEL_DIR 不是内核源码目录：$SRC_DIR"
    if [ -d "$SRC_DIR/.git" ]; then
        command -v git >/dev/null 2>&1 || fail '复用 git 源码目录时缺少 git。'
        actual=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null) || fail '无法读取内核源码提交。'
        [ "$actual" = "$SOURCE_COMMIT" ] || fail "源码提交不匹配：$actual"
    elif [ -f "$SRC_DIR/.qilin-source-commit" ]; then
        actual=$(tr -d '[:space:]' < "$SRC_DIR/.qilin-source-commit")
        [ "$actual" = "$SOURCE_COMMIT" ] || fail "源码标记提交不匹配：$actual"
    else
        fail '复用 QILIN_KERNEL_DIR 必须有 git HEAD 或 .qilin-source-commit 的固定提交证明。'
    fi
else
    archive="$CACHE_ROOT/kernel-${SOURCE_COMMIT}.tar.gz"
    [ -s "$archive" ] || download_once "$SOURCE_URL" "$archive"
    actual_archive_sha=$(sha256sum "$archive" | awk '{print $1}')
    SRC_DIR="$WORK_ROOT/kernel-${SOURCE_COMMIT}"
    if [ ! -f "$SRC_DIR/Makefile" ]; then
        [ ! -e "$SRC_DIR" ] || fail "源码目录存在但不完整；为保留半成品证据，不自动删除：$SRC_DIR"
        mkdir -p "$SRC_DIR"
        tar -xzf "$archive" --strip-components=1 -C "$SRC_DIR"
        printf '%s\n' "$SOURCE_COMMIT" > "$SRC_DIR/.qilin-source-commit"
    fi
    printf 'source_archive_sha256=%s\n' "$actual_archive_sha" > "$WORK_ROOT/source_archive.sha256"
fi

[ -f "$SRC_DIR/Makefile" ] || fail "源码缺少 Makefile：$SRC_DIR"
version=$(awk -F= '/^VERSION[[:space:]]*=/{v=$2} /^PATCHLEVEL[[:space:]]*=/{p=$2} /^SUBLEVEL[[:space:]]*=/{s=$2} END{gsub(/[[:space:]]/,"",v);gsub(/[[:space:]]/,"",p);gsub(/[[:space:]]/,"",s);print v "." p "." s}' "$SRC_DIR/Makefile")
[ "$version" = "$TARGET_BASE" ] || fail "源码基础版本不匹配：$version"
[ -f "$SRC_DIR/build.config.common" ] || fail '源码缺少 build.config.common。'
grep -q 'clang-r416183b' "$SRC_DIR/build.config.common" || fail '源码工具链基线不是 clang-r416183b。'
python3 "$ROOT/verify_source.py" "$SRC_DIR"

# The kernel repository deliberately contains symlinks outside its own root:
# kernel/oplus_cpu -> ../../vendor/oplus/kernel/cpu (and mm/oplus_mm likewise).
# Kconfig source statements are parsed even when surrounded by #ifdef comments.
# Restore the same-release official vendor repository before olddefconfig.
if [ -n "$MODULES_DIR" ]; then
    MODULES_DIR=$(CDPATH= cd -- "$MODULES_DIR" && pwd -P)
    if [ -d "$MODULES_DIR/.git" ]; then
        command -v git >/dev/null 2>&1 || fail '复用配套git源码目录时缺少git。'
        actual=$(git -C "$MODULES_DIR" rev-parse HEAD)
        [ "$actual" = "$MODULES_COMMIT" ] || fail "配套模块源码提交不匹配：$actual"
    else
        [ -f "$MODULES_DIR/.qilin-modules-commit" ] || fail '配套源码缺少固定提交标记。'
        actual=$(tr -d '[:space:]' < "$MODULES_DIR/.qilin-modules-commit")
        [ "$actual" = "$MODULES_COMMIT" ] || fail "配套模块源码标记不匹配：$actual"
    fi
else
    modules_archive="$CACHE_ROOT/modules-${MODULES_COMMIT}.tar.gz"
    [ -s "$modules_archive" ] || download_once "$MODULES_URL" "$modules_archive"
    # This exact official archive was independently downloaded and inspected.
    printf '%s  %s\n' '8a09d075536b8b6dec4ae5d3957b32890243ee4c1aca5963c5b85986c7fcd1d0' "$modules_archive" | sha256sum -c -
    MODULES_DIR="$WORK_ROOT/modules-${MODULES_COMMIT}"
    if [ ! -f "$MODULES_DIR/.qilin-modules-commit" ]; then
        [ ! -e "$MODULES_DIR" ] || fail "配套源码目录存在但不完整，保留现场：$MODULES_DIR"
        mkdir -p "$MODULES_DIR"
        tar -xzf "$modules_archive" --strip-components=1 -C "$MODULES_DIR"
        printf '%s\n' "$MODULES_COMMIT" > "$MODULES_DIR/.qilin-modules-commit"
    fi
fi
python3 "$ROOT/prepare_vendor.py" --kernel "$SRC_DIR" --modules "$MODULES_DIR" --output "$LOGS/vendor_dependencies.json"

if [ -n "$CLANG_DIR" ]; then
    CLANG_DIR=$(CDPATH= cd -- "$CLANG_DIR" && pwd -P)
else
    clang_archive="$CACHE_ROOT/clang-${TARGET_CLANG}.tar.gz"
    [ -s "$clang_archive" ] || download_once "$CLANG_URL" "$clang_archive"
    actual_clang_sha=$(sha256sum "$clang_archive" | awk '{print $1}')
    CLANG_DIR="$WORK_ROOT/clang-${TARGET_CLANG}"
    if ! resolve_clang "$CLANG_DIR" >/dev/null 2>&1; then
        [ ! -e "$CLANG_DIR" ] || fail "工具链目录存在但不完整；为保留半成品证据，不自动删除：$CLANG_DIR"
        mkdir -p "$CLANG_DIR"
        tar -xzf "$clang_archive" -C "$CLANG_DIR"
    fi
    printf 'clang_archive_sha256=%s\n' "$actual_clang_sha" > "$WORK_ROOT/clang_archive.sha256"
fi
CLANG_DIR=$(resolve_clang "$CLANG_DIR") || fail "无法定位 clang-r416183b 工具链：$CLANG_DIR"
verify_clang "$CLANG_DIR"

mkdir -p "$KOUT" "$DIST"
cp -- "$ROOT/captured.config" "$KOUT/.config"
export PATH="$CLANG_DIR/bin:$PATH"
export KCFLAGS="${KCFLAGS:-} -D__ANDROID_COMMON_KERNEL__"
make -C "$SRC_DIR" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" KCFLAGS="$KCFLAGS" olddefconfig
python3 - "$KOUT/.config" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines(); out=[]; seen=set()
for line in lines:
    if line.startswith('CONFIG_LOCALVERSION='):
        out.append('CONFIG_LOCALVERSION=""'); seen.add('CONFIG_LOCALVERSION'); continue
    if line.startswith('CONFIG_LOCALVERSION_AUTO=') or line == '# CONFIG_LOCALVERSION_AUTO is not set':
        out.append('# CONFIG_LOCALVERSION_AUTO is not set'); seen.add('CONFIG_LOCALVERSION_AUTO'); continue
    out.append(line)
if 'CONFIG_LOCALVERSION' not in seen: out.append('CONFIG_LOCALVERSION=""')
if 'CONFIG_LOCALVERSION_AUTO' not in seen: out.append('# CONFIG_LOCALVERSION_AUTO is not set')
p.write_text('\n'.join(out)+'\n')
PY
make -C "$SRC_DIR" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" KCFLAGS="$KCFLAGS" olddefconfig
# Preserve full LTO/CFI/MODVERSIONS; fail if olddefconfig changed them away.
for key in CONFIG_MODVERSIONS CONFIG_CFI_CLANG CONFIG_LTO_CLANG_FULL; do grep -qx "$key=y" "$KOUT/.config" || fail "$key 未保持为 y"; done
printf '%s\n' "$TARGET_RELEASE" > "$WORK_ROOT/target-release.txt"
make -C "$SRC_DIR" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" KCFLAGS="$KCFLAGS" LOCALVERSION="-android12-9-o-g104a939c0e3e" LOCALVERSION_AUTO=n -j"$JOBS" vmlinux modules
[ -f "$KOUT/vmlinux" ] || fail '内核 vmlinux 未生成。'
[ -f "$KOUT/Module.symvers" ] || fail 'Module.symvers 未生成，拒绝继续外部模块构建。'
make -C "$SRC_DIR" O="$KOUT" M="$ROOT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" KCFLAGS="$KCFLAGS" LOCALVERSION="-android12-9-o-g104a939c0e3e" LOCALVERSION_AUTO=n -j"$JOBS" modules
KO="$ROOT/cpuinfo_spoof.ko"
[ -s "$KO" ] || fail '目标外部模块 cpuinfo_spoof.ko 未生成。'
cp -- "$KO" "$DIST/cpuinfo_spoof.ko"
[ -f "$ROOT/run.sh" ] || fail 'run.sh 不存在。'
cp -- "$ROOT/run.sh" "$DIST/run.sh"
python3 "$ROOT/verify_module.py" --module "$DIST/cpuinfo_spoof.ko" --symvers "$KOUT/Module.symvers" --config "$KOUT/.config" --output "$DIST/build_report.json"
[ -s "$DIST/build_report.json" ] || fail 'verify_module.py 未生成 build_report.json。'
cp -- "$KOUT/.config" "$DIST/final.config"
diff -u "$ROOT/captured.config" "$KOUT/.config" > "$DIST/config.diff" || true
python3 - "$DIST/provenance.json" "$archive" "$clang_archive" "$SRC_DIR" "$CLANG_DIR" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
out,archive,clang_archive,src,clang=sys.argv[1:]
def h(p):
 p=Path(p)
 return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
obj={'experiment':'PHP110 1301 using PHP110 901 source baseline','source_commit':'cd19560616750906a568aa271d8b49ac17f13914','source_url':'https://github.com/OnePlusOSS/android_kernel_5.10_oneplus_mt6983/archive/cd19560616750906a568aa271d8b49ac17f13914.tar.gz','source_archive_sha256':h(archive) if archive else None,'clang_url':'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/clang-r416183b.tar.gz','clang_archive_sha256':h(clang_archive) if clang_archive else None,'kernel_dir':os.path.realpath(src),'clang_dir':os.path.realpath(clang),'target_release':'5.10.226-android12-9-o-g104a939c0e3e','config_source':'captured.config','config_localversion':'empty; LOCALVERSION_AUTO=n','claims':['experimental baseline; not OEM 1301 build','source commit message identifies PHP110 15.0.0.901(CN01)','must not be treated as exact 1301 ABI proof'],'generated_by':'build.sh'}
Path(out).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
PY
python3 - "$DIST/provenance.json" "$MODULES_DIR" "$modules_archive" "$LOGS/vendor_dependencies.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
out,modules,archive,audit=map(Path,sys.argv[1:])
obj=json.loads(out.read_text())
obj['build_fix']='r2: restore official external vendor repository before Kconfig'
obj['modules_commit']='749b101b1a1487f1b1f8a5b4b3319e7ba6ed0a5d'
obj['modules_dir']=str(modules.resolve())
obj['modules_archive_sha256']=hashlib.sha256(archive.read_bytes()).hexdigest() if archive.is_file() else None
obj['vendor_dependency_audit']=json.loads(audit.read_text())
out.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
PY
printf 'BUILD_SUCCESS\nDIST=%s\n' "$DIST"
