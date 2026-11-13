// 安全守卫的离线断言集：不依赖 Flutter，纯 Dart 即可运行。
//   dart run tool/guard_selfcheck.dart      （或 dart tool/guard_selfcheck.dart）
// 之所以不用 package:test：仓库现有 test/ 依赖 flutter_test，而这两组守卫是零依赖
// 纯函数，能在没有 Flutter 工具链的机器上直接跑，改动 net_guard/path_guard 后必须重跑。
// 退出码非 0 表示有断言失败。
// 故意用相对路径 import lib/ 下的文件、并用 print 输出：
// 这样只装 Dart SDK、连 `pub get` 都没跑过的机器也能直接执行本文件。
// ignore_for_file: avoid_relative_lib_imports, avoid_print
import '../lib/utils/net_guard.dart';
import '../lib/utils/path_guard.dart';

int fail = 0;
void chk(String what, Object? got, Object? want) {
  final ok = got == want;
  if (!ok) fail++;
  print('${ok ? "PASS" : "FAIL"}  $what  got=$got want=$want');
}

void main() {
  print('--- isInternalHost ---');
  for (final c in <List<Object>>[
    ['127.0.0.1', true], ['127.0.0.53', true], ['10.1.2.3', true], ['172.16.0.1', true],
    ['172.31.255.255', true], ['172.15.0.1', false], ['192.168.9.9', true],
    ['169.254.169.254', true], ['100.64.0.1', true], ['100.127.255.255', true],
    ['100.128.0.1', false], ['8.8.8.8', false], ['localhost', true],
    ['api.quark.cn', false], ['::1', true], ['fe80::1', true], ['fd12:3456::1', true],
    ['fc00::1', true], ['2001:4860:4860::8888', false], ['::ffff:127.0.0.1', true],
    ['[::1]', true], ['', true],
  ]) {
    chk('isInternalHost(${c[0]})', NetGuard.isInternalHost(c[0] as String), c[1]);
  }

  print('--- parseHttp ---');
  chk('https ok', NetGuard.parseHttp('https://a.com/x?y=1')?.host, 'a.com');
  chk('file rejected', NetGuard.parseHttp('file:///etc/passwd'), null);
  chk('javascript rejected', NetGuard.parseHttp('javascript:alert(1)'), null);
  chk('no scheme rejected', NetGuard.parseHttp('127.0.0.1:8080/x'), null);
  chk('no host rejected', NetGuard.parseHttp('http://'), null);

  print('--- credentialRejection ---');
  chk('scope none denied', NetGuard.credentialRejection('https://a.com/x', NetScope.none) != null, true);
  chk('metadata denied', NetGuard.credentialRejection('http://169.254.169.254/latest', NetScope.quark) != null, true);
  chk('loopback denied', NetGuard.credentialRejection('http://127.0.0.1:9999/x', NetScope.quark) != null, true);
  chk('public allowed', NetGuard.credentialRejection('https://cdn.example.com/f?sign=1', NetScope.quark), null);
  chk('decimal loopback 2130706433', NetGuard.isInternalHost('2130706433'), true);
  chk('short loopback 127.1', NetGuard.isInternalHost('127.1'), true);
  chk('hex 0x7f000001', NetGuard.isInternalHost('0x7f000001'), true);
  chk('octal 0177.0.0.1', NetGuard.isInternalHost('0177.0.0.1'), true);
  chk('zero host 0', NetGuard.isInternalHost('0'), true);
  chk('trailing dot quad', NetGuard.isInternalHost('127.0.0.1.'), true);
  chk('public quad still allowed', NetGuard.isInternalHost('8.8.8.8'), false);
  chk('test-net quad still allowed', NetGuard.isInternalHost('192.0.2.1'), false);
  chk('numeric label + domain allowed', NetGuard.isInternalHost('127.example.com'), false);
  chk('de tld allowed', NetGuard.isInternalHost('abcc.de'), false);
  chk('punycode allowed', NetGuard.isInternalHost('xn--fiqs8s.com'), false);
  chk('cdn with digits allowed', NetGuard.isInternalHost('p7-v28il6n.dom.pquark-stream.com'), false);

  print('--- isTrustedPage ---');
  chk('exact domain', NetGuard.isTrustedPage('https://xunlei.com/', NetScope.xunlei), true);
  chk('subdomain', NetGuard.isTrustedPage('https://pan.xunlei.com/x', NetScope.xunlei), true);
  chk('suffix spoof denied', NetGuard.isTrustedPage('https://xunlei.com.evil.com/', NetScope.xunlei), false);
  chk('substring spoof denied', NetGuard.isTrustedPage('https://notxunlei.com/', NetScope.xunlei), false);
  chk('wrong scope denied', NetGuard.isTrustedPage('https://pan.xunlei.com/', NetScope.quark), false);
  chk('query-only spoof denied', NetGuard.isTrustedPage('https://evil.com/?u=xunlei.com', NetScope.xunlei), false);
  chk('none scope denied', NetGuard.isTrustedPage('https://xunlei.com/', NetScope.none), false);

  print('--- PathGuard.safeName ---');
  final s1 = PathGuard.safeName('../../windows/win.ini');
  chk('no slash', s1.contains('/'), false);
  chk('no backslash', s1.contains(r'\'), false);
  chk('no dotdot', s1 == '..', false);
  final s2 = PathGuard.safeName('nul');
  chk('reserved nul neutralized', s2.toLowerCase() == 'nul', false);
  final s3 = PathGuard.safeName('con.txt');
  chk('reserved con.txt neutralized', s3.toLowerCase() == 'con.txt', false);
  chk('empty becomes unnamed', PathGuard.safeName('   '), 'unnamed');
  chk('dots become unnamed', PathGuard.safeName('....'), 'unnamed');
  final s5 = PathGuard.safeName('a\x00b\x1fc.txt');
  chk('control chars stripped', s5, 'abc.txt');
  final s6 = PathGuard.safeName('x' * 300);
  chk('long name capped', s6.length <= 200, true);
  final s7 = PathGuard.safeName('报告.最终版.mp4');
  chk('unicode kept', s7, '报告.最终版.mp4');
  final s8 = PathGuard.safeName('evil.${'a' * 300}.tar.gz');
  chk('long with ext capped', s8.length <= 200, true);

  print('--- PathGuard.traversalRejection / joinUnder ---');
  chk('clean path ok', PathGuard.traversalRejection('a/b/c'), null);
  chk('dotdot denied', PathGuard.traversalRejection('a/../b') != null, true);
  chk('backslash dotdot denied', PathGuard.traversalRejection(r'a\..\b') != null, true);
  chk('empty denied', PathGuard.traversalRejection('') != null, true);
  final j = PathGuard.joinUnder('/sdcard/Download', '../../../etc/passwd');
  chk('joinUnder stays under base', j.startsWith('/sdcard/Download/'), true);
  chk('joinUnder has no dotdot', j.contains('..'), false);
  chk('joinUnder empty rel', PathGuard.joinUnder('/base', ''), '/base');
  final j2 = PathGuard.joinUnder('/base', r'a\..\b/c');
  chk('joinUnder mixed seps safe', j2.contains('..'), false);
  print('  joinUnder sample: $j');
  print('  joinUnder sample: $j2');

  print(fail == 0 ? 'ALL PASS' : 'FAILURES: $fail');
}
