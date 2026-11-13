import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';

/// 凭据持久化唯一入口。
///
/// 只写插件的安全存储，不再向 SharedPreferences 落明文副本：
/// 历史版本的"secure + prefs 双写兜底"里，prefs 那一份是可读的 XML
/// （cookie / refresh_token / 123 密码明文），安全存储那一侧加密得再好也被它架空，
/// 且 `adb backup` 与云备份可以把这份 XML 整体带走。
///
/// [AndroidOptions.encryptedSharedPreferences] 保持 true，与上游既有写法逐字一致：
/// 现网安装包的既有值就是这种格式写进去的，两种模式共用同一个
/// `FlutterSecureStorage` 文件名，改动构造参数会让老设备读不出原有凭据——升级即全员掉登录。
/// 代价是这条后端依赖 Jetpack security-crypto，插件 10.x 起弃用该选项、11.x 移除，
/// 将来升到 10/11 时必须走插件自带的迁移开关，不能直接改参数（见 docs/operations.md）。
///
/// 安全存储不可用时（个别设备 Keystore 异常、或 Google Drive 自动备份导致
/// `Failed to unwrap key`）不再降级到明文，而是让调用方通过 [secureAvailable]
/// 感知并提示重新登录。
class CredentialStore {
  CredentialStore._();

  static final CredentialStore I = CredentialStore._();

  static const _tag = 'cred';

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 安全存储最近一次操作是否成功。false 表示凭据无法读写，
  /// 界面上应提示"系统安全存储不可用，需重新登录"。
  bool secureAvailable = true;

  /// 读取凭据；不存在或安全存储不可用时返回空串。
  Future<String> read(String key) async {
    try {
      final v = await _secure.read(key: key);
      secureAvailable = true;
      return v ?? '';
    } catch (e) {
      secureAvailable = false;
      AppLogger.I.e(_tag, '安全存储读取失败 key=$key: $e');
      return '';
    }
  }

  /// 写入凭据。[value] 为空串时等价删除（读取侧一律把空串当作未登录）。
  /// 返回 false 表示未能持久化，调用方不应静默忽略。
  Future<bool> write(String key, String value) async {
    if (value.isEmpty) return delete(key);
    try {
      await _secure.write(key: key, value: value);
      secureAvailable = true;
      return true;
    } catch (e) {
      secureAvailable = false;
      AppLogger.I.e(_tag, '安全存储写入失败 key=$key: $e');
      return false;
    }
  }

  Future<bool> delete(String key) async {
    try {
      await _secure.delete(key: key);
      secureAvailable = true;
      return true;
    } catch (e) {
      secureAvailable = false;
      AppLogger.I.e(_tag, '安全存储删除失败 key=$key: $e');
      return false;
    }
  }

  /// 清除历史版本写入 SharedPreferences 的明文凭据副本。
  ///
  /// 升级后首次启动调用一次即可：老用户设备上已存在的明文 cookie/密码
  /// 不会因为改了写入逻辑而自动消失，必须显式删除。
  Future<int> purgeLegacyPlaintext(Iterable<String> keys) async {
    if (keys.isEmpty) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      var removed = 0;
      for (final k in keys) {
        if (prefs.containsKey(k)) {
          await prefs.remove(k);
          removed++;
        }
      }
      if (removed > 0) {
        AppLogger.I.w(_tag, '已清除 $removed 项历史明文凭据（来自旧版本兜底存储）');
      }
      return removed;
    } catch (e) {
      AppLogger.I.e(_tag, '清理历史明文凭据失败: $e');
      return 0;
    }
  }
}
