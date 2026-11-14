// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../security/app_lock.dart';
import '../security/pin_dialogs.dart';
import '../services/app_services.dart';
import '../ui/app_icons.dart';
import 'account_export.dart';
import 'pairing_share.dart';
import 'qr_scanner.dart';

/// Connects to the computer of a scanned code (tests replace it).
typedef PairingConnectFn = Future<PairingConnection> Function(
  PairingOffer offer,
  String phoneName,
);

Future<PairingConnection> _connect(PairingOffer offer, String phoneName) =>
    PairingClient.connect(offer, phoneName: phoneName);

/// Asks for the app lock's fingerprint or PIN when the lock is on: the
/// accounts' passwords leave the phone. True when confirmed (or no lock).
Future<bool> confirmWithLock(
  BuildContext context,
  AppLock lock,
  String title,
) async {
  if (!lock.enabled) return true;
  if (lock.useBiometrics &&
      await lock.biometrics.isAvailable() &&
      await lock.biometrics.authenticate(title)) {
    return true;
  }
  if (!context.mounted) return false;
  return PinDialogs.confirm(context, title: title, check: lock.verify);
}

/// Settings > Send accounts to a computer (the phone's side): scan the
/// code on the computer, choose accounts, confirm, send. Over the local
/// network, or as a sealed file when the phone can't reach the computer.
final class SendAccountsPage extends StatefulWidget {
  const SendAccountsPage({
    super.key,
    required this.services,
    this.scanner = CameraQrScanner.build,
    this.connect = _connect,
    this.shareFile,
    this.phoneName,
  });

  final AppServices services;
  final QrScannerBuilder scanner;
  final PairingConnectFn connect;

  /// Hands the sealed file to the share sheet (default: Android's).
  final Future<bool> Function(Uint8List bytes)? shareFile;

  /// This phone's name, as the computer shows it.
  final String? phoneName;

  @override
  State<SendAccountsPage> createState() => _SendAccountsPageState();
}

enum _Step { scanning, connecting, problem, choosing, sending, sent, shared }

final class _SendAccountsPageState extends State<SendAccountsPage> {
  _Step _step = _Step.scanning;
  PairingOffer? _offer;
  PairingConnection? _connection;
  String? _problem;
  String? _computerName;

  /// Whether the problem allows sending a file instead.
  bool _fileOffered = false;

  /// Sending a file rather than over the network.
  bool _asFile = false;
  List<TransferResult> _results = const [];
  late final List<Account> _accounts = widget.services.store.accounts.all();
  late final Set<int> _chosen = {for (final a in _accounts) a.id};
  final _signInAgain = <int>{};
  bool _syncOn = false;
  bool _withSync = true;

  late final _export = AccountExport(widget.services);

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.services.deviceSync.enabled.then((on) {
        if (mounted) setState(() => _syncOn = on);
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_connection?.cancel());
    super.dispose();
  }

  String get _phoneName {
    if (widget.phoneName case final name?) return name;
    final host = Platform.localHostname;
    return host.isEmpty || host == 'localhost' ? 'Android phone' : host;
  }

  void _scanAgain() => setState(() {
    unawaited(_connection?.cancel());
    _connection = null;
    _offer = null;
    _problem = null;
    _asFile = false;
    _step = _Step.scanning;
  });

