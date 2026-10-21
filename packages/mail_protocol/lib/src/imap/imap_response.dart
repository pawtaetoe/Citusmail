// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'imap_value.dart';

/// OK, NO, BAD (tagged or untagged), plus PREAUTH and BYE (untagged).
enum ImapStatus { ok, no, bad, preauth, bye }

/// A response code in square brackets, e.g. `[UIDVALIDITY 3857529045]`.
final class ImapResponseCode {
  ImapResponseCode(String name, List<ImapValue> arguments)
    : name = name.toUpperCase(),
      arguments = List.unmodifiable(arguments);

  /// Upper case, e.g. `UIDVALIDITY`, `APPENDUID`, `ALREADYEXISTS`.
  final String name;
  final List<ImapValue> arguments;

  /// The first argument as a number (common for UIDNEXT, UIDVALIDITY...).
  int? get number => arguments.isEmpty ? null : arguments.first.asNumber;

  @override
  String toString() =>
      arguments.isEmpty ? '[$name]' : '[$name ${arguments.join(' ')}]';
}

/// A response line (with any literals) from the server.
sealed class ImapResponse {
  const ImapResponse();
}

/// `tag OK|NO|BAD [code] text`: completes a command.
final class ImapTaggedResponse extends ImapResponse {
  const ImapTaggedResponse(this.tag, this.status, this.code, this.text);

  final String tag;
  final ImapStatus status;
  final ImapResponseCode? code;
  final String text;
}

/// `* OK|NO|BAD|PREAUTH|BYE [code] text`.
final class ImapUntaggedStatus extends ImapResponse {
  const ImapUntaggedStatus(this.status, this.code, this.text);

  final ImapStatus status;
  final ImapResponseCode? code;
  final String text;
}

/// `* [number] KEYWORD values...`, e.g. `* 23 EXISTS`, `* 12 FETCH (...)`,
/// `* LIST (...) "/" INBOX`, `* CAPABILITY ...`.
final class ImapUntaggedData extends ImapResponse {
  ImapUntaggedData(this.number, String keyword, List<ImapValue> values)
    : keyword = keyword.toUpperCase(),
      values = List.unmodifiable(values);

  /// The leading number for message data (EXISTS, EXPUNGE, FETCH...).
  final int? number;

  /// Upper case keyword.
  final String keyword;
  final List<ImapValue> values;
}

/// `+ text`: the server waits for more data (literal or SASL).
final class ImapContinuation extends ImapResponse {
  const ImapContinuation(this.text);

  final String text;
}
