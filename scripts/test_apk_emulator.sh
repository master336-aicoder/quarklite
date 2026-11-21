#!/usr/bin/env bash
# 在本地 Android 模拟器上冒烟测试已构建的 APK。
#
# 覆盖范围（务必看清，这不是功能验收）：
#   1. AVD 缺失时按固定参数创建（pixel_6 + google_apis x86_64）；
#   2. 冷启动、等待 boot_completed、安装、force-stop 后重新启动；
#   3. 从 logcat 断言：进程存活、libgojni.so（Gopeed 引擎 AAR）被成功加载、
#      引擎 REST 调用没有 401、Dart 侧没有 Unhandled Exception；
#   4. 截图留档。
# 未覆盖：网盘登录、真实下载、前台服务保活 —— 需要真实凭据与真机，见 docs/build-and-env.md §7。
#
# 用法：
#   bash scripts/test_apk_emulator.sh [--apk <path>] [--avd <name>] [--api <n>]
#                                     [--recreate-avd] [--no-window]
# 默认测 build/app/outputs/flutter-apk/app-release.apk；模拟器已在跑则复用。
# 前置：ANDROID_HOME 已设置；已接受 sdk 许可；模拟器硬件加速可用（emulator -accel-check）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK=""
AVD_NAME="quark_api36"
API_LEVEL="36"
SYS_IMAGE="system-images;android-${API_LEVEL};google_apis;x86_64"
DEVICE="pixel_6"
PACKAGE="com.quarklite.quarklite"
ACTIVITY="${PACKAGE}/.MainActivity"
NO_WINDOW=""
FORCE_RECREATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --avd) AVD_NAME="$2"; shift 2 ;;
    --api) API_LEVEL="$2"; SYS_IMAGE="system-images;android-$2;google_apis;x86_64"; shift 2 ;;
    --recreate-avd) FORCE_RECREATE="1"; shift ;;
    --no-window) NO_WINDOW="1"; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "${SDK}" ] || [ ! -d "${SDK}" ]; then
  echo "!! 未设置 ANDROID_HOME，或目录不存在。先 source 环境脚本再运行。" >&2
  exit 1
fi
# Windows 的 SDK 只有 .bat/.exe，POSIX 下是同名脚本/二进制 —— 两者都接受
resolve_tool() {
  local base="$1" cand
  for cand in "${base}" "${base}.exe" "${base}.bat"; do
    if [ -f "${cand}" ]; then printf '%s' "${cand}"; return 0; fi
  done
  return 1
}
EMULATOR="$(resolve_tool "${SDK}/emulator/emulator")" || EMULATOR=""
ADB="$(resolve_tool "${SDK}/platform-tools/adb")" || ADB=""
AVDMANAGER="$(resolve_tool "${SDK}/cmdline-tools/latest/bin/avdmanager")" || AVDMANAGER=""
for t in "${EMULATOR}" "${ADB}" "${AVDMANAGER}"; do
  if [ -z "${t}" ]; then
    echo "!! 缺少工具：需要 android-sdk 的 emulator / platform-tools / cmdline-tools;latest 三个包。" >&2
    exit 1
  fi
done
if [ -z "${APK}" ]; then
  for cand in \
    "${REPO_ROOT}/build/app/outputs/flutter-apk/app-release.apk" \
    "${REPO_ROOT}/build/apk/quarklite-release.apk" \
    "${REPO_ROOT}/build/app/outputs/apk/release/app-release.apk"; do
    [ -f "${cand}" ] && { APK="${cand}"; break; }
  done
  APK="${APK:-${REPO_ROOT}/build/app/outputs/flutter-apk/app-release.apk}"
fi
if [ ! -f "${APK}" ]; then
  echo "!! 找不到待测 APK：${APK}" >&2
  echo "   先执行：bash scripts/build_all.sh --apk-only" >&2
  exit 1
fi

OUT_DIR="${REPO_ROOT}/build/emulator-test"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/logcat.txt"
FAILED=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILED=1; }

note "==> APK      : ${APK} ($(wc -c <"${APK}") bytes)"
note "==> AVD      : ${AVD_NAME} (${DEVICE} / ${SYS_IMAGE})"
note "==> 产物目录 : ${OUT_DIR}"

