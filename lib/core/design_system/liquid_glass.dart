import 'dart:ui';
import 'package:flutter/material.dart';

/// Specular rim highlight & optical refraction painter for Liquid Glass.
///
/// Implements authentic optical refraction without frosted blur:
/// 1. Chromatic Dispersion Fringe (Prism Aberration): Cyan/violet fringe on top-left,
///    amber/coral on bottom-right, simulating wavelength-dependent light refraction.
/// 2. Caustic Refraction Meniscus: Concentrated convergent light halo just inside the rim
///    where light rays bend through the curved liquid edge.
/// 3. Back-Surface Displaced Bevel: Offset internal reflection simulating physical glass thickness.
/// 4. Front-Surface Directional 45° Specular Rim Gleam: Razor-sharp light catch.
/// 5. Chromatic Caustic Bleed: Accent light dispersion along the bottom rim.
class LiquidGlassPainter extends CustomPainter {
  final double borderRadius;
  final bool isDark;
  final Color? accentColor;
  final double specularIntensity;
  final double strokeWidth;
  final double refractionStrength;

  const LiquidGlassPainter({
    this.borderRadius = 32.0,
    this.isDark = true,
    this.accentColor,
    this.specularIntensity = 1.0,
    this.strokeWidth = 1.0,
    this.refractionStrength = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(borderRadius),
    );

    // -------------------------------------------------------------
    // LAYER 1: Chromatic Dispersion Fringe (Prism Separation)
    // Simulates physical chromatic aberration of refractive liquid glass
    // where different light wavelengths bend at slightly different angles.
    // -------------------------------------------------------------
    if (refractionStrength > 0) {
      // Top-Left: Cyan / Violet cold dispersion fringe
      final cyanFringePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = const SweepGradient(
          center: Alignment.topLeft,
          colors: [
            Color(0x3564D2FF), // Ice-Cyan
            Color(0x24BF5AF2), // Violet
            Colors.transparent,
            Colors.transparent,
          ],
          stops: [0.0, 0.28, 0.55, 1.0],
        ).createShader(rect);
      canvas.drawRRect(rrect, cyanFringePaint);

      // Bottom-Right: Amber / Coral warm dispersion fringe
      final amberFringePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = const SweepGradient(
          center: Alignment.bottomRight,
          colors: [
            Color(0x2CFF9F0A), // Warm Amber
            Color(0x1EFF453A), // Coral
            Colors.transparent,
            Colors.transparent,
          ],
          stops: [0.0, 0.28, 0.55, 1.0],
        ).createShader(rect);
      canvas.drawRRect(rrect, amberFringePaint);
    }

    // -------------------------------------------------------------
    // LAYER 2: Front-Surface Specular Rim Outline
    // Crisp boundary highlight outlining the perimeter using active theme color
    // -------------------------------------------------------------
    final outerGleamAlpha = (isDark ? 0.88 : 0.95) * specularIntensity;
    final outerMidAlpha = (isDark ? 0.44 : 0.55) * specularIntensity;
    final outerCounterGleamAlpha = (isDark ? 0.76 : 0.88) * specularIntensity;

    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: const Alignment(-1.0, -0.85),
        end: const Alignment(1.0, 0.85),
        colors: [
          (accentColor ?? Colors.white)
              .withValues(alpha: outerGleamAlpha.clamp(0.0, 1.0)),
          Colors.white.withValues(alpha: outerMidAlpha.clamp(0.0, 1.0)),
          (accentColor ?? Colors.white)
              .withValues(alpha: outerCounterGleamAlpha.clamp(0.0, 1.0)),
        ],
        stops: const [0.0, 0.48, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, rimPaint);

    // -------------------------------------------------------------
    // LAYER 5: Chromatic Caustic Light Bleed (Bottom edge accent)
    // -------------------------------------------------------------
    if (accentColor != null) {
      final accentCausticPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.transparent,
            accentColor!.withValues(alpha: (isDark ? 0.35 : 0.24) * specularIntensity),
            Colors.transparent,
          ],
          stops: const [0.15, 0.5, 0.85],
        ).createShader(rect);

      canvas.drawRRect(rrect, accentCausticPaint);
    }
  }

  @override
  bool shouldRepaint(covariant LiquidGlassPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.isDark != isDark ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.specularIntensity != specularIntensity ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.refractionStrength != refractionStrength;
  }
}

