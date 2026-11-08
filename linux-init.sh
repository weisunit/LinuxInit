#!/usr/bin/env bash
# ==============================================================================
#  LinuxInit —— Linux 新装系统通用初始化脚本
#  版本: 1.0.0    需求文档: v0.6（D1~D15 已全部确认）
#
#  用法: bash linux-init.sh [模块ID...] [选项]     （无参数 = 交互主菜单）
#  模块: 1=换源 2=更新 3=时区 4=主机名 5=网络 6=防火墙 7=调优 8=软件
#        9=用户 10=Docker 11=SSH加固 12=NVIDIA 13=报告
#
#  兼容: Debian 11/12/13, Ubuntu 20.04~26.04, Rocky/Alma 8~10, CentOS Stream 9/10,
#        RHEL 8~10（尽力支持: CentOS 7.9 / RHEL 7 / openEuler 等）
#  要求: root 身份 + bash >= 4.0 + systemd
# ==============================================================================
set -u

SCRIPT_VERSION="1.0.0"
REQ_DOC_VERSION="v0.7"

# ---------------------------------------------------------------- 路径与常量
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

STATE_DIR="${LINUX_INIT_STATE_DIR:-/var/lib/linux-init}"
STATE_FILE="$STATE_DIR/state.env"
LOG_DIR="${LINUX_INIT_LOG_DIR:-/var/log/linux-init}"
BACKUP_ROOT="${LINUX_INIT_BACKUP_ROOT:-/root/linux-init-backup}"
LOCK_FILE="${LINUX_INIT_LOCK:-/var/lock/linux-init.lock}"

RUN_TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$RUN_TS"
LOG_FILE="$LOG_DIR/$RUN_TS.log"
REPORT_FILE="$LOG_DIR/last-report.txt"

VENDOR_TMP=""
MARK_BEGIN="# >>> linux-init >>> (由 LinuxInit 管理，勿手工编辑)"
MARK_END="# <<< linux-init <<<"

# dist 单文件内嵌的 vendor 脚本（build.sh 打包时替换；源码形态保持占位符）
VENDOR_MAIN_B64="__VENDOR_MAIN_B64__"
VENDOR_DOCKER_B64="__VENDOR_DOCKER_B64__"

# ---------------------------------------------------------------- 运行开关
ASSUME_YES=0 DRY_RUN=0 FORCE=0 STRICT_MIRROR=0 KEEP_FIREWALL=0 SELINUX_ENFORCING=0
SKIP_MIRRORS=0 SKIP_UPDATE=0 SKIP_TIME=0 SKIP_USER=0 SKIP_SSH=0
ARG_TUNE="mild" ARG_TOOLS="" ARG_TOOLS_SET=0
WITH_DOCKER=0 WITH_NVIDIA=0 WITH_CUDA=0 ARG_CUDA_VER=""
ARG_HOSTNAME="" ARG_TIMEZONE="" TARGET_USER="" SUDO_REQUIRE_PASSWORD=0
ARG_PUBKEY_FILE="" ARG_PUBKEY_URL="" ARG_SSH_PORT=""
ARG_MIRROR="" ARG_DOCKER_REGISTRY="" ARG_NVIDIA_DRIVER=""
ARG_DNS=""
ARG_ALL=0 REBOOT_AUTO=0 SHOW_HELP=0 SHOW_VERSION=0 FORCE_STEP=""
RUN_MODULES=() FORCE_STEP_APPLIED=0

# ---------------------------------------------------------------- 系统信息
OS_FAMILY="" OS_ID="" OS_VER="" OS_VER_MAJOR="" PKG="" SSH_SVC="" SUDO_GROUP=""
SSHD_BIN="/usr/sbin/sshd"
FAILED_MODULES=()
PUBKEYS=() NIC_PLAN=() USER_PASSWORD=""

# ---------------------------------------------------------------- 颜色
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'    C_GREEN=$'\033[32m'  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'   C_GRAY=$'\033[90m'   C_BOLD=$'\033[1m'  C_OFF=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_GRAY="" C_BOLD="" C_OFF=""
fi

# ---------------------------------------------------------------- 基础输出
info() { printf '%s[INFO]%s %s\n'  "$C_CYAN"   "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$C_GREEN"  "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_OFF" "$*"; }
err()  { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_OFF" "$*" >&2; }
hr()   { printf '%s%s%s\n' "$C_GRAY" "────────────────────────────────────────────────────" "$C_OFF"; }
die()  { local code="$1"; shift; err "$*"; exit "$code"; }

# 红字提示（危险操作说明，始终醒目）
danger() { printf '%s[!!] %s%s\n' "$C_RED$C_BOLD" "$*" "$C_OFF"; }

# ---------------------------------------------------------------- 交互
# confirm "提示" [默认y|n]  —— 返回 0=确认；--yes 模式自动确认
confirm() {
  local prompt="$1" def="${2:-n}" ans hint="[y/N]"
  [[ "$def" == "y" ]] && hint="[Y/n]"
  if [[ $ASSUME_YES -eq 1 ]]; then info "$prompt → --yes 自动确认"; return 0; fi
  while true; do
    read -r -p "$(printf '%s%s %s%s ' "$C_YELLOW" "$prompt" "$hint" "$C_OFF")" ans </dev/tty 2>/dev/null || return 1
    case "${ans,,}" in
      "")     [[ "$def" == "y" ]] && return 0 || return 1 ;;
      y|yes)  return 0 ;;
      n|no)   return 1 ;;
      *)      warn "请输入 y 或 n" ;;
    esac
  done
}

# ---------------------------------------------------------------- 命令执行
# run_cmd: 记录并执行简单命令；run_sh: 记录并执行 bash -c 字符串
run_cmd() {
  info "\$ $*"
  [[ $DRY_RUN -eq 1 ]] && return 0
  "$@"
}
run_sh() {
  info "\$ $1"
  [[ $DRY_RUN -eq 1 ]] && return 0
  bash -c "$1"
}

# write_file <路径> <权限>: 从 stdin 读取内容写文件（dry-run 只预览）
write_file() {
  local f="$1" mode="${2:-644}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将写入: $f (mode $mode)"
    sed 's/^/    | /'
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  install -m "$mode" "$tmp" "$f"
  rm -f "$tmp"
}

# ---------------------------------------------------------------- 备份
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then info "[dry-run] 将备份: $f"; return 0; fi
  local dest="$BACKUP_DIR$(dirname "$f")"
  mkdir -p "$dest"
  cp -a "$f" "$dest/" && info "已备份: $f → $dest/"
}

# ---------------------------------------------------------------- 标记块管理
remove_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -qF "$MARK_BEGIN" "$f" || return 0
  if [[ $DRY_RUN -eq 1 ]]; then info "[dry-run] 将清理标记块: $f"; return 0; fi
  local tmp; tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0, b) == 1 { inblk = 1; next }
    index($0, e) == 1 { inblk = 0; next }
    inblk == 0 { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

append_block() {
  local f="$1" content="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将追加标记块到: $f"
    printf '%s\n' "$content" | sed 's/^/    | /'
    return 0
  fi
  remove_block "$f"
  { printf '%s\n' "$MARK_BEGIN"; printf '%s\n' "$content"; printf '%s\n' "$MARK_END"; } >> "$f"
}

prepend_block() {
  local f="$1" content="$2" tmp
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将在头部插入标记块: $f"
    printf '%s\n' "$content" | sed 's/^/    | /'
    return 0
  fi
  remove_block "$f"
  tmp="$(mktemp)"
  { printf '%s\n' "$MARK_BEGIN"; printf '%s\n' "$content"; printf '%s\n' "$MARK_END"; cat "$f"; } > "$tmp"
  mv "$tmp" "$f"
}

# ---------------------------------------------------------------- 状态文件
state_init() { mkdir -p "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE" 2>/dev/null || true; }
state_get() {
  local k="$1"
  grep -E "^${k}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}
state_set() {
  local k="$1" v="$2" tmp
  state_init
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    index($0, k "=") == 1 { print k "=" v; f = 1; next }
    { print }
    END { if (!f) print k "=" v }
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# 重启提醒（多条累计）
hint_reboot() {
  local n
  n=$(( $(state_get REBOOT_HINT_N 2>/dev/null || echo 0) + 1 ))
  state_set "REBOOT_HINT_N" "$n"
  state_set "REBOOT_HINT_${n}" "$1"
  warn "需重启生效: $1"
}

# ---------------------------------------------------------------- 校验函数
valid_hostname() {
  local h="${1,,}"
  [[ -n "$h" && ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}
valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  case "$1" in
    root|daemon|bin|sys|adm|tty|disk|lp|mail|news|uucp|operator|man|nobody|dbus|sshd|messagebus|chrony*|systemd*) return 1 ;;
  esac
  return 0
}
valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o IFS='.'
  read -r -a o <<< "$ip"
  local x
  for x in "${o[@]}"; do [[ "$x" -le 255 ]] || return 1; done
  [[ "${o[0]}" != "127" && "${o[0]}" != "0" ]] || return 1
  return 0
}
valid_cidr() {
  local c="$1"
  [[ "$c" =~ ^(.+)/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  valid_ipv4 "${BASH_REMATCH[1]}"
}
valid_pubkey() {
  local k="$1"
  [[ "$k" =~ ^(sk-)?(ssh|ecdsa)-[A-Za-z0-9@.\-]+[[:space:]]+[A-Za-z0-9+/=]+ ]]
}
# 外部 URL 安全校验：仅 https，拒绝 localhost/私有/保留地址（前缀匹配）
url_is_safe() {
  [[ "$1" == https://* ]] || return 1
  local host
  host="$(printf '%s' "$1" | sed -E 's#^https://([^/:@]+).*#\1#')"
  [[ "$host" =~ ^(localhost|127\.|0\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[?::1\]?) ]] && return 1
  return 0
}
prefix_to_mask() {
  local p="$1" b
  b=$(( 0xFFFFFFFF << (32 - p) & 0xFFFFFFFF ))
  echo "$(( (b >> 24) & 255 )).$(( (b >> 16) & 255 )).$(( (b >> 8) & 255 )).$(( b & 255 ))"
}

# ---------------------------------------------------------------- 系统识别
detect_os() {
  [[ -r /etc/os-release ]] || die 11 "无法读取 /etc/os-release：不支持的系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; OS_VER_MAJOR="${OS_VER%%.*}"
  case "$OS_ID" in
    ubuntu|debian|kali|linuxmint|raspbian|armbian|deepin|openkylin) OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol|fedora|openeuler|anolis|opencloudos|almalinux-vault) OS_FAMILY="rhel" ;;
    *)
      if [[ "${ID_LIKE:-}" == *debian* ]]; then
        OS_FAMILY="debian"
      elif [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* || "${ID_LIKE:-}" == *centos* ]]; then
        OS_FAMILY="rhel"
      else
        [[ $FORCE -eq 1 ]] && { warn "未识别的发行版: ${PRETTY_NAME:-$OS_ID}（--force 继续按 Debian 系尝试）"; OS_FAMILY="debian"; } \
          || die 11 "不支持的发行版: ${PRETTY_NAME:-$OS_ID}（可加 --force 强行继续，风险自负）"
      fi ;;
  esac
  if command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  else PKG="apt-get"; fi
  if [[ "$OS_FAMILY" == "debian" ]]; then
    SSH_SVC="ssh"; SUDO_GROUP="sudo"
  else
    SSH_SVC="sshd"; SUDO_GROUP="wheel"
  fi
  SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
}

# ---------------------------------------------------------------- vendor 解析
# 优先: 脚本同目录 vendor/；否则解包 dist 单文件内嵌副本
resolve_vendor() {
  local name="$1"
  local b64var="" local_path="$SCRIPT_DIR/vendor/$name"
  if [[ -f "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi
  case "$name" in
    ChangeMirrors.sh)      b64var="$VENDOR_MAIN_B64" ;;
    DockerInstallation.sh) b64var="$VENDOR_DOCKER_B64" ;;
  esac
  if [[ -n "$b64var" && "$b64var" != __VENDOR_*_B64__ ]]; then
    [[ -z "$VENDOR_TMP" ]] && VENDOR_TMP="$(mktemp -d /tmp/linux-init-vendor.XXXXXX)"
    local out="$VENDOR_TMP/$name"
    # GNU base64 -d / BSD base64 -D 双兼容
    printf '%s' "$b64var" | base64 -d > "$out" 2>/dev/null \
      || printf '%s' "$b64var" | base64 -D > "$out" 2>/dev/null \
      || { err "内嵌 vendor 解包失败: $name"; return 1; }
    chmod +x "$out"
    printf '%s[INFO]%s 使用内嵌 vendor 副本: %s\n' "$C_CYAN" "$C_OFF" "$name" >&2
    echo "$out"
    return 0
  fi
  return 1
}

# 仅清理本脚本创建的 mktemp 目录（模式自检，防止变量异常时误删）
cleanup() {
  if [[ -n "$VENDOR_TMP" && -d "$VENDOR_TMP" && "$VENDOR_TMP" == /tmp/linux-init-vendor.* ]]; then
    rm -rf -- "$VENDOR_TMP"
  fi
  return 0
}

# 文本控制台（tty）检测：内核控制台字体无中文字形，中文必然乱码
is_text_console() {
  [[ "${TERM:-}" == "linux" || -z "${TERM:-}" ]] && return 0
  local cm; cm="$(locale charmap 2>/dev/null || echo unknown)"
  [[ "$cm" != "UTF-8" ]]
}

# ---------------------------------------------------------------- 模块元数据
declare -A MODULE_NAME=(
  [1]="更换国内软件源"              [2]="系统与软件更新"          [3]="时区与时间同步"
  [4]="设置主机名"                  [5]="网络配置(多网卡IP/Hosts)" [6]="关闭防火墙(含SELinux)"
  [7]="内核参数调优"                [8]="安装常用软件"            [9]="创建用户与sudo"
  [10]="安装 Docker"                [11]="SSH 服务加固"           [12]="NVIDIA 驱动与 CUDA"
  [13]="汇总报告与收尾"
)
MODULE_ORDER=(1 2 3 4 5 6 7 8 9 10 11 12 13)

# ================================================================ 模块 1: 换源
step_1() {
  local vendor
  vendor="$(resolve_vendor ChangeMirrors.sh)" || {
    warn "未找到 vendor/ChangeMirrors.sh（本地副本缺失）"
    if [[ $STRICT_MIRROR -eq 1 ]]; then err "换源失败（--strict-mirror 硬失败模式）"; return 1; fi
    warn "按默认软失败策略跳过换源（D10）"; return 0
  }
  local rc=0
  if [[ $ASSUME_YES -eq 1 ]]; then
    local src="${ARG_MIRROR:-mirrors.aliyun.com}"
    local -a args=(--source "$src" --protocol https --backup true
                   --upgrade-software false --clean-cache true --ignore-backup-tips)
    if [[ "$OS_FAMILY" == "rhel" ]]; then args+=(--install-epel true); else args+=(--install-epel false); fi
    info "无人值守换源: $src（EPEL: $([[ "$OS_FAMILY" == "rhel" ]] && echo 安装 || echo 不适用)）"
    bash "$vendor" "${args[@]}"; rc=$?
  else
    info "即将运行 linuxmirrors 换源脚本（交互模式；官方推荐：选择镜像站后一路回车）"
    bash "$vendor"; rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    warn "换源脚本退出码 $rc"
    if [[ $STRICT_MIRROR -eq 1 ]]; then err "换源失败（--strict-mirror）"; return 1; fi
    warn "按默认软失败策略继续（新装机官方源通常可用，D10）"; return 0
  fi
  ok "换源步骤结束"
}

# ================================================================ 模块 2: 更新
step_2() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_sh "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -y" || return 1
    run_sh "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade" || return 1
    run_sh "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge" || true
    if [[ -f /var/run/reboot-required ]]; then
      hint_reboot "系统更新要求重启（/var/run/reboot-required）"
    fi
  else
    run_cmd "$PKG" -y upgrade || return 1
    local latest_installed latest_running
    latest_installed="$(rpm -q kernel 2>/dev/null | sed 's/^kernel-//' | sort -V | tail -1)"
    latest_running="$(uname -r)"
    if [[ -n "$latest_installed" && "$latest_installed" != "$latest_running" ]]; then
      hint_reboot "内核已更新($latest_installed)，当前运行 $latest_running"
    fi
  fi
  ok "系统更新完成"
}

# ================================================================ 模块 3: 时区时间
step_3() {
  local tz="${ARG_TIMEZONE:-Asia/Shanghai}"
  run_cmd timedatectl set-timezone "$tz" || warn "时区设置失败（继续）"
  state_set INFO_TZ "$tz"
  if ! command -v chronyc >/dev/null 2>&1; then
    info "安装 chrony..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
      run_sh "DEBIAN_FRONTEND=noninteractive apt-get install -y chrony" || warn "chrony 安装失败"
    else
      run_cmd "$PKG" install -y chrony || warn "chrony 安装失败"
    fi
  fi
  if command -v chronyc >/dev/null 2>&1; then
    local conf="/etc/chrony.conf" svc="chronyd"
    [[ "$OS_FAMILY" == "debian" ]] && { conf="/etc/chrony/chrony.conf"; svc="chrony"; }
    backup_file "$conf"
    append_block "$conf" "# 国内 NTP 源（模块3）
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
server cn.pool.ntp.org iburst"
    run_cmd systemctl enable --now "$svc" || run_cmd systemctl restart "$svc" || warn "chrony 服务启动失败"
    ok "时间同步: chrony 已启用（ntp.aliyun.com / ntp.tencent.com / cn.pool.ntp.org）"
  fi
  run_cmd hwclock --systohc || true
  local cur_tz; cur_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo "$tz")"
  ok "时区: $cur_tz"
}

