import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/home_page.dart';
import 'pages/analytics_page.dart';
import 'pages/ledgers_page.dart';
import 'pages/mine_page.dart';
import 'pages/category_picker.dart';
import 'pages/personalize_page.dart' show headerStyleProvider;
import 'providers.dart';
import 'utils/ui_scale_extensions.dart';
import 'l10n/app_localizations.dart';
import 'widgets/voice_input_dialog.dart';

class BeeApp extends ConsumerStatefulWidget {
  const BeeApp({super.key});

  @override
  ConsumerState<BeeApp> createState() => _BeeAppState();
}

class _BeeAppState extends ConsumerState<BeeApp> {
  final _pages = const [
    HomePage(),
    AnalyticsPage(),
    LedgersPage(),
    MinePage(),
  ];

  // 双击检测：记录最后一次点击的时间和索引
  DateTime? _lastTapTime;
  int? _lastTappedIndex;

  @override
  Widget build(BuildContext context) {
    // 将 4 个页面映射到 5 槽位（中间为“+”）：页面索引 0,1,2,3 对应视觉槽位 0,1,3,4（槽位 2 为 +）。
    final idx = ref.watch(bottomTabIndexProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        // 拦截根路由的返回键，避免意外将根路由 pop 到空导致黑屏。
        // 若需要支持"再次返回退出应用"，可在此实现双击退出逻辑。
        // didPop will be false since canPop is false
      },
      child: Scaffold(
        body: IndexedStack(
          index: idx,
          children: _pages,
        ),
        bottomNavigationBar: BottomAppBar(
          color: Colors.white,
          shape: const CircularNotchedRectangle(),
          notchMargin: 8.0.scaled(context, ref),
          elevation: 8,
          child: SizedBox(
            height: 60.0.scaled(context, ref),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(5, (i) {
                if (i == 2) {
                  // 中间预留给 FAB 的槽位，确保 5 等分
                  return const Expanded(child: SizedBox());
                }
                // 槽位转页面索引
                final pageIndex = i > 2 ? i - 1 : i;
                final activeVisualIndex = idx >= 2 ? idx + 1 : idx;
                final active = activeVisualIndex == i;
                Color color = active
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black54;
                IconData icon;
                String label;
                final l10n = AppLocalizations.of(context);
                switch (pageIndex) {
                  case 0:
                    icon = Icons.list_alt_rounded;
                    label = l10n.tabHome;
                    break;
                  case 1:
                    icon = Icons.pie_chart_rounded;
                    label = l10n.tabAnalytics;
                    break;
                  case 2:
                    icon = Icons.menu_book_rounded;
                    label = l10n.tabLedgers;
                    break;
                  default:
                    icon = Icons.person_rounded;
                    label = l10n.tabMine;
                }
                return Expanded(
                  child: InkWell(
                    onTap: () {
                      final now = DateTime.now();
                      // 检测双击：同一个标签在300ms内连续点击两次
                      if (_lastTappedIndex == pageIndex &&
                          _lastTapTime != null &&
                          now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
                        // 双击首页标签，触发滚动到顶部
                        if (pageIndex == 0) {
                          ref.read(homeScrollToTopProvider.notifier).state++;
                        }
                        // 重置双击状态
                        _lastTapTime = null;
                        _lastTappedIndex = null;
                      } else {
                        // 记录本次点击
                        _lastTapTime = now;
                        _lastTappedIndex = pageIndex;
                        // 切换标签
                        ref.read(bottomTabIndexProvider.notifier).state = pageIndex;
                      }
                    },
                    child: Padding(
                      padding: EdgeInsets.only(top: 8.0.scaled(context, ref)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, color: color),
                          SizedBox(height: 4.0.scaled(context, ref)),
                          Text(label,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: color,
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.w400)),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        floatingActionButton: Consumer(builder: (context, ref, _) {
          final style = ref.watch(headerStyleProvider);
          final color = Theme.of(context).colorScheme.primary;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 语音记账按钮
              SizedBox(
                width: 56.0.scaled(context, ref),
                height: 56.0.scaled(context, ref),
                child: FloatingActionButton(
                  heroTag: 'voiceFab',
                  elevation: 4,
                  shape: const CircleBorder(),
                  backgroundColor: Colors.white,
                  onPressed: () async {
                    final parsed = await showVoiceInputDialog(context);
                    if (parsed != null && parsed.isValid && context.mounted) {
                      // 跳转到记账页面，传入解析结果
                      final db = ref.read(databaseProvider);

                      // 查找匹配的分类
                      int? categoryId;
                      if (parsed.categoryName != null) {
                        final categoryKind = parsed.type?.name ?? 'expense';
                        final categories = await (db.select(db.categories)
                              ..where((t) => t.kind.equals(categoryKind)))
                            .get();
                        final category = categories.where((c) => c.name == parsed.categoryName).firstOrNull;
                        categoryId = category?.id;
                      }

                      // 跳转到记账页面
                      if (context.mounted) {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CategoryPickerPage(
                              initialKind: parsed.type?.name ?? 'expense',
                              quickAdd: true,
                              initialAmount: parsed.amount,
                              initialCategoryId: categoryId,
                              initialNote: parsed.note,
                            ),
                          ),
                        );
                      }
                    }
                  },
                  child: Icon(Icons.mic, color: color, size: 24.0.scaled(context, ref)),
                ),
              ),
              SizedBox(height: 12.0.scaled(context, ref)),
              // 原有的添加按钮
              SizedBox(
                width: 80.0.scaled(context, ref),
                height: 80.0.scaled(context, ref),
                child: FloatingActionButton(
                  heroTag: 'addFab',
                  elevation: 8,
                  shape: const CircleBorder(),
                  backgroundColor: style == 'primary' ? color : color,
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CategoryPickerPage(
                          initialKind: 'expense',
                          quickAdd: true,
                        ),
                      ),
                    );
                  },
                  child: Icon(Icons.add, color: Colors.white, size: 34.0.scaled(context, ref)),
                ),
              ),
            ],
          );
        }),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      ),
    );
  }
}
