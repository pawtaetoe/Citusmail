// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_lock.dart';

/// Dialogs for choosing and confirming the PIN.
abstract final class PinDialogs {
  /// Asks for a new PIN twice; returns it, or null if cancelled.
  static Future<String?> choose(BuildContext context, {String? title}) =>
      showDialog<String>(
        context: context,
        builder: (_) => _ChoosePinDialog(title: title ?? 'Choose a PIN'),
      );

  /// Asks for the current PIN and runs [check] with it (verify, or turn
  /// the lock off); true once it was right.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required Future<UnlockResult> Function(String pin) check,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => _ConfirmPinDialog(title: title, check: check),
      ) ??
      false;
}

TextField _pinField(
  TextEditingController controller, {
  required String label,
  String? error,
  bool autofocus = false,
  bool enabled = true,
  ValueChanged<String>? onSubmitted,
}) => TextField(
  controller: controller,
  autofocus: autofocus,
  enabled: enabled,
  obscureText: true,
  keyboardType: TextInputType.number,
  maxLength: AppLock.maxLength,
  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
  enableSuggestions: false,
  autocorrect: false,
  decoration: InputDecoration(
    labelText: label,
    errorText: error,
    counterText: '',
  ),
  onSubmitted: onSubmitted,
);

final class _ChoosePinDialog extends StatefulWidget {
  const _ChoosePinDialog({required this.title});

  final String title;

  @override
  State<_ChoosePinDialog> createState() => _ChoosePinDialogState();
}

final class _ChoosePinDialogState extends State<_ChoosePinDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _firstError;
  String? _secondError;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _save() {
    final pin = _first.text;
    setState(() {
      _firstError = AppLock.isValidPin(pin)
          ? null
          : 'Use ${AppLock.minLength} to ${AppLock.maxLength} digits.';
      _secondError = _firstError == null && _second.text != pin
          ? 'The PINs don\'t match.'
          : null;
    });
    if (_firstError == null && _secondError == null) {
      Navigator.pop(context, pin);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'You\'ll need it to open the app. If you forget it, the only way '
            'back in is to reset the app and add your accounts again.',
          ),
          const SizedBox(height: 8),
          _pinField(
            _first,
            label: 'New PIN',
            error: _firstError,
            autofocus: true,
          ),
          _pinField(
            _second,
            label: 'Repeat the PIN',
            error: _secondError,
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

final class _ConfirmPinDialog extends StatefulWidget {
  const _ConfirmPinDialog({required this.title, required this.check});

  final String title;
  final Future<UnlockResult> Function(String pin) check;

  @override
  State<_ConfirmPinDialog> createState() => _ConfirmPinDialogState();
}

final class _ConfirmPinDialogState extends State<_ConfirmPinDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() => _busy = true);
    final result = await widget.check(_pin.text);
    if (!mounted) return;
    if (result is Unlocked) {
      Navigator.pop(context, true);
      return;
    }
    _pin.clear();
    setState(() {
      _busy = false;
      _error = switch (result) {
        MustWait(:final wait) || WrongPin(:final wait)
            when wait > Duration.zero =>
          'Too many wrong PINs. Try again in ${wait.inMinutes > 0 ? '${wait.inMinutes} min' : '${wait.inSeconds} s'}.',
        _ => 'Wrong PIN.',
      };
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _pinField(
        _pin,
        label: 'Current PIN',
        error: _error,
        autofocus: true,
        enabled: !_busy,
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: const Text('Continue'),
      ),
    ],
  );
}
