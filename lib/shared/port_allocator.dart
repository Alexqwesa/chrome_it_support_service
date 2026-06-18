class PortAllocator {
  PortAllocator(this.start, this.end) {
    if (start < 1 || end > 65535 || start > end) {
      throw ArgumentError('Invalid port range $start-$end.');
    }
  }

  final int start;
  final int end;
  final Set<int> _allocated = <int>{};

  int? allocate() {
    for (var port = start; port <= end; port++) {
      if (_allocated.add(port)) {
        return port;
      }
    }
    return null;
  }

  void release(int port) => _allocated.remove(port);
}
