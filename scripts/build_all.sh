#!/usr/bin/env bash
# Quarklite 一键出包：Android APK（含 split-per-ABI）+ Windows 安装包
#
# 用法（Git Bash / Linux）：
#   bash scripts/build_all.sh                  # 两端都出
#   bash scripts/build_all.sh --apk-only       # 只出 APK
#   bash scripts/build_all.sh --windows-only   # 只出 exe + 安装包
#   bash scripts/build_all.sh --aab            # 额外出 AAB
#   bash scripts/build_all.sh --require-release-signing
#                                              # 缺 android/key.properties 时直接失败，
#                                              # 不允许静默打成 debug 签名（发版必开）
# 常用开关：--skip-engine 复用已有引擎产物；--no-split 跳过 per-ABI APK；
#           --clean 先清 build/；--cn-mirror 使用国内镜像（Gradle/Maven/pub/go）
#
# 可覆盖的环境变量（不设则用括号里的默认值）：
#   FLUTTER_BIN / JAVA_HOME / ANDROID_HOME / GRADLE_BIN / ISCC_EXE
#   GOPEED_VERSION(v1.9.3) GOPEED_COMMIT(必填，见 docs/build-and-env.md §3.2)
#   GOMOBILE_VERSION(x/mobile 无 tag，必须给伪版本)
#
# 前置工具链与踩坑记录见 docs/build-and-env.md §6；本脚本不修改任何受版本控制的构建配置。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="${REPO_ROOT}/android"
WIN_RESOURCES="${REPO_ROOT}/windows/resources"
AAR_OUT="${ANDROID_DIR}/app/libs/libgopeed.aar"
EXE_OUT="${WIN_RESOURCES}/gopeed.exe"
CACHE_DIR="${REPO_ROOT}/build/toolcache"          # 在 .gitignore 的 /build/ 之下
KNOWN_GOOD_FLUTTER="3.44"                          # 实测可出包的 Flutter 次版本线

DO_ANDROID=1
DO_WINDOWS=1
DO_AAB=0
DO_SPLIT=1
DO_ENGINE=1
STRICT_SIGNING=0
CN_MIRROR=0
DO_CLEAN=0
ALLOW_ANY_FLUTTER=0

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*" >&2; }
die()  { printf '\nXX  %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apk-only)     DO_WINDOWS=0 ;;
    --windows-only) DO_ANDROID=0 ;;
    --aab)          DO_AAB=1 ;;
    --no-split)     DO_SPLIT=0 ;;
    --skip-engine)  DO_ENGINE=0 ;;
    --require-release-signing) STRICT_SIGNING=1 ;;
    --cn-mirror)    CN_MIRROR=1 ;;
    --clean)        DO_CLEAN=1 ;;
    --allow-any-flutter) ALLOW_ANY_FLUTTER=1 ;;
    -h|--help)      awk 'NR>1 && /^set -euo/{exit} NR>1{print}' "${BASH_SOURCE[0]}" ; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 0. 环境
[ -f "${REPO_ROOT}/pubspec.yaml" ] || die "找不到 pubspec.yaml，请在仓库根目录下执行"

OS="$(uname -s)"
IS_WINDOWS=0; case "$OS" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # Windows 上 .bat 往往没有 POSIX 执行位（Git Bash 里 ls -l 显示 rw-r--r--），
  # command -v 因此判它"不存在"，但 cmd 照样能跑——不能据此拒绝 FLUTTER_BIN/GRADLE_BIN。
  [ "$IS_WINDOWS" = 1 ] && [ -f "$1" ] && return 0
  die "缺少命令 $1：$2"
}
require "$FLUTTER_BIN" "装 Flutter 后加进 PATH，或用 FLUTTER_BIN=<绝对路径> 指定"
require git "需要 git 拉取 Gopeed 引擎源码"

if [ "$DO_WINDOWS" = 1 ] && [ "$IS_WINDOWS" != 1 ]; then
  warn "非 Windows（${OS}），跳过 Windows 出包"; DO_WINDOWS=0
