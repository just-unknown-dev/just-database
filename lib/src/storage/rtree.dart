import 'dart:math' as math;

import 'package:flutter/foundation.dart' show internal;

/// An axis-aligned rectangle; a point is a rectangle of zero size.
@internal
final class Rect {
  /// Creates a rectangle. Throws [ArgumentError] unless every bound is
  /// finite and min ≤ max.
  Rect(this.minX, this.minY, this.maxX, this.maxY) {
    if (!(minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite)) {
      throw ArgumentError('Rect bounds must be finite');
    }
    if (minX > maxX || minY > maxY) {
      throw ArgumentError('Rect min must not exceed max');
    }
  }

  /// A rectangle of zero size at ([x], [y]).
  Rect.point(double x, double y) : this(x, y, x, y);

  /// The bounds.
  final double minX, minY, maxX, maxY;

  /// The area.
  double get area => (maxX - minX) * (maxY - minY);

  /// The smallest rectangle holding this and [o].
  Rect union(Rect o) => Rect(
    math.min(minX, o.minX),
    math.min(minY, o.minY),
    math.max(maxX, o.maxX),
    math.max(maxY, o.maxY),
  );

  /// Whether this and [o] share at least a border point.
  bool intersects(Rect o) =>
      minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY;

  /// Whether [o] lies inside this rectangle (borders included).
  bool contains(Rect o) =>
      minX <= o.minX && o.maxX <= maxX && minY <= o.minY && o.maxY <= maxY;

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.minX == minX &&
      other.minY == minY &&
      other.maxX == maxX &&
      other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);

  @override
  String toString() => 'Rect($minX, $minY, $maxX, $maxY)';
}

final class _Entry<T> {
  _Entry(this.box, {this.value, this.child});
  Rect box;
  final T? value;
  final _Node<T>? child;
}

final class _Node<T> {
  _Node({required this.leaf});
  final bool leaf;
  final List<_Entry<T>> entries = [];
  _Node<T>? parent;

  Rect get box {
    var r = entries.first.box;
    for (var i = 1; i < entries.length; i++) {
      r = r.union(entries[i].box);
    }
    return r;
  }
}

/// An R-tree (Guttman, quadratic split) mapping rectangles to values.
@internal
final class RTree<T> {
  /// Creates an empty tree whose nodes hold up to [maxEntries] entries.
  RTree({this.maxEntries = 16})
    : minEntries = math.max(2, (maxEntries * 0.4).floor());

  /// The most entries a node holds before it splits.
  final int maxEntries;

  /// The fewest entries a non-root node keeps.
  final int minEntries;

  _Node<T> _root = _Node<T>(leaf: true);
  int _size = 0;

  /// The number of stored values.
  int get size => _size;

  /// Removes everything.
  void clear() {
    _root = _Node<T>(leaf: true);
    _size = 0;
  }

  /// Stores [value] under [box].
  void insert(Rect box, T value) {
    _insertEntry(_Entry<T>(box, value: value), leafLevel: true);
    _size++;
  }

  /// Removes one entry with [value] under exactly [box]. Returns whether
  /// one was found.
  bool remove(Rect box, T value) {
    final leaf = _findLeaf(_root, box, value);
    if (leaf == null) return false;
    leaf.entries.removeWhere((e) => e.value == value && e.box == box);
    _size--;
    _condense(leaf);
    if (!_root.leaf && _root.entries.length == 1) {
      _root = _root.entries.first.child!..parent = null;
    }
    return true;
  }

