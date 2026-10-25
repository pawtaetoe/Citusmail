// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';

import '../ui/citusmail_theme.dart';
import 'compose_controller.dart';

/// "To", "Cc" or "Bcc": addresses as chips, typed text turned into
/// addresses on comma, Enter or leaving the field, with suggestions from
/// people the user has written to.
final class RecipientField extends StatefulWidget {
  const RecipientField({
    super.key,
    required this.label,
    required this.list,
    required this.suggest,
    this.trailing,
    this.autofocus = false,
  });

  final String label;
  final RecipientList list;
  final List<MailAddress> Function(String text) suggest;
  final Widget? trailing;
  final bool autofocus;

  @override
  State<RecipientField> createState() => _RecipientFieldState();
}

final class _RecipientFieldState extends State<RecipientField> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.text = widget.list.pending;
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    widget.list.pending = _text.text;
    if (widget.list.commit()) _text.clear();
  }

  void _onChanged(String value) {
    if (value.contains(RegExp(r'[,;]\s*$'))) {
      widget.list.pending = value.replaceAll(RegExp(r'[,;]\s*$'), '');
      if (widget.list.commit()) _text.clear();
    } else {
      widget.list.pending = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.list,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              child: Text(
                widget.label,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final address in widget.list.addresses)
                    InputChip(
                      label: Text(
                        address.displayName?.trim().isNotEmpty == true
                            ? address.displayName!
                            : address.address,
                      ),
                      tooltip: address.address,
                      onDeleted: () => widget.list.remove(address),
                      visualDensity: VisualDensity.compact,
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 160,
                      maxWidth: 520,
                    ),
                    child: RawAutocomplete<MailAddress>(
                      textEditingController: _text,
                      focusNode: _focus,
                      optionsBuilder: (value) => value.text.trim().length < 2
                          ? const []
                          : widget.suggest(value.text),
                      displayStringForOption: (a) => a.address,
                      onSelected: (address) {
                        widget.list
                          ..pending = ''
                          ..add(address);
                        _text.clear();
                      },
                      fieldViewBuilder:
                          (context, controller, focus, onSubmit) => TextField(
                            controller: controller,
                            focusNode: focus,
                            autofocus: widget.autofocus,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: _onChanged,
                            onSubmitted: (_) => _commit(),
                            decoration: CitusmailTheme.bareField(
                              isDense: true,
                              errorText: widget.list.invalid == null
                                  ? null
                                  : 'Not an email address',
                            ),
                          ),
                      optionsViewBuilder: (context, onSelected, options) =>
                          Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              elevation: 4,
                              borderRadius: BorderRadius.circular(8),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                  maxHeight: 260,
                                ),
                                child: ListView(
                                  shrinkWrap: true,
                                  children: [
                                    for (final option in options)
                                      ListTile(
                                        dense: true,
                                        title: Text(
                                          option.displayName ?? option.address,
                                        ),
                                        subtitle: option.displayName == null
                                            ? null
                                            : Text(option.address),
                                        onTap: () => onSelected(option),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                    ),
                  ),
                ],
              ),
            ),
            ?widget.trailing,
          ],
        ),
      ),
    );
  }
}
