# Quarklite 运维与发布手册

本文是 [.github/workflows/build.yml](file:///D:/qorder/quarklite/.github/workflows/build.yml)
与 [android/app/build.gradle.kts](file:///D:/qorder/quarklite/android/app/build.gradle.kts)
里多处注释指向的"operations.md"。覆盖：发布签名材料配置、发版流程、回滚、
故障排查、日志取证、事件响应。

---

## 1. 一次性初始化（新仓库 / 新维护者）

### 1.1 配置 4 个 Secrets

CI **不再**自己生成 keystore，也不再内置口令。签名材料必须来自仓库 Secrets：

| Secret | 值 | 说明 |
|---|---|---|
| `QUARKLITE_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` | 整个 keystore 的二进制 |
| `QUARKLITE_KEYSTORE_PASSWORD` | keystore 口令 | |
| `QUARKLITE_KEY_ALIAS` | 密钥别名（历史值 `quarklite`） | |
| `QUARKLITE_KEY_PASSWORD` | 私钥口令 | |

生成新材料（**首次**或密钥泄露后）：

```bash
keytool -genkeypair -v -keystore upload-keystore.jks \
  -alias quarklite -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Quarklite, OU=Dev, O=Quarklite, L=Beijing, S=Beijing, C=CN"
base64 -w0 upload-keystore.jks        # 结果贴进 QUARKLITE_KEYSTORE_BASE64
```

离线保存 `upload-keystore.jks` 与两条口令（密码管理器 + 一份纸质/离线备份）。
**丢失 keystore = 之后所有版本都无法覆盖安装**，只能当新应用分发。

加固原因（写进 workflow 注释，见
[.github/workflows/build.yml:60-62](file:///D:/qorder/quarklite/.github/workflows/build.yml#L60-L62)）：
原方案把口令 `quarklite2026` 明文写在公开 workflow 里，并用 `keytool` 现场生成 +
`actions/cache` 保活 keystore。任何能读到该仓库的人都能产出**同签名**的 APK，
签名不再具备来源辨识度；缓存被污染或过期还会静默切回 debug 签名。

任一 Secret 缺失都会在早期失败并点名缺哪个：
[.github/workflows/build.yml:63-81](file:///D:/qorder/quarklite/.github/workflows/build.yml#L63-L81)。
恢复 keystore 后立刻用 `keytool -list` 自检口令与别名可用，
避免到 Gradle 阶段才报模糊错误：
[.github/workflows/build.yml:99-103](file:///D:/qorder/quarklite/.github/workflows/build.yml#L99-L103)。

### 1.2 配置 3 个 Variables

| Variable | 值 | 缺失后果 |
|---|---|---|
| `GOPEED_VERSION` | 引擎 tag，如 `v1.9.3` | 用脚本默认值 |
| `GOPEED_COMMIT` | 该 tag 的完整 commit SHA | CI 打告警后**继续构建**（不阻断） |
| `GOMOBILE_VERSION` | 如 `v0.8.2` | 退回 `@latest`，两次构建可能不一致 |

查 commit：`git ls-remote https://github.com/GopeedLab/gopeed.git refs/tags/v1.9.3`。
`GOPEED_COMMIT` 与源码实际 HEAD 不符时脚本 `exit 1`（tag 被移动或缓存串味）：
[scripts/build_libgopeed.sh:41-51](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L41-L51)。

### 1.3 job 权限

| Job | 权限 | 位置 |
|---|---|---|
| `build-android` | `contents: read` | [.github/workflows/build.yml:15-18](file:///D:/qorder/quarklite/.github/workflows/build.yml#L15-L18) |
| `publish-release` | `contents: write` | [.github/workflows/build.yml:177-181](file:///D:/qorder/quarklite/.github/workflows/build.yml#L177-L181) |
| `diag` | `contents: read` | [.github/workflows/diag-gopeed.yml](file:///D:/qorder/quarklite/.github/workflows/diag-gopeed.yml) |

显式声明后，**未点名的权限一律为 none**（GitHub 官方语义）。

---

## 2. 发版流程

1. 改 `pubspec.yaml` 的 `version: X.Y.Z+N`（tag 与产物名都由它推导，
   [.github/workflows/build.yml:23-30](file:///D:/qorder/quarklite/.github/workflows/build.yml#L23-L30)、
   [:174-175](file:///D:/qorder/quarklite/.github/workflows/build.yml#L196-L197)）。
2. 本地 `flutter pub get`；若 `git diff pubspec.lock` 非空，把 lock 一起提交，
   否则 CI 的 lock 一致性检查会失败
   （[.github/workflows/build.yml:105-116](file:///D:/qorder/quarklite/.github/workflows/build.yml#L105-L116)）。
3. 推到 `main`（或手动 `workflow_dispatch`）。`concurrency` 会取消同 ref 上的旧 run
   （[.github/workflows/build.yml:8-10](file:///D:/qorder/quarklite/.github/workflows/build.yml#L8-L10)）。
4. 观察三个关键断言：Secrets 齐全 → keystore 可打开 → **APK 非 debug 签名**。
5. `publish-release` 自动发 GitHub Release；已存在同名 tag 时用 `--clobber` 补传产物
   （[.github/workflows/build.yml:200-209](file:///D:/qorder/quarklite/.github/workflows/build.yml#L200-L209)）。

### 2.1 发版后必做：记录签名指纹

CI 会打印 APK 证书指纹（[.github/workflows/build.yml:130-164](file:///D:/qorder/quarklite/.github/workflows/build.yml#L130-L164)），
把它抄进该 Release 的说明。**下一个版本比对同一指纹**，是发现签名材料被换掉的唯一手段
——CI 只保证"不是 debug"，保证不了"和上个版本同一个签名者"。

本地复核（不需要源码）：

```bash
$ANDROID_HOME/build-tools/<ver>/apksigner verify --print-certs app-release.apk
```

> 为什么优先 `apksigner` 而不是 `keytool -printcert -jarfile`：后者只能读 v1(JAR) 签名，
> minSdk 24+ 的包默认不再生成 v1 块，那种情况它**没有任何输出**，
> 会让"不是 debug 签名"的判断静默走空。CI 已按 apksigner 优先、
> keytool 兜底并显式告警实现（[.github/workflows/build.yml:130-149](file:///D:/qorder/quarklite/.github/workflows/build.yml#L130-L149)）。

### 2.2 加固项一览（CI 侧）

| 断言 | 失败条件 | 位置 |
|---|---|---|
| Secrets 存在性 | 任一签名字段为空 | `:63-81` |
| keystore 可用性 | `keytool -list` 打不开或别名不存在 | `:99-103` |
| lockfile 一致性 | `flutter pub get` 后 `pubspec.lock` 有 diff | `:105-116` |
| 严格签名 | 缺 `key.properties` 且启用了 `quarklite.requireReleaseSigning` | [android/app/build.gradle.kts:55-61](file:///D:/qorder/quarklite/android/app/build.gradle.kts#L55-L61) |
| 产物签名 | 读不到签名信息，或签名者是 `CN=Android Debug` | `:130-163` |
| 引擎源码 | `GOPEED_COMMIT` 与实际 HEAD 不符 | `scripts/build_libgopeed.sh:41-51` |
| 诊断产物 | `gopeed_sha256` 传入且不匹配 | `.github/workflows/diag-gopeed.yml` 校验步骤 |

---

## 3. 回滚与签名轮换

**回滚（推荐）**：不动代码，直接在 GitHub Release 里重新分发上一版 APK，
并停止后续 push。用户侧覆盖安装即可，因为签名未变。

**代码回滚**：`git revert` 加固提交后重新构建。注意 CI 的严格签名已生效，
回滚到"自动生成 keystore"的旧 workflow 会让签名**换掉**——老用户将不能覆盖安装。
所以不要回滚 workflow 文件，只回滚业务代码。

**签名轮换（仅在 keystore 泄露或丢失时）**：

1. 立即把新版本号提高一个 minor，避免与旧包同号；
2. 在 README/Release 里明示"需要卸载重装，或走全新安装"；
3. 更新 4 个 Secrets；
4. 旧 Release 下架，防止用户装到与新版无法互相覆盖的包。

轮换是**用户可感知**的破坏性操作：Android 按签名判定同包名应用的覆盖安装。

---

## 4. 故障排查

### 4.1 先取日志

应用内：**我的 → 日志 → 复制**（[lib/pages/me/me_page.dart:360](file:///D:/qorder/quarklite/lib/pages/me/me_page.dart#L360)、
[:388](file:///D:/qorder/quarklite/lib/pages/me/me_page.dart#L388)）。
文件在 `<文档目录>/quarklite/logs/app.log`，超过 1MB 时截断保留尾部 512KB
（[lib/utils/app_logger.dart:11-13](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L11-L13)、
[:26-30](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L26-L30)）。
日志内容已在唯一出口脱敏（[lib/utils/app_logger.dart:44-46](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L44-L46)），
可以直接发给外部协助排查。

引擎标签：`engine`；凭据：`cred`；下载：`download`；鉴权：`auth`。

### 4.2 下载引擎起不来（Windows）

| 现象 / 日志 | 原因 | 处理 |
|---|---|---|
| `未找到 gopeed.exe，请确认程序目录完整` | 引擎没放在受控目录 | 把 `gopeed.exe` 放到主程序同级目录或应用文档目录（[lib/core/gopeed/gopeed_boot.dart:300-309](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L300-L309)）。**放 PATH 里没用**，裸名查找已移除 |
| `引擎启动后立即退出` | 杀软拦截 / 缺 VC 运行库 | 加白名单；300ms 存活探测见 [lib/core/gopeed/gopeed_boot.dart:215-225](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L215-L225) |
| `引擎连续快速退出 5 次，暂停自动重启` | 持续被拦截 | 停止重启以防灾难循环，等周期轮询（[lib/core/gopeed/gopeed_boot.dart:246-259](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L246-L259)） |
| `引擎未正常启动: …` 且无端口 | stdout 未出现监听地址 | Gopeed 打印 `Server start success on http://127.0.0.1:<port>`，解析见 [lib/core/gopeed/gopeed_boot.dart:312-358](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L312-L358) |
| 任务列表空/历史丢失 | 第 2 次尝试会**删除** `gopeed` 存储目录 | bolt 数据库损坏时的自愈代价，见 [lib/core/gopeed/gopeed_boot.dart:278-286](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L278-L286) |
| 两个实例互相杀进程 | 多开 | 单实例锁已拦截（[lib/main.dart:19-22](file:///D:/qorder/quarklite/lib/main.dart#L19-L22)） |
| 401 / 未授权 | 引擎带 token 而起，客户端没带 | 同一次会话的随机 token 同时喂给 `-T` 和 `Authorization: Bearer`（[lib/core/gopeed/gopeed_boot.dart:210](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L210)、[lib/core/gopeed/gopeed_client.dart:14-20](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_client.dart#L14-L20)），重启应用即可重建 |

> bolt 只允许单进程持有数据库文件锁（官方 README："Bolt obtains a file lock on the
> data file so multiple processes cannot open the same database at the same time"），
> 这就是启动前必须清残留实例的根因
> （[lib/core/gopeed/gopeed_boot.dart:74-78](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L74-L78)）。

### 4.3 下载被拦截（提示"下载被拦截: …"）

这是**预期行为**，不是 bug。原因串与含义：

| 提示 | 触发条件 | 位置 |
|---|---|---|
| `下载地址指向内网/元数据地址，已拦截` | 目标解析到回环/私网/链路本地/CGNAT | [lib/utils/net_guard.dart:104](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L104) |
| `下载地址必须是 http/https 绝对地址` | 非 http(s)、缺协议或缺主机 | [lib/utils/net_guard.dart:103](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L103) |
| `未声明凭据投递范围，拒绝附带凭据` | 调用方传了 `NetScope.none` 却带 cookie | [lib/utils/net_guard.dart:101](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L101) |
| `仅支持 magnet: 或 btth: 链接` | 磁力输入框里粘了 http 地址 | [lib/state/download_service.dart:147](file:///D:/qorder/quarklite/lib/state/download_service.dart#L147) |
| `下载路径非法: …` | 目标路径含上级引用 | [lib/core/gopeed/gopeed_client.dart:48-49](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_client.dart#L48-L49) |

误拦的排查顺序：先在日志里找该行的 `name=`，确认原始 URL；
再确认它是否真是公网 CDN 直链。放宽规则必须走代码评审，**不要在 UI 层加旁路开关**——
一旦有旁路，这套校验对新增调用点就不再自动生效。

### 4.4 升级后掉登录 / 提示"系统安全存储不可用"

加固后不再从 SharedPreferences 读明文兜底，因此：

- 若某设备 Keystore 异常（官方 README 记录的场景之一是 Google Drive 自动备份导致
  `java.security.InvalidKeyException: Failed to unwrap key`），登录态无法恢复，
  需要**重新登录一次**
  （[lib/state/app_state.dart:90-96](file:///D:/qorder/quarklite/lib/state/app_state.dart#L90-L96)、
  [lib/core/credential_store.dart:38-48](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L38-L48)）。
- 属有意的取舍：宁可掉登录，也不把凭据退回明文可读文件。
- 首次升级会在日志留下 `已清除 N 项历史明文凭据`，是正常的迁移清理
  （[lib/core/credential_store.dart:88-90](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L88-L90)）。

### 4.5 迅雷验证页打不开 / 验证后仍失败

验证页靠向官方页面注入 `XLJSWebViewBridge` 交换 `creditkey`/`deviceid`。
加固后注入被限定在迅雷可信页面域
（[lib/pages/login/xunlei_review_page.dart:88-91](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart#L88-L91)）。
若官方把验证页迁到**新域名**，现象会是"页面能打开但验证一直不通过"——
处理是在 [lib/utils/net_guard.dart:34-38](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L34-L38)
的 `trustedPageSuffixes` 里补域，**不要**改成无条件注入。

### 4.6 123 下载报超额 / 要付费

- 应用不做客户端流量预判，超额由服务端错误码返回（设计说明
  [lib/api/netdisk123_client.dart:276-288](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L276-L288)）。
- 先看诊断页（**我的/123 → 诊断**，
  [lib/pages/drive/netdisk123_diag_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_diag_page.dart)），
  它直接调 `trafficCheck` 接口，不影响主链路。
- 收银台域名变更时同样只需补 `trustedPageSuffixes[NetScope.pan123]`；
  跳出到支付宝/微信是**允许**的，导航处理刻意不阻断跨域，只记录
  （[lib/pages/drive/netdisk123_pay_page.dart:32-40](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_pay_page.dart#L32-L40)）。

### 4.7 CI 失败速查

| 报错 | 处理 |
|---|---|
| `缺少 Secret：QUARKLITE_*` | 见 §1.1 |
| `pubspec.lock 与 pubspec.yaml 不一致` | 本地 `flutter pub get` 后提交 lock |
| `release 构建缺少 android/key.properties` | 上一项失败连带；检查 Secrets 或本地加 `--debug` |
| `产物使用了 debug 签名` | Secrets 恢复了但没生效，检查 `key.properties` 写入步骤 |
| `无法读取 APK 签名信息` | runner 上 build-tools 缺失，或 APK 完全没有签名块——**必须人工确认**，不要直接放行 |
| `源码 commit 与 GOPEED_COMMIT 期望值不符` | 更新 Variable，或确认 tag 被上游移动（后者要查上游是否被劫持） |

---

## 5. 事件响应

| 场景 | 立即动作 |
|---|---|
| keystore 或口令泄露（含历史上明文写死在 workflow 的 `quarklite2026`） | 按 §3 轮换；把旧口令视为公开；审计该仓库的 Actions 访问 |
| `GOPEED_COMMIT` 校验失败且确认 tag 被移动 | 停止发版，改用具体 commit 重新设值；核对 AAR SHA-256 与上一次发布 |
| 用户报告凭据被盗（cookie 在他人设备上生效） | 指导其在官方侧改密/踢会话；确认用户是否开着云备份或做过 `adb backup` |
| 下载直链被大批量拦截 | 先确认不是 CDN 迁到内网段（不可能）或被中间设备改写；查 `download` 标签日志 |
| 日志泄露凭据 | 检查 [lib/utils/app_logger.dart:95-130](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L95-L130) 的 `LogRedact` 字段表是否漏了新的键名，补正则而不是删日志 |

---

## 6. 未覆盖的运维护栏（明确缺口）

1. 没有依赖漏洞扫描（`pnpm audit` 类的 pub 等价物未接入 CI）。
2. Actions 仍按**版本 tag**引用（`actions/checkout@v4` 等），未固定到 commit SHA。
   官方加固指南建议 pin 到 SHA；本次未做是因为无法离线核对各 action 的当前 SHA，
   填错会直接打断构建。见 [security-design.md](security-design.md) §5 待办。
3. `upload-artifact` / `download-artifact` 仍是 v4，官方最新版为 v7.0.2（2026-11 核对），
   升级留待一次专门改动验证，未混进加固提交。
4. 安全断言**已经写好，但流水线一个都不跑**：`build.yml` 里只有 §2.10 那条锁文件断言，
   既没有 `flutter analyze` 也没有 `flutter test`。目前两套用例都靠人工执行：
   - [tool/guard_selfcheck.dart](file:///D:/qorder/quarklite/tool/guard_selfcheck.dart)：**69 条**纯 Dart 断言（实跑计数，早期文档写的 75 是调用点估算），覆盖 §4.3 的内网/别名判定与文件名净化。改 `net_guard.dart` / `path_guard.dart` 后必须 `dart run tool/guard_selfcheck.dart` 重跑（只要 Dart SDK，不需要 Flutter）。
   - [test/log_redact_test.dart](file:///D:/qorder/quarklite/test/log_redact_test.dart)：9 条 `flutter test` 用例，盯日志脱敏真的生效。2026-11-13 的实跑就是靠它和全量 analyze 抓到 3 个加固自身缺陷（[hardening-changelog.md §5.5](hardening-changelog.md)）。
   接进 CI 的建议姿势与两个坑（`--fatal-infos` 默认 on；`dart format --set-exit-if-changed` 基线就红）见本节末尾与 [hardening-changelog.md §5.4](hardening-changelog.md)。
   依赖引擎与网络栈的拦截（明文 HTTP 被拒、无 token 401、日志真的落盘脱敏）仍只能人工验证。
5. iOS 未接入 CI 构建（workflow 名即 `Build Android`）。
