library;

import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

String shortCollabUserId(String userId) {
  final normalized = userId.trim();
  if (normalized.length <= 8) {
    return normalized;
  }
  return normalized.substring(0, 8);
}

String resolveCollabMemberName({
  required String userId,
  String? displayName,
  String? email,
  String? fallbackUnknown,
}) {
  final display = (displayName ?? '').trim();
  if (display.isNotEmpty) {
    return display;
  }
  final mail = (email ?? '').trim();
  if (mail.isNotEmpty) {
    return mail;
  }
  final shortId = shortCollabUserId(userId);
  if (shortId.isNotEmpty) {
    return shortId;
  }
  return (fallbackUnknown ?? 'Unknown').trim();
}

class CollabMemberAvatar extends StatelessWidget {
  const CollabMemberAvatar({
    super.key,
    required this.userId,
    required this.label,
    this.avatarUrl,
    this.size = 20,
  });

  final String userId;
  final String label;
  final String? avatarUrl;
  final double size;

  String _initial(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '?';
    }
    return trimmed.substring(0, 1).toUpperCase();
  }

  Color _backgroundColor(BuildContext context) {
    final source = userId.trim().isNotEmpty ? userId.trim() : label.trim();
    final hash = source.hashCode.abs();
    final hue = (hash % 360).toDouble();
    final isDark = BeeTokens.isDark(context);
    return HSLColor.fromAHSL(
      1,
      hue,
      0.48,
      isDark ? 0.34 : 0.76,
    ).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = (avatarUrl ?? '').trim();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _backgroundColor(context),
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: normalizedUrl.isNotEmpty
            ? Image.network(
                normalizedUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallbackText(context),
              )
            : _fallbackText(context),
      ),
    );
  }

  Widget _fallbackText(BuildContext context) {
    return Center(
      child: Text(
        _initial(label),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          color: BeeTokens.textPrimary(context),
          height: 1,
        ),
      ),
    );
  }
}
