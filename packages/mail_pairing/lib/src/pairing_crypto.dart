// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mail_appsync/mail_appsync.dart';

import 'pairing_offer.dart';
import 'transfer.dart';
import 'x25519.dart';

/// The keys of one pairing connection, from the X25519 secret of the
/// computer's key (from its QR code) and the phone's key, with the QR
/// code's token as HKDF salt: only someone who scanned the code, and the
/// computer that shows it, can compute them.
final class PairingKeys {
  PairingKeys._(this.toComputer, this.toPhone, this.checkCode);

  factory PairingKeys.derive({
    required List<int> sharedSecret,
    required List<int> token,
    required List<int> computerKey,
    required List<int> phoneKey,
  }) {
    final out = Hkdf.derive(
      sharedSecret,
      salt: token,
      info: [
        ...utf8.encode('citusmail pairing v1'),
        ...computerKey,
        ...phoneKey,
      ],
      length: 68,
    );
    final number =
        ((out[64] << 24) | (out[65] << 16) | (out[66] << 8) | out[67]) %
        1000000;
    final digits = number.toString().padLeft(6, '0');
    return PairingKeys._(
      Uint8List.sublistView(out, 0, 32),
      Uint8List.sublistView(out, 32, 64),
      '${digits.substring(0, 3)} ${digits.substring(3)}',
    );
  }

  final Uint8List toComputer;
  final Uint8List toPhone;

  /// Six digits both screens show (`123 456`), so the user sees they are
  /// connected to each other.
  final String checkCode;
}

/// Messages in one direction, each sealed with ChaCha20-Poly1305 under
/// its own number (the nonce): a message replayed, dropped or reordered
/// fails to open.
final class SealedDirection {
  SealedDirection(this._key);

  final Uint8List _key;
  int _counter = 0;

  static Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    for (var i = 0; i < 8; i++) {
      n[11 - i] = (counter >> (8 * i)) & 0xFF;
    }
    return n;
  }

  /// [type] and the JSON of [message], sealed.
  Uint8List seal(int type, Object? message) {
    final sealed = ChaCha20Poly1305.encrypt(
      _key,
      _nonce(_counter++),
      utf8.encode(jsonEncode(message)),
      aad: [PairingOffer.version, type],
    );
    return Uint8List(sealed.length + 1)
      ..[0] = type
      ..setRange(1, sealed.length + 1, sealed);
  }

  /// The message in [frame], which must be of [type]. Throws
  /// [AuthenticationFailed] if it was changed or sealed with another key,
  /// [PairingFormatException] if it isn't the expected message.
  Object? open(int type, List<int> frame) {
    if (frame.isEmpty) throw const PairingFormatException('empty message');
    if (frame[0] != type) {
      throw PairingFormatException('expected message $type, got ${frame[0]}');
    }
    final plain = ChaCha20Poly1305.decrypt(
      _key,
      _nonce(_counter++),
      frame.sublist(1),
      aad: [PairingOffer.version, type],
    );
    try {
      return jsonDecode(utf8.decode(plain));
    } on FormatException {
      throw const PairingFormatException('not JSON');
    }
  }
}

/// Why a file from the phone can't be opened.
enum PairingFileProblem {
  /// Not a Citusmail accounts file.
  notAFile,

  /// Made for another code (another computer, or an earlier code here).
  otherCode,

  /// Changed or damaged on the way.
  damaged,

  /// The code it was made for has expired or was used.
  expired,
}

final class PairingFileException implements Exception {
  const PairingFileException(this.problem);

  final PairingFileProblem problem;

  @override
  String toString() => 'PairingFileException(${problem.name})';
}

