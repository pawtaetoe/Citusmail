// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../mail/attachments_model.dart';
import '../mail/mail_controller.dart';
import 'attachment_save_flow.dart';
import 'mail_text.dart';
import 'reader_pane.dart';
import 'trust_banner.dart';

/// Every file people sent, in one list: "that PDF from last month"
/// without remembering the email. Searchable by file name, sender or
/// subject; each file opens its email right here, or saves straight to
/// Downloads with the usual checks. Found on the device.
final class AttachmentsPage extends StatefulWidget {
  const AttachmentsPage({super.key, required this.controller});

  final MailController controller;

  /// Narrower than this, the search and filters sit at the bottom, within
  /// reach of the thumb.
  static const phoneWidth = 600.0;

  @override
  State<AttachmentsPage> createState() => _AttachmentsPageState();
}

final class _AttachmentsPageState extends State<AttachmentsPage> {
  late final AttachmentsModel _model = AttachmentsModel(
    widget.controller.services,
  );
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _saving = <String>{};
  Timer? _typing;

  @override
  void initState() {
    super.initState();
    _model.load();
    _scroll.addListener(_nearEnd);
  }

  @override
  void dispose() {
    _typing?.cancel();
    _scroll.dispose();
    _search.dispose();
    _model.dispose();
    super.dispose();
  }

  void _nearEnd() {
    if (_scroll.position.extentAfter < 800) _model.loadMore();
  }

  void _onSearch(String text) {
    _typing?.cancel();
    _typing = Timer(
      const Duration(milliseconds: 250),
      () => _model.search = text,
    );
    setState(() {}); // the clear button
  }

  void _clearSearch() {
    _typing?.cancel();
    _search.clear();
    _model.search = '';
    setState(() {});
  }

  /// The file's email, read in place; "Don't list this file" there comes
  /// back here, with Undo.
  Future<void> _open(LibraryFile f) async {
    final message = _model.message(f.message.id);
    if (message == null) return;
    final controller = widget.controller;
    await controller.open(message);
    if (!mounted) return;
    final hide = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _FileMessagePage(
          controller: controller,
          file: f,
          model: _model,
          onSave: _save,
        ),
      ),
    );
    // Back in the list: the mail screen behind shows no message.
    controller.closeMessage();
    if (hide == true && mounted) _hide(f);
  }

  void _hide(LibraryFile f) {
    _model.hide(f);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${f.file.name} won\'t be listed'),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unhide(f),
          ),
        ),
      );
  }

  /// Saves to Downloads, downloading the email first when it is not on
  /// the device (it stays unread). Risky files ask first.
  Future<void> _save(BuildContext context, LibraryFile f) async {
    if (_saving.contains(f.key)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving.add(f.key));
    Uint8List? bytes;
    try {
      bytes = await _model.content(f);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn\'t download this email. Check your connection and try again.',
          ),
        ),
      );
      return;
    } finally {
      if (mounted) setState(() => _saving.remove(f.key));
    }
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('${f.file.name} is no longer in this email.')),
      );
      return;
    }
    if (!context.mounted) return;
    final virusTotal = widget.controller.services.virusTotal;
    await AttachmentSaveFlow.save(
      context,
      fileName: f.file.name,
      bytes: () => bytes!,
      verdict: RiskyFiles.check(f.file.name),
      virusTotal: virusTotal.enabled ? virusTotal.file : null,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Attachments'),
      actions: [
        IconButton(
          tooltip: 'How is this found?',
          icon: const Icon(Icons.help_outline),
          onPressed: () => _HowDialog.show(context),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final phone = constraints.maxWidth < AttachmentsPage.phoneWidth;
          final controls = ListenableBuilder(
            listenable: _model,
            builder: (context, _) => _Controls(
              model: _model,
              search: _search,
              onSearch: _onSearch,
              onClear: _clearSearch,
              phone: phone,
            ),
          );
          final list = ListenableBuilder(
            listenable: _model,
            builder: (context, _) => _list(context),
          );
          return phone
              ? Column(
                  children: [
                    Expanded(child: list),
                    controls,
                  ],
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Column(
                      children: [
                        controls,
                        Expanded(child: list),
                      ],
                    ),
                  ),
                );
        },
      ),
    ),
  );

  Widget _list(BuildContext context) {
    final files = _model.files;
    final offer = switch (_model) {
      AttachmentsModel(lookingUp: final r?) => _LookingUp(
        done: r.done,
        total: r.total,
        onStop: _model.stopLookingUp,
      ),
      AttachmentsModel(:final unknown) when unknown.isNotEmpty => _LookUpOffer(
        count: unknown.length,
        failed: _model.lookupFailed,
        onLookUp: _model.lookUp,
      ),
      _ => null,
    };
    final searching =
        _model.search.trim().isNotEmpty ||
        _model.filter != FileFilter.all ||
        _model.peopleOnly;
    final head = [?offer];
    final tail = _model.loading || _model.loadingMore
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        : files.isEmpty
        ? _Empty(searching: searching)
        : const SizedBox(height: 24);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: head.length + files.length + 1,
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        final j = i - head.length;
        if (j == files.length) return tail;
        final f = files[j];
        return _FileTile(
          key: ValueKey(f.key),
          file: f,
          model: _model,
          saving: _saving.contains(f.key),
          onOpen: () => _open(f),
          onSave: () => _save(context, f),
        );
      },
    );
  }
}

