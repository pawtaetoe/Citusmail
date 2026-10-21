# mail_sort

Sorts mail into **People**, **Newsletters** and **Notifications**. Pure
Dart, entirely on the device: it looks only at the sender, a few headers
and the folder, never at the body, and sends nothing anywhere.

## Header rules

The first rule that matches decides ([HeaderRuleClassifier](lib/src/header_rule_classifier.dart)):

| # | Rule | Category | Why it is here |
| - | ---- | -------- | -------------- |
| 1 | In Sent or Drafts | People | The user's own mail |
| 2 | Known service (GitHub, GitLab, Jira...) | Notifications | These send every notification with list headers |
| 3 | `Auto-Submitted: auto-replied` | People | Out-of-office replies and bounces answer the user's own mail |
| 4 | One-click unsubscribe (RFC 8058) | Newsletters | Required for bulk and marketing mail, so it beats a `noreply` sender |
| 5 | `noreply`-style sender, `Auto-Submitted: auto-generated` | Notifications | Banks, shops, delivery firms, password resets |
| 6 | `List-Id` or `List-Unsubscribe` | Newsletters | Newsletters and mailing lists |
| 7 | `Precedence: bulk`, `list` or `junk` | Newsletters | Mass mail without list headers |
| - | Anything else | People | |

Sorting is not a security decision. A From address can be forged, so a
known-service match only picks the folder and never makes a message more
trusted. Phishing checks are separate (M2).

## Teaching the sorter

"Move to ..." ([CategoryCorrections](lib/src/category_corrections.dart))
is remembered:

- for a **mailing list** (by `List-Id`) when the message came through one,
  so it covers everyone who posts to the list;
- otherwise for the **sender** address.

Earlier and later messages follow the choice, ahead of every rule, until it
is undone. The store keeps the automatic decision next to the shown
category, so undoing needs no download. Choices stay on this device until
app data sync between devices (M3).

## Re-sorting

When the rules change, `HeaderRuleClassifier.currentVersion` is bumped and
[Resorter](lib/src/resorter.dart) re-sorts stored mail from its stored
headers at the next start, in small batches. It also sorts mail stored by
versions from before sorting existed.

```bash
dart test
```
