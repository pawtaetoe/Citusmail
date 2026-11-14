// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// The app's icon vocabulary, in one place: outlined glyphs everywhere,
/// a filled one only for something that is on (a pin that is set, a
/// receipt asked for, an answer given). Pages name what they mean
/// ([archive], [snooze]) rather than picking a glyph, and one concept has
/// one icon wherever it shows. `app_icons_test.dart` keeps pages from
/// using `Icons.` directly.
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
  static const allFeatures = Icons.explore_outlined;
  static const screenedSenders = Icons.rule;
  static const signOff = Icons.draw_outlined;

  // Mail folders and Smart Inbox sections.
  static const drafts = Icons.edit_note;
  static const junk = Icons.report_gmailerrorred;
  static const allMail = Icons.all_inbox_outlined;
  static const starred = Icons.star_outline;
  static const important = Icons.label_important_outline;
  static const folder = Icons.folder_outlined;
  static const codes = Icons.password;
  static const notifications = Icons.notifications_outlined;
  static const newsletters = Icons.rss_feed;
  static const newSinceAway = Icons.waving_hand_outlined;

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
  static const notSpam = Icons.report_off_outlined;
  static const truncated = Icons.content_cut;
  static const unsubscribe = Icons.unsubscribe_outlined;
  static const allowDomain = Icons.domain_verification_outlined;
  static const blockDomain = Icons.domain_disabled_outlined;
  static const blockSender = Icons.person_off_outlined;
  static const copy = Icons.copy;
  static const selectAll = Icons.select_all;
  static const notNeeded = Icons.do_not_disturb_on_outlined;

  // Writing.
  static const compose = Icons.edit_outlined;
  static const send = Icons.send;
  static const sendLater = Icons.schedule_send;
  static const cancelSend = Icons.cancel_schedule_send_outlined;
  static const dropDown = Icons.arrow_drop_down;
  static const note = Icons.edit_note;

  // When: snooze, send later, follow-up reminders.
  static const time = Icons.schedule;
  static const morning = Icons.wb_sunny_outlined;
  static const tonight = Icons.nights_stay_outlined;
  static const weekend = Icons.weekend_outlined;
  static const week = Icons.date_range_outlined;
  static const oneDay = Icons.looks_one_outlined;
  static const threeDays = Icons.looks_3_outlined;
  static const pickTime = Icons.edit_calendar_outlined;

  // Calendar events and invitations.
  static const event = Icons.event_outlined;
  static const eventReply = Icons.event_available_outlined;
  static const eventCancelled = Icons.event_busy_outlined;
  static const eventChanged = Icons.update;
  static const addToCalendar = Icons.event_available_outlined;
  static const openInCalendar = Icons.edit_calendar_outlined;
  static const place = Icons.place_outlined;
  static const people = Icons.people_outline;
  static const videoCall = Icons.videocam_outlined;
  static const answerYes = Icons.check_circle_outline;
  static const answerMaybe = Icons.help_outline;
  static const answerNo = Icons.cancel_outlined;
  static const answeredYes = Icons.check_circle;
  static const answeredMaybe = Icons.help;
  static const answeredNo = Icons.cancel;

  // Found in your mail: deliveries, bills, accounts, appointments, trips.
  static const ordered = Icons.shopping_bag_outlined;
  static const pickup = Icons.storefront_outlined;
  static const outForDelivery = Icons.delivery_dining_outlined;
  static const delivered = Icons.check_circle_outline;
  static const returns = Icons.keyboard_return;
  static const bill = Icons.receipt_long_outlined;
  static const trial = Icons.hourglass_top;
  static const cancelled = Icons.cancel_outlined;
  static const priceUp = Icons.trending_up;
  static const priceDown = Icons.trending_down;
  static const signedUp = Icons.waving_hand_outlined;
  static const signInCode = Icons.pin_outlined;
  static const passwordReset = Icons.lock_reset;
  static const securityAlert = Icons.shield_outlined;
  static const accountChange = Icons.manage_accounts_outlined;
  static const accountClosed = Icons.no_accounts_outlined;
  static const health = Icons.medical_services_outlined;
  static const beauty = Icons.content_cut;
  static const carRepair = Icons.car_repair_outlined;
  static const homeRepair = Icons.home_repair_service_outlined;
  static const official = Icons.account_balance_outlined;
  static const interview = Icons.work_outline;
  static const school = Icons.school_outlined;
  static const lesson = Icons.self_improvement_outlined;
  static const flight = Icons.flight_outlined;
  static const stay = Icons.hotel_outlined;
  static const train = Icons.train_outlined;
  static const bus = Icons.directions_bus_outlined;
  static const car = Icons.directions_car_outlined;
  static const table = Icons.restaurant_outlined;
  static const ticket = Icons.confirmation_number_outlined;

  // Kinds of file.
  static const file = Icons.insert_drive_file_outlined;
  static const pdf = Icons.picture_as_pdf_outlined;
  static const image = Icons.image_outlined;
  static const document = Icons.description_outlined;
  static const spreadsheet = Icons.table_chart_outlined;
  static const zip = Icons.folder_zip_outlined;

  // Privacy and safety.
  static const privacy = Icons.shield_outlined;
  static const trackers = Icons.visibility_off_outlined;
  static const imagesBlocked = Icons.hide_image_outlined;
  static const trackingLinks = Icons.link_off;
  static const scam = Icons.gpp_maybe_outlined;
  static const untrusted = Icons.gpp_bad_outlined;
  static const safeBrowsing = Icons.travel_explore;
  static const virusTotal = Icons.policy_outlined;
  static const privacyPolicy = Icons.policy_outlined;
  static const showPassword = Icons.visibility_outlined;
  static const hidePassword = Icons.visibility_off_outlined;

  // Settings.
  static const account = Icons.alternate_email;
  static const keepMail = Icons.history;
  static const codeCleanup = Icons.auto_delete_outlined;
  static const learning = Icons.school_outlined;
  static const reset = Icons.restart_alt;
  static const appearance = Icons.palette_outlined;
  static const theme = Icons.dark_mode_outlined;
  static const server = Icons.dns_outlined;
  static const options = Icons.tune;
  static const backgroundChecks = Icons.schedule;
  static const instantMail = Icons.bolt_outlined;
  static const whatsNew = Icons.auto_awesome_outlined;
  static const tip = Icons.lightbulb_outline;
  static const info = Icons.info_outline;

  // Devices, pairing and sync.
  static const devices = Icons.devices_outlined;
  static const pairing = Icons.qr_code_2;
  static const scanCode = Icons.qr_code_scanner;
  static const pairingFile = Icons.file_present_outlined;
  static const openFile = Icons.file_open_outlined;
  static const signIn = Icons.login;
  static const signInWithBrowser = Icons.open_in_browser;
  static const noNetwork = Icons.wifi_off_outlined;
  static const turnOn = Icons.add_circle_outline;
  static const syncCode = Icons.vpn_key_outlined;
  static const syncProblem = Icons.sync_problem;
  static const syncOff = Icons.sync_disabled;

  // Around the app.
  static const search = Icons.search;
  static const searchOff = Icons.search_off;
  static const settings = Icons.settings_outlined;
  static const help = Icons.help_outline;
  static const lock = Icons.lock_outline;
  static const fingerprint = Icons.fingerprint;
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
  static const openExternal = Icons.open_in_new;
  static const hide = Icons.visibility_off_outlined;
  static const done = Icons.check;
  static const undo = Icons.undo;
  static const add = Icons.add;
  static const dragHandle = Icons.drag_handle;
  static const success = Icons.check_circle_outline;
  static const warning = Icons.warning_amber_rounded;
  static const downloading = Icons.downloading_outlined;
  static const person = Icons.person_outline;
}