  /// The values whose rectangles intersect [area].
  List<T> search(Rect area) {
    final out = <T>[];
    if (_size == 0) return out;
    final stack = [_root];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      for (final e in n.entries) {
        if (!e.box.intersects(area)) continue;
        if (n.leaf) {
          out.add(e.value as T);
        } else {
          stack.add(e.child!);
        }
      }
    }
    return out;
  }

  int _height(_Node<T> n) {
    var h = 1;
    var x = n;
    while (!x.leaf) {
      x = x.entries.first.child!;
      h++;
    }
    return h;
  }

  /// Inserts [entry] into a leaf (or, for a reinserted subtree, into a node
  /// at [depth] levels above the leaves).
  void _insertEntry(_Entry<T> entry, {required bool leafLevel, int depth = 0}) {
    var node = _root;
    final targetHeight = leafLevel ? 1 : depth + 1;
    while (_height(node) > targetHeight) {
      _Entry<T>? best;
      var bestGrowth = double.infinity;
      var bestArea = double.infinity;
      for (final e in node.entries) {
        final area = e.box.area;
        final growth = e.box.union(entry.box).area - area;
        if (growth < bestGrowth || (growth == bestGrowth && area < bestArea)) {
          best = e;
          bestGrowth = growth;
          bestArea = area;
        }
      }
      node = best!.child!;
    }
    node.entries.add(entry);
    entry.child?.parent = node;
    _adjust(node);
  }

  /// Splits [node] if it overflows and fixes the boxes on the path to the
  /// root.
  void _adjust(_Node<T> node) {
    _Node<T>? n = node;
    while (n != null) {
      _Node<T>? sibling;
      if (n.entries.length > maxEntries) sibling = _split(n);
      final parent = n.parent;
      if (parent == null) {
        if (sibling != null) {
          final root = _Node<T>(leaf: false);
          root.entries
            ..add(_Entry<T>(n.box, child: n))
            ..add(_Entry<T>(sibling.box, child: sibling));
          n.parent = root;
          sibling.parent = root;
          _root = root;
        }
        return;
      }
      for (final e in parent.entries) {
        if (identical(e.child, n)) e.box = n.box;
      }
      if (sibling != null) {
        parent.entries.add(_Entry<T>(sibling.box, child: sibling));
        sibling.parent = parent;
      }
      n = parent;
    }
  }

  /// Quadratic split: moves about half of [node]'s entries into a new
  /// sibling, which is returned.
  _Node<T> _split(_Node<T> node) {
    final all = List<_Entry<T>>.of(node.entries);
    // Pick the two seeds that would waste the most area together.
    var seedA = 0, seedB = 1;
    var worst = double.negativeInfinity;
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        final waste =
            all[i].box.union(all[j].box).area -
            all[i].box.area -
            all[j].box.area;
        if (waste > worst) {
          worst = waste;
          seedA = i;
          seedB = j;
        }
      }
    }
    final a = <_Entry<T>>[all[seedA]], b = <_Entry<T>>[all[seedB]];
    var boxA = all[seedA].box, boxB = all[seedB].box;
    final rest = [
      for (var i = 0; i < all.length; i++)
        if (i != seedA && i != seedB) all[i],
    ];
    while (rest.isNotEmpty) {
      // Keep both groups at least minEntries.
      if (a.length + rest.length == minEntries) {
        a.addAll(rest);
        break;
      }
      if (b.length + rest.length == minEntries) {
        b.addAll(rest);
        break;
      }
      // Next: the entry with the strongest preference.
      var pick = 0;
      var bestDiff = double.negativeInfinity;
      for (var i = 0; i < rest.length; i++) {
        final dA = boxA.union(rest[i].box).area - boxA.area;
        final dB = boxB.union(rest[i].box).area - boxB.area;
        final diff = (dA - dB).abs();
        if (diff > bestDiff) {
          bestDiff = diff;
          pick = i;
        }
      }
      final e = rest.removeAt(pick);
      final dA = boxA.union(e.box).area - boxA.area;
      final dB = boxB.union(e.box).area - boxB.area;
      final toA =
          dA < dB ||
          (dA == dB &&
              (boxA.area < boxB.area ||
                  (boxA.area == boxB.area && a.length <= b.length)));
      if (toA) {
        a.add(e);
        boxA = boxA.union(e.box);
      } else {
        b.add(e);
        boxB = boxB.union(e.box);
      }
    }
    node.entries
      ..clear()
      ..addAll(a);
    final sibling = _Node<T>(leaf: node.leaf);
    sibling.entries.addAll(b);
    for (final e in a) {
      e.child?.parent = node;
    }
    for (final e in b) {
      e.child?.parent = sibling;
    }
    return sibling;
  }

  _Node<T>? _findLeaf(_Node<T> node, Rect box, T value) {
    if (node.leaf) {
      for (final e in node.entries) {
        if (e.value == value && e.box == box) return node;
      }
      return null;
    }
    for (final e in node.entries) {
      if (e.box.contains(box)) {
        final found = _findLeaf(e.child!, box, value);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// After a removal from [leaf]: drops underfull nodes on the path to the
  /// root, reinserts their entries, and fixes the boxes.
  void _condense(_Node<T> leaf) {
    final orphans = <(_Entry<T>, int)>[];
    var n = leaf;
    var level = 0;
    while (n.parent != null) {
      final parent = n.parent!;
      if (n.entries.length < minEntries) {
        parent.entries.removeWhere((e) => identical(e.child, n));
        for (final e in n.entries) {
          orphans.add((e, level));
        }
      } else {
        for (final e in parent.entries) {
          if (identical(e.child, n)) e.box = n.box;
        }
      }
      n = parent;
      level++;
    }
    if (_root.entries.isEmpty && !_root.leaf) {
      _root = _Node<T>(leaf: true);
    }
    for (final (e, lvl) in orphans) {
      if (e.child == null) {
        _insertEntry(e, leafLevel: true);
      } else {
        _reinsertSubtree(e, lvl);
      }
    }
  }

  void _reinsertSubtree(_Entry<T> e, int level) {
    // A subtree whose root was at [level] above the leaves: if the tree has
    // become too short for it, reinsert its leaf entries one by one.
    if (_height(_root) < level + 1) {
      final stack = [e.child!];
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        for (final c in n.entries) {
          if (n.leaf) {
            _insertEntry(c, leafLevel: true);
          } else {
            stack.add(c.child!);
          }
        }
      }
      return;
    }
    _insertEntry(e, leafLevel: false, depth: level);
  }
}
