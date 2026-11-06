#!/usr/bin/env bash
# ==============================================================================
#  build.sh —— 将 vendor/ 内嵌进主脚本，打包生成可独立分发的 dist 单文件
#
#  用法: ./build.sh        （在项目根目录执行）
#  产物: dist/linux-init.sh —— 单文件，scp 到任意 Linux 机器直接运行
#
#  vendor 升级流程（见 vendor/README.md）:
#    官网重新下载 → sha256 核对 → diff 审查 → 更新 vendor/ → 重新 ./build.sh
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SRC="linux-init.sh"
OUT="dist/linux-init.sh"

for f in vendor/ChangeMirrors.sh vendor/DockerInstallation.sh "$SRC"; do
  [[ -f "$f" ]] || { echo "错误: 缺少 $f（请先在项目根目录执行）"; exit 1; }
done

mkdir -p dist

echo "→ 内嵌 vendor 脚本（base64）..."
MAIN_B64="$(base64 < vendor/ChangeMirrors.sh | tr -d '\n')"
DOCKER_B64="$(base64 < vendor/DockerInstallation.sh | tr -d '\n')"

echo "→ 生成 $OUT ..."
awk -v m="$MAIN_B64" -v d="$DOCKER_B64" '
  /^VENDOR_MAIN_B64=/   { print "VENDOR_MAIN_B64=\"" m "\""; next }
  /^VENDOR_DOCKER_B64=/ { print "VENDOR_DOCKER_B64=\"" d "\""; next }
  { print }
' "$SRC" > "$OUT"
chmod +x "$OUT"

# 完整性自检：内嵌副本解包后与 vendor/ 原件逐字节一致
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
if command -v base64 >/dev/null 2>&1; then
  if base64 -d "$OUT" >/dev/null 2>&1 || true; then :; fi
  # 解包验证（macOS 用 -D，GNU 用 -d）
  if base64 -d < <(grep '^VENDOR_MAIN_B64=' "$OUT" | sed 's/^VENDOR_MAIN_B64="//; s/"$//') > "$VERIFY_DIR/main.sh" 2>/dev/null \
     || base64 -D < <(grep '^VENDOR_MAIN_B64=' "$OUT" | sed 's/^VENDOR_MAIN_B64="//; s/"$//') > "$VERIFY_DIR/main.sh" 2>/dev/null; then
    if cmp -s "$VERIFY_DIR/main.sh" vendor/ChangeMirrors.sh; then
      echo "✓ 内嵌完整性校验通过（ChangeMirrors.sh 逐字节一致）"
    else
      echo "错误: 内嵌副本与 vendor/ 原件不一致！"; exit 1
    fi
  else
    echo "警告: 跳过内嵌解包校验（当前环境 base64 解码不可用）"
  fi
fi

echo
echo "已生成: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
echo "SHA256: $( (shasum -a 256 "$OUT" 2>/dev/null || sha256sum "$OUT") | awk '{print $1}')"
