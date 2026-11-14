// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ai_types.dart';

/// Why a request did not give an answer.
enum AiProblem {
  /// The key is wrong, revoked, or missing.
  badKey,

  /// Too many requests for now: try again after [AiException.retryAfter].
  rateLimited,

  /// The provider's account has no credit left, or billing is not set up.
  billing,

  /// The model or the provider's safety checks declined to answer.
  refused,

  /// The mail is too long for the model.
  contextTooLong,

  /// The model is not offered (any more) to this key.
  modelNotFound,

  /// The provider could not be reached (offline, timeout, TLS).
  network,

  /// The provider had a problem (5xx, overloaded).
  server,

  /// The provider refused the request as malformed (a bug, or an
  /// endpoint that is not quite compatible).
  badRequest,

  /// The answer could not be read.
  badResponse,

  /// The user stopped it.
  cancelled,

  /// This month's spending limit is reached: no more calls this month.
  capReached,

  /// No provider is set up for the feature, or it is turned off.
  notConfigured,
}

final class AiException implements Exception {
  const AiException(this.problem, this.message, {this.retryAfter});

  final AiProblem problem;

  /// Detail for the user, already plain; the provider's own words where
  /// it gave some.
  final String message;

  /// For [AiProblem.rateLimited], when the provider said.
  final Duration? retryAfter;

  /// A sentence for the user about what happened with [provider].
  String explain(String provider) => switch (problem) {
    AiProblem.badKey =>
      '$provider didn\'t accept the key. Check it in Settings, AI assistant.',
    AiProblem.rateLimited => switch (retryAfter) {
      final wait? when wait.inSeconds > 0 =>
        '$provider asks to wait ${_wait(wait)} before the next request.',
      _ => '$provider is busy with too many requests. Try again shortly.',
    },
    AiProblem.billing =>
      'Your $provider account has no credit left, or billing isn\'t set up.',
    AiProblem.refused => '$provider declined to answer this one.',
    AiProblem.contextTooLong =>
      'This is too long for the model. Try one email instead of the whole '
          'conversation, or a model with a larger limit.',
    AiProblem.modelNotFound =>
      '$provider doesn\'t offer this model to your key. Choose another in '
          'Settings, AI assistant.',
    AiProblem.network => 'Couldn\'t reach $provider: $message',
    AiProblem.server => '$provider had a problem. Try again later.',
    AiProblem.badRequest => '$provider didn\'t accept the request: $message',
    AiProblem.badResponse => '$provider\'s answer couldn\'t be read.',
    AiProblem.cancelled => 'Stopped.',
    AiProblem.capReached => message,
    AiProblem.notConfigured => message,
  };

  static String _wait(Duration d) => d.inMinutes >= 1
      ? '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}'
      : '${d.inSeconds} seconds';

  @override
  String toString() => 'AiException(${problem.name}): $message';
}

/// [AiException] for a request that was cancelled with [AiCancel].
const aiCancelled = AiException(AiProblem.cancelled, 'cancelled');
