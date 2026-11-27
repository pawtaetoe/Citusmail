// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Checks for what the user types or what arrives from outside, done once
/// at the edge: each validator turns text into a typed value ([Valid]) or
/// a short reason to show ([Invalid]). Past the edge, values are trusted.
///
/// ```dart
/// switch (const Port()(text)) {
///   case Valid(:final value): connect(value);
///   case Invalid(:final reason): show(reason);
/// }
/// ```
///
/// In a form: `validator: const HostName().field`.
library;

import 'dart:io' show InternetAddress;

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart' show StoredMailbox;
import 'package:mail_sync/mail_sync.dart' show FolderNameProblem, FolderNames;
import 'package:mail_web/mail_web.dart' show PublicAddressPolicy;

/// A checked value, or why there is none.
sealed class Validated<T> {
  const Validated();

  bool get isValid;

  /// The value, or null when invalid.
  T? get valueOrNull;

  /// Why it is invalid, in words for the user; null when valid.
  String? get reason;

  /// The value converted with [convert], or the same reason.
  Validated<R> map<R>(R Function(T value) convert);

  /// The value checked further with [next], or the same reason.
  Validated<R> then<R>(Validated<R> Function(T value) next);
}

final class Valid<T> extends Validated<T> {
  const Valid(this.value);

  final T value;

  @override
  bool get isValid => true;

  @override
  T get valueOrNull => value;

  @override
  String? get reason => null;

  @override
  Validated<R> map<R>(R Function(T value) convert) => Valid(convert(value));

  @override
  Validated<R> then<R>(Validated<R> Function(T value) next) => next(value);

  @override
  bool operator ==(Object other) => other is Valid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Valid($value)';
}

final class Invalid extends Validated<Never> {
  const Invalid(this.reason);

  /// A short sentence for the user, such as "Enter a port number".
  @override
  final String reason;

  @override
  bool get isValid => false;

  @override
  Never? get valueOrNull => null;

  @override
  Validated<R> map<R>(R Function(Never value) convert) => this;

  @override
  Validated<R> then<R>(Validated<R> Function(Never value) next) => this;

  @override
  bool operator ==(Object other) => other is Invalid && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'Invalid($reason)';
}

/// Turns text into a [T], or a reason.
abstract base class Validator<T> {
  const Validator();

  Validated<T> call(String input);

  /// For a form field's `validator`: the reason, or null when valid.
  String? field(String? input) => call(input ?? '').reason;
}

/// Characters that are never typed on purpose: C0 and C1 controls, and
/// the Unicode line and paragraph separators. Each could start a new line
/// in a mail header or a protocol command.
abstract final class ControlCharacters {
  static final _any = RegExp('[\\x00-\\x1F\\x7F-\\x9F  ]');
  static final _lineBreak = RegExp('[\\r\\n\u0085  ]');

  /// Controls other than tab, line feed and carriage return.
  static final _beyondLines = RegExp(
    '[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F-\\x84\\x86-\\x9F]',
  );

  /// Whether [text] has any (line breaks and tabs too).
  static bool inLine(String text) => _any.hasMatch(text);

  /// Whether [text] has any besides tabs and line breaks.
  static bool inText(String text) => _beyondLines.hasMatch(text);

  static bool hasLineBreak(String text) => _lineBreak.hasMatch(text);

  /// [text] with each one replaced by a space.
  static String toSpaces(String text) => text.replaceAll(_any, ' ');
}

/// Text, trimmed: one line unless [multiline], at most [maxLength]
/// characters. With [empty], it must not be empty and that is the reason.
final class TextInput extends Validator<String> {
  const TextInput({
    this.empty,
    this.maxLength = 200,
    this.multiline = false,
    this.keepIndent = false,
  });

  /// Why empty text is not allowed; null when it may be empty.
  final String? empty;
  final int maxLength;

  /// Whether line breaks (and tabs) belong in it.
  final bool multiline;

  /// Whether spaces at the start are kept (a layout the user chose); then
  /// only the end is trimmed.
  final bool keepIndent;

