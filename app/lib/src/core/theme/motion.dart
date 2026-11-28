// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mail_store/mail_store.dart';

import 'citusmail_theme.dart';

// The app's small animations, kept cheap: each one repaints or lays out
// only what moves, never a whole list per frame, and each is instant when
// the system asks for less motion (CitusMotion.reduced).

// ------------------------------------------------------- row to reader

/// Phones: the message list, or the open message over it. Opening grows
/// the tapped row into the message (the row's surface fills the screen and
/// the message fades in on it); Back shrinks it into the row again.
///
/// The list stays, hidden, under an open message, so it is where it was
/// on the way back.
final class OpenTransition extends StatefulWidget {
  const OpenTransition({
    super.key,
    required this.message,
    required this.list,
    required this.reader,
  });

  /// The open message's id; null shows the list.
  final MessageId? message;
  final Widget list;
  final Widget reader;

  /// Called by a row about to open [message]: it grows from that row.
  static void growFrom(BuildContext row, MessageId message) =>
      row.findAncestorStateOfType<_OpenTransitionState>()?._from(row, message);

  @override
  State<OpenTransition> createState() => _OpenTransitionState();
}

final class _OpenTransitionState extends State<OpenTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: CitusMotion.medium,
    value: widget.message == null ? 0 : 1,
  )..addStatusListener(_status);
  late final _curve = CurvedAnimation(
    parent: _progress,
    curve: CitusMotion.standard,
  );
  final _reader = GlobalKey();

  /// The row it grows from, in this widget's coordinates, and its message.
  Rect? _origin;
  MessageId? _originOf;

  /// The message as it last looked, while it shrinks back into its row
  /// (the reader itself is empty by then).
  ui.Image? _last;

  void _from(BuildContext row, MessageId message) {
    final box = row.findRenderObject();
    final own = context.findRenderObject();
    if (box is! RenderBox || own is! RenderBox) return;
    if (!box.hasSize || !own.hasSize) return;
    _origin = MatrixUtils.transformRect(
      box.getTransformTo(own),
      Offset.zero & box.size,
    );
    _originOf = message;
  }

  void _status(AnimationStatus status) {
    if (status.isDismissed) _dropLast();
    if (mounted) setState(() {});
  }

  void _dropLast() {
    _last?.dispose();
    _last = null;
  }

  @override
  void didUpdateWidget(OpenTransition old) {
    super.didUpdateWidget(old);
    final opening = old.message == null && widget.message != null;
    final closing = old.message != null && widget.message == null;
    if (!opening && !closing) return;
    // Opened some other way (a notification, a shortcut): no row to grow
    // from, so it rises into place instead.
    if (_originOf != (opening ? widget.message : old.message)) _origin = null;
    _dropLast();
    if (CitusMotion.reduced(context)) {
      _progress.value = opening ? 1 : 0;
      return;
    }
    if (opening) {
      _progress.forward();
    } else {
      _last = _snapshot();
      _progress.reverse();
    }
  }

  /// The reader as painted last, before it empties.
  ui.Image? _snapshot() {
    final boundary = _reader.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    try {
      return boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } on Object {
      // Not painted yet, or changing: it shrinks away without its content.
      return null;
    }
  }

  @override
  void dispose() {
    _dropLast();
    _curve.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.message != null;
    final covered = open && _progress.isCompleted;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          Visibility(
            visible: !covered,
            maintainState: true,
            child: widget.list,
          ),
          if (open || !_progress.isDismissed)
            _grow(context, Offset.zero & constraints.biggest),
        ],
      ),
    );
  }

  Widget _grow(BuildContext context, Rect full) {
    final tint = ListColors.of(context).selected;
    final surface = Theme.of(context).colorScheme.surface;
    final from = _origin ?? full.translate(0, 48);
    return AnimatedBuilder(
      animation: _progress,
      child: RepaintBoundary(key: _reader, child: widget.reader),
      builder: (context, reader) {
        final done = _progress.isCompleted;
        final closing = widget.message == null;
        final t = _curve.value;
        final linear = _progress.value;
        final rect = Rect.lerp(from, full, t)!;
        // The surface shows at once and turns from the row's tint to the
        // page's; the content comes in once there is room for it.
        final surfaceAlpha = const Interval(0, 0.15).transform(linear);
        final content = const Interval(0.3, 1).transform(linear);
        final color = Color.lerp(
          tint,
          surface,
          const Interval(0, 0.5).transform(t),
        )!.withValues(alpha: done ? 0 : surfaceAlpha);
        // Taps reach the message as it opens; while it closes, the list.
        return IgnorePointer(
          ignoring: closing,
          child: ClipRRect(
            key: const ValueKey('growing-message'),
            clipper: _RRectClipper(
              RRect.fromRectAndRadius(
                rect,
                Radius.circular(CitusmailTheme.radius * (1 - t)),
              ),
            ),
            clipBehavior: done ? Clip.none : Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: color),
                Transform.translate(
                  offset: done ? Offset.zero : rect.topLeft,
                  child: Opacity(opacity: closing ? 0 : content, child: reader),
                ),
                if (closing && _last != null)
                  Positioned(
                    left: rect.left,
                    top: rect.top,
                    width: full.width,
                    height: full.height,
                    child: RawImage(
                      key: const ValueKey('message-as-it-was'),
                      image: _last,
                      fit: BoxFit.fill,
                      opacity: AlwaysStoppedAnimation(content),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _RRectClipper extends CustomClipper<RRect> {
  const _RRectClipper(this.rrect);

  final RRect rrect;

  @override
  RRect getClip(Size size) => rrect;

  @override
  bool shouldReclip(_RRectClipper oldClipper) => oldClipper.rrect != rrect;
}

/// The reader's content easing in when another message opens: a short
/// fade and a small rise. Not on first showing (a phone's reader has just
/// grown into place).
final class ReaderFadeIn extends StatefulWidget {
  const ReaderFadeIn({super.key, required this.id, required this.child});

  /// What is shown; a new one fades in.
  final Object? id;
  final Widget child;

  @override
  State<ReaderFadeIn> createState() => _ReaderFadeInState();
}

final class _ReaderFadeInState extends State<ReaderFadeIn>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(
    vsync: this,
    duration: CitusMotion.short,
    value: 1,
  );
  late final _curve = CurvedAnimation(
    parent: _progress,
    curve: CitusMotion.standard,
  );

  @override
  void didUpdateWidget(ReaderFadeIn old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id && !CitusMotion.reduced(context)) {
      _progress.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 8 * (1 - _curve.value)),
        child: child,
      ),
    ),
  );
}

// ------------------------------------------------------------- folding

/// A sliver that folds away and back out: when [open] changes, its height
/// animates (and it fades) over [CitusMotion.fold]. [builder] makes the
/// sliver; it is not built at all while folded.
///
/// Fast with hundreds of rows: only the part that can be on screen takes
/// part (see [SliverFold]), and the rows are not rebuilt per frame.
final class FoldingSliver extends StatefulWidget {
  const FoldingSliver({super.key, required this.open, required this.builder});

  final bool open;
  final WidgetBuilder builder;

  @override
  State<FoldingSliver> createState() => _FoldingSliverState();
}

final class _FoldingSliverState extends State<FoldingSliver>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: CitusMotion.fold,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_status);
  late final _curve = CurvedAnimation(
    parent: _progress,
    curve: CitusMotion.standard,
  );

  void _status(AnimationStatus status) {
    if (mounted && status.isDismissed) setState(() {});
  }

  @override
  void didUpdateWidget(FoldingSliver old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    if (CitusMotion.reduced(context)) {
      _progress.value = widget.open ? 1 : 0;
    } else if (widget.open) {
      _progress.forward();
    } else {
      _progress.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _progress.isDismissed) {
      return const SliverToBoxAdapter();
    }
    return SliverFold(
      fold: _curve,
      sliver: SliverFadeTransition(
        opacity: _progress,
        sliver: widget.builder(context),
      ),
    );
  }
}

