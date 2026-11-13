/// 出网目标与凭据投递范围的统一校验入口。
///
/// 背景：下载任务把网盘登录凭据（Cookie / Bearer token）交给本地下载引擎，
/// 由引擎向 URL 发起请求。加固前该路径对 URL 不做任何判断——
/// 一旦非官方地址（内网元数据口、攻击者可控域）流入，凭据会随头一起外发。
///
/// 注意夸克/123 的下载直链落在各家 CDN 域，并不在厂商主域下，
/// 因此这里**不采用"厂商域白名单"判直链**（会打断正常下载），
/// 而是用三重更弱但不会误伤的约束：
///   1. 协议必须是 http/https；
///   2. 目标不得是回环/私网/链路本地/云元数据地址（SSRF 关键面）；
///   3. 凭据只在调用方显式声明 [NetScope] 时才附带——默认不附带。
library;

/// 凭据投递范围：调用方必须显式声明这份凭据属于哪家，才能被贴进请求头。
enum NetScope {
  /// 不附带任何凭据（默认，最安全）
  none,

  /// 夸克网盘会话凭据
  quark,

  /// 迅雷网盘凭据
  xunlei,

  /// 123 网盘凭据
  pan123,
}

class NetGuard {
  NetGuard._();

  /// 各厂商可控页面域（WebView 导航、外部浏览器打开用），含子域。
  static const Map<NetScope, List<String>> trustedPageSuffixes = {
    NetScope.quark: ['quark.cn'],
    NetScope.xunlei: ['xunlei.com', 'xunleix.com'],
    NetScope.pan123: ['123pan.cn', '123pan.com', '123278.com'],
  };

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

  /// 解析可发起的 http(s) 绝对地址；非法或协议不符返回 null。
  static Uri? parseHttp(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || !u.hasAuthority) return null;
    final s = u.scheme.toLowerCase();
    if (s != 'http' && s != 'https') return null;
    if (u.host.isEmpty) return null;
    return u;
  }

  /// BT/磁力任务允许的协议：仅 magnet 与 btth（Gopeed 的 HTTP 直链走另一条路径）。
  static bool isTorrentUri(String url) {
    final t = url.trim().toLowerCase();
    return t.startsWith('magnet:') || t.startsWith('btth:');
  }

  /// host 是否属于私网/回环/链路本地/云元数据等不可对外投递凭据的地址。
  static bool isInternalHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    if (h.isEmpty) return true;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;

    final m = _ipv4.firstMatch(h);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      if (a == 0 || a == 10 || a == 127) return true;
      if (a == 169 && b == 254) return true; // 链路本地 / 云元数据 169.254.169.254
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64.0.0/10
      return false;
    }

    if (h.contains(':')) {
      // IPv6 字面量（主机名不可能含冒号）
      if (h == '::1' || h == '::') return true;
      if (h.startsWith('fe80')) return true; // 链路本地 fe80::/10
      // 唯一本地地址 fc00::/7：前 7 位固定，因此 fc 与 fd 两个前缀都算内部
      if (h.startsWith('fc') || h.startsWith('fd')) return true;
      final mapped = RegExp(r'^::ffff:').hasMatch(h);
      if (mapped) return true; // v4 映射地址一律按内部处理，避免绕过
      return false;
    }
    return false;
  }

  /// 该 URL 能否接收 [scope] 对应的凭据。
  ///
  /// 返回非 null 的字符串表示拒绝原因（可直接展示/入日志）。
  static String? credentialRejection(String url, NetScope scope) {
    if (scope == NetScope.none) return '未声明凭据投递范围，拒绝附带凭据';
    final u = parseHttp(url);
    if (u == null) return '下载地址必须是 http/https 绝对地址';
    if (isInternalHost(u.host)) return '下载地址指向内网/元数据地址，已拦截';
    return null;
  }

  /// 目标 URL 是否属于该厂商的页面域（WebView 导航、系统浏览器打开前的检查）。
  static bool isTrustedPage(String url, NetScope scope) {
    final u = parseHttp(url);
    if (u == null) return false;
    final suffixes = trustedPageSuffixes[scope];
    if (suffixes == null) return false;
    final h = u.host.toLowerCase();
    for (final s in suffixes) {
      if (h == s || h.endsWith('.$s')) return true;
    }
    return false;
  }
}
