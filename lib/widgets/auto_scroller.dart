import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:gemma_vision_demo/theme.dart';

/// Keeps a transcript pinned to the bottom while tokens stream in — but stops
/// the moment the reader scrolls up, and resumes when they come back down.
///
/// The naive version (call `animateTo(maxScrollExtent)` on every token) makes
/// it impossible to read back through a long answer while it is still being
/// written: every token yanks you to the bottom again.
///
/// Detecting "the user took over" by comparing the offset to the bottom does
/// not work, because each new token GROWS `maxScrollExtent` — so a pinned view
/// looks scrolled-away for a frame and the heuristic disables itself. The
/// reliable signal is [UserScrollNotification], which only fires for
/// user-driven scrolling; programmatic `animateTo` never emits it.
class AutoScroller {
  AutoScroller(this.controller);

  final ScrollController controller;

  /// Within this many pixels of the bottom counts as "pinned".
  static const _bottomThreshold = 90.0;

  bool _pinned = true;

  /// True while OUR OWN animation is running, so its intermediate positions
  /// are not mistaken for the reader scrolling away.
  bool _animating = false;

  /// True when output is following the stream. Drives the "jump to latest"
  /// affordance.
  bool get isPinned => _pinned;

  /// Feed every [ScrollNotification] through this. Returns true if the pinned
  /// state changed, so the caller can rebuild.
  ///
  /// This deliberately does NOT rely on [UserScrollNotification] alone. That
  /// fires for touch drags, but trackpad and mouse-wheel scrolling on desktop
  /// take a different path through `Scrollable`, so a desktop reader could
  /// never unpin and the view fought every attempt to scroll back. Position
  /// is the signal that works everywhere; the [_animating] flag is what keeps
  /// our own scrolling from being read as the reader's.
  bool handleNotification(ScrollNotification notification) {
    final was = _pinned;

    if (notification is UserScrollNotification) {
      // Unambiguous when we get it: a drag away from the newest output.
      if (notification.direction == ScrollDirection.forward) {
        _pinned = false;
      }
    } else if (!_animating &&
        (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification)) {
      // Works for wheel, trackpad, scrollbar and keyboard alike.
      _pinned = _isAtBottom;
    }

    return was != _pinned;
  }

  bool get _isAtBottom {
    if (!controller.hasClients) return true;
    final position = controller.position;
    return position.pixels >= position.maxScrollExtent - _bottomThreshold;
  }

  /// Scroll to the newest output, but only while pinned. Safe to call on every
  /// token — it schedules for after the frame that added the content, since
  /// `maxScrollExtent` is not yet updated when the token arrives.
  void followOutput() {
    if (!_pinned) return;
    _jump();
  }

  /// Explicit "jump to latest" — re-pins regardless of current state.
  void resume() {
    _pinned = true;
    _jump();
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      _animating = true;
      controller
          .animateTo(
            controller.position.maxScrollExtent,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          )
          // A user scroll interrupts animateTo, which completes the future —
          // so clearing the flag here is correct in both cases.
          .whenComplete(() => _animating = false);
    });
  }
}

/// The "jump to latest" pill, shown only when the reader has scrolled away
/// from streaming output.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({
    super.key,
    required this.visible,
    required this.onPressed,
    required this.color,
  });

  final bool visible;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 180),
      offset: visible ? Offset.zero : const Offset(0, 1.6),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: color,
              borderRadius: BorderRadius.circular(999),
              elevation: 6,
              child: InkWell(
                onTap: onPressed,
                borderRadius: BorderRadius.circular(999),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_downward,
                        size: 14,
                        color: AppColors.onAccent,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Jump to latest',
                        style: TextStyle(
                          color: AppColors.onAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
