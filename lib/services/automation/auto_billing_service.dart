import 'dart:io';
import 'dart:ui';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../billing/ocr_service.dart';
import '../billing/category_matcher.dart';
import '../billing/bill_creation_service.dart';
import '../billing/post_processor.dart';
import '../attachment_service.dart';
import '../data/tag_seed_service.dart';
import '../ai/bill_extraction_service.dart';
import '../ai/ai_constants.dart';
import '../../data/repositories/base_repository.dart';
import 'auto_billing_config.dart';
import '../../providers.dart';
import '../../data/db.dart';
import '../../data/category_node.dart';
import '../../l10n/app_localizations.dart';
import '../system/logger_service.dart';

/// 鑷姩璁拌处鏈嶅姟 - 閫氱敤鏍稿績閫昏緫
/// Android鍜宨OS鍏辩敤鐨凮CR璇嗗埆鍜岃嚜鍔ㄨ璐﹂€昏緫
class AutoBillingService {
  static const _ledgerIdKey = 'current_ledger_id';
  static const _processedScreenshotsKey = 'processed_screenshots';

  final ProviderContainer _container;
  final OcrService _ocrService = OcrService();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // 闃查噸澶嶅鐞?
  final Set<String> _processedPaths = {};
  String? _lastProcessedPath;
  int _lastProcessedTime = 0;

  AutoBillingService(this._container) {
    _initNotifications();
    _loadProcessedScreenshots();
  }

