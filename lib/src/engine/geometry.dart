part of 'engine.dart';

/// A geometry: a point, or a polygon given by one closed ring.
///
/// Geometries are stored and passed around as WKT text:
/// `POINT(x y)` and `POLYGON((x1 y1, x2 y2, …, x1 y1))`. x is the
/// longitude and y the latitude where that matters (ST_DISTANCE_SPHERE).
final class _Geometry {
  _Geometry.point(double x, double y) : points = [(x, y)], isPoint = true;
  _Geometry.polygon(this.points) : isPoint = false;

  final List<(double, double)> points;
  final bool isPoint;

  (double, double) get point => points.first;

  Rect get bounds {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final (x, y) in points) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    return Rect(minX, minY, maxX, maxY);
  }

  String get wkt {
    if (isPoint) return 'POINT(${_num(point.$1)} ${_num(point.$2)})';
    // A WKT ring repeats its first point at the end.
    final ring = [
      for (final (x, y) in [...points, points.first]) '${_num(x)} ${_num(y)}',
    ];
    return 'POLYGON((${ring.join(', ')}))';
  }

  static String _num(double v) {
    final i = exactInt(v);
    return i != null && i.abs() < 1e15 ? '$i' : '$v';
  }

  /// Whether ([x], [y]) lies inside or on the border of this polygon.
  bool containsPoint(double x, double y) {
    final n = points.length;
    // On an edge?
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final (x1, y1) = points[j];
      final (x2, y2) = points[i];
      final cross = (x - x1) * (y2 - y1) - (y - y1) * (x2 - x1);
      if (cross.abs() < 1e-12 &&
          x >= math.min(x1, x2) - 1e-12 &&
          x <= math.max(x1, x2) + 1e-12 &&
          y >= math.min(y1, y2) - 1e-12 &&
          y <= math.max(y1, y2) + 1e-12) {
        return true;
      }
    }
    var inside = false;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final (xi, yi) = points[i];
      final (xj, yj) = points[j];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}

final _wktPoint = RegExp(
  r'^\s*POINT\s*\(\s*([-+0-9.eE]+)\s+([-+0-9.eE]+)\s*\)\s*$',
  caseSensitive: false,
);
final _wktPolygon = RegExp(
  r'^\s*POLYGON\s*\(\s*\(([^()]*)\)\s*\)\s*$',
  caseSensitive: false,
);

/// Reads a geometry from WKT; null when [v] is not one.
_Geometry? _geometry(Object? v) {
  if (v is! String) return null;
  var m = _wktPoint.firstMatch(v);
  if (m != null) {
    final x = double.tryParse(m[1]!), y = double.tryParse(m[2]!);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return _Geometry.point(x, y);
  }
  m = _wktPolygon.firstMatch(v);
  if (m == null) return null;
  final pts = <(double, double)>[];
  for (final pair in m[1]!.split(',')) {
    final xy = pair.trim().split(RegExp(r'\s+'));
    if (xy.length != 2) return null;
    final x = double.tryParse(xy[0]), y = double.tryParse(xy[1]);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    pts.add((x, y));
  }
  if (pts.length < 4 || pts.first != pts.last) return null;
  pts.removeLast();
  return _Geometry.polygon(pts);
}

double? _coordinate(Object? v) {
  if (v == null) return null;
  final d = toNumber(v).toDouble();
  return d.isFinite ? d : null;
}

_Geometry _envelope(double minX, double minY, double maxX, double maxY) {
  final x0 = math.min(minX, maxX), x1 = math.max(minX, maxX);
  final y0 = math.min(minY, maxY), y1 = math.max(minY, maxY);
  return _Geometry.polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)]);
}

bool _segmentsCross(
  (double, double) a,
  (double, double) b,
  (double, double) c,
  (double, double) d,
) {
  double orient((double, double) p, (double, double) q, (double, double) r) =>
      (q.$1 - p.$1) * (r.$2 - p.$2) - (q.$2 - p.$2) * (r.$1 - p.$1);
  final o1 = orient(a, b, c), o2 = orient(a, b, d);
  final o3 = orient(c, d, a), o4 = orient(c, d, b);
  return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0));
}

/// Whether [a] lies inside [b] (borders included).
bool _within(_Geometry a, _Geometry b) {
  if (b.isPoint) return a.isPoint && a.point == b.point;
  if (a.isPoint) return b.containsPoint(a.point.$1, a.point.$2);
  return a.points.every((p) => b.containsPoint(p.$1, p.$2));
}

bool _intersects(_Geometry a, _Geometry b) {
  if (a.isPoint && b.isPoint) return a.point == b.point;
  if (a.isPoint) return b.containsPoint(a.point.$1, a.point.$2);
  if (b.isPoint) return a.containsPoint(b.point.$1, b.point.$2);
  if (!a.bounds.intersects(b.bounds)) return false;
  if (a.points.any((p) => b.containsPoint(p.$1, p.$2))) return true;
  if (b.points.any((p) => a.containsPoint(p.$1, p.$2))) return true;
  final n = a.points.length, m = b.points.length;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < m; j++) {
      if (_segmentsCross(
        a.points[i],
        a.points[(i + 1) % n],
        b.points[j],
        b.points[(j + 1) % m],
      )) {
        return true;
      }
    }
  }
  return false;
}