  Future<void> _onCode(String text) async {
    if (_step != _Step.scanning) return;
    final offer = PairingOffer.decode(text);
    if (offer == null) {
      setState(() {
        _step = _Step.problem;
        _fileOffered = false;
        _problem =
            'That isn\'t a $appName code. On the computer, open $appName and '
            'choose Add account, then Add accounts from your phone.';
      });
      return;
    }
    _offer = offer;
    if (!offer.reachable) {
      return _chooseFile();
    }
    setState(() => _step = _Step.connecting);
    try {
      final connection = await widget.connect(offer, _phoneName);
      if (!mounted) {
        unawaited(connection.cancel());
        return;
      }
      _connection = connection;
      _computerName = connection.computerName;
      await _markSignInAgain(connection.clients);
      setState(() => _step = _Step.choosing);
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.problem;
        _fileOffered = true;
        _problem = switch (e.problem) {
          PairingProblem.unreachable =>
            'Your phone couldn\'t reach this computer. Put both on the same '
                'Wi-Fi and try again.',
          PairingProblem.refused =>
            'The computer didn\'t accept this code: it may have expired or '
                'been used. Show a new code on the computer and scan again.',
          PairingProblem.notThatComputer =>
            'Something other than your computer answered. Show a new code on '
                'the computer and scan again.',
          PairingProblem.connectionLost =>
            'The connection to the computer broke off. Try again.',
        };
      });
    }
  }

  Future<void> _markSignInAgain(Map<String, String>? clients) async {
    _signInAgain.clear();
    for (final a in _accounts) {
      if (!await _export.arrivesSignedIn(a, computerClients: clients)) {
        _signInAgain.add(a.id);
      }
    }
  }

  Future<void> _chooseFile() async {
    await _connection?.cancel();
    _connection = null;
    await _markSignInAgain(null);
    if (!mounted) return;
    setState(() {
      _asFile = true;
      _step = _Step.choosing;
    });
  }

  List<Account> get _selected =>
      _accounts.where((a) => _chosen.contains(a.id)).toList();

  Future<bool> _confirm() async {
    final count = _selected.length;
    final what = count == 1 ? '1 account' : '$count accounts';
    final where = _asFile
        ? 'a file for your computer'
        : _connection?.computerName ?? 'your computer';
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send $what to $where?'),
        content: Text(
          _asFile
              ? 'The file holds the passwords and sign-ins of the accounts you '
                    'chose, encrypted so that only the computer showing the code '
                    'can open it, while the code is showing.'
              : 'Their passwords and sign-ins go straight to this computer over '
                    'your local network, encrypted. Nothing goes through the '
                    'internet. Only send them to your own computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return false;
    return confirmWithLock(
      context,
      widget.services.lock,
      'Confirm to send your accounts',
    );
  }

  Future<void> _send() async {
    if (!await _confirm() || !mounted) return;
    final transfer = await _export.build(
      _selected,
      computerClients: _asFile ? null : _connection?.clients,
      withSync: _syncOn && _withSync,
    );
    if (!mounted) return;
    if (_asFile) {
      final file = PairingFile.seal(_offer!, transfer);
      final shared = await (widget.shareFile ?? PairingShare.share)(file);
      if (!mounted) return;
      if (shared) {
        setState(() => _step = _Step.shared);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No app could take the file.')),
        );
      }
      return;
    }
    final connection = _connection!;
    setState(() => _step = _Step.sending);
    try {
      final results = await connection.send(transfer);
      if (!mounted) return;
      setState(() {
        _results = results;
        _step = _Step.sent;
      });
    } on PairingException {
      if (!mounted) return;
      setState(() {
        _step = _Step.problem;
        _fileOffered = false;
        _problem =
            'The connection to the computer broke off. Check on the computer '
            'which accounts were added, then try again for the others.';
      });
    } finally {
      _connection = null;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Send accounts to a computer')),
    body: SafeArea(
      child: switch (_step) {
        _Step.scanning => _scanning(context),
        _Step.connecting => const _Busy('Connecting to your computer…'),
        _Step.sending => const _Busy('Adding the accounts on your computer…'),
        _Step.problem => _problemView(context),
        _Step.choosing => _choosing(context),
        _Step.sent => _sent(context),
        _Step.shared => _shared(context),
      },
    ),
  );

  Widget _scanning(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'On your computer, open $appName and choose Add account, then Add '
        'accounts from your phone. Point your camera at the code it shows.',
      ),
      const SizedBox(height: 16),
      AspectRatio(aspectRatio: 3 / 4, child: widget.scanner(context, _onCode)),
      const SizedBox(height: 12),
      Text(
        'Your accounts go straight to the computer over your Wi-Fi, encrypted. '
        'Nothing goes through the internet.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Widget _problemView(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Icon(
        AppIcons.noNetwork,
        size: 40,
        color: Theme.of(context).colorScheme.error,
      ),
      const SizedBox(height: 12),
      Text(_problem ?? '', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 20),
      FilledButton(onPressed: _scanAgain, child: const Text('Scan again')),
      if (_fileOffered && _offer != null) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _chooseFile,
          child: const Text('Send as a file instead'),
        ),
        const SizedBox(height: 8),
        const Text(
          'You send the file to your computer yourself, with any app (Quick '
          'Share, a cable, a message to yourself). It is encrypted: only the '
          'computer showing this code can open it, while the code is showing.',
        ),
      ],
    ],
  );

  Widget _choosing(BuildContext context) {
    final theme = Theme.of(context);
    final connection = _connection;
    final count = _selected.length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              if (connection != null)
                Card(
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected to ${connection.computerName}',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Check that your computer shows the same code:',
                        ),
                        const SizedBox(height: 4),
                        Text(
                          connection.checkCode,
                          key: const Key('check-code'),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Choose the accounts to put in the file. Then send the file '
                    'to your computer and open it there while its code is still '
                    'showing.',
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Accounts to send'),
              ),
              for (final a in _accounts)
                CheckboxListTile(
                  value: _chosen.contains(a.id),
                  onChanged: (on) => setState(() {
                    on == true ? _chosen.add(a.id) : _chosen.remove(a.id);
                  }),
                  title: Text(a.displayName ?? a.email),
                  subtitle: switch ((
                    a.displayName == null ? null : a.email,
                    _signInAgain.contains(a.id)
                        ? 'You sign in again on the computer.'
                        : null,
                  )) {
                    (null, null) => null,
                    (final email?, null) => Text(email),
                    (null, final note?) => Text(note),
                    (final email?, final note?) => Text('$email\n$note'),
                  },
                ),
              if (_syncOn)
                SwitchListTile(
                  title: const Text('Also turn on Sync between devices'),
                  subtitle: const Text(
                    'Blocked senders, Screener decisions and more stay the same '
                    'on both.',
                  ),
                  value: _withSync,
                  onChanged: (on) => setState(() => _withSync = on),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    'Tip: Sync between devices (in Settings) keeps blocked '
                    'senders, Screener decisions and more the same on your phone '
                    'and computer.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: count == 0 ? null : _send,
              child: Text(
                _asFile
                    ? 'Share the file'
                    : count == 1
                    ? 'Send 1 account'
                    : 'Send $count accounts',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sent(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'Sent to ${_computerName ?? 'your computer'}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      for (final r in _results) ResultTile(result: r),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Done'),
      ),
    ],
  );

  Widget _shared(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Icon(
        AppIcons.pairingFile,
        size: 40,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(height: 12),
      Text(
        'Open this file on your computer while its QR code is still showing.',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      const Text(
        'On the computer, choose Open a file from your phone. The file can\'t '
        'be opened anywhere else, and stops working when the code on the '
        'computer is closed or expires (after 15 minutes).',
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Done'),
      ),
    ],
  );
}

/// How one account went, on either device.
final class ResultTile extends StatelessWidget {
  const ResultTile({super.key, required this.result, this.trailing});

  final TransferResult result;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (result.outcome) {
      TransferOutcome.added => (AppIcons.success, colors.primary, 'Added'),
      TransferOutcome.alreadyThere => (
        AppIcons.success,
        colors.onSurfaceVariant,
        'Already on the computer',
      ),
      TransferOutcome.signInOnComputer => (
        AppIcons.signIn,
        colors.tertiary,
        'Sign in on the computer to finish',
      ),
      TransferOutcome.failed => (
        AppIcons.problem,
        colors.error,
        result.detail ?? 'Couldn\'t be added',
      ),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(result.email),
      subtitle: Text(text),
      trailing: trailing,
    );
  }
}

final class _Busy extends StatelessWidget {
  const _Busy(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(text),
      ],
    ),
  );
}