fi

FLUTTER_VER="$("$FLUTTER_BIN" --version 2>/dev/null | head -1 | sed -E 's/^Flutter ([0-9]+\.[0-9]+)\.[0-9]+.*/\1/')"
[ -n "$FLUTTER_VER" ] || die "读不到 flutter --version 输出"
if [ "$ALLOW_ANY_FLUTTER" != 1 ] && [ "$DO_ANDROID" = 1 ] && [ "$FLUTTER_VER" != "$KNOWN_GOOD_FLUTTER" ]; then
  die "flutter ${FLUTTER_VER} 未经验证：本仓库固定 Gradle 8.14 / AGP 8.13.2 / KGP 2.3.20，Flutter 3.45+ 会因最低版本校验失败（详见 docs/build-and-env.md §6.8 B-1）。请用 Flutter ${KNOWN_GOOD_FLUTTER}.x，或确认后果自行加 --allow-any-flutter"
fi

export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
if [ "$CN_MIRROR" = 1 ]; then
  export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
  export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
fi
log "Flutter ${FLUTTER_VER} · OS ${OS} · android=${DO_ANDROID} windows=${DO_WINDOWS} engine=${DO_ENGINE} aab=${DO_AAB} split=${DO_SPLIT}"

# pub 只有在拿到 SDK 版本后才知道能否解析；先跑一次让 .dart_tool 就位
log "flutter pub get"
( cd "$REPO_ROOT" && "$FLUTTER_BIN" pub get )
if [ -n "$(cd "$REPO_ROOT" && git status --porcelain -- pubspec.lock)" ]; then
  warn "pubspec.lock 被本次 pub get 改动了：本机 SDK 与提交锁文件所用 SDK 不同。
    出包可以继续，但**不要**顺手提交这份 lock（口径见 docs/build-and-env.md §6.6）"
fi

VER_NAME="$(sed -nE 's/^version: *([0-9][0-9.]*)(\+[0-9][0-9a-zA-Z.-]*)?$/\1/p' "$REPO_ROOT/pubspec.yaml")"
[ -n "$VER_NAME" ] || die "读不到 pubspec.yaml 的 version"
log "应用版本 ${VER_NAME}"

OUT_LIST=()
record() { OUT_LIST+=("$1"); }

# ---------------------------------------------------------------- 1. 引擎
if [ "$DO_CLEAN" = 1 ]; then
  # flutter clean 会删掉整个 build/，其中含本脚本的缓存目录 build/toolcache
  # （Gradle 用户级缓存 + Gopeed 源码），所以 --clean 与 --cn-mirror 同时用等于重新下载一切。
  log "flutter clean（连带清空 ${CACHE_DIR}，含 Gradle 缓存与引擎源码）"
  ( cd "$REPO_ROOT" && "$FLUTTER_BIN" clean ) >/dev/null
fi

if [ "$DO_ENGINE" = 1 ] && [ "$DO_ANDROID" = 1 ]; then
  if [ -f "$AAR_OUT" ]; then
    log "libgopeed.aar 已存在，跳过编译（--skip-engine 可显式跳过）：$(du -h "$AAR_OUT" | cut -f1)"
  else
    require go "编译 libgopeed.aar 需要 Go 工具链（docs/build-and-env.md §6.1）"
    [ -n "${GOPEED_COMMIT:-}" ] || die "编译 AAR 必须提供 GOPEED_COMMIT（GOPEED_VERSION 的 tag 可被移动，不可作为完整性依据）"
    [ -d "${ANDROID_HOME:-}" ] || die "ANDROID_HOME 未设置或不存在：AAR 需要 NDK"
    log "编译 libgopeed.aar（scripts/build_libgopeed.sh，首次约 10-20 分钟）"
    ( cd "$REPO_ROOT" && bash scripts/build_libgopeed.sh ) || die "libgopeed.aar 编译失败；CI 之外的机器需自备 NDK 与 gomobile"
  fi