/// A liquid glass container widget that provides true optical lens refraction,
/// crisp 3.5px liquid gloss dispersion, directional specular rim lighting,
/// chromatic dispersion fringes, and caustic meniscus light gathering.
/// A liquid glass container widget that provides true optical lens refraction,
/// crisp 2.8px liquid gloss dispersion, directional specular rim lighting,
/// chromatic dispersion fringes, and caustic meniscus light gathering.
class LiquidGlassContainer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double blurSigma;
  final double refractionScale; // Convex lens optical magnification (e.g. 1.035 = 3.5% magnification)
  final double refractionDeflection; // Snell's Law double refraction: lateral bend left then right
  final Color? surfaceColor;
  final Color? accentColor;
  final bool isDark;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final List<BoxShadow>? additionalShadows;
  final Offset? globalOffset;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 32.0,
    this.blurSigma = 2.0, // Crisp 2.0px optical liquid dispersion (never frosted fog)
    this.refractionScale = 1.05, // 5% convex lens optical magnification & real-time bending
    this.refractionDeflection = 2.8, // Enhanced optical ray bending: visible lateral bend towards center and back
    this.surfaceColor,
    this.accentColor,
    this.isDark = true,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.additionalShadows,
    this.globalOffset,
  });

  @override
  State<LiquidGlassContainer> createState() => _LiquidGlassContainerState();
}