  @override
  Validated<String> call(String input) {
    final lines = multiline
        ? input.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
        : input;
    final text = lines.trim().isEmpty
        ? ''
        : keepIndent
        ? lines.trimRight()
        : lines.trim();
    if (text.isEmpty) {
      return switch (empty) {
        final reason? => Invalid(reason),
        null => const Valid(''),
      };
    }
    if (text.runes.length > maxLength) {
      return Invalid('Use at most $maxLength characters.');
    }
    if (multiline && ControlCharacters.inText(text)) {
      return const Invalid('Remove the invisible control characters.');
    }
    if (!multiline && ControlCharacters.inLine(text)) {
      return Invalid(
        ControlCharacters.hasLineBreak(text)
            ? 'Keep it on one line.'
            : 'Remove the invisible control characters.',
      );
    }
    return Valid(text);
  }
}

/// A whole number from [min] to [max], in plain digits.
final class WholeNumber extends Validator<int> {
  const WholeNumber({required this.min, required this.max, this.reason})
    : assert(min <= max);

  final int min;
  final int max;

  /// The reason for anything else; by default it names the range.
  final String? reason;

  static final _digits = RegExp(r'^-?[0-9]{1,15}$');

  @override
  Validated<int> call(String input) {
    final text = input.trim();
    final value = _digits.hasMatch(text) ? int.parse(text) : null;
    if (value == null || value < min || value > max) {
      return Invalid(reason ?? 'Enter a whole number from $min to $max.');
    }
    return Valid(value);
  }
}

/// A port number (1 to 65535).
final class Port extends Validator<int> {
  const Port({this.reason = 'Enter a port number'});

  final String reason;

  @override
  Validated<int> call(String input) =>
      WholeNumber(min: 1, max: 65535, reason: reason)(input);
}

/// An amount of money (or a price) from [min] to [max], such as `5`,
/// `0.25`, `0,25` or `$5`: never NaN, infinite or in exponent form.
final class Amount extends Validator<double> {
  const Amount({
    this.min = 0,
    required this.max,
    this.reason = 'Enter an amount such as 5 or 0.25.',
  }) : assert(min <= max);

  final double min;
  final double max;
  final String reason;

  static final _amount = RegExp(r'^\$?\s*([0-9]{0,12})(?:[.,]([0-9]{0,6}))?$');

  @override
  Validated<double> call(String input) {
    final match = _amount.firstMatch(input.trim());
    final whole = match?[1] ?? '';
    final fraction = match?[2] ?? '';
    if (match == null || (whole.isEmpty && fraction.isEmpty)) {
      return Invalid(reason);
    }
    final value = double.parse(
      '${whole.isEmpty ? '0' : whole}.${fraction.isEmpty ? '0' : fraction}',
    );
    if (value < min) return Invalid(reason);
    if (value > max) {
      return Invalid('Enter an amount up to ${_plain(max)}.');
    }
    return Valid(value);
  }

  static String _plain(double n) =>
      n == n.roundToDouble() ? n.toStringAsFixed(0) : '$n';
}

/// One email address, `name@example.com`, read with the mail parser
/// ([AddressParser]). With [sendable], also one the message builder can
/// write ([HeaderEncoder.validateAddress]): mail to it can be sent.
/// Domains with letters beyond ASCII (`münchen.de`) are fine; they are
/// sent in their Punycode form.
final class EmailAddress extends Validator<MailAddress> {
  const EmailAddress({
    this.reason = 'Enter an email address, like name@example.com.',
    this.sendable = true,
  });

  final String reason;
  final bool sendable;

  /// The longest address SMTP allows (RFC 5321 4.5.3.1).
  static const maxLength = 254;

  static final _space = RegExp(r'\s');

