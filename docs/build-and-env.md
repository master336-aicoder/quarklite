# Quarklite 构建与环境

本文覆盖三件事：本机开发环境、Gopeed 引擎产物的构建、CI 构建的前置条件。
发布与故障处理见 [operations.md](operations.md)。

---

## 1. 本机环境

| 工具 | 要求 | 依据 |
|---|---|---|
| Flutter | stable 频道，Dart SDK `^3.12.2` | [pubspec.yaml:7-8](file:///D:/qorder/quarklite/pubspec.yaml#L7-L8)、CI 用 `channel: stable`（[.github/workflows/build.yml:43-46](file:///D:/qorder/quarklite/.github/workflows/build.yml#L43-L46)） |
| JDK | 17（`sourceCompatibility = VERSION_17`、`jvmTarget = JVM_17`） | [android/app/build.gradle.kts](file:///D:/qorder/quarklite/android/app/build.gradle.kts) 的 `compileOptions` / `kotlin { compilerOptions }` |
| Go | 1.25（CI 固定 `go-version: '1.25'`） | [.github/workflows/build.yml:32-35](file:///D:/qorder/quarklite/.github/workflows/build.yml#L32-L35) |
| Android SDK | 平台随 `flutter.compileSdkVersion`，NDK 随 `flutter.ndkVersion` | [android/app/build.gradle.kts](file:///D:/qorder/quarklite/android/app/build.gradle.kts) `android { }` 头部 |
| iOS | macOS + Xcode，`pod install`；最低 iOS 15 | [README.md:55-57](file:///D:/qorder/quarklite/README.md#L55-L57) |
| Windows | Visual Studio 2022（C++ 桌面负载，**必须带 ATL/MFC 组件**）+ CMake（Flutter 自带）+ 开发者模式 | `windows/` 为 Flutter 标准 C++ runner；缺 ATL 时 `flutter_local_notifications_windows`、`flutter_secure_storage_windows` 会报 `C1083 无法打开包括文件 "atlbase.h"`，缺开发者模式时插件符号链接创建失败，实测见 §6.1 |

依赖解析需要联网（pub.dev、Maven Central、GitHub）。项目没有配置私有镜像。

> **2026-11-13 本机实测补充**（完整命令与产物见 §6）：上表是"最低要求"口径，实际出包时
> 有三处与表格不同、且踩过坑：
> ① **Flutter 只能用 3.44.x，不能用 3.50**。3.50 的 `DependencyVersionChecker` 要求
> Gradle ≥ 9.3.1、AGP ≥ 9.1.1、KGP ≥ 2.4.10，而本仓库固定的是 Gradle 8.14
> （[android/gradle/wrapper/gradle-wrapper.properties:5](file:///D:/qorder/quarklite/android/gradle/wrapper/gradle-wrapper.properties#L5)）
> + AGP 8.13.2 + KGP 2.3.20（[android/settings.gradle.kts:22-23](file:///D:/qorder/quarklite/android/settings.gradle.kts#L22-L23)）。
> 用 3.50 出包必须改这三处受版本控制的构建配置，风险大于收益，故选用 Dart 3.12.2 的
> Flutter 3.44.9——正好等于 `pubspec.yaml:8` 的下限。
> ② **JDK 21 可以直接出包**：`VERSION_17` / `JVM_17` 是 source/target 兼容级别，不是 JDK 下限。
> ③ 国内网络下 `services.gradle.org`、`dl.google.com` Maven、`repo.maven.apache.org`
> 实测不可用（前者 135 B/s），需要在 `GRADLE_USER_HOME` 放一条**只改写仓库 URL**
> 的 `init.gradle`，见 §6.4。

### 1.1 首次构建

```bash
flutter pub get
bash scripts/build_libgopeed.sh          # 产出 android/app/libs/libgopeed.aar
flutter build apk --release
```

**`libgopeed.aar` 不在仓库里**，Android 构建缺它会失败，所以第 2 步不能跳。

`flutter pub get` 之后请检查 `pubspec.lock` 是否被改动：
CI 会在 lock 与 `pubspec.yaml` 不一致时直接失败
（[.github/workflows/build.yml:105-116](file:///D:/qorder/quarklite/.github/workflows/build.yml#L105-L116)）。
本地如果 `git diff pubspec.lock` 非空，就把更新后的 lock 一起提交。

### 1.2 本地 release 签名（可选）

`android/key.properties` 与 `android/app/upload-keystore.jks` 都在 `.gitignore` 内
（[.gitignore:48-49](file:///D:/qorder/quarklite/.gitignore#L48-L49)），本地自测可以直接不打签名：
缺 `key.properties` 时 release 构建会退回 debug 签名并打印醒目告警
（[android/app/build.gradle.kts:48-67](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L48-L67)）。

要本地复现正式签名，写 `android/key.properties`：

```properties
storeFile=upload-keystore.jks
storePassword=<口令>
keyAlias=<别名>
keyPassword=<口令>
```

`storeFile` 是相对 `android/app/` 的路径（Gradle `file(...)` 以模块目录为基准，见
[android/app/build.gradle.kts:40](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L40)；
这一条是**从 CI 的写法反推**的：CI 把 keystore 解到 `android/app/upload-keystore.jks`，
而 `key.properties` 里只写裸文件名 `upload-keystore.jks`，见
[.github/workflows/build.yml:91-98](file:///D:/qorder/quarklite/.github/workflows/build.yml#L91-L98)，
未单独核对 Gradle 官方文档）。

> 注意：`flutter build apk --release` 在本地默认**不**启用严格签名校验。
> 想复现 CI 的"缺签名就失败"行为，加
> `-Pquarklite.requireReleaseSigning=true`（Gradle project property），
> 见 [android/app/build.gradle.kts:55-61](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L55-L61)。

### 1.3 Windows 运行环境

Windows 版**不会自带 `gopeed.exe`**：只有先把引擎放到 `windows/resources/gopeed.exe`，
[windows/runner/CMakeLists.txt:43-50](file:///D:/qorder/quarklite/windows/runner/CMakeLists.txt#L43-L50)
才会在 POST_BUILD 用 `copy_if_different` 把它拷进产物目录；缺该文件时构建照常成功，
运行期再按两个受控位置查找（主程序同级目录、应用文档目录），找不到就报
"未找到 gopeed.exe，请确认程序目录完整"
（[lib/core/gopeed/gopeed_boot.dart:300-311](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L300-L311)、
[lib/core/gopeed/gopeed_boot.dart:192-196](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L192-L196)）。
引擎的具体编法与实测产物见本文 §6.2。

加固后**已删除"裸名 `gopeed.exe`"这一候选**（原来会按当前工作目录与 `PATH` 解析），
因此不能把引擎放到任意目录指望它能被找到
（[lib/core/gopeed/gopeed_boot.dart:296-299](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L296-L299)）。

---

## 2. 引擎源码完整性

Android 的下载内核是把 Gopeed 的 Go 代码用 `gomobile bind` 编成 AAR：

```
scripts/build_libgopeed.sh
  ├── git clone --depth 1 --branch <GOPEED_VERSION> GopeedLab/gopeed
  ├── 校验 HEAD commit == GOPEED_COMMIT                     :39-54
  ├── go install golang.org/x/mobile/cmd/gomobile@<GOMOBILE_VERSION>   :56-64
  ├── gomobile init                                          :68-69
  └── gomobile bind -tags nosqlite -ldflags="-w -s -checklinkname=0"
        -target=android -androidapi 21 -javapkg=com.gopeed
        github.com/GopeedLab/gopeed/bind/mobile              :71-77
```

脚本参数（[scripts/build_libgopeed.sh:12-21](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L12-L21)）：

| 环境变量 | 作用 | 不设置时 |
|---|---|---|
| `GOPEED_VERSION` | clone 的 tag，默认 `v1.9.3` | 用默认 tag |
| `GOPEED_COMMIT` | 期望的源码 commit（完整或短 SHA） | 打印告警并**继续**（[scripts/build_libgopeed.sh:52-54](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L52-L54)） |
| `GOMOBILE_VERSION` | gomobile 版本，如 `v0.8.2` | 退回 `@latest` 并告警（[scripts/build_libgopeed.sh:56-61](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L56-L61)） |
| 位置参数 1 | AAR 输出路径，默认 `android/app/libs/libgopeed.aar` | 用默认路径 |

加固带来的三点行为变化：

1. **commit 校验优先于 tag**：tag 是可由仓库所有者移动的引用，
   只看 tag 无法确认两次构建用的是同一份源码。校验失败**直接 exit 1**
   （[scripts/build_libgopeed.sh:41-51](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L41-L51)）。
2. **源码目录按 UID 隔离**：不再复用共享的 `/tmp/gopeed-src`。
   多用户机器上共享目录可被他人抢先创建并替换内容，而缓存命中会跳过 clone
   （[scripts/build_libgopeed.sh:20-21](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L20-L21)）。
3. **产物打印 SHA-256**，便于把 AAR 与某次发布记录对应起来
   （[scripts/build_libgopeed.sh:80-82](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L80-L82)）。

CI 侧相应地**去掉了 gopeed 源码的 `actions/cache`**：原来的
`restore-keys: gopeed-` 会跨版本命中旧缓存，缓存内容又不参与校验，
等于"构建用的是哪版引擎源码"无法确认；浅克隆一个 tag 体量很小，
用重新拉取换可追溯性（[.github/workflows/build.yml:48-58](file:///D:/qorder/quarklite/.github/workflows/build.yml#L48-L58)）。

---

## 3. CI 前置条件（必须逐项配置，否则构建失败）

### 3.1 Secrets（4 个，全部必填）

| Secret | 内容 |
|---|---|
| `QUARKLITE_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` 的输出 |
| `QUARKLITE_KEYSTORE_PASSWORD` | keystore 口令 |
| `QUARKLITE_KEY_ALIAS` | 密钥别名 |
| `QUARKLITE_KEY_PASSWORD` | 私钥口令 |

缺任意一个都会在构建早期失败并指明名字，不会静默产出 debug 签名包
（[.github/workflows/build.yml:63-81](file:///D:/qorder/quarklite/.github/workflows/build.yml#L63-L81)）。
恢复方式是把 base64 解码成 `android/app/upload-keystore.jks`，
再写 `android/key.properties`，并用 `keytool -list` 自检口令与别名可用
（[.github/workflows/build.yml:83-103](file:///D:/qorder/quarklite/.github/workflows/build.yml#L83-L103)）。

生成新的签名材料（首次配置或密钥泄露后轮换）：

```bash
keytool -genkeypair -v \
  -keystore upload-keystore.jks -alias quarklite \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Quarklite, OU=Dev, O=Quarklite, L=Beijing, S=Beijing, C=CN"
# 交互式提示入口令，然后
base64 -w0 upload-keystore.jks | xclip -selection clipboard
```

> **换 keystore = 老用户无法覆盖安装**，必须作为全新安装包分发。
> 轮换流程与影响面在 [operations.md](operations.md) §3。

### 3.2 Variables（正式发版必填）

| Variable | 建议值 | 说明 |
|---|---|---|
| `GOPEED_VERSION` | `v1.9.3` | 引擎源码 tag |
| `GOPEED_COMMIT` | 该 tag 指向的完整 commit SHA | 完整性校验基准；不设则 CI 打告警继续 |
| `GOMOBILE_VERSION` | 例如 `v0.8.2` | 固定工具链，避免 `@latest` 漂移 |

查 `GOPEED_COMMIT`：

```bash
git ls-remote https://github.com/GopeedLab/gopeed.git refs/tags/v1.9.3
```

### 3.3 权限

- `build-android`：`permissions: contents: read`
  （[.github/workflows/build.yml:15-18](file:///D:/qorder/quarklite/.github/workflows/build.yml#L15-L18)）——打 APK 不需要写仓库。
- `publish-release`：`permissions: contents: write`
  （[.github/workflows/build.yml:177-181](file:///D:/qorder/quarklite/.github/workflows/build.yml#L177-L181)）——只有发 Release 的 job 拿写权限。
- 诊断工作流同样显式声明 `contents: read`
  （[.github/workflows/diag-gopeed.yml](file:///D:/qorder/quarklite/.github/workflows/diag-gopeed.yml)）。

---

## 4. 诊断工作流的使用前提

`.github/workflows/diag-gopeed.yml` 会在 Windows runner 上**真的执行** `gopeed.exe`，
加固后增加了 SHA-256 校验步骤：`workflow_dispatch` 时可传 `gopeed_sha256`，
不传则打告警继续（用于排查官方产物本身的问题时不被校验卡住），
传了且不匹配则硬失败。

该工作流**故意**保留 `-T ''`（无 token）启动，用来复现"引擎未鉴权"这一原始状态；
应用侧现在始终传随机 token
（对照 [lib/core/gopeed/gopeed_boot.dart:210](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L210)）。
不要把该工作流的参数写法当成应用配置的参考。

---

## 5. 静态检查

```bash
dart analyze                 # 配置见 analysis_options.yaml
flutter test                 # test/ 目录
```

**状态更新（2026-11-13 第一轮）**：上面这些命令都真跑过了 —— 本机装了 Flutter 3.50.0
stable（Dart 3.14.0）在 `D:/tools/flutter`，SDK 包按官方 `releases_windows.json` 的
sha256 校验后才解压。结果与逐项证据在
[hardening-changelog.md](hardening-changelog.md) §5.4。当时**未执行**的出包类命令
（`flutter build apk` / Gopeed AAR / gopeed.exe / Windows 安装包）已在同日第二轮补齐：
Android SDK、Go、VS2022 Build Tools、Inno Setup、开发者模式全部装好，两个平台的包
都产出并验证过 —— **完整记录见本文 §6**（注意第二轮出包用的是 Flutter 3.44.9，不是这里跑
静态检查的 3.50.0，原因见 §1 表格下方的补充 ①）。

国内网络下需要的两个环境变量（否则会从 GCS 拉，实测慢约 60 倍）：

```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn   # 引擎产物
export PUB_HOSTED_URL=https://pub.flutter-io.cn                  # pub 包
```

另注：`flutter` 每次启动会在 SDK 自己的仓库里跑 `git fetch --tags`；本机 CRL 取不到
导致它报 `code 128`，但**不影响命令成功**（与克隆本仓库要 `--ssl-no-revoke` 是同一个问题）。

---

## 6. 全平台出包实测（2026-11-13 第二轮）

本节记录**真的把安装包跑出来**的全过程：装了哪些工具、每条命令、产物 SHA-256、
签名状态、以及**没有**验证到的部分。覆盖 Android（APK / split-per-ABI / AAB）与
Windows（runner 产物 + Inno Setup 安装包）；iOS/macOS/Linux 见 §6.7。

本机所有工具都装在仓库外（`D:/tools`，VS 与 Inno 装到系统目录），
`D:/tools/env.sh` 是被 `source` 的环境脚本。仓库内除了工具自己生成的
`pubspec.lock`，**没有改动任何受版本控制的构建配置**。

### 6.1 工具链实际安装组合

| 组件 | 实测可用版本 | 安装位置 | 说明 |
|---|---|---|---|
| Flutter（出包用） | **3.44.9** stable / Dart 3.12.2 | `D:/tools/flutter-3.44.9` | 3.50.0 跑不了本仓库的 Gradle 配置，见 §6.8 勘误 B-1。SDK 包按官方 `releases_windows.json` 的 sha256 校验：`8ef1107d226654736755bc51b969d6bd46787ff0241650f942e774fb0ca7d0ac`，该条目 `dart_sdk_version` = 3.12.2，正好等于 [pubspec.yaml:8](file:///D:/qorder/quarklite/pubspec.yaml#L8) 的下限 |
| Flutter（静态检查用） | 3.50.0 stable / Dart 3.14.0 | `D:/tools/flutter` | 只用于 §5 的 analyze/test，与出包无关 |
| JDK | 21.0.2 | `D:/Programs/Java/jdk-21` | 见 §6.8 B-2 |
| Android SDK | platform 34/35/36、build-tools 35.0.0+36.0.0、NDK **28.2.13676358**、platform-tools、cmake | `D:/tools/android-sdk` | NDK 版本取 Flutter 3.44.9 的默认 `ndkVersion`（`flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:42`），这样 Gradle 侧不用覆盖；`gomobile init` 也复用同一份 NDK |
| Go | 1.27.4 windows/amd64 | `D:/tools/go` | zip 解压版，sha256 `178ab98950ac69ab25069307dc6ade79f3816e414cce95b4da166a115cde1e7e` 已与 [go.dev/dl](https://go.dev/dl/) 上 `go1.27.4.windows-amd64.zip` 的官方值核对一致（2026-11-13 核对） |
| gomobile | 伪版本 `v0.0.0-20261011034528-197770444867` | `D:/tools/gopath/bin` | 见 §6.8 B-3 |
| VS 2022 Build Tools | MSVC 工具集 **14.44.35207** + Windows SDK 10.0.26100 + **VC.ATL** | 系统目录（`C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools`） | 缺 ATL 直接编译失败，见 §6.5 |
| Inno Setup | 6.7.3 | `C:/Program Files (x86)/Inno Setup 6` | 见 §6.8 B-4 |
| Gradle | 8.14（wrapper 分发包） | `D:/tools/gradle-dist` | 仓库内的 wrapper 三件套不在版本控制里，见 §6.3 |
| Windows 开发者模式 | `AllowDevelopmentWithoutDevLicense=1` | 注册表 | Flutter 插件符号链接需要，缺失时报错见 §6.8 B-5 |

### 6.2 完整命令序列

> **一条命令版**：[scripts/build_all.sh](file:///D:/qorder/quarklite/scripts/build_all.sh)
> 把下面 0)~6) 全部串起来（含引擎源码 commit 校验、Gradle wrapper 补建、国内镜像、
> 严格签名与 `apksigner` 签名者断言、Inno 打包、产物 SHA-256 清单）。
> 引擎校验的严格度是分开的：编 **AAR** 时 `GOPEED_COMMIT` **必填**（不填直接 die），
> 编 **gopeed.exe** 时没填只告警（`:137`），两条都靠 tag 是不可接受的（tag 可被移动）。
> `bash scripts/build_all.sh` 出 exe + apk 两样；只要 Android 加 `--apk-only`，
> 只要 Windows 加 `--windows-only`；`--aab` 额外出 AAB；`--cn-mirror` 走国内镜像；
> `--skip-engine` 复用已有的 `libgopeed.aar` / `gopeed.exe`；`--help` 看全部门槛。
> 它**不是** CI 脚本：CI 用 [.github/workflows/build.yml](file:///D:/qorder/quarklite/.github/workflows/build.yml)，
> 两者口径的差距记在 §7.1。下面的手工序列仍然保留，因为脚本失败时要能逐步定位。

```bash
# 0) 环境（Git Bash）
. /d/tools/env.sh
export PATH="/d/tools/flutter-3.44.9/bin:$PATH"; hash -r
cd /d/qorder/quarklite
flutter config --android-sdk D:/tools/android-sdk

# 1) 依赖（会重写 pubspec.lock，见 §6.6）
flutter pub get

# 2) Android 引擎库（见 §2 的脚本口径；本机手工执行等价命令，见下方注意）
GOPEED_VERSION=v1.9.3 \
GOPEED_COMMIT=a5cd53f94c18ac65add684b1113fa5f0b47cc4da \
GOMOBILE_VERSION=v0.0.0-20261011034528-197770444867 \
  bash scripts/build_libgopeed.sh

# 3) Android 包
flutter build apk --release
flutter build apk --release --split-per-abi
flutter build appbundle --release

# 4) Windows 引擎（放到位后 CMake 才会打包，见 §1.3）
cd /d/tools/dl/gopeed-src && go build -tags nosqlite,web -ldflags="-s -w" \
  -o /d/qorder/quarklite/windows/resources/gopeed.exe github.com/GopeedLab/gopeed/cmd/web

# 5) Windows runner + 安装包
cd /d/qorder/quarklite
flutter build windows --release
MSYS_NO_PATHCONV=1 "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" \
  /DAppVersion=1.3.3 scripts/quarklite.iss
```

> **口径说明**：上面是**产出这些包的命令序列**，不是逐条截图回放。两处工具自动落盘的东西
> 值得知道：`flutter config`/首次构建会写 `android/local.properties`（内容
> `flutter.sdk=D:\tools\flutter-3.44.9` + `sdk.dir=D:/tools/android-sdk`，该文件被
> [android/.gitignore:6](file:///D:/qorder/quarklite/android/.gitignore#L6) 忽略，不会进仓库）；
> 第 2 步的脚本在本机**没有整段跑通过**——`go install` 与
> `git clone` 都卡在本机 CRL 取不到（见本节末尾的"另注"同因）。实际做法是按脚本的
> 参数手工执行同一条 `gomobile bind -tags nosqlite -ldflags="-w -s -checklinkname=0"
> -target=android -androidapi 21 -javapkg=com.gopeed github.com/GopeedLab/gopeed/bind/mobile`，
> 源码固定在上游 tag `v1.9.3` = commit `a5cd53f9…`。
> **CI 里脚本能否跑通仍未验证**。
> 第 4 步同理：上游官方口径要求先 `flutter build web` 再把 `ui/flutter/build/web`
> 拷成 `cmd/web/dist`（gopeed `README.md:282-287`），本机用 `//go:embed dist/*`
> 允许的单文件占位 `index.html` 代替——只影响内嵌 Web 控制台，不影响 REST API：
> 应用启动引擎时只传 `-A 127.0.0.1 -P 0 -T <随机 token> -d <存储目录>`，
> 之后全部走 HTTP API（[lib/core/gopeed/gopeed_boot.dart:207-212](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L207-L212)），
> 从不请求 `/ui/` 静态页。

### 6.3 Android 产物与两个坑

| 产物 | 大小（B） | SHA-256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-release.apk`（合包） | 74,880,245 | `86b687ae8949bf29e99e343db1f9c7c820500b1f6bd1641ebb2f56774cc82d8b` |
| `…/app-arm64-v8a-release.apk` | 26,741,146 | `ffa7641403870f13dea0e0cde3421bd77f6483586e66728102008f0dedaa1d65` |
| `…/app-armeabi-v7a-release.apk` | 26,982,528 | `b99914e1e5d330fffdf7ba3bd700e30324a0140236dab28e75a92b0b63529f48` |
| `…/app-x86_64-release.apk` | 28,201,031 | `8b24229f11280653466ca1c38604d7684913f546d552d7761e063c21cdf50b23` |
| `build/app/outputs/bundle/release/app-release.aab` | 153,236,507 | `4cbf11ef17e15ab94cae4d17adbd3b484201bbc89eec73cff600751c35d0935d` |
| `android/app/libs/libgopeed.aar` | 67,563,577 | `f2f52befe9dccb425c1e73b202f7a94c7d5bf7d41710719849177f7b8e855c9f` |

AAR 内含 4 个 ABI 的 `libgojni.so`（armeabi-v7a / arm64-v8a / x86 / x86_64，
`unzip -l` 实测），所以合包 APK 里出现 3 个 ABI 是预期结果：
`aapt2 dump badging` 报 `native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'`、
`versionName='1.3.3'`（[pubspec.yaml:5](file:///D:/qorder/quarklite/pubspec.yaml#L5)）、`targetSdkVersion='36'`。

**坑 1：fresh clone 没有 Gradle wrapper。**
[android/.gitignore:1](file:///D:/qorder/quarklite/android/.gitignore#L1)、
[:4-5](file:///D:/qorder/quarklite/android/.gitignore#L4-L5) 把
`gradle-wrapper.jar`、`/gradlew`、`/gradlew.bat` 全忽略了，而
[android/settings.gradle.kts:11](file:///D:/qorder/quarklite/android/settings.gradle.kts#L11)
又依赖 `includeBuild` 的 Flutter 工具链，clone 后必须先补出 wrapper。本机做法是用
一份外部 Gradle 8.14 生成 wrapper，再**只**拷 `gradlew`、`gradlew.bat`、
`gradle-wrapper.jar` 三个文件进 `android/`，保留仓库原有的
[android/gradle/wrapper/gradle-wrapper.properties:5](file:///D:/qorder/quarklite/android/gradle/wrapper/gradle-wrapper.properties#L5)
（`services.gradle.org` 国内实测 135 B/s，用 `--gradle-distribution-url` 指向腾讯镜像才能生成成功）。
CI 是否也会卡在这里**未验证**（本仓库 CI 从未在 GitHub 上跑过）。

**坑 2：缺签名材料的告警在 `flutter build` 路径下看不到。**
[android/app/build.gradle.kts:62-65](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L62-L65)
用 `logger.warn` 打印"release 将使用 DEBUG 签名"，但实测
`flutter build apk --release` 的 stdout 里 **0 次** 出现该文案
（本机日志 `grep -c Quarklite` = 0）；直接跑 `./gradlew :app:tasks` 才看得到（第 16 行）。
本机 5 个产物全部是 debug 签名：`apksigner verify --print-certs` 报
`Signer #1 certificate DN: C=US, O=Android, CN=Android Debug`。
因此**这批包不可对外发布**，正式分发要么配 CI Secrets（§3.1），要么本地加
`-Pquarklite.requireReleaseSigning=true`（§1.2）逼它失败而不是静默降级。

### 6.4 国内镜像与仓库改写

| 源 | 实测 | 替代 |
|---|---|---|
| `services.gradle.org` | 135 B/s，等同不可用 | `https://mirrors.cloud.tencent.com/gradle/`（17 MB/s） |
| `dl.google.com` Maven / `plugins.gradle.org` | 卡死 | `https://maven.aliyun.com/repository/google` / `…/gradle-plugin` |
| `repo.maven.apache.org` | 卡死 | `https://maven.aliyun.com/repository/public` |
| Go 模块 | — | `https://goproxy.cn,direct` + `GOSUMDB=sum.golang.google.cn` |
| pub / Flutter 引擎 | 慢约 60 倍 | `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`（§5） |

Gradle 侧**不改仓库文件**：把改写脚本放在 `GRADLE_USER_HOME/init.gradle`
（本机用 `D:/tools/gradle-home` 做隔离，不污染 `~/.gradle`）。脚本只做一件事——
按上表**原地替换已有 Maven 仓库的 URL**，不新增、不重排、不删除仓库，
因此不会改变依赖解析的优先级语义。

### 6.5 Windows 产物与安装包

| 步骤 | 结果 |
|---|---|
| `flutter build windows --release` | 成功，`build/windows/x64/runner/Release/` 递归共 **31 个文件**（顶层 11 项，含 `data/`、`plugins/`），含 `quarklite.exe` 与被 CMake 拷入的 `gopeed.exe`（证明 §1.3 修正后的说法） |
| 首次失败原因 | `C1083 无法打开包括文件 "atlbase.h"`（来自 `flutter_local_notifications_windows`、`flutter_secure_storage_windows`）→ 缺 VS 组件 `Microsoft.VisualStudio.Component.VC.ATL` |
| VS 组件补装 | `setup.exe modify --installPath "…" --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart`；`--installPath` 的值**必须带引号**，否则 `C:\Program Files` 空格会把参数拆成两个，退出码 1；`--quiet` 需管理员权限；`--wait` 不是 `setup.exe` 的合法开关 |
| 开发者模式 | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense=1`，缺它 Flutter 创建插件符号链接时报 `Cannot create symlink` |
| Inno Setup 编译 | `ISCC /DAppVersion=1.3.3 scripts/quarklite.iss` → `build/installer/quarklite-1.3.3-setup.exe`，耗时 52 s，`Successful compile` |
| 安装包验证 | 静默安装（`/VERYSILENT /CURRENTUSER`）→ 启动 `quarklite.exe` → 自动拉起同目录 `gopeed.exe`（日志出现 `Server start success on`）→ 卸载干净 |

| 产物 | 大小（B） | SHA-256 |
|---|---|---|
| `windows/resources/gopeed.exe` | 42,874,368 | `ef6d89c52ee82827a4399a7fd830aaabd35be6f183a4159f3db7f8b1edd697a2` |
| `build/installer/quarklite-1.3.3-setup.exe` | 23,174,584 | `f9dd8eccbb3308e153510aa74f27dc478bca6c9ca980c425fd4cef08a6d871c7` |

> 引擎 exe 单独 42 MB、安装包只有 23 MB：Inno 的 `lzma2` + `SolidCompression=yes`
> （[scripts/quarklite.iss:19-20](file:///D:/qorder/quarklite/scripts/quarklite.iss#L19-L20)）
> 对 Go 静态二进制压得很凶，属正常现象，不是"没打进去"。核对方式是解压安装包
> 后与 `build/windows/x64/runner/Release/` 逐文件比对，实测 31/31 一致。

> **许可提示（已联网核对官方口径）**：本机 ISCC 每次启动都打印
> `Non-commercial use only`。官方页面写的是
> "All commercial users of Inno Setup are requested to purchase a commercial license"
> （[jrsoftware.org/isinfo.php](https://jrsoftware.org/isinfo.php)），
> 且"regardless of the version being used"
> （[jrsoftware.org/isorder.php](https://jrsoftware.org/isorder.php)）。
> 也就是说 Inno Setup 的产物**可以**用于商业分发，但官方**要求**商业用户购买许可；
> 这是分发决策项，不是构建阻塞项。本项目是 GPL-3.0 开源应用，属"开源免费软件"分发口径，
> 与"commercial use"的边界**未请法务确认**。

### 6.6 `pubspec.lock` 的连带改动（当前未提交）

用 Flutter 3.44.9（Dart 3.12.2）跑 `flutter pub get` 会**回退锁文件**：
127 个包 → 126 个，7 处变化**全部是 transitive**，直接依赖版本一个没动：

| 包 | HEAD | 工作区 |
|---|---|---|
| `clock` | 1.1.3 | 1.1.2 |
| `matcher` | 0.12.20 | 0.12.19 |
| `meta` | 1.19.0 | 1.18.0 |
| `stack_trace` | 1.12.2 | 1.12.1 |
| `test_api` | 0.7.14 | 0.7.11 |
| `vector_math` | 2.4.4 | 2.2.0 |
| `listen` | 1.0.1 | **移除** |
| `sdks.dart` | `>=3.13.0-0 <4.0.0` | `>=3.12.2 <4.0.0` |

CI 会在 lock 与 `pubspec.yaml` 不一致时失败（§1.1），所以这份回退后的 lock
**不应提交**——它的 `dart` 下限与 HEAD 的 `flutter: ">=3.44.0"` 记录来自不同 SDK。
本轮把它**留在工作区未提交**，正式提交前需用发版 SDK 重新 `pub get` 并核对 diff。

### 6.7 iOS / macOS / Linux：本机为什么出不了包

- **iOS**：不是"代码没写好"，是**这台机器上没有能编它的工具链**——需要 macOS + Xcode +
  `pod install`（§1 表格）与签名证书，Windows 一律做不到。仓库侧其实是**齐的**：
  `git ls-files ios` 有 42 个文件，含 `ios/Podfile`、`ios/Runner/AppDelegate.swift` 与
  `Runner.xcodeproj`。另外 iOS **不走 Gopeed 引擎**：[lib/core/gopeed/gopeed_boot.dart:104-106](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L104-L106)
  在 iOS 上直接进 `_startIos()`（同文件 112 行的小节标题写明是
  "iOS：URLSession 原生后台下载"），因此 iOS **不需要** `libgopeed.aar`/`gopeed.exe`
  这类引擎产物；§1 表格里"最低 iOS 15"本轮**未复核**。
- **macOS / Linux**：仓库里**没有** `macos/`、`linux/` 平台目录
  （`git ls-files macos linux` 返回 0 个文件），不是"构建失败"而是"根本没有可构建的 target"。
  而且 [lib/core/gopeed/gopeed_boot.dart:108](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L108)
  对其它平台直接抛 `UnsupportedError('当前平台暂不支持下载引擎')`。要出这两个平台的包，
  先要 `flutter create --platforms=macos,linux .` 生成 runner、再补 macOS/Linux 的引擎启动实现，
  并重新走一遍加固评审（§1.3 的引擎查找目录、M5 的进程清理逻辑都是 Windows/Android 专有实现）。

### 6.8 勘误表（本轮实测自我更正）

| 编号 | 原说法 | 正确说法 | 出处 |
|---|---|---|---|
| B-1 | 「装最新 stable Flutter（3.50.0）即可出包」 | 本仓库只能用 **Flutter 3.44.x**。3.50 的 `DependencyVersionChecker` 要求 Gradle ≥ 9.3.1、AGP ≥ 9.1.1、KGP ≥ 2.4.10，仓库固定的是 8.14 / 8.13.2 / 2.3.20；加 `--android-skip-build-dependency-validation` 绕过校验后，`android/build.gradle.kts:19` 又因 `ApplicationExtension.getDefaultConfig()` 被移除而 `NoSuchMethodError` | Flutter 3.50 SDK 源码 `packages/flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt:94-111`；仓库侧 [android/gradle/wrapper/gradle-wrapper.properties:5](file:///D:/qorder/quarklite/android/gradle/wrapper/gradle-wrapper.properties#L5)、[android/settings.gradle.kts:22-23](file:///D:/qorder/quarklite/android/settings.gradle.kts#L22-L23)。**原说法来源**：§5 第一轮只跑静态检查，未验证过出包 |
| B-2 | 「JDK 必须是 17」 | 17 是 source/target 兼容级别，JDK 21 实测可直接出包 | [android/app/build.gradle.kts](file:///D:/qorder/quarklite/android/app/build.gradle.kts) 的 `compileOptions { sourceCompatibility = JavaVersion.VERSION_17 }`；实测产物见 §6.3 |
| B-3 | 「`go install golang.org/x/mobile/cmd/gomobile@v0.9.1`」 | `x/mobile` **不发语义化 tag**，只能用伪版本；本机固定 `v0.0.0-20261011034528-197770444867`。脚本里 `GOMOBILE_VERSION` 传 tag 会解析失败 | `https://goproxy.cn/golang.org/x/mobile/@latest` 返回的唯一形态就是伪版本；[scripts/build_libgopeed.sh:56-61](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L56-L61) 目前给的示例 `v0.8.2` 因此不可用（已在 §7 待办里记下要改注释） |
| B-4 | 「Inno Setup 从 `files.jrsoftware.org/is/6/` 下载」 | 实测该目录下 `innosetup-6.7.3.exe` 返回 404 HTML（只剩 `.issig`），本机改从 GitHub `jrsoftware/issrc` 的 release 资产取安装程序。**"官方何时搬迁"未核实**，不要当成确定日期。另：仓库**自带**简体中文语言包 [scripts/languages/ChineseSimplified.isl](file:///D:/qorder/quarklite/scripts/languages/ChineseSimplified.isl)，[scripts/quarklite.iss:26](file:///D:/qorder/quarklite/scripts/quarklite.iss#L26) 用的是相对脚本目录的路径，**不需要**再去 `jrsoftware.org/files/istrans/` 下载 | 实测 404；该 isl 文件第 1 行自述 `Inno Setup version 6.5.0+`，即安装程序版本下限 |
| B-5 | 「Windows 构建只要 VS2022 C++ 负载」 | 还必须 ① 装 **VC.ATL** 组件，② 开**开发者模式**，否则分别报 `C1083 atlbase.h` 和插件符号链接创建失败 | 实测两轮失败日志；修正已写进 §1 表格 |
| B-6 | 「`logger.warn` 的 debug 签名告警能看到」 | `flutter build apk --release` 路径下该告警**被吞**（stdout 里 0 次出现），只在直接调 `gradlew` 时可见 → 现有"显式告警"的加固在 Flutter CLI 下不成立，需要 §1.2 的严格开关或构建后校验签名者 | 本机 `flutter build` 日志 `grep -c Quarklite` = 0，`gradlew :app:tasks` 日志第 16 行有该文案；对照 [android/app/build.gradle.kts:62-65](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L62-L65) |
| B-7 | 「Windows 版不含 `gopeed.exe`，需用户自行放置」 | `windows/runner/CMakeLists.txt:43-50` **会**在 `windows/resources/gopeed.exe` 存在时把它拷进产物目录；用户无需手动放置，但**需要构建方先编出引擎** | [windows/runner/CMakeLists.txt:43-50](file:///D:/qorder/quarklite/windows/runner/CMakeLists.txt#L43-L50)；实测产物目录含 `gopeed.exe`。同一处误述还散落在 [architecture.md](architecture.md) §7 第 2 条与 [hardening-changelog.md](hardening-changelog.md) §2.3.4 |
| B-8 | 「`MSYS_NO_PATHCONV` 无关紧要」 | 在 Git Bash 下 `ISCC /DAppVersion=1.3.3` 会被 MSYS 当成路径转换，ISCC 报 `You may not specify more than one script filename`；必须 `MSYS_NO_PATHCONV=1` | 实测 `ISCC` 报错文案 |
| B-9 | 「Windows runner 的 CMake 是标准模板、不用改」 | 打包引擎的 `GOPEED_BIN` 判断在 **[windows/runner/CMakeLists.txt](file:///D:/qorder/quarklite/windows/runner/CMakeLists.txt)**（`CMAKE_CURRENT_LIST_DIR` = `windows/runner`），**不在** [windows/CMakeLists.txt](file:///D:/qorder/quarklite/windows/CMakeLists.txt)。本轮之前的文档把两处混为一谈，说成"`windows/CMakeLists.txt` 不打包它"，因而得出"CMake 完全不打包引擎"的错误结论 | 见上方 B-7 的引用；本轮 §1.3 与 [architecture.md](architecture.md) §7 已按 runner 文件改写，**但未逐字给出行号**（文档编辑会移动行号，宁可不写也不写错） |
| B-10 | 「本仓库的 CI 能出包」 | CI **一次都没跑过**，所以这句话在本轮之前和之后都还是推测；本轮连本地都发现"fresh clone 缺 wrapper"（§6.3 坑 1）这种会让 CI 直接失败的问题 | [.github/workflows/build.yml](file:///D:/qorder/quarklite/.github/workflows/build.yml)（同样**故意不给行号**：该文件本轮未复核内容，行号无法保证准确） |

### 6.9 本轮**未**验证的项（不要当成已确认）

1. **Android 包没有在真机/模拟器上安装运行**——`adb devices` 无设备，只做了
   `apksigner verify` 与 `aapt2 dump badging` 的静态核对。
   → **本条已被 2026-11-21 第三轮推翻**（模拟器实跑，且当场暴露 2 个只有运行时才现形的缺陷），
   见 §6.10 与 [hardening-changelog.md](hardening-changelog.md) §9.2。原文按只增不改保留。
2. **Windows 应用只验证到"进程起、引擎起"**，UI 交互、登录、下载任务全流程**未点验**。
3. **CI 从未跑过**：§3 的 Secrets/Variables 未配置，GitHub Actions 的
   `build-android` / `publish-release` 是否真能成功属推断。
4. **`scripts/build_libgopeed.sh` 未整段跑通**（本机 CRL 问题，见 §6.2 注意）。
5. `gopeed.exe` 用占位 `cmd/web/dist` 编译，**内嵌 Web 控制台不可用**；
   若哪天有代码依赖 `/ui/` 静态页，会 404。
6. 本轮所有产物均为 **debug 签名**，不可对外发布（§6.3 坑 2）。
7. 上游 Gopeed 源码是用 `git -c http.sslVerify=false` 克隆的（同一 CRL 问题），
   **未经证书链确认**；commit `a5cd53f9…` 只保证与 tag `v1.9.3` 当时的 HEAD 一致。

---

### 6.10 第三轮：Android 包在模拟器上真跑（2026-11-21）

§6.9 第 1 条"没有在真机/模拟器上安装运行"到这一轮才兑现。做法固化成脚本
[scripts/test_apk_emulator.sh](file:///D:/qorder/quarklite/scripts/test_apk_emulator.sh)，
它自己会：查硬件加速 → 缺 AVD 就按固定参数创建 → 复用已在跑的模拟器 →
安装 → `force-stop` 后冷启动 → 清空 logcat → 等 25 秒 → 六条断言 → 截图。

**环境（本机实测，不是推荐配置）**

| 项 | 值 |
|---|---|
| AVD | `quark_api36` = `pixel_6` + `system-images;android-36;google_apis;x86_64`（rev 7） |
| 启动参数 | `-no-snapshot -no-audio -no-boot-anim -gpu auto`（**不要加 `-screen size=…`**，`-screen` 只接受 `touch`/`multi-touch`/`no-touch`，写尺寸会直接拒绝启动） |
| 加速 | `emulator -accel-check` → `WHPX(10.0.26300) is installed and usable`。注意 `Get-CimInstance Win32_ComputerSystem` 同时报 `VirtualizationFirmwareEnabled=False`、`SLAT=False`、`HypervisorPresent=True`——WHPX 在 Hyper-V/VBS 开着的时候本来就能用，**别拿那两个 False 判定"没加速"** |
| 系统 | Android 16（API 36）x86_64，`google_apis` 镜像（非 AOSP 纯净镜像） |
| 工具 | `sdkmanager` 直连 dl.google.com 可用；`avdmanager`/`emulator` 在 Windows 只有 `.bat`/`.exe`，脚本用 `resolve_tool()` 三种后缀都试 |

**三次运行的因果链（这是本节真正的价值）**

| 序 | 安装包的 SHA-256（前 8 位） | 大小（B） | 结果 |
|---|---|---|---|
| 起点 | `86b687ae`（§6.3 那个包，= 已提交代码） | 74,880,245 | 引擎起来了，但**每个 REST 调用 401**；另有 1 次 `Unhandled Exception: Null check operator used on a null value` |
| 修复 1 | 未单独记录哈希 | 74,879,941 | 鉴权头改 `X-Api-Token` → **401 消失**；崩溃仍在（`Overlay.of` ← `MiuixOverlayPanel.show`，`lib/widgets/miuix_common.dart:52`） |
| 修复 2 | `86d08794` | 74,880,009 | 更新检查发起点移到 `RootPage.initState` → 六条断言全 PASS，**截图里弹窗正常渲染**（"发现新版本 1.3.3 / 当前版本 1.3.2"） |
| 修复 3 | `a8aecdd7` | 74,880,161 | `currentVersion` 对齐 pubspec → 全 PASS 且**不再误弹升级提示** |

**六条断言**（脚本里的原话，全部为 `PASS`/`FAIL` 二值，可退出码判定）：
进程存活、`libgojni.so` 加载成功（证明 AAR 与 x86_64 ABI 匹配）、无 401、
无 `Unhandled Exception`、无 `FATAL EXCEPTION`/native signal、截图非空。

**踩过的坑与噪声**

1. 首轮那次崩溃**不是点击触发的**：`am start` 之后零交互、11 秒后自己炸。
   排查时先怀疑 UI 路径会浪费时间，正确入口是"启动后自动跑的那条链路"
   （这里是 `UpdateChecker.checkAndPrompt`）。
2. 截图里那个 **"System UI isn't responding"** 弹窗是模拟器镜像自带的 SystemUI ANR，
   与本应用无关；`adb logcat` 里它也不带本应用包名。别把它记成产品缺陷。
3. `build_all.sh --apk-only` 出的是 `build/app/outputs/flutter-apk/app-release.apk`，
   不是 `build/app/outputs/apk/release/`（后者是纯 Gradle 路径）；测试脚本按三个候选路径找。
4. 上一轮那 5 个 ABI 分包（§6.3）**本轮没重装**，只测了合包 x86_64 一条路径；
   arm64/v7a 在模拟器上未经运行。

**产物状态（重要：§6.3 / §6.5 的哈希表是第二轮的，含 401 缺陷）**

| 产物 | 第二轮 SHA-256（§6.3/§6.5） | 第三轮重打后 | 结论 |
|---|---|---|---|
| 合包 APK | `86b687ae…` | `a8aecdd76a6f710867ca625364f1b4cec082ad32d439d98f3bafa5e1b38ca4d4`（74,880,161 B） | 旧包**不要发**，下载功能全废 |
| `app-arm64-v8a` / `v7a` / `x86_64` 三个分包 | `ffa76414…` / `b99914e1…` / `8b24229f…` | **本轮没有重打**（用了 `--no-split`） | 三个分包仍是**带 401 的旧代码** |
| `app-release.aab` | `4cbf11ef…` | 本轮没有重打 | 同上，仍是旧代码 |
| Windows 安装包 | `f9dd8ecc…`（23,174,584 B） | `aa31003b3562f9870ea0a6908cb1d10a20d6df2f9881b5edfcdb2a69982cfb6e`（23,174,609 B） | 已含修复（`data/app.so` 重编译于本轮） |
| `libgopeed.aar` / `gopeed.exe` | `f2f52bef…` / `ef6d89c5…` | 未重编（`--skip-engine`） | 引擎侧本来就没错，哈希不变 |

`bash scripts/build_all.sh` 不带 `--no-split`/`--skip-engine` 会把 6 个产物全部重打，
届时 §6.3/§6.5 的表要整表换新——**别只改 APK 那一行**。

**本节仍未覆盖**：任何网盘登录、任何真实下载落盘、前台服务与通知（API 33+ 的
`POST_NOTIFICATIONS` 弹窗）、`google_apis` 之外的镜像、真机。
产品侧结论见 [hardening-changelog.md](hardening-changelog.md) §9。

---

## 7. 本轮暴露的构建侧待办（按优先级）

1. **`.gitignore` 没有覆盖引擎产物**：`android/app/libs/libgopeed.aar`、
   `libgopeed-sources.jar`、`windows/resources/`、`android/build/` 现在是**未跟踪且不忽略**
   状态，一次 `git add -A` 就会把 68 MB 的 AAR 和 43 MB 的 exe 提交进仓库。
   要么显式忽略，要么改走 release 资产分发，**不能保持现状**。
2. **签名降级在 Flutter CLI 下无声**（§6.3 坑 2）：发版脚本应固定带
   `-Pquarklite.requireReleaseSigning=true`，并在构建后加一步
   `apksigner verify --print-certs` 断言签名者不是 `CN=Android Debug`。
3. **fresh clone 出不了 Android 包**（§6.3 坑 1）：wrapper 三件套被 ignore，
   需要在 README/CI 里明确"先 `gradle wrapper --gradle-version 8.14`"这一步，
   或把 wrapper 纳入版本控制。
4. **[scripts/build_libgopeed.sh:56-61](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L56-L61) 的注释口径要改**：
   `GOMOBILE_VERSION` 的示例值应写成伪版本（x/mobile 不发 tag，见 §6.8 B-3）。
5. **`pubspec.lock` 的提交决策**（§6.6）：要么统一用 Flutter 3.44.x 作发版 SDK 并重写 lock，
   要么在 CI 里钉死 SDK 版本；现在是"本地一 pub get 就产生 7 处 diff"的状态。
6. **Windows 安装包无自动化**：`scripts/quarklite.iss` 的 `AppVersion` 默认还是 `"1.3.0"`
   （[scripts/quarklite.iss:2-3](file:///D:/qorder/quarklite/scripts/quarklite.iss#L2-L3)），
   与 [pubspec.yaml:5](file:///D:/qorder/quarklite/pubspec.yaml#L5) 的 `1.3.3+1` 不同步，
   忘记传 `/DAppVersion` 就会打出**版本号写错**的安装包，且不报错。
7. **CI 从未实跑**（§6.9 第 3 条）：建议先加 `flutter analyze` + `flutter test` +
   `dart run tool/guard_selfcheck.dart` 三步，再谈出包 job。
8. **iOS/macOS/Linux**（§6.7）：前两者要么放弃、要么补平台目录与 CI runner；
   这属于产品决策，不是构建配置问题。

### 7.1 第三轮（2026-11-21）对上述待办的状态更新

- 第 2 条（签名降级无声）**已由 [scripts/build_all.sh](file:///D:/qorder/quarklite/scripts/build_all.sh)
  落地**：构建后跑 `apksigner verify --print-certs`，解析 `Signer #1 certificate DN:`，
  见到 `CN=Android Debug` 就告警；`--require-release-signing` 时直接失败退出。
  绕开 `-P` 传不进 `flutter build` 的办法是把
  `quarklite.requireReleaseSigning=true` 写进脚本自带的 `GRADLE_USER_HOME/gradle.properties`。
- 第 3 条（fresh clone 没有 wrapper）**已由同一脚本处理**：缺 `gradlew`/wrapper jar 时
  用本机 `gradle wrapper --gradle-version 8.14`（可配 `--cn-mirror` 换成腾讯分发地址）
  生成后**再还原仓库自带的 `gradle-wrapper.properties`**，不留副作用。
- 第 6 条（`quarklite.iss` 的 `AppVersion` 默认 1.3.0）现在有了同类兄弟：
  `UpdateChecker.currentVersion` 也是手写常量，且已经真的漂移过（§6.10 修复 3）。
  **两条一起记成同一个待办**：版本号应当只有一个来源。可选做法——
  (a) 构建时用 `--dart-define=QUARKLITE_VERSION=$VER_NAME` 注入，代码里
  `String.fromEnvironment` 读，`build_all.sh` 与 CI 都从 `pubspec.yaml` 取；
  (b) 引 `package_info_plus` 直接读包元数据（多一个插件依赖与平台实现）。
  当前只加了断言型护栏 [test/update_checker_version_test.dart](file:///D:/qorder/quarklite/test/update_checker_version_test.dart)，
  它能在漂移时让 `flutter test` 失败，但**不会自动同步**，改版本仍要人改两处。
- 新增待办：**`lib/utils/window_close.dart:67` 的 `navigatorKey.currentContext` 与已修的
  启动崩溃是同一个缺陷类**，Windows"关闭时询问"会走到它，本机无法自动化验证；
  详见 [architecture.md](architecture.md) §7 第 5 条。
- 新增待办：**模拟器只覆盖了合包 x86_64 一条 ABI**，arm64-v8a / armeabi-v7a 分包
  与真机（尤其 MIUI/华为这类前台服务与省电策略）仍未跑过；
  `scripts/test_apk_emulator.sh` 换 `--apk` 指到分包即可复用，但需要 arm64 镜像或真机。