fi
# 存在性检查放在 DO_ENGINE 之外：--skip-engine 时也要在跑 Gradle 之前拦下缺失产物
if [ "$DO_ANDROID" = 1 ]; then
  [ -f "$AAR_OUT" ] || die "缺少 $AAR_OUT：Android 构建无法进行（android/app/build.gradle.kts 用 files(\"libs/libgopeed.aar\")）；没有引擎产物时不能用 --skip-engine"
fi

if [ "$DO_ENGINE" = 1 ] && [ "$DO_WINDOWS" = 1 ]; then
  if [ -f "$EXE_OUT" ]; then
    log "gopeed.exe 已存在，跳过编译：$(du -h "$EXE_OUT" | cut -f1)"
  else
    require go "编译 gopeed.exe 需要 Go 工具链"
    GOPEED_SRC="${GOPEED_SRC:-${CACHE_DIR}/gopeed-src}"
    GOPEED_VERSION="${GOPEED_VERSION:-v1.9.3}"
    mkdir -p "$CACHE_DIR"
    if [ ! -d "$GOPEED_SRC/.git" ]; then
      log "拉取 Gopeed 源码 ${GOPEED_VERSION} → ${GOPEED_SRC}"
      git clone --depth 1 --branch "$GOPEED_VERSION" https://github.com/GopeedLab/gopeed.git "$GOPEED_SRC"
    fi
    ACTUAL="$(cd "$GOPEED_SRC" && git rev-parse HEAD)"
    if [ -n "${GOPEED_COMMIT:-}" ]; then
      case "$ACTUAL" in "${GOPEED_COMMIT}"*) : ;; *) die "Gopeed 源码 commit 与 GOPEED_COMMIT 不符：期望 ${GOPEED_COMMIT}，实际 ${ACTUAL}" ;; esac
    else
      warn "未设置 GOPEED_COMMIT，引擎源码完整性未校验（${ACTUAL}）"
    fi
    # gopeed 的 cmd/web 用 //go:embed dist/* 内嵌 Web 控制台；应用只走 REST，
    # 没有前端产物时用占位页也能出 exe（口径见 docs/build-and-env.md §6.2）
    if [ ! -f "$GOPEED_SRC/cmd/web/dist/index.html" ]; then
      warn "cmd/web/dist 不存在，写入占位 index.html：exe 可用，但内嵌 Web 控制台打不开"
      mkdir -p "$GOPEED_SRC/cmd/web/dist"
      printf '<!doctype html><meta charset="utf-8"><title>gopeed</title><p>Web console not embedded in this build.</p>\n' \
        > "$GOPEED_SRC/cmd/web/dist/index.html"
    fi
    mkdir -p "$WIN_RESOURCES"
    log "编译 gopeed.exe（-tags nosqlite,web）"
    ( cd "$GOPEED_SRC" && go build -tags nosqlite,web -ldflags="-s -w" -o "$EXE_OUT" github.com/GopeedLab/gopeed/cmd/web )
  fi
fi
if [ "$DO_WINDOWS" = 1 ]; then
  [ -f "$EXE_OUT" ] || die "缺少 $EXE_OUT：装完应用会报「未找到下载引擎」，不能出包；没有引擎产物时不能用 --skip-engine"
fi