  @override
  Validated<MailAddress> call(String input) {
    final text = input.trim();
    if (text.isEmpty ||
        text.length > maxLength ||
        ControlCharacters.inLine(text) ||
        _space.hasMatch(text)) {
      return Invalid(reason);
    }
    final parsed = const AddressParser().parse(text);
    if (parsed.defects.isNotEmpty ||
        parsed.entries.length != 1 ||
        parsed.entries.single is! MailAddress) {
      return Invalid(reason);
    }
    final address = parsed.entries.single as MailAddress;
    if (address.displayName != null ||
        address.localPart.isEmpty ||
        address.domain.isEmpty ||
        address.localPart.contains('@')) {
      return Invalid(reason);
    }
    if (sendable) {
      if (sendProblem(address) case final problem?) return Invalid(problem);
    }
    return Valid(address);
  }

  /// Why mail to [address] can't be sent (the message builder would refuse
  /// it), or null when it can.
  static String? sendProblem(MailAddress address) {
    try {
      const HeaderEncoder().validateAddress(address);
      return null;
    } on MessageBuildException catch (e) {
      return e.message.contains('local part')
          ? 'Addresses with special letters or quotes before the @ can\'t '
                'be used yet.'
          : 'The part after the @ isn\'t a domain.';
    }
  }
}

/// A server's host name, such as `imap.example.com`, in lower case: ASCII
/// letters, digits and hyphens, in at least two parts.
final class HostName extends Validator<String> {
  const HostName({this.reason = 'Enter a server name'});

  final String reason;

  static const maxLength = 253;

  static final _host = RegExp(
    r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$',
  );

  @override
  Validated<String> call(String input) {
    final text = input.trim().toLowerCase();
    if (text.contains('://') || text.contains('/')) {
      return const Invalid('Enter only the server name, without http:// or /');
    }
    if (text.length > maxLength || !_host.hasMatch(text)) {
      return Invalid(reason);
    }
    return Valid(text);
  }
}

/// A web address with `https`, or with plain `http` when
/// [httpOnLocalNetwork] and the host may be on the user's own network: no
/// other scheme (`file:`, `javascript:`), a host, and no user name or
/// password in it.
///
/// A host given by name can't be looked up here; over plain http the
/// network layer checks what it resolves to before sending anything
/// (mail_ai's `IoAiHttp`). An IP address is judged here.
final class WebAddress extends Validator<Uri> {
  const WebAddress({
    this.httpOnLocalNetwork = false,
    this.reason = 'Enter a web address, like https://example.com.',
  });

  final bool httpOnLocalNetwork;
  final String reason;

  static const maxLength = 2000;

  @override
  Validated<Uri> call(String input) {
    final text = input.trim();
    if (text.length > maxLength) {
      return const Invalid('That address is too long.');
    }
    if (text.isEmpty || ControlCharacters.inLine(text) || text.contains(' ')) {
      return Invalid(reason);
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) return Invalid(reason);
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && (scheme != 'http' || !httpOnLocalNetwork)) {
      return const Invalid('Use an address that starts with https://.');
    }
    if (!uri.hasAuthority || uri.host.isEmpty) return Invalid(reason);
    if (uri.userInfo.isNotEmpty) {
      return const Invalid(
        'Leave the user name and password out of the address.',
      );
    }
    if (scheme == 'http' && isPublicAddress(uri.host)) {
      return const Invalid(
        'Plain http is only for your own computer or network. Use https:// '
        'for this address.',
      );
    }
    return Valid(uri);
  }

  /// Whether [host] is an IP address on the public internet (not
  /// loopback, private or link-local). Names are not looked up: false.
  static bool isPublicAddress(String host) {
    final address = InternetAddress.tryParse(host);
    return address != null && const PublicAddressPolicy().allows(address);
  }
}

/// A new IMAP folder's name among an account's [existing] folders,
/// trimmed ("Projects/2026" makes a subfolder). The rules are the sync
/// layer's ([FolderNames.problemWith]): nothing empty, nothing too long,
/// no IMAP wildcards or quotes, not the server's separator, not INBOX.
final class FolderName extends Validator<String> {
  const FolderName(this.existing);

  final List<StoredMailbox> existing;

