#!/usr/bin/env bash
# XrayR disk-safe installer for guangyindada/XrayR-release (2026-10-19)
set -Eeuo pipefail
umask 022
RELEASE_REPO="guangyindada/XrayR-release"
CORE_REPO="Mtoly/XrayRP"
BASE="https://raw.githubusercontent.com/${RELEASE_REPO}/master"
APP=/usr/local/XrayR
CFG=/etc/XrayR
UNIT=/etc/systemd/system/XrayR.service
MANAGER=/usr/bin/XrayR
TMP="$(mktemp -d /tmp/xrayr-install.XXXXXXXX)"
BACKUP=""
COMMITTED=0
DEPLOY_STARTED=0
WAS_RUNNING=0
WAS_ENABLED=0
CREATED_CONFIGS=()
MOVED_OLD=()
MOVED_NEW=()
log(){ printf '[XrayR] %s\n' "$*"; }
fail(){ printf '[XrayR ERROR] %s\n' "$*" >&2; exit 1; }
rollback() {
  log '部署阶段失败，正在恢复原有文件'
  # Remove new payload first, freeing space before restoring old files.
  local item
  for item in "${MOVED_NEW[@]}"; do rm -f -- "$APP/$item" || true; done
  for item in "${MOVED_OLD[@]}"; do
    if [[ -e "$BACKUP/$item" ]]; then mv -f -- "$BACKUP/$item" "$APP/$item" || true; fi
  done
  for item in "${CREATED_CONFIGS[@]}"; do rm -f -- "$CFG/$item" || true; done
  if [[ -e "$BACKUP/unit" ]]; then
    cp -a "$BACKUP/unit" "$UNIT" || true
  else
    rm -f -- "$UNIT" || true
  fi
  if [[ -e "$BACKUP/manager" ]]; then
    cp -a "$BACKUP/manager" "$MANAGER" || true
  else
    rm -f -- "$MANAGER" || true
  fi
  if [[ -e "$BACKUP/lowercase-link" ]]; then
    cp -a "$BACKUP/lowercase-link" /usr/bin/xrayr || true
  elif [[ -L /usr/bin/xrayr ]]; then
    rm -f /usr/bin/xrayr || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if (( WAS_ENABLED )); then systemctl enable XrayR >/dev/null 2>&1 || true;
  else systemctl disable XrayR >/dev/null 2>&1 || true; fi
  if (( WAS_RUNNING )); then systemctl restart XrayR || true; fi
  warn_msg="[XrayR] 已尝试回滚。若仍有问题，原文件备份目录：$BACKUP"
  printf '%s\n' "$warn_msg" >&2
}
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && DEPLOY_STARTED && ! COMMITTED )); then rollback; fi
  [[ -z "${TMP:-}" || ! -d "$TMP" ]] || rm -rf -- "$TMP"
  if (( rc != 0 )); then
    printf '[XrayR ERROR] 安装失败（退出码 %s）；未报告部署成功。\n' "$rc" >&2
  fi
}
trap on_exit EXIT
[[ $EUID -eq 0 ]] || fail '请使用 root 运行'
command -v systemctl >/dev/null || fail '需要 systemd/systemctl'
[[ -r /etc/os-release ]] || fail '无法识别操作系统'
. /etc/os-release
case "${ID:-}" in
 debian|ubuntu) PKG=apt ;;
 centos|rhel|rocky|almalinux|ol|fedora) PKG=rpm ;;
 *) fail "未验证的发行版：${ID:-unknown}" ;;
esac
case "$(uname -m)" in
 x86_64|amd64) ARCH=64 ;;
 aarch64|arm64) ARCH=arm64-v8a ;;
 *) fail "当前架构尚未验证：$(uname -m)" ;;
esac
# 只安装真正缺失的依赖，避免 Debian 11 安全源旧索引触发不必要的升级。
missing=()
for cmd in curl unzip python3; do
 if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
