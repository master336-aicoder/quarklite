import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';
import 'download_client.dart';
import 'gopeed_client.dart';
import 'ios_background_download_client.dart';

class GopeedEngine {
  static const _channel = MethodChannel('quarklite.com/gopeed');

  static DownloadClient? _client;
  static bool _started = false;
  static Process? _winProcess;
  static bool _winServerReady = false;
  static String _winDiag = '';
  /// 本次会话实际使用的 gopeed.exe 所在目录，供残留进程定向清理比对
  static String? _winExeDir;

  /// 进行中的启动流程（并发调用共享同一次启动，避免互相杀掉对方刚拉起的引擎进程）
  static Future<void>? _startInFlight;
  /// 引擎进程意外退出后的自动重启防抖标志
  static bool _autoRestarting = false;
  /// 连续快速退出计数（启动后 10 秒内退出算一次，防止被杀软反复拦截时无限重启）
  static int _rapidExitCount = 0;
  /// 最近一次引擎启动成功的时间
  static DateTime? _lastStartTime;

  /// 最近一次引擎启动失败的详细原因（供界面展示）
  static String? lastError;

  /// 本次会话的 REST API 随机 token。
  ///
  /// 加固前固定为空串，等于本机 127.0.0.1 上的下载接口无任何鉴权：
  /// 同机任意进程可下发任意 URL/路径的下载任务、读写引擎配置，
  /// 并可通过任务详情读到随任务提交的网盘 Cookie。
  /// token 每次进程生命周期内生成一次，引擎重启沿用（客户端同步重建）。
  static String? _apiToken;

  static String get _token {
    final t = _apiToken;
    if (t != null && t.isNotEmpty) return t;
    final r = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return _apiToken = base64Url.encode(bytes).replaceAll('=', '');
  }

  static DownloadClient get client {
    final c = _client;
    if (c == null) {
      throw Exception('下载引擎尚未启动');
    }
    return c;
  }

  static bool get started => _started;

  /// 确保引擎已启动（未启动时自动拉起），供添加下载任务前调用
  /// [wait] 为 true 时等待一次完整启动尝试（最多约 16 秒），失败立即报错；
  /// 为 false 时交给后台重试逻辑，调用方不等待
  static Future<DownloadClient> ensureStarted({bool wait = true}) async {
    if (!_started) {
      await start(retry: !wait);
    }
    return client;
  }

  /// 启动引擎。带自愈重试：
  /// 1. 先停掉可能残留的旧实例（Dart 隔离区重建后旧引擎仍持有数据库锁）
  /// 2. 失败时清理可能损坏的数据库目录再重试
  /// [retry] 为 false 时只尝试一次（保证快速失败，用于交互等待场景）
  /// 并发调用共享同一次启动，避免多个启动流程互相 taskkill 对方刚拉起的引擎进程。
  static Future<void> start({bool retry = true}) async {
    AppLogger.I.i('engine',
        'start 请求 retry=$retry started=$_started inFlight=${_startInFlight != null}');
    if (_started) return;
    final inFlight = _startInFlight;
    if (inFlight != null) return inFlight;
    final future = _doStart(retry: retry);
    _startInFlight = future;
    try {
      await future;
    } finally {
      _startInFlight = null;
    }
  }

  static Future<void> _doStart({required bool retry}) async {
    if (_started) return;
    if (!kIsWeb && Platform.isWindows) {
      await _startWindows(retry: retry);
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      await _startAndroid();
      return;
    }
    if (!kIsWeb && Platform.isIOS) {
      await _startIos();
      return;
    }
    throw UnsupportedError('当前平台暂不支持下载引擎');
  }


  // ---------------- iOS：URLSession 原生后台下载 ----------------

  static Future<void> _startIos() async {
    try {
      final client = IosBackgroundDownloadClient();
      await client.start();
      _client = client;
      _started = true;
      lastError = null;
    } catch (e) {
      _client = null;
      _started = false;
      lastError = 'iOS 后台下载器启动失败: $e';
      throw Exception(lastError!);
    }
  }

  // ---------------- Android：原生 Libgopeed（MethodChannel） ----------------

