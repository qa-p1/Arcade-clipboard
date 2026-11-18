import 'package:flutter/painting.dart';

/// Flutter keeps up to 100 MiB of decoded images by default. The history shows
/// clipboard images as thumbnails, so a long list of large screenshots would
/// otherwise stay decoded in memory (CB4). Evicted images decode again when
/// they scroll back into view.
const int imageCacheLimitBytes = 24 * 1024 * 1024;

/// Caps [cache] (the app's own by default) at [imageCacheLimitBytes].
void limitImageCache([ImageCache? cache]) {
  (cache ?? PaintingBinding.instance.imageCache).maximumSizeBytes =
      imageCacheLimitBytes;
}