# ---------------------------------------------------------------- 2. Gradle 前置
setup_gradle_env() {
  [ "$DO_ANDROID" = 1 ] || return 0
  export JAVA_HOME="${JAVA_HOME:-}"
  [ -n "$JAVA_HOME" ] || die "JAVA_HOME 未设置（需要 JDK 17+，实测 21 可用）"
  [ -x "${JAVA_HOME}/bin/javac" ] || die "JAVA_HOME 指向的目录里没有 bin/javac：${JAVA_HOME}"

  # ANDROID_HOME 交给 flutter 自己解析，只保证 local.properties 里 sdk.dir 存在
  if [ -n "${ANDROID_HOME:-}" ]; then
    win_android="$(cygpath -w "$ANDROID_HOME" 2>/dev/null || echo "$ANDROID_HOME")"
    ( cd "$REPO_ROOT" && "$FLUTTER_BIN" config --android-sdk "$win_android" >/dev/null 2>&1 ) \
      || warn "flutter config --android-sdk 失败，继续（若 android/local.properties 已有 sdk.dir 则无影响）"
  fi

  # 仓库把 wrapper 三件套 ignore 了，fresh clone 必须先补（docs/build-and-env.md §6.3 坑 1）
  if [ ! -f "${ANDROID_DIR}/gradlew" ] || [ ! -f "${ANDROID_DIR}/gradle/wrapper/gradle-wrapper.jar" ]; then
    GRADLE_BIN="${GRADLE_BIN:-gradle}"
    require "$GRADLE_BIN" "仓库里没有 Gradle wrapper，需要用系统 gradle 生成；或设 GRADLE_BIN=<路径>"
    local dist_url=()
    if [ "$CN_MIRROR" = 1 ]; then
      dist_url=(--gradle-distribution-url "https://mirrors.cloud.tencent.com/gradle/gradle-8.14-bin.zip")
    fi
    log "生成 Gradle wrapper（8.14）"
    mkdir -p "$CACHE_DIR"
    local props_backup="${CACHE_DIR}/gradle-wrapper.properties.bak"
    if [ -f "${ANDROID_DIR}/gradle/wrapper/gradle-wrapper.properties" ]; then
      cp "${ANDROID_DIR}/gradle/wrapper/gradle-wrapper.properties" "$props_backup"
    fi
    ( cd "$ANDROID_DIR" && "$GRADLE_BIN" wrapper --gradle-version 8.14 "${dist_url[@]}" -q ) \
      || die "gradle wrapper 生成失败"
    # distributionUrl 必须回到仓库钉死的值，否则出包用的是镜像地址而不是官方引用
    if [ -f "$props_backup" ]; then
      cp "$props_backup" "${ANDROID_DIR}/gradle/wrapper/gradle-wrapper.properties"
      warn "已把 gradle-wrapper.properties 的 distributionUrl 还原为仓库值；
        该地址（services.gradle.org）在国内不可用时，请预先缓存 Gradle 发行包到 GRADLE_USER_HOME"
    fi
  fi

  if [ "$CN_MIRROR" = 1 ]; then
    # 只改写已有 Maven 仓库的 URL：不新增、不重排、不删除，避免改变解析优先级
    export GRADLE_USER_HOME="${CACHE_DIR}/gradle-home"
    mkdir -p "$GRADLE_USER_HOME"
    cat > "${GRADLE_USER_HOME}/init.gradle" <<'GROOVY'
def MIRRORS = [
  'https://dl.google.com/dl/android/maven2' : 'https://maven.aliyun.com/repository/google',
  'https://repo.maven.apache.org/maven2'    : 'https://maven.aliyun.com/repository/public',
  'https://repo1.maven.org/maven2'          : 'https://maven.aliyun.com/repository/public',
  'https://plugins.gradle.org/m2'           : 'https://maven.aliyun.com/repository/gradle-plugin',
  'https://services.gradle.org/m2'          : 'https://maven.aliyun.com/repository/gradle-plugin',
]
def rewrite = { repo ->
  if (repo instanceof org.gradle.api.artifacts.repositories.MavenArtifactRepository) {
    try {
      def u = repo.url.toString()
      if (u.endsWith('/')) { u = u.substring(0, u.length() - 1) }
      def m = MIRRORS[u]
      if (m != null) { repo.setUrl(m) }
    } catch (Exception ignored) { }
  }
}
beforeSettings { s ->
  s.pluginManagement.repositories.all(rewrite)
  s.dependencyResolutionManagement.repositories.all(rewrite)
}
allprojects { p ->
  p.buildscript.repositories.all(rewrite)
  p.repositories.all(rewrite)
}
GROOVY
    log "Gradle 镜像：${GRADLE_USER_HOME}/init.gradle（只改写仓库 URL）"
  fi
}
setup_gradle_env

