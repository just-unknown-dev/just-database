import 'dart:math' as math;

/// A 2D point with x and y coordinates.
class Point {
  final double x;
  final double y;

  const Point(this.x, this.y);

  /// Euclidean distance to another point.
  double distanceTo(Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Returns this point as a [BoundingBox] of zero area.
  BoundingBox get boundingBox => BoundingBox(x, y, x, y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory Point.fromJson(Map<String, dynamic> json) =>
      Point((json['x'] as num).toDouble(), (json['y'] as num).toDouble());

  @override
  String toString() => 'Point($x, $y)';

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// A 2D axis-aligned bounding box.
class BoundingBox {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const BoundingBox(this.minX, this.minY, this.maxX, this.maxY);

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get area => width * height;

  Point get center => Point((minX + maxX) / 2, (minY + maxY) / 2);

  /// Returns true if this bounding box intersects [other].
  bool intersects(BoundingBox other) =>
      !(other.minX > maxX ||
          other.maxX < minX ||
          other.minY > maxY ||
          other.maxY < minY);

  /// Returns true if this bounding box fully contains [other].
  bool contains(BoundingBox other) =>
      other.minX >= minX &&
      other.maxX <= maxX &&
      other.minY >= minY &&
      other.maxY <= maxY;

  /// Returns true if this bounding box contains [point].
  bool containsPoint(Point point) =>
      point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY;

  /// Returns a new BoundingBox expanded to include [other].
  BoundingBox expand(BoundingBox other) => BoundingBox(
    math.min(minX, other.minX),
    math.min(minY, other.minY),
    math.max(maxX, other.maxX),
    math.max(maxY, other.maxY),
  );

  /// Returns a new BoundingBox expanded to include [point].
  BoundingBox expandPoint(Point point) => BoundingBox(
    math.min(minX, point.x),
    math.min(minY, point.y),
    math.max(maxX, point.x),
    math.max(maxY, point.y),
  );

  /// Area of enlargement needed to include [other].
  double enlargement(BoundingBox other) {
    final expanded = expand(other);
    return expanded.area - area;
  }

  Map<String, dynamic> toJson() => {
    'minX': minX,
    'minY': minY,
    'maxX': maxX,
    'maxY': maxY,
  };

  factory BoundingBox.fromJson(Map<String, dynamic> json) => BoundingBox(
    (json['minX'] as num).toDouble(),
    (json['minY'] as num).toDouble(),
    (json['maxX'] as num).toDouble(),
    (json['maxY'] as num).toDouble(),
  );

  @override
  String toString() => 'BBox([$minX,$minY] - [$maxX,$maxY])';

  @override
  bool operator ==(Object other) =>
      other is BoundingBox &&
      other.minX == minX &&
      other.minY == minY &&
      other.maxX == maxX &&
      other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);
}

/// A polygon defined by an ordered list of vertices.
class Polygon {
  final List<Point> vertices;

  const Polygon(this.vertices);

  /// Computes the bounding box of the polygon.
  BoundingBox get boundingBox {
    if (vertices.isEmpty) return const BoundingBox(0, 0, 0, 0);
    var minX = vertices[0].x;
    var minY = vertices[0].y;
    var maxX = vertices[0].x;
    var maxY = vertices[0].y;
    for (final v in vertices) {
      if (v.x < minX) minX = v.x;
      if (v.y < minY) minY = v.y;
      if (v.x > maxX) maxX = v.x;
      if (v.y > maxY) maxY = v.y;
    }
    return BoundingBox(minX, minY, maxX, maxY);
  }

  /// Ray-casting algorithm to test if [point] is inside this polygon.
  bool containsPoint(Point point) {
    int count = 0;
    final n = vertices.length;
    for (int i = 0; i < n; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % n];
      if (((a.y <= point.y && point.y < b.y) ||
              (b.y <= point.y && point.y < a.y)) &&
          (point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x)) {
        count++;
      }
    }
    return count % 2 == 1;
  }

  /// Computes the area using the shoelace formula.
  double get area {
    double sum = 0;
    final n = vertices.length;
    for (int i = 0; i < n; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % n];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2;
  }

  List<Map<String, dynamic>> toJson() =>
      vertices.map((v) => v.toJson()).toList();

  factory Polygon.fromJson(List<dynamic> json) =>
      Polygon(json.cast<Map<String, dynamic>>().map(Point.fromJson).toList());

  @override
  String toString() => 'Polygon(${vertices.length} vertices)';
}
