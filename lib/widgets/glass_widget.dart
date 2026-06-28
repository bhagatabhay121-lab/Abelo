import 'dart:ui';
import 'package:flutter/material.dart';

/// Reusable glassmorphism container used across the whole app.
class GlassBox extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Color? borderColor;
  final double borderWidth;
  final List<BoxShadow>? shadows;

  const GlassBox({
    super.key,
    required this.child,
    this.blur = 18,
    this.opacity = 0.15,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.padding,
    this.borderColor,
    this.borderWidth = 1.0,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(opacity),
            borderRadius: borderRadius,
            border: Border.all(
              color: borderColor ?? Colors.white.withOpacity(0.18),
              width: borderWidth,
            ),
            boxShadow: shadows,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Shows a glassy center dialog with a title row, optional subtitle,
/// and a list of action tiles — replaces all bottom sheets in the app.
Future<T?> showGlassMenuDialog<T>({
  required BuildContext context,
  required String title,
  IconData? titleIcon,
  Widget? header, // optional song header row
  required List<Widget> items,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Material(
              color: Colors.transparent,
              child: GlassBox(
                borderRadius: BorderRadius.circular(24),
                opacity: 0.20,
                blur: 32,
                borderColor: Colors.white.withOpacity(0.15),
                borderWidth: 1.2,
                shadows: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.40),
                    blurRadius: 40,
                    offset: const Offset(0, 10),
                  ),
                ],
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Title bar ──────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 16, 14),
                      child: Row(
                        children: [
                          if (titleIcon != null) ...[
                            Icon(titleIcon, color: Colors.white, size: 20),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(ctx),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.10),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white.withOpacity(0.60),
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── Optional song header ───────────────────────
                    if (header != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: header,
                      ),
                    ],
                    Divider(height: 1, color: Colors.white.withOpacity(0.09)),
                    // ── Action items ───────────────────────────────
                    ...items,
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Keep the bottom sheet helpers for _showSongDetails & playlist picker
/// which need scroll / draggable behaviour.
Future<T?> showGlassBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext, ScrollController?) builder,
  bool isDraggable = false,
  double initialSize = 0.55,
  double minSize = 0.35,
  double maxSize = 0.92,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.5),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      if (isDraggable) {
        return DraggableScrollableSheet(
          initialChildSize: initialSize,
          minChildSize: minSize,
          maxChildSize: maxSize,
          expand: false,
          builder: (_, sc) => _GlassSheetBody(builder: (c) => builder(c, sc)),
        );
      }
      return _GlassSheetBody(builder: (c) => builder(c, null));
    },
  );
}

class _GlassSheetBody extends StatelessWidget {
  final Widget Function(BuildContext) builder;
  const _GlassSheetBody({required this.builder});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0D).withOpacity(0.60),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withOpacity(0.08),
                width: 0.5,
              ),
            ),
          ),
          child: builder(context),
        ),
      ),
    );
  }
}
