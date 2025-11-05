import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/voice_input_service.dart';
import '../services/transaction_parser.dart';

/// 语音输入对话框
class VoiceInputDialog extends ConsumerStatefulWidget {
  const VoiceInputDialog({super.key});

  @override
  ConsumerState<VoiceInputDialog> createState() => _VoiceInputDialogState();
}

class _VoiceInputDialogState extends ConsumerState<VoiceInputDialog>
    with SingleTickerProviderStateMixin {
  final VoiceInputService _voiceService = VoiceInputService();
  String _recognizedText = '';
  String _partialText = '';
  bool _isListening = false;
  bool _hasPermission = true;
  String? _errorMessage;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _initializeAndStart();
  }

  Future<void> _initializeAndStart() async {
    try {
      debugPrint('[VoiceInput] 开始初始化语音识别...');

      // 强制重新初始化（每次进入都重新请求权限）
      final success = await _voiceService.initialize(forceReinit: true);
      debugPrint('[VoiceInput] 初始化结果: $success');

      if (!success) {
        // 初始化失败，检查权限状态
        final micStatus = await Permission.microphone.status;
        final speechStatus = await Permission.speech.status;
        debugPrint('[VoiceInput] 麦克风权限状态: $micStatus');
        debugPrint('[VoiceInput] 语音识别权限状态: $speechStatus');

        setState(() {
          // 权限已授予但初始化失败 = 设备不支持
          if (micStatus.isGranted && speechStatus.isGranted) {
            _hasPermission = true;
            _errorMessage = '该设备不支持语音识别\n可能缺少Google语音服务或语音引擎';
            debugPrint('[VoiceInput] 设备不支持语音识别');
          } else if (micStatus.isPermanentlyDenied || speechStatus.isPermanentlyDenied) {
            _hasPermission = false;
            _errorMessage = '麦克风权限已被拒绝，请在系统设置中开启';
            debugPrint('[VoiceInput] 权限被永久拒绝');
          } else {
            _hasPermission = false;
            _errorMessage = '语音识别初始化失败，请允许麦克风和语音识别权限';
            debugPrint('[VoiceInput] 权限未授予或初始化失败');
          }
        });
        return;
      }

      // 重置错误状态
      setState(() {
        _hasPermission = true;
        _errorMessage = null;
      });
      debugPrint('[VoiceInput] 初始化成功，准备开始监听');

      // 开始监听
      await _startListening();
    } catch (e) {
      debugPrint('[VoiceInput] 初始化异常: $e');
      setState(() {
        _errorMessage = '初始化失败: $e';
      });
    }
  }

  // 打开系统设置
  Future<void> _openSettings() async {
    await openAppSettings();
  }

  Future<void> _startListening() async {
    try {
      debugPrint('[VoiceInput] 开始监听语音...');
      setState(() {
        _isListening = true;
        _errorMessage = null;
      });

      await _voiceService.startListening(
        onResult: (text) {
          debugPrint('[VoiceInput] 识别结果: $text');
          setState(() {
            _recognizedText = text;
            _partialText = '';
          });
          // 识别完成，解析并返回结果
          _handleRecognizedText(text);
        },
        onPartialResult: (text) {
          debugPrint('[VoiceInput] 部分识别: $text');
          setState(() {
            _partialText = text;
          });
        },
      );
      debugPrint('[VoiceInput] 监听已启动');
    } catch (e) {
      debugPrint('[VoiceInput] 监听启动失败: $e');
      setState(() {
        _isListening = false;
        _errorMessage = '启动失败: $e';
      });
    }
  }

  void _handleRecognizedText(String text) {
    // 解析文本
    final parsed = TransactionParser.parse(text);

    // 等待一小段时间显示结果，然后关闭对话框
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        Navigator.of(context).pop(parsed);
      }
    });
  }

  Future<void> _stopListening() async {
    await _voiceService.stopListening();
    setState(() {
      _isListening = false;
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Text(
              '语音记账',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),

            // 麦克风动画
            if (_isListening)
              AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor.withOpacity(0.1),
                      boxShadow: [
                        BoxShadow(
                          color: theme.primaryColor.withOpacity(
                            0.3 * (1 - _animationController.value),
                          ),
                          blurRadius: 30 * _animationController.value,
                          spreadRadius: 20 * _animationController.value,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.mic,
                      size: 48,
                      color: theme.primaryColor,
                    ),
                  );
                },
              )
            else
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.withOpacity(0.1),
                ),
                child: const Icon(
                  Icons.mic_off,
                  size: 48,
                  color: Colors.grey,
                ),
              ),

            const SizedBox(height: 24),

            // 识别文本显示
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              constraints: const BoxConstraints(minHeight: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_errorMessage != null)
                    Text(
                      _errorMessage!,
                      style: textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    )
                  else if (_recognizedText.isNotEmpty)
                    Text(
                      _recognizedText,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  else if (_partialText.isNotEmpty)
                    Text(
                      _partialText,
                      style: textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Text(
                      _isListening ? '请说话...' : '等待中...',
                      style: textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 提示文本
            if (_isListening && _recognizedText.isEmpty && _partialText.isEmpty)
              Text(
                '例如: "午饭花了50块"',
                style: textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

            const SizedBox(height: 16),

            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 取消按钮
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('取消'),
                ),

                // 权限相关按钮
                if (_errorMessage != null && !_hasPermission)
                  FilledButton.tonal(
                    onPressed: () async {
                      debugPrint('[VoiceInput] 用户点击授权按钮');
                      // 检查是否被永久拒绝
                      final micStatus = await Permission.microphone.status;
                      final speechStatus = await Permission.speech.status;
                      debugPrint('[VoiceInput] 授权按钮 - 麦克风: $micStatus, 语音: $speechStatus');

                      if (micStatus.isPermanentlyDenied || speechStatus.isPermanentlyDenied) {
                        // 打开系统设置
                        debugPrint('[VoiceInput] 打开系统设置');
                        await _openSettings();
                      } else {
                        // 重新请求权限
                        debugPrint('[VoiceInput] 重新请求权限');
                        await _initializeAndStart();
                      }
                    },
                    child: const Text('授权'),
                  )
                // 其他错误时显示重试按钮
                else if (_errorMessage != null && _hasPermission)
                  FilledButton.tonal(
                    onPressed: () {
                      debugPrint('[VoiceInput] 用户点击重试按钮');
                      _startListening();
                    },
                    child: const Text('重试'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 显示语音输入对话框
Future<ParsedTransaction?> showVoiceInputDialog(BuildContext context) {
  return showDialog<ParsedTransaction>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const VoiceInputDialog(),
  );
}
