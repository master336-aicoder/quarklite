# 文档索引

这里是 Quarklite 的完整文档。先说几件必须知道的事：

1. **本项目不是"设计先行"的产物**：需求与架构文档是**按当前代码实际行为反向写成的**（as-built）。文档里写的就是代码现在做的事；如果发现不一致，以代码为准并回来改文档。
2. **安全加固已过全量静态分析与单元测试**（2026-11-13 用 Flutter 3.50.0 / Dart 3.14.0 实跑）：`flutter analyze` **0 error**，且与基线 `5ba21ac` 逐项对比**新增问题 0 项**；`flutter test` 11 个用例通过；离线守卫断言 69 条全通过。全量分析暴露并修好了加固代码**自身**的 3 个缺陷——2 个编译错误 + 1 个让日志脱敏彻底失效的正则错误，详见 [hardening-changelog.md](hardening-changelog.md) §5.4/§5.5。同一天第二轮把**安装包也真打出来了**（见下面第 4 条），但**未真机、未跑 CI**。不要把加固后的代码直接当发版候选。
3. **别在 CI 里直接加 `dart format --set-exit-if-changed`**：基线 59 个 dart 文件里已有 49 个不符合 Dart 3.14 的 tall style（上游历史写法），要先做一次性全仓格式化才能开这道门。
4. **安装包确实打出来了，但一个都不能对外发**（2026-11-13 第二轮实跑）：Android 侧 1 个合包 APK + 3 个 split APK + 1 个 AAB，Windows 侧 1 个 Inno 安装包（静默安装→启动→引擎拉起→卸载全链路验证过）。**全部是 debug 签名**，Android 也没上真机。产物与 SHA-256、实际能用的工具链组合、镜像口径、以及"为什么 iOS/macOS/Linux 本机出不了包"都在 [build-and-env.md](build-and-env.md) §6；这一轮实测推翻了文档里 8 条旧说法（§6.8 勘误表），并留下 8 条构建侧待办（§7）。
5. **第三轮把 Android 包装进了模拟器，当场抓到 3 个只有运行时才现形的缺陷**（2026-11-21）：
   (1) 加固后的引擎鉴权**从来没通过**——客户端发 `Authorization: Bearer`，而 Gopeed 只认
   `X-Api-Token`，所有 REST 调用一律 401，Android/Windows 两端的下载全废；
   (2) 启动时的"发现新版本"弹窗取的是 `MaterialApp` 之上的 `context`，`Overlay.of` 返回 null，
   抛未捕获异常，这个对话框从来没成功显示过；
   (3) `UpdateChecker.currentVersion` 手写常量停在 1.3.2、pubspec 已是 1.3.3，
   修完 (2) 之后每个正式包每次启动都会误提示升级。
   三处**都已修复并在模拟器上复跑验证**（`flutter analyze` 仍 0 error，`flutter test` 12 个用例，
   新增的版本漂移断言经过反向验证），细节见 [hardening-changelog.md](hardening-changelog.md) §9
   与 [build-and-env.md](build-and-env.md) §6.10；测试做法固化在
   [../scripts/test_apk_emulator.sh](../scripts/test_apk_emulator.sh)。
   **仍未做**：任何网盘登录、任何真实下载、真机、arm64 分包、CI。
   一条命令出 exe + apk 的脚本见 [../scripts/build_all.sh](../scripts/build_all.sh)（用法在 build-and-env.md §6.2）。

## 该读哪一篇

| 你的问题 | 文档 |
|---|---|
| 这个产品到底做什么、各平台支持到什么程度、验收标准是什么 | [requirements.md](requirements.md) |
| 代码怎么分层？下载任务从点击到落盘经过哪些调用？凭据怎么存？引擎怎么启？ | [architecture.md](architecture.md) |
| 我要在本地把它跑起来 / 出包，需要哪些工具链、目录、文件 | [build-and-env.md](build-and-env.md) |
| 一条命令出 exe + apk 的脚本、以及怎么在模拟器上验包 | [../scripts/build_all.sh](../scripts/build_all.sh) + [../scripts/test_apk_emulator.sh](../scripts/test_apk_emulator.sh)，口径见 [build-and-env.md](build-and-env.md) §6.2 / §6.10 |
| 我是维护者：CI 要配什么 Secret、怎么发版、线上出问题了怎么查、哪些能力其实还没做 | [operations.md](operations.md) |
| 安全边界在哪、防的是什么威胁、某处为什么"没有做得更强" | [security-design.md](security-design.md) |
| 相对上游改了什么、为什么改、怎么回滚 | [hardening-changelog.md](hardening-changelog.md) |
| 迅雷接口怎么调（逆向来源、风控、直链、会员权益） | [xunlei_api.md](xunlei_api.md) |

