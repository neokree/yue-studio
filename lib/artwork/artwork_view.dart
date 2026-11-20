import 'package:flutter/widgets.dart';

import '../library/song.dart';
import 'artwork.dart';

/// The song's artwork at [size] x [size] (DESIGN.md: radius 6).
class ArtworkView extends StatelessWidget {
  const ArtworkView({super.key, required this.song, this.size = 40, this.radius = 6});
  final Song song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(width: size, height: size, child: CustomPaint(painter: ArtworkPainter(song.art))),
        ),
      );
}
