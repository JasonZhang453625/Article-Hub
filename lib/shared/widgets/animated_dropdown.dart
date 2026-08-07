import 'dart:async';

import 'package:flutter/material.dart';

/// Animated dropdown with a styled trigger and a spring-animated overlay menu.
///
/// The overlay appears below the trigger, scaling and sliding in with a
/// spring curve, and options cascade in with a staggered fade. The selection
/// is visually confirmed with a check mark and a quick scale pop.
class AnimatedDropdownButton<T> extends StatefulWidget {
  final T value;
  final List<T> options;
  final String? Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final String? hint;

  const AnimatedDropdownButton({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.hint,
  });

  @override
  State<AnimatedDropdownButton<T>> createState() =>
      _AnimatedDropdownButtonState<T>();
}

class _AnimatedDropdownButtonState<T> extends State<AnimatedDropdownButton<T>> {
  final GlobalKey _triggerKey = GlobalKey();
  final FocusNode _focusNode = FocusNode();
  bool _open = false;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    _overlayEntry?.remove();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _openMenu();
    } else {
      _closeMenu();
    }
  }

  void _openMenu() {
    if (_open) return;
    final box = _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null || !box.attached) return;

    // Trigger rect in overlay coordinates so the menu anchors exactly below it.
    final rect =
        box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    setState(() => _open = true);
    _overlayEntry = OverlayEntry(
      builder: (_) => _AnimatedDropdownMenu<T>(
        triggerRect: rect,
        value: widget.value,
        options: widget.options,
        labelOf: widget.labelOf,
        onChanged: widget.onChanged,
        onDismiss: _closeMenu,
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _closeMenu() {
    if (!_open) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final label = widget.labelOf(widget.value) ?? '';
    final primary = theme.colorScheme.primary;

    return Focus(
      focusNode: _focusNode,
      child: Semantics(
        button: true,
        label: widget.hint,
        child: GestureDetector(
          key: _triggerKey,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focusNode.requestFocus();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _open
                    ? primary
                    : (isDark
                        ? Colors.white24
                        : const Color(0xFFD7E3EA)),
                width: _open ? 1.4 : 1.0,
              ),
              boxShadow: _open
                  ? [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      label,
                      key: ValueKey(label),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white
                            : const Color(0xFF10273F),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: _open
                        ? primary
                        : (isDark ? Colors.white54 : const Color(0xFF537082)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating menu itself. It lays out its own size (unconstrained), then
/// animates scale/translation/opacity in, staggering each option's reveal.
class _AnimatedDropdownMenu<T> extends StatefulWidget {
  final Rect triggerRect;
  final T value;
  final List<T> options;
  final String? Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final VoidCallback onDismiss;

  const _AnimatedDropdownMenu({
    required this.triggerRect,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    required this.onDismiss,
  });

  @override
  State<_AnimatedDropdownMenu<T>> createState() =>
      _AnimatedDropdownMenuState<T>();
}

class _AnimatedDropdownMenuState<T> extends State<_AnimatedDropdownMenu<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _dismissTimer;
  bool _selected = false;
  T? _selectedValue;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    )..forward();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _choose(T value) {
    if (_selected) return;
    setState(() {
      _selected = true;
      _selectedValue = value;
    });
    widget.onChanged(value);
    _dismissTimer = Timer(const Duration(milliseconds: 240), () {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1A2530) : Colors.white;
    final itemHeight = 48.0;
    const maxVisible = 6.0;
    const listPadding = 10.0; // 5 top + 5 bottom
    final visibleItems = widget.options.length.clamp(1, maxVisible.toInt());
    final menuHeight = visibleItems * itemHeight + listPadding;
    final screenW = MediaQuery.sizeOf(context).width;

    // Prefer opening downward below the trigger; flip upward when space is tight.
    final spaceBelow = MediaQuery.sizeOf(context).height -
        widget.triggerRect.bottom;
    final openDown = spaceBelow >= menuHeight;
    final left = (widget.triggerRect.left - 8).clamp(8.0, screenW - 8.0 - 8.0);

    // Entry curve: sharp decelerate with a hint of overshoot.
    final entry = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.82, curve: Curves.easeOutBack),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: openDown ? widget.triggerRect.bottom + 6 : null,
          bottom: openDown ? null : widget.triggerRect.top - menuHeight - 6,
          width: widget.triggerRect.width + 16,
          child: IgnorePointer(
            ignoring: _selected,
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: _controller,
                child: ScaleTransition(
                  scale: entry,
                  alignment: openDown
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    height: menuHeight,
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isDark
                            ? Colors.white12
                            : const Color(0xFFD7E3EA),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        itemCount: widget.options.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          thickness: 0.6,
                          indent: 44,
                          endIndent: 16,
                          color: isDark
                              ? Colors.white10
                              : const Color(0xFFE4EDF2),
                        ),
                        itemBuilder: (context, index) {
                          final option = widget.options[index];
                          final isSelected = option == widget.value;
                          final isChosen = _selected && option == _selectedValue;
                          return _MenuOption<T>(
                            index: index,
                            total: widget.options.length,
                            controller: _controller,
                            label: widget.labelOf(option) ?? '',
                            selected: isSelected,
                            chosen: isChosen,
                            onTap: () => _choose(option),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuOption<T> extends StatelessWidget {
  final int index;
  final int total;
  final Animation<double> controller;
  final String label;
  final bool selected;
  final bool chosen;
  final VoidCallback onTap;

  const _MenuOption({
    required this.index,
    required this.total,
    required this.controller,
    required this.label,
    required this.selected,
    required this.chosen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    final staggerStart = 0.08 + (index / total) * 0.35;
    final stagger = CurvedAnimation(
      parent: controller,
      curve: Interval(
        staggerStart,
        (staggerStart + 0.5).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );

    return FadeTransition(
      opacity: stagger,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.08),
          end: Offset.zero,
        ).animate(stagger),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(stagger),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: selected
                    ? primary.withValues(alpha: isDark ? 0.16 : 0.10)
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: child,
                    ),
                    child: Container(
                      key: ValueKey(selected),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? primary
                              : (isDark ? Colors.white24 : const Color(0xFFC3D3DC)),
                          width: 1.6,
                        ),
                        color: selected
                            ? primary
                            : Colors.transparent,
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? primary
                            : (isDark
                                ? Colors.white
                                : const Color(0xFF10273F)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
