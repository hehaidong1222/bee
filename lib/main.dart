import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'widgets/biz/login_2fa_challenge_view.dart';
import 'theme.dart';
import 'providers.dart';
import 'providers/font_scale_provider.dart';
import 'providers/cloud_mode_providers.dart';
import 'providers/ui_state_providers.dart';
import 'utils/notification_factory.dart';
import 'pages/auth/splash_page.dart';
import 'pages/auth/welcome_page.dart';
import 'pages/auth/app_lock_screen.dart';
import 'providers/security_providers.dart';
import 'services/system/reminder_monitor_service.dart';
import 'providers/credit_card_reminder_providers.dart';
import 'services/platform/screenshot_monitor_service.dart';
import 'services/platform/image_share_handler_service.dart';
import 'services/platform/app_link_service.dart';
import 'services/mcp/mcp_server.dart';
import 'services/system/logger_service.dart';
import 'l10n/app_localizations.dart';
import 'widget/widget_manager.dart';
import 'package:home_widget/home_widget.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';


/// 鍏ㄥ眬 navigator key 鈥?缁?service 灞?娌℃湁 BuildContext)push 璺敱浣跨敤銆?
/// 褰撳墠鐢ㄩ€?BeeCount Cloud 鐧诲綍鎷垮埌 requires_2fa 鏃跺脊鍑?[Login2FAChallengeView]銆?
final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 鍒濆鍖栨棩蹇楃郴缁燂紙纭繚鍘熺敓鏃ュ織妗ユ帴灏辩华锛?
  logger.info('App', '搴旂敤鍚姩锛屾棩蹇楃郴缁熷凡鍒濆鍖?);
  print('馃摫 LoggerService 宸插垵濮嬪寲');

  // 鍒濆鍖栨椂鍖猴紙蹇呴』鍦ㄩ€氱煡鏈嶅姟涔嬪墠锛屼慨澶峣OS閫氱煡闂锛?
  try {
    NotificationFactory.initializeTimeZone();
  } catch (e) {
    print('鈿狅笍  鏃跺尯鍒濆鍖栧け璐ワ紙鍙兘鍦ㄤ笉鏀寔鐨勫钩鍙颁笂杩愯锛? $e');
  }

  // 閰嶇疆iOS App Group锛坵idget鍜屼富app鍏变韩鏁版嵁蹇呴渶锛?
  try {
    if (Platform.isIOS) {
      await HomeWidget.setAppGroupId('group.com.tntlikely.beecount');
    }
  } catch (e) {
    print('鈿狅笍  HomeWidget 鎻掍欢鍒濆鍖栧け璐ワ紙鍙兘鍦ㄤ笉鏀寔鐨勫钩鍙颁笂杩愯锛? $e');
  }

  // 鍒濆鍖栭€氱煡鏈嶅姟
  try {
    final notificationUtil = NotificationFactory.getInstance();
    await notificationUtil.initialize();
  } catch (e) {
    print('鈿狅笍  閫氱煡鏈嶅姟鍒濆鍖栧け璐ワ紙鍙兘鍦ㄤ笉鏀寔鐨勫钩鍙颁笂杩愯锛? $e');
  }

  // 鎭㈠鐢ㄦ埛鐨勮璐︽彁閱掕缃紙鍏抽敭淇锛氬簲鐢ㄩ噸鍚悗鑷姩鎭㈠鎻愰啋锛?
  await _restoreUserReminder();

  // 鍚姩鎻愰啋鐩戞帶鏈嶅姟锛堢洃鍚簲鐢ㄧ敓鍛藉懆鏈燂紝鑷姩鎭㈠涓㈠け鐨勬彁閱掞級
  try {
    ReminderMonitorService().startMonitoring();
  } catch (e) {
    print('鈿狅笍  鎻愰啋鐩戞帶鏈嶅姟鍚姩澶辫触锛堝彲鑳藉湪涓嶆敮鎸佺殑骞冲彴涓婅繍琛岋級: $e');
  }

  // 鍒涘缓鍏ㄥ眬ProviderContainer锛堥渶瑕佸湪鍛ㄦ湡浜ゆ槗鐢熸垚涔嬪墠鍒涘缓锛屽洜涓洪渶瑕佷娇鐢?repositoryProvider锛?
  final container = ProviderContainer();

  // 鍒濆鍖栧簲鐢ㄦā寮忥紙闇€瑕佸湪鐢熸垚閲嶅浜ゆ槗涔嬪墠锛岀‘淇濇ā寮忔纭級
  // 鐩存帴浠?SharedPreferences 璇诲彇骞惰缃埌 appModeProvider
  await _initializeAppMode(container);

  // 娉ㄦ剰锛氫笉鍐嶅湪鍚姩鏃剁敓鎴愰噸澶嶄氦鏄?
  // 鍛ㄦ湡浜ゆ槗鐢熸垚宸茬Щ鑷?appSplashInitProvider 涓紙绛夊緟鏁版嵁搴撳畬鍏ㄥ垵濮嬪寲鍚庢墽琛岋級
  // await _generatePendingRecurringTransactions(container);

  // 鎭㈠淇＄敤鍗¤繕娆炬彁閱?
  try {
    final repo = container.read(repositoryProvider);
    await CreditCardReminderService.restoreAllReminders(
      getCreditCardAccounts: () => repo.getCreditCardAccounts(),
    );
  } catch (e) {
    // 闈欓粯澶辫触锛屼笉褰卞搷鍚姩
  }

  // [宸插垹闄 v1.15.0 璐︽埛鐙珛杩佺Щ & v2.7.1 杞处鍒嗙被杩佺Щ
  // 鎵€鏈夋椿璺冪敤鎴峰凡瀹屾垚锛孌rift onUpgrade 宸茶鐩栫浉鍏?schema 鍙樻洿
  // 纭紪鐮?SQL 閲嶅缓琛ㄤ細瀵艰嚧鏂板瀛楁涓㈠け锛堝 sort_order锛夛紝鏁呯Щ闄?

  // 娉ㄥ唽灏忕粍浠朵氦浜掑洖璋?
  try {
    await WidgetManager.registerCallback();
  } catch (e) {
    print('鈿狅笍  灏忕粍浠跺洖璋冩敞鍐屽け璐ワ紙鍙兘鍦ㄤ笉鏀寔鐨勫钩鍙颁笂杩愯锛? $e');
  }

  // 鎭㈠鎴浘鑷姩璇嗗埆璁剧疆锛圓ndroid涓撳睘锛夛紝浼犲叆container
  await _restoreScreenshotMonitor(container);

  // 鍒濆鍖栧浘鐗囧垎浜鐞嗘湇鍔★紙Android涓撳睘锛?
  if (Platform.isAndroid) {
    _setupImageShareHandler(container);
  }

  // 鍚姩 URL 鐩戝惉锛堢敤浜庡揩鎹锋寚浠?AppLink 鑷姩璁拌处锛?
  _setupUrlListener(container);

  // 鍚姩鏈湴 MCP 鏈嶅姟鍣紙渚涘皬绫?MiClip 绛?MCP 瀹㈡埛绔煡璇㈣处鍗曪級
  _setupMCPServer(container);

  // 娉ㄥ唽 BeeCount Cloud 2FA challenge handler銆傚綋 server 杩斿洖 requires_2fa=true,
  // service 灞備細璋冭繖涓?handler 寮瑰嚭 Login2FAChallengeDialog 璁╃敤鎴疯緭鐮併€?
  // 楠岃瘉澶辫触鐣欏湪瀵硅瘽妗嗗氨鍦板睍绀洪敊璇?楠岃瘉閫氳繃 / 鐢ㄦ埛鍙栨秷鎵嶅叧闂€傝瑙?.docs/2fa-design.md
  BeeCountCloudProvider.globalTwoFactorHandler = (request) async {
    final ctx = globalNavigatorKey.currentContext;
    if (ctx == null) {
      // 鏋佺鍦烘櫙:cloud auth 鍦?navigator 杩樻病 attach 涔嬪墠瑙﹀彂,鍙兘瑙嗕负鍙栨秷
      return false;
    }
    return await Login2FAChallengeDialog.show(ctx, request);
  };

  // 鍚姩涓€娆℃€х鐩樺绔嬫枃浠?GC(attachments / attachment_thumbs / custom_icons),
  // 娓呯悊鍘嗗彶鐗堟湰閬楃暀鐨勬枃浠躲€傛爣蹇椾綅 SharedPreferences 淇濊瘉鍙窇涓€娆°€傚悗鍙板紓姝?
  // 鎵ц,澶辫触涓嶈嚧鍛姐€?
  unawaited(_runOrphanFileGcOnce(container));

  runApp(ProviderScope(
    parent: container,
    observers: const [_WidgetUpdateObserver()],
    child: const MainApp(),
  ));
}