建议的阅读顺序：**requirements → architecture → security-design → hardening-changelog → build-and-env → operations**。前三篇建立"是什么/怎么运转/防什么"，第四篇是变更事实，后两篇是动手时的操作手册。

## 各文档要点速览

- **[requirements.md](requirements.md)** — 三网盘能力矩阵（夸克 / 迅雷 / 123）、FR-1…FR-6 功能需求、平台矩阵、NFR-1…NFR-9 非功能需求、§5 约束与取舍、§6 验收标准 A1…A8。其中 A1/A5/A8 明确标注**未执行**。
- **[architecture.md](architecture.md)** — `pages → state → api/core → utils` 单向依赖；单例 `ChangeNotifier` + `ListenableBuilder`（没有引入 provider/riverpod）；三条数据流（下载调用链、Windows 引擎启动 8 步、Android MethodChannel `cfg`）；§3 讲 bootstrap 顺序为什么不能调整；§4 凭据链路；§6 依赖取舍（含 `file_picker` 为什么钉在 11.x）；§7 已知缺陷。
- **[security-design.md](security-design.md)** — 资产 A-1…A-7、边界 B-1…B-6（B-3 本地 IPC 是最弱的一环）、威胁登记 R-01…R-18 与当前状态、§4 八项控制深挖（每项含"为什么没做得更强"）、§5 待办 T-1…T-7、§6 遗留风险 X-1…X-9、§7 外部事实来源、§8 勘误表与未验证项。
- **[hardening-changelog.md](hardening-changelog.md)** — 11 项加固的「加固前 HEAD 行号 → 风险 → 加固后落点 → 兼容性 → 回滚」；§4 记录**评估后故意不改**的地方及原因；§5 验证状态（跑了什么、没跑什么）；§6 按主题独立回滚的命令；**§8 第二轮出包实跑对 §5.2 与 §2.3.4/§2.9 结论的更正**（原文按只增不改保留）；**§9 第三轮模拟器实跑改掉的 3 个缺陷**（本轮**动了代码**，回滚锚点 `c4d65d4`）。
- **[build-and-env.md](build-and-env.md)** — 工具链版本表、首次构建步骤、本地 release 签名、Windows `gopeed.exe` 打包条件、引擎源码完整性变量、CI 前置条件、静态检查；**§6 全平台出包实测（命令 / 产物 / SHA-256 / 镜像 / 许可 / 未验证项 / 勘误表 B-1…B-10）**，含 **§6.10 Android 模拟器实跑（三次运行的因果链与六条断言）**；**§7 构建侧待办 8 条**，含 **§7.1 第三轮对这些待办的状态更新**。
- **[operations.md](operations.md)** — 一次性 CI 配置清单、发版流程、§2.1 签名指纹必须留档（以及为什么要用 apksigner）、§2.2 加固断言对照、§3 回滚与 keystore 轮换（会破坏覆盖安装）、§4 故障排查表（日志位置、引擎启动失败、五类用户可见拦截语）、§5 事件响应、§6 诚实的能力缺口。

## 文档之外

- [../README.md](../README.md) — 面向使用者的入口（功能、APK 下载、工作原理、许可）。
- [../HANDOFF_MIUIX_REFACTOR.md](../HANDOFF_MIUIX_REFACTOR.md) — 上游留下的 Miuix 重构交接记录，**历史文档**，其中的部分结论已被当前代码推翻，只作背景阅读，不当作现状依据。
- [../LICENSE](../LICENSE) — GPL-3.0 全文（此前缺失，本次补齐，见 hardening-changelog §2.11）。

## 维护约定

- 文档里的每条代码结论都带 `文件#L行号`。**插入或删除代码行会让下游行号集体失效**，改完代码要重新核对引用；行号以加固后的当前工作区为准。
- 凡是没有实际跑过的验证，文档必须显式写"未执行/未验证"，不允许用"应该没问题"代替。
- 涉及外部事实（Android API 行为、Gopeed 鉴权语义、插件弃用版本、GitHub Actions 语义）的表述，改动时须重新联网核对原文，并把更正记进 `security-design.md` §8 勘误表。
