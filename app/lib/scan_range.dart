/// Bound scan duration and retained results to at most a /16.
const maximumScanAddresses = 65536;

void validateScanSize(int hostCount) {
  if (hostCount < 1 || hostCount > maximumScanAddresses) {
    throw ArgumentError(
      'Subnet scans support at most $maximumScanAddresses addresses (/16). '
      'Configure a smaller subnet before scanning.',
    );
  }
}

/// Generates a worker's portion lazily, without allocating the whole subnet.
Iterable<String> scanWorkerAddresses(int first, int last, int stride) sync* {
  if (stride < 1) throw ArgumentError.value(stride, 'stride');
  for (var value = first; value <= last; value += stride) {
    yield '${(value >> 24) & 255}.${(value >> 16) & 255}.'
        '${(value >> 8) & 255}.${value & 255}';
  }
}
