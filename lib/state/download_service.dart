import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/quark_client.dart';
import '../core/gopeed/gopeed_boot.dart';
import '../core/gopeed/download_client.dart';
import '../state/app_state.dart';
import '../utils/app_logger.dart';
import '../utils/net_guard.dart';

class DownloadService {
  /// 把直链加入 Gopeed 下载队列，返回错误信息（null 表示成功）
  /// [batchTotal] 为本次批量下载的任务总数，用于按预算分摊连接数（默认单任务）。
  /// [maxConnections] 为该网盘的单任务线程上限（夸克默认 512，迅雷 64）。
  /// [referer]/[userAgent] 自定义下载请求头（默认夸克网盘）。
  /// [credentialScope] 声明 [cookie] 属于哪家网盘：只有显式声明范围的调用
  /// 才会把凭据附到请求上，且目标不得是内网/元数据地址。
  static Future<String?> addDirectUrl({
    required String url,
    required String fileName,
    required String cookie,
    required NetScope credentialScope,
    String? path,
    int? connections,
    int? maxConnections,
    int batchTotal = 1,
    String? referer,
    String? userAgent,
  }) async {
    // 凭据投递前置校验：非法目标直接拒绝，不进入引擎
    final rejection =
        cookie.isEmpty ? null : NetGuard.credentialRejection(url, credentialScope);
    if (rejection != null) {
      AppLogger.I.e('download', '拒绝创建任务 name=$fileName: $rejection');
      return '下载被拦截: $rejection';
    }
    try {
      var client = await GopeedEngine.ensureStarted();
      final dir = path ?? await AppState.I.effectiveDownloadDir();
      final app = AppState.I;
      final actualConnections =
          connections ?? app.effectiveConnections(batchTotal, maxPerTask: maxConnections);
      AppLogger.I.i('download',
          '创建任务 name=$fileName connections=$actualConnections batch=$batchTotal dir=$dir url=${_briefUrl(url)}');
      try {
        await _createTask(client,
            url: url,
            path: dir,
            name: fileName,
            cookie: cookie,
            credentialScope: credentialScope,
            connections: actualConnections,
            referer: referer,
            userAgent: userAgent);
        AppLogger.I.i('download', '创建任务成功 name=$fileName');
      } catch (e) {
        // 引擎进程可能在等待目录等异步操作期间退出（如被杀软终止），
        // 导致引擎状态被清空：重启引擎并重试一次，而不是直接报“引擎尚未启动”
        if (e.toString().contains('下载引擎尚未启动') || !GopeedEngine.started) {
          AppLogger.I.w('download', '引擎失效（$e），重启引擎并重试创建任务 name=$fileName');
          client = await GopeedEngine.ensureStarted();
          await _createTask(client,
              url: url,
              path: dir,
              name: fileName,
              cookie: cookie,
              credentialScope: credentialScope,
              connections: actualConnections,
              referer: referer,
              userAgent: userAgent);
          AppLogger.I.i('download', '重试创建任务成功 name=$fileName');
        } else {
          rethrow;
        }
      }
      return null;
    } catch (e) {
      AppLogger.I.e('download', '创建任务最终失败 name=$fileName: $e');
      return '创建下载任务失败: $e';
    }
  }

  /// 日志脱敏：直链只保留协议+主机+路径，query 中的签名参数不落日志
  static String _briefUrl(String url) => LogRedact.url(url);

  /// 创建 Gopeed 下载任务（附带下载请求头）
  static Future<void> _createTask(
    DownloadClient client, {
    required String url,
    required String path,
    required String name,
    required String cookie,
    required NetScope credentialScope,
    required int connections,
    String? referer,
    String? userAgent,
  }) {
    // 凭据仅在调用方显式声明归属网盘时才附带（范围校验已在 addDirectUrl 完成）
    final attachCredential =
        cookie.isNotEmpty && credentialScope != NetScope.none;
    return client.create(
      url: url,
      path: path,
      name: name,
      headers: {
        if (attachCredential) 'Cookie': cookie,
        'Referer': referer ?? 'https://pan.quark.cn/',
        'User-Agent': userAgent ?? QuarkClient.uaDesktopClient,
      },
      connections: connections,
    );
  }

  /// 根据 fid 直接下载网盘文件，返回错误信息（null 表示已加入队列）
  static Future<String?> downloadQuarkFile(String fid,
      {String? fileName}) async {
    try {
      final app = AppState.I;
      final (infos, cookie) = await app.quark.getDownloadInfo([fid]);
      if (infos.isEmpty) return '未获取到下载地址';
      final info = infos.first;
      return addDirectUrl(
        url: info.url,
        fileName:
            info.fileName.isNotEmpty ? info.fileName : (fileName ?? ''),
        cookie: cookie,
        credentialScope: NetScope.quark,
        batchTotal: 1,
      );
    } catch (e) {
      return '下载失败: $e';
    }
  }

  /// 把 magnet 链接加入下载队列
  static Future<String?> addMagnet({
    required String url,
    String? name,
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      return 'iOS 暂不支持磁力/BT下载';
    }
    // 磁力入口只接受 magnet/btth，避免把任意 http 地址（含内网）当种子丢给引擎
    if (!NetGuard.isTorrentUri(url)) {
      AppLogger.I.w('download', '拒绝非法 BT 链接 scheme: ${LogRedact.url(url)}');
      return '仅支持 magnet: 或 btth: 链接';
    }
    try {
      var client = await GopeedEngine.ensureStarted();
      final dir = await AppState.I.effectiveDownloadDir();
      AppLogger.I.i('download', '创建 BT 任务 name=${name ?? ''} dir=$dir');
      try {
        await client.create(
          url: url,
          path: dir,
          name: name ?? '',
        );
        AppLogger.I.i('download', '创建 BT 任务成功 name=${name ?? ''}');
      } catch (e) {
        if (e.toString().contains('下载引擎尚未启动') || !GopeedEngine.started) {
          AppLogger.I.w('download', '引擎失效（$e），重启引擎并重试 BT 任务 name=${name ?? ''}');
          client = await GopeedEngine.ensureStarted();
          await client.create(
            url: url,
            path: dir,
            name: name ?? '',
          );
          AppLogger.I.i('download', '重试 BT 任务成功 name=${name ?? ''}');
        } else {
          rethrow;
        }
      }
      return null;
    } catch (e) {
      AppLogger.I.e('download', '创建 BT 任务失败 name=${name ?? ''}: $e');
      return '创建 BT 任务失败: $e';
    }
  }
}