/// Provider observer to update widget on app start
class _WidgetUpdateObserver extends ProviderObserver {
  const _WidgetUpdateObserver();
  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    // Update widget when current ledger is loaded
    if (provider == currentLedgerIdProvider && newValue != null) {
      _updateWidgetOnStart(container);
    }
  }

  void _updateWidgetOnStart(ProviderContainer container) async {
    try {
      final repository = container.read(repositoryProvider);
      final ledgerId = container.read(currentLedgerIdProvider);
      final primaryColor = container.read(primaryColorProvider);
      final redForIncome = container.read(incomeExpenseColorSchemeProvider);

      final widgetManager = WidgetManager();
      await widgetManager.updateWidget(
        repository,
        ledgerId,
        primaryColor,
        redForIncome: redForIncome,
      );

      print('鉁?灏忕粍浠舵暟鎹凡鏇存柊');
    } catch (e) {
      print('鉂?鏇存柊灏忕粍浠跺け璐ワ紙鍙兘鍦ㄤ笉鏀寔鐨勫钩鍙颁笂杩愯锛? $e');
    }
  }
}

/// 鎭㈠鐢ㄦ埛涔嬪墠璁剧疆鐨勮璐︽彁閱?
///
/// 闂鍦烘櫙锛?
/// - 搴旂敤琚郴缁熸潃姝诲悗锛岄€氱煡浠诲姟浼氫涪澶?
/// - 搴旂敤鏇存柊鍚庯紝閫氱煡浠诲姟浼氳娓呴櫎
/// - 鎵嬫満閲嶅惎鍚庯紝閫氱煡浠诲姟闇€瑕侀噸鏂拌缃?
///
/// 瑙ｅ喅鏂规锛?
/// - 鍦ㄥ簲鐢ㄥ惎鍔ㄦ椂妫€鏌ョ敤鎴锋槸鍚﹀紑鍚簡鎻愰啋
/// - 濡傛灉寮€鍚簡锛岄噸鏂拌缃€氱煡浠诲姟
Future<void> _restoreUserReminder() async {
  try {
    print('馃攧 妫€鏌ュ苟鎭㈠璁拌处鎻愰啋...');
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('reminder_enabled') ?? false;

    if (isEnabled) {
      final hour = prefs.getInt('reminder_hour') ?? 21;
      final minute = prefs.getInt('reminder_minute') ?? 0;
      print('鉁?鍙戠幇鐢ㄦ埛宸插惎鐢ㄨ璐︽彁閱? ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}');
      print('馃敂 姝ｅ湪閲嶆柊璁剧疆鎻愰啋浠诲姟...');

      try {
        final notificationUtil = NotificationFactory.getInstance();
        await notificationUtil.scheduleDailyReminder(
          id: 1001,
          title: '璁拌处鎻愰啋',
          body: '鍒繕浜嗚褰曚粖澶╃殑鏀舵敮鍝?馃挵',
          hour: hour,
          minute: minute,
        );
        print('鉁?璁拌处鎻愰啋宸叉垚鍔熸仮澶?);
      } catch (e) {
        print('鉂?璁拌处鎻愰啋璁剧疆澶辫触锛堝彲鑳藉湪涓嶆敮鎸佺殑骞冲彴涓婅繍琛岋級: $e');
      }
    } else {
      print('鈩癸笍  鐢ㄦ埛鏈惎鐢ㄨ璐︽彁閱掞紝璺宠繃鎭㈠');
    }
  } catch (e) {
    print('鉂?鎭㈠璁拌处鎻愰啋澶辫触: $e');
    // 涓嶆姏鍑哄紓甯革紝閬垮厤褰卞搷搴旂敤鍚姩
  }
}

/// 鎭㈠鎴浘鑷姩璇嗗埆璁剧疆锛堜粎Android锛?
///
/// 闂鍦烘櫙锛?
/// - 搴旂敤閲嶅惎鍚庯紝鎴浘鐩戝惉鏈嶅姟浼氫涪澶?
/// - 闇€瑕佽嚜鍔ㄦ仮澶嶇敤鎴蜂箣鍓嶇殑璁剧疆
///
/// 瑙ｅ喅鏂规锛?
/// - 鍦ㄥ簲鐢ㄥ惎鍔ㄦ椂妫€鏌ョ敤鎴锋槸鍚﹀紑鍚簡鎴浘鐩戝惉
/// - 濡傛灉寮€鍚簡锛岄噸鏂板惎鍔ㄧ洃鍚湇鍔?
Future<void> _restoreScreenshotMonitor(ProviderContainer container) async {
  if (!Platform.isAndroid) return;

  try {
    print('馃摳 妫€鏌ュ苟鎭㈠鎴浘鑷姩璇嗗埆...');
    final screenshotMonitor = ScreenshotMonitorService(container);
    final isEnabled = await screenshotMonitor.isEnabled();

    if (isEnabled) {
      print('鉁?鍙戠幇鐢ㄦ埛宸插惎鐢ㄦ埅鍥捐嚜鍔ㄨ瘑鍒?);
      print('馃攧 姝ｅ湪閲嶆柊鍚姩鐩戝惉鏈嶅姟...');
      await screenshotMonitor.enable();
      print('鉁?鎴浘鐩戝惉鏈嶅姟宸叉垚鍔熸仮澶?);
    } else {
      print('鈩癸笍  鐢ㄦ埛鏈惎鐢ㄦ埅鍥捐嚜鍔ㄨ瘑鍒紝璺宠繃鎭㈠');
    }
  } catch (e) {
    print('鉂?鎭㈠鎴浘鐩戝惉澶辫触: $e');
    // 涓嶆姏鍑哄紓甯革紝閬垮厤褰卞搷搴旂敤鍚姩
  }
}

/// 鍒濆鍖栧簲鐢ㄦā寮?
///
/// 鍦ㄥ簲鐢ㄥ惎鍔ㄦ椂浠?SharedPreferences 璇诲彇妯″紡骞惰缃埌 appModeProvider
/// 杩欐牱鍙互纭繚鍚庣画浣跨敤 repositoryProvider 鏃惰兘鑾峰彇鍒版纭殑妯″紡
/// [container] Provider瀹瑰櫒
Future<void> _initializeAppMode(ProviderContainer container) async {
  try {
    print('鈴?鍒濆鍖栧簲鐢ㄦā寮?..');

    // 浠?SharedPreferences 鐩存帴璇诲彇妯″紡
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString('app_mode');
    final mode = modeStr != null ? AppMode.fromString(modeStr) : AppMode.local;

    // 浣跨敤 switchMode 鏂规硶璁剧疆妯″紡锛岀‘淇?repositoryProvider 鑳界珛鍗宠幏鍙栧埌姝ｇ‘鐨勬ā寮?
    // switchMode 涓嶄細閲嶅鍐欏叆 SharedPreferences锛屽洜涓哄€煎凡缁忓瓨鍦?
    await container.read(appModeProvider.notifier).switchMode(mode);

    print('鉁?搴旂敤妯″紡宸插垵濮嬪寲: ${mode.label}');
  } catch (e, stackTrace) {
    print('鈿狅笍  搴旂敤妯″紡鍒濆鍖栧け璐? $e');
    logger.error('Main', '搴旂敤妯″紡鍒濆鍖栧け璐?, e, stackTrace);
  }
}


/// 璁剧疆鍥剧墖鍒嗕韩澶勭悊锛圓ndroid涓撳睘锛?
///
/// 鍒濆鍖?ImageShareHandlerService 浠ユ帴鏀朵粠鐩稿唽鎴栧叾浠栧簲鐢ㄥ垎浜殑鍥剧墖
/// 鍒嗕韩鐨勫浘鐗囦細鑷姩瑙﹀彂璁拌处娴佺▼
void _setupImageShareHandler(ProviderContainer container) {
  try {
    logger.info('App', '馃柤锔? [Android] 鍒濆鍖栧浘鐗囧垎浜鐞嗘湇鍔?..');

    // 鍒濆鍖栨湇鍔★紙浼氳嚜鍔ㄨ缃甅ethodChannel鐩戝惉鍣級
    ImageShareHandlerService(container);

    logger.info('App', '鉁?[Android] 鍥剧墖鍒嗕韩澶勭悊鏈嶅姟宸插惎鍔?);
  } catch (e) {
    logger.error('App', '鉂?[Android] 鍥剧墖鍒嗕韩澶勭悊鏈嶅姟鍒濆鍖栧け璐?, e);
    // 涓嶆姏鍑哄紓甯革紝閬垮厤褰卞搷搴旂敤鍚姩
  }
}

/// 璁剧疆 URL 鐩戝惉锛堢敤浜?AppLink锛?
///
/// 鐩戝惉 beecount:// URL Scheme 璋冪敤
/// 鏀寔鐨刄RL鏍煎紡:
/// - beecount://voice - 璇煶璁拌处
/// - beecount://image - 鍥剧墖璁拌处锛堜粠鐩稿唽锛?
/// - beecount://camera - 鎷嶇収璁拌处
/// - beecount://ai-chat - AI 灏忓姪鎵?
/// - beecount://add?amount=100&type=expense - 鑷姩璁拌处
/// - beecount://auto-billing?text=... - 鏂囨湰鑷姩璁拌处锛堝吋瀹规棫鐗堬級
/// - beecount://quick-billing - 蹇€熻璐︼紙鍏煎鏃х増锛?
void _setupUrlListener(ProviderContainer container) {
  try {
    logger.info('AppLink', '鍒濆鍖朥RL鐩戝惉...');

    final appLinks = AppLinks();
    final appLinkService = AppLinkService(container);

    // 璁剧疆瀵艰埅鍥炶皟
    appLinkService.onNavigate = (action, {params}) {
      logger.info('AppLink', '瑙﹀彂瀵艰埅: $action');
      if (action == AppLinkAction.newTransaction && params != null) {
        container.read(pendingNewTransactionTypeProvider.notifier).state = params.type;
      }
      container.read(pendingAppLinkActionProvider.notifier).state = action;
    };

    // 鐩戝惉URL锛堝簲鐢ㄥ湪鍚庡彴鏃讹級
    appLinks.uriLinkStream.listen((uri) {
      logger.info('AppLink', '鏀跺埌URL: $uri');
      appLinkService.handleUrl(uri);
    }, onError: (err) {
      logger.error('AppLink', 'URL鐩戝惉閿欒', err);
    });

    // 娉ㄦ剰锛氫笉浣跨敤 getInitialLink/getLatestLink锛屽洜涓哄畠浠細缂撳瓨鏃ч摼鎺?
    // 鍙緷璧?uriLinkStream锛屽畠浼氬湪搴旂敤閫氳繃 URL 鍚姩鏃剁珛鍗宠Е鍙?

    logger.info('AppLink', 'URL鐩戝惉宸插惎鍔?);
  } catch (e) {
    logger.error('AppLink', 'URL鐩戝惉鍒濆鍖栧け璐?, e);
    // 涓嶆姏鍑哄紓甯革紝閬垮厤褰卞搷搴旂敤鍚姩
  }
}

/// 鍏ㄥ眬 MCP 鏈嶅姟鍣ㄥ疄渚?
final MCPServer globalMCPServer = MCPServer();

/// 璁剧疆 MCP 鏈嶅姟鍣紙鏈湴 HTTP 鏈嶅姟锛屼緵 MiClip 绛?AI 鍔╂墜鏌ヨ璐﹀崟锛?
void _setupMCPServer(ProviderContainer container) {
  try {
    logger.info('MCP', '姝ｅ湪鍚姩 MCP 鏈嶅姟鍣?..');
    final repo = container.read(repositoryProvider);
    unawaited(globalMCPServer.start(repo: repo));
    logger.info('MCP', 'MCP 鏈嶅姟鍣ㄥ凡鍔犲叆鍚姩闃熷垪');
  } catch (e) {
    logger.error('MCP', 'MCP 鏈嶅姟鍣ㄥ惎鍔ㄥけ璐?, e);
  }
}

class NoGlowScrollBehavior extends MaterialScrollBehavior {
  const NoGlowScrollBehavior();
  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child; // 鍘婚櫎 Android 涓婄殑鍙戝厜鏁堟灉锛岄伩鍏嶉《閮ㄥ嚭鐜颁竴鎶圭孩
  }
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  // 鏍规嵁鍒濆鍖栫姸鎬佸拰娆㈣繋椤甸潰鐘舵€佸喅瀹氭樉绀哄摢涓〉闈?
  Widget _getHomePage(AppInitState initState, WidgetRef ref) {
    // 棣栧厛妫€鏌ユ槸鍚﹂渶瑕佹樉绀烘杩庨〉闈?
    final shouldShowWelcome = ref.watch(shouldShowWelcomeProvider);
    if (shouldShowWelcome) {
      return const WelcomePage();
    }

    // 娆㈣繋椤甸潰瀹屾垚鍚庯紝鏍规嵁鍒濆鍖栫姸鎬佹樉绀哄搴旈〉闈?
    if (initState != AppInitState.ready) {
      return const SplashPage();
    }

    // 妫€鏌ユ槸鍚﹂渶瑕佹樉绀洪攣灞?
    final isLocked = ref.watch(isAppLockedProvider);
    if (isLocked) {
      return const AppLockScreen();
    }

    return const BeeApp();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 棣栧厛妫€鏌ユ槸鍚﹂渶瑕佹樉绀烘杩庨〉闈?
    ref.watch(welcomeCheckProvider);

    // 妫€鏌ュ簲鐢ㄥ垵濮嬪寲鐘舵€?
    final initState = ref.watch(appInitStateProvider);
    final selectedLanguage = ref.watch(languageProvider);

    // 濡傛灉鏄惎灞忕姸鎬侊紝鍚姩鍒濆鍖?
    if (initState == AppInitState.splash) {
      ref.watch(appSplashInitProvider);
    }

    // 鍛ㄦ湡浜ゆ槗鐢熸垚宸茬粺涓€鍦?appSplashInitProvider 涓鐞?

    final primary = ref.watch(primaryColorProvider);
    final platform = Theme.of(context).platform; // 褰撳墠骞冲彴
    final base = BeeTheme.lightTheme(platform: platform);
    final baseTextTheme = base.textTheme;

    // 猸?浜壊涓婚
    final theme = base.copyWith(
      textTheme: baseTextTheme,
      colorScheme: base.colorScheme.copyWith(primary: primary),
      primaryColor: primary,
      scaffoldBackgroundColor: Colors.white,
      dividerColor: Colors.black.withOpacity(0.06),
      listTileTheme: ListTileThemeData(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        iconColor: const Color(0xFF111827),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: baseTextTheme.titleMedium?.copyWith(
            color: const Color(0xFF111827), fontWeight: FontWeight.w600),
        contentTextStyle:
            baseTextTheme.bodyMedium?.copyWith(color: const Color(0xFF6B7280)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: baseTextTheme.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
        selectedItemColor: primary,
        type: BottomNavigationBarType.fixed,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
    );
    // Clamp 绯荤粺瀛椾綋缂╂斁锛岄伩鍏嶉儴鍒嗚澶囪缃?1.5+ 閫犳垚 UI 婧㈠嚭
    final media = MediaQuery.of(context);
    // init font scale persistence
    ref.watch(fontScaleInitProvider);
    final customScale = ref.watch(effectiveFontScaleProvider);
    final clamped = media.textScaler.clamp(
      minScaleFactor: 0.85,
      maxScaleFactor: 1.15,
    );
    final combinedScale = clamped.scale(customScale); // returns double
    final newScaler = TextScaler.linear(combinedScale);
    return MediaQuery(
      data: media.copyWith(textScaler: newScaler),
      child: MaterialApp(
        navigatorKey: globalNavigatorKey,
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        scrollBehavior: const NoGlowScrollBehavior(),
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: BeeTheme.darkTheme(platform: platform).copyWith(
          colorScheme: BeeTheme.darkTheme(platform: platform).colorScheme.copyWith(primary: primary),
          primaryColor: primary,
        ),                                                // 猸?鏆楅粦涓婚锛堜娇鐢ㄥ姩鎬佷富棰樿壊锛?
        themeMode: ref.watch(themeModeProvider),         // 猸?浣跨敤 provider 鏀寔鎵嬪姩鍒囨崲
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
          Locale('zh'),
          Locale('zh', 'TW'),
        ],
        locale: selectedLanguage,
        builder: (context, child) {
          final showPrivacy = ref.watch(showPrivacyScreenProvider);
          return Stack(
            children: [
              child ?? const SizedBox.shrink(),
              if (showPrivacy)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.lock_outline_rounded,
                        size: 64,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        // 鏄惧紡鍛藉悕鏍硅矾鐢憋紝渚夸簬璺敱鏃ュ織涓?popUntil 绮剧‘璇嗗埆
        home: _getHomePage(initState, ref),
        onGenerateRoute: (settings) {
          if (settings.name == Navigator.defaultRouteName ||
              settings.name == '/') {
            return MaterialPageRoute(
                builder: (_) => _getHomePage(initState, ref),
                settings: const RouteSettings(name: '/'));
          }
          return null;
        },
      ),
    );
  }
}

/// 涓€娆℃€х鐩樺绔嬫枃浠舵竻鐞?鈥斺€?娓呭巻鍙茬増鏈仐鐣欑殑:
///   - `attachments/*.jpg` + `attachment_thumbs/*.jpg`:鍘嗗彶 sync pull 鍒犱氦鏄撴椂
///     鍙垹琛ㄨ涓嶆竻纾佺洏,鎴栬€呯敤鎴风鍦ㄦ煇鐗堟湰涔嬪墠娌℃湁瀹屾暣娓呯悊鐨勯檮浠?
///   - `custom_icons/*.png`:鏃х増 deleteCategory 鍙垹鍒嗙被琛?customIconPath 鎸囧悜
///     鐨勬湰鍦板浘鏍囨枃浠堕仐鐣?
///
/// SharedPreferences 鏍囧織浣?`orphan_file_gc_v1_done` 淇濊瘉鍙窇涓€娆°€傚け璐ュ叏閮?
/// try/catch 鍚炴帀 鈥斺€?杩欐槸 nice-to-have,涓嶅簲 block app 鍚姩銆?
Future<void> _runOrphanFileGcOnce(ProviderContainer container) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    const flagKey = 'orphan_file_gc_v1_done';
    if (prefs.getBool(flagKey) == true) return;

    final db = container.read(databaseProvider);

    // 缁欎富绾跨▼璁╄矾,鍚姩鍏抽敭璺緞鍏堣窇瀹?
    await Future.delayed(const Duration(seconds: 3));

    var attCleaned = 0;
    var thumbCleaned = 0;
    var iconCleaned = 0;

    // --- attachments / attachment_thumbs ---
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final attDir = Directory('${appDir.path}/attachments');
      if (await attDir.exists()) {
        final usedNames = <String>{
          for (final row in await db.select(db.transactionAttachments).get())
            row.fileName,
        };
        await for (final entity in attDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedNames.contains(name)) {
            try {
              await entity.delete();
              attCleaned++;
            } catch (e) {
              logger.warning('OrphanGC', 'unlink attachment failed $name: $e');
            }
          }
        }
      }

      final cacheDir = await getTemporaryDirectory();
      final thumbDir = Directory('${cacheDir.path}/attachment_thumbs');
      if (await thumbDir.exists()) {
        // 缂╃暐鍥惧懡鍚嶈鍒?`<basename(fileName)>_thumb.jpg`
        final usedThumbNames = <String>{
          for (final row in await db.select(db.transactionAttachments).get())
            '${p.basenameWithoutExtension(row.fileName)}_thumb.jpg',
        };
        await for (final entity in thumbDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedThumbNames.contains(name)) {
            try {
              await entity.delete();
              thumbCleaned++;
            } catch (_) {/* best effort */}
          }
        }
      }
    } catch (e, st) {
      logger.warning('OrphanGC', 'attachment scan failed: $e\n$st');
    }

    // --- custom_icons ---
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final iconDir = Directory('${appDir.path}/custom_icons');
      if (await iconDir.exists()) {
        final usedIconNames = <String>{};
        final categoryRows = await (db.select(db.categories)
              ..where((c) => c.customIconPath.isNotNull()))
            .get();
        for (final row in categoryRows) {
          final cp = row.customIconPath;
          if (cp != null && cp.trim().isNotEmpty) {
            usedIconNames.add(p.basename(cp));
          }
        }
        await for (final entity in iconDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedIconNames.contains(name)) {
            try {
              await entity.delete();
              iconCleaned++;
            } catch (e) {
              logger.warning('OrphanGC', 'unlink custom icon failed $name: $e');
            }
          }
        }
      }
    } catch (e, st) {
      logger.warning('OrphanGC', 'custom_icons scan failed: $e\n$st');
    }

    await prefs.setBool(flagKey, true);
    logger.info(
      'OrphanGC',
      '涓€娆℃€ф竻鐞嗗畬鎴?attachments=$attCleaned thumbs=$thumbCleaned icons=$iconCleaned',
    );
  } catch (e, st) {
    // 浠讳綍寮傚父閮戒笉璇ュ奖鍝?app 鍚姩銆備笅娆″惎鍔ㄨ繕浼氶噸璇?鍥犱负娌¤ flag)銆?
    logger.warning('OrphanGC', '涓€娆℃€ф竻鐞嗗紓甯?浼氬湪涓嬫鍚姩閲嶈瘯): $e\n$st');
  }
}
