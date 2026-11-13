# 加固变更对照（Hardening Changelog）

本文逐条记录本次安全加固相对上游代码的改动：每条给出「加固前证据 → 风险 → 加固后落点 → 兼容性影响 → 回滚方式」。

- **加固前**一律指 `HEAD = 5ba21acb7dfbf7cc3ccf660b9ac59220aa3b8e98`（2026-10-17，即本次克隆下来的上游提交）的文件与行号，取自 `git show HEAD:<path>`。
- **加固后**一律指当前工作区的文件与行号。
- 风险编号（H1/H2/M1…）与威胁登记（R-01…R-18）的对应关系见 [security-design.md](security-design.md) §3。
- ⚠ 本文所有 Dart 改动**均未经过编译器或运行时验证**，原因见 §5.2。

---

## 1. 总览

| # | 风险 | 主题 | 落点（加固后） | 兼容性 |
|---|---|---|---|---|
| 1 | H1 | 凭据明文落盘 + 明文降级读 | [credential_store.dart](../lib/core/credential_store.dart)、三个 state 类 | 保留登录态，见 §2.1.4 |
| 2 | H2 | 本地引擎 API 无鉴权 | [gopeed_boot.dart:44-51](../lib/core/gopeed/gopeed_boot.dart#L44)、[gopeed_client.dart](../lib/core/gopeed/gopeed_client.dart) | 无 |
| 3 | M5 | `gopeed.exe` 裸名加载 + 按映像名全局强杀 | [gopeed_boot.dart:300-306](../lib/core/gopeed/gopeed_boot.dart#L300)、[同文件 374-423](../lib/core/gopeed/gopeed_boot.dart#L374) | 见 §2.3.4 |
| 4 | M1 | 凭据被投递到任意/内网主机（SSRF 相邻） | [net_guard.dart](../lib/utils/net_guard.dart)、[download_service.dart:33](../lib/state/download_service.dart#L33) | 可能拒绝内网自建源，见 §2.4.4 |
| 5 | M2 | 下载路径穿越 / 文件名注入 | [path_guard.dart](../lib/utils/path_guard.dart)、[gopeed_client.dart:48-50](../lib/core/gopeed/gopeed_client.dart#L48) | 超长名被截断 |
| 6 | M3 | WebView 无导航校验即注入凭据 bridge | [xunlei_review_page.dart:60-91](../lib/pages/login/xunlei_review_page.dart#L60)、[netdisk123_pay_page.dart:32-40](../lib/pages/drive/netdisk123_pay_page.dart#L32) | 迅雷风控域变更需改配置 |
| 7 | M4 | release 允许明文 HTTP | [AndroidManifest.xml:37](../android/app/src/main/AndroidManifest.xml#L37)、[network_security_config.xml](../android/app/src/main/res/xml/network_security_config.xml) | 明文源下载失败（预期） |
| 8 | L8 | 日志泄露 cookie/token/URL 签名 | [app_logger.dart:43-131](../lib/utils/app_logger.dart#L43) | 日志可读性下降 |
| 9 | H3 | CI 签名口令明文 + debug 签名静默兜底 + 断言失效 | [build.yml](../.github/workflows/build.yml)、[build.gradle.kts:47-66](../android/app/build.gradle.kts#L47) | **需要一次性配置 Secrets** |
| 10 | M6 | 引擎源码 tag 可漂移 / 共享 /tmp / 工具链 @latest | [build_libgopeed.sh](../scripts/build_libgopeed.sh) | 需设 `GOPEED_COMMIT` |
| 11 | R-16 | 缺 LICENSE（GPL-3.0 项目无授权文本） | [LICENSE](../LICENSE) | 无 |

改动规模（`git diff --stat` + 新增文件）：21 个已跟踪文件 +590/−227，另有 4 个新 Dart 文件、2 个新 Android XML 资源、`LICENSE`、以及本目录 6 篇文档。

---

## 2. 逐条对照

### 2.1 H1：凭据明文落盘

#### 2.1.1 夸克 cookie

| 加固前 | 加固后 |
|---|---|
| `app_state.dart:85-99` `_loadCookie()`：安全存储读失败 → `prefs.getString('quark_cookie_backup')` 明文回退 | [app_state.dart:90-96](../lib/state/app_state.dart#L90)：只读 `CredentialStore.I.read(_kCookie)`；不可用时打 `AppLogger.I.w('auth', ...)`（[92](../lib/state/app_state.dart#L92)），**不回退** |
| `app_state.dart:101-112`（注释原文「双写持久化」）：`_secure.write` 之后 `prefs.setString('quark_cookie_backup', cookie)` | [app_state.dart:99-105](../lib/state/app_state.dart#L99)：只写安全存储，写失败显式记 ERROR（[102](../lib/state/app_state.dart#L102)） |
| `app_state.dart:114-120` `_clearCookie` 各 try/catch 静默删除 | [app_state.dart:107-109](../lib/state/app_state.dart#L107)：`CredentialStore.I.delete` + `purgeLegacyPlaintext(legacyPlaintextKeys)` |

#### 2.1.2 迅雷 / 123 网盘

| 加固前 | 加固后 |
|---|---|
| `xunlei_state.dart:173-183` `_read`：安全存储异常后 `prefs.getString(key)` 明文回退 | [xunlei_state.dart:169](../lib/state/xunlei_state.dart#L169) `_read` 单行委托 `CredentialStore.I.read` |
| `xunlei_state.dart:185-194` `_write`：`_secure.write` + `prefs.setString(key, value)`（[191-192](../lib/state/xunlei_state.dart) 为 HEAD 行号） | [xunlei_state.dart:171-174](../lib/state/xunlei_state.dart#L171)：只写安全存储；保留上游 `value.isEmpty` 早退语义 |
| `xunlei_state.dart:127-135` logout 循环里双份删除 | [xunlei_state.dart:129-131](../lib/state/xunlei_state.dart#L129)：删除 + `purgeLegacyPlaintext` |
| `netdisk123_state.dart:46-48` 单账号键、`368-370` 把 token/username/password 复制进 3 个额外键、`389`+`393` 双写 | [netdisk123_state.dart:376-381](../lib/state/netdisk123_state.dart#L376) 统一走 `CredentialStore`；多账号只存 `_kAccounts` 一个 JSON 键；[368-374](../lib/state/netdisk123_state.dart#L368) `purgeCredentialDuplicates()` 清掉迁移残留与旧明文键 |

#### 2.1.3 新增集中点

[credential_store.dart](../lib/core/credential_store.dart)（101 行）：

- [30](../lib/core/credential_store.dart#L30) `AndroidOptions(encryptedSharedPreferences: true)` —— **与上游逐字一致**，不是本次引入。
- [35](../lib/core/credential_store.dart#L35) `secureAvailable`：把「安全存储是否可用」变成调用方可见状态，取代静默明文降级。
- [38](../lib/core/credential_store.dart#L38) `read` / [52](../lib/core/credential_store.dart#L52) `write`（`write(key, '')` 等价 delete）/ [65](../lib/core/credential_store.dart#L65) `delete`。
- [81-100](../lib/core/credential_store.dart#L81) `purgeLegacyPlaintext`：升级后一次性清理历史明文键，返回清理条数。

清理时机：[app.dart:70-92](../lib/app.dart#L70) `_restoreSecondaryAccountsAndPurge()` **先** `XunleiState.init()` / `Netdisk123State.init()`（这两步要从旧明文键迁移读取），**再** `purgeLegacyPlaintext([AppState, XunleiState, Netdisk123State] 的 legacyPlaintextKeys)` + `purgeCredentialDuplicates()`。若先清理后恢复，老用户会直接掉登录。

#### 2.1.4 兼容性（重要）

- `encryptedSharedPreferences: true` 不能改成 `false`：插件两种模式共用同一个 `FlutterSecureStorage` 文件名，改了这个开关，已安装设备的密文无法解出 → **全网掉登录**。该参数在插件 10.x 已弃用、11.0.0 移除，届时必须走插件自带的迁移开关（`migrateOnAlgorithmChange`），外部口径与出处见 [security-design.md](security-design.md) §4.1 及 P-2/P-3、勘误 E-2/E-3。
- 加固前写入的明文副本不会自己消失：只有升级后 `purgeLegacyPlaintext` 执行一次才会删掉。**在本次加固之前已经安装并使用过的设备，其 SharedPreferences 里的明文窗口期已经存在过**（遗留风险 X-9）。
- 个别 Keystore 异常设备（`Failed to unwrap key`）加固后会掉登录而不是降级读明文——这是有意的取舍（`security-design.md` §4.1）。

#### 2.1.5 回滚

`git checkout HEAD -- lib/state/app_state.dart lib/state/xunlei_state.dart lib/state/netdisk123_state.dart` 并删除 `lib/core/credential_store.dart`（注意 [app.dart:83-88](../lib/app.dart#L83) 会引用它，需同步还原 `app.dart`）。

---

### 2.2 H2：本地引擎 REST 无鉴权

| 项 | 加固前（HEAD） | 加固后 |
|---|---|---|
| token 来源 | 无 | [gopeed_boot.dart:44-51](../lib/core/gopeed/gopeed_boot.dart#L44)：进程内首次使用时 `Random.secure` 生成 32 字节、base64url 去填充 |
| Windows 启动参数 | `gopeed_boot.dart:194` `'-T', ''` | [gopeed_boot.dart:210](../lib/core/gopeed/gopeed_boot.dart#L210) `'-T', _token` |
| Windows client | `gopeed_boot.dart:214` `GopeedClient('http://127.0.0.1:$port')` | [gopeed_boot.dart:230](../lib/core/gopeed/gopeed_boot.dart#L230) `GopeedClient(..., apiToken: _token)` |
| Android cfg | `gopeed_boot.dart:121` `'apiToken': ''` | [gopeed_boot.dart:140](../lib/core/gopeed/gopeed_boot.dart#L140) `'apiToken': _token`；[157](../lib/core/gopeed/gopeed_boot.dart#L157) client 带 token |
| 请求侧 | `gopeed_client.dart` 无鉴权头 | [gopeed_client.dart](../lib/core/gopeed/gopeed_client.dart) 注入 `X-Api-Token` |

效果：Gopeed 侧 `ApiToken != ""` 才启用校验（外部口径 S-2），`''` 时整个鉴权分支被跳过 —— 加固前同机任意进程（甚至浏览器里一段 `fetch('http://127.0.0.1:<port>/tasks')`）都能枚举任务、创建任务、读到 `extra.header` 里的 cookie。现在无 token 一律 401。

**未验证项**：token 是否真的被引擎接受，依赖 Gopeed 版本的 `-T` / `X-Api-Token` 语义；本次没有启动过引擎（§5.2）。另外 token 通过命令行 `-T` 传递，同机用户可从进程列表读到（遗留风险 X-2）。

回滚：`git checkout HEAD -- lib/core/gopeed/gopeed_boot.dart lib/core/gopeed/gopeed_client.dart`。

---

### 2.3 M5：引擎二进制来源与进程清理

#### 2.3.1 exe 查找

加固前 `gopeed_boot.dart:288` 把裸名 `gopeed.exe` 列为候选，由当前工作目录与 `PATH` 解析；任何可写目录里放一个 `gopeed.exe` 即可被当作下载引擎拉起（并把 cookie header 交给它）。

加固后 [gopeed_boot.dart:300-310](../lib/core/gopeed/gopeed_boot.dart#L300) 只接受两个受控绝对路径：主程序同目录（`File(Platform.resolvedExecutable).parent.path`，[303](../lib/core/gopeed/gopeed_boot.dart#L303)）与应用私有文档目录（[305](../lib/core/gopeed/gopeed_boot.dart#L305)）。

#### 2.3.2 残留进程清理

加固前 `gopeed_boot.dart:354` `Process.run('taskkill', ['/IM','gopeed.exe','/F'])` 按映像名强杀，会连带杀掉**用户自己启动的 Gopeed 客户端**。

加固后 [gopeed_boot.dart:374-423](../lib/core/gopeed/gopeed_boot.dart#L374)：PowerShell `-EncodedCommand`（UTF-16LE base64，[392](../lib/core/gopeed/gopeed_boot.dart#L392)）枚举 `Win3_Process`，只对 `ExecutablePath` 以本次 exe 目录开头的实例 `Stop-Process`；目录经环境变量 `QUARKLITE_GOPEED_DIR` 传入（[397](../lib/core/gopeed/gopeed_boot.dart#L397)），不参与字符串拼接 → 无命令行注入面。PowerShell 不可用时才退回按名强杀并显式告警（[412-414](../lib/core/gopeed/gopeed_boot.dart#L412)）。

#### 2.3.3 启动并发与自愈

- [gopeed_boot.dart:78](../lib/core/gopeed/gopeed_boot.dart#L78) 起 `_startInFlight` 共享同一次启动，避免两条启动流程互相 kill 对方刚拉起的进程。
- 连续「启动后 10 秒内退出」计数（[247-258](../lib/core/gopeed/gopeed_boot.dart#L247)）达到 5 次则暂停自动重启，防止杀软持续拦截时无限重启。

#### 2.3.4 兼容性

`gopeed.exe` 不再从 `PATH` 查找：把引擎放在 PATH 目录（而非程序目录）的用户升级后会得到「未找到 gopeed.exe」（[191-196](../lib/core/gopeed/gopeed_boot.dart#L191) 抛错路径）。放置规则见 [build-and-env.md](build-and-env.md) §1.3。另外本仓库的 CMake 并没有打包 `gopeed.exe`（`architecture.md` §7），这条路径对纯 Android/iOS 用户无影响。

---

### 2.4 M1：出网目标校验

新增 [net_guard.dart](../lib/utils/net_guard.dart)（113 行）：

- [43](../lib/utils/net_guard.dart#L43) `parseHttp`：只放行 http/https 绝对 URL。
- [53](../lib/utils/net_guard.dart#L53) `isTorrentUri`：限制 BT/magnet 的 scheme 形状。
- [59-88](../lib/utils/net_guard.dart#L59) `isInternalHost`：环回、RFC1918、CGNAT `100.64/10`（[73](../lib/utils/net_guard.dart#L73)）、链路本地 `169.254/16` 与云 metadata（[70](../lib/utils/net_guard.dart#L70)）、IPv6 `::1` / `fe80::/10` / `fc00::/7`（[80-82](../lib/utils/net_guard.dart#L80)，`fc` 与 `fd` 两个前缀都覆盖 —— 早期只判 `fd` 漏了一半）、以及 IPv4-mapped `::ffff:`（[83](../lib/utils/net_guard.dart#L83)）。
- [93-99](../lib/utils/net_guard.dart#L93) `credentialRejection`、[102](../lib/utils/net_guard.dart#L102) `isTrustedPage` 配 [34-38](../lib/utils/net_guard.dart#L34) 的 `trustedPageSuffixes` 域表。

调用点：

| 位置 | 作用 |
|---|---|
| [download_service.dart:33](../lib/state/download_service.dart#L33) | cookie 非空时，若目标是内网/环回则拒绝创建任务并给出用户可见原因 |
| [download_service.dart:145-147](../lib/state/download_service.dart#L145) | 非法 BT scheme 拒绝并记 `LogRedact.url` |
| [download_service.dart:107](../lib/state/download_service.dart#L107) | 加固前是 `if (cookie.isNotEmpty) 'Cookie': cookie`（HEAD 第 91 行，无条件附 cookie）；现在由 `attachCredential` 决定 |
| [xunlei_review_page.dart:69](../lib/pages/login/xunlei_review_page.dart#L69)、[91](../lib/pages/login/xunlei_review_page.dart#L91) | 只在受信域注入 bridge |
| [netdisk123_pay_page.dart:32-40](../lib/pages/drive/netdisk123_pay_page.dart#L32) | 充值页：`parseHttp` 失败即 `prevent`；离开 123 域只记 INFO（该页不注入凭据） |

**取舍**：`isInternalHost` 只用于「是否附带凭据」，不用于「是否允许下载」。因为网盘直链会落到各家 CDN 的随机主机名，做厂商域白名单会让正常下载大面积失败，收益不抵成本（`security-design.md` §4.3「为什么没更强」）。**加固前该判断完全不存在**，把夸克 cookie POST 到 `http://127.0.0.1:8080/` 这类目标是通的。

**未验证**：域名后缀匹配用的是 host 的小写后缀比较，未做 DNS 解析 —— DNS rebinding 到内网仍可绕过（遗留风险 X-1）。

---

### 2.5 M2：路径与文件名

新增 [path_guard.dart](../lib/utils/path_guard.dart)（64 行）：`safeName`（[13](../lib/utils/path_guard.dart#L13)，剥控制字符、Windows 保留名、末尾点/空格，限长 200）、`traversalRejection`（[43](../lib/utils/path_guard.dart#L43)）、`joinUnder`（[53](../lib/utils/path_guard.dart#L53)，拼接后规范化并要求仍在 base 之下）。

| 加固前 | 加固后 |
|---|---|
| `gopeed_client.dart:33-58` `create()` 直接把 `name`、`path` 放进 `opts` | [gopeed_client.dart:48-50](../lib/core/gopeed/gopeed_client.dart#L48) 先 `traversalRejection(path)` 再 `safeName(name)` |
| iOS 客户端同样直传 | [ios_background_download_client.dart:107-110](../lib/core/gopeed/ios_background_download_client.dart#L107) |
| 目录树拼接 `'$base/$rel'`（`drive_page.dart:465`，另见 `490`、`927`） | [drive_page.dart:467](../lib/pages/drive/drive_page.dart#L467) `PathGuard.joinUnder(base, rel)`；[xunlei_drive_page.dart:201](../lib/pages/drive/xunlei_drive_page.dart#L201)、[netdisk123_drive_page.dart:313](../lib/pages/drive/netdisk123_drive_page.dart#L313) 同 |

危害模型：文件名来自网盘元数据（可被他人构造），`../../` 或 `C:\...` 让下载落到目标目录之外；`con.txt`、`nul` 之类在 Windows 上会创建失败或重定向。

**未验证**：`joinUnder` 在两个平台（Windows 反斜杠 / POSIX 正斜杠）的规范化只按 `/` 处理，Windows 上 `..\..\x` 形式依赖 `traversalRejection` 先拦；没有真机跑过。

---

### 2.6 M3：WebView

加固前 `xunlei_review_page.dart:51-68`：`onPageStarted`（55-58）与 `onPageFinished`（59-62）**各自无条件**调用 `_injectBridge()`，且该方法当时**不接受 url 参数**（`_injectBridge()` 定义在 HEAD 第 71 行），既没有 `onNavigationRequest`，也没有任何域名判断。也就是说凭据 bridge 注入到了导航到达的任意页面 —— 一次跳转/重定向就能把 cookie 送出去。

加固后 [xunlei_review_page.dart:60-91](../lib/pages/login/xunlei_review_page.dart#L60)：

- [61-74](../lib/pages/login/xunlei_review_page.dart#L61) 装 `NavigationDelegate.onNavigationRequest`；对非受信域**记 WARN 但不阻止导航**（[68](../lib/pages/login/xunlei_review_page.dart#L68) 的注释写明原因：风控页要让用户完成人机验证，硬拦会让功能不可用）。
- [75-76](../lib/pages/login/xunlei_review_page.dart#L75) 两个回调仍指向 `_injectBridge`，但 `_injectBridge` 内部先做门禁（[88-91](../lib/pages/login/xunlei_review_page.dart#L88)）：`isTrustedPage(url, NetScope.xunlei)` 不通过就直接 return，一行业务 JS 都不注入。

123 充值页 [netdisk123_pay_page.dart:32-40](../lib/pages/drive/netdisk123_pay_page.dart#L32) 采用同一套委托：**硬拦非 http(s) 协议**（`parseHttp` 失败即 `prevent`，[33-36](../lib/pages/drive/netdisk123_pay_page.dart#L33)），但离开 123 域只记 INFO 不拦导航（[37-39](../lib/pages/drive/netdisk123_pay_page.dart#L37)）——因为充值流程本来就要三跳到支付渠道，按域硬拦会让用户付不了款。该页面不注入任何凭据 bridge，所以放宽导航的代价比迅雷验证页低。

**取舍与代价**：`trustedPageSuffixes`（[net_guard.dart:34-38](../lib/utils/net_guard.dart#L34)）里的迅雷域是 `xunlei.com` / `xunleix.com`。迅雷风控落地域一旦变更，表现是「验证页能打开但一直要求重新登录」，处理方式是往这张表里加域，**而不是**删掉门禁 —— 已写进 [operations.md](operations.md) §4 故障表。另外 bridge 注入后页面 JS 不受 CSP 约束，属于遗留风险 X-3。

---

### 2.7 M4：明文流量与备份面

| 文件 | 加固前 | 加固后 |
|---|---|---|
| [AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml) | 第 22 行 `android:usesCleartextTraffic="true"` | [37](../android/app/src/main/AndroidManifest.xml#L37) `="false"`；[36](../android/app/src/main/AndroidManifest.xml#L36) `allowBackup="false"`；[38](../android/app/src/main/AndroidManifest.xml#L38) `dataExtractionRules`；[39](../android/app/src/main/AndroidManifest.xml#L39) `networkSecurityConfig` |
| [network_security_config.xml](../android/app/src/main/res/xml/network_security_config.xml) | 不存在 | 新增（30 行）：`base-config` cleartext=false，只信任 `system`/`user` 信任锚；注释说明 cleartext 默认值随 targetSdk 的变化与 API 24 / ≤23 / 38+ 的适用性 |
| [data_extraction_rules.xml](../android/app/src/main/res/xml/data_extraction_rules.xml) | 不存在 | 新增（32 行）：`cloud-backup` 与 `device-transfer` 双排除（含 `device_sharedpref`/`device_file`/`device_database`/`device_root`），注释记录 OEM D2D 迁移无法完全关闭的厂商现实 |
| [app.dart](../lib/app.dart) iOS | 无 | `Info.plist` / entitlements 侧未改动，见 §4 |

注：加固前 manifest 还带着 `fullBackupContent="false"`。这个布尔写法在官方文档里没有明确语义（该属性期望的是文件名），已移除并把语义收敛到 `allowBackup=false` + `dataExtractionRules`。`requestLegacyExternalStorage`（[35](../android/app/src/main/AndroidManifest.xml#L35)）**保留**：它在 targetSdk>10 时无效，但本仓库 targetSdk 取自 Flutter 注入值、本次无法离线确证，删掉属于不可验证的改动 —— 注释（[26-28](../android/app/src/main/AndroidManifest.xml#L26)）写明了这一点。

---

### 2.8 L8：日志脱敏

加固前 `app_logger.dart:44` 直接把 `msg` 原样写文件，而 `download_service.dart:71-73` 的 `_briefUrl` 只是「截断到 120 字符」—— 截断不脱敏，URL 里的 `sign=` / `token=` 与日志里的 `Cookie: ...` 全部落盘（日志文件在应用文档目录，可被读日志功能导出、也可被 `adb backup`（加固前）取出）。

加固后：

- [app_logger.dart:43-55](../lib/utils/app_logger.dart#L43) `_log` 成为**唯一收口**：所有级别都过 `LogRedact.text`。
- [app_logger.dart:95-130](../lib/utils/app_logger.dart#L95) `LogRedact`：`_kv`（[101](../lib/utils/app_logger.dart#L101)）匹配 `key=value` 形态的 cookie/token/password 等，`_jsonStr`（[109](../lib/utils/app_logger.dart#L109)）匹配 JSON 字符串字段，命中替换为 `[已脱敏]`（[98](../lib/utils/app_logger.dart#L98)）；`url`（[123](../lib/utils/app_logger.dart#L123)）剥掉 query。
- [download_service.dart:85](../lib/state/download_service.dart#L85) `_briefUrl` 改为委托 `LogRedact.url`（不再是截断）。
- 日志轮转：[app_logger.dart:12-13](../lib/utils/app_logger.dart#L12) 1MB 上限、截断保留 512KB 尾部。

**风险**：脱敏靠键名正则，非清单化的凭据字段（例如第三方返回的怪名字段）会漏。§5.2 说明没有针对脱敏写回归测试。

---

### 2.9 H3：CI 与签名

| 加固前（HEAD `.github/workflows/build.yml`） | 加固后 |
|---|---|
| 第 57 行 `actions/cache` 缓存 keystore、第 68 行 `keytool -genkeypair` 现场生成、第 71/77/79 行口令 `quarklite2026` 明文写在公开 workflow 里 | [build.yml:63-81](../.github/workflows/build.yml#L63) 先断言 4 个 Secret 齐备，[83-103](../.github/workflows/build.yml#L83) 从 Secret 还原 keystore 并用 `keytool -list` 自检；口令全在 Secrets（一次性配置见 [operations.md](operations.md) §1） |
| 第 101 行 job 沿用仓库默认宽权限 | [17-18](../.github/workflows/build.yml#L17) `permissions: contents: read`；[180-181](../.github/workflows/build.yml#L180) 只有 `publish-release` 拿 `contents: write` |
| — | [105-116](../.github/workflows/build.yml#L105) `pubspec.lock` 一致性断言（上游出现过声明依赖在 lock 里没有条目） |
| debug 签名断言用 `keytool -printcert -jarfile`（**只读 v1**；无 v1 块时输出为空 → `grep CN=Android Debug` 永不匹配 → 断言静默通过） | [130-164](../.github/workflows/build.yml#L130) apksigner 优先、找不到才 `keytool` 兜底并 WARN、**两者都无输出即 exit 1** |
| gradle 缺 `key.properties` 时静默用 debug 签名（HEAD `build.gradle.kts:51`） | [build.gradle.kts:47-66](../android/app/build.gradle.kts#L47)：WARN + 支持 `-Pquarklite.requireReleaseSigning=true` 直接失败；CI 里由 [build.yml:122-128](../.github/workflows/build.yml#L122) 的 `GRADLE_OPTS` 传入 |

> 移除 `actions/cache` 复用 keystore 是安全修复的一部分：原方案让「谁能读这个公开仓库」等于「谁能产出同签名 APK」。

**一次性代价**：Secrets 未配置时 CI 直接失败（这是刻意的 fail-visible）。配置清单见 [operations.md](operations.md) §1、[build-and-env.md](build-and-env.md) §3。

---

### 2.10 M6：引擎源码供应链

加固前 `scripts/build_libgopeed.sh`（39 行版本）：第 13-21 行使用固定路径 `/tmp/gopeed-src` 且存在即复用（无 commit 校验；多用户机器上可被抢先创建并替换内容）；第 24 行 `gomobile@latest`；只按 tag 浅克隆（tag 可被仓库所有者移动）。

加固后 [scripts/build_libgopeed.sh](../scripts/build_libgopeed.sh)：

- 源码目录按 UID 隔离（`quarklite-gopeed-src-$(id -u)-<tag>`）。
- 无论克隆还是复用缓存，都 `git rev-parse HEAD` 并与 `GOPEED_COMMIT` 比对，不匹配即中止（打印期望/实际两个 SHA）。
- `GOMOBILE_VERSION` 可固定工具链版本；未设置时退回 `@latest` 并打 WARN。
- 产物打印 `SHA-256`，便于把 AAR 与发布记录对上。
- CI 侧变量注入见 [build.yml:52-58](../.github/workflows/build.yml#L52)。

**遗留**：`GOPEED_COMMIT` 未设置时脚本只告警不失败（[operations.md](operations.md) §6 记为待办 T-x）。

---

### 2.11 R-16：LICENSE

仓库按 GPL-3.0 声明但缺授权文本。新增 [LICENSE](../LICENSE)（官方 GPL-3.0 全文，674 行，`sha256 = 3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`，与 GNU 发布文本一致）。这是法律/合规修复，不属于代码加固。

---

## 3. 新增文件清单

| 文件 | 行数 | 职责 |
|---|---|---|
| [lib/core/credential_store.dart](../lib/core/credential_store.dart) | 101 | 凭据读写唯一入口 + `secureAvailable` + 旧明文清理 |
| [lib/utils/net_guard.dart](../lib/utils/net_guard.dart) | 113 | URL 合法性、内部地址判定、受信页面域表 |
| [lib/utils/path_guard.dart](../lib/utils/path_guard.dart) | 64 | 文件名净化、穿越判定、受控拼接 |
| [android/app/src/main/res/xml/network_security_config.xml](../android/app/src/main/res/xml/network_security_config.xml) | 30 | 禁明文 + 信任锚 |
| [android/app/src/main/res/xml/data_extraction_rules.xml](../android/app/src/main/res/xml/data_extraction_rules.xml) | 32 | 云备份/近设备转移排除 |
| [LICENSE](../LICENSE) | 674 | GPL-3.0 全文 |
| docs/*.md | — | 需求、架构、安全设计、构建环境、运维、本对照表 |

---

## 4. 评估后**故意**不改的地方

| 项 | 不改的原因 |
|---|---|
| 不删除 `requestLegacyExternalStorage` | targetSdk 由 Flutter 注入、离线无法确证；删除属于不可验证的行为改动。改为在注释里标明其在 target>10 时无效。 |
| 不对下载 URL 做厂商域白名单 | 网盘直链主机名随机轮换，白名单会让正常下载大面积失败。仅约束「是否附带凭据」。 |
| 不阻止非受信域导航 | 风控人机验证必须能跳到第三方域；改为「放行导航 + 拒绝注入凭据」。 |
| 不改 `encryptedSharedPreferences` 的值 | 会破坏已安装设备的解密（§2.1.4）。上游写法本就是 `true`，本次把它原样搬进 `CredentialStore` 并加了为什么必须是 `true` 的注释。 |
| 不在本次引入 `flutter_secure_storage` 10.x/11.x | 10.x 弃用该选项、11.x 移除，且 9.2.2 与 `file_picker ^11.0.3` 依赖的 `win32` 版本约束纠缠（`architecture.md` §6）。升级路径与外部口径写在 [security-design.md](security-design.md) §4.1、P-3。 |
| iOS / Windows 侧没有等价网络与备份加固 | iOS 走 URLSession 原生下载、Windows 明文流量策略由系统默认；本次未改动，记为待办而非假装已完成。 |
| 不引入依赖漏洞扫描、不锁 actions 到 SHA | 属于 CI 待办（[operations.md](operations.md) §6），不是本仓库现有能力，未擅自加流水线。 |

---

## 5. 验证状态

### 5.1 已执行的检查（全部是静态检查，没有运行仓库代码）

| 检查 | 命令/方式 | 结果 |
|---|---|---|
| Dart 结构平衡 | 自写 `dart_balance.py`（括号/引号/注释感知的扫描器） | 60 个文件，结构问题 0 |
| XML 良构 | Python `xml.dom.minidom.parse`（manifest + 两个新 xml） | 通过 |
| YAML 良构 | `npx --yes js-yaml` 解析两个 workflow | 通过 |
| Shell 语法 | `bash -n scripts/build_libgopeed.sh` | 通过 |
| LICENSE 完整性 | sha256 与 GNU 发布文本比对 | 一致 |
| 悬空引用 | grep 确认：`_kCookieBackup` 在 lib/ 内 0 处；三个 state 类不再出现任何 `prefs.setString(<凭据键>, …)`；`FlutterSecureStorage` 与 `_secure` 只存在于 `credential_store.dart` 内部（定义 + 3 处调用），调用方一律走 `CredentialStore` | 通过 |
| 文档行号引用 | 自写引用校验脚本，核对文档里每条 `文件#Lxx` 的标签/URL 一致性与范围有效性 | TOTAL BAD: 0 |

### 5.2 **未执行**（结论未经这些验证支撑）

- 没有 `dart analyze` / `flutter analyze`：本机没有 Dart/Flutter SDK（PATH 无 `dart`、`flutter`；离线下载 SDK 未能完成）。
- 没有 `flutter test`：`test/` 下的用例一次都没跑过。
- 没有构建过 APK/AAR/gopeed.exe，没有连接过任何真机或模拟器。
- 没有跑过 GitHub Actions。**因此 §2.9 的 Secrets 清单、§2.2 的 token 生效、§2.7 的域表命中都只有代码级依据，没有运行级证据。**
- 日志脱敏、路径净化、内网判定都**没有安全回归测试**（待办，见 [security-design.md](security-design.md) §5）。
- 加固只做了静态改写，**没有对任何行为做端到端验证**；交付时请把它当作「待验证的补丁集」，不要直接发版。

### 5.3 换行符说明（一次自我更正）

改写过程中若干文件被写成 CRLF，一度判断为「会破坏构建」。核查 `.git/config` 后确认本机 `core.autocrlf=true`，且 `HEAD` 里的 blob 是 LF —— 仓库内容与 CI 不受影响，仅工作区显示差异。**先前的「构建会被破坏」判断已撤回**，本次未据此改动任何代码逻辑。

---

## 6. 回滚

按主题独立回滚（各条之间没有强耦合，除 `app.dart` 引用了 `credential_store.dart`）：

```bash
# H1 凭据（会连带需要还原 app.dart 的 purge 调用）
git checkout HEAD -- lib/state/app_state.dart lib/state/xunlei_state.dart lib/state/netdisk123_state.dart lib/app.dart
rm lib/core/credential_store.dart

# H2 + M5 引擎
git checkout HEAD -- lib/core/gopeed/gopeed_boot.dart lib/core/gopeed/gopeed_client.dart lib/core/gopeed/ios_background_download_client.dart

# M1 + M2 出网与路径
git checkout HEAD -- lib/state/download_service.dart lib/pages/drive/drive_page.dart lib/pages/drive/xunlei_drive_page.dart lib/pages/drive/netdisk123_drive_page.dart
rm lib/utils/net_guard.dart lib/utils/path_guard.dart

# M3 WebView
git checkout HEAD -- lib/pages/login/xunlei_review_page.dart lib/pages/drive/netdisk123_pay_page.dart lib/pages/parse/netdisk123_share_page.dart lib/pages/parse/share_files_page.dart

# M4 + L8
git checkout HEAD -- android/app/src/main/AndroidManifest.xml lib/utils/app_logger.dart
rm android/app/src/main/res/xml/network_security_config.xml android/app/src/main/res/xml/data_extraction_rules.xml

# H3 + M6 CI
git checkout HEAD -- .github/workflows/build.yml .github/workflows/diag-gopeed.yml android/app/build.gradle.kts scripts/build_libgopeed.sh
```

> ⚠ 回滚 H1 后，加固期间新写入的凭据只存在于安全存储中，旧代码的明文回退读不到它们 —— 表现为升级用户（相对回滚版本而言）需要重新登录。回滚 H3 前请先确认没有把 `upload-keystore.jks` 从 CI 里删除，否则回到「现场生成 keystore」意味着**换签名**，已安装设备无法覆盖安装（[operations.md](operations.md) §3）。

---

## 7. 后续必须做的事（不属本次加固范围）

按优先级，摘要自 [security-design.md](security-design.md) §5：

1. 在有 Flutter SDK 的机器上 `flutter pub get && dart analyze && flutter test`，把 §5.2 的空缺补上；这是合入前置条件。
2. 配置 CI Secrets/Variables（[operations.md](operations.md) §1），跑通一次签名构建并记录 APK 签名指纹。
3. 为 `NetGuard.isInternalHost`、`PathGuard.safeName/joinUnder`、`LogRedact` 写单元测试（这三处是纯函数，最容易被测试锁住）。
4. DNS rebinding（X-1）：若要彻底堵住，需要在解析后再判 IP，或改用 IP 直连校验；当前实现只在 host 字面量层面拦截。
5. 依赖与 actions 供应链：SHA 锁定、依赖漏洞扫描、iOS CI（[operations.md](operations.md) §6）。
