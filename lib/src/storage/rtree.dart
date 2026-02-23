import 'dart:math' as math;
import 'spatial.dart';

/// Entry stored in the R-tree.
class RTreeEntry {
  final int id; // user-supplied row/record ID
  final BoundingBox bbox;

  const RTreeEntry({required this.id, required this.bbox});

  factory RTreeEntry.fromJson(Map<String, dynamic> json) => RTreeEntry(
    id: json['id'] as int,
    bbox: BoundingBox.fromJson(json['bbox'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {'id': id, 'bbox': bbox.toJson()};
}

/// An in-memory R-tree spatial index using the quadratic split algorithm.
/// Supports insert, delete, bounding-box search, and k-nearest-neighbour query.
class RTreeIndex {
  static const int _maxEntries = 9;
  static const int _minEntries = 4;

  _RTreeNode _root = _RTreeNode(isLeaf: true);

  RTreeIndex._();

  /// Creates a new empty R-tree index.
  factory RTreeIndex() => RTreeIndex._();

  /// Returns the number of entries in the index.
  int get length => _countEntries(_root);

  int _countEntries(_RTreeNode node) {
    if (node.isLeaf) return node.entries.length;
    return node.children.fold(0, (sum, child) => sum + _countEntries(child));
  }

  // ---------------------------------------------------------------------------
  // Insert
  // ---------------------------------------------------------------------------

  /// Inserts an entry with the given [id] and [bbox].
  void insert(int id, BoundingBox bbox) {
    final entry = RTreeEntry(id: id, bbox: bbox);
    final overflow = _insert(_root, entry, _treeHeight(_root));
    if (overflow != null) {
      // Root was split
      final newRoot = _RTreeNode(isLeaf: false);
      newRoot.children.add(_root);
      newRoot.children.add(overflow);
      newRoot.bbox = _root.bbox!.expand(overflow.bbox!);
      _root = newRoot;
    } else {
      _updateBBox(_root);
    }
  }

  _RTreeNode? _insert(_RTreeNode node, RTreeEntry entry, int targetLevel) {
    if (node.isLeaf) {
      node.entries.add(entry);
      _updateBBox(node);
      if (node.entries.length > _maxEntries) {
        return _splitLeaf(node);
      }
      return null;
    }

    // Choose sub-tree with minimum enlargement
    final best = _chooseBestChild(node, entry.bbox);
    final overflow = _insert(best, entry, targetLevel);
    _updateBBox(node);
    if (overflow != null) {
      node.children.add(overflow);
      if (node.children.length > _maxEntries) {
        return _splitInternal(node);
      }
    }
    return null;
  }

  _RTreeNode _chooseBestChild(_RTreeNode node, BoundingBox bbox) {
    _RTreeNode? best;
    double bestEnlargement = double.infinity;
    double bestArea = double.infinity;
    for (final child in node.children) {
      final enlargement = child.bbox?.enlargement(bbox) ?? double.infinity;
      final childArea = child.bbox?.area ?? double.infinity;
      if (enlargement < bestEnlargement ||
          (enlargement == bestEnlargement && childArea < bestArea)) {
        best = child;
        bestEnlargement = enlargement;
        bestArea = childArea;
      }
    }
    return best ?? node.children.first;
  }

  // ---------------------------------------------------------------------------
  // Quadratic split
  // ---------------------------------------------------------------------------

  _RTreeNode _splitLeaf(_RTreeNode node) {
    final sibling = _RTreeNode(isLeaf: true);
    _quadraticPickSeeds(node.entries, (a, b) {
      final left = [a];
      final right = [b];
      final remaining = List.of(node.entries)
        ..remove(a)
        ..remove(b);
      _distributeEntries(remaining, left, right);
      node.entries
        ..clear()
        ..addAll(left);
      sibling.entries.addAll(right);
    });
    _updateBBox(node);
    _updateBBox(sibling);
    return sibling;
  }

  _RTreeNode _splitInternal(_RTreeNode node) {
    final sibling = _RTreeNode(isLeaf: false);
    final allChildren = List.of(node.children);
    node.children.clear();

    // Find the pair (a, b) that waste most area
    double worstWaste = double.negativeInfinity;
    int seedA = 0, seedB = 1;
    for (int i = 0; i < allChildren.length; i++) {
      for (int j = i + 1; j < allChildren.length; j++) {
        final combined = (allChildren[i].bbox ?? const BoundingBox(0, 0, 0, 0))
            .expand(allChildren[j].bbox ?? const BoundingBox(0, 0, 0, 0));
        final waste =
            combined.area -
            (allChildren[i].bbox?.area ?? 0) -
            (allChildren[j].bbox?.area ?? 0);
        if (waste > worstWaste) {
          worstWaste = waste;
          seedA = i;
          seedB = j;
        }
      }
    }

    final leftChildren = [allChildren[seedA]];
    final rightChildren = [allChildren[seedB]];
    final remaining = List.of(allChildren)
      ..removeAt(math.max(seedA, seedB))
      ..removeAt(math.min(seedA, seedB));

    for (final child in remaining) {
      final leftBBox = leftChildren.fold<BoundingBox?>(
        null,
        (acc, c) =>
            acc == null ? c.bbox : (c.bbox == null ? acc : acc.expand(c.bbox!)),
      );
      final rightBBox = rightChildren.fold<BoundingBox?>(
        null,
        (acc, c) =>
            acc == null ? c.bbox : (c.bbox == null ? acc : acc.expand(c.bbox!)),
      );
      final leftGrowth =
          leftBBox?.enlargement(child.bbox ?? const BoundingBox(0, 0, 0, 0)) ??
          0;
      final rightGrowth =
          rightBBox?.enlargement(child.bbox ?? const BoundingBox(0, 0, 0, 0)) ??
          0;
      if (leftChildren.length + remaining.length - 1 == _minEntries) {
        leftChildren.add(child);
      } else if (rightChildren.length + remaining.length - 1 == _minEntries) {
        rightChildren.add(child);
      } else if (leftGrowth < rightGrowth) {
        leftChildren.add(child);
      } else {
        rightChildren.add(child);
      }
    }

    node.children.addAll(leftChildren);
    sibling.children.addAll(rightChildren);
    _updateBBox(node);
    _updateBBox(sibling);
    return sibling;
  }

  void _quadraticPickSeeds<T extends Object>(
    List<T> items,
    void Function(T, T) callback,
  ) {
    if (items.length < 2) return;
    T? seedA, seedB;
    double worstWaste = double.negativeInfinity;
    for (int i = 0; i < items.length; i++) {
      for (int j = i + 1; j < items.length; j++) {
        final bboxA = _bboxOf(items[i]);
        final bboxB = _bboxOf(items[j]);
        if (bboxA == null || bboxB == null) continue;
        final combined = bboxA.expand(bboxB);
        final waste = combined.area - bboxA.area - bboxB.area;
        if (waste > worstWaste) {
          worstWaste = waste;
          seedA = items[i];
          seedB = items[j];
        }
      }
    }
    if (seedA != null && seedB != null) callback(seedA, seedB);
  }

  void _distributeEntries(
    List<RTreeEntry> remaining,
    List<RTreeEntry> left,
    List<RTreeEntry> right,
  ) {
    for (final entry in remaining) {
      final leftBox = left.fold<BoundingBox?>(
        null,
        (acc, e) => acc == null ? e.bbox : acc.expand(e.bbox),
      );
      final rightBox = right.fold<BoundingBox?>(
        null,
        (acc, e) => acc == null ? e.bbox : acc.expand(e.bbox),
      );
      final leftGrow = leftBox?.enlargement(entry.bbox) ?? 0;
      final rightGrow = rightBox?.enlargement(entry.bbox) ?? 0;
      if (left.length + remaining.length - remaining.indexOf(entry) ==
          _minEntries) {
        left.add(entry);
      } else if (right.length + remaining.length - remaining.indexOf(entry) ==
          _minEntries) {
        right.add(entry);
      } else if (leftGrow <= rightGrow) {
        left.add(entry);
      } else {
        right.add(entry);
      }
    }
  }

  BoundingBox? _bboxOf(dynamic item) {
    if (item is RTreeEntry) return item.bbox;
    if (item is _RTreeNode) return item.bbox;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  /// Removes the entry with the given [id]. Returns true if found.
  bool delete(int id) {
    final removed = _delete(_root, id);
    if (removed) _updateBBox(_root);
    return removed;
  }

  bool _delete(_RTreeNode node, int id) {
    if (node.isLeaf) {
      final before = node.entries.length;
      node.entries.removeWhere((e) => e.id == id);
      return node.entries.length < before;
    }
    for (final child in node.children) {
      if (child.bbox != null && _delete(child, id)) {
        _updateBBox(node);
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Returns all entries whose bounding boxes intersect [bbox].
  List<RTreeEntry> search(BoundingBox bbox) {
    final results = <RTreeEntry>[];
    _search(_root, bbox, results);
    return results;
  }

  void _search(_RTreeNode node, BoundingBox bbox, List<RTreeEntry> results) {
    if (node.bbox != null && !node.bbox!.intersects(bbox)) return;
    if (node.isLeaf) {
      for (final entry in node.entries) {
        if (entry.bbox.intersects(bbox)) results.add(entry);
      }
    } else {
      for (final child in node.children) {
        _search(child, bbox, results);
      }
    }
  }

  /// Returns the [k] nearest entries to the given [point].
  List<RTreeEntry> nearest(Point point, int k) {
    final all = <RTreeEntry>[];
    _collectAll(_root, all);
    all.sort((a, b) {
      final da = _minDist(a.bbox, point);
      final db = _minDist(b.bbox, point);
      return da.compareTo(db);
    });
    return all.take(k).toList();
  }

  double _minDist(BoundingBox bbox, Point point) {
    final cx = point.x.clamp(bbox.minX, bbox.maxX);
    final cy = point.y.clamp(bbox.minY, bbox.maxY);
    final dx = point.x - cx;
    final dy = point.y - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _collectAll(_RTreeNode node, List<RTreeEntry> results) {
    if (node.isLeaf) {
      results.addAll(node.entries);
    } else {
      for (final child in node.children) {
        _collectAll(child, results);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _updateBBox(_RTreeNode node) {
    if (node.isLeaf) {
      if (node.entries.isEmpty) {
        node.bbox = null;
        return;
      }
      node.bbox = node.entries.fold<BoundingBox?>(
        null,
        (acc, e) => acc == null ? e.bbox : acc.expand(e.bbox),
      );
    } else {
      if (node.children.isEmpty) {
        node.bbox = null;
        return;
      }
      for (final child in node.children) {
        _updateBBox(child);
      }
      node.bbox = node.children.fold<BoundingBox?>(
        null,
        (acc, c) =>
            c.bbox == null ? acc : (acc == null ? c.bbox : acc.expand(c.bbox!)),
      );
    }
  }

  int _treeHeight(_RTreeNode node) {
    if (node.isLeaf) return 0;
    return 1 + _treeHeight(node.children.first);
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {'root': _serializeNode(_root)};

  factory RTreeIndex.fromJson(Map<String, dynamic> json) {
    final index = RTreeIndex._();
    index._root = _deserializeNode(json['root'] as Map<String, dynamic>);
    return index;
  }

  static Map<String, dynamic> _serializeNode(_RTreeNode node) {
    return {
      'isLeaf': node.isLeaf,
      'bbox': node.bbox?.toJson(),
      'entries': node.entries.map((e) => e.toJson()).toList(),
      'children': node.children.map(_serializeNode).toList(),
    };
  }

  static _RTreeNode _deserializeNode(Map<String, dynamic> json) {
    final node = _RTreeNode(isLeaf: json['isLeaf'] as bool);
    if (json['bbox'] != null) {
      node.bbox = BoundingBox.fromJson(json['bbox'] as Map<String, dynamic>);
    }
    node.entries.addAll(
      (json['entries'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        RTreeEntry.fromJson,
      ),
    );
    node.children.addAll(
      (json['children'] as List<dynamic>).cast<Map<String, dynamic>>().map(
        _deserializeNode,
      ),
    );
    return node;
  }
}

class _RTreeNode {
  final bool isLeaf;
  BoundingBox? bbox;
  final List<RTreeEntry> entries = [];
  final List<_RTreeNode> children = [];

  _RTreeNode({required this.isLeaf});
}
