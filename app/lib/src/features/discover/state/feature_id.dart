// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Every feature the app describes ("All features", "What's new", the
/// tips), by a stable id: the value's [name] ("commandBar"), which never
/// changes once released.
enum FeatureId {
  subscriptions,
  deliveries,
  trips,
  appointments,
  events,
  onlineAccounts,
  cleanUp,
  privacyReport,
  files,
  commandBar,
  aiAssistant,
  aiTranslate,
  askMail,
  screener,
  newSinceAway,
  summaryLine,
  peek,
  snooze,
  pins,
  calendar,
  unsubscribe,
  aiTidy,
  codes,
  aiSorting,
  sendLater,
  writingHints,
  followUps,
  readReceipt,
  writeWithAi,
  signOffs,
  aiQuickReplies,
  images,
  block,
  appLock,
  scamWarnings,
  notifications,
  instantMail,
  codeTile,
  pairing,
  deviceSync;

  /// The feature named [id] (from outside: a link, an older version),
  /// or null for one this version doesn't know.
  static FeatureId? parse(String id) => _byName[id];

  static final _byName = FeatureId.values.asNameMap();
}
