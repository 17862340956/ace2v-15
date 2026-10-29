#!/system/bin/sh
# Phone-only entry for the explicitly selected 901-source experiment on PHP110 1301.
# Requires the KO and report produced together by this source kit's verifier.
[ "$(id -u)" = 0 ] || { echo '请选择 ROOT 执行。'; exit 1; }
umask 077
DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
BASE=/data/adb
[ -d "$BASE" ] && [ -w "$BASE" ] || BASE=/data/local/tmp
OUT="$BASE/php110_901_exp_$(date '+%Y%m%d_%H%M%S')_$$"
mkdir -p "$OUT" || exit 1
TARGET=5.10.226-android12-9-o-g104a939c0e3e
REV=qilin-php510-901-exp1
SOURCE=cd19560616750906a568aa271d8b49ac17f13914
PASS=0
FAIL=0
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$OUT/run.txt"; }
step() { printf '%s\n' "$1" > "$OUT/last_step.txt"; sync; }
finish() {
    printf 'pass=%s\nfail=%s\n' "$PASS" "$FAIL" > "$OUT/summary.txt"
    dmesg > "$OUT/dmesg.txt" 2> "$OUT/dmesg.error"
    sync
    if tar -czf "$OUT.tar.gz" -C "$BASE" "${OUT##*/}" 2> "$OUT/archive.error"; then
        echo "发送这一个日志包：$OUT.tar.gz"
    else echo "日志目录：$OUT"; fi
}
fail() { FAIL=$((FAIL+1)); say "FAIL $1"; finish; exit 1; }
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); say "PASS $1=$2"
    else FAIL=$((FAIL+1)); say "FAIL $1=$2 expected=$3"; fi
}
value() { sed -n "s/^$1=//p" "$OUT/status.txt"; }
read_check() {
    step "read_$1"
    GOT=$(cat "$2" 2>> "$OUT/read.error")
    RC=$?
    [ "$RC" = 0 ] || { FAIL=$((FAIL+1)); say "FAIL read $2 rc=$RC"; return; }
    check "$1" "$GOT" "$3"
}
say 'PHP110：901 源码实验基线，用于 1301；不是原厂精确匹配或已验证稳定版。'
[ "$(getprop ro.board.platform)" = mt6983 ] || fail '平台不匹配。'
[ "$(getprop ro.build.display.id)" = 'PHP110_15.0.0.1301(CN01)' ] || fail '固件不是本次登记的1301。'
[ "$(getconf PAGESIZE 2>/dev/null)" = 4096 ] || fail '页大小不匹配。'
KO="$DIR/cpuinfo_spoof.ko"
REPORT="$DIR/build_report.json"
[ -s "$KO" ] && [ -s "$REPORT" ] || fail '缺少本实验版本配套KO或报告；源码包本身没有预编译KO。'
for TOOL in sha256sum strings gzip awk; do command -v "$TOOL" >/dev/null 2>&1 || fail "缺少工具：$TOOL"; done
HASH=$(sha256sum "$KO" | awk '{print $1}')
EXPECTED=$(awk -F '"' '/"sha256"/ {print $4; exit}' "$REPORT")
[ -n "$EXPECTED" ] && [ "$HASH" = "$EXPECTED" ] || fail 'KO与报告哈希不一致。'
[ "$(awk -F '"' '/"revision"/ {print $4; exit}' "$REPORT")" = "$REV" ] || fail '报告版本不匹配。'
[ "$(awk -F '"' '/"source_commit"/ {print $4; exit}' "$REPORT")" = "$SOURCE" ] || fail '报告不是固定901源码。'
[ "$(awk -F '"' '/"source_basis"/ {print $4; exit}' "$REPORT")" = PHP110_901_EXPERIMENTAL ] || fail '报告源码基线不匹配。'
cp "$REPORT" "$OUT/build_report.json"
printf '%s  %s\n' "$HASH" "$KO" > "$OUT/module_sha256.txt"
strings "$KO" > "$OUT/module_strings.txt"
grep -qx "version=$REV" "$OUT/module_strings.txt" || fail 'KO revision不符。'
grep -qx "source_commit=$SOURCE" "$OUT/module_strings.txt" || fail 'KO源码基线不符。'
grep -q "^vermagic=$TARGET " "$OUT/module_strings.txt" || fail 'KO release不符。'
# This fingerprint identifies the original capture; no live BTF is required.
step check_config
gzip -dc /proc/config.gz > "$OUT/live.config" 2> "$OUT/config.error" || fail '读取内核配置失败。'
CONFIG_HASH=$(sha256sum "$OUT/live.config" | awk '{print $1}')
[ "$CONFIG_HASH" = 0fd19e2ba9114e47b80b3cd35792d8245deffb50887eba7c65e2a56b231fca70 ] || fail '运行配置与登记1301画像不一致。'
if [ -d /sys/module/cpuinfo_spoof ]; then
    cat /proc/cpuinfo_spoof > "$OUT/status.txt" 2>> "$OUT/read.error" || fail '已有实例状态不可读。'
    [ "$(value revision)" = "$REV" ] && [ "$(value original_release)" = "$TARGET" ] || fail '旧版或其他版本驻留；重启后使用本包，不自动卸载。'
    say '同版本实例已在，读取状态，不重复加载。'
else
    [ "$(uname -r)" = "$TARGET" ] || fail '运行内核release不符。'
    step before_insmod
    insmod "$KO" stage=full pointer_tests=1 > "$OUT/insmod.txt" 2>&1
    RC=$?
    cat "$OUT/insmod.txt"
    [ "$RC" = 0 ] || fail "加载失败rc=$RC；不重试。"
    step after_insmod
    cat /proc/cpuinfo_spoof > "$OUT/status.txt" 2>> "$OUT/read.error" || fail '状态节点读取失败。'
fi
for EXPECTED_STATE in "revision=$REV" 'stage=full' 'state=active' 'planned=9' 'applied=9' 'pointer_applied=8' 'uts_applied=1' 'last_error=0' 'pinned=1' 'cpuinfo=pde_pointer_active' 'source_basis=php110-901-experimental' 'boost=disabled'; do
    grep -qx "$EXPECTED_STATE" "$OUT/status.txt" || fail "状态不完整：$EXPECTED_STATE；驻留实例需重启清理。"
done
step read_cpuinfo
cat /proc/cpuinfo > "$OUT/cpuinfo.txt" 2>> "$OUT/read.error" || fail 'CPUINFO读取失败。'
check processors "$(grep -c '^processor' "$OUT/cpuinfo.txt")" 12
check hardware "$(sed -n 's/^Hardware[[:space:]]*: //p' "$OUT/cpuinfo.txt")" 'HUAWEI Kirin9020'
check uname_release "$(uname -r)" 5.10.226-HUAWEI-Kirin9020
VERSION=$(cat /proc/version 2>> "$OUT/read.error")
printf '%s\n' "$VERSION" > "$OUT/proc_version.txt"
case "$VERSION" in 'Linux version 5.10.226-HUAWEI-Kirin9020 '*) check proc_version match match ;; *) check proc_version mismatch match ;; esac
for KEY in online possible present; do read_check "$KEY" "/sys/devices/system/cpu/$KEY" 0-11; done
for CPU in 0 1 2 3 4 5 6 7; do
    if [ "$CPU" -lt 4 ]; then CORE=$CPU; PACKAGE=0; else CORE=$((CPU-4)); PACKAGE=1; fi
    read_check "cpu${CPU}_core" "/sys/devices/system/cpu/cpu$CPU/topology/core_id" "$CORE"
    read_check "cpu${CPU}_package" "/sys/devices/system/cpu/cpu$CPU/topology/physical_package_id" "$PACKAGE"
    read_check "cpu${CPU}_die" "/sys/devices/system/cpu/cpu$CPU/topology/die_id" -1
done
FREQS='307200 441600 556800 672000 787200 902400 1017600 1113600 1228800 1344000 1459200 1555200 1670400 1785600 1900800 2016000 2188800 2323200 2457600 2592000 2707200 2803200 2918400 3000000 3187200'
for POLICY in policy0 policy4 policy7; do
    read_check "${POLICY}_freqs" "/sys/devices/system/cpu/cpufreq/$POLICY/scaling_available_frequencies" "$FREQS"
done
say 'boost节点未暴露，本目标保持关闭。频率为项目显示模板，不改变实际频率。'
[ "$FAIL" = 0 ] || fail '接口读取存在差异，停止属性步骤。'
RP=''
for TOOL in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop; do
    [ ! -x "$TOOL" ] || { RP=$TOOL; break; }
done
[ -n "$RP" ] || RP=$(command -v resetprop 2>/dev/null)
[ -n "$RP" ] && [ -x "$RP" ] || fail '缺少resetprop；内核读取结果已保存。'
step properties
for KEY in ro.soc.model ro.soc.manufacturer; do printf '%s=%s\n' "$KEY" "$(getprop "$KEY")"; done > "$OUT/props_before.txt"
"$RP" -n ro.soc.model Kirin9020 > "$OUT/resetprop.txt" 2>&1
R1=$?
"$RP" -n ro.soc.manufacturer HiSilicon >> "$OUT/resetprop.txt" 2>&1
R2=$?
check property_model_rc "$R1" 0
check property_manufacturer_rc "$R2" 0
check ro.soc.model "$(getprop ro.soc.model)" Kirin9020
check ro.soc.manufacturer "$(getprop ro.soc.manufacturer)" HiSilicon
step complete
say "PASS=$PASS FAIL=$FAIL；仅对应本次有限读取，不代表1301长期稳定、真实12核或GPU适配。"
finish
[ "$FAIL" = 0 ]
