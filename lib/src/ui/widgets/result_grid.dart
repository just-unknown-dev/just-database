/// A lazily built, sortable, resizable table of rows, and page controls.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../admin_style.dart';
import '../admin_utils.dart';

/// A cell of a [ResultGrid]: its row (in [ResultGrid.rows]) and column.
@internal
typedef GridCell = ({int row, int column});

/// A table of [rows] under a header of [columns].
///
/// Only the rows on screen are built, so thousands of rows stay cheap.
/// Wide tables scroll sideways. Headers sort ([onSort]) and resize by
/// dragging their right edge ([onResize]). A tap selects a cell, a second
/// tap on it (or a double tap) calls [onCellDoubleTap], a right click or
/// long press calls [onCellMenu]. Needs a bounded height.
@internal
class ResultGrid extends StatefulWidget {
  const ResultGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.widths = const {},
    this.onResize,
    this.sortColumn,
    this.sortAscending = true,
    this.onSort,
    this.leadingWidth = 0,
    this.leadingBuilder,
    this.leadingHeader,
    this.isSelected,
    this.selectedCell,
    this.onCellTap,
    this.onCellDoubleTap,
    this.onCellMenu,
    this.cellOverride,
    this.dense = false,
  });

  /// The column names.
  final List<String> columns;

  /// The rows, one value per column.
  final List<List<Object?>> rows;

  /// Widths chosen by the user, by column name.
  final Map<String, double> widths;

  /// Called while a column is resized.
  final void Function(String column, double width)? onResize;

  /// The column sorted by, or null.
  final String? sortColumn;

  /// Whether [sortColumn] sorts ascending.
  final bool sortAscending;

  /// Called when a header is tapped.
  final void Function(String column)? onSort;

  /// The width of the cell [leadingBuilder] builds before each row.
  final double leadingWidth;

  /// Builds a cell (row actions) before row `index`.
  final Widget Function(BuildContext context, int index)? leadingBuilder;

  /// The header above the leading cells.
  final Widget? leadingHeader;

  /// Whether row `index` is highlighted.
  final bool Function(int index)? isSelected;

  /// The highlighted cell.
  final GridCell? selectedCell;

  /// Called when a cell is tapped once.
  final void Function(GridCell cell)? onCellTap;

  /// Called when a cell is tapped twice (or the selected cell again).
  final void Function(GridCell cell)? onCellDoubleTap;

  /// Called on a right click or long press, with where it happened.
  final void Function(GridCell cell, Offset position)? onCellMenu;

  /// A widget to show instead of a cell's value (an editor), or null.
  final Widget? Function(BuildContext context, GridCell cell)? cellOverride;

  /// Shorter rows.
  final bool dense;

  /// The row height.
  double get rowHeight => dense ? 34 : 40;

  /// The header height.
  static const double headerHeight = 38;

  @override
  State<ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<ResultGrid> {
  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  List<double>? _auto;
  List<String>? _autoFor;
  List<List<Object?>>? _autoRows;
  GridCell? _lastTap;
  DateTime _lastTapAt = DateTime(0);

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  List<double> _autoWidths() {
    if (_auto != null &&
        identical(_autoFor, widget.columns) &&
        identical(_autoRows, widget.rows)) {
      return _auto!;
    }
    final sample = math.min(widget.rows.length, 100);
    final widths = <double>[];
    for (var c = 0; c < widget.columns.length; c++) {
      var chars = widget.columns[c].length + 3;
      for (var r = 0; r < sample; r++) {
        final row = widget.rows[r];
        if (c >= row.length) continue;
        final len = formatCellValue(row[c], maxLength: 60).length;
        if (len > chars) chars = len;
      }
      widths.add((chars * 7.8 + 28).clamp(72.0, 360.0));
    }
    _autoFor = widget.columns;
    _autoRows = widget.rows;
    return _auto = widths;
  }

  List<double> _widths() {
    final auto = _autoWidths();
    return [
      for (var c = 0; c < widget.columns.length; c++)
        widget.widths[widget.columns[c]] ?? auto[c],
    ];
  }

  void _tap(GridCell cell) {
    final now = DateTime.now();
    final again =
        _lastTap == cell &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 400);
    _lastTap = cell;
    _lastTapAt = now;
    if (again || widget.selectedCell == cell) {
      _lastTap = null;
      widget.onCellDoubleTap?.call(cell);
    } else {
      widget.onCellTap?.call(cell);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final widths = _widths();
    final contentWidth =
        widget.leadingWidth + widths.fold<double>(0, (a, b) => a + b);
    final header = Container(
      height: ResultGrid.headerHeight,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          if (widget.leadingWidth > 0)
            SizedBox(
              width: widget.leadingWidth,
              child: widget.leadingHeader ?? const SizedBox.shrink(),
            ),
          for (var c = 0; c < widget.columns.length; c++)
            _HeaderCell(
              key: ValueKey('jdb-header-${widget.columns[c]}'),
              name: widget.columns[c],
              width: widths[c],
              sorted: widget.sortColumn == widget.columns[c]
                  ? widget.sortAscending
                  : null,
              onSort: widget.onSort == null
                  ? null
                  : () => widget.onSort!(widget.columns[c]),
              onResize: widget.onResize == null
                  ? null
                  : (w) => widget.onResize!(widget.columns[c], w),
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(contentWidth, constraints.maxWidth);
        return Scrollbar(
          controller: _horizontal,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Expanded(
                    child: Scrollbar(
                      controller: _vertical,
                      child: ListView.builder(
                        controller: _vertical,
                        itemExtent: widget.rowHeight,
                        itemCount: widget.rows.length,
                        itemBuilder: (context, i) => _row(context, i, widths),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, int i, List<double> widths) {
    final cs = Theme.of(context).colorScheme;
    final row = widget.rows[i];
    final selected = widget.isSelected?.call(i) ?? false;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? cs.secondaryContainer
            : (i.isOdd ? cs.surfaceContainerLowest : null),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          if (widget.leadingWidth > 0)
            SizedBox(
              width: widget.leadingWidth,
              child: widget.leadingBuilder?.call(context, i),
            ),
          for (var c = 0; c < widget.columns.length; c++)
            _cell(
              context,
              (row: i, column: c),
              c < row.length ? row[c] : null,
              widths[c],
              selected,
            ),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    GridCell cell,
    Object? value,
    double width,
    bool rowSelected,
  ) {
    final cs = Theme.of(context).colorScheme;
    final override = widget.cellOverride?.call(context, cell);
    final isSelected = widget.selectedCell == cell;
    final isNull = value == null;
    final isNumber = value is num;
    final Widget content =
        override ??
        Align(
          alignment: isNumber ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            formatCellValue(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              fontSize: 13,
              fontFeatures: isNumber
                  ? const [FontFeature.tabularFigures()]
                  : null,
              color: isNull
                  ? cs.onSurfaceVariant
                  : (rowSelected ? cs.onSecondaryContainer : cs.onSurface),
              fontStyle: isNull ? FontStyle.italic : null,
            ),
          ),
        );
    final interactive =
        override == null &&
        (widget.onCellTap != null ||
            widget.onCellDoubleTap != null ||
            widget.onCellMenu != null);
    Widget box = Container(
      width: width,
      height: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: override == null ? 12 : 2),
      decoration: isSelected && override == null
          ? BoxDecoration(border: Border.all(color: cs.primary, width: 1.5))
          : null,
      child: content,
    );
    if (interactive) {
      box = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _tap(cell),
        onSecondaryTapUp: widget.onCellMenu == null
            ? null
            : (d) => widget.onCellMenu!(cell, d.globalPosition),
        onLongPressStart: widget.onCellMenu == null
            ? null
            : (d) => widget.onCellMenu!(cell, d.globalPosition),
        child: box,
      );
    }
    return KeyedSubtree(
      key: ValueKey('jdb-cell-${cell.row}-${cell.column}'),
      child: box,
    );
  }
}

class _HeaderCell extends StatefulWidget {
  const _HeaderCell({
    super.key,
    required this.name,
    required this.width,
    required this.sorted,
    required this.onSort,
    required this.onResize,
  });

  final String name;
  final double width;

  /// True ascending, false descending, null unsorted.
  final bool? sorted;
  final VoidCallback? onSort;
  final ValueChanged<double>? onResize;

  @override
  State<_HeaderCell> createState() => _HeaderCellState();
}

class _HeaderCellState extends State<_HeaderCell> {
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sorted = widget.sorted;
    final label = Row(
      children: [
        Flexible(
          child: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
        if (sorted != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(
              sorted ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: cs.primary,
            ),
          ),
      ],
    );
    return SizedBox(
      width: widget.width,
      child: Stack(
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: widget.onSort,
              child: Tooltip(
                message: widget.onSort == null
                    ? widget.name
                    : '${widget.name} — tap to sort',
                waitDuration: const Duration(milliseconds: 600),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
                  child: Align(alignment: Alignment.centerLeft, child: label),
                ),
              ),
            ),
          ),
          if (widget.onResize != null)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _dragWidth = widget.width,
                  onHorizontalDragUpdate: (d) {
                    final w = ((_dragWidth ?? widget.width) + d.delta.dx).clamp(
                      56.0,
                      900.0,
                    );
                    _dragWidth = w;
                    widget.onResize!(w);
                  },
                  onHorizontalDragEnd: (_) => _dragWidth = null,
                  child: Center(
                    child: Container(
                      width: 1,
                      height: 18,
                      color: cs.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "21–40 of 120" with first / previous / next / last buttons and an
/// optional page-size menu.
@internal
class PageBar extends StatelessWidget {
  const PageBar({
    super.key,
    required this.offset,
    required this.pageSize,
    required this.total,
    required this.onOffsetChanged,
    this.onPageSizeChanged,
    this.pageSizes = const [25, 50, 100, 250, 500],
    this.busy = false,
    this.leading,
  });

  /// The first row shown (0-based).
  final int offset;
  final int pageSize;
  final int total;
  final ValueChanged<int> onOffsetChanged;
  final ValueChanged<int>? onPageSizeChanged;
  final List<int> pageSizes;
  final bool busy;

  /// Shown at the start of the bar (a summary).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final last = total == 0 ? 0 : ((total - 1) ~/ pageSize) * pageSize;
    final end = math.min(offset + pageSize, total);
    final range = total == 0 ? '0 rows' : '${offset + 1}–$end of $total';
    final canBack = !busy && offset > 0;
    final canForward = !busy && offset + pageSize < total;
    return Material(
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 560;
            final density = wide
                ? VisualDensity.standard
                : VisualDensity.compact;
            final sizes = onPageSizeChanged;
            return Row(
              children: [
                if (leading != null && wide) Flexible(child: leading!),
                if (sizes != null) ...[
                  if (wide) ...[
                    const SizedBox(width: 12),
                    Text('Rows per page', style: AdminStyle.caption(context)),
                    const SizedBox(width: 6),
                  ],
                  DropdownButton<int>(
                    value: pageSizes.contains(pageSize) ? pageSize : null,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    style:
                        (Theme.of(context).textTheme.bodyMedium ??
                                const TextStyle())
                            .copyWith(fontSize: 13, color: cs.onSurface),
                    items: [
                      for (final s in pageSizes)
                        DropdownMenuItem(value: s, child: Text('$s')),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v != null) sizes(v);
                          },
                  ),
                ],
                const Spacer(),
                Flexible(
                  child: Text(
                    range,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  tooltip: 'First page',
                  visualDensity: density,
                  icon: const Icon(Icons.first_page),
                  onPressed: canBack ? () => onOffsetChanged(0) : null,
                ),
                IconButton(
                  tooltip: 'Previous page',
                  visualDensity: density,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: canBack
                      ? () => onOffsetChanged(math.max(0, offset - pageSize))
                      : null,
                ),
                IconButton(
                  tooltip: 'Next page',
                  visualDensity: density,
                  icon: const Icon(Icons.chevron_right),
                  onPressed: canForward
                      ? () => onOffsetChanged(offset + pageSize)
                      : null,
                ),
                IconButton(
                  tooltip: 'Last page',
                  visualDensity: density,
                  icon: const Icon(Icons.last_page),
                  onPressed: canForward ? () => onOffsetChanged(last) : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
