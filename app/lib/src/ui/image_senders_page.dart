// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../services/app_services.dart';

/// Settings > Images: the senders whose images load without asking.
final class ImageSendersPage extends StatefulWidget {
  const ImageSendersPage({super.key, required this.services});

  final AppServices services;

  @override
  State<ImageSendersPage> createState() => _ImageSendersPageState();
}

final class _ImageSendersPageState extends State<ImageSendersPage> {
  ImageSenderRepository get _senders => widget.services.store.imageSenders;

  @override
  Widget build(BuildContext context) {
    final senders = _senders.all();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Images')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Images are hidden until you load them, so senders can\'t see '
              'when you open their mail. Images from these senders load '
              'automatically, when your mail server confirms the mail is '
              'really from them. Tracking pixels are never loaded.',
              style: TextStyle(color: muted),
            ),
          ),
          if (senders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No senders yet. Choose "Always from this sender" on a message.',
                style: TextStyle(color: muted),
              ),
            ),
          for (final sender in senders)
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(sender.address),
              trailing: TextButton(
                onPressed: () {
                  _senders.remove(sender.id);
                  setState(() {});
                },
                child: const Text('Remove'),
              ),
            ),
        ],
      ),
    );
  }
}
