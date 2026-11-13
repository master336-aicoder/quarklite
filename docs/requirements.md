# Quarklite 需求规格说明

版本对应：`pubspec.yaml` `version: 1.3.3+1`（[pubspec.yaml:5](file:///D:/qorder/quarklite/pubspec.yaml#L5)）
文档状态：本文档为加固改造后的现状规格（as-built），描述代码实际实现的行为，而非最初的产品设想。

---

## 1. 产品定位

Quarklite 是一个跨平台的网盘下载客户端，把"官方网盘接口 + 本地多线程下载引擎"组合起来，
用多连接分片突破官方客户端的单连接限速。支持三家网盘：

| 网盘 | 登录方式 | 浏览 | 分享解析 | 转存 | 下载 | 上传 | BT/磁力 |
|---|---|---|---|---|---|---|---|
| 夸克 | 扫码 / Cookie | ✅ | ✅ | ✅ | ✅ | ✅ | Android/Windows |
| 迅雷 | OAuth（access/refresh token） | ✅ | ✅ | ✅ | ✅ | — | Android/Windows |
| 123 网盘 | 扫码 / 账号密码（多账号） | ✅ | ✅ | ✅ | ✅ | — | Android/Windows |

"—"表示该网盘在本项目中未实现该能力（迅雷、123 只有下载链路，没有上传实现）。

**接口性质**：三家接口均为社区逆向，不是官方开放 API。夸克侧的提示已在
[README.md:65](file:///D:/qorder/quarklite/README.md#L65) 声明"可能随官方更新失效"。
123 侧的逆向结论与实测记录写在
[lib/api/netdisk123_client.dart:276-300](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L276-L300)。
这决定了本项目的核心非功能约束：**接口可失效性高，必须内建诊断与降级路径**（见 §4 NFR-7）。

---

## 2. 功能需求

### FR-1 账号与登录态

- FR-1.1 夸克：支持扫码登录与 Cookie 粘贴登录两种方式，登录后拉取用户信息（昵称、头像、容量）。
  实现入口 [lib/pages/login/login_page.dart](file:///D:/qorder/quarklite/lib/pages/login/login_page.dart)，
  扫码流程 [lib/api/quark_auth.dart:10](file:///D:/qorder/quarklite/lib/api/quark_auth.dart#L10)。
- FR-1.2 夸克会话保活：`__puus` 类会话 Cookie 需要周期性刷新，否则长任务下载中途 403。
  定时器由 [lib/state/app_state.dart:80](file:///D:/qorder/quarklite/lib/state/app_state.dart#L80)
  的 `_startSessionRefresher()` 启动，间隔 100 分钟（README 描述见
  [README.md:36](file:///D:/qorder/quarklite/README.md#L36)）。
- FR-1.3 迅雷：`access_token` 约 7 天有效，到期前用 `refresh_token` 自动续期
  （[lib/state/xunlei_state.dart:154](file:///D:/qorder/quarklite/lib/state/xunlei_state.dart#L154)）。
  设备 ID 与登录凭据绑定，恢复登录态时由 `refresh_token` 派生，不能随机生成
  （[lib/state/xunlei_state.dart:53](file:///D:/qorder/quarklite/lib/state/xunlei_state.dart#L53)）。
- FR-1.4 迅雷风控：接口返回验证要求时，应用内 WebView 加载官方验证页，
  验证通过后取回新 `creditkey`（[lib/pages/login/xunlei_review_page.dart](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart)）。
- FR-1.5 123：支持多账号并存与切换，每个账号独立保存 token
  （[lib/state/netdisk123_state.dart:40](file:///D:/qorder/quarklite/lib/state/netdisk123_state.dart#L40)，账号管理页
  [lib/pages/drive/netdisk123_accounts_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_accounts_page.dart)）。
  token 过期后可用本机记住的密码自动重登
  （[lib/api/netdisk123_client.dart:319](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L319)）。
- FR-1.6 退出登录必须删除全部持久化凭据，且不留明文残留副本
  （[lib/state/app_state.dart:107](file:///D:/qorder/quarklite/lib/state/app_state.dart#L107)、
  [lib/state/xunlei_state.dart:129](file:///D:/qorder/quarklite/lib/state/xunlei_state.dart#L129)、
  [lib/state/netdisk123_state.dart:326](file:///D:/qorder/quarklite/lib/state/netdisk123_state.dart#L326)）。

### FR-2 文件浏览与检索

- FR-2.1 目录树浏览、进入子目录、返回上级、容量条
  （[lib/pages/drive/drive_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/drive_page.dart)、
  [lib/widgets/storage_capacity.dart](file:///D:/qorder/quarklite/lib/widgets/storage_capacity.dart)）。
- FR-2.2 夸克搜索支持 AI 内容检索（按照片内容词搜索）
  （[lib/pages/drive/search_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/search_page.dart)）。
- FR-2.3 相册：扫描网盘内全部图片，网格浏览、全屏查看、原图下载
  （[lib/pages/drive/album_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/album_page.dart)）。
- FR-2.4 移动到目录：跨网盘统一的目标目录选择器
  （[lib/pages/drive/move_target_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/move_target_page.dart)）。

### FR-3 分享链接

- FR-3.1 粘贴分享链接自动识别提取码、列出文件、按需转存到自己网盘再下载
  （[lib/pages/parse/parse_page.dart](file:///D:/qorder/quarklite/lib/pages/parse/parse_page.dart)、
  [lib/pages/parse/share_files_page.dart](file:///D:/qorder/quarklite/lib/pages/parse/share_files_page.dart)）。
- FR-3.2 123 分享页独立实现（分享域接口与登录态接口不同源）
  （[lib/pages/parse/netdisk123_share_page.dart](file:///D:/qorder/quarklite/lib/pages/parse/netdisk123_share_page.dart)）。
- FR-3.3 转存产生的路径必须落在下载目录内，目录名由服务端返回的文件名净化得到（见 FR-5.5）。

### FR-4 下载

- FR-4.1 单文件/批量多选入队，入队即返回失败原因（不静默丢任务）
  （[lib/state/download_service.dart:19](file:///D:/qorder/quarklite/lib/state/download_service.dart#L19)）。
- FR-4.2 每任务线程数可配，且受全局连接预算约束：单任务时可接近全部预算，
  批量任务自动分摊，避免打爆网络导致连接中断
  （[lib/state/app_state.dart:61-63](file:///D:/qorder/quarklite/lib/state/app_state.dart#L61-L63)）。
- FR-4.3 默认线程数按网盘分档：夸克 512、迅雷 64、123 为 128
  （[lib/state/app_state.dart:50-56](file:///D:/qorder/quarklite/lib/state/app_state.dart#L50-L56)）。
- FR-4.4 并发运行任务上限（Gopeed `maxRunning`，默认 4），超出排队
  （[lib/state/app_state.dart:59](file:///D:/qorder/quarklite/lib/state/app_state.dart#L59)）。
- FR-4.5 任务列表轮询刷新，支持暂停/恢复/删除（可选连同文件）/清除已完成/全部暂停
  （[lib/state/download_manager.dart:25-125](file:///D:/qorder/quarklite/lib/state/download_manager.dart#L25-L125)）。
- FR-4.6 磁力与 BT 链接直接入队，非磁力/BT 协议串一律拒绝
  （[lib/state/download_service.dart:146](file:///D:/qorder/quarklite/lib/state/download_service.dart#L146)）；
  iOS 不提供该能力（[README.md:58](file:///D:/qorder/quarklite/README.md#L58)）。
- FR-4.7 下载直链必须携带对应的 Cookie / Referer / User-Agent，否则 CDN 拒绝
  （[README.md:35](file:///D:/qorder/quarklite/README.md#L35)，实现见
  [lib/state/download_service.dart:94-101](file:///D:/qorder/quarklite/lib/state/download_service.dart#L94-L101)）。
- FR-4.8 123 免费账号的月度流量限制：产品选择**不在客户端做流量预判**，
  直接按通道取直链，由服务端错误码兜底；`traffic/check` 仅保留为诊断接口。
  理由与实测记录见 [lib/api/netdisk123_client.dart:276-288](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L276-L288)。
- FR-4.9 123 超额提示必须区分"整单被拒"与"提示语误导"，UI 不得直接展示
  `originalRemainTraffic`（大文件场景该值不可信，实测等于"文件大小 − 10GiB"）
  （[lib/api/netdisk123_client.dart:100-104](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L100-L104)）。
- FR-4.10 123 需要升级配额时进入应用内收银台页
  （[lib/pages/drive/netdisk123_pay_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_pay_page.dart)）。
- FR-4.11 后台下载：Android 使用前台服务保活，iOS 使用 URLSession 后台会话
  （[lib/core/gopeed/ios_background_download_client.dart](file:///D:/qorder/quarklite/lib/core/gopeed/ios_background_download_client.dart)）。

### FR-5 上传

- FR-5.1 多文件上传与文件夹上传（保持目录结构），实时进度/速度、取消、重试
  （[lib/state/upload_manager.dart:95](file:///D:/qorder/quarklite/lib/state/upload_manager.dart#L95)、
  [lib/pages/uploads/uploads_page.dart](file:///D:/qorder/quarklite/lib/pages/uploads/uploads_page.dart)）。
- FR-5.2 上传链路：`upload/pre` 预申请 → `update/hash` 秒传校验（MD5/SHA1）→ OSS 分片直传 → 合并 → `finish`
  （[README.md:27](file:///D:/qorder/quarklite/README.md#L27)，会话模型
  [lib/api/quark_models.dart:185](file:///D:/qorder/quarklite/lib/api/quark_models.dart#L185)）。
- FR-5.3 分片大小由服务端下发，客户端按顺序直传
  （[README.md:38](file:///D:/qorder/quarklite/README.md#L38)）。
- FR-5.4 同时上传任务数默认 1：一次一个文件，降低接口限流概率与内存占用
  （[lib/state/app_state.dart:68-69](file:///D:/qorder/quarklite/lib/state/app_state.dart#L68-L69)）。
- FR-5.5 文件夹上传时每一层目录名必须净化后拼接，禁止 `..` 逃出下载目录
  （[lib/utils/path_guard.dart:53](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L53)，
  调用点 [lib/pages/drive/drive_page.dart:467](file:///D:/qorder/quarklite/lib/pages/drive/drive_page.dart#L467) 等三处）。

### FR-6 设置与体验

- FR-6.1 可配置项：下载目录、夸克/迅雷/123 各自线程数、并发任务上限、连接预算、
  上传并行数、主题模式、窗口关闭行为（键名集中在
  [lib/state/app_state.dart:18-28](file:///D:/qorder/quarklite/lib/state/app_state.dart#L18-L28)）。
- FR-6.2 主题：system / light / dark 三档，跟随 Miuix 视觉体系
  （[lib/theme/app_theme.dart](file:///D:/qorder/quarklite/lib/theme/app_theme.dart)）。
- FR-6.3 Windows 单实例：重复启动聚焦已有窗口
  （[lib/utils/single_instance.dart](file:///D:/qorder/quarklite/lib/utils/single_instance.dart)）。
- FR-6.4 关闭窗口行为四态：`ask_once` / `minimize` / `exit` / `ask`
  （[lib/state/app_state.dart:65-66](file:///D:/qorder/quarklite/lib/state/app_state.dart#L65-L66)、
  [lib/utils/window_close.dart](file:///D:/qorder/quarklite/lib/utils/window_close.dart)）。
- FR-6.5 通知权限与存储权限按需申请
  （[lib/utils/permission.dart](file:///D:/qorder/quarklite/lib/utils/permission.dart)）。
- FR-6.6 检查更新：读取 GitHub Releases 最新版并提示，支持跳过该版本
  （[lib/core/update_checker.dart:20-97](file:///D:/qorder/quarklite/lib/core/update_checker.dart#L20-L97)）。

---

## 3. 平台矩阵与差异

| 能力 | Android | Windows | iOS |
|---|---|---|---|
| 下载引擎 | Gopeed（编译进 `libgopeed.aar`，FFI/MethodChannel 配置） | Gopeed（`gopeed.exe` 子进程 + 本机 REST） | 原生 URLSession 后台下载 |
| BT/磁力 | ✅ | ✅ | ❌ |
| 上传 | ✅（需存储权限） | ✅ | ❌（未实现） |
| 最低系统 | Android（`-androidapi 21` 编译内核，见 [scripts/build_libgopeed.sh:75](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh#L75)） | Windows 10+ | iOS 15（[README.md:55](file:///D:/qorder/quarklite/README.md#L55)） |
| 凭据存储 | Android：EncryptedSharedPreferences（MasterKey 在 KeyStore） | Windows：插件的 Windows 后端（作用域未复核，见安全设计 §6） | iOS：Keychain（默认 accessibility = WhenUnlocked） |

引擎启动、端口发现、鉴权 token、异常重启的完整流程属于架构范畴，见
[architecture.md](architecture.md) §4。

---

## 4. 非功能需求

- **NFR-1 凭据不落明文。** 所有登录凭据（cookie、access/refresh token、密码）只进系统安全存储；
  不允许再向 `SharedPreferences` 写可读副本。安全存储不可用时**不降级**，
  显式提示重新登录（[lib/core/credential_store.dart:6-20](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L6-L20)）。
- **NFR-2 凭据不随备份外流。** Android 关闭 `allowBackup`，并配置 `dataExtractionRules`
  排除全部域（[android/app/src/main/AndroidManifest.xml:36-39](file:///D:/qorder/quarklite/android/app/src/main/AndroidManifest.xml#L36-L39)）。
- **NFR-3 凭据只投递给声明过的目标。** 下载 URL 必须通过出网校验，
  内网/链路本地/云元数据地址一律拦截（[lib/utils/net_guard.dart:100-106](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L100-L106)）。
- **NFR-4 本机服务不可被第三方进程调用。** 本地引擎 REST 每次启动使用随机 token 鉴权
  （[lib/core/gopeed/gopeed_boot.dart:44-52](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L44-L52)）。
- **NFR-5 传输加密默认开启。** 生产构建不允许明文 HTTP 回流
  （[android/app/src/main/res/xml/network_security_config.xml](file:///D:/qorder/quarklite/android/app/src/main/res/xml/network_security_config.xml)）。
- **NFR-6 日志不泄密。** 凭据类字段与 URL query 在唯一出口统一脱敏
  （[lib/utils/app_logger.dart:46](file:///D:/qorder/quarklite/lib/utils/app_logger.dart#L46)）。
- **NFR-7 可诊断。** 引擎启动失败、接口异常、安全拦截都必须留下可定位的日志；
  123 提供独立诊断页（[lib/pages/drive/netdisk123_diag_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_diag_page.dart)），
  Gopeed 启动失败保留诊断摘要
  （[lib/core/gopeed/gopeed_boot.dart:22](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L22)）。
- **NFR-8 不可静默失败。** 安全策略拒绝任务时返回给用户可读的原因串，
  而不是抛异常或返回 null（[lib/state/download_service.dart:32-37](file:///D:/qorder/quarklite/lib/state/download_service.dart#L32-L37)）。
- **NFR-9 发布产物可验证。** CI 必须确认 APK 是发布签名而非 debug 签名，
  签名材料只来自 Secrets（[.github/workflows/build.yml](file:///D:/qorder/quarklite/.github/workflows/build.yml)）。

---

## 5. 约束与取舍（明确记录，不做掩饰）

1. **逆向接口不可控**：官方一次改动即可让登录/直链失效。项目内以"接口层独立成文件 +
   诊断页 + 版本提示"承担这个风险，不承诺可用性。
2. **`MANAGE_EXTERNAL_STORAGE` 保留**：文件夹上传需要遍历任意目录结构，
   去掉该权限会让 FR-5.1 的文件夹上传不可用。作为已知残余风险记录在安全设计 §6，
   并用路径净化（NFR 之外的第二道防线）限制其危害面
   （[android/app/src/main/AndroidManifest.xml:12](file:///D:/qorder/quarklite/android/app/src/main/AndroidManifest.xml#L12)、
   [lib/utils/path_guard.dart:53](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L53)）。
3. **厂商域白名单判直链被否决**：夸克/123 直链落在第三方 CDN 域，白名单会打断正常下载。
   改用"协议 + 内网目标 + 显式凭据范围"三重弱约束，取舍理由写在
   [lib/utils/net_guard.dart:7-12](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L7-L12)。
4. **WebView 只观测不拦截**：验证码跳转与 123 收银台必然跳出厂商域，硬性拦截会打断支付与验证。
   改为"非 http(s) 协议阻断 + 离开可信域时不注入凭据桥"
   （[lib/pages/login/xunlei_review_page.dart:61-91](file:///D:/qorder/quarklite/lib/pages/login/xunlei_review_page.dart#L61-L91)）。
5. **debug 签名兜底仅用于本机开发**：CI 用 Gradle 属性强制关闭该兜底
   （[android/app/build.gradle.kts](file:///D:/qorder/quarklite/android/app/build.gradle.kts)）。

---

## 6. 验收标准（加固后）

| # | 验收动作 | 期望结果 |
|---|---|---|
| A1 | 卸载重装前用文件管理器读 `shared_prefs` | 不存在任何 cookie/token/密码明文键 |
| A2 | 下载一个指向 `http://169.254.169.254/` 的直链 | 任务被拒绝，界面显示"下载地址指向内网/元数据地址" |
| A3 | 下载一个 `file://` 或 `javascript:` 串 | 被拒绝，不入队 |
| A4 | 构造文件名 `../../windows/win.ini` | 落盘名被净化，仍在下载目录内 |
| A5 | 端口扫描本机 Gopeed REST 并匿名调用 | 401/403；只有应用带本次会话 token 才能调用 |
| A6 | `grep -r "quark_cookie" 日志文件` | 只能看到脱敏占位，看不到真实 cookie 值 |
| A7 | 清空 CI 的 4 个签名 Secrets 后触发构建 | 构建在签名阶段失败，而不是产出 debug 签名 APK |
| A8 | 生产 APK 发起一次明文 HTTP 请求 | 连接被网络安全配置拒绝 |

其中 A2/A3/A4/A6/A7 已在代码层落实；A1/A5/A8 需要在真机与 CI 产物上实测，
本次交付**未执行**（原因与已做的静态检查见 [hardening-changelog.md](hardening-changelog.md) §5.2「未执行」）。
