import 'package:flutter_test/flutter_test.dart';

import '../../example/example.dart';

void main() {
  test('the example tour runs and prints what it promises', () async {
    final log = await runTour();
    expect(log, [
      'Austen: 1 book(s), first in 1815',
      "O'Brien: 1 book(s), first in 1939",
      'rolled back: CHECK constraint failed: year > 0',
      'books: 2',
      'migration: applied',
      'done: Read Emma, due 2030-01-01T00:00:00.000Z',
      'copy has 6 rows in authors, books, _migrations, tasks',
    ]);
  });
}