/// The search field and the filter chips: at the top on wide screens, at
/// the bottom on phones.
final class _Controls extends StatelessWidget {
  const _Controls({
    required this.model,
    required this.search,
    required this.onSearch,
    required this.onClear,
    required this.phone,
  });

  final AttachmentsModel model;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback onClear;
  final bool phone;

  static const _labels = {
    FileFilter.all: 'All',
    FileFilter.pdfs: 'PDFs',
    FileFilter.images: 'Images',
    FileFilter.documents: 'Documents',
    FileFilter.spreadsheets: 'Spreadsheets',
    FileFilter.other: 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final field = TextField(
      controller: search,
      onChanged: onSearch,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search file names, senders or subjects',
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        suffixIcon: search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: onClear,
              ),
      ),
    );
    final chipList = [
      for (final f in FileFilter.values)
        ChoiceChip(
          label: Text(_labels[f]!),
          selected: model.filter == f,
          onSelected: (_) => model.filter = f,
        ),
      FilterChip(
        avatar: model.peopleOnly ? null : const Icon(Icons.person_outline),
        label: const Text('From people'),
        tooltip: 'Leave out newsletters and notifications',
        selected: model.peopleOnly,
        onSelected: (on) => model.peopleOnly = on,
      ),
    ];
    // Phones: one row that scrolls sideways; wider screens: they wrap.
    final Widget chips = phone
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final (i, chip) in chipList.indexed) ...[
                  if (i > 0) SizedBox(width: i == chipList.length - 1 ? 12 : 6),
                  chip,
                ],
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, runSpacing: 6, children: chipList),
          );
    final children = [
      Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 0), child: field),
      const SizedBox(height: 8),
      chips,
    ];
    return phone
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              // The chips just above the field, the field nearest the thumb.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: children.reversed.toList(),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          );
  }
}

/// One file: its kind (or a preview, for an image on the device), name,
/// size, who sent it and when, and the email's subject.
final class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.file,
    required this.model,
    required this.saving,
    required this.onOpen,
    required this.onSave,
  });

  final LibraryFile file;
  final AttachmentsModel model;
  final bool saving;
  final VoidCallback onOpen;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final m = file.message;
    final risky = RiskyFiles.check(file.file.name);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            FileThumbnail(file: file, model: model),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          file.file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (risky != null) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: risky.reason,
                          child: Icon(
                            TrustStyle.of(context, risky.level).icon,
                            size: 16,
                            color: TrustStyle.of(
                              context,
                              risky.level,
                            ).foreground,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${MailText.size(file.file.size)} · ${MailText.sender(m)} · '
                    '${MailText.listDate(context, m.receivedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                  Text(
                    MailText.subject(m),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (saving)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else
              IconButton(
                tooltip: file.downloaded ? 'Save to Downloads' : 'Save to Downloads (downloads the email; it stays unread)',
                icon: const Icon(Icons.download_outlined),
                onPressed: onSave,
              ),
          ],
        ),
      ),
    );
  }
}

/// A file's kind as a coloured icon, or a small preview of an image that
/// is already on the device (never fetched).
final class FileThumbnail extends StatefulWidget {
  const FileThumbnail({
    super.key,
    required this.file,
    required this.model,
    this.size = 48,
  });

  final LibraryFile file;
  final AttachmentsModel model;
  final double size;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

final class _FileThumbnailState extends State<FileThumbnail> {
  late Future<Uint8List?> _preview = widget.model.preview(widget.file);

  @override
  void didUpdateWidget(FileThumbnail old) {
    super.didUpdateWidget(old);
    if (old.file.key != widget.file.key) {
      _preview = widget.model.preview(widget.file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final kind = widget.file.kind;
    final (color, icon) = KindStyle.of(context, kind);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, color: color, size: size * 0.5),
      ),
    );
    return FutureBuilder(
      future: _preview,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return fallback;
        final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: pixels,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          ),
        );
      },
    );
  }
}

