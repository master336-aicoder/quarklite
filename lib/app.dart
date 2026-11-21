import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'core/credential_store.dart';
import 'core/gopeed/gopeed_boot.dart';
import 'core/notify/download_notifier.dart';
import 'core/update_checker.dart';
import 'pages/downloads/downloads_page.dart';
import 'pages/drive/drive_hub_page.dart';
import 'pages/me/me_page.dart';
import 'pages/parse/parse_page.dart';
import 'pages/uploads/uploads_page.dart';
import 'state/app_state.dart';
import 'state/download_manager.dart';
import 'state/netdisk123_state.dart';
import 'state/upload_manager.dart';
import 'state/xunlei_state.dart';
import 'theme/app_theme.dart';
import 'utils/app_logger.dart';
import 'widgets/miuix_common.dart';

class QuarkLiteApp extends StatefulWidget {
  final GlobalKey<NavigatorState>? navigatorKey;

  const QuarkLiteApp({super.key, this.navigatorKey});

  @override
  State<QuarkLiteApp> createState() => _QuarkLiteAppState();
}

class _QuarkLiteAppState extends State<QuarkLiteApp> {
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();
  bool _ready = false;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await AppLogger.I.init();
    AppLogger.I.i('app', '应用启动 bootstrap 开始');
    try {
      await DownloadNotifier.init().timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      await AppState.I.init().timeout(const Duration(seconds: 10));
    } catch (e) {
      _bootError = e.toString();
      AppLogger.I.e('app', 'AppState 初始化失败: $e');
    }
    // 迅雷/123 登录态恢复（非阻塞），完成后清理旧版本遗留在
    // SharedPreferences 中的明文凭据副本——改了写入逻辑不会让已落盘的
    // 明文自己消失，必须升级后显式清一次
    unawaited(_restoreSecondaryAccountsAndPurge());
    unawaited(_bootEngine());
    DownloadManager.I.startPolling();
    if (mounted) {
      setState(() => _ready = true);
      // 更新检查的弹窗需要根 Overlay，因此由 RootPage（在 Navigator 之下）自己发起，
      // 见 _RootPageState.initState。
    }
  }

  Future<void> _restoreSecondaryAccountsAndPurge() async {
    try {
      await XunleiState.I.init();
    } catch (e) {
      AppLogger.I.e('app', '迅雷登录态恢复失败: $e');
    }
    try {
      await Netdisk123State.I.init();
    } catch (e) {
      AppLogger.I.e('app', '123 网盘登录态恢复失败: $e');
    }
    // 恢复完成后再清理，避免与旧单账号键的迁移读取抢跑
    try {
      await CredentialStore.I.purgeLegacyPlaintext([
        ...AppState.legacyPlaintextKeys,
        ...XunleiState.legacyPlaintextKeys,
        ...Netdisk123State.legacyPlaintextKeys,
      ]);
      await Netdisk123State.I.purgeCredentialDuplicates();
    } catch (e) {
      AppLogger.I.e('app', '清理历史明文凭据失败: $e');
    }
  }

  Future<void> _bootEngine() async {
    try {
      await GopeedEngine.start();
      final client = GopeedEngine.client;
      final dir = await AppState.I.effectiveDownloadDir();
      await client.updateConfig(
        downloadDir: dir,
        maxRunning: AppState.I.maxRunning,
        connections: AppState.I.connectionBudget,
      );
    } catch (e) {
      AppLogger.I.e('app', '后台启动引擎失败: $e');
    }
  }

  @override
  void dispose() {
    DownloadManager.I.stopPolling();
    _snackbarHost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 全局 Snackbar：供 pages 通过 MiuixToast.show(context, msg) 调用
    SnackbarRegistry.globalHost = _snackbarHost;
    final mode = AppState.I.themeMode;
    final isDark = switch (mode) {
      'light' => false,
      'dark' => true,
      _ => null, // system：跟随系统亮度
    };
    return MiuixThemeController(
      colorSchemeMode: MiuixColorSchemeMode.system,
      isDark: isDark,
      textStyles: _appTextStyles,
      child: MaterialApp(
        title: 'Quarklite',
        debugShowCheckedModeBanner: false,
        navigatorKey: widget.navigatorKey,
        // Material 主题提供文字/转场基座 + 暗色模式；Miuix 配色由外层跟随系统
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        builder: (context, child) {
          // 全局兜底：所有 Text / EditableText 继承 decoration:none，彻底消除黄色下划线
          final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
          return DefaultTextStyle(
            style: base.copyWith(decoration: TextDecoration.none, decorationColor: Colors.transparent, decorationStyle: TextDecorationStyle.solid),
            child: MediaQuery(
              data: MediaQuery.of(context),
              child: Material(
                type: MaterialType.transparency,
                child: child!,
              ),
            ),
          );
        },
        home: _ready
            ? RootPage(snackbarHost: _snackbarHost)
            : _BootView(error: _bootError, snackbarHost: _snackbarHost),
      ),
    );
  }
}