double _pointSegment(
  (double, double) p,
  (double, double) a,
  (double, double) b,
) {
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : ((p.$1 - a.$1) * dx + (p.$2 - a.$2) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final x = a.$1 + t * dx - p.$1, y = a.$2 + t * dy - p.$2;
  return math.sqrt(x * x + y * y);
}

/// The planar distance between two geometries (0 when they intersect).
double _distance(_Geometry a, _Geometry b) {
  if (_intersects(a, b)) return 0;
  if (a.isPoint && b.isPoint) {
    final dx = a.point.$1 - b.point.$1, dy = a.point.$2 - b.point.$2;
    return math.sqrt(dx * dx + dy * dy);
  }
  var best = double.infinity;
  void edges(_Geometry poly, Iterable<(double, double)> pts) {
    final n = poly.points.length;
    for (final p in pts) {
      for (var i = 0; i < n; i++) {
        final d = _pointSegment(p, poly.points[i], poly.points[(i + 1) % n]);
        if (d < best) best = d;
      }
    }
  }

  if (!b.isPoint) edges(b, a.points);
  if (!a.isPoint) edges(a, b.points);
  return best;
}

/// The great-circle distance in metres between two points given as
/// (longitude, latitude) in degrees.
double _sphereDistance((double, double) a, (double, double) b) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.$2 - a.$2), dLon = rad(b.$1 - a.$1);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.$2)) *
          math.cos(rad(b.$2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h.toDouble())));
}

/// Reads two geometries from [a] (two WKT values, or four numbers as two
/// points: x1, y1, x2, y2).
(_Geometry, _Geometry)? _twoGeometries(List<Object?> a) {
  if (a.length == 4) {
    final c = [for (final v in a) _coordinate(v)];
    if (c.contains(null)) return null;
    return (_Geometry.point(c[0]!, c[1]!), _Geometry.point(c[2]!, c[3]!));
  }
  final g1 = _geometry(a[0]), g2 = _geometry(a[1]);
  if (g1 == null || g2 == null) return null;
  return (g1, g2);
}

final Map<String, _FunctionDef> _geometryFunctions = {
  'ST_MAKEPOINT': _FunctionDef(2, 2, (_, a) {
    final x = _coordinate(a[0]), y = _coordinate(a[1]);
    if (x == null || y == null) return null;
    return _Geometry.point(x, y).wkt;
  }),
  'ST_POINT': _FunctionDef(2, 2, (_, a) {
    final x = _coordinate(a[0]), y = _coordinate(a[1]);
    if (x == null || y == null) return null;
    return _Geometry.point(x, y).wkt;
  }),
  'ST_X': _FunctionDef(1, 1, (_, a) {
    final g = _geometry(a[0]);
    return g != null && g.isPoint ? g.point.$1 : null;
  }),
  'ST_Y': _FunctionDef(1, 1, (_, a) {
    final g = _geometry(a[0]);
    return g != null && g.isPoint ? g.point.$2 : null;
  }),
  'ST_MAKEENVELOPE': _FunctionDef(4, 4, (_, a) {
    final c = [for (final v in a) _coordinate(v)];
    if (c.contains(null)) return null;
    return _envelope(c[0]!, c[1]!, c[2]!, c[3]!).wkt;
  }),
  'ST_BBOX': _FunctionDef(4, 4, (_, a) {
    final c = [for (final v in a) _coordinate(v)];
    if (c.contains(null)) return null;
    return _envelope(c[0]!, c[1]!, c[2]!, c[3]!).wkt;
  }),
  'ST_ENVELOPE': _FunctionDef(1, 4, (_, a) {
    if (a.length == 4) {
      final c = [for (final v in a) _coordinate(v)];
      if (c.contains(null)) return null;
      return _envelope(c[0]!, c[1]!, c[2]!, c[3]!).wkt;
    }
    if (a.length != 1) return null;
    final g = _geometry(a[0]);
    if (g == null) return null;
    final b = g.bounds;
    return _envelope(b.minX, b.minY, b.maxX, b.maxY).wkt;
  }),
  'ST_GEOMFROMTEXT': _FunctionDef(1, 1, (_, a) => _geometry(a[0])?.wkt),
  'ST_ASTEXT': _FunctionDef(1, 1, (_, a) => _geometry(a[0])?.wkt),
  'ST_ISVALID': _FunctionDef(1, 1, (_, a) => _geometry(a[0]) == null ? 0 : 1),
  'ST_DISTANCE': _FunctionDef(2, 4, (_, a) {
    if (a.length == 3) return null;
    final g = _twoGeometries(a);
    return g == null ? null : _distance(g.$1, g.$2);
  }),
  'ST_DISTANCE_SPHERE': _FunctionDef(2, 4, (_, a) {
    if (a.length == 3) return null;
    final g = _twoGeometries(a);
    if (g == null || !g.$1.isPoint || !g.$2.isPoint) return null;
    return _sphereDistance(g.$1.point, g.$2.point);
  }),
  'ST_DWITHIN': _FunctionDef(3, 3, (_, a) {
    final g1 = _geometry(a[0]), g2 = _geometry(a[1]), d = _coordinate(a[2]);
    if (g1 == null || g2 == null || d == null) return null;
    return _distance(g1, g2) <= d ? 1 : 0;
  }),
  'ST_WITHIN': _FunctionDef(2, 2, (_, a) {
    final g1 = _geometry(a[0]), g2 = _geometry(a[1]);
    if (g1 == null || g2 == null) return null;
    return _within(g1, g2) ? 1 : 0;
  }),
  'ST_CONTAINS': _FunctionDef(2, 2, (_, a) {
    final g1 = _geometry(a[0]), g2 = _geometry(a[1]);
    if (g1 == null || g2 == null) return null;
    return _within(g2, g1) ? 1 : 0;
  }),
  'ST_INTERSECTS': _FunctionDef(2, 2, (_, a) {
    final g1 = _geometry(a[0]), g2 = _geometry(a[1]);
    if (g1 == null || g2 == null) return null;
    return _intersects(g1, g2) ? 1 : 0;
  }),
};
