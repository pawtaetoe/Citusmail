# Citusmail Privacy Policy

Effective date: 10 November 2026

Citusmail is an email app published by **Fluminaris**. This policy explains
what the app does with your information. Questions or requests:
**kungchihchia@gmail.com**, or an issue at
<https://github.com/pawtaetoe/Citusmail/issues>.

## In short

- Citusmail has **no account with us and no server of ours**. We do not
  collect, receive, store, sell or share any of your data.
- No analytics, no crash reporting, no advertising, no advertising ID, no
  tracking.
- Your mail, contacts and settings stay **on your device, encrypted**, and
  travel only between your device and the services you use: your own mail
  provider, optional services you turn on yourself, and your own computer
  when you send it your accounts.

## The data the app handles

To work as an email app, Citusmail handles on your device:

| Data | Why | Where it goes |
| --- | --- | --- |
| Your email address, mail server settings, and password or sign-in token | To connect to your mail account | Only to your own mail provider (and its sign-in service, see below). Passwords and tokens are kept in your device's secure keychain |
| Your email messages, attachments, contacts and folders | To show, search, sort and send your mail | Downloaded from and sent through your own mail provider; stored encrypted on the device |
| App settings, blocked senders, Screener decisions, snoozed emails, folder rules, sign-offs | To remember your choices | On the device; optionally synced between your own devices, end-to-end encrypted (see below) |

None of this is sent to Fluminaris or to any third party other than the
services listed in the next section.

Features that understand your mail, such as sorting, finding verification
codes, phishing checks, the list of your paid subscriptions (found in
receipts and renewal emails), your deliveries (found in order and
shipping emails), your trips and appointments (found in booking
emails), run entirely on the device. The optional AI assistant is the
one exception you can choose: see below.

## Services the app connects to

