import 'dart:async';

import 'package:fieldnote/services/retryable_serial_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('保存を直列実行し、全件完了までdrainが待機する', () async {
    final RetryableSerialQueue<String, int> queue =
        RetryableSerialQueue<String, int>();
    final List<int> started = <int>[];
    final Map<int, Completer<bool>> completions = <int, Completer<bool>>{};

    Future<bool> persist(int value) {
      started.add(value);
      final Completer<bool> completer = Completer<bool>();
      completions[value] = completer;
      return completer.future;
    }

    queue.enqueue('first', 1, persist);
    queue.enqueue('second', 2, persist);
    await Future<void>.delayed(Duration.zero);

    expect(started, <int>[1]);
    expect(queue.pendingCount, 2);

    completions[1]!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(started, <int>[1, 2]);

    bool drained = false;
    queue.drain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    completions[2]!.complete(true);
    await queue.drain();
    expect(drained, isTrue);
    expect(queue.pendingCount, 0);
  });

  test('失敗した項目を保持して再試行できる', () async {
    final RetryableSerialQueue<String, int> queue =
        RetryableSerialQueue<String, int>();
    int attempts = 0;

    await queue.enqueue('photo', 7, (value) async {
      attempts++;
      return false;
    });
    expect(queue.pendingCount, 1);

    await queue.retryPending((value) async {
      attempts++;
      return true;
    });
    expect(attempts, 2);
    expect(queue.pendingCount, 0);
  });
}
