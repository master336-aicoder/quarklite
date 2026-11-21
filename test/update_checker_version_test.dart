import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quarklite/core/update_checker.dart';

void main() {
  test('UpdateChecker.currentVersion 必须等于 pubspec.yaml 的 version', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)').firstMatch(line);
    expect(match, isNotNull, reason: 'pubspec.yaml 的 version 行无法解析：$line');
    expect(
      UpdateChecker.currentVersion,
      match!.group(1),
      reason: '版本常量漂移会让已升级到最新版的用户每次启动都看到"发现新版本"弹窗',
    );
  });
}
