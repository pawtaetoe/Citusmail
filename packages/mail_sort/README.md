# mail_sort

Sorts mail into **General**, **Newsletters** and **Notifications**. Pure
Dart, entirely on the device: it looks only at the sender, a few headers
and the folder, never at the body, and sends nothing anywhere.

## Categories

Every message gets one category from header rules. Sorting is always
automatic; users group mail their own way with custom folders: rules that
move new inbox mail into real folders on the server (`FolderRuleApplier`
in mail_sync).

The first rule that matches decides ([HeaderRuleClassifier](lib/src/header_rule_classifier.dart)):

| # | Rule | Category | Why it is here |
| - | ---- | -------- | -------------- |
| 1 | In Sent or Drafts | General | The user's own mail |
| 2 | Known service (GitHub, GitLab, Jira...) | Notifications | These send every notification with list headers |
| 3 | `Auto-Submitted: auto-replied` | General | Out-of-office replies and bounces answer the user's own mail |
| 4 | One-click unsubscribe (RFC 8058) | Newsletters | Required for bulk and marketing mail, so it beats a `noreply` sender |
| 5 | `noreply`-style sender, `Auto-Submitted: auto-generated` | Notifications | Banks, shops, delivery firms, password resets |
| 6 | `List-Id` or `List-Unsubscribe` | Newsletters | Newsletters and mailing lists |
| 7 | `Precedence: bulk`, `list` or `junk` | Newsletters | Mass mail without list headers |
| - | Anything else | General | |

Sorting is not a security decision. A From address can be forged, so a
known-service match only picks the folder and never makes a message more
trusted. Phishing checks are separate (M2).

## Smart Inbox sections

The store places every inbox message in one section, the first that
applies (`SmartSection` in mail_store):

1. **Pinned**: flagged (shown as a star in other mail apps).
2. **Newsletters** and **Notifications**: by category.
3. **Important**: General mail from someone the user has written to, a
   reply to the user's own mail, or mail the server marks important
   (`$Important` keyword or the `\Important` folder).
4. **General**: everything else.

Pinned and Important are worked out when listing, so they follow pins and
new conversations at once.

## Re-sorting

When the rules change, `HeaderRuleClassifier.currentVersion` is bumped and
[Resorter](lib/src/resorter.dart) re-sorts stored mail from its stored
headers at the next start, in small batches. It also sorts mail stored by
versions from before sorting existed.

```bash
dart test
```
