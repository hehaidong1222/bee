import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart';

/// 语音输入服务
class VoiceInputService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  bool _isListening = false;

  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;

  /// 初始化语音识别（自动请求权限）
  /// forceReinit: 强制重新初始化，用于重新请求权限
  Future<bool> initialize({bool forceReinit = false}) async {
    if (_isInitialized && !forceReinit) return true;

    // 如果强制重新初始化，先清理状态
    if (forceReinit) {
      _isInitialized = false;
      _isListening = false;
    }

    try {
      // initialize会自动请求麦克风和语音识别权限
      _isInitialized = await _speech.initialize(
        onError: (error) {
          debugPrint('语音识别错误: ${error.errorMsg}');
        },
        onStatus: (status) {
          debugPrint('语音识别状态: $status');
        },
      );
      return _isInitialized;
    } catch (e) {
      debugPrint('初始化语音识别失败: $e');
      return false;
    }
  }

  /// 开始监听
  Future<void> startListening({
    required Function(String) onResult,
    Function(String)? onPartialResult,
  }) async {
    if (!_isInitialized) {
      final success = await initialize();
      if (!success) {
        throw Exception('语音识别初始化失败');
      }
    }

    if (_isListening) {
      await stopListening();
    }

    try {
      _isListening = true;
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            onResult(result.recognizedWords);
          } else if (onPartialResult != null) {
            onPartialResult(result.recognizedWords);
          }
        },
        localeId: 'zh_CN', // 使用中文识别
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.confirmation,
        ),
      );
    } catch (e) {
      _isListening = false;
      debugPrint('开始监听失败: $e');
      rethrow;
    }
  }

  /// 停止监听
  Future<void> stopListening() async {
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }
  }

  /// 取消监听
  Future<void> cancel() async {
    if (_isListening) {
      await _speech.cancel();
      _isListening = false;
    }
  }

  /// 检查是否有语音识别权限
  Future<bool> hasPermission() async {
    return await _speech.hasPermission;
  }

  /// 获取可用的语言
  Future<List<String>> getAvailableLocales() async {
    if (!_isInitialized) {
      await initialize();
    }
    final locales = await _speech.locales();
    return locales.map((locale) => locale.localeId).toList();
  }

  /// 释放资源
  void dispose() {
    _speech.stop();
    _isInitialized = false;
    _isListening = false;
  }
}