done
if [[ $PKG == apt ]]; then
 if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed'; then
  missing+=(ca-certificates)
 fi
fi
if (( ${#missing[@]} )); then
 log "仅安装缺失的依赖：${missing[*]}"
 if [[ $PKG == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  # Debian 11 的旧安全仓库可能仍提供索引，但对应 .deb 已经返回 404。
  # 在已知主仓库存在 unzip 的情况下直接选择主仓库版本，避免重复失败。
  if [[ ${ID:-} == debian && ${VERSION_ID%%.*} == 11 ]]; then
   for i in "${!missing[@]}"; do
    if [[ ${missing[$i]} == unzip ]]; then
     # Prefer APT's machine-friendly madison listing, avoiding policy indentation parsing.
     # Match only Debian bullseye/main, not bullseye-security.
     main_version="$(python3 - <<'PYAPT'
import re
import subprocess

p = subprocess.run(['apt-cache', 'madison', 'unzip'], text=True,
                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
for line in p.stdout.splitlines():
    parts = [part.strip() for part in line.split('|')]
    if len(parts) < 3 or parts[0] != 'unzip':
        continue
    version, source = parts[1], parts[2]
    if re.search(r'\b(?:https?://)?deb\.debian\.org/debian\s+bullseye/main\b', source):
        print(version)
        break
PYAPT
)"
     # Some APT builds omit madison sources. Fall back to version blocks in policy.
     if [[ -z "$main_version" ]]; then
      main_version="$(python3 - <<'PYAPT'
import re
import subprocess

p = subprocess.run(['apt-cache', 'policy', 'unzip'], text=True,
                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
version = ''
for line in p.stdout.splitlines():
    stripped = line.strip()
    m = re.fullmatch(r'(?:\*\*\*\s+)?([^\s]+)\s+[0-9]+', stripped)
    if m:
        version = m.group(1)
        continue
    if version and re.search(r'https?://deb\.debian\.org/debian\s+bullseye/main\b', line):
        print(version)
        break
PYAPT
)"
     fi
     if [[ -n "$main_version" ]]; then
      log "Debian 11 主仓库可用 unzip 版本：$main_version；优先安装此版本以避开安全仓库 404"
      missing[$i]="unzip=$main_version"
     else
      log '未找到主仓库 unzip 版本，改用标准 APT 安装流程'
     fi
    fi
   done
  fi
  if ! apt-get install -y --no-install-recommends --no-upgrade "${missing[@]}"; then
   log 'APT 安装失败，刷新索引后再尝试一次'
   apt-get update || fail 'APT 索引更新失败'
   apt-get install -y --no-install-recommends --no-upgrade "${missing[@]}" \
    || fail '依赖安装失败；已停止部署 XrayR。请检查 APT 仓库与可用版本'
  fi
 elif command -v dnf >/dev/null 2>&1; then
  dnf install -y "${missing[@]}"
 else
  yum install -y "${missing[@]}"
 fi
fi
for cmd in curl unzip python3; do
 command -v "$cmd" >/dev/null 2>&1 || fail "缺少依赖：$cmd"
done
fetch(){ curl -fL --retry 3 --connect-timeout 15 --max-time 600 -sS "$1" -o "$2"; }
log '获取最新 release 版本'
fetch "https://api.github.com/repos/${CORE_REPO}/releases/latest" "$TMP/latest.json"
VERSION="$(python3 - "$TMP/latest.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])).get('tag_name','')
if not v or '/' in v or '..' in v: raise SystemExit('invalid tag_name')
print(v)
PY
)"
[[ -n "$VERSION" ]] || fail '无法解析最新版本'
ZIP="XrayR-linux-${ARCH}.zip"
log "下载 $VERSION ($ARCH)"
fetch "https://github.com/${CORE_REPO}/releases/download/${VERSION}/${ZIP}" "$TMP/$ZIP"
unzip -tq "$TMP/$ZIP" >/dev/null || fail 'ZIP 损坏，现有安装未修改'
# Detect insufficient filesystem capacity BEFORE extraction, rather than halfway
# through writing the live files. The archive remains untouched until validated.
python3 - "$TMP/$ZIP" <<'PYSPACE'
import os, sys, zipfile, shutil
archive = sys.argv[1]
with zipfile.ZipFile(archive) as z:
    files = z.infolist()
    for info in files:
        path = info.filename.replace('\\', '/')
        if path.startswith('/') or '..' in path.split('/'):
            raise SystemExit('[XrayR ERROR] ZIP 包含不安全路径，已终止')
    payload = sum(i.file_size for i in files)
free = shutil.disk_usage(os.path.dirname(archive)).free
# 16 MiB headroom for metadata and transient file operations.
required = payload + 16 * 1024 * 1024
print(f'[XrayR] 解压前空间检查：需要约 {required//1048576} MiB，可用 {free//1048576} MiB')
if free < required:
    raise SystemExit('[XrayR ERROR] 临时目录空间不足，未解压、未修改现有安装；请扩容磁盘或清理不需要的文件')
PYSPACE
mkdir -p "$TMP/stage"
unzip -q "$TMP/$ZIP" -d "$TMP/stage"
rm -f -- "$TMP/$ZIP" # archive is no longer required; reclaim disk space
BIN="$(find "$TMP/stage" -type f -name XrayR -print -quit)"
[[ -n "$BIN" && -s "$BIN" ]] || fail '压缩包缺少 XrayR 程序'
chmod 755 "$BIN"
"$BIN" version >"$TMP/version.txt" 2>&1 || fail '二进制无法执行'
log "程序验证：$(head -1 "$TMP/version.txt")"
for name in XrayR.service XrayR.sh; do
 fetch "$BASE/$name" "$TMP/$name"
 [[ -s "$TMP/$name" ]] || fail "$name 下载为空"
done
bash -n "$TMP/XrayR.sh" || fail '管理脚本语法检查失败'
grep -q '^\[Service\]' "$TMP/XrayR.service" || fail 'systemd unit 格式异常'
grep -Fq 'ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml' "$TMP/XrayR.service" || fail 'systemd unit 启动路径不匹配'
# 先准备默认配置，避免在停止现有服务后才开始网络下载
mkdir -p "$TMP/defaults"
for name in config.yml dns.json route.json custom_inbound.json custom_outbound.json; do
 if [[ ! -s "$CFG/$name" ]]; then
  fetch "$BASE/config/$name" "$TMP/defaults/$name" || {
   [[ $name == config.yml ]] && fail '默认 config.yml 下载失败'
   log "可选文件 $name 下载失败，跳过"
  }
 fi
done
# 数据文件必须来自 release 包或已有安装，不能使用空文件
for name in geoip.dat geosite.dat; do
 src="$(find "$TMP/stage" -type f -name "$name" -print -quit)"
 if [[ -z "$src" && ! -s "$CFG/$name" ]]; then
  fetch "$BASE/config/$name" "$TMP/defaults/$name" || fail "缺少必需文件 $name"
 fi
done
[[ -s "$CFG/config.yml" || -s "$TMP/defaults/config.yml" ]] || fail '缺少 config.yml'
# Validate final deployment capacity before touching the live program or service.
# Same-filesystem mv does not duplicate the binary/geo files. Cross-filesystem mv
# requires enough free capacity in the destination for a full copy.
python3 - "$TMP" "$APP" "$BIN" <<'PYDEPLOY'
import os, shutil, sys
root, target, binary = sys.argv[1:]
parent = os.path.dirname(target)
os.makedirs(parent, exist_ok=True)
source_paths = [binary]
for name in ('geoip.dat', 'geosite.dat'):
    for folder in (os.path.join(root, 'stage'), os.path.join(root, 'defaults')):
        for dirpath, _, files in os.walk(folder):
            if name in files:
                source_paths.append(os.path.join(dirpath, name))
                break
        if len(source_paths) >= (2 if name == 'geoip.dat' else 3):
            break
source_bytes = sum(os.stat(p).st_size for p in source_paths)
free = shutil.disk_usage(parent).free
same_fs = os.stat(root).st_dev == os.stat(parent).st_dev
reserve = 16 * 1024 * 1024
required = reserve if same_fs else source_bytes + reserve
print(f'[XrayR] 部署空间检查：目标目录可用 {free//1048576} MiB；所需至少 {required//1048576} MiB；跨分区={"是" if not same_fs else "否"}')
if free < required:
    raise SystemExit('[XrayR ERROR] 目标分区空间不足，尚未修改运行中的程序；请先扩容或清理磁盘')
PYDEPLOY
# Never copy potentially huge existing binaries for backup. Rename them on the
# same filesystem to avoid consuming extra disk space and enable easy rollback.
log '下载与空间预检完成，开始部署'
mkdir -p "$APP" "$CFG"
BACKUP="$(mktemp -d /usr/local/.xrayr-backup.XXXXXXXX)"
for pair in "$UNIT:unit" "$MANAGER:manager"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  [[ ! -f "$src" ]] || cp -a -- "$src" "$BACKUP/$dst"
done
if [[ -L /usr/bin/xrayr ]]; then cp -a /usr/bin/xrayr "$BACKUP/lowercase-link"; fi
if systemctl is-active --quiet XrayR; then WAS_RUNNING=1; fi
if systemctl is-enabled --quiet XrayR; then WAS_ENABLED=1; fi
DEPLOY_STARTED=1
if (( WAS_RUNNING )); then systemctl stop XrayR; fi
for name in XrayR geoip.dat geosite.dat; do
  if [[ -e "$APP/$name" ]]; then
    mv -f -- "$APP/$name" "$BACKUP/$name"
    MOVED_OLD+=("$name")
  fi
  if [[ "$name" == XrayR ]]; then
    src="$BIN"
  else
    src="$(find "$TMP/stage" -type f -name "$name" -print -quit)"
    [[ -n "$src" ]] || src="$TMP/defaults/$name"
  fi
  [[ -s "$src" ]] || fail "缺少部署文件：$name"
  MOVED_NEW+=("$name") # include interrupted cross-device copies in rollback
  mv -f -- "$src" "$APP/$name"
done
chmod 755 "$APP/XrayR"
chmod 644 "$APP/geoip.dat" "$APP/geosite.dat"
for name in config.yml dns.json route.json custom_inbound.json custom_outbound.json; do
  if [[ ! -e "$CFG/$name" && -s "$TMP/defaults/$name" ]]; then
    CREATED_CONFIGS+=("$name") # ensure partial writes are removed on rollback
    install -m 644 "$TMP/defaults/$name" "$CFG/$name"
  fi
done
install -m 644 "$TMP/XrayR.service" "$UNIT"
install -m 755 "$TMP/XrayR.sh" "$MANAGER"
ln -sfn "$MANAGER" /usr/bin/xrayr
systemctl daemon-reload
systemctl enable XrayR
# Preserve the running state of an existing deployment. Do not launch an
# unconfigured example node on the first install.
if (( WAS_RUNNING )); then
  systemctl start XrayR
  sleep 2
  systemctl is-active --quiet XrayR || fail '服务重启后未保持运行'
  log '服务已恢复运行：active'
elif (( ${#MOVED_OLD[@]} )); then
  log '程序已更新；原服务未运行，继续保持未运行状态'
else
  log '首次安装完成。请编辑 /etc/XrayR/config.yml 填写真实节点配置后再启动服务'
fi
systemctl is-enabled --quiet XrayR || fail '开机自启设置失败'
COMMITTED=1
log "部署成功：$VERSION；开机自启 enabled"
log "旧程序备份：$BACKUP（确认运行正常后可自行删除以释放空间）"
