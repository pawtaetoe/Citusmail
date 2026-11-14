// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mail_pairing/mail_pairing.dart';

import '../app.dart' show appName;
import '../services/app_services.dart';
import '../setup/new_setup.dart';
import '../setup/setup_controller.dart';
import '../setup/setup_page.dart';
import '../ui/app_icons.dart';
import 'account_export.dart';
import 'account_import.dart';
import 'qr_code.dart';
import 'send_accounts_page.dart' show ResultTile;

/// Starts the computer's side with [receive] (tests replace it).
typedef PairingHostStarter = Future<PairingHost> Function(
  AccountReceiver receive,
);

/// Asks the user for a file from the phone (tests replace it).
typedef PairingFilePicker = Future<Uint8List?> Function();

Future<Uint8List?> _pickFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: '$appName accounts',
        extensions: [PairingFile.extension],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > PairingFile.maxLength) return Uint8List(0);
  return file.readAsBytes();
}

/// "Add accounts from your phone" (the computer's side): shows a one-time
/// QR code; the phone scans it and sends the accounts over the local
/// network, or as a sealed file. Each account is checked with a real
/// sign-in before it is saved. Pops with true when accounts were added.
final class ReceiveAccountsPage extends StatefulWidget {
  const ReceiveAccountsPage({
    super.key,
    required this.services,
    this.startHost,
    this.pickFile = _pickFile,
    this.importer,
    this.newSetup,
  });

  /// Where the page is offered: computers (the phone sends).
  static bool get supported => Platform.isLinux || Platform.isWindows;

  final AppServices services;
  final PairingHostStarter? startHost;
  final PairingFilePicker pickFile;

  /// Adds the accounts (tests give one with fake sign-ins).
  final AccountImport Function()? importer;

  /// A sign-in flow for accounts the computer signs in to itself.
  final SetupController Function()? newSetup;

  @override
  State<ReceiveAccountsPage> createState() => _ReceiveAccountsPageState();
}

