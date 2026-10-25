# mail_sort

Sorts mail into **General**, **Codes**, **Newsletters** and
**Notifications**. Pure Dart, entirely on the device: it looks only at the
sender, a few headers, the subject, the server's short preview (if it
sends one) and the folder, never at the body, and sends nothing anywhere.

## Categories

Every message gets one category from header rules. Sorting is always
automatic; users group mail their own way with custom folders: rules that
move new inbox mail into real folders on the server (`FolderRuleApplier`
in mail_sync).

The first rule that matches decides ([HeaderRuleClassifier](lib/src/header_rule_classifier.dart)):

| # | Rule | Category | Why it is here |
| - | ---- | -------- | -------------- |
| 1 | In Sent or Drafts | General | The user's own mail |
| 2 | Read receipt (RFC 8098 report) | Notifications | About the user's own mail |
| 3 | Verification code, sign-in link or password reset, from the subject or a code next to a keyword in the preview; not replies, forwards, automatic replies or promotions | Codes | Wanted right away, and easy to lose among notifications |
| 4 | Known service (GitHub, GitLab, Jira...) | Notifications | These send every notification with list headers |
| 5 | `Auto-Submitted: auto-replied` | General | Out-of-office replies and bounces answer the user's own mail |
| 6 | One-click unsubscribe (RFC 8058) | Newsletters | Required for bulk and marketing mail, so it beats a `noreply` sender |
| 7 | `noreply`-style sender, `Auto-Submitted: auto-generated` | Notifications | Banks, shops, delivery firms |
| 8 | `List-Id` or `List-Unsubscribe` | Newsletters | Newsletters and mailing lists |
| 9 | `Precedence: bulk`, `list` or `junk` | Newsletters | Mass mail without list headers |
| - | Anything else | General | |

Sorting is not a security decision. A From address can be forged, so a
known-service match only picks the folder and never makes a message more
trusted. Phishing checks are separate (M2).

### Codes

[VerificationCodes](lib/src/verification_codes.dart) also finds the code
itself: 4 to 8 digits (`123456`, `123 456`, `G-123456`) or 5 to 10
capitals and digits (`F7K2P`), with a keyword such as "code", "OTP" or
"password" close by, and never part of an amount, time, phone number or
address. When the subject promises a code ("Your login code"), the first
code of 6 or more characters counts without a keyword. Sync stores it
with the message (from the subject or preview, or, for fresh Codes mail
on servers without previews, from the body: `CodeReader` in mail_sync),
and the list shows it in place of the preview.

The learned sorting never sorts by sender into Codes: a code is known from
each message itself.

## Smart Inbox sections

The store places every inbox message in one section, the first that
applies (`SmartSection` in mail_store):

1. **Pinned**: flagged (shown as a star in other mail apps).
2. **Codes** (shown as Verification), **Newsletters** and
   **Notifications**: by category.
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