class _LiquidGlassContainerState extends State<LiquidGlassContainer> {
  Offset? _globalOffset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOffset());
  }

  void _updateOffset() {
    if (!mounted) return;
    if (widget.globalOffset != null) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize && renderBox.attached) {
      final offset = renderBox.localToGlobal(Offset.zero);
      if (_globalOffset == null || (_globalOffset! - offset).distanceSquared > 1.0) {
        setState(() {
          _globalOffset = offset;
        });
      }
    }
  }

  Offset _getEffectiveGlobalOffset(BuildContext context, double w, double h) {
    if (widget.globalOffset != null) {
      return widget.globalOffset!;
    }
    if (_globalOffset != null && _globalOffset != Offset.zero) {
      return _globalOffset!;
    }
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery != null) {
      final screen = mediaQuery.size;
      final bottomPadding = mediaQuery.padding.bottom;
      final bottomMargin = bottomPadding > 0 ? bottomPadding : 10.0;
      final x = (screen.width - w) / 2;
      final y = screen.height - bottomMargin - h;
      return Offset(x, y);
    }
    return Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    // Keep global coordinates in sync across layout shifts & scrolling
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOffset());

    final isTransparent = widget.surfaceColor == Colors.transparent ||
        (widget.surfaceColor != null && widget.surfaceColor!.a == 0.0);

    return Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: (widget.accentColor ??
                  (widget.isDark ? Colors.white : Colors.black))
              .withValues(alpha: widget.isDark ? 0.38 : 0.28),
          width: 1.0,
        ),
        boxShadow: [
          // Diffuse water-drop ambient drop shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: widget.isDark ? 0.30 : 0.08),
            blurRadius: 20,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
          if (widget.additionalShadows != null) ...widget.additionalShadows!,
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = widget.height ??
                (constraints.maxHeight > 0 ? constraints.maxHeight : 64.0);

            // Construct optical lens refraction filter centered at the EXACT
            // global screen position of this container.
            // This guarantees realtime in-place optical magnification and bending
            // of whatever content is directly behind the glass, without sampling
            // scrolled-past content from above.
            // Separate blur and matrix filters to eliminate midline seams.
            // The blur is applied as a SINGLE full-width BackdropFilter (no edge
            // truncation artifacts), while the 4-quadrant matrix distortions are
            // applied WITHOUT blur in their own BackdropFilters.
            ImageFilter? singleLensFilter;
            ImageFilter? topLeftMatrixFilter;
            ImageFilter? bottomLeftMatrixFilter;
            ImageFilter? topRightMatrixFilter;
            ImageFilter? bottomRightMatrixFilter;
            ImageFilter? unifiedBlurFilter;

            if (w > 0 && h > 0) {
              final globalOffset = _getEffectiveGlobalOffset(context, w, h);
              final centerX = globalOffset.dx + w / 2;
              final centerY = globalOffset.dy + h / 2;
              final yTop = globalOffset.dy;
              final yBottom = globalOffset.dy + h;

              final scaleMatrix = Matrix4.identity();
              if (widget.refractionScale != 1.0) {
                scaleMatrix
                  ..translateByDouble(centerX, centerY, 0, 1)
                  ..scaleByDouble(
                    widget.refractionScale,
                    widget.refractionScale,
                    1.0,
                    1,
                  )
                  ..translateByDouble(-centerX, -centerY, 0, 1);
              }

              if (widget.refractionDeflection != 0.0) {
                // Symmetric 2D Optical Lens Refraction:
                // When light enters from any perimeter edge (bottom, top, left, right):
                // - It refracts inwards towards the center of the lens.
                // - When about to exit at the opposite edge, it bends back,
                //   returning seamlessly to its original trajectory.
                final d = widget.refractionDeflection;
                final sRightBottom = 2.0 * d / h;
                final sRightTop = -2.0 * d / h;
                final sLeftBottom = -2.0 * d / h;
                final sLeftTop = 2.0 * d / h;

                // Right Side: Enters from bottom-right, refracts LEFT towards center; exits top returning to original path
                final shearBR = Matrix4.identity()
                  ..setEntry(0, 1, sRightBottom)
                  ..setEntry(0, 3, -sRightBottom * yBottom);
                final shearTR = Matrix4.identity()
                  ..setEntry(0, 1, sRightTop)
                  ..setEntry(0, 3, -sRightTop * yTop);

                // Left Side: Enters from bottom-left, refracts RIGHT towards center; exits top returning to original path
                final shearBL = Matrix4.identity()
                  ..setEntry(0, 1, sLeftBottom)
                  ..setEntry(0, 3, -sLeftBottom * yBottom);
                final shearTL = Matrix4.identity()
                  ..setEntry(0, 1, sLeftTop)
                  ..setEntry(0, 3, -sLeftTop * yTop);

                // Matrix-ONLY filters for each quadrant (no blur composed in).
                // The blur is applied separately as a single unified layer to
                // avoid double-blur overlap seams at quadrant boundaries.
                topLeftMatrixFilter = ImageFilter.matrix(
                  (scaleMatrix * shearTL).storage,
                );
                bottomLeftMatrixFilter = ImageFilter.matrix(
                  (scaleMatrix * shearBL).storage,
                );
                topRightMatrixFilter = ImageFilter.matrix(
                  (scaleMatrix * shearTR).storage,
                );
                bottomRightMatrixFilter = ImageFilter.matrix(
                  (scaleMatrix * shearBR).storage,
                );

                // Single unified blur filter applied over the full container
                if (widget.blurSigma > 0) {
                  unifiedBlurFilter = ImageFilter.blur(
                    sigmaX: widget.blurSigma,
                    sigmaY: widget.blurSigma,
                  );
                }
              } else if (widget.refractionScale != 1.0) {
                final matrixFilter = ImageFilter.matrix(scaleMatrix.storage);
                if (widget.blurSigma > 0) {
                  singleLensFilter = ImageFilter.compose(
                    outer: ImageFilter.blur(
                      sigmaX: widget.blurSigma,
                      sigmaY: widget.blurSigma,
                    ),
                    inner: matrixFilter,
                  );
                } else {
                  singleLensFilter = matrixFilter;
                }
              } else if (widget.blurSigma > 0) {
                singleLensFilter = ImageFilter.blur(
                  sigmaX: widget.blurSigma,
                  sigmaY: widget.blurSigma,
                );
              }
            }

            Widget surface = CustomPaint(
              foregroundPainter: LiquidGlassPainter(
                borderRadius: widget.borderRadius,
                isDark: widget.isDark,
                accentColor: widget.accentColor,
                refractionStrength: 1.0,
              ),
              child: Container(
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  color: isTransparent
                      ? null
                      : (widget.surfaceColor ??
                          (widget.isDark
                              ? const Color(0xFF141414).withValues(alpha: 0.14)
                              : const Color(0xFFFAFAFA).withValues(alpha: 0.16))),
                ),
                child: widget.child,
              ),
            );

            if (topLeftMatrixFilter != null &&
                bottomLeftMatrixFilter != null &&
                topRightMatrixFilter != null &&
                bottomRightMatrixFilter != null) {
              final halfW = w / 2;
              final halfH = h / 2;

              // Layer 1: 4-quadrant matrix-only distortions (no blur)
              // Quadrants tile exactly at halfW/halfH with NO overlap — this
              // eliminates the double-blur seam that the old +0.5 overlap caused.
              Widget matrixLayer = Stack(
                fit: StackFit.passthrough,
                children: [
                  // 1. Top-Left: Light bends left back to original path on exit
                  Positioned(
                    top: 0,
                    left: 0,
                    width: halfW,
                    height: halfH,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: topLeftMatrixFilter,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  // 2. Bottom-Left: Light enters and bends right towards center
                  Positioned(
                    top: halfH,
                    left: 0,
                    width: halfW,
                    bottom: 0,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: bottomLeftMatrixFilter,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  // 3. Top-Right: Light bends right back to original path on exit
                  Positioned(
                    top: 0,
                    left: halfW,
                    right: 0,
                    height: halfH,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: topRightMatrixFilter,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  // 4. Bottom-Right: Light enters and bends left towards center
                  Positioned(
                    top: halfH,
                    left: halfW,
                    right: 0,
                    bottom: 0,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: bottomRightMatrixFilter,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              );

              // Layer 2: Single unified blur over the ENTIRE container.
              // This avoids blur kernel clipping at quadrant edges, which was
              // the primary cause of visible midline crosshair artifacts.
              Widget blurLayer = unifiedBlurFilter != null
                  ? BackdropFilter(
                      filter: unifiedBlurFilter,
                      child: const SizedBox.expand(),
                    )
                  : const SizedBox.expand();

              return Stack(
                fit: StackFit.passthrough,
                children: [
                  matrixLayer,
                  blurLayer,
                  surface,
                ],
              );
            }

            if (singleLensFilter != null) {
              return BackdropFilter(
                filter: singleLensFilter,
                child: surface,
              );
            }

            return surface;
          },
        ),
      ),
    );
  }
}

