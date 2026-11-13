import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../api/netdisk123_client.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_logger.dart';
import '../../utils/net_guard.dart';

/// 123 网盘流量包充值页（内置 WebView，默认 0.5 元流量包）
class Netdisk123PayPage extends StatefulWidget {
  final String url;
  const Netdisk123PayPage({super.key, this.url = Netdisk123Client.kPayUrl});

  @override
  State<Netdisk123PayPage> createState() => _Netdisk123PayPageState();
}

class _Netdisk123PayPageState extends State<Netdisk123PayPage> {
  WebViewController? _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.bg)
      ..setNavigationDelegate(NavigationDelegate(
        // 充值流程会三跳到支付渠道，不能按域硬拦；
        // 这里只挡非 http(s) 协议（file://、自定义 scheme），并记录离开 123 域
        onNavigationRequest: (request) {
          if (NetGuard.parseHttp(request.url) == null) {
            AppLogger.I.w('netdisk123', '充值页拦截非 http(s) 导航: ${request.url}');
            return NavigationDecision.prevent;
          }
          if (!NetGuard.isTrustedPage(request.url, NetScope.pan123)) {
            AppLogger.I.i('netdisk123', '充值页离开 123 域: ${request.url}');
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) { if (mounted) setState(() => _loading = true); },
        onPageFinished: (_) { if (mounted) setState(() => _loading = false); },
      ))
      ..loadRequest(Uri.parse(widget.url));
    _controller = c;
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '流量包充值',
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: MiuixIcon(
              icon: Icons.arrow_back_ios_new_rounded,
              tint: colors.onSurfaceContainer,
              size: 20),
        ),
        actions: [
          MiuixIconButton(
            onPressed: () => _controller?.reload(),
            child: MiuixIcon(icon: Icons.refresh_rounded, tint: colors.primary),
          ),
        ],
      ),
      content: (padding) => Padding(
        padding: padding,
        child: Stack(
          children: [
            if (_controller != null) WebViewWidget(controller: _controller!),
            if (_loading)
              MiuixLinearProgressIndicator(
                progress: null,
                height: 2,
                colors: MiuixProgressIndicatorColors(
                  foregroundColor: colors.primary,
                  disabledForegroundColor: colors.primary,
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
