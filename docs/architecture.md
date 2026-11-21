# Quarklite 架构设计

适用版本：1.3.3+1（[pubspec.yaml:5](file:///D:/qorder/quarklite/pubspec.yaml#L5)）
运行时：Flutter stable / Dart 3（`environment` 约束见
[pubspec.yaml:7-8](file:///D:/qorder/quarklite/pubspec.yaml#L7-L8)）

---

## 1. 分层

```
lib/
  main.dart          进程入口：绑定初始化、单实例锁、窗口关闭钩子、runApp
  app.dart           应用根：bootstrap 编排、主题、路由与底部导航
  api/               网盘协议层（纯 HTTP + 数据模型，不含 UI 状态）
  core/              基础设施：下载引擎、凭据存储、通知、更新检查
  state/             应用状态层（ChangeNotifier 单例）+ 业务编排服务
  pages/             界面层（按 网盘/功能 分目录）
  widgets/           复用组件
  utils/             无状态工具（含安全守卫 net_guard / path_guard / 日志脱敏）
  theme/             配色与排版
```

依赖方向自上而下单向：`pages → state → api/core → utils`。
`api/` 不引用 `state/`，`core/` 不引用 `pages/`——这条约束让协议层可以脱离 UI 单独调试
（123 的诊断页正是这样复用 `api/` 的：
[lib/pages/drive/netdisk123_diag_page.dart](file:///D:/qorder/quarklite/lib/pages/drive/netdisk123_diag_page.dart)）。

### 1.1 状态管理：无第三方容器

项目**不使用** `provider` / `riverpod`。每个状态类是自带 `ChangeNotifier` 的单例，
界面用 `ListenableBuilder` 或显式 `addListener` 订阅：

- 单例入口：`AppState.I`、`XunleiState.I`、`Netdisk123State.I`、`DownloadManager.I`、
  `UploadManager.I`（[lib/state/app_state.dart:36-37](file:///D:/qorder/quarklite/lib/state/app_state.dart#L36-L37)，
  同一模式复制在各状态类中）。
- 订阅点示例：[lib/app.dart:331](file:///D:/qorder/quarklite/lib/app.dart#L331)、
  [lib/pages/downloads/downloads_page.dart:47](file:///D:/qorder/quarklite/lib/pages/downloads/downloads_page.dart#L47)、
  [lib/pages/drive/drive_page.dart:66](file:///D:/qorder/quarklite/lib/pages/drive/drive_page.dart#L66)。

代价是状态类全局可及、单元测试需要手工重置单例；收益是启动路径没有依赖注入容器，
bootstrap 顺序完全显式（见 §3）。

### 1.2 各层职责

| 层 | 模块 | 职责 |
|---|---|---|
| api | [lib/api/quark_client.dart:36](file:///D:/qorder/quarklite/lib/api/quark_client.dart#L36) `QuarkClient` | 夸克登录态、列表、搜索、直链、分享、转存、上传会话 |
| api | [lib/api/xunlei_client.dart:114](file:///D:/qorder/quarklite/lib/api/xunlei_client.dart#L114) `XunleiClient` | 迅雷 OAuth、云盘列表、直链、creditkey 风控 |
| api | [lib/api/netdisk123_client.dart:289](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L289) `Netdisk123Client` | 123 扫码/密码登录、多账号、直链通道、签名参数 |
| api | [lib/api/quark_models.dart](file:///D:/qorder/quarklite/lib/api/quark_models.dart) | 用户/文件/分享/直链/上传会话的数据模型 |
| core | [lib/core/credential_store.dart:25](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L25) `CredentialStore` | 凭据持久化**唯一入口**，只对接插件安全存储，无明文降级 |
| core | [lib/core/gopeed/gopeed_boot.dart:15](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L15) `GopeedEngine` | 引擎生命周期：启动、端口发现、鉴权、自愈重启、残留进程清理 |
| core | [lib/core/gopeed/download_client.dart:6](file:///D:/qorder/quarklite/lib/core/gopeed/download_client.dart#L6) `DownloadClient` | 下载任务的抽象接口（create/list/pause/resume/remove/updateConfig） |
| core | [lib/core/gopeed/gopeed_client.dart:10](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_client.dart#L10) | 接口实现：Gopeed REST（Android/Windows） |
| core | [lib/core/gopeed/ios_background_download_client.dart](file:///D:/qorder/quarklite/lib/core/gopeed/ios_background_download_client.dart) | 接口实现：URLSession 后台下载（iOS） |
| core | [lib/core/notify/](file:///D:/qorder/quarklite/lib/core/notify) | 下载/上传的进度通知与 Android 16+ Live Updates |
| state | [lib/state/download_service.dart:12](file:///D:/qorder/quarklite/lib/state/download_service.dart#L12) `DownloadService` | 业务编排：取直链 → 组装头 → 安全校验 → 入队 |
| state | [lib/state/download_manager.dart:10](file:///D:/qorder/quarklite/lib/state/download_manager.dart#L10) | 任务列表轮询与操作代理 |
| state | [lib/state/upload_manager.dart:95](file:///D:/qorder/quarklite/lib/state/upload_manager.dart#L95) | 上传队列、分片、秒传、进度聚合 |
| utils | [lib/utils/net_guard.dart:30](file:///D:/qorder/quarklite/lib/utils/net_guard.dart#L30) `NetGuard` | 出网目标与凭据投递范围校验 |
| utils | [lib/utils/path_guard.dart:6](file:///D:/qorder/quarklite/lib/utils/path_guard.dart#L6) `PathGuard` | 文件名净化与穿越防护 |
| utils | [lib/utils/app_logger.dart](file:///D:/qorder/quarklite/lib/utils/app_logger.dart) | 日志唯一出口 + `LogRedact` 脱敏 |

`DownloadClient` 是**唯一**跨平台的下载抽象：`GopeedClient` 与 iOS 实现同源接口，
所以 `state/` 与 `pages/` 完全不感知平台差异（[lib/core/gopeed/download_client.dart:6-33](file:///D:/qorder/quarklite/lib/core/gopeed/download_client.dart#L6-L33)）。

---

## 2. 关键数据流

### 2.1 下载一次夸克文件

```
drive_page (多选)
  → DownloadService.downloadQuarkFile()            state/download_service.dart:116-129
      → QuarkClient 取直链 + Cookie/Referer/UA
      → DownloadService.addDirectUrl(credentialScope: NetScope.quark)   :19 / :128
          ① NetGuard.credentialRejection(url, scope)   —— 不过就 return 原因串
          ② GopeedEngine.ensureStarted()
          ③ AppState.effectiveDownloadDir() + 连接预算分摊
          ④ DownloadClient.create(path, name, url, headers)
              · PathGuard.traversalRejection(path)     core/gopeed/gopeed_client.dart:51
              · PathGuard.safeName(name)               core/gopeed/gopeed_client.dart:53
              · X-Api-Token: <会话 token>             core/gopeed/gopeed_client.dart:23
  → DownloadManager 轮询刷新 UI                      state/download_manager.dart:44
```

设计要点：**凭据是显式参数**，不是隐式全局。`addDirectUrl` 把
`credentialScope` 声明为 required（[lib/state/download_service.dart:23](file:///D:/qorder/quarklite/lib/state/download_service.dart#L23)），
新增调用点在编译期就必须回答"这份凭据属于哪家"，
否则拿不到 `NetScope.none` 之外的凭据（[lib/state/download_service.dart:101](file:///D:/qorder/quarklite/lib/state/download_service.dart#L101)）。

### 2.2 引擎启动（Windows）

```
GopeedEngine.start()                     core/gopeed/gopeed_boot.dart:79
  └ _doStart() 按平台分派                :94-109
      └ _startWindows()                  :181
          ① _findGopeedExe()             :191/:300  只接受受控目录绝对路径
          ② _winExeDir = exe 所在目录     :197      供后续定向清理
          ③ _stopWindowsProcess()        :205      杀残留（按 _winExeDir 过滤）
          ④ Process.start(exe, [-A 127.0.0.1, -P 0, -T <随机 token>, -d <storageDir>])  :207-212
          ⑤ 300ms 存活确认               :216-225  （杀软立刻杀掉时快速失败）
          ⑥ _readServerPort(stdout)      :226/:313 解析实际监听端口
          ⑦ GopeedClient('http://127.0.0.1:$port', apiToken: _token)  :230
          ⑧ exitCode 回调 → 标记失效 + _autoRestart()  :238-262
```

自愈与保护机制：
- 并发 `start()` 共享同一次启动，避免多个流程互相杀掉对方刚拉起的进程
  （[lib/core/gopeed/gopeed_boot.dart:78-84](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L78-L84)）。
- 第 2 次尝试前删除 `gopeed` 存储目录：bolt 数据库损坏时宁可丢任务记录也要恢复可用性
  （[lib/core/gopeed/gopeed_boot.dart:278-286](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L278-L286)）。
- 连续快速退出（10 秒内）累计 5 次后停止自动重启，交给周期轮询
  （[lib/core/gopeed/gopeed_boot.dart:246-259](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L246-L259)）。
- stdout/stderr 必须持续消费，否则缓冲写满会阻塞引擎进程；
  单订阅流二次 `listen()` 会抛 `Bad state` —— 这条约束写进了注释
  （[lib/core/gopeed/gopeed_boot.dart:263-265](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L263-L265)）。

### 2.3 引擎启动（Android）

Dart 侧不拉进程，而是通过 `MethodChannel('quarklite.com/gopeed')` 调用编译进 APK 的
`libgopeed.aar`（Gopeed 的 Go 内核经 `gomobile bind` 打成 AAR）：

- 配置体：`{network, address: 127.0.0.1:0, storage: bolt, storageDir, refreshInterval: 350, apiToken}`
  （[lib/core/gopeed/gopeed_boot.dart:134-141](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L134-L141)）。
- `start` 返回实际端口，Dart 侧据此构造 `GopeedClient`
  （[lib/core/gopeed/gopeed_boot.dart:151-157](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L151-L157)）。
- 原生侧处理器在 [android/app/src/main/kotlin/com/quarklite/quarklite/MainActivity.kt:36-58](file:///D:/qorder/quarklite/android/app/src/main/kotlin/com/quarklite/quarklite/MainActivity.kt#L36-L58)，
  该 channel 绑定到 `makeBackgroundTaskQueue()`，因此引擎启动跑在独立 isolate，
  不阻塞 UI。
- `refreshInterval: 350` 是任务状态轮询间隔（毫秒），决定了下载页速度刷新的粒度。

### 2.4 iOS

没有 Gopeed，改用原生 `URLSession` 后台会话实现同一个 `DownloadClient` 接口
（[lib/core/gopeed/ios_background_download_client.dart](file:///D:/qorder/quarklite/lib/core/gopeed/ios_background_download_client.dart)）。
因此 iOS 不具备 BT/磁力能力，也不受本地 REST 鉴权改造影响；
但它同样经过 `PathGuard` 的路径与文件名校验
（[lib/core/gopeed/ios_background_download_client.dart:107-110](file:///D:/qorder/quarklite/lib/core/gopeed/ios_background_download_client.dart#L107-L110)）。

---

## 3. 启动编排（bootstrap）

[lib/app.dart:44-67](file:///D:/qorder/quarklite/lib/app.dart#L44-L67) 的顺序是有意的：

1. `AppLogger.init()` —— 必须最先，后续所有分支都要能落日志。
2. `DownloadNotifier.init()`（10 秒超时，失败吞掉）—— 通知渠道不可用不影响主功能。
3. `AppState.init()`（10 秒超时）—— 读设置 + 从安全存储恢复夸克 cookie + 刷新会话 + 拉用户信息；
   失败记 `_bootError` 但不 crash
   （[lib/state/app_state.dart:75-83](file:///D:/qorder/quarklite/lib/state/app_state.dart#L75-L83)）。
4. `unawaited(_restoreSecondaryAccountsAndPurge())` —— 迅雷、123 依次恢复登录态，
   **全部完成后**才清理旧版本遗留在 SharedPreferences 的明文凭据；
   先恢复后清理是为了不和迁移读取抢跑
   （[lib/app.dart:69-91](file:///D:/qorder/quarklite/lib/app.dart#L69-L91)）。
5. `unawaited(_bootEngine())` —— 引擎后台拉起，同时把下载目录、`maxRunning`、
   连接预算一次性写进引擎配置
   （[lib/app.dart:93-106](file:///D:/qorder/quarklite/lib/app.dart#L93-L106)）。
6. `DownloadManager.startPolling()`，然后 `setState(_ready = true)`
   （[lib/app.dart:61-66](file:///D:/qorder/quarklite/lib/app.dart#L61-L66)）。
   **更新检查不在这里发起**：`_QuarkLiteAppState` 的 `context` 位于 `MaterialApp` 之上，
   没有 `Overlay` 祖先，`Overlay.of(context, rootOverlay: true)` 会返回 null 并抛
   `Null check operator used on a null value`（2026-11-21 模拟器实测到的崩溃）。
   改由 `RootPage`（在 Navigator 之下）在自己的 `initState` 首帧回调里发起，
   见 [lib/app.dart:247-254](file:///D:/qorder/quarklite/lib/app.dart#L247-L254)。

`main()` 在 `runApp` 之前做两件事（[lib/main.dart:14-27](file:///D:/qorder/quarklite/lib/main.dart#L14-L27)）：
Android 前台服务通信端口初始化、Windows 单实例锁。单实例锁的架构意义写明在注释里：
**防止两个实例的引擎进程互相 taskkill 形成死循环**
（[lib/main.dart:19](file:///D:/qorder/quarklite/lib/main.dart#L19)）。

---

## 4. 凭据链路（加固后的唯一路径）

```
pages/state 层                    CredentialStore                     平台安全存储
  quark cookie   ─┐
  xunlei access  ─┤   read/write/delete        ──→  Android: EncryptedSharedPreferences
  xunlei refresh ─┤   （无明文降级）                    （MasterKey 由 KeyStore 持有）
  123 token/pwd  ─┘                                   iOS: Keychain（默认 unlocked）
  purgeLegacyPlaintext(keys) ──→ SharedPreferences    Windows: 插件 Windows 后端
                                   （仅删除，不写入凭据）
```

- 入口只有一个类：全仓库对 `FlutterSecureStorage` 的引用只在
  [lib/core/credential_store.dart:1](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L1)。
- 构造参数逐字沿用上游写法 `AndroidOptions(encryptedSharedPreferences: true)`
  （[lib/core/credential_store.dart:30](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L30)，
  对照 `git show 5ba21ac:lib/state/app_state.dart` 第 39-41 行）。
  原因：现网安装包的既有值就是这种格式写的，插件两种模式**共用同一个
  `FlutterSecureStorage` 文件名**，改参数会让老设备读不出原凭据（升级即全员掉登录），
  而不是"换一种更安全的存储"。
- 加固真正消灭的是**第二份可读明文副本**（`shared_preferences` 里的 cookie/token/密码），
  安全存储那一层本来就已加密。
- `write('')` 语义等价删除（[lib/core/credential_store.dart:53](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L53)），
  保留各状态层原有"空值不覆盖"的调用习惯。
- `secureAvailable` 是**读写失败的可见性通道**：安全存储异常时不静默返回空串，
  调用方据此提示重新登录（[lib/core/credential_store.dart:35](file:///D:/qorder/quarklite/lib/core/credential_store.dart#L35)、
  [lib/state/app_state.dart:92-94](file:///D:/qorder/quarklite/lib/state/app_state.dart#L92-L94)）。
- 非凭据的普通设置与用户资料缓存仍留在 SharedPreferences
  （[lib/state/app_state.dart:116-130](file:///D:/qorder/quarklite/lib/state/app_state.dart#L116-L130)）：
  区分点是"能否直接换回账号控制权"。

---

## 5. 安全控制点在架构中的位置

| 控制 | 所在层 | 为什么放这里 |
|---|---|---|
| 出网/凭据范围校验 | `state/download_service.dart` | 这是凭据与 URL 第一次同时出现的唯一位置 |
| 文件名与路径净化 | `core/gopeed/*_client.dart` + `pages` 拼接点 | 落盘前最后一道，跨平台实现各拦一次 |
| 引擎 REST 鉴权 | `core/gopeed/gopeed_boot.dart` | token 与进程生命周期同源，避免持久化 |
| 日志脱敏 | `utils/app_logger.dart` 单出口 | Dio 异常串里带完整 URL，只有出口统一处理才不漏 |
| WebView 导航与凭据桥 | `pages/**`（两处 WebView） | 只有页面层知道"这个页面该不该拿到凭据" |
| 传输加密与备份策略 | `android/app/src/main/AndroidManifest.xml` + `res/xml/` | 系统级开关，代码无法替代 |

细节与威胁模型见 [security-design.md](security-design.md)。

---

## 6. 外部依赖与取舍

核心依赖（[pubspec.yaml](file:///D:/qorder/quarklite/pubspec.yaml)）：

| 包 | 用途 | 备注 |
|---|---|---|
| `dio ^5.7.0` | 全部网盘 HTTP | 异常串含 URL，因此需要日志脱敏 |
| `flutter_secure_storage ^9.2.2` | 凭据 | 唯一凭据出口，见 §4 |
| `shared_preferences ^2.3.2` | 非凭据设置 | 加固后不再承载凭据 |
| `webview_flutter ^4.14.0` + `webview_flutter_windows` | 风控验证、收银台 | 受导航与注入约束 |
| `background_downloader ^9.5.8` | iOS 后台下载底座 | 与 iOS `DownloadClient` 实现配套 |
| `flutter_foreground_task ^8.2.0` | Android 保活 | 下载中前台服务 |
| `file_picker ^11.0.3` | 上传选择 | **版本被有意锁在 11.x**：12.x 需要 `win32 ^6.3`，与 `flutter_secure_storage 9.2.2` 冲突，注释见 [pubspec.yaml](file:///D:/qorder/quarklite/pubspec.yaml) |
| `flutter_miuix ^1.1.1` | 视觉体系 | 全局主题与组件基座 |

`libgopeed.aar` 不在仓库里长期保存，由 CI 每次从 Gopeed 源码编译
（[scripts/build_libgopeed.sh](file:///D:/qorder/quarklite/scripts/build_libgopeed.sh)），
版本与提交固定方式见 [build-and-env.md](build-and-env.md) §3。

---

## 7. 已知架构局限

1. **单例状态无依赖注入**，跨状态协作靠调用顺序约束（§3 第 4 步的"先恢复后清理"），
   改动 bootstrap 顺序容易引入竞态。
2. **Windows 的 `gopeed.exe` 要构建方自备**：[windows/runner/CMakeLists.txt:43-50](file:///D:/qorder/quarklite/windows/runner/CMakeLists.txt#L43-L50)
   只有在 `windows/resources/gopeed.exe` 存在时才把它拷进产物目录，而仓库不带该二进制、CI 也不编它，
   所以"直接 clone 构建出来的 Windows 包"运行期仍会报"未找到 gopeed.exe"（失败提示见
   [lib/core/gopeed/gopeed_boot.dart:192-196](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L192-L196)）；编法与实测见 [build-and-env.md](build-and-env.md) §6.2。这仍是可用性缺口，也是 §2.2 ① 必须限制查找目录的原因。
3. **接口层与业务层耦合于逆向细节**：123 的签名参数、`cashierEnv` 语义等实测结论
   只存在于代码注释（[lib/api/netdisk123_client.dart:355-375](file:///D:/qorder/quarklite/lib/api/netdisk123_client.dart#L355-L375)），
   官方一旦变更需要重新逆向，没有契约测试兜底。
4. **任务态依赖 bolt 单写者**：引擎残留进程会持锁，因此启动前必须清理残留
   （[lib/core/gopeed/gopeed_boot.dart:75](file:///D:/qorder/quarklite/lib/core/gopeed/gopeed_boot.dart#L75)），
   这个清理逻辑是 Windows 平台特有四舍五入，不能简单移植。
5. **命令式弹层只认"页面级 context"，这个约束此前没有写在任何地方**（2026-11-21 模拟器实测暴露）：
   `MiuixOverlayPanel.show` 内部用 `Overlay.of(context, rootOverlay: true)`
   （[lib/widgets/miuix_common.dart:52](file:///D:/qorder/quarklite/lib/widgets/miuix_common.dart#L52)），
   而 `findRootAncestorStateOfType` **不含自身**，所以两类 context 必然拿到 null 并抛未捕获异常：
   `QuarkLiteApp`/`MaterialApp` 之上的 context（已修，§3 第 6 步），以及
   `navigatorKey.currentContext`——Navigator 自己的 Overlay 是它的**子**代，不是祖先。
   后者仍留在 [lib/utils/window_close.dart:67-74](file:///D:/qorder/quarklite/lib/utils/window_close.dart#L67-L74)：
   关闭窗口选"询问"时，Windows 上会走这条路径。**本轮未修、也未在 Windows 上实测**
   （需要人工点 X 且把行为设成 ask），修法是把 `MiuixOverlayPanel` 的入参从 `BuildContext`
   换成 `OverlayState`（`navigatorKey.currentState!.overlay`），或改用 `Navigator.push` 路由。
   在此之前，Windows 的"关闭时询问"应视为**未验证且有已知崩溃风险**的能力。
