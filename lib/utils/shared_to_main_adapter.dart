/// 共享账本表 → 主表 Drift 行的轻量适配器。
///
/// `SharedCategory` / `SharedAccount` / `SharedTag` 跟 `Category` / `Account` /
/// `Tag` 字段几乎一对一(只差 parentId 这种本地外键不通用的字段),用这套
/// adapter 把 Shared 行包装成主表类型,让上层 UI 完全不需要知道数据来源。
///
/// 关键不变量:**SharedCategory.id 跟 Category.id 不会撞**(都是 autoIncrement
/// 但分两张表)— Transactions.categoryId 在共享账本下指向 SharedCategory.id,
/// 在非共享下指向 Category.id。读取时 repo 按 ledger 选择 join 哪张表。
library;

import '../data/db.dart';

/// SharedCategory → Category。parentId / communityIconId 没意义,填 null。
Category sharedCategoryAsCategory(SharedCategory s) => Category(
      id: s.id,
      name: s.name,
      kind: s.kind,
      icon: s.icon,
      sortOrder: s.sortOrder,
      parentId: null,
      level: s.level,
      iconType: s.iconType,
      customIconPath: s.customIconPath,
      communityIconId: null,
      syncId: s.syncId,
    );

/// SharedAccount → Account。legacy ledgerId 字段没意义,填 -1。
Account sharedAccountAsAccount(SharedAccount s) => Account(
      id: s.id,
      ledgerId: -1, // legacy field;account 跨账本可见,这列实际无用
      name: s.name,
      type: s.type,
      currency: s.currency,
      initialBalance: s.initialBalance,
      createdAt: null,
      updatedAt: null,
      sortOrder: s.sortOrder,
      creditLimit: s.creditLimit,
      billingDay: s.billingDay,
      paymentDueDay: s.paymentDueDay,
      bankName: s.bankName,
      cardLastFour: s.cardLastFour,
      note: s.note,
      syncId: s.syncId,
    );

/// SharedTag → Tag。createdAt 用当前时间兜底(UI 一般不用)。
Tag sharedTagAsTag(SharedTag s) => Tag(
      id: s.id,
      name: s.name,
      color: s.color,
      sortOrder: s.sortOrder,
      createdAt: DateTime.now(),
      syncId: s.syncId,
    );
