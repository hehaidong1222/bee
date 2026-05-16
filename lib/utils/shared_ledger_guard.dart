/// 共享账本权限守卫。
///
/// 一个集中判断"当前账本是不是 B 是 Editor 角色的共享账本"的 helper,UI 层
/// 根据返回值决定隐藏写按钮 / 切换数据源。
library;

import '../data/db.dart';

/// 当前账本是 "B 是 Editor 角色的共享账本"
/// - 单人账本(isShared=false)→ false
/// - Owner 的共享账本(myRole='owner')→ false(Owner 仍可改账本元信息)
/// - Editor 视角的共享账本(isShared=true && myRole != 'owner')→ true
bool isReadOnlySharedContext(Ledger? ledger) {
  if (ledger == null) return false;
  if (!ledger.isShared) return false;
  return ledger.myRole != 'owner';
}