/// Colour and icon of each kind of file.
abstract final class KindStyle {
  static (Color, IconData) of(BuildContext context, FileKind kind) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color pick(int light, int night) => Color(dark ? night : light);
    return switch (kind) {
      FileKind.pdf => (
        pick(0xFFD0453A, 0xFFF08A80),
        Icons.picture_as_pdf_outlined,
      ),
      FileKind.image => (pick(0xFF8A55C0, 0xFFC4A0EA), Icons.image_outlined),
      FileKind.document => (
        pick(0xFF3F67C8, 0xFF8FAEF0),
        Icons.description_outlined,
      ),
      FileKind.spreadsheet => (
        pick(0xFF1F8A55, 0xFF7ED0A2),
        Icons.table_chart_outlined,
      ),
      FileKind.archive => (
        pick(0xFFA06A12, 0xFFE0B060),
        Icons.folder_zip_outlined,
      ),
      FileKind.calendar => (pick(0xFF00897B, 0xFF6CCFC2), Icons.event_outlined),
      FileKind.other => (
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.insert_drive_file_outlined,
      ),
    };
  }
}

final class _LookUpOffer extends StatelessWidget {
  const _LookUpOffer({
    required this.count,
    required this.failed,
    required this.onLookUp,
  });

  final int count;
  final bool failed;
  final VoidCallback onLookUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emails = count == 1
        ? '1 older email has'
        : '$count older emails have';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.attach_file),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '$emails files that aren\'t listed yet. Their names can be '
                    'asked from your mail server: nothing is downloaded, and '
                    'the emails stay unread.'
                    '${failed ? '\n\nYour mail server couldn\'t be reached. Try again later.' : ''}',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onLookUp,
                child: Text(failed ? 'Try again' : 'List their files'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _LookingUp extends StatelessWidget {
  const _LookingUp({
    required this.done,
    required this.total,
    required this.onStop,
  });

  final int done;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Listing files: $done of $total emails'),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onStop, child: const Text('Stop')),
        ],
      ),
    ),
  );
}

final class _Empty extends StatelessWidget {
  const _Empty({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(
            searching ? Icons.search_off : Icons.attach_file,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? 'No matching files' : 'No files yet',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            searching
                ? 'Try other words, or another filter.'
                : 'Files people send you show here: PDFs, photos, documents '
                      'and more, from every account.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

final class _HowDialog extends StatelessWidget {
  const _HowDialog();

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _HowDialog());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this found?'),
    content: const Text(
      'Citusmail lists the attachments of the emails on this device, from '
      'every account and folder except Trash, Junk and Drafts, newest first. '
      'Their names and sizes come with each email when it arrives, so '
      'nothing is downloaded to list them. Logos and pictures that are only '
      'part of an email\'s design are left out.\n\n'
      'Saving a file downloads its email if it isn\'t on this device yet (it '
      'stays unread). Files are never opened for you, and programs and '
      'other risky files ask first. Nothing is sent anywhere.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}

/// A file's email, read in place, with the file at the top: Save, or
/// "Don't list this file" (pops with true). Back returns to the list.
final class _FileMessagePage extends StatefulWidget {
  const _FileMessagePage({
    required this.controller,
    required this.file,
    required this.model,
    required this.onSave,
  });

  final MailController controller;
  final LibraryFile file;
  final AttachmentsModel model;
  final Future<void> Function(BuildContext context, LibraryFile file) onSave;

  @override
  State<_FileMessagePage> createState() => _FileMessagePageState();
}

final class _FileMessagePageState extends State<_FileMessagePage> {
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.controller.reader.addListener(_closedElsewhere);
  }

  @override
  void dispose() {
    widget.controller.reader.removeListener(_closedElsewhere);
    super.dispose();
  }

  /// Archived, deleted or closed from its own actions: back to the list.
  void _closedElsewhere() {
    if (widget.controller.reader.value.message == null &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(context, widget.file);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final f = widget.file;
    return Scaffold(
      appBar: AppBar(
        title: Text(f.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<void>(
            tooltip: 'More',
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: () => Navigator.pop(context, true),
                child: const Text('Don\'t list this file'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: colors.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(
                  children: [
                    FileThumbnail(file: f, model: widget.model, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            MailText.size(f.file.size),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ReaderPane(
                controller: widget.controller,
                toolbarAtBottom: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
