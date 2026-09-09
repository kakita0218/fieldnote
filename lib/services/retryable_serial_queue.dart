class RetryableSerialQueue<K, V extends Object> {
  final Map<K, V> _pending = <K, V>{};
  Future<void> _tail = Future<void>.value();

  int get pendingCount => _pending.length;

  Future<void> enqueue(
    K key,
    V value,
    Future<bool> Function(V value) persist,
  ) {
    _pending[key] = value;
    return _schedule(key, persist);
  }

  Future<void> drain() => _tail;

  Future<void> retryPending(Future<bool> Function(V value) persist) {
    final List<K> keys = List<K>.from(_pending.keys);
    for (final K key in keys) {
      _schedule(key, persist);
    }
    return _tail;
  }

  Future<void> _schedule(
    K key,
    Future<bool> Function(V value) persist,
  ) {
    _tail = _tail.catchError((Object _) {}).then((_) async {
      final V? value = _pending[key];
      if (value == null) return;
      bool saved = false;
      try {
        saved = await persist(value);
      } catch (_) {
        saved = false;
      }
      if (saved && identical(_pending[key], value)) {
        _pending.remove(key);
      }
    });
    return _tail;
  }
}
