# Quarklite 安全设计与威胁模型

本文描述加固后的安全边界、控制措施、有意接受的残余风险，以及所有外部技术口径的出处。
变更逐条对照见 [hardening-changelog.md](hardening-changelog.md)。

约定：`R-xx` 为本文定义的威胁编号；每条结论都给出代码位置或官方出处。
未经实测复核的项标注 **[未验证]**。

---

## 1. 受保护资产

| 编号 | 资产 | 敏感性 | 一旦泄露的后果 |
|---|---|---|---|
| A-1 | 夸克会话 Cookie（含 `__puus`） | 高 | 直接以用户身份访问网盘、转存、下载，等同账号会话被接管 |
| A-2 | 迅雷 `access_token` / `refresh_token` | 高 | refresh token 可持续换取新会话，失效前无法通过改密止损 |
| A-3 | 123 网盘 token 与**记住的密码** | 高 | 密码是明文级别的最高价值目标，且用于自动重登 |
| A-4 | 本地下载引擎的控制权 | 中高 | 可代应用发起任意请求、读写用户文件、消耗带宽与配额 |
| A-5 | 用户文件与下载目录内容 | 中 | 越权读写目录树之外的文件 |
| A-6 | 账号配额/月度流量与支付入口 | 中 | 被诱导消费或超额 |
| A-7 | 发布产物的签名与来源可信性 | 高 | 用户无法分辨官方包与仿冒包 |