# ================================================================ 模块 4: 主机名
step_4() {
  local hn="$ARG_HOSTNAME"
  if [[ -z "$hn" ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then info "未指定 --hostname，跳过主机名设置"; return 0; fi
    info "主机名规范: 小写字母/数字/连字符，如 web-01、ai-gpu-02（直接回车 = 跳过）"
    read -r -p "$(printf '%s请输入新主机名: %s' "$C_CYAN" "$C_OFF")" hn </dev/tty 2>/dev/null || return 0
    [[ -z "$hn" ]] && { info "跳过主机名设置"; return 0; }
  fi
  hn="${hn,,}"
  until valid_hostname "$hn"; do
    warn "非法主机名: $hn（每段 1-63 字符，仅 a-z 0-9 -，连字符不在首尾）"
    read -r -p "$(printf '%s请重新输入主机名(回车跳过): %s' "$C_CYAN" "$C_OFF")" hn </dev/tty 2>/dev/null || return 0
    [[ -z "$hn" ]] && { info "跳过主机名设置"; return 0; }
    hn="${hn,,}"
  done
  local old; old="$(hostname)"
  backup_file /etc/hostname
  run_cmd hostnamectl set-hostname "$hn" || { run_cmd hostname "$hn" || return 1; }
  state_set INFO_HOSTNAME "$hn"
  backup_file /etc/hosts
  append_block /etc/hosts "127.0.1.1	$hn"
  ok "主机名: $old → $hn（sudo 不再报 unable to resolve host）"
}

# ================================================================ 模块 5: 网络
list_nics() {
  ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo/ {print $2}' | awk '{print $1}' | sed 's/@.*//' | sort -u
}
nic_ipv4() { ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1; }
default_route_nic() { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
session_nic() {
  local cip="${SSH_CLIENT%% *}"
  [[ -z "$cip" ]] && return 1
  ip route get "$cip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
nic_gateway() {
  ip route show default 2>/dev/null | awk -v d="$1" '$0 ~ ("dev " d "( |$)") {for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}'
}
nic_mode() {
  local n="$1"
  if command -v nmcli >/dev/null 2>&1; then
    local con
    con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$n" '$2==d{print $1; exit}')"
    [[ -n "$con" ]] && { nmcli -g ipv4.method connection show "$con" 2>/dev/null && return 0; }
  fi
  echo "—"
}
render_nic_table() {
  local -a nics
  mapfile -t nics < <(list_nics)
  local def_r snic i=0 n st ip4 gw mode notes
  def_r="$(default_route_nic || true)"
  snic="$(session_nic 2>/dev/null || true)"
  printf '  %-4s %-12s %-6s %-20s %-16s %-10s %s\n' "序号" "网卡" "状态" "当前IPv4" "网关" "方式" "备注"
  for n in ${nics[@]+"${nics[@]}"}; do
    st="$(cat "/sys/class/net/$n/operstate" 2>/dev/null || echo "?")"
    ip4="$(nic_ipv4 "$n")"; gw="$(nic_gateway "$n")"; mode="$(nic_mode "$n")"
    notes=""
    [[ "$n" == "$def_r" ]] && notes+="默认路由 "
    [[ "$n" == "$snic" ]] && notes+="${C_RED}⚠会话${C_OFF} "
    printf '  %-4s %-12s %-6s %-20s %-16s %-10s %b\n' "$i" "$n" "$st" "${ip4:--}" "${gw:--}" "$mode" "$notes"
    i=$((i + 1))
  done
}
parse_nic_spec() {  # "eth0:CIDR:gw|none[:dns]" → NIC_PLAN+=("nic|cidr|gw|dns")
  local spec="$1" nic cidr gw dns
  IFS=':' read -r nic cidr gw dns <<< "$spec"
  [[ -n "$nic" ]] || { err "--nic 缺少网卡名: $spec"; return 1; }
  valid_cidr "$cidr" || { err "--nic CIDR 非法: $spec（示例 eth0:192.168.1.10/24:192.168.1.1）"; return 1; }
  [[ -n "${gw:-}" ]] || { err "--nic 缺少网关字段（none 表示不配网关）: $spec"; return 1; }
  if [[ "${gw,,}" == "none" ]]; then gw=""; else valid_ipv4 "$gw" || { err "--nic 网关非法: $spec"; return 1; }; fi
  NIC_PLAN+=("$nic|$cidr|$gw|${dns:-${ARG_DNS:-223.5.5.5,119.29.29.29}}")
}
write_hosts_entries() {
  local e ip rest body=""
  local count=0
  for e in ${ARG_HOSTS_ENTRIES[@]+"${ARG_HOSTS_ENTRIES[@]}"}; do
    ip="${e%% *}"; rest="${e#* }"
    valid_ipv4 "$ip" || { err "--hosts-entry IP 非法: $e"; return 1; }
    [[ -n "$rest" && "$rest" != "$e" ]] || { err "--hosts-entry 需包含主机名: $e"; return 1; }
    count=$((count + 1))
  done
  [[ $count -eq 0 ]] && return 0
  backup_file /etc/hosts
  for e in ${ARG_HOSTS_ENTRIES[@]+"${ARG_HOSTS_ENTRIES[@]}"}; do body+="$e"$'\n'; done
  append_block /etc/hosts "${body%$'\n'}"
  ok "Hosts 解析: $count 条已写入 /etc/hosts"
}
write_nic_configs() {  # NIC_PLAN → 按系统族落盘
  local entry nic cidr gw dns ip plen con
  # 预校验 + 多网关警告
  local gw_count=0
  for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
    IFS='|' read -r nic cidr gw dns <<< "$entry"
    [[ -n "$gw" ]] && gw_count=$((gw_count + 1))
    ip -o link show dev "$nic" >/dev/null 2>&1 || { err "网卡不存在: $nic"; return 1; }
  done
  [[ $gw_count -gt 1 ]] && warn "多张网卡配置了默认网关，可能引起路由抖动（D15 策略：仅一张配网关，其余 none）"
  if [[ ${NIC_PLAN[@]+"${NIC_PLAN[@]}"} ]]; then
    for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
      IFS='|' read -r nic cidr gw dns <<< "$entry"
      info "计划: $nic → $cidr  网关: ${gw:-无}  DNS: ${dns:-—}"
    done
  fi
  if [[ "$(session_nic 2>/dev/null || true)" ]]; then
    local snic; snic="$(session_nic)"
    for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
      IFS='|' read -r nic cidr gw dns <<< "$entry"
      if [[ "$nic" == "$snic" ]]; then
        danger "计划修改当前 SSH 会话所在网卡($snic)——可能导致断连！建议改配其他网卡或经带外/云控制台操作"
      fi
    done
  fi
  if [[ $ASSUME_YES -eq 0 ]]; then
    confirm "确认按以上计划写入网络配置？（原配置将备份）" n || { info "已取消网卡配置"; NIC_PLAN=(); return 0; }
  fi
  local family_mode=""
  if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then family_mode="netplan"
  elif command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then family_mode="nmcli"
  elif [[ -d /etc/sysconfig/network-scripts ]]; then family_mode="ifcfg"
  elif [[ -d /etc/network ]]; then family_mode="ifupdown"
  else family_mode="nmcli"; fi
  info "网络配置方式: $family_mode"
  case "$family_mode" in
    netplan)
      local yaml="network:"
      yaml+=$'\n'"  version: 2"
      yaml+=$'\n'"  ethernets:"
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        yaml+=$'\n'"    $nic:"
        yaml+=$'\n'"      dhcp4: false"
        yaml+=$'\n'"      addresses: [$cidr]"
        if [[ -n "$gw" ]]; then
          yaml+=$'\n'"      gateway4: $gw"
        fi
        [[ -n "$dns" ]] && yaml+=$'\n'"      nameservers:"$'\n'"        addresses: [$dns]"
      done
      write_file /etc/netplan/99-linux-init.yaml 600 <<< "$yaml"
      run_cmd chmod 600 /etc/netplan/99-linux-init.yaml
      ;;
    nmcli)
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$nic" '$2==d{print $1; exit}')"
        [[ -z "$con" ]] && { run_cmd nmcli connection add type ethernet ifname "$nic" con-name "$nic" && con="$nic"; }
        ip="${cidr%%/*}"; plen="${cidr#*/}"
        run_cmd nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$ip/$plen"
        [[ -n "$gw" ]] && run_cmd nmcli connection modify "$con" ipv4.gateway "$gw" ipv4.never-default no
        [[ -z "$gw" ]] && run_cmd nmcli connection modify "$con" ipv4.never-default yes
        [[ -n "$dns" ]] && run_cmd nmcli connection modify "$con" ipv4.dns "$dns"
      done
      ;;
    ifcfg)
      local f
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        ip="${cidr%%/*}"; plen="${cidr#*/}"
        f="/etc/sysconfig/network-scripts/ifcfg-$nic"
        backup_file "$f"
        local body="DEVICE=$nic
NAME=$nic
ONBOOT=yes
BOOTPROTO=none
IPADDR=$ip
PREFIX=$plen"
        [[ -n "$gw" ]] && body+=$'\n'"GATEWAY=$gw"
        local d1="${dns%%,*}" d2=""
        [[ "$dns" == *,* ]] && d2="${dns#*,}"
        [[ -n "$d1" ]] && body+=$'\n'"DNS1=$d1"
        [[ -n "$d2" ]] && body+=$'\n'"DNS2=$d2"
        append_block "$f" "$body"
      done
      ;;
    ifupdown)
      local body="" mask
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        ip="${cidr%%/*}"; plen="${cidr#*/}"
        mask="$(prefix_to_mask "$plen")"
        body+="auto $nic"$'\n'"iface $nic inet static"$'\n'"    address $ip"$'\n'"    netmask $mask"$'\n'
        [[ -n "$gw" ]] && body+="    gateway $gw"$'\n'
      done
      append_block /etc/network/interfaces.d/linux-init "${body%$'\n'}"
      ;;
  esac
  if [[ ${#NIC_PLAN[@]} -gt 0 ]]; then
    state_set INFO_NET "$(printf '%s ' ${NIC_PLAN[@]+"${NIC_PLAN[@]}"} | tr '|' ' ')"
    ok "网络配置已写入（默认不激活，重启后生效）"
  fi
}
step_5() {
  write_hosts_entries || return 1
  local has_nic_args=0
  [[ ${#ARG_NICS[@]} -gt 0 ]] && has_nic_args=1
  if [[ $ASSUME_YES -eq 1 ]]; then
    if [[ $has_nic_args -eq 0 ]]; then info "未指定 --nic，跳过网卡配置"; return 0; fi
    local spec
    for spec in ${ARG_NICS[@]+"${ARG_NICS[@]}"}; do parse_nic_spec "$spec" || return 1; done
    apply_nic_activation "$([[ ${#NIC_PLAN[@]} -gt 0 ]] && echo 1 || echo 0)"
    return 0
  fi
  # 交互模式
  if [[ $has_nic_args -eq 0 ]]; then
    render_nic_table
    echo
    info "  a) 配置网卡固定 IP    b) 跳过网卡配置（Hosts 解析已按参数处理）"
    local mode="b"
    read -r -p "$(printf '%s选择 [a/b，默认 b]: %s' "$C_CYAN" "$C_OFF")" mode </dev/tty 2>/dev/null || mode="b"
    [[ "${mode,,}" != "a" ]] && { info "跳过网卡配置"; return 0; }
    render_nic_table
    local sel nic pick tokens token
    read -r -p "$(printf '%s输入要配置的网卡（序号或名称，可多选，如 0 2 或 eth0 ens192）: %s' "$C_CYAN" "$C_OFF")" sel </dev/tty 2>/dev/null || return 0
    [[ -z "$sel" ]] && { info "跳过网卡配置"; return 0; }
    mapfile -t tokens <<< "$sel"
    local -a chosen=()
    local -a all_nics; mapfile -t all_nics < <(list_nics)
    for token in ${tokens[@]+"${tokens[@]}"}; do
      token="${token//[[:space:]]/}"
      [[ -z "$token" ]] && continue
      if [[ "$token" =~ ^[0-9]+$ ]] && [[ "$token" -lt ${#all_nics[@]} ]]; then
        chosen+=("${all_nics[$token]}")
      else
        found=0
        for n in ${all_nics[@]+"${all_nics[@]}"}; do [[ "$n" == "$token" ]] && { chosen+=("$n"); found=1; break; }; done
        [[ $found -eq 0 ]] && warn "忽略无效选择: $token"
      fi
    done
    [[ ${#chosen[@]} -eq 0 ]] && { warn "未选择任何网卡"; return 0; }
    local first=1 cur_gw gw_in dns_in cidr_in
    cur_gw="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}')"
    for nic in ${chosen[@]+"${chosen[@]}"}; do
      local cur_ip; cur_ip="$(nic_ipv4 "$nic")"
      if [[ $first -eq 1 ]]; then
        read -r -p "$(printf '%s[%s] IP/CIDR (回车=沿用 %s): %s' "$C_CYAN" "$nic" "${cur_ip:--}" "$C_OFF")" cidr_in </dev/tty 2>/dev/null || return 0
        cidr_in="${cidr_in:-$cur_ip}"
        read -r -p "$(printf '%s[%s] 网关 (回车=沿用 %s，输入 none 不配网关): %s' "$C_CYAN" "$nic" "${cur_gw:--}" "$C_OFF")" gw_in </dev/tty 2>/dev/null || return 0
        gw_in="${gw_in:-$cur_gw}"
        first=0
      else
        read -r -p "$(printf '%s[%s] IP/CIDR (回车=沿用 %s): %s' "$C_CYAN" "$nic" "${cur_ip:--}" "$C_OFF")" cidr_in </dev/tty 2>/dev/null || return 0
        cidr_in="${cidr_in:-$cur_ip}"
        read -r -p "$(printf '%s[%s] 网关 (回车=none 不配网关): %s' "$C_CYAN" "$nic" "$C_OFF")" gw_in </dev/tty 2>/dev/null || return 0
        gw_in="${gw_in:-none}"
      fi
      gw_in="${gw_in%% }"
      if [[ "${gw_in,,}" != "none" && -n "$gw_in" ]]; then valid_ipv4 "$gw_in" || { err "网关非法: $gw_in"; return 1; }; fi
      read -r -p "$(printf '%s[%s] DNS (回车=%s): %s' "$C_CYAN" "$nic" "${ARG_DNS:-223.5.5.5,119.29.29.29}" "$C_OFF")" dns_in </dev/tty 2>/dev/null || return 0
      dns_in="${dns_in:-${ARG_DNS:-223.5.5.5,119.29.29.29}}"
      [[ "$cidr_in" != */* ]] && { cidr_in="$cidr_in/24"; info "未带掩码位，按 /24 处理: $cidr_in"; }
      valid_cidr "$cidr_in" || { err "CIDR 非法: $cidr_in"; return 1; }
      [[ "${gw_in,,}" == "none" ]] && gw_in=""
      NIC_PLAN+=("$nic|$cidr_in|$gw_in|$dns_in")
    done
    apply_nic_activation 1
    return 0
  fi
  # 交互 + 显式 --nic 参数
  local spec
  for spec in ${ARG_NICS[@]+"${ARG_NICS[@]}"}; do parse_nic_spec "$spec" || return 1; done
  apply_nic_activation 1
}
apply_nic_activation() {  # $1: 是否有计划(1/0)
  [[ "${1:-0}" -eq 1 ]] || return 0
  write_nic_configs || return 1
  [[ ${#NIC_PLAN[@]} -eq 0 ]] && return 0
  [[ $DRY_RUN -eq 1 ]] && return 0
  if confirm "是否立即激活网络配置？（默认否=仅写入，重启后生效，更安全）" n; then
    if command -v netplan >/dev/null 2>&1; then
      info "netplan try: 120 秒内未确认将自动回滚"
      run_cmd netplan try || warn "netplan try 失败或超时回滚（原配置保留）"
    else
      local entry nic con snic
      snic="$(session_nic 2>/dev/null || true)"
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        [[ "$nic" == "$snic" ]] && continue
        con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$nic" '$2==d{print $1; exit}')"
        [[ -n "$con" ]] && run_cmd nmcli connection up "$con" || warn "激活失败: $nic"
      done
      for entry in ${NIC_PLAN[@]+"${NIC_PLAN[@]}"}; do
        IFS='|' read -r nic cidr gw dns <<< "$entry"
        [[ "$nic" != "$snic" ]] && continue
        danger "激活会话所在网卡 $snic —— 可能断连"
        confirm "确认激活 $snic？" n || { warn "已跳过 $snic（重启后生效）"; continue; }
        con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$nic" '$2==d{print $1; exit}')"
        [[ -n "$con" ]] && run_cmd nmcli connection up "$con" || warn "激活失败: $nic"
      done
    fi
  else
    hint_reboot "网卡静态 IP 配置已写入，重启后生效"
  fi
}

# ================================================================ 模块 6: 防火墙 + SELinux
step_6() {
  if [[ $KEEP_FIREWALL -eq 1 ]]; then
    info "已选择保留防火墙(--keep-firewall)；模块 11 将放行新 SSH 端口"
    state_set FIREWALL_KEPT 1
  else
    danger "关闭防火墙后端口全部暴露——公网机器的访问控制责任转移到云厂商安全组"
    confirm "确认关闭防火墙？" n || { info "已取消（可稍后单独运行模块 6）"; return 0; }
    if [[ "$FW_TOOL" == "ufw" ]] && command -v ufw >/dev/null 2>&1; then
      run_cmd ufw disable || warn "ufw disable 失败"
    fi
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "firewalld.service"; then
      run_cmd systemctl disable --now firewalld || true
      run_cmd systemctl mask firewalld || true
    fi
    if systemctl is-active nftables >/dev/null 2>&1; then
      run_cmd systemctl disable --now nftables || true
    fi
    ok "防火墙已关闭"
  fi
  # SELinux（RedHat 系；D6: 默认关闭）
  if command -v getenforce >/dev/null 2>&1; then
    local cur; cur="$(getenforce 2>/dev/null || echo Unknown)"
    if [[ $SELINUX_ENFORCING -eq 1 ]]; then
      info "保留 SELinux enforcing（--selinux-enforcing）"
      state_set SELINUX_MODE enforcing
    elif [[ "$cur" != "Disabled" ]]; then
      danger "即将关闭 SELinux（D6 默认行为）: setenforce 0 + /etc/selinux/config → disabled"
      state_set SELINUX_ORIG "$cur"
      run_cmd setenforce 0 || warn "setenforce 失败"
      if [[ -f /etc/selinux/config ]]; then
        backup_file /etc/selinux/config
        run_sh "sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config; grep -q '^SELINUX=' /etc/selinux/config || echo 'SELINUX=disabled' >> /etc/selinux/config"
      fi
      state_set SELINUX_MODE disabled
      ok "SELinux 已关闭（当前会话立即生效；完全生效需重启）"
    fi
  fi
}

# ================================================================ 模块 7: 内核调优
ensure_limits_block() {  # $1: 是否含 memlock(yes/no)
  local lim="/etc/security/limits.d/99-linux-init.conf" memlock="$1"
  backup_file "$lim"
  local body="* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576"
  [[ "$memlock" == "yes" ]] && body+=$'\n'"* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited"
  append_block "$lim" "$body"
}
step_7() {
  local profile
  case "$ARG_TUNE" in
    off) info "已选择关闭内核调优(--tune off)"; return 0 ;;
    aggressive) profile="aggressive" ;;
    *) profile="mild" ;;
  esac
  state_set INFO_TUNE "$profile"
  local conf="/etc/sysctl.d/99-linux-init.conf"
  backup_file "$conf"
  local body="# BBR 拥塞控制 + fq 队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 连接队列
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
# 文件描述符
fs.file-max = 1048576
# 端口范围与复用
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
# 内存
vm.swappiness = 10"
  if [[ "$profile" == "aggressive" ]]; then
    body+=$'\n'"# —— 激进档（大并发 / AI 推理服务器）——
fs.file-max = 2097152
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.inotify.max_user_watches = 1048576
vm.max_map_count = 262144"
  fi
  append_block "$conf" "$body"
  run_cmd sysctl --system
  local errs
  errs="$(sysctl -p "$conf" 2>&1 >/dev/null | grep -iE 'cannot|invalid|no such' || true)"
  [[ -n "$errs" ]] && warn "部分参数当前内核不支持（已忽略，不影响其余参数）:""$'\n'""$errs"
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo)" != "bbr" ]]; then
    warn "BBR 未生效（内核过旧？其余参数仍已应用）"
  fi
  ensure_limits_block "$([[ "$profile" == "aggressive" ]] && echo yes || echo no)"
  ok "内核调优已应用（$profile 档）"
}

# ================================================================ 模块 8: 常用软件
step_8() {
  local grp="${ARG_TOOLS:-basic}"
  [[ "$grp" == "none" ]] && { info "已选择不安装常用软件(--tools none)"; return 0; }
  if [[ $ASSUME_YES -eq 0 && $ARG_TOOLS_SET -eq 0 ]]; then
    confirm "是否额外安装开发工具组 dev（gcc/make/python3-pip/tmux/tcpdump 等）？" n && grp="dev"
  fi
  local -a basic_pkgs dev_pkgs all=()
  if [[ "$OS_FAMILY" == "debian" ]]; then
    basic_pkgs=(vim wget curl git htop tree jq unzip zip lsof rsync net-tools bash-completion lrzsz sysstat iotop man-db manpages pciutils ca-certificates)
    dev_pkgs=(build-essential dkms python3-pip python3-venv tmux mtr tcpdump strace file dos2unix)
  else
    "$PKG" list installed epel-release >/dev/null 2>&1 || run_cmd "$PKG" install -y epel-release || warn "epel-release 安装失败（htop/jq 等可能缺包）"
    basic_pkgs=(vim-enhanced wget curl git htop tree jq unzip zip lsof rsync net-tools bash-completion lrzsz sysstat iotop man-pages pciutils ca-certificates)
    dev_pkgs=(gcc gcc-c++ make dkms python3-pip tmux mtr tcpdump strace file dos2unix)
  fi
  all=("${basic_pkgs[@]}")
  [[ "$grp" == "dev" ]] && all+=("${dev_pkgs[@]}")
  info "安装软件包（${#all[@]} 个, $grp 组）: ${all[*]}"
  if ! run_cmd "$PKG" install -y ${all[@]+"${all[@]}"}; then
    warn "批量安装失败，改为逐个尽力安装..."
    local p
    for p in ${all[@]+"${all[@]}"}; do
      run_cmd "$PKG" install -y "$p" || warn "安装失败(跳过): $p"
    done
  fi
  ok "常用软件安装完成（$grp 组）"
}

# ================================================================ 模块 9: 用户与 sudo
get_user_password() {
  if [[ -n "${LINUX_INIT_USER_PASSWORD:-}" ]]; then USER_PASSWORD="$LINUX_INIT_USER_PASSWORD"; return 0; fi
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local p1 p2
  while true; do
    read -rs -p "$(printf '%s请输入 %s 的密码(不回显，直接回车=不设密码): %s' "$C_CYAN" "$TARGET_USER" "$C_OFF")" p1 </dev/tty 2>/dev/null || return 0
    printf '\n'
    [[ -z "$p1" ]] && { warn "不设置密码（仅密钥登录，本地控制台无法登录）"; return 0; }
    [[ ${#p1} -lt 8 ]] && warn "密码少于 8 位，建议加强"
    read -rs -p "再次输入确认: " p2 </dev/tty 2>/dev/null || return 0
    printf '\n'
    if [[ "$p1" == "$p2" ]]; then USER_PASSWORD="$p1"; return 0; fi
    err "两次输入不一致，请重试"
  done
}
pubkey_url_safe() {
  url_is_safe "$1" && return 0
  err "pubkey-url 仅允许 https 且不得指向本机/内网/保留地址: $1"
  return 1
}
collect_pubkeys() {  # 汇总 ARG_PUBKEYS(内联) / 文件 / URL / 交互粘贴 → PUBKEYS
  PUBKEYS=()
  local k line
  for k in ${ARG_PUBKEYS[@]+"${ARG_PUBKEYS[@]}"}; do
    valid_pubkey "$k" && PUBKEYS+=("$k") || warn "忽略无效公钥: ${k:0:30}..."
  done
  if [[ -n "$ARG_PUBKEY_FILE" ]]; then
    [[ -r "$ARG_PUBKEY_FILE" ]] || { err "公钥文件不可读: $ARG_PUBKEY_FILE"; return 1; }
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != \#* ]] && valid_pubkey "$line" && PUBKEYS+=("$line")
    done < "$ARG_PUBKEY_FILE"
  fi
  if [[ -n "$ARG_PUBKEY_URL" ]]; then
    pubkey_url_safe "$ARG_PUBKEY_URL" || return 1
    local fetched
    fetched="$(curl -fsSL --max-time 15 "$ARG_PUBKEY_URL" 2>/dev/null)" || { err "公钥 URL 拉取失败: $ARG_PUBKEY_URL"; return 1; }
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != \#* ]] && valid_pubkey "$line" && PUBKEYS+=("$line")
    done <<< "$fetched"
  fi
  if [[ ${#PUBKEYS[@]} -eq 0 && $ASSUME_YES -eq 0 ]]; then
    info "请粘贴 SSH 公钥（可多行，每行一条；空行结束）"
    while IFS= read -r line </dev/tty 2>/dev/null; do
      [[ -z "${line//[[:space:]]/}" ]] && break
      valid_pubkey "$line" && PUBKEYS+=("$line") || warn "忽略无效行: ${line:0:30}..."
    done
  fi
  [[ ${#PUBKEYS[@]} -gt 0 ]] && ok "已收集公钥 ${#PUBKEYS[@]} 条"
  return 0
}
write_authorized_keys() {
  local home ak grp tmp
  home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -d "$home" ]] || { err "用户家目录不存在: $home"; return 1; }
  grp="$(id -gn "$TARGET_USER")"
  tmp="$(mktemp)"
  printf '%s\n' ${PUBKEYS[@]+"${PUBKEYS[@]}"} > "$tmp"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将写入 $home/.ssh/authorized_keys（${#PUBKEYS[@]} 条）"
    rm -f "$tmp"; return 0
  fi
  install -d -m 700 -o "$TARGET_USER" -g "$grp" "$home/.ssh"
  install -m 600 -o "$TARGET_USER" -g "$grp" "$tmp" "$home/.ssh/authorized_keys"
  rm -f "$tmp"
  ok "公钥已写入: $home/.ssh/authorized_keys"
}
step_9() {
  # 用户名
  if [[ -z "$TARGET_USER" ]]; then
    [[ $ASSUME_YES -eq 1 ]] && die 13 "无人值守模式必须指定 --user"
    while true; do
      read -r -p "$(printf '%s请输入新用户名: %s' "$C_CYAN" "$C_OFF")" TARGET_USER </dev/tty 2>/dev/null || return 1
      [[ -z "$TARGET_USER" ]] && continue
      valid_username "$TARGET_USER" || { warn "非法/保留用户名: $TARGET_USER"; continue; }
      id -u "$TARGET_USER" >/dev/null 2>&1 && { warn "用户已存在: $TARGET_USER（将补齐配置）"; }
      break
    done
  fi
  local created=0
  if id -u "$TARGET_USER" >/dev/null 2>&1; then
    info "用户已存在: $TARGET_USER（补齐组/凭据/公钥）"
  else
    run_cmd useradd -m -s /bin/bash "$TARGET_USER" || { err "创建用户失败: $TARGET_USER"; return 1; }
    created=1
  fi
  run_cmd usermod -aG "$SUDO_GROUP" "$TARGET_USER" || warn "加入 $SUDO_GROUP 组失败"
  # 凭据
  collect_pubkeys || return 1
  get_user_password
  if [[ -n "$USER_PASSWORD" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] 将为 $TARGET_USER 设置密码（值不落日志）"
    else
      printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | run_cmd chpasswd && ok "密码已设置（值不落日志）"
    fi
  elif [[ ${#PUBKEYS[@]} -eq 0 ]]; then
    err "必须提供密码（环境变量 LINUX_INIT_USER_PASSWORD）或至少一条 SSH 公钥"
    return 1
  else
    warn "未设置密码：SSH 走密钥、sudo 走免密（D3），但本地控制台无法登录该用户"
  fi
  [[ ${#PUBKEYS[@]} -gt 0 ]] && write_authorized_keys
  # sudo 策略（D3: 默认 NOPASSWD）
  if [[ $SUDO_REQUIRE_PASSWORD -eq 0 ]]; then
    local sud="/etc/sudoers.d/99-linux-init"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] 将写入 $sud: $TARGET_USER ALL=(ALL) NOPASSWD:ALL"
    else
      local tmp; tmp="$(mktemp)"
      printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" > "$tmp"
      if visudo -cf "$tmp" >/dev/null 2>&1; then
        install -m 440 "$tmp" "$sud"
        danger "已配置 sudo NOPASSWD 免密（等价 root 权限，D3 默认）；如需改回: rm $sud"
      else
        err "sudoers 语法校验失败，未启用免密"
      fi
      rm -f "$tmp"
    fi
  else
    info "sudo 需要密码模式（--sudo-require-password）"
  fi
  state_set INFO_USER "$TARGET_USER"
  if [[ $DRY_RUN -eq 0 ]]; then
    id "$TARGET_USER" >/dev/null && ok "用户验证: $(id "$TARGET_USER")"
    visudo -c >/dev/null 2>&1 && ok "sudoers 语法校验通过" || warn "sudoers 校验异常，请人工检查"
    su - "$TARGET_USER" -c 'true' >/dev/null 2>&1 && ok "用户登录 shell 可用"
  fi
}

# ================================================================ 模块 10: Docker
step_10() {
  local vendor rc=0
  vendor="$(resolve_vendor DockerInstallation.sh)" || { err "未找到 vendor/DockerInstallation.sh"; return 1; }
  command -v jq >/dev/null 2>&1 || run_cmd "$PKG" install -y jq || true
  if command -v docker >/dev/null 2>&1; then
    info "检测到已安装 Docker → 仅更换镜像加速器模式（--only-registry）"
    local -a args=(--only-registry)
    [[ -n "$ARG_DOCKER_REGISTRY" ]] && args+=(--source-registry "$ARG_DOCKER_REGISTRY")
    bash "$vendor" ${args[@]+"${args[@]}"}; rc=$?
  elif [[ $ASSUME_YES -eq 1 ]]; then
    local reg="${ARG_DOCKER_REGISTRY:-docker.1ms.run}"
    info "无人值守安装 Docker（CE 源: mirrors.tencent.com/docker-ce，加速器: $reg）"
    bash "$vendor" --source mirrors.tencent.com/docker-ce --source-registry "$reg" \
      --protocol https --install-latest true --close-firewall false --ignore-backup-tips
    rc=$?
  else
    info "即将运行 linuxmirrors Docker 安装脚本（交互模式：自选 Docker CE 源与镜像加速器）"
    warn "提示: 该脚本交互过程会清屏，属正常现象（日志中此处中断不影响执行）"
    bash "$vendor"; rc=$?
  fi
  [[ $rc -ne 0 ]] && { warn "docker.sh 退出码 $rc"; return 1; }
  run_cmd systemctl enable --now docker || true
  if [[ -n "$TARGET_USER" ]] && id -u "$TARGET_USER" >/dev/null 2>&1; then
    run_cmd usermod -aG docker "$TARGET_USER"
    danger "docker 组等价 root 权限：$TARGET_USER 已加入（重新登录后生效）"
  fi
  if [[ $DRY_RUN -eq 0 ]] && command -v docker >/dev/null 2>&1; then
    local dver; dver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    state_set INFO_DOCKER "$dver"
    ok "Docker 版本: $dver"
    docker compose version >/dev/null 2>&1 && ok "Docker Compose 插件可用" || warn "Docker Compose 插件不可用"
    if timeout 90 docker run --rm hello-world >/dev/null 2>&1; then
      ok "hello-world 冒烟测试通过"
    else
      warn "hello-world 拉取失败（多为加速器抽风，不阻断）"
    fi
  fi
}

# ================================================================ 模块 11: SSH 加固
ssh_rollback() {
  err "回滚 SSH 配置..."
  [[ -f "$BACKUP_DIR/etc/ssh/sshd_config" ]] && cp -a "$BACKUP_DIR/etc/ssh/sshd_config" /etc/ssh/sshd_config
  local f
  for f in "$BACKUP_DIR"/etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" ]] && cp -a "$f" "/etc/ssh/sshd_config.d/$(basename "$f")"
  done
  rm -f /etc/ssh/sshd_config.d/00-linux-init.conf
  "$SSHD_BIN" -t >/dev/null 2>&1 && systemctl restart "$SSH_SVC" >/dev/null 2>&1 && ok "已回滚并重启 sshd（原配置）"
}
step_11() {
  # ---- 防锁死前置校验（安全红线） ----
  if [[ -z "$TARGET_USER" ]] || ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      err "模块 11 需要已创建的非 root 用户（模块 9）；--yes 模式请通过 --user 指定"
      return 1
    fi
    confirm "尚未创建/指定非 root 用户，是否先运行模块 9？" y || return 1
    run_module 9 || return 1
  fi
  local home ak
  home="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
  ak="$home/.ssh/authorized_keys"
  if [[ ! -s "$ak" ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      err "用户 $TARGET_USER 无 authorized_keys —— 防锁死红线：拒绝禁用密码登录"
      return 1
    fi
    warn "用户 $TARGET_USER 尚无 SSH 公钥（安全红线：必须先配置密钥）"
    collect_pubkeys || return 1
    [[ ${#PUBKEYS[@]} -gt 0 ]] || { err "未提供任何公钥，放弃 SSH 加固"; return 1; }
    write_authorized_keys || return 1
  fi
  # ---- 端口 ----
  local port="${ARG_SSH_PORT:-22222}"
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || { err "非法端口: $port（1024-65535）"; return 1; }
  if [[ "$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":$port$")" ]]; then
    warn "端口 $port 已被占用:"; ss -tln | grep ":$port " || true
  fi
  # ---- 备份 + 清理冲突指令 ----
  backup_file /etc/ssh/sshd_config
  local f
  for f in /etc/ssh/sshd_config.d/*.conf; do [[ -f "$f" ]] && backup_file "$f"; done 2>/dev/null
  run_sh "for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do [ -f \"\$f\" ] && sed -i 's/^[[:space:]]*Port[[:space:]]/# linux-init: Port /' \"\$f\"; done; true"
  # ---- 写目标配置 ----
  local content="Port $port
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes"
  if "$SSHD_BIN" -t -o "KbdInteractiveAuthentication=no" >/dev/null 2>&1; then
    content+=$'\n'"KbdInteractiveAuthentication no"
  elif "$SSHD_BIN" -t -o "ChallengeResponseAuthentication=no" >/dev/null 2>&1; then
    content+=$'\n'"ChallengeResponseAuthentication no"
  fi
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
    # drop-in：00- 前缀确保优先于云镜像自带的 50-cloud-init.conf 等既有 drop-in
    info "写入 drop-in: /etc/ssh/sshd_config.d/00-linux-init.conf"
    run_cmd mkdir -p /etc/ssh/sshd_config.d
    write_file /etc/ssh/sshd_config.d/00-linux-init.conf 600 <<< "$content"
  else
    info "主配置无 Include（老系统），头部插入标记块"
    prepend_block /etc/ssh/sshd_config "$content"
  fi
  # ---- Ubuntu ssh.socket 兼容 ----
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    warn "检测到 ssh.socket 激活模式（Ubuntu 22.10+），迁移为 ssh.service"
    run_cmd systemctl disable --now ssh.socket || true
    run_cmd systemctl enable ssh.service || true
  fi
  # ---- SELinux（保留 enforcing 时放行端口） ----
  if [[ "$(state_get SELINUX_MODE)" == "enforcing" || "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    info "SELinux enforcing: 放行端口 $port"
    command -v semanage >/dev/null 2>&1 || run_cmd "$PKG" install -y policycoreutils-python-utils || true
    run_sh "semanage port -a -t ssh_port_t -p tcp $port 2>/dev/null || semanage port -m -t ssh_port_t -p tcp $port" \
      || warn "semanage 失败——若 sshd 启动失败请检查 SELinux"
  fi
  # ---- 防火墙联动（保留防火墙时放行新端口） ----
  if [[ "$(state_get FIREWALL_KEPT)" == "1" ]]; then
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
      run_cmd firewall-cmd --permanent --add-port="$port/tcp" && run_cmd firewall-cmd --reload
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      run_cmd ufw allow "$port/tcp"
    fi
  fi
  # ---- 语法校验 + 重启 ----
  if ! run_cmd "$SSHD_BIN" -t; then
    err "sshd -t 校验失败，尝试移除兼容指令后重试..."
    if [[ -f /etc/ssh/sshd_config.d/00-linux-init.conf ]]; then
      run_sh "sed -i '/KbdInteractiveAuthentication/d;/ChallengeResponseAuthentication/d' /etc/ssh/sshd_config.d/00-linux-init.conf"
    else
      run_sh "sed -i '/KbdInteractiveAuthentication/d;/ChallengeResponseAuthentication/d' /etc/ssh/sshd_config"
    fi
    "$SSHD_BIN" -t >/dev/null 2>&1 || { err "仍校验失败，回滚"; ssh_rollback; return 1; }
    warn "已移除兼容指令并通过校验"
  fi
  run_cmd systemctl restart "$SSH_SVC" || { err "sshd 重启失败，回滚"; ssh_rollback; return 1; }
  # ---- 生效验证 ----
  if ss -tln 2>/dev/null | grep -qE ":$port[[:space:]]"; then
    ok "sshd 已监听新端口 $port"
  else
    warn "未检测到端口 $port 监听，请人工确认: ss -tlnp | grep sshd"
  fi
  local eff
  eff="$("$SSHD_BIN" -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) ' || true)"
  info "生效配置:"; printf '%s\n' "$eff" | sed 's/^/    /'
  state_set INFO_SSH_PORT "$port"
  danger "SSH 加固完成 —— 请勿关闭当前会话！"
  info "  1. 新开终端验证: ssh -p $port $TARGET_USER@<本机IP>（密钥登录）"
  info "  2. 确认 sudo 可用"
  info "  3. 确认旧端口(22)/root/密码登录均被拒绝"
  info "  4. 全部通过后再退出当前会话"
}

# ================================================================ 模块 12: NVIDIA
map_gpu_arch() {  # $1 = 显卡名(小写) → ARCH/MIN_DRV/MODULE_REQ
  local n="$1"
  case "$n" in
    *"rtx pro 6000"*|*"rtx 50"*|*b100*|*b200*|*b300*|*blackwell*) ARCH="blackwell"; MIN_DRV=570; MODULE_REQ="open" ;;
    *h100*|*h200*|*h20*)                                          ARCH="hopper";   MIN_DRV=545; MODULE_REQ="open" ;;
    *"rtx 40"*|*ada*)                                             ARCH="ada";      MIN_DRV=520; MODULE_REQ="either" ;;
    *"rtx 30"*|*a100*|*a800*|*a30*|*a40*|*a16*|*a2)               ARCH="ampere";   MIN_DRV=470; MODULE_REQ="either" ;;
    *"rtx 20"*|*"gtx 16"*)                                        ARCH="turing";   MIN_DRV=440; MODULE_REQ="either" ;;
    *"gtx 10"*|*"gtx 9"*|*p100*|*p40*|*p6*|*p4*|*p102*|*p106*)    ARCH="pascal";   MIN_DRV=375; MODULE_REQ="proprietary" ;;
    *)                                                            ARCH="unknown";  MIN_DRV=470; MODULE_REQ="either" ;;
  esac
}
gpu_pretty() {  # 从 lspci 行提取显卡市场名（可移植实现，不依赖 GNU sed 分支）
  local l="$1" n="" re
  # 注意 POSIX 方括号类中反斜杠是字面量：排除 ] 必须写 [^]] 而非 [^\]]
  re='\[([^]]+)\] \[10de:[0-9a-fA-F]{4}\]'
  if [[ "$l" =~ $re ]]; then n="${BASH_REMATCH[1]}"
  else
    re='NVIDIA Corporation ([^\[]+)\['
    [[ "$l" =~ $re ]] || re='NVIDIA ([^\[]+)\['
    [[ "$l" =~ $re ]] && n="${BASH_REMATCH[1]}"
  fi
  n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
  printf '%s' "$n"
}
cuda_max_for_driver() {  # $1=驱动分支数字 → 输出最高 CUDA (格式 13-0)
  local b="$1"
  if   (( b >= 580 )); then echo "13-0"
  elif (( b >= 575 )); then echo "12-8"
  elif (( b >= 570 )); then echo "12-8"
  elif (( b >= 560 )); then echo "12-6"
  elif (( b >= 550 )); then echo "12-4"
  else                      echo "12-2"; fi
}
nvidia_pick_driver() {  # $1=gpu名 → CHOSEN_DRIVER（空=未找到）
  CHOSEN_DRIVER=""
  map_gpu_arch "${1,,}"
  info "GPU 架构识别: $ARCH（内核模块要求: $MODULE_REQ，最低驱动 $MIN_DRV）"
  dpkg -s ubuntu-drivers-common >/dev/null 2>&1 || run_cmd apt-get install -y ubuntu-drivers-common || true
  local recommended=""
  if command -v ubuntu-drivers >/dev/null 2>&1; then
    recommended="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/{for(i=1;i<=NF;i++) if($i ~ /^nvidia-driver-[0-9]+/) print $i}' | head -1)"
    [[ -n "$recommended" ]] && info "ubuntu-drivers 推荐: $recommended"
  fi
  local -a candidates=()
  mapfile -t candidates < <(apt-cache search --names-only '^nvidia-driver-[0-9]+(-open)?$' 2>/dev/null | awk '{print $1}')
  local c num ok_flag best="" best_num=0 best_open="" best_open_num=0
  for c in ${candidates[@]+"${candidates[@]}"}; do
    num="$(printf '%s' "$c" | grep -Eo '[0-9]+' | head -1)"
    [[ -z "$num" ]] && continue
    (( num >= MIN_DRV )) || continue
    case "$MODULE_REQ" in
      open)        [[ "$c" == *-open ]] || continue ;;
      proprietary) [[ "$c" != *-open ]] || continue ;;
    esac
    if [[ "$c" == *-open ]]; then
      if (( num > best_open_num )); then best_open="$c"; best_open_num=$num; fi
    else
      if (( num > best_num )); then best="$c"; best_num=$num; fi
    fi
  done
  # recommended 满足约束则优先
  if [[ -n "$recommended" ]]; then
    local rnum; rnum="$(printf '%s' "$recommended" | grep -Eo '[0-9]+' | head -1)"
    local rcompliant=1
    case "$MODULE_REQ" in
      open)        [[ "$recommended" == *-open ]] || rcompliant=0 ;;
      proprietary) [[ "$recommended" != *-open ]] || rcompliant=0 ;;
    esac
    [[ -n "$rnum" && "$rnum" -ge "$MIN_DRV" ]] || rcompliant=0
    if [[ $rcompliant -eq 1 ]]; then CHOSEN_DRIVER="$recommended"; return 0; fi
  fi
  # 无推荐：偶数稳定分支优先（open 与 proprietary 各取最高，再按架构要求挑选）
  local pick=""
  if [[ "$MODULE_REQ" == "open" ]]; then pick="$best_open"
  elif [[ "$MODULE_REQ" == "proprietary" ]]; then pick="$best"
  else
    # either：open 可用则优先 open 的最高偶数分支，否则 proprietary
    if [[ -n "$best_open" ]] && (( best_open_num % 2 == 0 )); then pick="$best_open"
    elif [[ -n "$best" ]] && (( best_num % 2 == 0 )); then pick="$best"
    elif [[ -n "$best_open" ]]; then pick="$best_open"
    else pick="$best"; fi
  fi
  CHOSEN_DRIVER="$pick"
}
install_cuda_toolkit() {  # 依赖: state NVIDIA_DRIVER
  local branch; branch="$(printf '%s' "$(state_get NVIDIA_DRIVER)" | grep -Eo '[0-9]+' | head -1)"
  local want="${ARG_CUDA_VER:-}" maxv
  maxv="$(cuda_max_for_driver "${branch:-535}")"
  maxv_dotted="${maxv//-/.}"
  if [[ -z "$want" ]]; then
    want="$maxv"
    info "未指定 CUDA 版本 → 按驱动($branch)自动匹配最高支持: CUDA ${maxv_dotted}"
  else
    want="${want//./-}"   # 13.0 → 13-0
    local need_drv
    case "$want" in
      13-*) need_drv=580 ;; 12-8) need_drv=570 ;; 12-6) need_drv=560 ;; 12-4) need_drv=550 ;; 12-2) need_drv=535 ;;
      *) need_drv=0 ;;
    esac
    if (( need_drv > 0 && branch > 0 && branch < need_drv )); then
      warn "CUDA $want 需要驱动 ≥ $need_drv，当前 $branch → 跳过 CUDA 安装（可升级驱动后重跑）"
      return 1
    fi
  fi
  # Ubuntu 26.04+: 系统源原生收录 CUDA
  if (( ${OS_VER_MAJOR:-0} >= 26 )); then
    if run_cmd apt-get install -y "cuda-toolkit-$want"; then ok "CUDA Toolkit $want 安装完成（系统源）"; return 0; fi
    warn "系统源无 cuda-toolkit-$want，尝试 NVIDIA 官方仓库..."
  fi
  # NVIDIA CUDA 仓库（TUNA 镜像优先，官方回退）
  local utag arch_tag base url ok_key=0
  utag="ubuntu${OS_VER/./}"
  [[ "$utag" != "ubuntu2004" && "$utag" != "ubuntu2204" && "$utag" != "ubuntu2404" ]] && utag="ubuntu2404"
  arch_tag="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  [[ "$arch_tag" == "amd64" ]] && arch_tag="x86_64"
  for base in "https://mirrors.tuna.tsinghua.edu.cn/nvidia-cuda" "https://developer.download.nvidia.com"; do
    url="$base/compute/cuda/repos/$utag/cuda-keyring_1.1-1_all.deb"
    info "尝试获取 CUDA 仓库密钥: $url"
    if curl -fsSL --max-time 20 "$url" -o /tmp/cuda-keyring.deb 2>/dev/null; then ok_key=1; break; fi
  done
  if [[ $ok_key -eq 0 ]]; then warn "无法下载 CUDA 仓库密钥（网络受限）→ 跳过 CUDA"; return 1; fi
  run_cmd dpkg -i /tmp/cuda-keyring.deb || return 1
  rm -f /tmp/cuda-keyring.deb
  run_sh "apt-get update -y" || return 1
  if run_cmd apt-get install -y "cuda-toolkit-$want"; then
    ok "CUDA Toolkit $want 安装完成（NVIDIA 仓库，版本锁定）"
  else
    warn "cuda-toolkit-$want 安装失败（仓库可能不含该版本）"; return 1
  fi
}
install_nvidia_container_toolkit() {
  run_sh "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg" \
    || { warn "container-toolkit 密钥获取失败"; return 1; }
  run_sh "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list" \
    || { warn "container-toolkit 仓库配置失败"; return 1; }
  run_sh "apt-get update -y && apt-get install -y nvidia-container-toolkit" || { warn "nvidia-container-toolkit 安装失败"; return 1; }
  run_cmd nvidia-ctk runtime configure --runtime=docker || true
  run_cmd systemctl restart docker || true
  ok "nvidia-container-toolkit 已配置"
}
nvidia_verify() {  # nvidia-smi 可用后的验证流程（重启后重跑也走这里）
  local gpus drvver
  nvidia-smi || { err "nvidia-smi 执行失败"; return 1; }
  gpus="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
  drvver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  ok "GPU 数量: $gpus，驱动版本: $drvver"
  state_set INFO_NVIDIA "${drvver:-unknown}（${gpus} 卡）"
  systemctl enable --now nvidia-persistenced >/dev/null 2>&1 || nvidia-smi -pm 1 >/dev/null 2>&1 || true
  ok "持久化模式已启用（nvidia-persistenced / persistence mode）"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local branch cv utag tag
    branch="$(printf '%s' "$drvver" | grep -Eo '^[0-9]+' | head -1)"
    cv="$(cuda_max_for_driver "${branch:-580}")"; cv="${cv//-/.}"
    [[ "$cv" =~ ^[0-9]+\.[0-9]+$ ]] && cv="${cv}.0"   # 镜像 tag 为三段式版本号（如 13.0.0）
    utag="ubuntu${OS_VER/./}"
    [[ "$utag" != "ubuntu2004" && "$utag" != "ubuntu2204" && "$utag" != "ubuntu2404" ]] && utag="ubuntu2404"
    tag="nvidia/cuda:${cv}-base-${utag}"
    info "容器 GPU 冒烟测试: docker run --gpus all $tag"
    if timeout 180 docker run --rm --gpus all "$tag" nvidia-smi >/dev/null 2>&1; then
      ok "容器内 GPU 直通正常"
    else
      warn "容器 GPU 冒烟失败（镜像拉取或 toolkit 配置问题，不阻断；可查 docker info | grep -i runtime）"
    fi
  fi
}
step_12() {
  # v1 仅 Ubuntu（D2）
  if [[ "$OS_ID" != "ubuntu" ]]; then
    warn "NVIDIA 模块 v1 仅支持 Ubuntu（D2 已确认），当前系统 $OS_ID → 跳过"
    return 0
  fi
  local gpu_list gpu_name count
  gpu_list="$(lspci -nn -d 10de: 2>/dev/null | grep -iE 'vga|3d|display' || true)"
  [[ -z "$gpu_list" ]] && gpu_list="$(lspci -nn -d 10de: 2>/dev/null || true)"
  if [[ -z "$gpu_list" ]]; then
    info "未检测到 NVIDIA 显卡 → 自动跳过（零改动，不算失败）"
    return 0
  fi
  count="$(grep -c . <<< "$gpu_list")"
  info "检测到 $count 张 NVIDIA GPU:"
  printf '%s\n' "$gpu_list" | sed 's/^/    /'
  # 型号提取：优先取 [10de:xxxx] 前的市场名括号（如 GeForce RTX 3090），回退到 codename
  gpu_name="$(gpu_pretty "${gpu_list%%$'\n'*}")"
  [[ -z "$gpu_name" ]] && gpu_name="NVIDIA GPU"
  [[ -z "$gpu_name" ]] && gpu_name="NVIDIA GPU"
  info "显卡型号: $gpu_name"
  # 断点续跑：装过驱动 → 等验证
  local drv_state; drv_state="$(state_get NVIDIA_DRIVER)"
  if [[ -n "$drv_state" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
      nvidia_verify || return 1
      return 0
    fi
    info "驱动已安装($drv_state)但尚未生效 —— 请重启后重跑同一命令，将自动完成验证"
    return 0
  fi
  # 首次安装
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    warn "Secure Boot 已开启：DKMS 自编译模块可能无法加载；如安装后驱动异常，请关闭 Secure Boot 或注册 MOK（见 README）"
  fi
  local chosen=""
  if [[ -n "$ARG_NVIDIA_DRIVER" ]]; then
    chosen="$ARG_NVIDIA_DRIVER"
    map_gpu_arch "${gpu_name,,}"
    local cnum; cnum="$(printf '%s' "$chosen" | grep -Eo '[0-9]+' | head -1)"
    case "$MODULE_REQ" in
      open)        [[ "$chosen" == *-open ]] || { err "$ARCH 架构必须使用 open 内核模块驱动（如 ${cnum}-open）"; return 1; } ;;
      proprietary) [[ "$chosen" != *-open ]] || { err "$ARCH 架构不支持 open 内核模块（请用 $cnum 无 -open 后缀）"; return 1; } ;;
    esac
    [[ -n "$cnum" && "$cnum" -ge "$MIN_DRV" ]] || { err "$ARCH 架构要求驱动 ≥ $MIN_DRV"; return 1; }
  else
    nvidia_pick_driver "$gpu_name"
    chosen="$CHOSEN_DRIVER"
    if [[ -z "$chosen" ]]; then
      err "仓库中未找到满足约束的驱动（架构 $ARCH / 最低 $MIN_DRV）——请手动指定 --nvidia-driver <分支>"
      return 1
    fi
  fi
  if [[ $ASSUME_YES -eq 0 ]]; then
    info "选型结论: $gpu_name → $chosen"
    confirm "确认安装该驱动分支？" y || { info "已取消（可选 c 跳过本模块）"; return 0; }
  fi
  # nouveau 屏蔽
  if lsmod 2>/dev/null | grep -q '^nouveau'; then
    info "屏蔽 nouveau 开源驱动..."
    write_file /etc/modprobe.d/blacklist-nouveau.conf 644 <<< "blacklist nouveau
options nouveau modeset=0"
    run_cmd update-initramfs -u || warn "update-initramfs 失败"
  fi
  # 头文件 + DKMS + 驱动
  run_cmd apt-get install -y "linux-headers-$(uname -r)" dkms || { err "内核头文件/DKMS 安装失败"; return 1; }
  info "安装驱动: $chosen（安装后 apt-mark hold 锁定）"
  run_cmd apt-get install -y "$chosen" || { err "驱动安装失败（详见日志）"; return 1; }
  run_sh "apt-mark hold \$(dpkg -l 2>/dev/null | awk '/^ii  nvidia-(driver|dkms|kernel)-/ {print \$2}' | tr '\n' ' ') >/dev/null 2>&1; true"
  state_set NVIDIA_DRIVER "$chosen"
  danger "版本铁三角提醒: 驱动($chosen)/CUDA/上层框架需匹配，勿随意升级驱动（已 apt-mark hold，解锁: apt-mark unhold '<包名>'）"
  # CUDA（默认不装，D8）
  if [[ $WITH_CUDA -eq 1 ]]; then
    install_cuda_toolkit || warn "CUDA 安装未完成（不影响驱动）"
  else
    info "未安装 CUDA Toolkit（D8 默认；vLLM/PyTorch 等 pip 生态自带运行时）"
  fi
  # 容器工具包
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    install_nvidia_container_toolkit || warn "nvidia-container-toolkit 安装失败（不影响驱动）"
  fi
  # memlock（多卡 NCCL 硬需求）
  if (( count >= 2 )); then
    ensure_limits_block yes
    ok "检测到多卡（$count）：已在 limits 追加 memlock unlimited（NCCL 需要）"
  fi
  hint_reboot "NVIDIA 驱动($chosen)已安装，必须重启后加载；重启后重跑同一命令自动完成验证"
  ok "NVIDIA 驱动安装阶段完成 —— 重启后重跑本脚本完成验证"
}
nvidia_ready() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; }

# ================================================================ 模块 13: 报告
module_status_char() {
  local id="$1" st
  st="$(state_get "STEP_${id}_STATUS")"
  case "$st" in
    done)    printf '%s✅ 完成%s'   "$C_GREEN"  "$C_OFF" ;;
    failed)  printf '%s❌ 失败%s'   "$C_RED"    "$C_OFF" ;;
    skipped) printf '%s⏭ 跳过%s'    "$C_GRAY"   "$C_OFF" ;;
    pending) printf '%s⏸ 待重启验证%s' "$C_YELLOW" "$C_OFF" ;;
    *)       printf '%s○ 未执行%s'  "$C_GRAY"   "$C_OFF" ;;
  esac
}
gen_report() {
  local id dur st
  printf '\n'
  printf '%s╭──────────────────────────────────────────────────────────╮%s\n' "$C_CYAN" "$C_OFF"
  printf '%s│              LinuxInit 初始化汇总报告 v%-14s│%s\n' "$C_CYAN" "$SCRIPT_VERSION" "$C_OFF"
  printf '%s╰──────────────────────────────────────────────────────────╯%s\n' "$C_CYAN" "$C_OFF"
  printf '  系统: %s  内核: %s  虚拟化: %s\n' "${PRETTY_NAME:-$OS_ID}" "$(uname -r)" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf '  日志: %s\n' "$LOG_FILE"
  printf '\n  %-4s %-28s %s\n' "ID" "模块" "状态/耗时"
  printf '  %s\n' "──  ──────────────────────────  ─────────────"
  for id in "${MODULE_ORDER[@]}"; do
    dur="$(state_get "STEP_${id}_DUR")"
    st="$(module_status_char "$id")"
    local durs=""
    [[ -n "$dur" ]] && durs="  ($(printf '%02d:%02d' $((dur/60)) $((dur%60))))"
    printf '  %-4s %-28s %s%s\n' "$id" "${MODULE_NAME[$id]}" "$st" "$durs"
  done
  printf '\n  —— 关键信息 ——\n'
  local h u p tz tn dk nv sel fw
  h="$(state_get INFO_HOSTNAME)"; u="$(state_get INFO_USER)"; p="$(state_get INFO_SSH_PORT)"
  tz="$(state_get INFO_TZ)"; tn="$(state_get INFO_TUNE)"; dk="$(state_get INFO_DOCKER)"
  nv="$(state_get INFO_NVIDIA)"; sel="$(state_get SELINUX_MODE)"; fw="$(state_get FIREWALL_KEPT)"
  [[ -n "$h" ]]  && printf '  主机名: %s\n' "$h"
  [[ -n "$tz" ]] && printf '  时区: %s\n' "$tz"
  [[ -n "$tn" ]] && printf '  内核调优: %s 档\n' "$tn"
  [[ -n "$u" ]]  && printf '  用户: %s（sudo %s）\n' "$u" "$([[ -f /etc/sudoers.d/99-linux-init ]] && echo NOPASSWD || echo 需密码)"
  [[ -n "$p" ]]  && printf '  SSH: 端口 %s / root 登录: 禁用 / 密码登录: 禁用 / 密钥: 启用\n' "$p"
  [[ "$fw" == "1" ]] && printf '  防火墙: 保留（新端口已放行）\n' || printf '  防火墙: 已关闭（注意云安全组）\n'
  [[ -n "$sel" ]] && printf '  SELinux: %s\n' "$sel"
  [[ -n "$dk" ]] && printf '  Docker: %s\n' "$dk"
  [[ -n "$nv" ]] && printf '  NVIDIA: %s\n' "$nv"
  # 重启提醒
  local hn hn_v
  hn="$(state_get REBOOT_HINT_N 2>/dev/null || echo 0)"
  [[ "$hn" =~ ^[0-9]+$ ]] || hn=0
  if (( hn > 0 )); then
    printf '\n  %s—— 需要重启的事项 ——%s\n' "$C_YELLOW" "$C_OFF"
    for (( hn_v = 1; hn_v <= hn; hn_v++ )); do
      printf '  %d. %s\n' "$hn_v" "$(state_get "REBOOT_HINT_${hn_v}")"
    done
  fi
  if [[ -n "$u" && -n "$p" ]]; then
    printf '\n  %s—— 退出前自测清单（请勿先关闭当前会话）——%s\n' "$C_GREEN" "$C_OFF"
    printf '  1. 新开终端: ssh -p %s %s@<本机IP>   ← 密钥登录\n' "$p" "$u"
    printf '  2. 确认 sudo 可用\n'
    printf '  3. 确认 22 端口 / root / 密码登录均被拒绝\n'
    printf '  4. 全部通过后再退出当前会话\n'
  fi
  printf '\n'
}
step_13() {
  gen_report | tee "$REPORT_FILE"
  ok "报告已存档: $REPORT_FILE"
  [[ $DRY_RUN -eq 1 ]] && return 0
  local hn; hn="$(state_get REBOOT_HINT_N 2>/dev/null || echo 0)"
  [[ "$hn" =~ ^[0-9]+$ ]] || hn=0
  if (( hn > 0 )); then
    if [[ $REBOOT_AUTO -eq 1 ]]; then
      warn "--reboot 指定：5 秒后重启（Ctrl+C 取消）..."
      sleep 5
      run_cmd systemctl reboot || run_cmd reboot
    elif [[ $ASSUME_YES -eq 1 ]]; then
      info "无人值守模式默认不自动重启（如需自动重启请加 --reboot）；请稍后手动重启使配置生效"
    elif confirm "是否立即重启？（推荐：网络/NVIDIA/内核变更需重启生效）" n; then
      warn "5 秒后重启（Ctrl+C 取消）..."
      sleep 5
      run_cmd systemctl reboot || run_cmd reboot
    else
      info "稍后请手动重启以使全部配置生效"
    fi
  fi
}

# ================================================================ 预检
precheck() {
  [[ $EUID -eq 0 ]] || die 10 "请以 root 身份运行（su root 或 sudo -i 后执行）"
  command -v systemctl >/dev/null 2>&1 || die 11 "未检测到 systemd：不支持的运行环境（容器内请直接使用宿主机）"
  local virt; virt="$(systemd-detect-virt 2>/dev/null || echo none)"
  case "$virt" in
    docker|lxc|lxc-libvirt|containerd|podman|systemd-nspawn) die 11 "检测到容器环境($virt)：初始化脚本不适用于容器内部" ;;
    wsl|wsl2) warn "检测到 WSL：systemd 服务/NVIDIA 等功能可能受限" ;;
  esac
  # curl 自举
  if ! command -v curl >/dev/null 2>&1; then
    warn "未安装 curl，尝试用现有源自举安装..."
    if [[ "$PKG" == "apt-get" ]]; then
      run_sh "DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y curl" || true
    else
      run_cmd "$PKG" install -y curl || true
    fi
    if ! command -v curl >/dev/null 2>&1; then
      err "curl 安装失败；应急方案: python3 -c \"import urllib.request; urllib.request.urlretrieve('https://linuxmirrors.cn/main.sh','main.sh')\" 或手动安装 curl 后重试"
      die 12 "curl 不可用"
    fi
  fi
  # 网络探测
  local probe_host="${ARG_MIRROR:-mirrors.aliyun.com}"
  if curl -sI --max-time 5 "https://$probe_host" >/dev/null 2>&1; then
    ok "网络连通: https://$probe_host"
  else
    warn "网络探测失败（https://$probe_host）"
    [[ $FORCE -eq 1 ]] || die 12 "网络不可达；离线环境请人工确认后加 --force"
  fi
  # 磁盘
  local avail_gb; avail_gb="$(df -BG / 2>/dev/null | awk 'NR==2{print int($4)}')"
  [[ -n "$avail_gb" && "$avail_gb" -lt 2 ]] && warn "根分区剩余 ${avail_gb}GB < 2GB，安装/更新可能失败"
  # 运行锁
  if command -v flock >/dev/null 2>&1; then
    mkdir -p /var/lock
    exec 200>"$LOCK_FILE"
    flock -n 200 2>/dev/null || die 12 "已有 LinuxInit 实例在运行（$LOCK_FILE）"
  fi
}

# ================================================================ 主菜单
menu_status_line() {
  local id="$1"
  if [[ "$id" == "12" ]]; then
    local st; st="$(state_get STEP_12_STATUS)"
    if command -v lspci >/dev/null 2>&1 && [[ -z "$(lspci -nn -d 10de: 2>/dev/null)" ]]; then
      printf '%s— 无 GPU（自动跳过）%s' "$C_GRAY" "$C_OFF"; return
    fi
    if [[ -n "$(state_get NVIDIA_DRIVER)" && "$st" != "done" ]]; then
      printf '%s⏸ 待重启验证%s' "$C_YELLOW" "$C_OFF"; return
    fi
  fi
  module_status_char "$id"
}
show_menu() {
  printf '\n%s╭──────────────────────────────────────────────────────────╮%s\n' "$C_CYAN$C_BOLD" "$C_OFF"
  printf '%s│          LinuxInit · Linux 新装系统初始化 v%-12s│%s\n' "$C_CYAN$C_BOLD" "$SCRIPT_VERSION" "$C_OFF"
  printf '%s│    主机: %-14s 系统: %-24s│%s\n' "$C_CYAN" "$(hostname 2>/dev/null || echo -)" "${PRETTY_NAME:--}" "$C_OFF"
  printf '%s╰──────────────────────────────────────────────────────────╯%s\n' "$C_CYAN" "$C_OFF"
  printf '\n   %-3s %-30s %s\n' "ID" "模块" "状态"
  printf '   %s\n' "──  ──────────────────────────  ──────────"
  local id
  for id in "${MODULE_ORDER[@]}"; do
    printf '   %-3s %-30s ' "$id" "${MODULE_NAME[$id]}"
    menu_status_line "$id"
    printf '\n'
  done
  printf '   %s\n' "──  ──────────────────────────  ──────────"
   printf '   %sa%s   全部执行（按推荐顺序 1→13）\n' "$C_BOLD" "$C_OFF"
   printf '   %sv%s   查看上次运行报告\n' "$C_BOLD" "$C_OFF"
   printf '   %sq%s   退出\n' "$C_BOLD" "$C_OFF"
   printf '\n   选择: 输入编号运行模块，可多选（如 2 3 7），将按推荐顺序执行\n'
   printf '   %sInput: module IDs (e.g. 2 3 7) | a = run all | v = last report | q = quit%s\n' "$C_GRAY" "$C_OFF"
}
menu_loop() {
  local inp token found
  while true; do
    show_menu
    read -r -p "$(printf '%s   选择: %s' "$C_BOLD" "$C_OFF")" inp </dev/tty 2>/dev/null || { warn "无交互终端，退出"; exit 0; }
    case "${inp,,}" in
      q|quit|exit) info "再见"; exit 0 ;;
      v|view) [[ -f "$REPORT_FILE" ]] && cat "$REPORT_FILE" || info "尚无历史报告"; continue ;;
      a|all) RUN_MODULES=("${MODULE_ORDER[@]}"); break ;;
      "") continue ;;
      *)
        local -a picked=()
        found=0
        for token in $inp; do
          if [[ "$token" =~ ^([1-9]|1[0-3])$ ]]; then
            picked+=("$token"); found=1
          else
            warn "无效编号: $token（1-13）"
          fi
        done
        if [[ $found -eq 1 ]]; then
          mapfile -t RUN_MODULES < <(printf '%s\n' ${picked[@]+"${picked[@]}"} | sort -nu)
          break
        fi
        ;;
    esac
  done
}

# ================================================================ 模块调度
skip_module() {
  local id="$1" why="${2:-参数}"
  printf '  %s⏭ 模块 %s（%s）按参数跳过%s\n' "$C_GRAY" "$id" "${MODULE_NAME[$id]}" "$C_OFF"
  state_set "STEP_${id}_STATUS" "skipped"
}
module_should_skip() {
  local id="$1"
  case "$id" in
    1)  [[ $SKIP_MIRRORS -eq 1 ]] ;;
    2)  [[ $SKIP_UPDATE -eq 1 ]] ;;
    3)  [[ $SKIP_TIME -eq 1 ]] ;;
    4)  [[ $ASSUME_YES -eq 1 && -z "$ARG_HOSTNAME" ]] ;;
    5)  [[ $ASSUME_YES -eq 1 && ${#ARG_NICS[@]} -eq 0 && ${#ARG_HOSTS_ENTRIES[@]} -eq 0 ]] ;;
    6)  [[ $KEEP_FIREWALL -eq 1 ]] ;;
    7)  [[ "$ARG_TUNE" == "off" ]] ;;
    8)  [[ "${ARG_TOOLS:-basic}" == "none" ]] ;;
    9)  [[ $SKIP_USER -eq 1 ]] ;;
    10) [[ $WITH_DOCKER -eq 0 ]] ;;
    11) [[ $SKIP_SSH -eq 1 ]] ;;
    12) [[ $WITH_NVIDIA -eq 0 ]] ;;
    *)  return 1 ;;
  esac
}
print_module_head() {
  local id="$1"
  printf '\n%s┌─▶ 模块 %s · %s%s\n' "$C_CYAN$C_BOLD" "$id" "${MODULE_NAME[$id]}" "$C_OFF"
  hr
}
run_module() {
  local id="$1" rc=0 t0 t1 dur
  if module_should_skip "$id"; then skip_module "$id"; return 0; fi
  local st; st="$(state_get "STEP_${id}_STATUS")"
  if [[ "$st" == "done" && "$FORCE_STEP" != "$id" ]]; then
    printf '  %s⏭ 模块 %s（%s）已完成，跳过（--force-step %s 可重跑）%s\n' "$C_GRAY" "$id" "${MODULE_NAME[$id]}" "$id" "$C_OFF"
    return 0
  fi
  if [[ "$st" == "pending" && "$id" == "12" && "$FORCE_STEP" != "$id" ]]; then
    printf '  %s⏭ 模块 12 待重启验证（重启后重跑同一命令自动继续）%s\n' "$C_GRAY" "$C_OFF"
    return 0
  fi
  if ! declare -F "step_$id" >/dev/null; then
    err "内部错误: 模块函数缺失 step_$id"; FAILED_MODULES+=("$id"); return 1
  fi
  print_module_head "$id"
  t0="$(date +%s)"
  "step_$id"; rc=$?
  t1="$(date +%s)"; dur=$((t1 - t0))
  if [[ $rc -eq 0 ]]; then
    # 模块 12 特殊：驱动已装但未重启验证前保持 pending（防止重启后验证被跳过）
    if [[ "$id" == "12" && -n "$(state_get NVIDIA_DRIVER)" ]] && ! nvidia_ready; then
      state_set "STEP_${id}_STATUS" "pending"
    else
      state_set "STEP_${id}_STATUS" "done"
    fi
    state_set "STEP_${id}_DUR" "$dur"
    printf '  %s■ 模块 %s 完成（耗时 %02d:%02d）%s\n' "$C_GREEN" "$id" $((dur / 60)) $((dur % 60)) "$C_OFF"
  else
    state_set "STEP_${id}_STATUS" "failed"
    state_set "STEP_${id}_DUR" "$dur"
    FAILED_MODULES+=("$id")
    printf '  %s■ 模块 %s 失败（详见日志 %s）%s\n' "$C_RED" "$id" "$LOG_FILE" "$C_OFF"
  fi
  return "$rc"
}

# ================================================================ 用法
usage() {
  cat <<EOF
LinuxInit —— Linux 新装系统通用初始化脚本 v$SCRIPT_VERSION（需求文档 $REQ_DOC_VERSION）

用法: bash linux-init.sh [模块ID...] [选项]    （无参数 = 交互主菜单）

模块ID: 1=换源 2=更新 3=时区 4=主机名 5=网络 6=防火墙 7=调优 8=软件 9=用户 10=Docker 11=SSH 12=NVIDIA 13=报告
        单独执行: linux-init.sh 11      多选: linux-init.sh 1 2 3      全部: --all

运行控制
  -y, --yes                 无人值守（无模块 ID 时等价 --all）
      --all                 按推荐顺序执行全部模块（可配合 --skip-* 剔除）
      --dry-run             试运行，只打印动作
      --force-step <ID>     强制重跑指定模块（配合断点续跑）
      --force               预检告警不终止（未识别系统/离线等）
      --reboot              结束后自动重启
      --lang <zh|en>        输出语言（v1 仅 zh，en 为 backlog）

模块跳过
      --skip-mirrors        跳过换源（模块1）
      --skip-update         跳过系统更新（模块2）
      --skip-time           跳过时区时间（模块3）
      --keep-firewall       保留防火墙（跳过模块6）
      --selinux-enforcing   保留 SELinux enforcing（RedHat 系；默认关闭，D6）
      --tune off|aggressive 内核调优关闭 / 激进档（模块7，默认温和档）
      --tools basic|dev|none    常用软件组（模块8，默认 basic）
      --skip-user           跳过创建用户（模块9；则模块11须一并 --skip-ssh）
      --skip-ssh            跳过 SSH 加固（模块11）
      --with-docker         安装/配置 Docker（模块10，默认跳过）
      --with-nvidia         安装 NVIDIA 驱动（模块12，默认跳过；无显卡自动跳过）
      --with-cuda[=<ver>]   同时安装 CUDA Toolkit（缺省自动匹配驱动最高版本）

关键配置
      --hostname <NAME>     设置主机名（模块4；不给则跳过，RFC 1123 校验）
      --nic "<网卡>:<CIDR>:<网关|none>[:<DNS>]"   网卡固定 IP（模块5，可重复=多网卡）
                            例: --nic "eth0:192.168.1.10/24:192.168.1.1:223.5.5.5,119.29.29.29"
                                --nic "eth1:10.0.0.5/24:none"
      --hosts-entry "<IP> <主机名>"   /etc/hosts 解析条目（模块5，可重复）
      --dns <IP[,IP]>       全局 DNS（默认 223.5.5.5,119.29.29.29）
      --timezone <TZ>       时区（默认 Asia/Shanghai）
      --user <NAME>         新用户名
      --sudo-require-password   新用户 sudo 需要密码（默认 NOPASSWD 免密，D3）
      --pubkey "<公钥>"     直接给定公钥（可重复）
      --pubkey-file <PATH>  从本地文件读公钥
      --pubkey-url <URL>    从 https URL 拉取公钥（拒绝内网/保留地址）
      --ssh-port <N>        新 SSH 端口（默认 22222，1024-65535）
      --mirror <域名>       换源镜像站（默认 mirrors.aliyun.com）
      --docker-registry <域名>  Docker 镜像加速器（默认 docker.1ms.run）
      --nvidia-driver <分支>    手动指定驱动分支（如 580-open；缺省自动选型）
      --strict-mirror       换源失败即终止（默认仅警告）

凭据传入（唯一安全通道，不提供命令行密码参数）
  LINUX_INIT_USER_PASSWORD  环境变量，新用户密码；缺省则交互式输入

更多文档: 需求文档.md / README.md
EOF
}

# ================================================================ 参数解析
parse_args() {
  local i=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      --all) ARG_ALL=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      --reboot) REBOOT_AUTO=1 ;;
      -V|--version) SHOW_VERSION=1 ;;
      -h|--help) SHOW_HELP=1 ;;
      --force-step) FORCE_STEP="$2"; shift ;;
      --lang) shift ;;
      --skip-mirrors) SKIP_MIRRORS=1 ;;
      --skip-update) SKIP_UPDATE=1 ;;
      --skip-time) SKIP_TIME=1 ;;
      --keep-firewall) KEEP_FIREWALL=1 ;;
      --selinux-enforcing) SELINUX_ENFORCING=1 ;;
      --tune) ARG_TUNE="$2"; shift ;;
      --tune=*) ARG_TUNE="${1#*=}" ;;
      --tools) ARG_TOOLS="$2"; ARG_TOOLS_SET=1; shift ;;
      --skip-user) SKIP_USER=1 ;;
      --skip-ssh) SKIP_SSH=1 ;;
      --with-docker) WITH_DOCKER=1 ;;
      --with-nvidia) WITH_NVIDIA=1 ;;
      --with-cuda) WITH_CUDA=1 ;;
      --with-cuda=*) WITH_CUDA=1; ARG_CUDA_VER="${1#*=}" ;;
      --hostname) ARG_HOSTNAME="$2"; shift ;;
      --nic) ARG_NICS+=("$2"); shift ;;
      --hosts-entry) ARG_HOSTS_ENTRIES+=("$2"); shift ;;
      --dns) ARG_DNS="$2"; shift ;;
      --timezone) ARG_TIMEZONE="$2"; shift ;;
      --user) TARGET_USER="$2"; shift ;;
      --sudo-require-password) SUDO_REQUIRE_PASSWORD=1 ;;
      --pubkey) ARG_PUBKEYS+=("$2"); shift ;;
      --pubkey-file) ARG_PUBKEY_FILE="$2"; shift ;;
      --pubkey-url) ARG_PUBKEY_URL="$2"; shift ;;
      --ssh-port) ARG_SSH_PORT="$2"; shift ;;
      --mirror) ARG_MIRROR="$2"; shift ;;
      --docker-registry) ARG_DOCKER_REGISTRY="$2"; shift ;;
      --nvidia-driver) ARG_NVIDIA_DRIVER="$2"; shift ;;
      --strict-mirror) STRICT_MIRROR=1 ;;
      --) shift; while [[ $# -gt 0 ]]; do parse_positional "$1"; shift; done; break ;;
      -*) die 13 "未知参数: $1（--help 查看用法）" ;;
      *) parse_positional "$1" ;;
    esac
    shift
  done
  # 值校验
  case "$ARG_TUNE" in mild|aggressive|off) ;; *) die 13 "--tune 仅支持 mild|aggressive|off" ;; esac
  if [[ -n "$ARG_TOOLS" ]]; then case "$ARG_TOOLS" in basic|dev|none) ;; *) die 13 "--tools 仅支持 basic|dev|none" ;; esac; fi
  if [[ "$SKIP_USER" -eq 1 && $SKIP_SSH -eq 0 ]]; then
    warn "--skip-user 时模块 11（SSH 加固）必须一并跳过（无用户可登录）→ 已自动跳过"
    SKIP_SSH=1
  fi
}
parse_positional() {
  [[ "$1" =~ ^([1-9]|1[0-3])$ ]] || die 13 "无效模块 ID: $1（1-13，--help 查看用法）"
  RUN_MODULES+=("$1")
}

# ================================================================ 主入口
main() {
  parse_args "$@"
  [[ $SHOW_VERSION -eq 1 ]] && { printf 'linux-init.sh %s（需求文档 %s）\n' "$SCRIPT_VERSION" "$REQ_DOC_VERSION"; exit 0; }
  [[ $SHOW_HELP -eq 1 ]] && { usage; exit 0; }

  mkdir -p "$LOG_DIR"
  # shellcheck disable=SC2094
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'cleanup' EXIT

  printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_CYAN$C_BOLD" "$C_OFF"
  printf '%s║        LinuxInit · Linux 新装系统初始化  v%-14s║%s\n' "$C_CYAN$C_BOLD" "$SCRIPT_VERSION" "$C_OFF"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_CYAN" "$C_OFF"
  info "日志: $LOG_FILE"

  detect_os
  info "系统识别: ${PRETTY_NAME:-$OS_ID}（$OS_FAMILY 族，包管理 $PKG，SSH 服务 $SSH_SVC）"
  precheck
  if is_text_console; then
    warn "检测到文本控制台（tty）：中文将显示为乱码，操作不受影响（输入编号/字母即可）"
    warn "Text console detected: CJK shows as garbage. Recommend: run via SSH from your desktop."
  fi

  # 模块选择
  if [[ ${#RUN_MODULES[@]} -eq 0 ]]; then
    if [[ $ASSUME_YES -eq 1 || $ARG_ALL -eq 1 ]]; then
      RUN_MODULES=("${MODULE_ORDER[@]}")
      [[ $ASSUME_YES -eq 1 ]] && info "无人值守模式：按推荐顺序执行全部模块"
    else
      menu_loop
    fi
  elif [[ $ARG_ALL -eq 1 ]]; then
    RUN_MODULES=("${MODULE_ORDER[@]}")
  fi
  mapfile -t RUN_MODULES < <(printf '%s\n' ${RUN_MODULES[@]+"${RUN_MODULES[@]}"} | sort -nu)

  # 交互全跑时，询问默认关闭的可选模块（4/5 在各自模块内询问）
  if [[ $ASSUME_YES -eq 0 && ${#RUN_MODULES[@]} -gt 5 ]]; then
    if printf '%s\n' ${RUN_MODULES[@]+"${RUN_MODULES[@]}"} | grep -qx 10 && [[ $WITH_DOCKER -eq 0 ]]; then
      confirm "是否安装 Docker（模块 10，默认跳过）？" n && WITH_DOCKER=1
    fi
    if printf '%s\n' ${RUN_MODULES[@]+"${RUN_MODULES[@]}"} | grep -qx 12 && [[ $WITH_NVIDIA -eq 0 ]]; then
      if command -v lspci >/dev/null 2>&1 && [[ -n "$(lspci -nn -d 10de: 2>/dev/null)" ]]; then
        confirm "检测到 NVIDIA 显卡，是否安装驱动（模块 12，自动选型）？" n && WITH_NVIDIA=1
      fi
    fi
  fi

  # 执行（报告固定最后）
  local id ran13=0
  for id in ${RUN_MODULES[@]+"${RUN_MODULES[@]}"}; do
    [[ "$id" == "13" ]] && continue
    run_module "$id"
  done
  run_module 13
  ran13=1

  # 退出码
  if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
    err "存在失败模块: ${FAILED_MODULES[*]}（详见日志 $LOG_FILE）"
    exit 20
  fi
  exit 0
}

# 仅直接执行时运行（支持 source 做单元测试）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
