// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Where one setting is in Settings: what the Settings search finds and
/// what `SettingsPage(show: ...)` opens at. Only these constants (and the
/// typed constructors for settings made per account or per AI feature)
/// make one, so a typo doesn't compile. [id] is stable: the command bar
/// keeps it in its recent commands.
extension type const SettingId._(String id) {
  /// The id for an account of the user's other than the first (the first
  /// is [accounts]).
  SettingId.account(int accountId) : id = 'account-$accountId';

  /// The id for an AI feature's own setting, by the feature's id
  /// ("summaries": [aiSummaries]).
  SettingId.aiFeature(String featureId) : id = 'ai-$featureId';

  // Notifications & checking mail.
  static const notifications = SettingId._('notifications');
  static const notifyServices = SettingId._('notifyServices');
  static const previews = SettingId._('previews');
  static const reminders = SettingId._('reminders');
  static const monthlyRenewals = SettingId._('monthlyRenewals');
  static const followUps = SettingId._('followUps');
  static const instantMail = SettingId._('instantMail');
  static const backgroundChecks = SettingId._('backgroundChecks');
  static const codeTile = SettingId._('codeTile');

  // Inbox & sorting.
  static const newSinceAway = SettingId._('newSinceAway');
  static const summaryLine = SettingId._('summaryLine');
  static const screener = SettingId._('screener');
  static const screenOutPlace = SettingId._('screenOutPlace');
  static const screenedSenders = SettingId._('screenedSenders');
  static const autoRead = SettingId._('autoRead');
  static const codeCleanup = SettingId._('codeCleanup');

  // Writing.
  static const signOffs = SettingId._('signOffs');
  static const writing = SettingId._('writing');
  static const writingHints = SettingId._('writingHints');

  // Accounts.
  static const accounts = SettingId._('accounts');
  static const addAccount = SettingId._('addAccount');
  static const keepMail = SettingId._('keepMail');

  // Privacy & security.
  static const appLock = SettingId._('appLock');
  static const lockAfter = SettingId._('lockAfter');
  static const biometrics = SettingId._('biometrics');
  static const changePin = SettingId._('changePin');
  static const images = SettingId._('images');
  static const blockedSenders = SettingId._('blockedSenders');

  // Devices & sync.
  static const deviceSync = SettingId._('deviceSync');
  static const pairing = SettingId._('pairing');

  // AI assistant.
  static const aiAssistant = SettingId._('aiAssistant');
  static const aiSummaries = SettingId._('ai-summaries');
  static const aiTranslate = SettingId._('ai-translate');
  static const aiQuickReplies = SettingId._('ai-quickReplies');
  static const aiAsk = SettingId._('ai-ask');
  static const aiLimit = SettingId._('aiLimit');
  static const aiWriting = SettingId._('ai-writing');
  static const aiActions = SettingId._('ai-actions');
  static const aiSorting = SettingId._('ai-sorting');

  // Appearance.
  static const theme = SettingId._('theme');

  // Help & about, and Advanced.
  static const discover = SettingId._('discover');
  static const commandBar = SettingId._('commandBar');
  static const whatsNew = SettingId._('whatsNew');
  static const tips = SettingId._('tips');
  static const privacy = SettingId._('privacy');
  static const privacyPolicy = SettingId._('privacyPolicy');
  static const terms = SettingId._('terms');
  static const licences = SettingId._('licences');
  static const safeBrowsing = SettingId._('safeBrowsing');
  static const virusTotal = SettingId._('virusTotal');
  static const serverRules = SettingId._('serverRules');
  static const learning = SettingId._('learning');

  /// Not a setting: the Settings search's "See all features".
  static const seeAllFeatures = SettingId._('@discover');

  /// Every constant above but [seeAllFeatures].
  static const all = [
    notifications,
    notifyServices,
    previews,
    reminders,
    monthlyRenewals,
    followUps,
    instantMail,
    backgroundChecks,
    codeTile,
    newSinceAway,
    summaryLine,
    screener,
    screenOutPlace,
    screenedSenders,
    autoRead,
    codeCleanup,
    signOffs,
    writing,
    writingHints,
    accounts,
    addAccount,
    keepMail,
    appLock,
    lockAfter,
    biometrics,
    changePin,
    images,
    blockedSenders,
    deviceSync,
    pairing,
    aiAssistant,
    aiSummaries,
    aiTranslate,
    aiQuickReplies,
    aiAsk,
    aiLimit,
    aiWriting,
    aiActions,
    aiSorting,
    theme,
    discover,
    commandBar,
    whatsNew,
    tips,
    privacy,
    privacyPolicy,
    terms,
    licences,
    safeBrowsing,
    virusTotal,
    serverRules,
    learning,
  ];

  /// The setting [id] names, from outside (the command bar's stored
  /// recent commands); null for one this version doesn't know.
  static SettingId? parse(String id) {
    for (final setting in all) {
      if (setting.id == id) return setting;
    }
    return null;
  }
}