  static Future<void> _startAndroid() async {
    final docs = await getApplicationDocumentsDirectory();
    final storageDir = '${docs.path}/gopeed';
    final cfg = {
      'network': 'tcp',
      'address': '127.0.0.1:0',
      'storage': 'bolt',
      'storageDir': storageDir,
      'refreshInterval': 350,
      'apiToken': _token,
    };
    String lastError_ = '';
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        try {
          await _channel.invokeMethod('stop');
        } catch (_) {
          // 无残留实例时忽略
        }
        await Future.delayed(const Duration(milliseconds: 200));
        final port = await _channel.invokeMethod<int>('start', {
          'cfg': jsonEncode(cfg),
        });
        if (port == null || port <= 0) {
          throw Exception('引擎返回无效端口');
        }
        _client = GopeedClient('http://127.0.0.1:$port', apiToken: _token);
        _started = true;
        return;
      } catch (e) {
        lastError_ = e.toString();
        // 前两次失败后清理损坏的任务数据库再重试（会丢失任务记录但保证引擎可用）
        if (attempt == 1) {
          try {
            final dir = Directory(storageDir);
            if (dir.existsSync()) {
              dir.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
    }
    _client = null;
    _started = false;
    lastError = '下载引擎启动失败: $lastError_';
    throw Exception(lastError!);
  }

  // ---------------- Windows：gopeed.exe 子进程 + REST API ----------------

  static Future<void> _startWindows({bool retry = true}) async {
    // 已就绪判定必须同时满足进程存活标记与 client 非空：
    // 进程刚退出、退出回调尚未执行时 _winServerReady 仍为 true，
    // 若此时直接返回会让调用方拿到空的 client，报『下载引擎尚未启动』
    if (_winProcess != null && _winServerReady && _client != null) {
      _started = true;
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    final storageDir = '${docs.path}/gopeed';
    final exe = _findGopeedExe(docs.path);
    if (exe == null) {
      lastError = '未找到 gopeed.exe，请确认程序目录完整';
      AppLogger.I.e('engine', 'Windows 启动失败: $lastError');
      throw Exception(lastError!);
    }
    _winExeDir = File(exe).parent.path;
    AppLogger.I.i('engine', 'Windows 引擎启动 exe=$exe storage=$storageDir retry=$retry');
    _winDiag = '';
    String lastError_ = '';
    final attempts = retry ? 3 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      Process? process;
      try {
        await _stopWindowsProcess();
        // 端口 0 表示随机分配，解析 stdout 中的监听地址
        process = await Process.start(exe, [
          '-A', '127.0.0.1',
          '-P', '0',
          '-T', _token,
          '-d', storageDir,
        ]);
        _winProcess = process;
        AppLogger.I.i('engine', '引擎进程已拉起 pid=${process.pid} attempt=${attempt + 1}/$attempts');
        // 确认进程存活：部分环境（杀软扫描等）进程启动后立即退出
        final exited = await Future.any([
          process.exitCode.then((code) {
            _winDiag = '引擎进程退出 code=$code';
            return true;
          }),
          Future.delayed(const Duration(milliseconds: 300), () => false),
        ]);
        if (exited) {
          throw Exception('引擎启动后立即退出');
        }
        final port = await _readServerPort(process);
        if (port == null || port <= 0) {
          throw Exception('引擎未正常启动: $_winDiag');
        }
        _client = GopeedClient('http://127.0.0.1:$port', apiToken: _token);
        _started = true;
        _winServerReady = true;
        _lastStartTime = DateTime.now();
        AppLogger.I.i('engine', '引擎启动成功 port=$port pid=${process.pid}');
        // 进程异常退出时标记引擎失效并自动重启；只清理当前进程的引用，避免误清新实例
        // （闭包内 process 无法做空类型提升，先取出 pid 供回调使用）
        final pid = process.pid;
        process.exitCode.then((code) {
          _winDiag = '引擎进程退出 code=$code';
          AppLogger.I.w('engine', '引擎进程退出 code=$code pid=$pid');
          if (!identical(process, _winProcess)) return;
          _winProcess = null;
          _winServerReady = false;
          _started = false;
          _client = null;
          // 连续快速退出（启动后 10 秒内被杀）计数：防止引擎被持续拦截时无限重启
          final t = _lastStartTime;
          if (t != null &&
              DateTime.now().difference(t) < const Duration(seconds: 10)) {
            _rapidExitCount++;
          } else {
            _rapidExitCount = 0;
          }
          if (_rapidExitCount >= 5) {
            AppLogger.I.w('engine',
                '引擎连续快速退出 $_rapidExitCount 次，暂停自动重启（等待周期轮询重试）');
            _rapidExitCount = 0;
            return;
          }
          // 引擎被杀软终止/崩溃后立即自愈，避免用户操作踩中引擎失效窗口
          unawaited(_autoRestart());
        });
        // 注意：stdout/stderr 已由 _readServerPort 的监听器持续消费
        // （防止缓冲填满导致进程阻塞），这里绝不能再次 listen——
        // 单订阅流重复监听会抛 "Bad state: Stream has already been listened to."
        return;
      } catch (e) {
        lastError_ = e.toString();
        AppLogger.I.e('engine', '引擎启动尝试失败 attempt=${attempt + 1}/$attempts: $e');
        // 失败时立即杀掉本次启动的进程，避免残留实例堆积
        try {
          process?.kill();
        } catch (_) {}
        if (identical(process, _winProcess)) {
          _winProcess = null;
          _winServerReady = false;
        }
        // 前两次失败后清理损坏的任务数据库再重试
        if (attempt == 1) {
          try {
            final dir = Directory(storageDir);
            if (dir.existsSync()) {
              dir.deleteSync(recursive: true);
            }
          } catch (_) {}
        }
      }
    }
    _client = null;
    _started = false;
    lastError = '下载引擎启动失败: $lastError_$_winDiag';
    AppLogger.I.e('engine', 'Windows 引擎启动最终失败: $lastError');
    throw Exception(lastError!);
  }

  /// 查找 gopeed.exe：仅接受受控目录（主程序目录、应用私有文档目录）下的绝对路径。
  ///
  /// 加固前还把裸名 `gopeed.exe` 作为候选（按当前工作目录与 PATH 解析），
  /// 等于允许任意位置的替身二进制被当作下载引擎拉起；该候选已移除。
  static String? _findGopeedExe(String docsPath) {
    final candidates = <String>[];
    try {
      candidates.add('${File(Platform.resolvedExecutable).parent.path}/gopeed.exe');
    } catch (_) {}
    candidates.add('$docsPath/gopeed.exe');
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 读取子进程 stdout 中的 "Server start success on http://127.0.0.1:port"
  static Future<int?> _readServerPort(Process process) async {
    final buffer = StringBuffer();
    final stderrBuf = StringBuffer();
    final completer = Completer<int?>();
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      buffer.write(chunk);
      if (buffer.length > 4096) {
        final tail = buffer.toString().substring(buffer.length - 2048);
        buffer.clear();
        buffer.write(tail);
      }
      final text = buffer.toString();
      final match =
          RegExp(r'Server start success on http://[^:]+:(\d+)').firstMatch(text);
      if (match != null && !completer.isCompleted) {
        completer.complete(int.tryParse(match.group(1)!));
      }
    }, onError: (Object _) {});
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      stderrBuf.write(chunk);
      if (stderrBuf.length > 4096) {
        final tail = stderrBuf.toString().substring(stderrBuf.length - 2048);
        stderrBuf.clear();
        stderrBuf.write(tail);
      }
    }, onError: (Object _) {});
    // 首次启动被杀毒软件深度扫描会明显变慢，超时放宽到 30 秒
    // （引擎为后台异步启动，不阻塞界面）
    Future.delayed(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        final text = buffer.toString().trim();
        final err = stderrBuf.toString().trim();
        _winDiag = text.isNotEmpty ? '输出: ${_clip(text)}' : '';
        if (err.isNotEmpty) {
          _winDiag = '$_winDiag 错误输出: ${_clip(err)}';
        }
        completer.complete(null);
      }
    });
    return completer.future;
  }

  /// 诊断文本截断：保留头部与尾部，避免超长输出刷屏
  static String _clip(String s, [int limit = 6000]) {
    if (s.length <= limit) return s;
    final head = s.substring(0, limit ~/ 2);
    final tail = s.substring(s.length - limit ~/ 2);
    return '$head …[中间省略 ${s.length - limit} 字符]… $tail';
  }

  /// 杀掉残留的引擎进程，释放 bolt 数据库文件锁。
  ///
  /// 只处理可执行文件位于本次启动所用 exe 同目录的实例——加固前用
  /// `taskkill /IM gopeed.exe /F` 按映像名强杀，会连带终止用户
  /// 自己启动的同名 Gopeed 客户端。
  /// 脚本走 `-EncodedCommand`（UTF-16LE，Windows 小端）、目录走环境变量，
  /// 两者都不参与命令行字符串拼接，避免路径注入。
  static Future<void> _killAllGopeed() async {
    final exeDirRaw = _winExeDir;
    if (exeDirRaw == null) {
      AppLogger.I.w('engine', '未知引擎 exe 目录，跳过残留进程清理（不做全局按名强杀）');
      return;
    }
    const script = r'''
$ErrorActionPreference = "SilentlyContinue"
$dir = $env:QUARKLITE_GOPEED_DIR
$hit = 0
Get-CimInstance Win32_Process -Filter "Name='gopeed.exe'" | ForEach-Object {
  if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
    Stop-Process -Id $_.ProcessId -Force
    $hit = $hit + 1
  }
}
Write-Output "killed=$hit"
''';
    final encoded = base64.encode(utf16.encode(script));
    try {
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
        environment: {'QUARKLITE_GOPEED_DIR': exeDirRaw},
      );
      final killed = int.tryParse(
              RegExp(r'killed=(\d+)').firstMatch(r.stdout.toString())?.group(1) ??
                  '') ??
          0;
      if (killed > 0) {
        AppLogger.I.w('engine', '清理了 $killed 个残留引擎进程 (dir=$exeDirRaw)');
      }
      if (r.exitCode != 0) {
        AppLogger.I.w('engine',
            '定向清理返回非零码 ${r.exitCode}: ${r.stderr.toString().trim()}');
      }
    } catch (e) {
      // PowerShell 不可用（组策略禁用等）时才退回按映像名强杀，并显式告警
      AppLogger.I.w('engine', 'PowerShell 定向清理不可用，退回按映像名强杀: $e');
      try {
        final r = await Process.run('taskkill', ['/IM', 'gopeed.exe', '/F']);
        if (r.exitCode == 0) {
          AppLogger.I.w('engine',
              'taskkill 清除了残留 gopeed 进程: ${r.stdout.toString().trim()}');
        }
      } catch (_) {
        // 无残留实例时 taskkill 会报错，忽略
      }
    }
  }

  static Future<void> _stopWindowsProcess() async {
    final p = _winProcess;
    _winProcess = null;
    _winServerReady = false;
    if (p != null) {
      try {
        p.kill();
        await p.exitCode.timeout(const Duration(seconds: 2),
            onTimeout: () => -1);
      } catch (_) {
        // 忽略停止失败
      }
    }
    await _killAllGopeed();
  }

  static Future<void> stop() async {
    AppLogger.I.i('engine', 'stop 请求 started=$_started');
    if (!_started) return;
    if (!kIsWeb && Platform.isWindows) {
      await _stopWindowsProcess();
    } else if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stop');
      } catch (_) {
        // 忽略停止失败
      }
    } else if (!kIsWeb && Platform.isIOS) {
      final iosClient = _client;
      if (iosClient is IosBackgroundDownloadClient) {
        await iosClient.dispose();
      }
    }
    _client = null;
    _started = false;
  }

  /// 引擎进程意外退出后的自动重启（防抖；失败时留给 DownloadManager 周期重试）
  static Future<void> _autoRestart() async {
    AppLogger.I.i('engine', '引擎退出触发自动重启 _autoRestarting=$_autoRestarting');
    if (_autoRestarting) return;
    _autoRestarting = true;
    try {
      // 先等系统清理完退出的进程，再拉起新实例
      await Future.delayed(const Duration(milliseconds: 800));
      if (_started) return;
      try {
        await start();
      } catch (e) {
        AppLogger.I.e('engine', '自动重启失败: $e');
        // 自动重启失败不抛给调用方，界面由 DownloadManager 呈现引擎错误
      }
    } finally {
      _autoRestarting = false;
    }
  }
}
