# Quarklite

夸克网盘不限速下载工具（Android / Windows / iOS）。Android 与 Windows 使用 [Gopeed](https://github.com/GopeedLab/gopeed)，iOS 使用基于 URLSession 的原生后台下载器，支持：

- 夸克网盘扫码登录 / Cookie 登录
- 网盘文件浏览、搜索（支持 AI 识别内容搜索，可直接搜照片内容词）
- 相册：自动扫描网盘内全部照片，网格浏览、全屏查看、一键下载
- 分享链接解析（提取码自动识别）、批量转存
- 批量下载（多选后一次加入队列）
- BT / 磁力链接下载（Android / Windows；iOS 暂不支持）
- **上传：多文件上传、文件夹上传（保持目录结构），实时查看进度/速度，支持取消与重试**

## 下载 APK

在 GitHub Actions 页面打开最新的构建（workflow run），下载 **quarklite-apk** 工件：

1. 打开仓库的 [Actions](https://github.com/zxeb/quarklite/actions) 页面
2. 点击最新一次成功的构建
3. 在 Artifacts 区域下载 `quarklite-apk`

> Fork 本仓库后 CI 会**故意失败**：release 签名材料改为从仓库 Secrets 读取，缺任一 Secret 即中止，不再回退到 debug 签名（回退会产生无法覆盖安装的包）。配置清单见 [docs/operations.md](docs/operations.md) §1。

## 工作原理

```
Flutter App (UI)
  ├── QuarkApi (Dart)  → drive.quark.cn / pan.quark.cn 夸克接口
  │      └─ 登录、文件列表、搜索、下载直链、分享解析、转存
  │      └─ 上传：upload/pre 预申请 → update/hash 秒传 → OSS 分片直传 → 合并 → finish
  ├── Gopeed 内核（Android / Windows）
  │      └─ 本地 REST API (127.0.0.1) 多线程下载 / BT 磁力
  └── iOS URLSession 后台下载器
         └─ 原生 URLSession 后台下载 / 暂停恢复 / 任务持久化
```

- 夸克直链本身走 CDN 不限速，配合 Gopeed 多连接分片达到满速
- 下载时自动携带直链对应的 Cookie / Referer / User-Agent
- 会话 Cookie（`__puus`）每 100 分钟自动刷新，避免下载 403
- 相册使用夸克返回的缩略图地址加载，点击可全屏查看并下载原图
- 上传按服务端分片大小顺序直传 OSS，先算 MD5/SHA1 走秒传校验；
  上传页实时显示进度、速度与状态，支持取消 / 重试 / 清除已完成

## 文档

设计、需求、安全与运维文档在 [`docs/`](docs/README.md)，索引与各文档职责见 [docs/README.md](docs/README.md)。动手前至少看两篇：

- 要构建 / 出包：[docs/build-and-env.md](docs/build-and-env.md)（工具链版本、`gopeed.exe` 放置、签名材料）
- 要改代码或发布：[docs/operations.md](docs/operations.md)（CI Secrets 一次性配置、发版流程、故障排查）

安全相关的现状与遗留风险：[docs/security-design.md](docs/security-design.md)；相对上游的加固改动与回滚：[docs/hardening-changelog.md](docs/hardening-changelog.md)。

> 注：网盘凭据（夸克 cookie、迅雷 token、123 令牌）只写入系统安全存储，不再落明文副本；备份与近设备转移已在 manifest 层禁用。

## 本地构建

```bash
# 1. 编译 Gopeed 内核（需要 Go + Android SDK）
bash scripts/build_libgopeed.sh

# 2. 构建 APK
flutter pub get
flutter build apk --release
```


### iOS

- 最低系统版本为 iOS 15。
- 下载文件保存在应用 Documents/Quarklite，可在“文件 → 我的 iPhone → Quarklite”中查看。
- 首次在 macOS 构建前运行 `flutter pub get` 和 `cd ios && pod install`，并在 Xcode 中配置自己的签名团队。
- iOS 使用原生后台直链下载，不支持 BT / 磁力链接。

## 许可

本项目基于 **GPL-3.0** 协议开源。内嵌的 Gopeed 下载引擎同样为 GPL-3.0。
商用前请确认 Gopeed 的商业授权要求。

> 夸克网盘接口为社区逆向，可能随官方更新失效，请合理使用。

---

# 关于作者

> 源码猿（master336）—— 一个把「踩过的坑」写成「别人脚下的路」的技术作者。

## 一句话介绍

**源码猿（master336）**，现就职于**某公司**，担任**高级技术架构师 / 产品售前专家**（腾讯云开发者社区认证）。长期深耕 Java 后端与分布式架构，近年将主要精力投向 **AI Agent、大模型私有化部署与工程化落地**，坚持用「能跑通、可复现、讲原理」的标准写每一篇文章。

## 身份与平台

| 平台 | 主页 | 身份 / 荣誉 |
| --- | --- | --- |
| CSDN 博客 | [master336.blog.csdn.net](https://master336.blog.csdn.net) | 人工智能领域**新星创作者**，原力等级 **298**，累计获赞 **461** 次、评论 **86** 条 |
| 腾讯云开发者社区 | [cloud.tencent.com/developer/user/1558800](https://cloud.tencent.com/developer/user/1558800) | 认证作者 · 某公司｜高级技术架构师、产品售前专家 |

## 技术视野

作者的写作版图横跨「从底层到应用、从传统工程到 AI 原生」的完整链路：

- **后端与架构**：Java、Spring / SpringBoot / SpringCloud、微服务架构、Maven
- **数据与存储**：MySQL、Redis、PostgreSQL、Greenplum、GaussDB、ETL 与大数据处理
- **运维与基础设施**：Linux、Nginx、操作系统、网络协议（TCP/UDP、HTTP/HTTPS、OSI 七层模型）、RabbitMQ
- **前端与客户端**：JavaScript、CSS、Vue.js、HTML、Android、微信小程序
- **AI 与智能化**：机器学习、NLP、图像处理、数据分析、AIGC
- **AI 工程化（近期主线）**：AI Agent 架构与多智能体协同、Ollama / ComfyUI 私有大模型部署、MCP 协议、Skill 资产化、大模型评测与上下文召回

## 写作风格

不同于「Hello World 式」的速食教程，作者的文章有三个鲜明特点：

1. **讲透原理** —— 不满足于告诉你「怎么做」，更在意解释「为什么这么做」；
2. **给出可落地的工程** —— 完整目录结构、核心代码、硬件选型、避坑清单，拿来就能改；
3. **有数据、有出处** —— 明确区分哪些是实测、哪些是预测、哪些不可横向比较，拒绝拍脑袋结论。

近期在腾讯云开发者社区连续产出《用 CodeArts 把一个自托管云相册真正做完》《Ollama 私有大模型部署与生态配置完全指南》《从零构建 AI Agent：一份写给工程师的深度开发指南》《一次讲透 HTTP 与 HTTPS》等长文，几乎保持日更节奏。

## 联系方式

- CSDN：[https://master336.blog.csdn.net](https://master336.blog.csdn.net)
- 腾讯云开发者社区：[https://cloud.tencent.com/developer/user/1558800](https://cloud.tencent.com/developer/user/1558800)

---

## ☕ 支持作者

看到这里，说明你已经陪我读到了文章的最后。

如果这些文字曾经帮你**少踩一个坑、少熬一个夜、少走一次弯路**，那它就是有价值的。写作这件事，靠的不只是兴趣，还有一台够用的机器、几个付费的实验环境、以及愿意花在查证与实测上的时间。

**你的每一份支持，都会变成下一篇文章里的一个真实实验、一次更深入的拆解。**

> 不用有压力 —— 一杯咖啡的钱，就足够让我开心很久。
> 当然，一个点赞、一条评论、一次转发，同样是最好的鼓励。

### 打赏渠道

<div align="center">

| 微信支付 | 支付宝 |
| :---: | :---: |
| ![微信支付二维码](images/wx.png) | ![支付宝二维码](images/zfb.jpg) |
| *推荐使用微信支付* | *支持信用卡 / 花呗付款* |

</div>

### 不打烊的支持方式

如果不方便打赏，下面这些同样珍贵：

- 👍 **点赞** —— 让更多人看到这篇内容
- ⭐ **收藏** —— 下次要用时能第一时间找到
- 💬 **评论** —— 你的问题常常是下一篇选题的起点
- 🔗 **转发** —— 把有用的东西分享给需要的朋友

感谢每一位读到这里的人。我们下篇文章见。

---

*Made with ❤️ by 源码猿（master336）*