final class _ReceiveAccountsPageState extends State<ReceiveAccountsPage> {
  PairingHost? _host;
  PairingHostState? _state;
  StreamSubscription<PairingHostState>? _changes;
  late AccountImport _import;
  String? _startProblem;
  String? _fileProblem;
  bool _added = false;
  final _signedIn = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_host?.close());
    super.dispose();
  }

  Future<void> _start() async {
    await _changes?.cancel();
    await _host?.close();
    _import = widget.importer?.call() ?? AccountImport(widget.services);
    try {
      final host = await (widget.startHost ?? _defaultStart)(_receive);
      if (!mounted) {
        await host.close();
        return;
      }
      setState(() {
        _host = host;
        _state = host.state;
        _startProblem = null;
        _fileProblem = null;
      });
      _changes = host.changes.listen((state) {
        if (mounted) setState(() => _state = state);
      });
    } on SocketException catch (e) {
      if (mounted) {
        setState(() => _startProblem = 'Couldn\'t start: ${e.message}');
      }
    }
  }

  Future<PairingHost> _defaultStart(AccountReceiver receive) =>
      PairingHost.start(
        computerName: Platform.localHostname,
        clients: builtInClients(),
        receive: receive,
      );

  Future<List<TransferResult>> _receive(AccountTransfer transfer) async {
    final results = await _import.receive(transfer);
    if (results.any((r) => r.outcome == TransferOutcome.added)) _added = true;
    return results;
  }

  Future<void> _openFile() async {
    final host = _host;
    if (host == null) return;
    final bytes = await widget.pickFile();
    if (bytes == null || !mounted) return;
    try {
      setState(() => _fileProblem = null);
      await host.openFile(bytes);
    } on PairingFileException catch (e) {
      if (!mounted) return;
      setState(
        () => _fileProblem = switch (e.problem) {
          PairingFileProblem.notAFile =>
            'That isn\'t a $appName accounts file.',
          PairingFileProblem.otherCode =>
            'That file was made for another code. Scan this code with your '
                'phone and send a new file.',
          PairingFileProblem.damaged =>
            'That file is damaged or was changed. Send a new one from your '
                'phone.',
          PairingFileProblem.expired =>
            'This code can\'t take a file any more. Show a new code and send a '
                'new file from your phone.',
        },
      );
    }
  }

  /// Signs in to [need] here: the provider's page opens in the browser,
  /// as in normal setup.
  Future<void> _signIn(SignInNeeded need) async {
    final controller =
        (widget.newSetup ?? () => newSetupController(widget.services))();
    var done = false;
    final route = Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SetupPage(
          controller: controller,
          onDone: (_) {
            done = true;
            Navigator.of(context).pop();
          },
          onCancel: () => Navigator.of(context).pop(),
        ),
      ),
    );
    unawaited(
      controller.signInWithAny(
        need.provider,
        email: need.email,
        displayName: need.displayName,
      ),
    );
    await route;
    if (done && mounted) {
      setState(() {
        _added = true;
        _signedIn.add(need.email);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.of(context).pop(_added);
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Add accounts from your phone')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _body(context),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    if (_startProblem case final problem?) {
      return _Message(
        text: problem,
        action: FilledButton(onPressed: _start, child: const Text('Try again')),
      );
    }
    final host = _host;
    final state = _state;
    if (host == null || state == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final newCode = FilledButton(
      onPressed: _start,
      child: const Text('Show a new code'),
    );
    return switch (state) {
      HostWaiting(:final listening) => _waiting(context, host, listening),
      HostConnected(:final checkCode, :final phoneName) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connected to $phoneName', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('Check that your phone shows the same code:'),
          const SizedBox(height: 8),
          Text(
            checkCode,
            key: const Key('check-code'),
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Choose the accounts on your phone and send them. If the codes '
            'differ, close this page: something else connected.',
          ),
        ],
      ),
      HostReceiving(:final count) => _Message(
        busy: true,
        text: count == 1
            ? 'Adding 1 account and checking that it signs in…'
            : 'Adding $count accounts and checking that they sign in…',
      ),
      HostFinished(:final results) => _finished(context, results),
      HostFailed(:final problem) => _Message(
        text: switch (problem) {
          HostProblem.cancelled => 'Cancelled on your phone.',
          HostProblem.connectionLost =>
            'The connection to your phone broke off. Accounts that were '
                'already added stay.',
          HostProblem.tooManyTries =>
            'Too many devices tried a wrong code, so this code was closed.',
        },
        action: newCode,
      ),
      HostExpired() => _Message(
        text: 'The code expired. Nothing was received.',
        action: newCode,
      ),
    };
  }

  Widget _waiting(BuildContext context, PairingHost host, bool listening) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final until = TimeOfDay.fromDateTime(
      listening ? host.networkUntil : host.fileUntil,
    ).format(context);
    final instructions = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Open $appName on your phone → Settings → Send accounts to a '
          'computer, and scan this code.',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (!host.offer.reachable)
          const Text(
            'This computer isn\'t on a local network, so your phone can\'t '
            'connect to it. Your phone can send a file instead.',
          )
        else if (listening)
          Text(
            'Both need to be on the same Wi-Fi. Your phone sends the accounts '
            'straight to this computer, encrypted; nothing goes through the '
            'internet. The code works once, until $until.',
          )
        else
          Text(
            'The code no longer connects over Wi-Fi. A file from your phone '
            'can still be opened until $until.',
          ),
        if (Platform.isWindows && listening) ...[
          const SizedBox(height: 8),
          Text(
            'If Windows asks whether $appName may use your network, allow it '
            'on private networks.',
            style: muted,
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final qr = QrCodeView(
              key: const Key('pairing-qr'),
              data: host.offer.encode(),
              size: box.maxWidth < 420 ? box.maxWidth.clamp(160, 260) : 240,
            );
            if (box.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: qr),
                  const SizedBox(height: 20),
                  instructions,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                qr,
                const SizedBox(width: 24),
                Expanded(child: instructions),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        Text('Phone couldn\'t connect?', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Your phone can send the accounts as a file instead. Only this '
          'computer can open it, while this code is showing (until '
          '${TimeOfDay.fromDateTime(host.fileUntil).format(context)}).',
          style: muted,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _openFile,
            icon: const Icon(AppIcons.openFile),
            label: const Text('Open a file from your phone'),
          ),
        ),
        if (_fileProblem case final problem?) ...[
          const SizedBox(height: 8),
          Text(problem, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (!listening) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _start,
              child: const Text('Show a new code'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _finished(BuildContext context, List<TransferResult> results) {
    final theme = Theme.of(context);
    final needs = {for (final n in _import.signInNeeded) n.email: n};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('From your phone', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final r in results)
          if (_signedIn.contains(r.email))
            ResultTile(result: TransferResult(r.email, TransferOutcome.added))
          else
            ResultTile(
              result: r,
              trailing: switch (needs[r.email]) {
                final need? => FilledButton.tonal(
                  onPressed: () => _signIn(need),
                  child: Text('Sign in with ${need.provider.name}'),
                ),
                null => null,
              },
            ),
        if (_import.syncTurnedOn) ...[
          const SizedBox(height: 8),
          const Text(
            'Sync between devices is on here too. Your blocked senders and '
            'other choices arrive with the next check for mail.',
          ),
        ],
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(_added),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

final class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.busy = false});

  final String text;
  final Widget? action;
  final bool busy;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (busy) ...[
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
      ],
      Text(text, textAlign: TextAlign.center),
      if (action case final action?) ...[const SizedBox(height: 16), action],
    ],
  );
}
