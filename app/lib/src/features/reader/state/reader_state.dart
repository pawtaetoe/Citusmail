// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';

/// What the reading pane shows.
sealed class ReaderState {
  const ReaderState();

  StoredMessage? get message => null;
}

final class ReaderEmpty extends ReaderState {
  const ReaderEmpty();
}

final class ReaderLoading extends ReaderState {
  const ReaderLoading(this.message);

  @override
  final StoredMessage message;
}

final class ReaderReady extends ReaderState {
  const ReaderReady(
    this.message,
    this.view, {
    required this.to,
    required this.cc,
    required this.trust,
    required this.unsubscribe,
    this.unsubscribed,
    this.imagesShown = false,
  });

  @override
  final StoredMessage message;
  final MessageView view;

  /// What the message checks found (phishing signs, risky files).
  final TrustReport trust;

  /// How to unsubscribe from the message's list, if it has one.
  final UnsubscribePlan unsubscribe;

  /// When the user unsubscribed from this list, if they did.
  final Unsubscription? unsubscribed;

  /// Whether the message's remote images may load (the user asked, for
  /// this message or for this verified sender).
  final bool imagesShown;

  /// Whether images may be loaded at all: never for mail that looks like
  /// a scam.
  bool get imagesAllowed => trust.level != TrustLevel.danger;

  ReaderReady copyWith({
    StoredMessage? message,
    Unsubscription? unsubscribed,
    bool? imagesShown,
  }) => ReaderReady(
    message ?? this.message,
    view,
    to: to,
    cc: cc,
    trust: trust,
    unsubscribe: unsubscribe,
    unsubscribed: unsubscribed ?? this.unsubscribed,
    imagesShown: imagesShown ?? this.imagesShown,
  );
  final List<MailAddress> to;
  final List<MailAddress> cc;
}

final class ReaderFailed extends ReaderState {
  const ReaderFailed(this.message, this.reason);

  @override
  final StoredMessage message;
  final String reason;
}