  @override
  Validated<String> call(String input) {
    final name = input.trim();
    return switch (FolderNames.problemWith(existing, name)) {
      null => Valid(name),
      FolderNameProblem.empty when name.isEmpty => const Invalid(
        'Enter a name.',
      ),
      FolderNameProblem.empty => const Invalid(
        'Give each folder between two / a name.',
      ),
      FolderNameProblem.tooLong => const Invalid(
        'Use at most ${FolderNames.maxPartLength} characters for each folder.',
      ),
      FolderNameProblem.invalidCharacter => const Invalid(
        'Folder names can\'t contain %, *, ", \\ or line breaks.',
      ),
      FolderNameProblem.separator => Invalid(
        'Folder names can\'t contain "${FolderNames.separatorOf(existing)}" '
        'on this server.',
      ),
      FolderNameProblem.reserved when name.toUpperCase() == 'INBOX' =>
        const Invalid('Inbox already exists.'),
      FolderNameProblem.reserved => const Invalid(
        'That can\'t be a folder name.',
      ),
    };
  }
}

/// What to search for: control characters become spaces, and it is at
/// most [maxLength] characters. Empty is fine (no search).
final class SearchText extends Validator<String> {
  const SearchText({this.maxLength = defaultMaxLength});

  static const defaultMaxLength = 200;

  final int maxLength;

  @override
  Validated<String> call(String input) {
    if (input.length > maxLength * 4) {
      return Invalid('Search for at most $maxLength characters.');
    }
    final text = ControlCharacters.toSpaces(input).trim();
    if (text.runes.length > maxLength) {
      return Invalid('Search for at most $maxLength characters.');
    }
    return Valid(text);
  }
}

/// An API key as pasted, trimmed: printable ASCII without spaces or line
/// breaks, [minLength] to [maxLength] characters. With [empty], it must
/// not be empty and that is the reason.
final class ApiKey extends Validator<String> {
  const ApiKey({this.empty, this.minLength = 8, this.maxLength = 512});

  final String? empty;
  final int minLength;
  final int maxLength;

  static final _printable = RegExp(r'^[\x21-\x7E]+$');

  @override
  Validated<String> call(String input) {
    final key = input.trim();
    if (key.isEmpty) {
      return switch (empty) {
        final reason? => Invalid(reason),
        null => const Valid(''),
      };
    }
    if (key.length > maxLength) {
      return const Invalid(
        'That is longer than an API key. Copy just the key.',
      );
    }
    if (!_printable.hasMatch(key)) {
      return const Invalid(
        'An API key has no spaces or line breaks. Copy just the key.',
      );
    }
    if (key.length < minLength) {
      return const Invalid('That is shorter than an API key.');
    }
    return Valid(key);
  }
}

/// Text, trimmed, that must match [pattern] whole (a key of a known
/// shape); anything else is invalid with [reason].
final class MatchingText extends Validator<String> {
  const MatchingText(this.pattern, this.reason);

  /// A regular expression the whole text must match.
  final String pattern;
  final String reason;

  static final _compiled = <String, RegExp>{};

  @override
  Validated<String> call(String input) {
    final text = input.trim();
    final regExp = _compiled.putIfAbsent(pattern, () => RegExp('^$pattern\$'));
    return regExp.hasMatch(text) ? Valid(text) : Invalid(reason);
  }
}

/// A model's id as a provider names it (`gpt-4o-mini`,
/// `meta-llama/Llama-3.3-70B-Instruct`, `llama3.2:3b`): no spaces or
/// control characters, at most [maxLength] characters.
final class ModelId extends Validator<String> {
  const ModelId({this.empty = 'Choose or type a model.'});

  final String empty;

  static const maxLength = 200;

  static final _space = RegExp(r'\s');

  @override
  Validated<String> call(String input) {
    final id = input.trim();
    if (id.isEmpty) return Invalid(empty);
    if (id.length > maxLength) {
      return const Invalid('That is longer than a model\'s name.');
    }
    if (_space.hasMatch(id) || ControlCharacters.inLine(id)) {
      return const Invalid('A model\'s name has no spaces.');
    }
    return Valid(id);
  }
}