  /// 鍒濆鍖栭€氱煡
  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(initSettings);
  }

  /// 鍔犺浇宸插鐞嗙殑鎴浘鍒楄〃
  Future<void> _loadProcessedScreenshots() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_processedScreenshotsKey) ?? [];
    _processedPaths.addAll(list);

    // 鍙繚鐣欐渶杩慛涓紝閬垮厤鍐呭瓨鍗犵敤杩囧ぇ
    if (_processedPaths.length > AutoBillingConfig.maxProcessedCache) {
      final toRemove =
          _processedPaths.length - AutoBillingConfig.maxProcessedCache;
      _processedPaths.removeAll(_processedPaths.take(toRemove));
      await _saveProcessedScreenshots();
      logger.debug('AutoBilling', '娓呯悊宸插鐞嗙紦瀛?,
          '绉婚櫎=$toRemove, 淇濈暀=${AutoBillingConfig.maxProcessedCache}');
    }
  }

  /// 淇濆瓨宸插鐞嗙殑鎴浘鍒楄〃
  Future<void> _saveProcessedScreenshots() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _processedScreenshotsKey, _processedPaths.toList());
  }

  /// 鏍囪鎴浘宸插鐞?
  Future<void> _markAsProcessed(String path) async {
    _processedPaths.add(path);
    await _saveProcessedScreenshots();
  }

  /// 妫€鏌ユ埅鍥炬槸鍚﹀凡澶勭悊
  bool _isProcessed(String path) {
    return _processedPaths.contains(path);
  }

  /// 鏍稿績锛氬鐞嗘埅鍥惧苟鑷姩璁拌处
  /// [imagePath] 鎴浘鏂囦欢璺緞
  /// [showNotification] 鏄惁鏄剧ず閫氱煡锛堥粯璁rue锛?
  /// 杩斿洖锛氫氦鏄撹褰旾D锛屽け璐ヨ繑鍥瀗ull
  Future<int?> processScreenshot(
    String imagePath, {
    bool showNotification = true,
  }) async {
    final totalStartTime = DateTime.now().millisecondsSinceEpoch;
    print('馃摳 [AutoBilling] 寮€濮嬪鐞嗘埅鍥? $imagePath');
    logger.info('AutoBilling', '寮€濮嬪鐞嗘埅鍥?, imagePath);

    // 闃查噸澶嶅鐞? 宸插鐞嗚繃鐨勮烦杩?
    if (_isProcessed(imagePath)) {
      print('鈿狅笍 [AutoBilling] 鎴浘宸插鐞嗚繃锛岃烦杩?);
      logger.warning('AutoBilling', '鎴浘宸插鐞嗚繃锛岃烦杩?, imagePath);
      return null;
    }

    // 闃查噸澶嶅鐞? 閰嶇疆鏃堕棿绐楀彛鍐呯浉鍚岃矾寰勫彧澶勭悊涓€娆?
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProcessedPath == imagePath &&
        (now - _lastProcessedTime) < AutoBillingConfig.duplicateCheckWindow) {
      final timeDiff = now - _lastProcessedTime;
      print('鈿狅笍 [AutoBilling] 閲嶅鎴浘锛岃烦杩囧鐞?(${timeDiff}ms鍓嶅凡澶勭悊)');
      logger.warning('AutoBilling', '閲嶅鎴浘锛岃烦杩囧鐞?, '${timeDiff}ms鍓嶅凡澶勭悊');
      return null;
    }

    _lastProcessedPath = imagePath;
    _lastProcessedTime = now;

    try {
      const notificationId = 1001;

      // 妫€鏌ユ枃浠舵槸鍚﹀瓨鍦?
      final file = File(imagePath);

      // 濡傛灉鏂囦欢涓嶅瓨鍦?鍙兘闇€瑕佺煭鏆傜瓑寰?
      // (鏃犻殰纰嶆湇鍔＄洿鎺ユ埅鍥炬椂鏂囦欢宸插氨缁?ContentObserver 鍙兘闇€瑕佺瓑寰?
      if (!await file.exists()) {
        print('鈴?鏂囦欢灏氭湭灏辩华,绛夊緟鏈€澶?{AutoBillingConfig.fileWaitTimeout}ms...');
        logger.info('AutoBilling', '鏂囦欢灏氭湭灏辩华锛屽紑濮嬬瓑寰?,
            '璺緞=$imagePath, 瓒呮椂=${AutoBillingConfig.fileWaitTimeout}ms');

        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鉁?妫€娴嬪埌鎴浘',
            body: '姝ｅ湪绛夊緟鏂囦欢鍐欏叆...',
          );
        }

        final waitStartTime = DateTime.now().millisecondsSinceEpoch;
        var waitTime = 0;
        final maxWait = AutoBillingConfig.fileWaitTimeout;

        while (waitTime < maxWait) {
          if (await file.exists() && await file.length() > 0) {
            print('鉁?鏂囦欢宸插氨缁紝绛夊緟鏃堕棿=${waitTime}ms');
            logger.info('AutoBilling', '鏂囦欢灏辩华', '绛夊緟鏃堕棿=${waitTime}ms');
            break;
          }
          await Future.delayed(Duration(milliseconds: AutoBillingConfig.fileCheckInterval));
          waitTime = DateTime.now().millisecondsSinceEpoch - waitStartTime;
        }

        if (!await file.exists() || await file.length() == 0) {
          print('鉂?鎴浘鏂囦欢绛夊緟瓒呮椂 (${waitTime}ms)');
          logger.error('AutoBilling', '鎴浘鏂囦欢绛夊緟瓒呮椂',
              '璺緞=$imagePath, 绛夊緟鏃堕棿=${waitTime}ms, 鏂囦欢瀛樺湪=${await file.exists()}');
          if (showNotification) {
            await _showNotification(
              id: notificationId,
              title: '璇嗗埆澶辫触',
              body: '鎴浘鏂囦欢涓嶅彲鐢?,
            );
          }
          return null;
        }
      } else {
        print('鉁?鏂囦欢宸插氨缁?鏃犻渶绛夊緟');
        logger.debug('AutoBilling', '鏂囦欢宸插氨缁紝鏃犻渶绛夊緟');
      }

      // 鏇存柊閫氱煡锛氬紑濮嬭瘑鍒?
      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: '姝ｅ湪璇嗗埆鎴浘...',
          body: '姝ｅ湪鍒嗘瀽鏀粯淇℃伅,璇风◢鍊?,
        );
      }

      final repo = _container.read(repositoryProvider);

      final prefs = await SharedPreferences.getInstance();
      final aiEnabled =
          prefs.getBool(AIConstants.keyAiBillExtractionEnabled) ?? false;

      OcrResult result;
      if (aiEnabled) {
        print('馃 [AutoBilling] AI宸插惎鐢紝灏濊瘯AI瑙嗚璇嗗埆');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '馃 AI璇嗗埆涓?..',
            body: '姝ｅ湪浣跨敤AI鍒嗘瀽鏀粯鎴浘',
          );
        }
        final aiResult = await _tryAiVision(file, repo);
        if (aiResult == null) {
          if (showNotification) {
            await _showNotification(
              id: notificationId,
              title: '鉂?AI璇嗗埆澶辫触',
              body: 'AI鏈兘璇嗗埆鍑烘湁鏁堥噾棰濓紝璇烽噸璇曟垨妫€鏌I閰嶇疆',
            );
          }
          print('鉂?[AutoBilling] AI瑙嗚璇嗗埆澶辫触锛屽凡鍙栨秷');
          return null;
        }
        result = aiResult;
        print('鉁?[AutoBilling] AI瑙嗚璇嗗埆鎴愬姛: 閲戦=${result.amount}');
      } else {
        result = await _ocrService.recognizePaymentImage(file, repo: repo);
      }

      // 鎵撳嵃璇嗗埆缁撴灉鐢ㄤ簬璋冭瘯
      print('馃挵 璇嗗埆鍒扮殑閲戦: ${result.amount}');
      print('馃摑 璇嗗埆鍒扮殑澶囨敞: ${result.note}');
      print('鈴?璇嗗埆鍒扮殑鏃堕棿: ${result.time}');
      print('馃 鏄惁AI璇嗗埆: ${result.aiEnhanced}');
      if (result.aiEnhanced) {
        print('馃搨 AI鍒嗙被: ${result.aiCategoryName}');
        print('馃彟 AI璐︽埛: ${result.aiAccountName}');
        print('馃搵 AI绫诲瀷: ${result.aiType}');
      }
      logger.info('AutoBilling', '璇嗗埆缁撴灉', {
        'amount': result.amount,
        'note': result.note,
        'time': result.time,
        'aiEnhanced': result.aiEnhanced,
        'aiCategory': result.aiCategoryName,
        'aiAccount': result.aiAccountName,
        'aiType': result.aiType,
      }.toString());

      // 鏍囪涓哄凡澶勭悊
      await _markAsProcessed(imagePath);

      // 鏍规嵁璇嗗埆缁撴灉澶勭悊
      if (result.amount != null && result.amount!.abs() > 0) {
        print('鉁?璇嗗埆鎴愬姛: 閲戦=${result.amount}, 澶囨敞=${result.note}');

        try {
          final dbStartTime = DateTime.now().millisecondsSinceEpoch;
          print('鈴憋笍 [鎬ц兘] 寮€濮嬪垱寤轰氦鏄撹褰?);
          final autoAddTags = _container.read(smartBillingAutoTagsProvider);
          final autoAddAttachment = _container.read(smartBillingAutoAttachmentProvider);

          final billingTypes = <String>[TagSeedService.billingTypeImage];
          if (result.aiEnhanced) {
            billingTypes.add(TagSeedService.billingTypeAi);
          }
          final transactionId = await _createTransaction(
            result,
            billingTypes: billingTypes,
            autoAddTags: autoAddTags,
          );
          final dbElapsed = DateTime.now().millisecondsSinceEpoch - dbStartTime;
          print('鈴憋笍 [鎬ц兘] 浜ゆ槗璁板綍鍒涘缓瀹屾垚, 鑰楁椂=${dbElapsed}ms');

          if (transactionId != null) {
            if (autoAddAttachment) {
              try {
                final attachmentService = _container.read(attachmentServiceProvider);
                await attachmentService.saveAttachment(
                  transactionId: transactionId,
                  sourceFile: file,
                  index: 0,
                );
                logger.info('AutoBilling', '鎴浘闄勪欢淇濆瓨鎴愬姛', 'transactionId=$transactionId');
                _container.read(attachmentListRefreshProvider.notifier).state++;
              } catch (e, st) {
                logger.error('AutoBilling', '淇濆瓨鎴浘闄勪欢澶辫触', e, st);
              }
            }

            _container.read(statsRefreshProvider.notifier).state++;
            if (showNotification) {
              final prefix = result.aiEnhanced ? '馃 ' : '';
              await _showNotification(
                id: notificationId,
                title: '${prefix}鉁?鑷姩璁拌处鎴愬姛 楼${result.amount!.toStringAsFixed(2)}',
                body: result.note != null
                    ? '澶囨敞: ${result.note}'
                    : '宸茶嚜鍔ㄥ垱寤烘敮鍑鸿褰?,
              );
            }
            print('鉁?鑷姩璁拌处鎴愬姛: ID=$transactionId');
            logger.info('AutoBilling', '鑷姩璁拌处鎴愬姛', 'ID=$transactionId, 閲戦=${result.amount}');
            return transactionId;
          } else {
            if (showNotification) {
              await _showNotification(
                id: notificationId,
                title: '鉂?鑷姩璁拌处澶辫触',
                body: '璇嗗埆鎴愬姛浣嗗垱寤鸿褰曞け璐ワ紝璇锋墜鍔ㄨ璐?,
              );
            }
            print('鉂?鑷姩璁拌处澶辫触: 鍒涘缓浜ゆ槗璁板綍杩斿洖null');
            logger.error('AutoBilling', '鑷姩璁拌处澶辫触锛氬垱寤轰氦鏄撹褰曡繑鍥瀗ull');
            return null;
          }
        } catch (e, stackTrace) {
          print('鉂?鑷姩璁拌处澶辫触: $e');
          logger.error('AutoBilling', '鑷姩璁拌处澶辫触', {
            'path': imagePath,
            'amount': result.amount,
            'note': result.note,
            'error': e.toString(),
          }, stackTrace);
          if (showNotification) {
            await _showNotification(
              id: notificationId,
              title: '鉂?鑷姩璁拌处澶辫触',
              body: '璇嗗埆鎴愬姛浣嗗垱寤鸿褰曞け璐? $e',
            );
          }
          return null;
        }
      } else if (result.allNumbers.isNotEmpty) {
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鈿狅笍 璇嗗埆鍒伴噾棰濆€欓€?,
            body: '鍙兘鐨勯噾棰? ${result.allNumbers.join(", ")} | 璇锋墜鍔ㄧ‘璁?,
          );
        }
        print('鈿狅笍 璇嗗埆鍒版暟瀛椾絾鏈‘瀹氶噾棰? ${result.allNumbers}');
        logger.warning('AutoBilling', '璇嗗埆鍒版暟瀛椾絾鏈‘瀹氶噾棰?, result.allNumbers.toString());
        return null;
      } else {
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鉂?鏈瘑鍒埌鏀粯淇℃伅',
            body: '鍙兘涓嶆槸鏀粯鎴浘,鎴栧浘鐗囪川閲忚緝宸?,
          );
        }
        print('鈿狅笍 鏈瘑鍒埌浠讳綍鏈夋晥閲戦');
        logger.warning('AutoBilling', '鏈瘑鍒埌浠讳綍鏈夋晥閲戦');
        return null;
      }
    } catch (e, stackTrace) {
      print('鉂?澶勭悊鎴浘澶辫触: $e');
      logger.error('AutoBilling', '澶勭悊鎴浘澶辫触', {
        'path': imagePath,
        'error': e.toString(),
        'stage': '鏈煡闃舵',
      }, stackTrace);
      return null;
    } finally {
      final totalElapsed =
          DateTime.now().millisecondsSinceEpoch - totalStartTime;
      print('鈴憋笍 [鎬ц兘] 鏁翠釜娴佺▼瀹屾垚, 鎬昏€楁椂=${totalElapsed}ms');
    }
  }

  /// 鏍稿績锛氱洿鎺ュ鐞嗘枃鏈苟鑷姩璁拌处(蹇嵎鎸囦护鎺ㄨ崘鏂瑰紡)
  /// [text] 蹇嵎鎸囦护浼犻€掔殑璇嗗埆鏂囨湰
  /// [showNotification] 鏄惁鏄剧ず閫氱煡锛堥粯璁rue锛?
  /// 杩斿洖锛氫氦鏄撹褰旾D锛屽け璐ヨ繑鍥瀗ull
  Future<int?> processText(
    String text, {
    bool showNotification = true,
  }) async {
    final totalStartTime = DateTime.now().millisecondsSinceEpoch;
    print('馃摑 [AutoBilling] 寮€濮嬪鐞嗘枃鏈? $text');

    try {
      const notificationId = 1002;

      // 鏄剧ず"姝ｅ湪璇嗗埆"閫氱煡
      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: '鈴?姝ｅ湪璇嗗埆',
          body: '姝ｅ湪瑙ｆ瀽鏀粯淇℃伅...',
        );
      }

      // 鐩存帴瑙ｆ瀽鏂囨湰(鏃犻渶OCR)
      final ocrResult = _ocrService.parsePaymentText(text);

      if (ocrResult.amount == null) {
        print('鉂?鏈兘璇嗗埆鍑洪噾棰?);
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鉂?璇嗗埆澶辫触',
            body: '鏈兘璇嗗埆鍑洪噾棰濅俊鎭?,
          );
        }
        return null;
      }

      print('鉁?璇嗗埆鎴愬姛: 閲戦=${ocrResult.amount}, 澶囨敞=${ocrResult.note}');

      // 鏇存柊閫氱煡鐘舵€?
      if (showNotification) {
        await _showNotification(
          id: notificationId,
          title: '鉁?璇嗗埆鎴愬姛',
          body: '姝ｅ湪鍒涘缓浜ゆ槗璁板綍...',
        );
      }

      // 鑾峰彇鍒嗙被骞跺垱寤轰氦鏄?
      final repo = _container.read(repositoryProvider);
      final topLevelCategories = await repo.getTopLevelCategories('expense');
      final allCategories = <Category>[];
      allCategories.addAll(topLevelCategories);
      // 鑾峰彇鎵€鏈夊瓙鍒嗙被
      for (final category in topLevelCategories) {
        final subCategories = await repo.getSubCategories(category.id);
        allCategories.addAll(subCategories);
      }

      // 杩囨护鍑哄彲鐢ㄥ垎绫伙紙鎺掗櫎鏈夊瓙鍒嗙被鐨勭埗鍒嗙被锛?
      final categories = CategoryHierarchy.getUsableCategories(allCategories);

      final suggestedCategoryId = CategoryMatcher.smartMatch(
        merchant: ocrResult.note,
        fullText: ocrResult.rawText,
        categories: categories,
      );

      final resultWithCategory = OcrResult(
        amount: ocrResult.amount,
        note: ocrResult.note,
        time: ocrResult.time,
        rawText: ocrResult.rawText,
        allNumbers: ocrResult.allNumbers,
        suggestedCategoryId: suggestedCategoryId,
      );

      // 鍒涘缓浜ゆ槗璁板綍
      final txId = await _createTransaction(resultWithCategory);

      if (txId != null) {
        // 鍒锋柊缁熻淇℃伅
        _container.read(statsRefreshProvider.notifier).state++;
        print('鉁?浜ゆ槗鍒涘缓鎴愬姛: id=$txId');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鉁?璁拌处鎴愬姛',
            body: '宸茶嚜鍔ㄥ垱寤烘敮鍑鸿褰? 楼${ocrResult.amount}',
          );
        }
        return txId;
      } else {
        print('鉂?浜ゆ槗鍒涘缓澶辫触');
        if (showNotification) {
          await _showNotification(
            id: notificationId,
            title: '鉂?鍒涘缓澶辫触',
            body: '鏃犳硶鍒涘缓浜ゆ槗璁板綍',
          );
        }
        return null;
      }
    } catch (e) {
      print('鉂?[AutoBilling] 鏂囨湰澶勭悊澶辫触: $e');
      if (showNotification) {
        await _showNotification(
          id: 1002,
          title: '鉂?澶勭悊澶辫触',
          body: '閿欒: $e',
        );
      }
      return null;
    } finally {
      final totalElapsed =
          DateTime.now().millisecondsSinceEpoch - totalStartTime;
      print('鈴憋笍 [鎬ц兘] 鏂囨湰澶勭悊瀹屾垚, 鎬昏€楁椂=${totalElapsed}ms');
    }
  }

  /// 鍒涘缓浜ゆ槗璁板綍
  /// [billingTypes] 璁拌处鏂瑰紡鍒楄〃锛岀敤浜庢坊鍔犳爣绛?
  /// [autoAddTags] 鏄惁鑷姩娣诲姞鏍囩
  Future<int?> _createTransaction(
    OcrResult result, {
    List<String>? billingTypes,
    bool autoAddTags = true,
  }) async {
    try {
      // 鑾峰彇褰撳墠璐︽湰ID锛堜紭鍏堜粠Provider璇诲彇锛屽け璐ュ垯浠嶴haredPreferences璇诲彇锛屾渶鍚庝粠鏁版嵁搴撹幏鍙栭粯璁よ处鏈級
      int? ledgerId;

      // 鏂规1: 灏濊瘯浠嶱rovider璇诲彇
      try {
        ledgerId = _container.read(currentLedgerIdProvider);
        print('鉁?浠嶱rovider鑾峰彇璐︽湰ID: $ledgerId');
      } catch (e) {
        print('鈿狅笍 浠嶱rovider鑾峰彇璐︽湰ID澶辫触: $e');
      }

      // 鏂规2: 濡傛灉Provider澶辫触锛屼粠SharedPreferences璇诲彇
      if (ledgerId == null) {
        final prefs = await SharedPreferences.getInstance();
        ledgerId = prefs.getInt(_ledgerIdKey);
        if (ledgerId != null) {
          print('鉁?浠嶴haredPreferences鑾峰彇璐︽湰ID: $ledgerId');
        }
      }

      // 鏂规3: 濡傛灉閮藉け璐ワ紝浠庢暟鎹簱鑾峰彇绗竴涓处鏈?
      if (ledgerId == null) {
        print('鈿狅笍 鏃犳硶浠庣紦瀛樿幏鍙栬处鏈琁D锛屽皾璇曚粠鏁版嵁搴撹幏鍙栭粯璁よ处鏈?);
        final repo = _container.read(repositoryProvider);
        final ledgers = await repo.getAllLedgers();
        if (ledgers.isNotEmpty) {
          ledgerId = ledgers.first.id;
          print('鉁?浠庢暟鎹簱鑾峰彇榛樿璐︽湰ID: $ledgerId');
          // 淇濆瓨鍒癝haredPreferences渚涗笅娆′娇鐢?
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(_ledgerIdKey, ledgerId!);
        }
      }

      if (ledgerId == null) {
        print('鉂?鏃犳硶鑾峰彇浠讳綍璐︽湰ID锛岃鍏堝垱寤鸿处鏈?);
        return null;
      }

      print('馃摑 鍑嗗鍒涘缓浜ゆ槗: ledgerId=$ledgerId');

      // 浣跨敤鍏变韩鐨凚illCreationService鍒涘缓浜ゆ槗
      final repo = _container.read(repositoryProvider);
      final billCreationService = BillCreationService(repo);

      // 鍑嗗澶囨敞
      String? note;
      if (result.note != null) {
        note = result.note!;
      }

      // 鑾峰彇 l10n锛堜娇鐢ㄧ郴缁熻瑷€璁剧疆锛?
      final systemLocale = PlatformDispatcher.instance.locale;
      final l10n = lookupAppLocalizations(systemLocale);

      final transactionId = await billCreationService.createBillTransaction(
        result: result,
        ledgerId: ledgerId,
        note: note,
        billingTypes: billingTypes,
        l10n: l10n,
        autoAddTags: autoAddTags,
      );

      if (transactionId != null) {
        logger.info('AutoBilling', '浜ゆ槗璁板綍宸插垱寤?, 'ID=$transactionId');
        // 缁熶竴鍚庡鐞嗭細鍒锋柊UI + 瑙﹀彂浜戝悓姝?
        await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
      } else {
        logger.warning('AutoBilling', '鍒涘缓浜ゆ槗璁板綍澶辫触');
      }

      return transactionId;
    } catch (e) {
      print('鉂?鍒涘缓浜ゆ槗璁板綍澶辫触: $e');
      print('鉂?閿欒鍫嗘爤: ${StackTrace.current}');
      rethrow;
    }
  }

  /// 灏濊瘯绾疉I瑙嗚璇嗗埆锛堢洿鎺ヤ娇鐢℅LM瑙嗚妯″瀷锛岃烦杩嘙LKit OCR锛?
  Future<OcrResult?> _tryAiVision(File file, BaseRepository repo) async {
    try {
      List<String> expenseCategories = [];
      List<String> incomeCategories = [];
      List<String>? accounts;

      try {
        final expenseCats = await repo.getUsableCategories('expense');
        final incomeCats = await repo.getUsableCategories('income');
        expenseCategories = expenseCats.map((c) => c.name).toList();
        incomeCategories = incomeCats.map((c) => c.name).toList();
        final allAccounts = await repo.getAllAccounts();
        accounts = allAccounts.map((a) => a.name).toList();
      } catch (e) {
        logger.warning('AutoBilling', '鑾峰彇鍒嗙被/璐︽埛鍒楄〃澶辫触', e);
      }

      final service = BillExtractionService(
        expenseCategories: expenseCategories,
        incomeCategories: incomeCategories,
        accounts: accounts,
      );
      await service.init();

      final billInfo = await service.extractFromImage(file);
      if (billInfo == null || billInfo.amount == null || billInfo.amount!.abs() <= 0) {
        return null;
      }

      return OcrResult(
        amount: billInfo.amount,
        note: billInfo.note,
        time: billInfo.time,
        rawText: '',
        allNumbers: [billInfo.amount!.abs().toStringAsFixed(2)],
        aiCategoryName: billInfo.category,
        aiType: billInfo.type?.toString().split('.').last,
        aiAccountName: billInfo.account,
        aiProvider: 'AI',
        aiEnhanced: true,
      );
    } catch (e) {
      logger.warning('AutoBilling', 'AI瑙嗚璇嗗埆澶辫触锛屽噯澶囧洖閫€MLKit', e);
      return null;
    }
  }

  /// 鏄剧ず閫氱煡
  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'screenshot_ocr',
      '鎴浘璇嗗埆',
      channelDescription: '鎴浘鑷姩璇嗗埆閫氱煡',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notificationsPlugin.show(id, title, body, details);
  }

  /// 閲婃斁璧勬簮
  void dispose() {
    _ocrService.dispose();
  }
}
