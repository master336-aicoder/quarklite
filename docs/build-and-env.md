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
| Windows | Visual Studio 2022（C++ 桌面负载）+ CMake（Flutter 自带） | `windows/` 为 Flutter 标准 C++ runner |

依赖解析需要联网（pub.dev、Maven Central、GitHub）。项目没有配置私有镜像。

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

Windows 版**不含内置的 `gopeed.exe`**：`windows/CMakeLists.txt` 不打包它，
运行时会按两个受控位置查找（主程序同级目录、应用文档目录），
找不到就报"未找到 gopeed.exe，请确认程序目录完整"
（[lib/core/gopeed/gopeed_boot.dart:300-311](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L300-L311)、
[lib/core/gopeed/gopeed_boot.dart:192-196](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L192-L196)）。

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

本次加固交付**未执行**以上任何命令：本机既无 Flutter/Dart 工具链，
Dart SDK 下载也未完成，且仓库代码全程未被运行。
已执行的检查与其局限见 [hardening-changelog.md](hardening-changelog.md) §5。
