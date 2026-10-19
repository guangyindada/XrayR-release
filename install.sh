#!/usr/bin/env bash
# XrayR safe installer for guangyindada/XrayR-release
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
log(){ printf '[XrayR] %s\n' "$*"; }
fail(){ printf '[XrayR ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'rc=$?; echo "[XrayR ERROR] 安装失败（退出码 $rc，第 $LINENO 行）。" >&2; exit "$rc"' ERR
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
     main_version="$(apt-cache policy unzip | awk '
       /^[[:space:]]*\*{0,3}[[:space:]]*[0-9][^[:space:]]*[[:space:]]+[0-9]+$/ {version=$1; if (version=="***") version=$2}
       /deb\.debian\.org\/debian[[:space:]]+bullseye\/main[[:space:]]/ {if (version!="") {print version; exit}}
     ')"
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
mkdir -p "$TMP/stage"
unzip -q "$TMP/$ZIP" -d "$TMP/stage"
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
# 全部远程下载完成后才开始修改现有安装
log '下载与预检完成，开始部署'
mkdir -p "$APP" "$CFG"
BACKUP="$(mktemp -d /var/tmp/xrayr-backup.XXXXXXXX)"
for pair in "$APP/XrayR:binary" "$UNIT:unit" "$MANAGER:manager"; do
 src="${pair%%:*}"; dst="${pair##*:}"
 [[ ! -f "$src" ]] || cp -a "$src" "$BACKUP/$dst"
done
WAS_RUNNING=0
systemctl is-active --quiet XrayR && WAS_RUNNING=1 || true
if (( WAS_RUNNING )); then systemctl stop XrayR; fi
rollback(){
 log '正在尝试恢复原有程序及服务文件'
 [[ ! -f "$BACKUP/binary" ]] || install -m 755 "$BACKUP/binary" "$APP/XrayR"
 [[ ! -f "$BACKUP/unit" ]] || install -m 644 "$BACKUP/unit" "$UNIT"
 [[ ! -f "$BACKUP/manager" ]] || install -m 755 "$BACKUP/manager" "$MANAGER"
 systemctl daemon-reload || true
 if (( WAS_RUNNING )); then systemctl restart XrayR || true; fi
}
trap 'rc=$?; if (( ! COMMITTED )); then rollback; fi; echo "[XrayR ERROR] 部署失败（退出码 $rc），备份目录：$BACKUP" >&2; exit "$rc"' ERR
install -m 755 "$BIN" "$APP/XrayR"
for name in geoip.dat geosite.dat; do
 src="$(find "$TMP/stage" -type f -name "$name" -print -quit)"
 [[ -n "$src" ]] || src="$TMP/defaults/$name"
 install -m 644 "$src" "$APP/$name"
done
for name in config.yml dns.json route.json custom_inbound.json custom_outbound.json; do
 if [[ ! -e "$CFG/$name" && -s "$TMP/defaults/$name" ]]; then
  install -m 644 "$TMP/defaults/$name" "$CFG/$name"
 fi
done
install -m 644 "$TMP/XrayR.service" "$UNIT"
install -m 755 "$TMP/XrayR.sh" "$MANAGER"
ln -sfn "$MANAGER" /usr/bin/xrayr
systemctl daemon-reload
systemctl enable XrayR
# 已运行的服务升级后应恢复运行；首次安装的示例配置不能当成真实配置
if (( WAS_RUNNING )); then
 systemctl start XrayR
 sleep 2
 systemctl is-active --quiet XrayR || fail '服务重启后未保持运行'
 log '服务已恢复运行：active'
elif [[ -f "$BACKUP/binary" ]]; then
 log '程序升级完成；原服务未运行，保持原状态'
else
 log '首次安装完成。请编辑 /etc/XrayR/config.yml 填写真实节点配置后再启动服务'
fi
systemctl is-enabled --quiet XrayR || fail '开机自启设置失败'
COMMITTED=1
log "部署成功：$VERSION；开机自启 enabled"
log "备份目录：$BACKUP（确认运行正常后可自行删除）"
