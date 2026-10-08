import 'package:flutter/material.dart';

/// Design tokens for the demo.
///
/// The app deliberately does **not** share the talk's slide branding. The
/// slides are Google Sans on a cool near-black; an app dressed the same way
/// dissolved into the slide behind it the moment a recording was dropped into
/// a laptop mockup. So this is its own thing: a warm charcoal, a jade house
/// colour, a four-hue set for the four demos, and a different set of
/// typefaces. Warm on cool is what makes the recording read as a screen.
///
/// The second constraint is the room. A projector washes out mid-tones, so
/// surfaces stay dark, text stays bright, type runs a size larger than a
/// normal app, and colour means something instead of decorating.
abstract final class AppFonts {
  /// Headings and numbers. It has mannerisms — tight joins, a condensed
  /// feel — which is the point: the headline is the one place in the app
  /// with a voice of its own.
  static const display = 'Bricolage Grotesque';

  /// Everything you actually read.
  static const sans = 'Inter';

  /// Code, JSON, tool calls. A face the room will recognise from its own
  /// editors.
  static const mono = 'JetBrains Mono';
}

abstract final class AppColors {
  // Surfaces — warm charcoal, lightest layer last.
  static const bg = Color(0xFF1A1917);
  static const bgElevated = Color(0xFF201F1C);
  static const surface = Color(0xFF232220);
  static const surfaceHigh = Color(0xFF2C2A27);

  /// Code, JSON and tool output sit one step brighter again.
  static const surfaceCode = Color(0xFF322F2B);

  static const border = Color(0x14FFFFFF);
  static const borderStrong = Color(0x26FFFFFF);

  /// Jade is the app's own colour and carries every primary action. It is
  /// bright enough to own a filled shape, which is why anything sitting *on*
  /// it uses [onAccent].
  static const accent = Color(0xFF3ECF8E);
  static const accentBright = Color(0xFF6FE3AD);
  static const accentDeep = Color(0xFF2BA873);

  /// Text and icons on ANY filled accent shape — jade, azure, amber, rose.
  /// Every one of them is light, and white on a light fill is unreadable
  /// across a room, so filled shapes take this warm near-black instead.
  static const onAccent = Color(0xFF161411);

  // One hue per demo, so a screenshot is identifiable at a glance. What keeps
  // this from being the old paint box is that they are a SET: four hues
  // picked at roughly the same lightness and saturation, each one used for
  // exactly one thing, and never blended into a gradient.
  static const vision = Color(0xFF63A9F9); // azure
  static const thinking = Color(0xFFF0B45C); // amber
  static const tool = Color(0xFF46D49A); // jade, the house colour
  static const voice = Color(0xFFF2798F); // rose

  /// A warm sand for second-rank detail — rules, dividers inside cards and
  /// the odd label that would otherwise be the third jade thing on screen.
  static const sand = Color(0xFFD9B27C);

  // Text, warmed to match the surfaces.
  static const textPrimary = Color(0xFFF4F1EC);
  static const textSecondary = Color(0xFFBCB6AC);
  static const textTertiary = Color(0xFF8A8479);

  // Status, drawn from the same set: jade for good, amber for careful, a
  // deeper red for bad so it never reads as the rose of the voice demo.
  static const success = Color(0xFF46D49A);
  static const warning = Color(0xFFF0B45C);
  static const danger = Color(0xFFF0675A);

  /// The one place that has to shout: the microphone while it is recording.
  /// Deeper and more saturated than [voice], so "live" never looks like
  /// "idle".
  static const recording = Color(0xFFD33F2F);

  // The backdrop. A flat fill is what made the old build feel like a
  // prototype, but a loud gradient is what made it feel generated — so this
  // is a shallow tonal wash with two very soft colour blooms in it, closer to
  // lighting than to decoration. Nothing on top of it changes colour.
  static const bgTop = Color(0xFF201E1B);
  static const bgBottom = Color(0xFF141310);
}

abstract final class AppText {
  static const hero = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 46,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.08,
    letterSpacing: -1.4,
  );
  static const title = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 29,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.2,
    letterSpacing: -0.6,
  );
  static const heading = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.2,
  );
  // Sizes run a notch above a normal app: in a conference room the back row
  // is reading this off a projector, not holding the phone.
  static const body = TextStyle(
    fontFamily: AppFonts.sans,
    color: AppColors.textSecondary,
    fontSize: 16.5,
    height: 1.55,
  );
  static const bodySmall = TextStyle(
    fontFamily: AppFonts.sans,
    color: AppColors.textSecondary,
    fontSize: 14.5,
    height: 1.45,
  );
  static const caption = TextStyle(
    fontFamily: AppFonts.sans,
    color: AppColors.textTertiary,
    fontSize: 13,
    height: 1.4,
  );

  /// Small section label — tracked a little, never shouting. The old all-caps
  /// styling was doing work that colour and spacing do now.
  static const label = TextStyle(
    fontFamily: AppFonts.sans,
    color: AppColors.accent,
    fontSize: 12.5,
    letterSpacing: 0.4,
    fontWeight: FontWeight.w600,
  );
  static const mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 13,
    height: 1.5,
    color: AppColors.textSecondary,
  );
}

/// Crisper than the slides on purpose — another small thing keeping the two
/// from looking like the same artefact.
abstract final class AppRadius {
  static const card = 10.0;
  static const button = 10.0;
  static const pill = 999.0;
  static const bubble = 14.0;
}