| Service | When | What is sent |
| --- | --- | --- |
| Your mail provider (IMAP, SMTP) | Always, to read and send mail | Your login and your mail, over encrypted connections (TLS) |
| Google sign-in (Gmail) | Only if you add a Gmail account with "Sign in with Google" | Sign-in happens on Google's page in your browser; the app then receives a token to access your mail. Your password never passes through the app |
| Microsoft sign-in (Outlook, Microsoft 365) | Only if you add such an account | As for Google: sign-in on Microsoft's page, then a token for your mail |
| Your mail provider's setup service (your domain's own servers, or those of the mail host your domain's records point to), your DNS resolver | When you add an account | Your email address, over an encrypted connection, to your provider's own settings service (some providers need it to answer); your DNS resolver sees your domain only (and, when a mail server's certificate is for another name, that server's name and address, to find a shared hosting server's own name) |
| Mozilla's mail server database | Only if you allow it during setup | Your email domain and your mail host's domain (never your full address) |
| Your mail server's rules service (ManageSieve) | Only if you turn on "Rules on the mail server" (Settings > Advanced) | Your blocked senders and folder rules, so your server can sort mail |
| Google Safe Browsing | Only if you turn on "Check links with Google Safe Browsing" (Settings > Advanced) | Lists of dangerous sites are downloaded; to confirm a match, only a 4-byte part of a link's fingerprint is sent, never the link itself |
| VirusTotal | Only if you turn it on with your own API key (Settings > Advanced), and only when you tap "Check with VirusTotal" | A file's SHA-256 fingerprint (the file is never uploaded) or a link's address |
| The AI provider you choose (Anthropic, OpenAI, Meta for its Muse models, Google for Gemini, or an OpenAI-compatible address you enter) | Only if you add your own API key and turn a feature on (Settings > AI assistant), after the app asks you once, and only when you use the feature (such as Summarise) | Only what that feature needs: for a summary, the email or conversation you ask about (senders, recipients, dates, subjects, text and the names of attached files, never the files), with your key |
| The AI provider you choose, with your own key: writing help | Only if you turn on "Writing help" (Settings > AI assistant), and only when you tap "Write with AI" and ask for a draft or rewrite | For a drafted reply, the email you are answering and your instruction; for a rewrite, only the text you wrote; your name. Never your recipients or other mail |
| The AI provider you chose (your own key) | Only if you turn on Suggested actions (Settings > AI assistant), when you ask it to tidy | Your request, your folder names, and the sender, subject, date and status (read, pinned, folder) of the emails it should look at, never their text |
| Newsletter senders | Only when you tap Unsubscribe and confirm | The unsubscribe request the newsletter asked for |
| The organizer of a meeting invitation | Only when you tap Accept, Maybe or Decline | An email from your own account with your answer and any note you add, sent through your own mail server |
| Images and links in an email | Only when you choose to load images or open a link | A request for the image or page, without cookies; like any connection, it shows your IP address |

Each of these services handles data under its own privacy policy.

## Google user data

When you sign in with Google, Citusmail asks for access to your Gmail
mailbox (IMAP and SMTP) so it can show and send your mail. This data is
used only to provide the app's email features to you, on your device. It
is not transferred to Fluminaris, not used for advertising, and not read
by people. The one transfer you can choose is the optional AI assistant:
if you add your own key and turn a feature on, the email or conversation
you ask about is sent from your device to the AI provider you chose, only
when you ask, to give you that feature (such as a summary).

Citusmail's use and transfer of information received from Google APIs
adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## AI assistant with your own key (optional)

Citusmail has no AI service of its own. If you choose to, you can add
your own API key for an AI provider (Claude from Anthropic, GPT from
OpenAI, Meta (Muse models), Google (Gemini), or an OpenAI-compatible service or a model on
your own computer) and turn on features such as summaries. Everything is
off until you do, and each feature asks once, naming the provider and
what it sends, before it first sends anything.

When you use a feature, your device sends what it needs (for a summary,
the email or conversation you ask about) directly to the provider you
chose, with your key. It is not sent to Fluminaris; we never receive it.
The provider handles it under its own terms and privacy policy; on
Google's free tier for Gemini, Google may use what it receives to improve
its products, which a paid key avoids. Your
keys stay in your device's secure keychain, and results such as
summaries are kept only on your device, encrypted.

## Sync between your devices (optional)

Off until you turn it on. Then your blocked senders, Screener decisions,
snoozed emails, unsubscribes, folder rules, image choices, sign-offs and
mail-handling preferences (the Screener on or off, "New since you were away", reading receipts and bookings automatically, learning from your corrections, bill and trial reminders and monthly renewals, follow-up reminders, clean-up of old codes and your agreement to it, Clean up's Keep list, and whether tips are off) are kept the same on your devices. They travel
through a folder in **your own mail account**, never through a server of
ours, and are end-to-end encrypted with a code only your devices hold.
Other settings stay on each device: notifications, instant mail and
battery, the theme, the app lock and PIN, and Safe Browsing,
VirusTotal and the AI assistant, which each device agrees to itself. Older versions of the
app can't read the synced data once it holds these preferences.

## Adding accounts from your phone (optional)

If you choose "Send accounts to a computer" on your phone and scan the
code your computer shows, the accounts you pick (address, name, server
settings and password, or Google sign-in tokens) go straight from your
phone to your computer over your own local network, end-to-end encrypted,
after you confirm. Nothing goes through the internet or a server of ours.
If the phone can't reach the computer, it can make an encrypted file
instead that only that computer can open, while its code is showing.

## Android permissions

| Permission | Why |
| --- | --- |
| Internet, network state | To connect to your mail provider |
| Notifications | To tell you about new mail (sender, subject and, unless you turn previews off, the first lines; on the lock screen only that there is new mail) |
| Foreground service, start at boot | To keep a live connection to your mail server ("Instant mail", on unless you turn it off), or check for new mail in the background |
| Run in the background without battery limits | Asked once, with Android's own dialog, so Instant mail keeps its connection while the phone sleeps |
| Fingerprint or face unlock | Only if you turn on the app lock; checked by Android, the app only learns "yes" or "no" |
| Camera | Only while you scan your computer's code in "Send accounts to a computer"; Android asks the first time. Nothing is recorded or kept |

The app does not use your location, microphone, contacts list or
advertising ID.

## Security

Connections to mail servers are encrypted (TLS). Mail and settings on the
device are stored in an encrypted database whose key is kept in the
device's secure keychain. Passwords and sign-in tokens are kept only in
that keychain. Images and trackers in emails are blocked unless you load
them, and the app checks messages for signs of phishing on the device.

## Keeping and deleting your data

Your data stays on your device for as long as the account is in the app.
Removing an account from the app deletes its mail and settings from the
device; uninstalling the app deletes everything it stored. Mail on your
mail provider's servers is managed by your provider and is not affected,
except by actions you take in the app (such as deleting a message).

Because Fluminaris holds no data about you, there is nothing for us to
delete; you can still contact us with any question.

## Children

Citusmail is not directed at children under 13 and does not knowingly
collect data from anyone.

## Terms of service

Using Citusmail is also covered by the
[Terms of Service](terms-of-service.md).

## Changes to this policy

If this policy changes, the new version will be published at this address
with a new effective date.