/// Shows [fold] (0 to 1) of its sliver's height, clipped. Only the part
/// from the sliver's start to the bottom of the viewport folds; the rest
/// (off screen) goes at once, so a long section folds as fast as a short
/// one. Listens to [fold] itself: nothing is rebuilt as it moves.
final class SliverFold extends SingleChildRenderObjectWidget {
  const SliverFold({super.key, required this.fold, required Widget sliver})
    : super(child: sliver);

  final Animation<double> fold;

  @override
  RenderSliverFold createRenderObject(BuildContext context) =>
      RenderSliverFold(fold);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverFold renderObject,
  ) => renderObject.fold = fold;
}

final class RenderSliverFold extends RenderProxySliver {
  RenderSliverFold(this._fold);

  Animation<double> _fold;
  final _clip = LayerHandle<ClipRectLayer>();

  set fold(Animation<double> value) {
    if (value == _fold) return;
    if (attached) {
      _fold.removeListener(markNeedsLayout);
      value.addListener(markNeedsLayout);
    }
    _fold = value;
    markNeedsLayout();
  }

  bool get _folding =>
      _fold.value < 1 && constraints.axisDirection == AxisDirection.down;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _fold.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _fold.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    final full = child.geometry!;
    if (!_folding || full.scrollOffsetCorrection != null) {
      geometry = full;
      return;
    }
    final seen = math.min(
      full.scrollExtent,
      constraints.scrollOffset + constraints.remainingPaintExtent,
    );
    final extent = seen * _fold.value.clamp(0, 1);
    final paint = calculatePaintOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: math.min(paint, full.paintExtent),
      layoutExtent: math.min(paint, full.layoutExtent),
      maxPaintExtent: extent,
      hitTestExtent: math.min(paint, full.hitTestExtent),
      cacheExtent: math.min(
        calculateCacheOffset(constraints, from: 0, to: extent),
        full.cacheExtent,
      ),
      hasVisualOverflow: true,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || !geometry!.visible) {
      _clip.layer = null;
      return;
    }
    if (!_folding) {
      _clip.layer = null;
      context.paintChild(child!, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(constraints.crossAxisExtent, geometry!.paintExtent),
      (context, offset) => context.paintChild(child!, offset),
      oldLayer: _clip.layer,
    );
  }
}