/// App-wide spacing scale, so padding is never a magic number.
abstract final class Gap {
  static const xs = SizedBox(height: 4);
  static const sm = SizedBox(height: 8);
  static const md = SizedBox(height: 16);
  static const lg = SizedBox(height: 24);
  static const xl = SizedBox(height: 36);

  static const wSm = SizedBox(width: 8);
  static const wMd = SizedBox(width: 14);
}

/// How much room the window has.
///
/// The demo runs on a phone, on a laptop, and full screen on a Mac mirrored
/// to a projector — a 10x range in width. Laying it out once for the middle
/// case leaves the big case looking like a phone app stranded in the dark.
enum AppSize {
  /// Phones, and a small desktop window.
  compact,

  /// A normal laptop window.
  medium,

  /// Full screen on a Mac, which is how the demo is actually shown.
  expanded;

  static AppSize of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  static AppSize fromWidth(double width) => width < 700
      ? AppSize.compact
      : width < 1180
      ? AppSize.medium
      : AppSize.expanded;

  bool get isExpanded => this == AppSize.expanded;
}

/// Keeps content in a readable column, and lets that column grow with the
/// window instead of stranding it in the middle of a big empty screen.
///
/// Phones fall through at full width; a laptop window gets a measured column;
/// full screen gets a wider one, because at that size the line length is no
/// longer the thing that hurts — the empty margins are.
class PageWidth extends StatelessWidget {
  const PageWidth({
    super.key,
    required this.child,
    this.medium = 820,
    this.expanded = 1120,
  });

  final Widget child;
  final double medium;
  final double expanded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = AppSize.fromWidth(constraints.maxWidth);
        final max = switch (size) {
          AppSize.compact => double.infinity,
          AppSize.medium => medium,
          AppSize.expanded => expanded,
        };
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max),
            child: child,
          ),
        );
      },
    );
  }
}

/// The horizontal inset that centres a column of the same width [PageWidth]
/// would produce.
///
/// Scrolling screens use this instead of [PageWidth]: a [ListView] inside a
/// constrained box puts its scrollbar against the *column's* edge, which on a
/// wide window floats in the middle of the screen. Padding the list keeps the
/// scrollbar where it belongs, at the window edge.
double pageInset(
  double width, {
  double medium = 820,
  double expanded = 1120,
  double gutter = 24,
}) {
  final column = switch (AppSize.fromWidth(width)) {
    AppSize.compact => width,
    AppSize.medium => medium,
    AppSize.expanded => expanded,
  };
  return ((width - column) / 2).clamp(gutter, double.infinity);
}

/// A scrolling page whose content is centred while it is shorter than the
/// window, and scrolls normally once it is taller.
///
/// It measures the viewport itself, because inside a [SingleChildScrollView]
/// the incoming `maxHeight` is infinite — asking for it there yields an
/// infinitely tall child and nothing renders at all.
class CentredScrollView extends StatelessWidget {
  const CentredScrollView({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight - padding.vertical;
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: available.isFinite && available > 0 ? available : 0,
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// The app's backdrop: a shallow top-to-bottom wash with a jade bloom behind
/// the top-left (where headlines live) and a rose one in the far corner.
///
/// It is painted once, under everything, by wrapping [MaterialApp.builder] —
/// so every screen gets it and no screen has to remember to. Scaffolds are
/// transparent for the same reason.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.bgTop, AppColors.bgBottom],
        ),
      ),
      child: Stack(
        children: [
          // Blooms are sized from the window, so they stay soft whether this
          // is a phone or a full-screen Mac.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: const _BloomPainter()),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _BloomPainter extends CustomPainter {
  const _BloomPainter();

  @override
  void paint(Canvas canvas, Size size) {
    void bloom(Offset centre, double radius, Color color) {
      final rect = Rect.fromCircle(center: centre, radius: radius);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }

    final reach = size.longestSide;
    bloom(
      Offset(size.width * .12, size.height * .02),
      reach * .62,
      AppColors.accent.withValues(alpha: .09),
    );
    bloom(
      Offset(size.width * .95, size.height * .92),
      reach * .55,
      AppColors.voice.withValues(alpha: .07),
    );
  }

  @override
  bool shouldRepaint(_BloomPainter oldDelegate) => false;
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: AppFonts.sans,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: AppColors.accent,
          onPrimary: AppColors.onAccent,
          surface: AppColors.bg,
          error: AppColors.danger,
        ),
  );
  return base.copyWith(
    // Transparent, so the one backdrop painted in `main.dart` shows through
    // every screen.
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: AppColors.textPrimary),
      titleTextStyle: AppText.heading,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(
        fontFamily: AppFonts.sans,
        color: AppColors.textPrimary,
        fontSize: 14.5,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
  );
}

/// Primary call to action: a flat jade fill, no gradient and no glow.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final ink = enabled ? AppColors.onAccent : AppColors.textTertiary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: enabled ? AppColors.accent : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                else if (icon != null)
                  Icon(icon, size: 18, color: ink),
                if (busy || icon != null) Gap.wSm,
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppFonts.sans,
                    color: ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 15.5,
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

/// Small chip used for feature tags and status.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppFonts.sans,
          color: color,
          fontSize: 12,
          letterSpacing: 0.1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Standard elevated container — one place to change card styling.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: borderColor ?? AppColors.border),
      ),
      child: child,
    );
  }
}
