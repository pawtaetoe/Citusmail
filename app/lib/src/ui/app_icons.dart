// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// The app's icon vocabulary, in one place: outlined glyphs everywhere,
/// a filled one only for something that is on (a pin that is set, a
/// receipt asked for). Pages name what they mean ([archive], [snooze])
/// rather than picking a glyph.
abstract final class AppIcons {
  // Places.
  static const inbox = Icons.inbox_outlined;
  static const pins = Icons.push_pin_outlined;
  static const outbox = Icons.outbox_outlined;
  static const snoozed = Icons.snooze_outlined;
  static const waiting = Icons.hourglass_empty;
  static const noReply = Icons.hourglass_bottom;
  static const screener = Icons.how_to_reg_outlined;
  static const sent = Icons.send_outlined;
  static const mail = Icons.mail_outline;
  static const subscriptions = Icons.autorenew;
  static const deliveries = Icons.local_shipping_outlined;
  static const trips = Icons.luggage_outlined;
  static const appointments = Icons.event_available_outlined;
  static const onlineAccounts = Icons.badge_outlined;
  static const cleanUp = Icons.cleaning_services_outlined;
  static const privacyReport = Icons.shield_outlined;

  // What can be done with a message.
  static const archive = Icons.archive_outlined;
  static const delete = Icons.delete_outline;
  static const deleteForever = Icons.delete_forever_outlined;
  static const move = Icons.drive_file_move_outline;
  static const snooze = Icons.snooze_outlined;
  static const unsnooze = Icons.alarm_off_outlined;
  static const remind = Icons.alarm_add_outlined;
  static const remindOn = Icons.alarm_on;
  static const remindOff = Icons.alarm_off_outlined;
  static const reminder = Icons.alarm_outlined;
  static const pinOff = Icons.push_pin_outlined;
  static const pinOn = Icons.push_pin;
  static const markRead = Icons.mark_email_read_outlined;
  static const markUnread = Icons.mark_email_unread_outlined;
  static const markAllRead = Icons.done_all;
  static const block = Icons.block_outlined;
  static const unblock = Icons.how_to_reg_outlined;
  static const forwardAsAttachment = Icons.forward_to_inbox_outlined;
  static const save = Icons.download_outlined;
  static const original = Icons.data_object;
  static const reply = Icons.reply;
  static const replyAll = Icons.reply_all;
  static const forward = Icons.forward;
  static const attachment = Icons.attach_file;
  static const receipt = Icons.mark_email_read_outlined;
  static const receiptOn = Icons.mark_email_read;

  // Writing.
  static const compose = Icons.edit_outlined;
  static const send = Icons.send;
  static const sendLater = Icons.schedule_send;

  // Around the app.
  static const search = Icons.search;
  static const searchOff = Icons.search_off;
  static const settings = Icons.settings_outlined;
  static const help = Icons.help_outline;
  static const lock = Icons.lock_outline;
  static const sync = Icons.sync;
  static const menu = Icons.menu;
  static const more = Icons.more_vert;
  static const moreHorizontal = Icons.more_horiz;
  static const close = Icons.close;
  static const back = Icons.arrow_back;
  static const expand = Icons.expand_more;
  static const chevron = Icons.chevron_right;
  static const addAccount = Icons.person_add_alt;
  static const folderRules = Icons.filter_alt_outlined;
  static const offline = Icons.cloud_off_outlined;
  static const problem = Icons.error_outline;
  static const retry = Icons.refresh;
}