# --- 0. 硬件加速 -------------------------------------------------------------
note "==> 检查模拟器硬件加速"
if ! "${EMULATOR}" -accel-check >/dev/null 2>&1; then
  bad "硬件加速不可用：${EMULATOR} -accel-check 失败（x86_64 镜像无加速会慢到不可用）"
  exit 1
fi
ok "accel-check 通过：$("${EMULATOR}" -accel-check 2>&1 | tr -d '\r' | tail -1)"

# --- 1. AVD 是否存在 ---------------------------------------------------------
avd_exists() {
  "${AVDMANAGER}" list avd 2>/dev/null | tr -d '\r' \
    | grep -qE "^[[:space:]]*Name:[[:space:]]*${AVD_NAME}[[:space:]]*$"
}
if avd_exists; then
  note "==> 复用已有 AVD ${AVD_NAME}"
else
  if [ ! -d "${SDK}/system-images/android-${API_LEVEL}/google_apis/x86_64" ]; then
    bad "缺少系统镜像 ${SYS_IMAGE}，本脚本不联网自动下载。请执行："
    note "    sdkmanager \"${SYS_IMAGE}\" \"emulator\" \"platform-tools\""
    exit 1
  fi
  note "==> 创建 AVD ${AVD_NAME}"
  if [ -n "${FORCE_RECREATE}" ]; then
    "${AVDMANAGER}" delete avd -n "${AVD_NAME}" >/dev/null 2>&1 || true
  fi
  echo "no" | "${AVDMANAGER}" create avd -n "${AVD_NAME}" -k "${SYS_IMAGE}" -d "${DEVICE}" \
    >/dev/null 2>&1 || true
  if ! avd_exists; then
    bad "AVD 创建失败"
    exit 1
  fi
  ok "AVD 已创建"
fi

# --- 2. 启动并等待开机完成 ---------------------------------------------------
if "${ADB}" devices 2>/dev/null | tr -d '\r' | grep -qE "^emulator-[0-9]+[[:space:]]+device$"; then
  note "==> 模拟器已在运行，直接复用"
else
  note "==> 启动模拟器（首次冷启动可能要 1-3 分钟）"
  EMU_ARGS=(-avd "${AVD_NAME}" -no-snapshot -no-audio -no-boot-anim -gpu auto)
  [ -n "${NO_WINDOW}" ] && EMU_ARGS+=(-no-window)
  # 必须脱离脚本进程组，否则脚本退出时模拟器一起被带走
  case "$(uname -s 2>/dev/null || echo Windows)" in
    MINGW*|MSYS*|CYGWIN*|Windows*)
      EMU_ARGSTR=""
      for a in "${EMU_ARGS[@]}"; do EMU_ARGSTR="${EMU_ARGSTR}${a} "; done
      EMU_WIN="$(cygpath -w "${EMULATOR}" 2>/dev/null || printf '%s' "${EMULATOR}")"
      LOG_WIN="$(cygpath -w "${OUT_DIR}/emulator.log" 2>/dev/null || printf '%s' "${OUT_DIR}/emulator.log")"
      PS_CMD="Start-Process -FilePath '${EMU_WIN}' -ArgumentList '${EMU_ARGSTR}' -WindowStyle Minimize -RedirectStandardError '${LOG_WIN}'"
      powershell -NoProfile -Command "${PS_CMD}" >/dev/null 2>&1 \
        || { bad "Start-Process 启动模拟器失败（可手工执行：${EMULATOR} ${EMU_ARGSTR}）"; exit 1; } ;;
    *)
      setsid "${EMULATOR}" "${EMU_ARGS[@]}" >"${OUT_DIR}/emulator.log" 2>&1 < /dev/null & ;;
  esac
fi
"${ADB}" wait-for-device || { bad "adb wait-for-device 失败"; exit 1; }
BOOTED=""
for _ in $(seq 1 120); do
  V="$("${ADB}" -e shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  [ "${V}" = "1" ] && { BOOTED="1"; break; }
  sleep 2
