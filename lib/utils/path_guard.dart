/// 文件名与目录路径防护。
///
/// 下载任务的 name/path 来自网盘 API 响应或分享链接内容，属外部输入；
/// 加固前直接透传给下载引擎，配合 Android 全部文件访问权限，
/// 恶意目录名（`../../`）理论上可越出下载目录写文件。
class PathGuard {
  PathGuard._();

  /// 保留的 Windows 非法字符替换为下划线；Unix 下 `/` 同样替换。
  static const int _maxNameLength = 200;

  /// 清洗单个文件名/目录名：剔除路径分隔符、上级引用、控制字符与保留名。
  static String safeName(String raw) {
    var s = raw.replaceAll('\\', '_');
    s = s.replaceAll('/', '_');
    s = s.replaceAll(':', '_');
    // 控制字符
    s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    s = s.trim().replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty || s == '.' || s == '..') return 'unnamed';
    // Windows 保留设备名
    const reserved = {
      'con', 'prn', 'aux', 'nul',
      'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
      'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
    };
    final stem = s.split('.').first.toLowerCase();
    if (reserved.contains(stem)) s = '_$s';
    if (s.length > _maxNameLength) {
      // 保留扩展名，截断主体
      final dot = s.lastIndexOf('.');
      s = dot > 0 && s.length - dot <= 12
          ? '${s.substring(0, _maxNameLength - (s.length - dot))}${s.substring(dot)}'
          : s.substring(0, _maxNameLength);
    }
    return s;
  }

  /// 校验拼接了相对路径的目标目录：任一分段不得是 `..`。
  ///
  /// 下载目录本身可能含符号链接，这里只挡字符串层面的越界，
  /// 返回非 null 表示拒绝原因。
  static String? traversalRejection(String path) {
    if (path.isEmpty) return '下载路径为空';
    final normalized = path.replaceAll('\\', '/');
    for (final seg in normalized.split('/')) {
      if (seg == '..') return '下载路径含上级引用，已拦截: $path';
    }
    return null;
  }

  /// 安全拼接：`base` 保持原样，`rel` 逐段清洗后再拼，保证不越出 `base`。
  static String joinUnder(String base, String rel) {
    if (rel.isEmpty) return base;
    final normalized = rel.replaceAll('\\', '/');
    final parts = <String>[];
    for (final seg in normalized.split('/')) {
      if (seg.isEmpty || seg == '.' || seg == '..') continue;
      parts.add(safeName(seg));
    }
    if (parts.isEmpty) return base;
    return '$base/${parts.join('/')}';
  }
}
