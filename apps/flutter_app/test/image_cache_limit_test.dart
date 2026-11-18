import 'package:arcade_clipboard/services/image_cache_limit.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the decoded image cache is capped at 24 MiB, below Flutter default',
      () {
    final cache = ImageCache();
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
    limitImageCache(cache);
    expect(cache.maximumSizeBytes, 24 * 1024 * 1024);
    expect(imageCacheLimitBytes, 24 * 1024 * 1024);
  });

  testWidgets('limitImageCache caps the app image cache by default',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final before = cache.maximumSizeBytes;
    addTearDown(() => cache.maximumSizeBytes = before);
    limitImageCache();
    expect(cache.maximumSizeBytes, imageCacheLimitBytes);
  });
}
