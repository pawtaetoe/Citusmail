# Privacy

The app collects nothing. There is no account with us, no server of ours,
no analytics, no crash reporting and no advertising.

## What leaves your device

| Destination | When | What is sent |
| --- | --- | --- |
| Your mail servers | Always, to read and send mail | Your login and mail, over TLS |
| Your mail provider's settings file | When adding an account | Your email domain (in the web address only; no app name, no cookies) |
| Your system's DNS resolver | When adding an account | Lookups for your domain's mail records |
| Common server names of your domain | When adding an account, if nothing else found them | A connection test without any login |
| Mozilla's mail server database | Only if you allow it during setup | Your email domain, never the full address |
| A newsletter's one-click unsubscribe address | Only when you tap Unsubscribe and confirm | One request with the fixed text `List-Unsubscribe=One-Click` and a generic user agent. No cookies, no referrer, no language. Like any connection, it shows your IP address |
| A newsletter's unsubscribe email address | Only when you tap Unsubscribe and confirm | An email from your account saying "unsubscribe" (a copy is kept in Sent) |
| A newsletter's unsubscribe page | Only when you tap Unsubscribe and choose to open it | Your browser opens the page |
| A link in an email | Only when you tap it and confirm the address | Your browser opens the link |
| Remote images in an email | Never yet; later only when you tap "Load images" or trust the sender | A normal image request to the sender's server |

Planned optional features (off by default, each asks first):

| Destination | What is sent |
| --- | --- |
| Google Safe Browsing | Hash prefixes downloaded to the device; links are checked locally |
| VirusTotal (your own API key) | Only links or file hashes that local checks flagged |

## What stays on your device

Mail, contacts, settings and caches are stored encrypted on the device.
Sorting into Important, General, Newsletters and Notifications runs on the
device from a few message headers and your Sent folder. Phishing checks
(sender verification, lookalike addresses, deceptive links, risky
attachments) also run on the device only, using the results your own mail
server already wrote into the message and a built-in list of domain
endings. No link, address or file is looked up anywhere.

Blocking a sender is private: they aren't told, and the block list is kept
on the device. Their new mail is moved to the Junk folder in your own mail
account and never shown as a notification. A later version will let app
settings such as the block list sync between your devices through a hidden
folder in your own mail account. They never go to anyone else.

## Notifications

New-mail notifications show the sender and subject, never the message
text, and only for Important and General mail. On Android the lock screen
shows only that there is new mail. They are created on your device; no
push service is involved. On Android, Fmail checks for mail about every 15
minutes in the background, or keeps a live connection if you turn on
"Instant mail" (which shows a permanent notification, as Android requires).

## Mail you send

Sent mail carries no app name or version. Its Message-ID is random and
uses your own domain, and its date is written in UTC, so it does not
reveal your time zone. Bcc recipients are never written into the message.

## Unsubscribing

Fmail remembers on your device which lists you unsubscribed from, so it
can tell you when one keeps sending. It never offers to unsubscribe from
mail that looks like a scam, because that would only confirm your address
is read.

## Read receipts and trackers

Read-receipt requests are ignored, and remote images (including tracking
pixels) are blocked by default.
