import 'package:flutter_test/flutter_test.dart';
import 'package:quarklite/utils/app_logger.dart';

/// 日志脱敏的行为断言。
///
/// 加这组用例的直接原因：`_kv` / `_jsonStr` 最初写成内联 `(?i)`，而 Dart 的
/// RegExp 是 ECMAScript 语法，构造时即抛 FormatException；由于 `AppLogger._log`
/// 在 try 之外调用 `LogRedact.text`，实际后果是每条日志都抛异常。
/// 这类"正则根本编译不过"的问题只有真正运行才会暴露，纯静态检查会漏。
void main() {
  group('LogRedact.text', () {
    test('正则可编译，任意文本过脱敏不抛异常', () {
      expect(() => LogRedact.text('plain message'), returnsNormally);
      expect(() => LogRedact.text(''), returnsNormally);
    });

    test('k=v 凭据被替换且键名保留', () {
      final out = LogRedact.text('cookie: __pus_top_secret_value');
      expect(out, contains('cookie:'));
      expect(out, isNot(contains('__pus_top_secret_value')));
      expect(out, contains('[已脱敏]'));
    });

    test('键名大小写不敏感', () {
      for (final key in [
        'COOKIE', 'Cookie', 'cookie', 'Authorization', 'AUTH_KEY', '__PUUS',
      ]) {
        expect(
          LogRedact.text('$key=leak_me_please'),
          isNot(contains('leak_me_please')),
          reason: '键 $key 未被脱敏',
        );
      }
    });

    test('JSON 里的凭据字段被替换，非凭据字段原样保留', () {
      final out = LogRedact.text('{"Cookie":"abc123xyz","name":"movie.mp4"}');
      expect(out, isNot(contains('abc123xyz')));
      expect(out, contains('movie.mp4'));
    });

    test('Dio 异常串（完整 URL + 请求头）不泄露凭据', () {
      final out = LogRedact.text(
        'DioException: uri=https://dl.example.com/f?auth_key=SECRET-TOKEN-999 '
        'headers: {Cookie: __puus=AAAA} ',
      );
      expect(out, isNot(contains('SECRET-TOKEN-999')));
      expect(out, isNot(contains('__puus=AAAA')));
    });

    test('普通路径不被误伤', () {
      const s = 'start /storage/emulated/0/Download/a.mp4 ok';
      expect(LogRedact.text(s), s);
    });
  });

  group('LogRedact.url', () {
    test('丢弃整个 query，保留协议+主机+路径', () {
      expect(
        LogRedact.url('https://cdn.example.com/p/a.mp4?auth_key=1234-5678-SECRET'),
        'https://cdn.example.com/p/a.mp4?[已脱敏]',
      );
    });

    test('无 query 时原样返回', () {
      expect(
        LogRedact.url('https://cdn.example.com/p/a.mp4'),
        'https://cdn.example.com/p/a.mp4',
      );
    });

    test('空串原样返回', () {
      expect(LogRedact.url(''), '');
    });
  });
}
