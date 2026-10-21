// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The parts of `pubspec.lock` the policy needs: which hosts packages are
/// downloaded from.
class LockFile {
  const LockFile(this.packageHosts);

  /// Reads every `url:` entry. These only appear for hosted packages.
  factory LockFile.parse(String text) {
    final urlLine = RegExp(r'^\s+url:\s*"?([^"\s]+)"?\s*$');
    return LockFile({
      for (final line in text.split('\n'))
        if (urlLine.firstMatch(line) case final match?) match.group(1)!,
    });
  }

  final Set<String> packageHosts;
}