/// Liquid Droplet Selection Indicator Painter.
///
/// Paints a refractive liquid glass droplet that serves as the selected tab pill,
/// complete with a luminous caustic core, chromatic dispersion edge,
/// and delicate specular border.
class LiquidDropletPainter extends CustomPainter {
  final double borderRadius;
  final bool isDark;
  final Color accentColor;
  final double stretchFactor; // 0.0 at rest, up to 1.0 when dynamically elongated

  const LiquidDropletPainter({
    required this.borderRadius,
    required this.isDark,
    required this.accentColor,
    this.stretchFactor = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(borderRadius),
    );

    // 1. Refractive Caustic Core (Light Focal Point)
    // In a liquid droplet, light converges through the convex surface
    // into an illuminated caustic core near the center-top.
    final causticCorePaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(0.0, -0.25 + stretchFactor * 0.1),
        radius: 0.85 + stretchFactor * 0.4,
        colors: [
          isDark
              ? Colors.white.withValues(alpha: 0.25 + (0.05 * (1.0 - stretchFactor)))
              : Colors.white.withValues(alpha: 0.40 + (0.05 * (1.0 - stretchFactor))),
          accentColor.withValues(alpha: isDark ? 0.35 : 0.30),
          accentColor.withValues(alpha: isDark ? 0.12 : 0.08),
        ],
        stops: const [0.0, 0.60, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, causticCorePaint);

    // 2. Chromatic Refraction Fringe on Droplet Perimeter
    final dropletPrismPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = SweepGradient(
        center: Alignment.center,
        colors: [
          const Color(0x3864D2FF), // Cyan dispersion
          accentColor.withValues(alpha: isDark ? 0.55 : 0.45),
          const Color(0x30FF9F0A), // Amber dispersion
          Colors.white.withValues(alpha: isDark ? 0.40 : 0.50),
          const Color(0x3864D2FF),
        ],
        stops: const [0.0, 0.3, 0.6, 0.85, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, dropletPrismPaint);

    // 3. Inner Meniscus Refraction Line
    if (size.width > 4 && size.height > 4) {
      final innerDropletRRect = rrect.deflate(1.2);
      final innerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.30 : 0.40),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5],
        ).createShader(rect);

      canvas.drawRRect(innerDropletRRect, innerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant LiquidDropletPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.isDark != isDark ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.stretchFactor != stretchFactor;
  }
}
