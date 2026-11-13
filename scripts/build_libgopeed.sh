#!/usr/bin/env bash
# 编译 libgopeed.aar（Gopeed Go 内核 → Android AAR）
#
# 加固要点（见 docs/operations.md「下载引擎源码完整性」）：
#   1. tag 可被仓库所有者移动，因此用 GOPEED_COMMIT 固定到具体 commit 并强制校验；
#   2. 缓存源码目录同样要过 commit 校验，不复用未经确认的源码；
#   3. 不再复用共享的 /tmp/gopeed-src（多用户机器上可被抢先创建并替换内容）；
#   4. gomobile 工具链版本可通过 GOMOBILE_VERSION 固定，未固定时显式告警；
#   5. 产物 AAR 打印 SHA-256，便于把引擎版本与发布记录对应起来。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOPEED_VERSION="${GOPEED_VERSION:-v1.9.3}"
# 期望的源码 commit（完整或短 SHA）。留空则跳过校验并告警。
GOPEED_COMMIT="${GOPEED_COMMIT:-}"
# gomobile 版本（如 v0.8.2）。留空则退回 @latest 并告警。
GOMOBILE_VERSION="${GOMOBILE_VERSION:-}"
AAR_OUT="${1:-${REPO_ROOT}/android/app/libs/libgopeed.aar}"

# 按 UID 隔离，避免共享 /tmp 下的同名目录被其他用户抢占
SRC_DIR="${TMPDIR:-/tmp}/quarklite-gopeed-src-$(id -u)-${GOPEED_VERSION}"

echo "==> GOPEED_VERSION=${GOPEED_VERSION}"
echo "==> GOPEED_COMMIT=${GOPEED_COMMIT:-<未设置，跳过完整性校验>}"
echo "==> SRC_DIR=${SRC_DIR}"

mkdir -p "$(dirname "${AAR_OUT}")"

if [ ! -d "${SRC_DIR}" ]; then
  echo "==> clone GopeedLab/gopeed ${GOPEED_VERSION}"
  git clone --depth 1 --branch "${GOPEED_VERSION}" \
    https://github.com/GopeedLab/gopeed.git "${SRC_DIR}"
else
  echo "==> reuse cached gopeed source"
fi

cd "${SRC_DIR}"

ACTUAL_COMMIT="$(git rev-parse HEAD)"
echo "==> gopeed source commit=${ACTUAL_COMMIT}"
if [ -n "${GOPEED_COMMIT}" ]; then
  case "${ACTUAL_COMMIT}" in
    "${GOPEED_COMMIT}"*) : ;;
    *)
      echo "!! 源码 commit 与 GOPEED_COMMIT 期望值不符" >&2
      echo "!!   期望: ${GOPEED_COMMIT}" >&2
      echo "!!   实际: ${ACTUAL_COMMIT}" >&2
      echo "!!   tag 可能已被移动，或缓存目录来自另一次构建；已中止" >&2
      exit 1
      ;;
  esac
else
  echo "!! 未设置 GOPEED_COMMIT，源码完整性未校验（正式发布必须设置）" >&2
fi

if [ -n "${GOMOBILE_VERSION}" ]; then
  GOMOBILE_SPEC="golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}"
else
  GOMOBILE_SPEC="golang.org/x/mobile/cmd/gomobile@latest"
  echo "!! 未设置 GOMOBILE_VERSION，工具链取 @latest，两次构建可能不一致" >&2
fi

echo "==> install gomobile (${GOMOBILE_SPEC})"
go install "${GOMOBILE_SPEC}"
go get golang.org/x/mobile/bind
export PATH="${PATH}:$(go env GOPATH)/bin"

echo "==> gomobile init"
gomobile init

echo "==> gomobile bind"
gomobile bind -tags nosqlite \
  -ldflags="-w -s -checklinkname=0" \
  -o "${AAR_OUT}" \
  -target=android -androidapi 21 \
  -javapkg=com.gopeed \
  github.com/GopeedLab/gopeed/bind/mobile

echo "==> done: ${AAR_OUT}"
if command -v sha256sum >/dev/null 2>&1; then
  echo "==> AAR SHA-256: $(sha256sum "${AAR_OUT}" | cut -d' ' -f1)"
fi