// ---------------------------------------------------------------- undo

/// A notice with Undo, and a small ring beside Undo that empties as its
/// [duration] runs out (4 seconds, as any notice, unless given).
SnackBar undoSnackBar({
  required Widget content,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 4),
  SnackBarBehavior? behavior,
  double? width,
}) => SnackBar(
  content: Row(
    children: [
      Expanded(child: content),
      const SizedBox(width: CitusSpace.m),
      CountdownRing(duration: duration),
    ],
  ),
  behavior: behavior,
  width: width,
  duration: duration,
  // With Undo too it goes away after [duration].
  persist: false,
  action: SnackBarAction(label: 'Undo', onPressed: onUndo),
);

/// A ring that empties over [duration]: how long Undo is still there.
///
/// Moved by a timer, not a ticker: it is information, not decoration, so
/// it does not keep the frame clock running (or tests waiting for it to
/// settle). Steps once a second when the system asks for less motion.
final class CountdownRing extends StatefulWidget {
  const CountdownRing({super.key, required this.duration, this.size = 16});

  final Duration duration;
  final double size;

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

final class _CountdownRingState extends State<CountdownRing> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    final step = CitusMotion.reduced(context)
        ? const Duration(seconds: 1)
        : const Duration(milliseconds: 50);
    _timer = Timer.periodic(step, (timer) {
      setState(() => _elapsed += step);
      if (_elapsed >= widget.duration) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        theme.snackBarTheme.actionTextColor ?? theme.colorScheme.inversePrimary;
    final total = widget.duration.inMilliseconds;
    final left = total <= 0
        ? 0.0
        : (1 - _elapsed.inMilliseconds / total).clamp(0.0, 1.0);
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const ValueKey('undo-ring'),
        dimension: widget.size,
        child: CustomPaint(
          painter: _RingPainter(left: left, color: color),
        ),
      ),
    );
  }
}

final class _RingPainter extends CustomPainter {
  const _RingPainter({required this.left, required this.color});

  /// What is left, from 1 (full) to 0.
  final double left;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: 0.25));
    if (left > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * left,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.left != left || old.color != color;
}

// ------------------------------------------------------------- tabs

/// Phones: the tab shown, changing with a Material fade-through when
/// [tab] changes. The tab left fades out over the first third (as it was
/// painted last: its content may already be another tab's), then the new
/// one fades in while it grows from 92%. Instant when the system asks for
/// less motion.
///
/// Only [child] is built: the tab left is a picture, so nothing of it
/// runs (or loads) twice, and no tab is held up by the transition.
final class TabFadeThrough extends StatefulWidget {
  const TabFadeThrough({super.key, required this.tab, required this.child});

  /// The tab shown; the transition runs when it changes.
  final Object tab;
  final Widget child;

  /// How much of the transition is the tab left fading out.
  static const outgoing = 0.35;

  @override
  State<TabFadeThrough> createState() => _TabFadeThroughState();
}