# `flutter build apk` 不能把 -P 透传给 Gradle，所以严格签名只能走 Gradle 的用户级属性文件
# （findProperty 会读 GRADLE_USER_HOME/gradle.properties，见 android/app/build.gradle.kts 的 strict 分支）
if [ "$DO_ANDROID" = 1 ] && [ "$STRICT_SIGNING" = 1 ]; then
  if [ -z "${GRADLE_USER_HOME:-}" ]; then
    export GRADLE_USER_HOME="${CACHE_DIR}/gradle-home"
    warn "GRADLE_USER_HOME 未设置，严格签名需要它来传属性，改用隔离目录 ${GRADLE_USER_HOME}
      （首次会重新下载全部 Gradle 依赖；已有缓存的机器建议 export GRADLE_USER_HOME 后再跑）"
  fi
  mkdir -p "$GRADLE_USER_HOME"
  if ! grep -q '^quarklite.requireReleaseSigning=true' "${GRADLE_USER_HOME}/gradle.properties" 2>/dev/null; then
    printf 'quarklite.requireReleaseSigning=true\n' >> "${GRADLE_USER_HOME}/gradle.properties"
  fi
  log "严格签名已开启：${GRADLE_USER_HOME}/gradle.properties 里写入 quarklite.requireReleaseSigning=true"
fi

# ---------------------------------------------------------------- 3. Android
if [ "$DO_ANDROID" = 1 ]; then
  log "flutter build apk --release（universal）"
  ( cd "$REPO_ROOT" && "$FLUTTER_BIN" build apk --release )
  APK="${REPO_ROOT}/build/app/outputs/flutter-apk/app-release.apk"
  [ -f "$APK" ] || die "构建结束但没产出 $APK"
  record "$APK"

  if [ "$DO_SPLIT" = 1 ]; then
    log "flutter build apk --release --split-per-abi"
    ( cd "$REPO_ROOT" && "$FLUTTER_BIN" build apk --release --split-per-abi )
    # 这三个是 flutter --split-per-abi 的默认 ABI（仓库里没有 abiFilters/target-platform），
    # 换平台集要同时改这里与上面的构建命令。
    for abi in arm64-v8a armeabi-v7a x86_64; do
      f="${REPO_ROOT}/build/app/outputs/flutter-apk/app-${abi}-release.apk"
      [ -f "$f" ] && record "$f" || warn "缺少 ${abi} 分包：$f"
    done
  fi

  if [ "$DO_AAB" = 1 ]; then
    log "flutter build appbundle --release"
    ( cd "$REPO_ROOT" && "$FLUTTER_BIN" build appbundle --release )
    AAB="${REPO_ROOT}/build/app/outputs/bundle/release/app-release.aab"
    [ -f "$AAB" ] || die "构建结束但没产出 $AAB"
    record "$AAB"
  fi

  # flutter build 会吞掉 gradle 里的告警（docs/build-and-env.md §6.8 B-6），
  # 所以签名者必须在构建之后单独验一次，不能靠日志。
  log "校验 APK 签名者"
  SIGNER="unknown"
  APKSIGNER=""
  if [ -n "${ANDROID_HOME:-}" ]; then
    APKSIGNER="$(ls "${ANDROID_HOME}"/build-tools/*/apksigner 2>/dev/null | head -1 || true)"
    [ -n "$APKSIGNER" ] || APKSIGNER="$(ls "${ANDROID_HOME}"/build-tools/*/apksigner.bat 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$APKSIGNER" ] && [ -x "$APKSIGNER" -o -f "$APKSIGNER" ]; then
    SIGNER_OUT="$("$APKSIGNER" verify --print-certs "$APK" 2>&1 || true)"
    [ -n "$SIGNER_OUT" ] || die "apksigner 无输出：无法判定签名者（按失败处理）"
    SIGNER="$(printf '%s\n' "$SIGNER_OUT" | sed -nE 's/^Signer #1 certificate DN: (.*)$/\1/p' | head -1)"
    printf '   %s\n' "$SIGNER"
    if printf '%s' "$SIGNER" | grep -q "CN=Android Debug"; then
      if [ "$STRICT_SIGNING" = 1 ]; then
        die "严格模式下仍拿到 debug 签名，说明签名材料配置有问题，停止出包"
      fi
      warn "当前是 DEBUG 签名包：**不可对外发布**（与正式包签名不同，用户无法覆盖安装）。
        发版请配 android/key.properties 并加 --require-release-signing，或走 CI（docs/build-and-env.md §3.1）"
    fi
  else
    warn "没找到 apksigner，签名者未校验（ANDROID_HOME=${ANDROID_HOME:-<未设置>}）"
  fi
