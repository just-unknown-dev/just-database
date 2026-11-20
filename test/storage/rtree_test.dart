import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/src/storage/rtree.dart';

void main() {
  List<int> brute(Map<int, Rect> boxes, Rect area) => [
    for (final e in boxes.entries)
      if (e.value.intersects(area)) e.key,
  ]..sort();

  test('search matches a brute-force scan after inserts and removals', () {
    final rng = Random(7);
    final tree = RTree<int>();
    final boxes = <int, Rect>{};
    for (var i = 0; i < 3000; i++) {
      final x = rng.nextDouble() * 1000, y = rng.nextDouble() * 1000;
      final box = i.isEven
          ? Rect.point(x, y)
          : Rect(x, y, x + rng.nextDouble() * 20, y + rng.nextDouble() * 20);
      boxes[i] = box;
      tree.insert(box, i);
    }
    for (var i = 0; i < 3000; i += 3) {
      expect(tree.remove(boxes[i]!, i), isTrue);
      boxes.remove(i);
    }
    expect(tree.size, boxes.length);
    for (var q = 0; q < 50; q++) {
      final x = rng.nextDouble() * 1000, y = rng.nextDouble() * 1000;
      final area = Rect(x, y, x + 80, y + 80);
      expect(tree.search(area)..sort(), brute(boxes, area));
    }
  });

  test('removing everything leaves an empty tree', () {
    final tree = RTree<int>();
    final pts = [
      for (var i = 0; i < 500; i++)
        Rect.point(i.toDouble(), (i * 7 % 500).toDouble()),
    ];
    for (var i = 0; i < pts.length; i++) {
      tree.insert(pts[i], i);
    }
    for (var i = 0; i < pts.length; i++) {
      expect(tree.remove(pts[i], i), isTrue);
    }
    expect(tree.size, 0);
    expect(tree.search(Rect(-1e9, -1e9, 1e9, 1e9)), isEmpty);
  });

  test('non-finite rectangles are rejected', () {
    expect(() => Rect.point(double.nan, 0), throwsArgumentError);
    expect(() => Rect(0, 0, double.infinity, 1), throwsArgumentError);
    expect(() => Rect(2, 0, 1, 1), throwsArgumentError);
  });

  test('inserting stays close to linear', () {
    int timeFor(int n) {
      final tree = RTree<int>();
      final rng = Random(1);
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        tree.insert(Rect.point(rng.nextDouble(), rng.nextDouble()), i);
      }
      return sw.elapsedMicroseconds;
    }

    timeFor(2000); // warm up
    final small = timeFor(5000), big = timeFor(40000);
    // Quadratic took seconds; a ratio on a few ms is noisy under load.
    expect(
      big < 2000000 || big / small < 20,
      isTrue,
      reason: '8x points took ${big / small}x',
    );
  });
}