实现定位：A-1..A-3 的读写全部收敛到
[lib/core/credential_store.dart](file:///D:/qorder/quarklite/lib/core/credential_store.dart)；
A-4 在 [lib/core/gopeed/gopeed_boot.dart](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart)；
A-7 在 [.github/workflows/build.yml](file:///D:/qorder/quarklite/.github/workflows/build.yml)。

---

## 2. 信任边界

```
        ┌──────────────────────────────────────────────┐
        │  OS 备份/迁移通道（云备份、D2D、adb backup）    │  B-4
        ├──────────────────────────────────────────────┤
 UI 层  │  pages / widgets                             │
        ├──────────────────────────────────────────────┤
 状态层  │  state + core/credential_store              │  B-1（凭据只在应用进程内解密）
        ├──────────────────────────────────────────────┤
 协议层  │  api/quark|xunlei|netdisk123                │  B-2（厂商 HTTPS）
        ├──────────────────────────────────────────────┤
 引擎   │  Gopeed（AAR / exe）  ← 127.0.0.1 + token →   │  B-3（本机 IPC）
        ├──────────────────────────────────────────────┤
 系统   │  Keystore / Keychain / 存储权限 / 前台服务      │  B-5
        └──────────────────────────────────────────────┘
 供应链  │  Actions runner、Gopeed 源码、gomobile、AAR   │  B-6（在用户设备之外）
```

- **B-1 凭据边界**：凭据只在应用进程内以可读形式存在，落盘一律走系统安全存储。
- **B-2 厂商边界**：逆向接口不是可信输入源——文件名、路径、URL、`reviewurl` 都来自这里，
  按外部输入处理（见 §4.2、§4.3）。
- **B-3 本机 IPC 边界**：这是加固前最薄的一环。引擎监听 loopback，
  但**同一台机器上的任何进程**都能连上并代它发起请求。
- **B-4 备份边界**：Android 的备份通道会把应用私有文件整体带走。
- **B-5 系统能力边界**：`MANAGE_EXTERNAL_STORAGE` 一旦授予，沙箱对文件系统的保护就没了。
- **B-6 供应链边界**：签名材料与引擎二进制的来源可信性决定 A-7。

---

## 3. 威胁登记（现状）

| ID | 威胁 | 边界 | 加固前 | 现状 |
|---|---|---|---|---|
| R-01 | 凭据以可读 XML 落盘，可被文件读取/备份带走 | B-1/B-4 | 存在（双写兜底） | 已消除 |
| R-02 | 应用备份/设备迁移带走凭据 | B-4 | 存在（`allowBackup` 默认 true） | 已关闭（含 API 31+ 显式规则） |
| R-03 | 本机任意进程调用引擎 REST，代应用发起下载/读取任务 | B-3 | 存在（无 token） | 已缓解（随机 token） |
| R-04 | 凭据被投递到内网/元数据地址（SSRF 面） | B-2/B-3 | 存在 | 已缓解 |
| R-05 | 恶意文件名/相对路径穿越下载目录 | B-2/B-5 | 存在 | 已缓解 |
| R-06 | `gopeed.exe` 被任意位置替身劫持 | B-6 | 存在（裸名候选） | 已缓解 |
| R-07 | 按镜像名 `taskkill` 误杀用户自己的 Gopeed | B-5 | 存在 | 已缓解（定向清理） |
| R-08 | 明文 HTTP 回流 + 用户 CA 被无条件信任（中间人读凭据） | B-2 | 存在（`usesCleartextTraffic="true"`） | 已关闭 |
| R-09 | WebView 里凭据桥注入到第三方页面 | B-2 | 存在（无导航判定） | 已缓解（可信域才注入） |
| R-10 | 日志把 cookie/token/签名参数写进可分享文件 | B-1 | 存在 | 已缓解（出口脱敏） |
| R-11 | 公开仓库里的签名口令 → 任何人可产出同签名 APK | B-6 | 存在 | 已消除 |
| R-12 | CI 静默产出 debug 签名包 | B-6 | 存在 | 已加断言 |
| R-13 | 引擎源码/AAR 来源不可追溯（tag 可移动、缓存跨版本命中） | B-6 | 存在 | 已缓解 |
| R-14 | `pubspec.lock` 漂移导致构建不可复现 | B-6 | 存在（且已实际发生） | 已加断言 |
| R-15 | `GITHUB_TOKEN` 宽权限被单个被入侵 workflow 滥用 | B-6 | 存在 | 已收敛 |
| R-16 | GPL-3.0 声明缺许可证正文 | 合规 | 存在 | 已补齐 |
| R-17 | 磁力输入框接受任意 URL 当种子提交 | B-2 | 存在 | 已缓解 |
| R-18 | 123 账号 token/用户名/密码被复制进额外 3 个键 | B-1 | 存在 | 已消除 |

---

## 4. 控制详解

### 4.1 凭据只走安全存储（R-01、R-18）

**做法**：新增 `CredentialStore` 作为唯一入口，三个状态类的
`_loadCookie/_saveCookie/_read/_write` 全部改为委托，
删除 SharedPreferences 兜底分支；升级后一次性清理历史明文键。

- 入口类：[lib/core/credential_store.dart:22-45](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L22-L45)
- 夸克侧改造：[lib/state/app_state.dart:90-114](file:///D:/qorder/quarklite/lib/state/app_state.dart#L90-L114)
  （对照加固前 `git show HEAD:lib/state/app_state.dart` 第 101-112 行的"双写持久化"）
- 123 侧不再把凭据复制进 `_kToken/_kUsername/_kPassword`：
  [lib/state/netdisk123_state.dart:368-374](file:///D:/qorder/quarklite/lib/state/netdisk123_state.dart#L368-L374)
  （对照 `git show HEAD:lib/state/netdisk123_state.dart` 第 368-370 行）
- 明文副本清理：[lib/core/credential_store.dart:81-100](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L81-L100)，
  启动时机见 [lib/app.dart:70-92](file:///D:/qorder/quarklite/lib/app.dart#L70-L92)
- 全仓库对 `FlutterSecureStorage` 的引用只剩一处（已 grep 核对）。

**为什么不保留"读不到就退回 prefs"**：那个兜底本身就是漏洞主体——
攻击面从"破解 Keystore"降级成"读一个 XML 文件"。
现在的取舍是**宁可掉登录**（[lib/state/app_state.dart:92-94](file:///D:/qorder/quarklite/lib/state/app_state.dart#L92-L94)）。

**为什么构造参数一个字没改**：插件的 `encryptedSharedPreferences` 与普通模式
共用同一个 `FlutterSecureStorage` 文件名，改动会让现网安装包的既有值读不出来
（插件 README 的 Note + issue #487，见 §7）。
保持 true 是兼容性要求，不是安全增强；安全增强在于**消灭第二份副本**。

**123 的密码**：`rememberedPassword` 仍会持久化（用于 token 过期后自动重登，
[lib/api/netdisk123_client.dart:319](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L319)）。
加固没有改变这一产品行为，只保证它不再以明文形式出现在第二个存储里。
彻底消除的方案是"过期即要求重新登录"，属于产品决策，见 §5 待办 T-2。

### 4.2 凭据投递范围显式化（R-04、R-17）

**问题结构**：`addDirectUrl` 同时持有"用户/服务端给的 URL"和"网盘凭据"，
加固前只要 cookie 非空就无条件附带（`git show HEAD:lib/state/download_service.dart` 第 91 行：
`if (cookie.isNotEmpty) 'Cookie': cookie`）。
一个指向 `169.254.169.254` 或内网服务的 URL 就能把会话 Cookie 送出去。

**做法**：三重约束，全部集中在 [lib/utils/net_guard.dart](file:///D:/qorder/quarklite/lib/utils/net_guard.dart)。

1. **协议必须 http/https**（[:43-50](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L43-L50)），
   `file:`/`javascript:`/自定义 scheme 直接不通过。
2. **目标不得是内部地址**（[:59-95](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L59-L95)；含 `2130706433`、`127.1`、`0x7f000001` 这类 IP 别名写法，见 [:92-93](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L92-L93)）：
   回环、`0/8`、`10/8`、`127/8`、`169.254/16`（含云厂商元数据口）、`172.16-31`、
   `192.168/16`、`100.64/10`、IPv6 `::1`、`fe80::/10`、`fc00::/7`（`fc` 与 `fd` 两个前缀都覆盖）、
   `::ffff:` 映射地址一律按内部处理（不做解析以免绕过）。
3. **凭据只在调用方显式声明 `NetScope` 时才附带**，且 `NetScope.none` 直接拒绝
   （[:100-106](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L100-L106)、
   [lib/state/download_service.dart:94-101](file:///D:/qorder/quarklite/lib/state/download_service.dart#L94-L101)）。
   `credentialScope` 是 **required** 参数，全部 10 个外部调用点都已声明（已 grep 核对）；
   新代码不声明就编译不过。

**为什么不用厂商域名白名单判直链**：夸克与 123 的直链落在第三方 CDN 域，
白名单会打断正常下载。取舍理由写进代码头注释
（[lib/utils/net_guard.dart:7-12](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L7-L12)）。

**这套约束的性质**：它是**基于地址形态**的拦截，不是基于域名的信任。
它挡不住"合法公网域名被解析到内网"（DNS rebinding）和
"公网 CDN 域名本身可控"这两类情形——见 §6 残余风险 X-1。

**磁力入口**：只接受 `magnet:` / `btth:`，其他串（含 http）拒绝
（[:53-56](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L53-L56)、
[lib/state/download_service.dart:144-147](file:///D:/qorder/quarklite/lib/state/download_service.dart#L144-L147)）。

### 4.3 文件名与路径净化（R-05）

- 净化单个名字：[lib/utils/path_guard.dart:13-41](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L13-L41)
  —— 剔除路径分隔符与控制字符、去掉尾部点/空格、Windows 保留名、200 字符上限（保扩展名）。
- 拒绝上级引用：[lib/utils/path_guard.dart:43-51](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L43-L51)。
- 逐段拼接（文件夹上传）：[lib/utils/path_guard.dart:53-63](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L53-L63)，
  三处拼接点改为 `PathGuard.joinUnder`：
  [lib/pages/drive/drive_page.dart:467](file:///D:/qorder/quarklite/lib/pages/drive/drive_page.dart#L467)、
  [lib/pages/drive/xunlei_drive_page.dart:201](file:///D:/qorder/quarklite/lib/pages/drive/xunlei_drive_page.dart#L201)、
  [lib/pages/drive/netdisk123_drive_page.dart:313](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_drive_page.dart#L313)。
- 引擎侧再拦一次（两个实现各自守）：
  [lib/core/gopeed/gopeed_client.dart:48-50](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_client.dart#L48-L50)、
  [lib/core/gopeed/ios_background_download_client.dart:107-110](file:///D:/qorder/quarklite/lib/core/gopeed/ios_background_download_client.dart#L107-L110)。

**为什么两层都做**：上层拼的是"目录 + 网盘内相对路径"，引擎层收到的是最终 `path`/`name`。
任何一层单独失守都不应该导致越界写入。

### 4.4 本地引擎鉴权与进程治理（R-03、R-06、R-07）

- 每次启动生成 32 字节 CSPRNG token，仅存内存，不落盘
  （[lib/core/gopeed/gopeed_boot.dart:44-53](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L44-L53)）。
  base64url 会带 `=` 填充，因此显式去掉——填充符进 HTTP 头不安全
  （[lib/core/gopeed/gopeed_boot.dart:51](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L51)）。
- 同一条 token 同时喂给引擎侧与客户端侧：
  Android 配置 `'apiToken'`（[lib/core/gopeed/gopeed_boot.dart:140](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L140)）、
  Windows 命令行 `-T`（[lib/core/gopeed/gopeed_boot.dart:210](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L210)）、
  客户端 `Authorization: Bearer`（[lib/core/gopeed/gopeed_client.dart:14-21](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_client.dart#L14-L21)）。
  Gopeed 侧只要 `ApiToken != ""` 就启用校验，接受 `X-Api-Token` 或 `Bearer`，
  常量时间比较，未通过返回 401（见 §7 出处 S-2）。
- 绑定地址仍是 `127.0.0.1`（[lib/core/gopeed/gopeed_boot.dart:136](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L136)、
  [:208](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L208)）。
  这一点必须保留：Gopeed 的 `-A` 默认值是 `0.0.0.0`（§7 出处 S-1），
  不显式指定就会把引擎暴露到局域网。
- exe 查找只接受受控目录的绝对路径，删除裸名候选
  （[lib/core/gopeed/gopeed_boot.dart:296-309](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L296-L309)）。
- 残留进程清理改为按目录定向：PowerShell 过滤 `Win32_Process.ExecutablePath`
  前缀，目录通过环境变量传入、脚本经 `-EncodedCommand`（UTF-16LE + base64）传入，
  避免命令行拼接注入
  （[lib/core/gopeed/gopeed_boot.dart:374-421](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L374-L421)）。
  只有在 PowerShell 本身调用失败时才退回 `taskkill /IM`，
  且这是"宁可少杀也不要误杀"的兜底
  （[lib/core/gopeed/gopeed_boot.dart:412-420](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L412-L420)）。

**残余**：命令行里的 token 在 Windows 上是**同机任意用户态进程可读**的
（`Win32_Process.CommandLine` 对同权限进程可见）。见 §6 X-2。

### 4.5 WebView：观测导航 + 按域注入（R-09）

迅雷验证页会把 `creditkey`/`deviceid` 注入到 JS 桥，因此注入点必须限定域名：

- 载入前校验 URL 可解析为 http(s)
  （[lib/pages/login/xunlei_review_page.dart:53](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart#L53)）。
- 只有当前页面属于迅雷域才注入凭据桥
  （[lib/pages/login/xunlei_review_page.dart:88-91](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart#L88-L91)、
  域表 [lib/utils/net_guard.dart:34-38](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L34-L38)）。
- **非 http(s) 协议阻断，跨域导航只记录不阻断**
  （[lib/pages/login/xunlei_review_page.dart:61-74](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart#L61-L74)）。
  理由：验证码流程必然跳转，硬阻断等于打断登录。
- 123 收银台同样处理：阻断非 http(s)，允许跨域（付款要跳支付宝/微信）
  （[lib/pages/drive/netdisk123_pay_page.dart:32-40](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_pay_page.dart#L32-L40)）。

两处 WebView 都保留 `JavaScriptMode.unrestricted`：验证页依赖页面自身的 JS 与
`XLJSWebViewBridge` 回调，关掉脚本会让风控验证无法完成。这是**已知取舍**（§6 X-3）。

### 4.6 传输与备份（R-02、R-08）

- Manifest 现在的四个开关：
  [android/app/src/main/AndroidManifest.xml:35-39](file:///D:/qorder/quarklite/android/app/src/main/AndroidManifest.xml#L35-39)
  （加固前同一位置是 `android:usesCleartextTraffic="true"`，见
  `git show HEAD:android/app/src/main/AndroidManifest.xml` 第 22 行）。
- NSC：release 禁止明文且只信任系统 CA；debug 构建才追加用户 CA，
  保住抓包排障能力
  （[android/app/src/main/res/xml/network_security_config.xml:17-30](file:///D:/qorder/quarklite/android/app/src/main/res/xml/network_security_config.xml#L17-L30)）。
  没有 `domain-config` 时所有连接落 `base-config`（§7 出处 A-3）。
- 备份规则：`allowBackup="false"` + API 31+ 的 `dataExtractionRules` 双重声明，
  `device-transfer` 额外排除 `device_*` 变体域
  （[android/app/src/main/res/xml/data_extraction_rules.xml:13-32](file:///D:/qorder/quarklite/android/app/src/main/res/xml/data_extraction_rules.xml#L13-L32)）。
- `fullBackupContent` 已从 manifest 移除。原因：AOSP 的属性声明允许
  `reference|boolean` 两种格式，但官方 Auto Backup 文档只描述资源引用形式，
  布尔值语义**查无官方口径**；既然 `allowBackup="false"` 已足以覆盖
  （官方原文：设为 false 后"no backup or restore … ever performed"，含 adb 全系统备份），
  就不依赖没有文档保证的属性。

### 4.7 日志脱敏（R-10）

日志是唯一落盘出口，脱敏放在这一处，新增调用点自动生效：

- 出口：[lib/utils/app_logger.dart:44-46](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L44-L46)
  （加固前是无条件 `$msg`，见 `git show HEAD:lib/utils/app_logger.dart` 第 44 行）。
- 规则：[lib/utils/app_logger.dart:95-130](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L95-L130)
  覆盖 `key=value`、JSON 字符串值、URL query 三类形态；
  字段表包含 cookie/authorization/set-cookie/各类 token/signature/sign/pwd/password/
  secret/client_secret/creditkey/`__puus`/`__pus`/`__kp`/device_id。
- 下载 URL 单独走 `LogRedact.url`——**整个 query 丢弃**，因为网盘直链的签名参数
  本身即凭据（[lib/state/download_service.dart:85](file:///D:/qorder/quarklite/lib/state/download_service.dart#L85)）。

**为什么值得做在出口而不是调用点**：Dio 异常串自带完整请求 URL 与 query，
调用点级脱敏必然漏掉异常分支。

**局限**：正则脱敏是尽力而为。字段名不在表里、或值以其他编码出现时仍可能漏。
新增接口字段时要同步维护字段表（§5 待办 T-4）。

### 4.8 供应链与发布完整性（R-11..R-16）

见 [operations.md](operations.md) §1-§2 与 [build-and-env.md](build-and-env.md) §2-§3。要点：

- 签名材料只来自 4 个 Secrets；公开 workflow 里不再有口令
  （加固前：`git show HEAD:.github/workflows/build.yml` 第 68-79 行把
  `quarklite2026` 写死在 `keytool -genkeypair` 与 `key.properties` 里，
  第 57 行还有一步 `Cache keystore`）。
- 三道断言：Secrets 齐全、`keytool -list` 自检、**APK 非 debug 签名**
  （[.github/workflows/build.yml:63-81](file:///D:/qorder/quarklite/.github/workflows/build.yml#L63-L81)、
  [:99-103](file:///D:/qorder/quarklite/.github/workflows/build.yml#L99-L103)、
  [:130-164](file:///D:/qorder/quarklite/.github/workflows/build.yml#L130-L164)）。
  第三条**必须**用 `apksigner verify --print-certs`：`keytool -printcert -jarfile`
  只能读签名 JAR 块（Oracle 文档只描述"signed JAR file"），
  若 APK 只有 v2/v3 而无 v1 块，它会**没有任何输出**，
  `grep "CN=Android Debug"` 不匹配就会让断言静默通过。
  现在无输出即失败（[:130-164](file:///D:/qorder/quarklite/.github/workflows/build.yml#L130-L164)）。
- 引擎源码固定到 commit 并强制校验；不再共享 `/tmp` 源码目录；
  移除跨版本会命中的 `restore-keys` 缓存
  （[scripts/build_libgopeed.sh:20-21](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L20-L21)、
  [:41-51](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L41-L51)、
  [.github/workflows/build.yml:48-58](file:///D:/qorder/quarklite/.github/workflows/build.yml#L48-L58)）。
- `GITHUB_TOKEN` 按 job 最小化；官方语义是**一旦显式声明，未点名的权限一律 none**
  （[:15-18](file:///D:/qorder/quarklite/.github/workflows/build.yml#L15-L18)、
  [:177-181](file:///D:/qorder/quarklite/.github/workflows/build.yml#L177-L181)）。
- 诊断工作流下载的引擎二进制增加 SHA-256 校验
  （[.github/workflows/diag-gopeed.yml](file:///D:/qorder/quarklite/.github/workflows/diag-gopeed.yml)）。
- 补齐 GPL-3.0 正文 `LICENSE`（与 GNU 官方文本一致，
  SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`，本地实测）。

---

## 5. 待办（明确不做，但要记账）

| ID | 项 | 为什么本次没做 |
|---|---|---|
| T-1 | Actions 固定到 commit SHA | 官方建议 pin SHA（§7 A-6），但本次无法离线核对各 action 当前 SHA，填错会直接打断构建。留作专门一次改动 |
| T-2 | 不再持久化 123 密码 | 会改变产品行为（token 过期后不再自动重登），需要用户侧确认 |
| T-3 | `MANAGE_EXTERNAL_STORAGE` 换成 SAF/目录选择器 | 会牺牲"文件夹上传保持目录结构"能力（[README.md:11](file:///D:/qorder/quarklite/README.md#L11)） |
| T-4 | 脱敏字段表与安全守卫的自动化回归测试 | 本机已装到 Dart SDK 3.14.0，但 `test/` 现有用例依赖 `flutter_test`，进 CI 仍需 Flutter SDK；`NetGuard`/`PathGuard` 已固化为仓库内断言 [tool/guard_selfcheck.dart](file:///D:/qorder/quarklite/tool/guard_selfcheck.dart)（`dart run tool/guard_selfcheck.dart`，无需 Flutter）；`LogRedact` 依赖 Flutter 仍完全没覆盖 |
| T-5 | `upload/download-artifact` 从 v4 升到 v7（官方最新 7.0.2，2026-11 核对） | 与加固无关的版本升级，混进同一批改动会让回滚边界不清 |
| T-6 | DNS rebinding 防护（解析后校验 IP） | 需要引入自定义 `findProxy`/`badCertificateCallback` 逻辑，影响面大；列为 X-1 的长期方案 |
| T-7 | iOS `IOSOptions.accessibility` 显式设为 `first_unlock` | 需要确认后台下载恢复时是否真的读凭据；改了会影响 Keychain 项迁移行为，未验证不动 |

---

## 6. 残余风险（接受并记录）

| ID | 风险 | 影响 | 接受理由 |
|---|---|---|---|
| X-1 | 公网域名 DNS 解析到内网/元数据地址（rebinding），绕过 §4.2 的地址形态检查 | 凭据外泄 | 需要在 HTTP 层做解析后二次校验（T-6）；当前控制对"直接把 URL 写成内网地址"这一主要形态有效（含十进制/八进制/十六进制/短写别名，已断言验证） |
| X-2 | Windows 命令行里的 `-T token` 对同机其他进程可见 | 本机进程可冒充应用调用引擎 | 攻击者已具备同用户权限时，本来就能读应用内存；收益不足以引入 Gopeed 不支持的配置通道 |
| X-3 | 两处 WebView 保留 `JavaScriptMode.unrestricted` | 页面脚本可操作注入的桥 | 关掉脚本会让风控验证与支付页不可用；已用"仅可信域注入"收窄 |
| X-4 | CDN 迁移到新的第三方域时可能命中 §4.2 拦截（误拦，非漏拦） | 下载失败并给出原因串 | 失败可见、可诊断，比静默把凭据送出去好 |
| X-5 | 部分厂商 ROM 上"近设备迁移"无法完全关闭（官方明确说明，见 A-1） | 换机时凭据可能随迁 | 已同时使用 `allowBackup=false` 与 `dataExtractionRules`；无更强系统级手段 |
| X-6 | `MANAGE_EXTERNAL_STORAGE` 授予后沙箱失效（配合 Play 政策需申报，见 A-8） | 越权文件访问面大 | 功能必需（T-3）；用路径净化 + 引擎侧二次校验限制后果 |
| X-7 | 逆向接口随时失效；官方改协议即出现功能性故障 | 用户可见 | 产品性质决定；用诊断页 + 更新检查承担 |
| X-8 | 历史版本的明文凭据**在被清理之前**已可能流走 | 已发生的泄露无法追溯 | 清理只解决"此后"；文档明确要求用户改密（operations.md §5） |
| X-9 | 本机时间被篡改不影响 token，但会让日志时序失去取证价值 | 事后定位困难 | 未引入签名时间戳，成本收益不划算 |

---

## 7. 外部技术口径与出处

> 拉取环境限制说明：`developer.android.com` 与 `support.google.com` 在本机直接抓取失败，
> 核对走的是 Google 官方镜像 `developer.android.google.cn`（内容同源）。
> 下文引用的是这些页面的**规范 URL**。

### 代码类

| 编号 | 事实 | 出处 |
|---|---|---|
| S-1 | Gopeed `-A/-P/-T/-d/-u/-p` 定义与默认值（`-A` 默认 `0.0.0.0`，`-P` 默认 9999，`-T` 默认空串） | [cmd/web/flags.go](https://github.com/GopeedLab/gopeed/blob/main/cmd/web/flags.go) |
| S-2 | `ApiToken != ""` 即启用校验；接受 `X-Api-Token` 或 `Authorization: Bearer`；常量时间比较；失败 401 | [pkg/rest/server.go](https://github.com/GopeedLab/gopeed/blob/main/pkg/rest/server.go) |
| S-3 | 端口打印语句 `Server start success on http://%s`（实际监听地址） | [cmd/server.go](https://github.com/GopeedLab/gopeed/blob/main/cmd/server.go) |
| S-4 | 存储后端为 `go.etcd.io/bbolt`；bolt 官方 README："Bolt obtains a file lock on the data file so multiple processes cannot open the same database at the same time." | [pkg/download/storage.go](https://github.com/GopeedLab/gopeed/blob/main/pkg/download/storage.go)、[boltdb/bolt](https://github.com/boltdb/bolt) |
| S-5 | `-P 0` 随机端口来自 Go `net.Listen` 语义（端口 0 由内核分配） | [pkg.go.dev/net#Listen](https://pkg.go.dev/net#Listen) |
| S-6 | `gomobile bind` 的 `-javapkg`/`-target`/`-androidapi`；绑定包 `github.com/GopeedLab/gopeed/bind/mobile`，其 `Start` 返回端口 | [gomobile 文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)、[bind/mobile](https://github.com/GopeedLab/gopeed/blob/main/bind/mobile/main.go) |
| S-7 | `-tags nosqlite` 出现在 Gopeed 自己的构建命令里，但当前 `main` 的存储代码**没有** `//go:build nosqlite` 保护，实际是 no-op | [Gopeed build.yml](https://github.com/GopeedLab/gopeed/blob/main/.github/workflows/build.yml)、[storage.go](https://github.com/GopeedLab/gopeed/blob/main/pkg/download/storage.go) |
| S-8 | `base64Url` 是 URL 安全字母表且**带 `=` 填充**（所以进 HTTP 头前要去填充） | [dart:convert Base64Codec](https://api.dart.dev/stable/dart-convert/Base64Codec-class.html) |
| S-9 | PowerShell `-EncodedCommand` 接受 base64(UTF-16LE) | [about_PowerShell_exe](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe) |

### 平台与策略类

| 编号 | 事实 | 出处 |
|---|---|---|
| A-1 | `allowBackup` 默认 `"true"`；设为 false 后"no backup or restore … ever performed"，含 adb 全系统备份。官方警告：targeting 31+ 时"部分厂商设备无法关闭 D2D 文件迁移" | [application 元素](https://developer.android.com/guide/topics/manifest/application-element)、[Auto Backup](https://developer.android.com/identity/data/autobackup) |
| A-2 | `usesCleartextTraffic`：target ≤27 默认 true，target 28+ 默认 false；target 38+ 会被忽略；API 23 及以下必须额外显式声明该属性（NSC 只覆盖 24+） | 同 A-1 页面 |
| A-3 | NSC：`<base-config>` 覆盖无 `domain-config` 匹配的连接；`<certificates src>` 合法值为 `system` / `user` / 原始资源（**没有 `network`**）；`<debug-overrides>` 仅在 `debuggable="true"` 生效，否则整段忽略；`cleartextTrafficPermitted` 平台默认 target 28+ 为 false | [Network Security Configuration](https://developer.android.com/privacy-and-security/security-config) |
| A-4 | `dataExtractionRules` 是 **Android 12 / API 31**（不是 30）起；Android 11 及以下由 `allowBackup` + `fullBackupContent` 管；两套规则名 `cloud-backup` / `device-transfer`；合法域含 `root`/`file`/`database`/`sharedpref`/`external` 及 `device_*` 变体（拼写是 `sharedpref`，不是 `sharepref`）；`path="."` 为官方示例用法 | 同 A-1 第二页、[lint DataExtractionRules](https://googlesamples.github.io/android-custom-lint-rules/checks/DataExtractionRules.md.html) |
| A-5 | `fullBackupContent` 在 AOSP `attrs_manifest.xml` 声明为 `reference\|boolean`（布尔合法），但官方指南**未描述**布尔语义 → 本文不声称其行为 | [attrs_manifest.xml](https://android.googlesource.com/platform/frameworks/base/+/HEAD/core/res/res/values/attrs_manifest.xml) |
| A-6 | Actions 加固建议："Pin references to actions to a commit SHA"；`permissions` 一旦显式声明，未点名的权限设为 none | [Security hardening](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)、[workflow-syntax#permissions](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions#permissions) |
| A-7 | AndroidX security-crypto 官方警告："Deprecated all APIs in favour of existing platform APIs and direct use of Android Keystore."（"end of life" 字样**查无官方口径**） | [AndroidX security releases](https://developer.android.com/jetpack/androidx/releases/security) |
| A-8 | `MANAGE_EXTERNAL_STORAGE` 属 Play 受限的"All files access"特殊访问；核心功能需要时必须填写 Permissions Declaration Form 并获批准 | [Play 政策](https://support.google.com/googleplay/android-developer/answer/10467955)、[manage-all-files](https://developer.android.com/training/data-storage/manage-all-files) |
| A-9 | `requestLegacyExternalStorage` 只在 target Android 10 有效，target 11+ 被系统忽略 | [Android 11 storage](https://developer.android.com/about/versions/11/privacy/storage) |
| A-10 | target 31+ 时 `adb backup` 默认排除应用数据（Android 12 行为变更）。"adb backup 已移除"仅有 adb 二进制自身的 deprecated 提示，**查无官方版本口径** | [behavior-changes-12](https://developer.android.com/about/versions/12/behavior-changes-12) |
| A-11 | 元数据端点：AWS EC2 `169.254.169.254`（IPv6 `fd00:ec2::254`）、ECS `169.254.170.2`、GCP `169.254.169.254`、Azure IMDS `169.254.169.254` | [EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html)、[ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v2.html)、[GCP](https://docs.cloud.google.com/compute/docs/metadata/querying-metadata)、[Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service) |
| A-12 | RFC 6598 `100.64.0.0/10`（共享地址空间/CGNAT，现并入 RFC 6890 注册表）、RFC 3927 `169.254/16`、RFC 4291 `fe80::/10` 与 `::1/128`、RFC 4193 `FC00::/7`（本地分配即 `fd00::/8`） | [RFC 6598](https://www.rfc-editor.org/rfc/rfc6598)、[3927](https://www.rfc-editor.org/rfc/rfc3927)、[4291](https://www.rfc-editor.org/rfc/rfc4291)、[4193](https://www.rfc-editor.org/rfc/rfc4193) |
| A-13 | `keytool -printcert -jarfile` 文档措辞为读取"signed JAR file"的证书。"v2/v3-only 签名的 APK 不产生输出"是据此 + AGP 签名方案得出的**推断**，未逐字核对官方文句 | [keytool(1)](https://docs.oracle.com/en/java/javase/17/docs/specs/man/keytool.html) |
| A-14 | `pubspec.lock`：应用应提交，以保证依赖一致 | [pub glossary](https://dart.dev/tools/pub/glossary#lockfile) |
| A-15 | `--split-per-abi` 与 fat APK 的区别；split APK 会给 versionCode 加 `ABI_VERSION*1000` | [Deploy an Android App Bundle/APK](https://docs.flutter.dev/deployment/android) |

### flutter_secure_storage 类

| 编号 | 事实 | 出处 |
|---|---|---|
| P-1 | 9.2.2 的 Android 默认分支写 `getSharedPreferences("FlutterSecureStorage", MODE_PRIVATE)`，值经 AES 加密（AES key 由 RSA 包裹存于 KeyStore），**不是明文**；明文风险来自应用自己的 `shared_preferences` 副本 | [v9.2.2 源码](https://raw.githubusercontent.com/juliansteenbakker/flutter_secure_storage/v9.2.2/flutter_secure_storage/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorage.java)、[9.2.2 README](https://pub.dev/packages/flutter_secure_storage/versions/9.2.2) |
| P-2 | `AndroidOptions.encryptedSharedPreferences` 在 9.2.2 默认 **false**；置 true 时改用 Jetpack `EncryptedSharedPreferences` + `MasterKey.DEFAULT_MASTER_KEY_ALIAS`，**同一文件名**，因此两种模式混用会导致旧值读不出（issue #487） | [android_options.dart@v9.2.2](https://raw.githubusercontent.com/juliansteenbakker/flutter_secure_storage/v9.2.2/flutter_secure_storage/lib/options/android_options.dart)、[issue #487](https://github.com/juliansteenbakker/flutter_secure_storage/issues/487) |
| P-3 | 版本边界：10.0.0-beta.1 曾强制 true；10.0.0 起该选项**弃用**并引入 `migrateOnAlgorithmChange`、`resetOnError` 默认改 true；11.0.0 **移除**该参数 | [CHANGELOG](https://github.com/juliansteenbakker/flutter_secure_storage/blob/develop/flutter_secure_storage/CHANGELOG.md) |
| P-4 | 插件 README 记录："By default Android backups data on Google Drive. It can cause exception `java.security.InvalidKeyException: Failed to unwrap key`" → 与本文 §4.6 的备份关闭互为依赖 | 9.2.2 README |
| P-5 | iOS 默认 `accessibility = KeychainAccessibility.unlocked`，README 原文 "The default if not specified is unlocked"；Apple 侧 `kSecAttrAccessibleWhenUnlocked` 是未显式设置时的默认值，`AfterFirstUnlock` 才适合后台读取；两者默认都会随加密备份迁移到新设备 | [9.2.2 README](https://pub.dev/packages/flutter_secure_storage/versions/9.2.2)、[WhenUnlocked](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked)、[AfterFirstUnlock](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock) |
| P-6 | 9.x 线无已发布安全公告（GitHub advisory 页无内容，pub.dev 安全页 404）；热门问题是功能性（#487/#933/#853/#789） | [security policy](https://github.com/juliansteenbakker/flutter_secure_storage/security/policy) |
| P-7 | 当前版本 11.2.0（2026-09-16 发布）。"Bad MAC"/`InvalidAlgorithmParameterException` 这一具体命名**查无官方口径**；changelog 中无该字样 | [pub.dev versions/changelog](https://pub.dev/packages/flutter_secure_storage/changelog) |
| P-8 | 卸载时是否自动删除 Keychain/Keystore 项：插件与 Apple/AOSP 页面均**查无官方口径**；"Keychain 单项 2048 字节上限"是 macOS 传统 Keychain 的说法，**不适用于**本文场景且插件未提及 | 上述各页 |

---

## 8. 本文修订记录与勘误表

### 8.1 本文档相对上一版（聊天里的原始审计报告）的变更

原始风险审计报告只在对话中交付，未落成文件。本文重新编号为 `R-xx`，
并把审计阶段的"高危/中危/低危"分档统一为"现状列 + 残余风险列"。
新增内容：§6 X-1..X-9（接受理由）、§7 全部外部口径、§5 T-1..T-7。

### 8.2 勘误表（编写本文过程中被官方口径纠正的说法）

| # | 原说法 | 正确说法 | 出处 |
|---|---|---|---|
| E-1 | "flutter_secure_storage 不加参数就是明文 XML 落盘" | 插件默认分支也是 AES 加密后写入 `FlutterSecureStorage.xml`；真正可读的是应用自己双写到 `shared_preferences` 的那一份 | P-1 |
| E-2 | "改成默认后端更安全" | 默认后端与 `encryptedSharedPreferences` 两种模式共用同一文件名，切换会让老设备读不出既有凭据（升级即全员掉登录）；因此**保持**上游原有的 `true` 不动 | P-2、P-3 |
| E-3 | "`encryptedSharedPreferences` 是长期方向" | 该选项依赖已整体弃用的 Jetpack security-crypto，插件 10.0.0 弃用、11.0.0 移除 | A-7、P-3 |
| E-4 | "`dataExtractionRules` 自 API 30 起" | Android 12 / **API 31** 起；Android 11 及以下仍看 `allowBackup` 与 `fullBackupContent` | A-4 |
| E-5 | "域名叫 `sharepref`，还有 `sp:`/`db:`/`file:` 前缀" | 合法拼写是 `sharedpref`；`device_*` 变体用于 D2D；`sp:`/`db:`/`file:` 前缀在文档中不存在 | A-4 |
| E-6 | "`fullBackupContent=\"false\"` 是标准关法" | 布尔形式在平台属性里合法，但官方指南不描述其语义（查无官方口径）；改为只依赖 `allowBackup="false"` | A-1、A-5 |
| E-7 | "关掉 allowBackup 就彻底堵住 adb backup 与换机迁移" | `allowBackup="false"` 确实覆盖 adb 备份；但官方明确：部分厂商 ROM 上 D2D 文件迁移**无法**关闭 | A-1、A-10 |
| E-8 | "`<certificates src=\"network\">` 是可选信任锚" | 合法值只有 `system` / `user` / 原始资源，没有 `network` | A-3 |
| E-9 | "有 NSC 就够了" | NSC 自 API 24 生效；target ≤23 需再显式 `usesCleartextTraffic`；该属性在 target 38+ 被忽略，NSC 才是长期机制 | A-2、A-3 |
| E-10 | "`requestLegacyExternalStorage` 提供旧式存储行为" | target 11+ 系统直接忽略该标志，全部文件访问只来自 `MANAGE_EXTERNAL_STORAGE` | A-9 |
| E-11 | "`keytool -printcert -jarfile` 足以判定 APK 签名者" | 它读的是签名 JAR 块；无 v1 块时不输出内容，会让"不是 debug 签名"的判断静默走空 → CI 改用 `apksigner verify --print-certs` 并把"无输出"当失败 | A-13 |
| E-12 | "`-T ''` 只是没设密码" | `-T` 是 API token，`ApiToken != ""` 才启用校验，与 BasicAuth 的 `-u/-p` 无关；因此 `Bearer` 头是有效的鉴权手段 | S-1、S-2 |
| E-13 | "`-tags nosqlite` 会改变存储后端" | 上游构建脚本确实带这个 tag，但当前 `main` 没有对应 build guard，实际是 no-op | S-7 |
| E-14 | "`upload/download-artifact@v4` 是当前版本" | 最新为 v7.0.2，v4 已是历史大版本 | operations.md §6 |
| E-15 | "IPv6 内部地址判 `fd` 前缀即可" | `fc00::/7` 的本地分配位使其同时覆盖 `fc`/`fd` 两个前缀，只判 `fd` 会漏一半唯一本地地址 | A-12 |

### 8.3 未复核项（诚实声明）

1. `flutter.minSdkVersion` / `flutter.targetSdkVersion` 的实际数值未取到（本机无 Flutter 工具链）。
   §4.6 关于"API ≤23 需要显式 `usesCleartextTraffic`"的写法按"两种情况都成立"处理：
   加上该属性在任何 minSdk 下都无害。
2. `apksigner` 在 `ubuntu-latest` runner 上的具体路径布局未实测；
   CI 步骤做了 `ANDROID_HOME/build-tools/*/apksigner` 探测 + keytool 兜底 +
   "无输出即失败"三重处理，任一路径出问题都不会静默通过。
3. "v2/v3-only 签名的 APK 是否真的不含 v1 块"取决于 AGP 与 minSdk 组合，
   属推断（A-13），未逐字核对官方文句。
4. 所有代码层控制的**运行时效果**均未实测（原因见 hardening-changelog.md §5）。
   例外：`NetGuard` 与 `PathGuard` 是零依赖纯函数，已跑过仓库内断言集 [tool/guard_selfcheck.dart](file:///D:/qorder/quarklite/tool/guard_selfcheck.dart)（75 条）（首跑暴露 3 条 IP 别名绕过，已修 [net_guard.dart:92-93](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L92-L93)）；该断言集不依赖 Flutter，已可离线重跑；接入 CI 仍受 T-4 限制（缺 Flutter SDK）。
