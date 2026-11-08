#!/usr/bin/env bash
# ==============================================================================
#  LinuxInit 一键引导脚本（本文件只在仓库分发，主脚本已内嵌 vendor，无需整仓）
#
#  用法: bash <(curl -sSL <本文件URL>) [传给主脚本的参数...]
#
#  一行启动（交互主菜单）:
#    bash <(curl -sSL https://cdn.jsdelivr.net/gh/weisunit/LinuxInit@main/init.sh)
#
#  无人值守（密码走环境变量，不进 history）:
#    LINUX_INIT_USER_PASSWORD='***' bash <(curl -sSL <本文件URL>) \
#      --yes --user deploy --ssh-port 22222 \
#      --pubkey-url https://github.com/<user>.keys --with-docker
#
#  环境变量:
#    LINUX_INIT_VERSION   指定分支/标签（默认 main，可锁 v1.0.0 等稳定版）
#    LINUX_INIT_DEST      主脚本落盘路径（默认 ~/linux-init.sh，重启续跑用它）
# ==============================================================================
set -u

REPO="weisunit/LinuxInit"
TAG="${LINUX_INIT_VERSION:-main}"
DEST="${LINUX_INIT_DEST:-$HOME/linux-init.sh}"

# ---- 输出（stderr 打日志，stdout 保持干净） ----
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_C=$'\033[36m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_E=$'\033[0m'
else
  C_C="" C_G="" C_Y="" C_R="" C_E=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_C" "$C_E" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n'  "$C_G" "$C_E" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n'  "$C_Y" "$C_E" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n'  "$C_R" "$C_E" "$*" >&2; }

TMPD="$(mktemp -d /tmp/linux-init-boot.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

looks_right() {  # 防止拿到 404 页面/被篡改内容：必须是我们的 bash 脚本且体量正确
  [[ -s "$1" ]] || return 1
  head -c 64 "$1" | grep -q '#!/usr/bin/env bash' || return 1
  [[ "$(wc -c < "$1")" -gt 100000 ]]
}

fetch_to() {  # $1=url  $2=输出文件
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 40 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" --timeout=40 "$1"
  else
    return 97
  fi
}

ensure_fetcher() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0
  warn "未检测到 curl/wget，尝试用现有源安装 curl（新装 Debian minimal 常见）..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y 2>/dev/null || true
    apt-get install -y curl 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl 2>/dev/null || true
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# ---- 通道 0: codeload 整仓 tar（github 直连，大陆常可用） ----
try_codeload() {
  local d
  fetch_to "https://codeload.github.com/$REPO/tar.gz/$TAG" "$TMPD/repo.tar.gz" || return 1
  tar -xzf "$TMPD/repo.tar.gz" -C "$TMPD" 2>/dev/null || return 1
  d="$(tar -tzf "$TMPD/repo.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
  [[ -n "$d" && -f "$TMPD/$d/dist/linux-init.sh" ]] || return 1
  cp "$TMPD/$d/dist/linux-init.sh" "$DEST"
}

# ---- 通道 1..n: 直链单文件 ----
try_url() {  # $1=url
  fetch_to "$1" "$DEST" && looks_right "$DEST"
}

main() {
  info "LinuxInit 一键引导 (repo: $REPO, 版本: $TAG)"
  ensure_fetcher || {
    err "无法下载：请先安装 curl（apt-get install -y curl）后重试"
    exit 1
  }

  if looks_right "$DEST" 2>/dev/null; then
    warn "已存在 $DEST 且体量正确 → 复用本地文件（断点续跑场景）；如需更新请 rm 后重跑"
  else
    local done=0
    # 通道顺序：codeload → jsDelivr（双 CDN）→ ghproxy 镜像 → raw 直连
    try_codeload && done=1
    if [[ $done -eq 0 ]]; then
      for u in \
        "https://cdn.jsdelivr.net/gh/$REPO@$TAG/dist/linux-init.sh" \
        "https://fastly.jsdelivr.net/gh/$REPO@$TAG/dist/linux-init.sh" \
        "https://ghproxy.net/https://raw.githubusercontent.com/$REPO/$TAG/dist/linux-init.sh" \
        "https://raw.githubusercontent.com/$REPO/$TAG/dist/linux-init.sh"; do
        info "尝试通道: $u"
        try_url "$u" && { done=1; break; } || warn "通道失败，切换下一个..."
      done
    fi
    [[ $done -eq 1 ]] || {
      err "所有下载通道均失败（网络受限？）"
      err "应急方案: git clone https://github.com/$REPO.git && sudo bash $REPO/linux-init.sh"
      exit 1
    }
    ok "下载完成: $DEST ($(wc -c < "$DEST") bytes)"
    command -v sha256sum >/dev/null 2>&1 && \
      ok "SHA256: $(sha256sum "$DEST" | awk '{print $1}')"
  fi

  # ---- 启动（非 root 自动提权；环境变量透传给主脚本） ----
  if [[ "$(id -u)" -eq 0 ]]; then
    exec bash "$DEST" "$@"
  fi
  command -v sudo >/dev/null 2>&1 || {
    err "当前非 root 且未安装 sudo；请 su root 后重新执行: bash $DEST"
    exit 1
  }
  if [[ -n "${LINUX_INIT_USER_PASSWORD:-}${LINUX_INIT_VERSION:-}${LINUX_INIT_DEST:-}" ]]; then
    exec sudo --preserve-env=LINUX_INIT_USER_PASSWORD,LINUX_INIT_VERSION,LINUX_INIT_DEST \
      bash "$DEST" "$@"
  fi
  exec sudo bash "$DEST" "$@"
}

main "$@"
