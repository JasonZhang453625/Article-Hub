class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;

  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
  });

  factory AppVersion.parse(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid app version: $value');
    }
    return AppVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
    );
  }

  /// Android versionCode mapping used by Memora releases.
  ///
  /// Example: 2.1.8 -> 20108.
  int get versionCode {
    if (minor > 99 || patch > 99) {
      throw StateError(
        'Version components must fit MAJOR.MINOR(0-99).PATCH(0-99): $this',
      );
    }
    final code = major * 10000 + minor * 100 + patch;
    if (code <= 0 || code > 2100000000) {
      throw StateError('Android versionCode is out of range: $code');
    }
    return code;
  }

  @override
  int compareTo(AppVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) return majorComparison;
    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}
