// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'mail_text.dart';

/// Asks for a folder name and creates the folder on the server.
abstract final class NewFolderDialog {
  static Future<void> show(
    BuildContext context,
    MailController controller,
    int accountId,
  ) => showDialog<void>(
    context: context,
    builder: (_) => _NewFolder(controller: controller, accountId: accountId),
  );
}

final class _NewFolder extends StatefulWidget {
  const _NewFolder({required this.controller, required this.accountId});

  final MailController controller;
  final int accountId;

  @override
  State<_NewFolder> createState() => _NewFolderState();
}

final class _NewFolderState extends State<_NewFolder> {
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.controller.createFolder(
      widget.accountId,
      _name.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New folder'),
    content: TextField(
      controller: _name,
      autofocus: true,
      enabled: !_busy,
      onSubmitted: (_) => _create(),
      decoration: InputDecoration(
        labelText: 'Name',
        helperText: 'Use / for a folder inside another, like Projects/2026.',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: _busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Create'),
      ),
    ],
  );
}

/// The rules that file new mail into one folder.
abstract final class FolderRulesDialog {
  static Future<void> show(
    BuildContext context,
    MailController controller,
    StoredMailbox mailbox,
  ) => showDialog<void>(
    context: context,
    builder: (_) => _Rules(controller: controller, mailbox: mailbox),
  );

  static String describe(RuleField field, String value) => switch (field) {
    RuleField.fromAddress => 'From $value',
    RuleField.fromDomain => 'From anyone at $value',
    RuleField.toAddress => 'Sent to $value',
    RuleField.subject => 'Subject contains "$value"',
  };
}

final class _Rules extends StatefulWidget {
  const _Rules({required this.controller, required this.mailbox});

  final MailController controller;
  final StoredMailbox mailbox;

  @override
  State<_Rules> createState() => _RulesState();
}

final class _RulesState extends State<_Rules> {
  final _value = TextEditingController();
  RuleField _field = RuleField.fromAddress;
  bool _existing = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _add() {
    final error = widget.controller.addRule(
      widget.mailbox,
      _field,
      _value.text,
      includeExisting: _existing,
    );
    setState(() {
      _error = error;
      if (error == null) {
        _value.clear();
        _existing = false;
      }
    });
  }

  static String _fieldLabel(RuleField field) => switch (field) {
    RuleField.fromAddress => 'From address',
    RuleField.fromDomain => 'From domain',
    RuleField.toAddress => 'Sent to address',
    RuleField.subject => 'Subject contains',
  };

  @override
  Widget build(BuildContext context) {
    final rules = widget.controller.rulesFor(widget.mailbox.id);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Rules for ${MailText.folder(widget.mailbox)}'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New mail in your inbox that matches any of these moves here, '
              'on the server, so every device sees it.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (rules.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No rules yet.'),
              ),
            for (final rule in rules)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.filter_alt_outlined),
                title: Text(FolderRulesDialog.describe(rule.field, rule.value)),
                trailing: IconButton(
                  tooltip: 'Remove rule',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      setState(() => widget.controller.removeRule(rule)),
                ),
              ),
            const Divider(height: 24),
            Row(
              children: [
                DropdownButton<RuleField>(
                  value: _field,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final field in RuleField.values)
                      DropdownMenuItem(
                        value: field,
                        child: Text(_fieldLabel(field)),
                      ),
                  ],
                  onChanged: (field) =>
                      setState(() => _field = field ?? _field),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _value,
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: switch (_field) {
                        RuleField.fromAddress => 'orders@shop.example',
                        RuleField.fromDomain => 'shop.example',
                        RuleField.toAddress => 'me+shopping@example.com',
                        RuleField.subject => 'Invoice',
                      },
                      errorText: _error,
                    ),
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _existing,
              onChanged: (v) => setState(() => _existing = v ?? false),
              title: const Text('Also move matching mail already in the inbox'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _add, child: const Text('Add rule')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