/// The file route, for when the phone can't reach the computer: the same
/// accounts, sealed on the phone to the computer's one-time key from the
/// QR code. The file is:
///
///     CMPAIR | version (1) | code id (8) | phone key (32) | nonce (12) |
///     ciphertext + tag
///
/// The key comes from X25519 of a new key of the phone's and the
/// computer's key, through HKDF with the QR token as salt; everything
/// before the ciphertext is associated data. The code id (from a hash of
/// the token) tells which code a file was made for, without revealing it.
/// Only the computer that showed the code can open the file, while that
/// code is still showing: its private key is in its memory only.
abstract final class PairingFile {
  static const extension = 'cmpair';
  static const fileName = 'citusmail-accounts.$extension';
  static final _magic = ascii.encode('CMPAIR');
  static const _headerLength = 6 + 1 + 8 + 32 + 12;

  /// Files larger than this are not ours.
  static const maxLength = 1 << 20;

  /// The id of the code with [token] (8 bytes).
  static Uint8List codeId(List<int> token) => Uint8List.fromList(
    sha256
        .convert([...utf8.encode('citusmail pairing file id'), ...token])
        .bytes
        .sublist(0, 8),
  );

  /// [transfer] sealed for the computer that showed [offer].
  static Uint8List seal(
    PairingOffer offer,
    AccountTransfer transfer, {
    Random? random,
  }) {
    final r = random ?? Random.secure();
    final phonePrivate = X25519.newPrivateKey(r);
    final phoneKey = X25519.publicKey(phonePrivate);
    final shared = X25519.sharedSecret(phonePrivate, offer.publicKey);
    final key = _key(shared, offer.token, offer.publicKey, phoneKey);
    final nonce = Uint8List.fromList([
      for (var i = 0; i < 12; i++) r.nextInt(256),
    ]);
    final header = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(PairingOffer.version)
      ..add(codeId(offer.token))
      ..add(phoneKey)
      ..add(nonce);
    final head = header.takeBytes();
    final sealed = ChaCha20Poly1305.encrypt(
      key,
      nonce,
      utf8.encode(jsonEncode(transfer.toJson())),
      aad: head,
    );
    return Uint8List(head.length + sealed.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + sealed.length, sealed);
  }

  /// The accounts in [file], opened with the computer's one-time
  /// [privateKey] and the code's [token]. Throws [PairingFileException].
  static AccountTransfer open(
    List<int> file, {
    required List<int> privateKey,
    required List<int> token,
  }) {
    if (file.length < _headerLength + ChaCha20Poly1305.tagLength ||
        file.length > maxLength) {
      throw const PairingFileException(PairingFileProblem.notAFile);
    }
    for (var i = 0; i < _magic.length; i++) {
      if (file[i] != _magic[i]) {
        throw const PairingFileException(PairingFileProblem.notAFile);
      }
    }
    if (file[6] != PairingOffer.version) {
      throw const PairingFileException(PairingFileProblem.notAFile);
    }
    final id = codeId(token);
    for (var i = 0; i < 8; i++) {
      if (file[7 + i] != id[i]) {
        throw const PairingFileException(PairingFileProblem.otherCode);
      }
    }
    final phoneKey = file.sublist(15, 47);
    final nonce = file.sublist(47, 59);
    final head = file.sublist(0, _headerLength);
    try {
      final shared = X25519.sharedSecret(privateKey, phoneKey);
      final key = _key(shared, token, X25519.publicKey(privateKey), phoneKey);
      final plain = ChaCha20Poly1305.decrypt(
        key,
        nonce,
        file.sublist(_headerLength),
        aad: head,
      );
      return AccountTransfer.fromJson(jsonDecode(utf8.decode(plain)));
    } on AuthenticationFailed {
      throw const PairingFileException(PairingFileProblem.damaged);
    } on ArgumentError {
      throw const PairingFileException(PairingFileProblem.damaged);
    } on FormatException {
      throw const PairingFileException(PairingFileProblem.damaged);
    } on PairingFormatException {
      throw const PairingFileException(PairingFileProblem.damaged);
    }
  }

  static Uint8List _key(
    List<int> shared,
    List<int> token,
    List<int> computerKey,
    List<int> phoneKey,
  ) => Hkdf.derive(
    shared,
    salt: token,
    info: [
      ...utf8.encode('citusmail pairing file v1'),
      ...computerKey,
      ...phoneKey,
    ],
  );
}