final class _TabFadeThroughState extends State<TabFadeThrough>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: CitusMotion.medium,
    value: 1,
  )..addStatusListener(_status);
  late final _fadeIn = CurvedAnimation(
    parent: _progress,
    curve: const Interval(
      TabFadeThrough.outgoing,
      1,
      curve: CitusMotion.standard,
    ),
  );
  late final _scaleIn = Tween<double>(begin: 0.92, end: 1).animate(_fadeIn);
  late final _out = CurvedAnimation(
    parent: _progress,
    curve: const Interval(
      0,
      TabFadeThrough.outgoing,
      curve: CitusMotion.standard,
    ),
  );
  late final _fadeOut = ReverseAnimation(_out);
  final _shown = GlobalKey();

  /// The tab left, as it was painted last, while it fades out.
  ui.Image? _last;

  void _status(AnimationStatus status) {
    if (status.isCompleted) _dropLast();
    if (mounted) setState(() {});
  }

  void _dropLast() {
    _last?.dispose();
    _last = null;
  }

  @override
  void didUpdateWidget(TabFadeThrough old) {
    super.didUpdateWidget(old);
    if (old.tab == widget.tab) return;
    _dropLast();
    if (CitusMotion.reduced(context)) {
      _progress.value = 1;
      return;
    }
    _last = _snapshot();
    _progress.forward(from: 0);
  }

  /// The tab as painted last, before it is replaced.
  ui.Image? _snapshot() {
    final boundary = _shown.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    try {
      return boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } on Object {
      // Not painted yet, or changing: the new tab fades in on its own.
      return null;
    }
  }

  @override
  void dispose() {
    _dropLast();
    _out.dispose();
    _fadeIn.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      // Gone (transparent) after the first third; dropped at the end.
      if (_last case final last?)
        Positioned.fill(
          child: IgnorePointer(
            child: RawImage(
              key: const ValueKey('tab-as-it-was'),
              image: last,
              fit: BoxFit.fill,
              opacity: _fadeOut,
            ),
          ),
        ),
      RepaintBoundary(
        key: _shown,
        child: FadeTransition(
          opacity: _fadeIn,
          child: ScaleTransition(
            scale: _scaleIn,
            // A new tab is a new subtree: nothing of the one left is kept.
            child: KeyedSubtree(key: ValueKey(widget.tab), child: widget.child),
          ),
        ),
      ),
    ],
  );
}

// ------------------------------------------------------- small touches

/// Gives a little (to 98%) while pressed, like a real button.
final class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child});

  final Widget child;

  @override
  State<PressScale> createState() => _PressScaleState();
}

final class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _press(true),
    onPointerUp: (_) => _press(false),
    onPointerCancel: (_) => _press(false),
    child: AnimatedScale(
      scale: _pressed ? 0.98 : 1,
      duration: CitusMotion.of(context, CitusMotion.press),
      curve: CitusMotion.standard,
      child: widget.child,
    ),
  );
}

/// A number that rolls to its new value: up from below as it grows, down
/// from above as it shrinks.
final class CountSwitcher extends StatefulWidget {
  const CountSwitcher({super.key, required this.count, required this.builder});

  final int count;
  final Widget Function(BuildContext context, int count) builder;

  @override
  State<CountSwitcher> createState() => _CountSwitcherState();
}

final class _CountSwitcherState extends State<CountSwitcher> {
  bool _up = true;

  @override
  void didUpdateWidget(CountSwitcher old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count) _up = widget.count > old.count;
  }

  @override
  Widget build(BuildContext context) {
    final current = ValueKey(widget.count);
    return AnimatedSwitcher(
      duration: CitusMotion.of(context, CitusMotion.short),
      switchInCurve: CitusMotion.standard,
      switchOutCurve: CitusMotion.standard,
      layoutBuilder: (shown, leaving) =>
          Stack(alignment: Alignment.center, children: [...leaving, ?shown]),
      transitionBuilder: (child, animation) {
        // The new number comes from where the count is heading; the old
        // one leaves the other way.
        final incoming = child.key == current;
        final from = (incoming == _up) ? 0.6 : -0.6;
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: Offset(0, from),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: current,
        child: widget.builder(context, widget.count),
      ),
    );
  }
}

/// Fades its child out once, as it appears (the unread dot of a message
/// just read). Then paints nothing.
final class FadeAway extends StatefulWidget {
  const FadeAway({super.key, required this.child});

  final Widget child;

  @override
  State<FadeAway> createState() => _FadeAwayState();
}

final class _FadeAwayState extends State<FadeAway>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(
    vsync: this,
    duration: CitusMotion.short,
    value: 1,
  )..reverse();

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _progress, child: widget.child);
}