/// 全局 Snackbar 注册表：让业务代码不依赖页面直接拿到 host。
/// 全局文本样式：跟随系统默认字体，不含任何装饰（下划线等），
/// 供 MiuixThemeController 注入，消除个别平台出现的默认下划线。
final MiuixTextStyles _appTextStyles = MiuixTextStyles(
  main: const TextStyle(fontSize: 17, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  paragraph: const TextStyle(fontSize: 17, height: 1.2, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  body1: const TextStyle(fontSize: 16, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  body2: const TextStyle(fontSize: 14, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  button: const TextStyle(fontSize: 17, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  footnote1: const TextStyle(fontSize: 13, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  footnote2: const TextStyle(fontSize: 11, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  headline1: const TextStyle(fontSize: 17, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  headline2: const TextStyle(fontSize: 16, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  subtitle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  title1: const TextStyle(fontSize: 32, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  title2: const TextStyle(fontSize: 24, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  title3: const TextStyle(fontSize: 20, decoration: TextDecoration.none, decorationColor: Colors.transparent),
  title4: const TextStyle(fontSize: 18, decoration: TextDecoration.none, decorationColor: Colors.transparent),
);

class SnackbarRegistry {
  SnackbarRegistry._();
  static MiuixSnackbarHostState globalHost = MiuixSnackbarHostState();
}

class _BootView extends StatelessWidget {
  final String? error;
  final MiuixSnackbarHostState snackbarHost;

  const _BootView({this.error, required this.snackbarHost});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: MiuixScaffold(
        snackbarHost: MiuixSnackbarHost(state: snackbarHost),
        content: (_) => Center(
          child: error == null
              ? const MiuixCircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MiuixIcon(
                        icon: Icons.error_outline,
                        tint: AppColors.red,
                        size: 48),
                    const SizedBox(height: 16),
                    MiuixText('下载引擎启动失败',
                        fontSize: 16, fontWeight: FontWeight.w600),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: MiuixText(
                        error!,
                        textAlign: TextAlign.center,
                        color: MiuixTheme.of(context).colors.onSurfaceSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class RootPage extends StatefulWidget {
  final MiuixSnackbarHostState snackbarHost;

  const RootPage({super.key, required this.snackbarHost});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _index = 0;

  static const _pages = [
    ParsePage(),
    DriveHubPage(),
    DownloadsPage(),
    UploadsPage(),
    MePage(),
  ];

  @override
  void initState() {
    super.initState();
    // 只有本页面在 Navigator/Overlay 之下，弹层才拿得到根 Overlay；
    // 用 QuarkLiteApp 的 context 会让 Overlay.of 返回 null。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(UpdateChecker.checkAndPrompt(context));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: MiuixScaffold(
        snackbarHost: MiuixSnackbarHost(state: widget.snackbarHost),
        bottomBar: _MiuixBottomBar(
          index: _index,
          onTap: (i) => setState(() => _index = i),
        ),
        content: (_) => _AnimatedPageView(index: _index, children: _pages),
      ),
    );
  }
}

class _AnimatedPageView extends StatelessWidget {
  final int index;
  final List<Widget> children;

  const _AnimatedPageView({required this.index, required this.children});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          AnimatedOpacity(
            opacity: i == index ? 1 : 0,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: i == index ? Offset.zero : const Offset(0, 0.04),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: i != index,
                child: TickerMode(
                  enabled: i == index,
                  child: children[i],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ActiveDot extends StatelessWidget {
  const _ActiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: AppColors.red,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.bottomBar, width: 1.5),
      ),
    );
  }
}

class _MiuixBottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;

  const _MiuixBottomBar({required this.index, required this.onTap});

  Widget _tabIcon(int i, IconData icon) {
    if (i != 3) return MiuixIcon(icon: icon, size: 26);
    return ListenableBuilder(
      listenable: UploadManager.I,
      builder: (context, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          MiuixIcon(icon: icon, size: 26),
          if (UploadManager.I.hasActive)
            const Positioned(
              right: -4,
              top: -4,
              child: _ActiveDot(),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.link_rounded, '解析'),
      (Icons.folder_rounded, '网盘'),
      (Icons.download_rounded, '下载'),
      (Icons.upload_rounded, '上传'),
      (Icons.person_outline_rounded, '我的'),
    ];
    return MiuixNavigationBar(
      children: [
        for (var i = 0; i < items.length; i++)
          MiuixNavigationBarItem(
            selected: i == index,
            onPressed: () => onTap(i),
            icon: _tabIcon(i, items[i].$1),
            label: items[i].$2,
          ),
      ],
    );
  }
}
