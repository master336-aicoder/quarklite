import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 轻量应用日志：追加写入 <文档目录>/quarklite/logs/app.log（Windows 可直接访问），
/// 超过 1MB 环形截断保留尾部，供排查下载引擎问题（我的 → 日志 → 复制）。
class AppLogger {
  AppLogger._();

  static final AppLogger I = AppLogger._();

  static const int _maxBytes = 1024 * 1024; // 日志文件上限 1MB
  static const int _keepBytes = 512 * 1024; // 截断后保留的尾部大小

  File? _file;
  bool _ready = false;
  bool _initDone = false;

  /// 初始化日志文件（失败时仅控制台输出，不影响主流程）
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/quarklite/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}/app.log');
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        final bytes = f.readAsBytesSync();
        f.writeAsBytesSync(bytes.sublist(bytes.length - _keepBytes));
      }
      _file = f;
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  void i(String tag, String msg) => _log('INFO', tag, msg);
  void w(String tag, String msg) => _log('WARN', tag, msg);
  void e(String tag, String msg) => _log('ERROR', tag, msg);

  void _log(String level, String tag, String msg) {
    // 集中脱敏：所有落盘与 print 的内容都过一遍，
    // 避免异常对象（Dio 异常串自带完整请求 URL 与 query）把凭据写进日志
    final line = '[${_ts()}] [$level] [$tag] ${LogRedact.text(msg)}';
    // ignore: avoid_print
    print(line);
    if (!_ready) return;
    try {
      _file!.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // 日志写入失败不影响主流程
    }
  }

  static String _ts() {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} '
        '${p(n.hour)}:${p(n.minute)}:${p(n.second)}.${p(n.millisecond, 3)}';
  }

  /// 读取最近 [maxLines] 行日志（供界面复制/展示）
  Future<String> readLog({int maxLines = 500}) async {
    final f = _file;
    if (f == null || !f.existsSync()) return '（暂无日志）';
    try {
      final lines = f.readAsLinesSync();
      if (lines.length <= maxLines) return lines.join('\n');
      return lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return '（日志读取失败）';
    }
  }

  /// 日志文件完整路径
  Future<String> logPath() async {
    final f = _file;
    if (f != null) return f.path;
    try {
      final docs = await getApplicationDocumentsDirectory();
      return '${docs.path}/quarklite/logs/app.log';
    } catch (_) {
      return '（未知）';
    }
  }
}

/// 日志脱敏工具。
///
/// 网盘直链的 query 携带签名参数（auth_key / sign / token 等），
/// 请求头携带会话凭据；日志文件落在应用文档目录且界面支持一键复制，
/// 原文写盘等于把凭据交给任何拿到日志的人。
class LogRedact {
  LogRedact._();

  static const _placeholder = '[已脱敏]';

  /// 凭据类键名：值一律替换掉。
  static final RegExp _kv = RegExp(
    r'''(?i)(["']?(cookie|set-cookie|authorization|x-captcha-token|x-client-secret|'''
    r'''access_token|refresh_token|api_token|token|auth_key|signature|sign|'''
    r'''pwd|password|secret|client_secret|creditkey|credit_key|__puus|__pus|__kp|'''
    r'''device_id|deviceId)["']?\s*[:=]\s*["']?)([^"'\\\s&,;}\]]+)''',
  );

  /// JSON 里的凭据字段：`"cookie":"xxx"` 之外还要兜住嵌套结构里的字符串值。
  static final RegExp _jsonStr = RegExp(
    r'''(?i)("(?:cookie|authorization|password|secret|token|creditkey|'''
    r'''access_token|refresh_token|auth_key)"\s*:\s*")((?:[^"\\]|\\.)*)(")''',
  );

  /// 任意文本脱敏（日志主入口）。
  static String text(String s) {
    if (s.isEmpty) return s;
    var out = s.replaceAllMapped(_kv, (m) => '${m.group(1)}$_placeholder');
    out = out.replaceAllMapped(_jsonStr, (m) => '${m.group(1)}$_placeholder${m.group(3)}');
    return out;
  }

  /// URL 脱敏：保留协议+主机+路径，丢弃整个 query（签名参数都在 query）。
  static String url(String raw) {
    if (raw.isEmpty) return raw;
    final q = raw.indexOf('?');
    if (q < 0) return raw;
    // 保留 # 片段前的锚点信息一般无意义，直接截到 ?
    return '${raw.substring(0, q)}?$_placeholder';
  }
}