fi

# ---------------------------------------------------------------- 4. Windows
if [ "$DO_WINDOWS" = 1 ]; then
  log "flutter build windows --release"
  ( cd "$REPO_ROOT" && "$FLUTTER_BIN" build windows --release )
  REL_DIR="${REPO_ROOT}/build/windows/x64/runner/Release"
  [ -f "${REL_DIR}/quarklite.exe" ] || die "缺少 ${REL_DIR}/quarklite.exe"
  if [ -f "${REL_DIR}/gopeed.exe" ]; then
    log "产物目录已含 gopeed.exe（windows/runner/CMakeLists.txt 的 POST_BUILD 拷贝）"
  else
    warn "产物目录里没有 gopeed.exe：安装后应用会报「未找到 gopeed.exe」"
  fi

  ISCC_EXE="${ISCC_EXE:-}"
  if [ -z "$ISCC_EXE" ]; then
    for c in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
      [ -f "$c" ] && { ISCC_EXE="$c"; break; }
    done
    [ -n "$ISCC_EXE" ] || ISCC_EXE="$(command -v iscc 2>/dev/null || true)"
  fi
  if [ -z "$ISCC_EXE" ] || [ ! -f "$ISCC_EXE" ]; then
    warn "没找到 Inno Setup 的 ISCC.exe，跳过安装包（便携目录产物仍可用：${REL_DIR}）"
  else
    log "ISCC 编译安装包（AppVersion=${VER_NAME}）"
    # /Dxxx 在 MSYS 下会被当成路径转换，必须关掉（docs/build-and-env.md §6.8 B-8）
    ( cd "$REPO_ROOT" && MSYS_NO_PATHCONV=1 "$ISCC_EXE" "/DAppVersion=${VER_NAME}" scripts/quarklite.iss >/dev/null )
    SETUP="${REPO_ROOT}/build/installer/quarklite-${VER_NAME}-setup.exe"
    [ -f "$SETUP" ] || die "ISCC 退出但没有 $SETUP"
    record "$SETUP"
  fi
fi

# ---------------------------------------------------------------- 5. 汇总
log "产物清单"
if [ "${#OUT_LIST[@]}" -eq 0 ]; then
  warn "没有产出任何文件级产物（Windows 便携目录除外），请检查上面的日志"
fi
for f in "${OUT_LIST[@]}"; do
  size="$(wc -c < "$f" | tr -d ' ')"
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  printf '  %14s B  %s\n%s\n' "$size" "$sha" "     $f"
done
if [ "$DO_WINDOWS" = 1 ]; then
  printf '  便携目录：%s（%s 个文件）\n' \
    "${REPO_ROOT}/build/windows/x64/runner/Release" \
    "$(find "${REPO_ROOT}/build/windows/x64/runner/Release" -type f | wc -l | tr -d ' ')"
fi
if [ "$DO_ANDROID" = 1 ] && [ "$STRICT_SIGNING" != 1 ]; then
  warn "本次未开 --require-release-signing：若缺 key.properties，出的是 debug 签名包"
fi
log "完成"
