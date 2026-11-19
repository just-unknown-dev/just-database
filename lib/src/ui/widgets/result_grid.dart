/// A lazily built table of query results, and page controls for it.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../admin_utils.dart';

/// A table of [rows] under a header of [columns].
///
/// Only the rows on screen are built (a [ListView.builder] with a fixed row
/// height), so a page of thousands of rows stays cheap. Wide tables scroll
/// sideways. Needs a bounded height.
@internal
class ResultGrid extends StatefulWidget {
  const ResultGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.leadingWidth = 0,
    this.leadingBuilder,
    this.leadingHeader,
    this.isSelected,
  });

  /// The column names.
  final List<String> columns;

  /// The rows, one value per column.
  final List<List<Object?>> rows;

  /// The width of the cell [leadingBuilder] builds before each row.
  final double leadingWidth;

  /// Builds a cell (row actions) before row `index`.
  final Widget Function(BuildContext context, int index)? leadingBuilder;

  /// The header above the leading cells.
  final Widget? leadingHeader;

  /// Whether row `index` is highlighted.
  final bool Function(int index)? isSelected;

  static const double rowHeight = 40;
  static const double headerHeight = 40;

  @override
  State<ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<ResultGrid> {
  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  List<double>? _widths;
  List<String>? _widthsFor;
  List<List<Object?>>? _widthsRows;

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  List<double> _columnWidths() {
    if (_widths != null &&
        identical(_widthsFor, widget.columns) &&
        identical(_widthsRows, widget.rows)) {
      return _widths!;
    }
    final sample = math.min(widget.rows.length, 100);
    final widths = <double>[];
    for (var c = 0; c < widget.columns.length; c++) {
      var chars = widget.columns[c].length + 2;
      for (var r = 0; r < sample; r++) {
        final row = widget.rows[r];
        if (c >= row.length) continue;
        final len = formatCellValue(row[c], maxLength: 60).length;
        if (len > chars) chars = len;
      }
      widths.add((chars * 8.0 + 24).clamp(72.0, 360.0));
    }
    _widthsFor = widget.columns;
    _widthsRows = widget.rows;
    return _widths = widths;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final widths = _columnWidths();
    final contentWidth =
        widget.leadingWidth + widths.fold<double>(0, (a, b) => a + b);

    Widget cell(String text, double width, {TextStyle? style}) => SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: style,
        ),
      ),
    );

    final header = Container(
      height: ResultGrid.headerHeight,
      color: cs.surfaceContainerHigh,
      child: Row(
        children: [
          if (widget.leadingWidth > 0)
            SizedBox(
              width: widget.leadingWidth,
              child: widget.leadingHeader ?? const SizedBox.shrink(),
            ),
          for (var c = 0; c < widget.columns.length; c++)
            cell(
              widget.columns[c],
              widths[c],
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
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
                  Divider(height: 1, color: cs.outlineVariant),
                  Expanded(
                    child: Scrollbar(
                      controller: _vertical,
                      child: ListView.builder(
                        controller: _vertical,
                        itemExtent: ResultGrid.rowHeight,
                        itemCount: widget.rows.length,
                        itemBuilder: (context, i) {
                          final row = widget.rows[i];
                          final selected = widget.isSelected?.call(i) ?? false;
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              color: selected
                                  ? cs.secondaryContainer
                                  : (i.isOdd
                                        ? cs.surfaceContainerLowest
                                        : null),
                              border: Border(
                                bottom: BorderSide(
                                  color: cs.outlineVariant,
                                  width: 0.5,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                if (widget.leadingWidth > 0)
                                  SizedBox(
                                    width: widget.leadingWidth,
                                    child: widget.leadingBuilder?.call(
                                      context,
                                      i,
                                    ),
                                  ),
                                for (var c = 0; c < widget.columns.length; c++)
                                  _valueCell(
                                    context,
                                    c < row.length ? row[c] : null,
                                    widths[c],
                                    selected,
                                  ),
                              ],
                            ),
                          );
                        },
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

  Widget _valueCell(
    BuildContext context,
    Object? value,
    double width,
    bool selected,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isNull = value == null;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          formatCellValue(value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: TextStyle(
            fontSize: 13,
            color: isNull
                ? cs.onSurfaceVariant
                : (selected ? cs.onSecondaryContainer : cs.onSurface),
            fontStyle: isNull ? FontStyle.italic : null,
          ),
        ),
      ),
    );
  }
}

/// "21-40 of 120" with first / previous / next / last buttons and an
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
    this.pageSizes = const [25, 50, 100, 250],
    this.busy = false,
  });

  /// The first row shown (0-based).
  final int offset;
  final int pageSize;
  final int total;
  final ValueChanged<int> onOffsetChanged;
  final ValueChanged<int>? onPageSizeChanged;
  final List<int> pageSizes;
  final bool busy;

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
          builder: (context, constraints) => _row(
            context,
            wide: constraints.maxWidth >= 520,
            range: range,
            last: last,
            canBack: canBack,
            canForward: canForward,
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required bool wide,
    required String range,
    required int last,
    required bool canBack,
    required bool canForward,
  }) {
    final cs = Theme.of(context).colorScheme;
    final density = wide ? VisualDensity.standard : VisualDensity.compact;
    final sizes = onPageSizeChanged;
    return Row(
      children: [
        if (sizes != null) ...[
          if (wide) ...[
            Text(
              'Rows per page',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 6),
          ],
          DropdownButton<int>(
            value: pageSizes.contains(pageSize) ? pageSize : null,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 13, color: cs.onSurface),
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
  }
}