done
if [ -z "${BOOTED}" ]; then
  bad "等待 boot_completed 超时（4 分钟），详见 ${OUT_DIR}/emulator.log"
  exit 1
fi
ok "系统已开机：Android $(  "${ADB}" -e shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"

# --- 3. 安装并冷启动 ---------------------------------------------------------
note "==> 安装 APK"
if ! "${ADB}" -e install -r -g "${APK}" >"${OUT_DIR}/install.log" 2>&1; then
  bad "安装失败：$(tail -3 "${OUT_DIR}/install.log" | tr -d '\r' | tr '\n' ' ')"
  exit 1
fi
ok "安装成功"
"${ADB}" -e shell am force-stop "${PACKAGE}" >/dev/null 2>&1
sleep 1
"${ADB}" logcat -c >/dev/null 2>&1
"${ADB}" -e shell am start -W -n "${ACTIVITY}" >"${OUT_DIR}/amstart.log" 2>&1
ok "已发起启动：$(grep -i 'Status\|TotalTime' "${OUT_DIR}/amstart.log" | tr -d '\r' | tr '\n' ' ')"

# 等引擎后台拉起 + 一轮轮询（gopeed_boot 的启动路径在这里被真实执行）
sleep 25

# --- 4. 断言 -----------------------------------------------------------------
"${ADB}" logcat -d >"${LOG}" 2>&1
LOG_LINES="$(wc -l <"${LOG}" | tr -d ' ')"
note "==> 抓取 logcat：${LOG_LINES} 行"

if "${ADB}" -e shell pidof "${PACKAGE}" 2>/dev/null | tr -d '\r' | grep -qE '[0-9]'; then
  ok "进程存活（pid $("${ADB}" -e shell pidof "${PACKAGE}" 2>/dev/null | tr -d '\r')）"
else
  bad "进程不存在 —— 启动后崩溃"
fi

grep -q "libgojni.so" "${LOG}" && ! grep -q "libgojni.so.*not found\|dlopen failed" "${LOG}"
if [ $? -eq 0 ]; then
  ok "Gopeed 引擎原生库已加载（libgojni.so）"
else
  bad "libgojni.so 未成功加载 —— AAR 可能缺 ABI 或与设备 ABI 不匹配"
fi

if grep -qE "status code of 401|unauthorized" "${LOG}"; then
  bad "引擎 REST 返回 401 —— 鉴权头不匹配（应发 X-Api-Token，见 docs/security-design.md §8.2 E-12）"
  grep -E "轮询任务列表失败|后台启动引擎失败" "${LOG}" | head -2 | tr -d '\r' | sed 's/^/        /'
else
  ok "未出现 401/未授权"
fi

if grep -q "Unhandled Exception" "${LOG}"; then
  bad "Dart 侧存在未捕获异常"
  grep -A 6 "Unhandled Exception" "${LOG}" | head -14 | tr -d '\r' | sed 's/^/        /'
else
  ok "未出现 Unhandled Exception"
fi

if grep -qE "FATAL EXCEPTION|signal [0-9]+ \(SIG" "${LOG}"; then
  bad "存在原生崩溃（FATAL EXCEPTION / native signal）"
  grep -E "FATAL EXCEPTION" "${LOG}" | head -2 | tr -d '\r' | sed 's/^/        /'
else
  ok "未出现原生崩溃"
fi

"${ADB}" -e exec-out screencap -p >"${OUT_DIR}/screen.png" 2>/dev/null
if [ -s "${OUT_DIR}/screen.png" ]; then
  ok "截图已保存：${OUT_DIR}/screen.png ($(wc -c <"${OUT_DIR}/screen.png") bytes)"
else
  note "  WARN  截图为空（不影响结论）"
fi

note ""
note "==> 本脚本未验证：网盘登录、真实下载落盘、前台服务保活、Android 12+ 通知权限弹窗。"
note "==> 结论仅针对'引擎能被应用拉起并正常鉴权'。"
if [ "${FAILED}" = "0" ]; then
  note "==> 冒烟测试通过"
else
  note "==> 冒烟测试存在问题，见上面 FAIL 行"
fi
exit "${FAILED}"
