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
| A link in an email | Only when you tap it and confirm the address | Your browser opens the link, without tracking parameters such as `utm_source` |
| Images in an email | Only when you tap "Load images", or for a sender you chose "Always from this sender" for (and only when your mail server verified the mail is from them) | A request for each image with a generic user agent: no cookies, no referrer, no language. Like any connection, it shows your IP address, and the sender can tell the message was opened. Tracking pixels are never requested |

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
push service is involved. On Android, Citusmail checks for mail about every 15
minutes in the background, or keeps a live connection if you turn on
"Instant mail" (which shows a permanent notification, as Android requires).

## Mail you send

Sent mail carries no app name or version. Its Message-ID is random and
uses your own domain, and its date is written in UTC, so it does not
reveal your time zone. Bcc recipients are never written into the message.

## Unsubscribing

Citusmail remembers on your device which lists you unsubscribed from, so it
can tell you when one keeps sending. It never offers to unsubscribe from
mail that looks like a scam, because that would only confirm your address
is read.

## Read receipts and trackers

Read receipts are never sent. When a sender asks for one, the message
says so, and that nothing was sent.

Images stay hidden until you load them, so senders can't see when or
where you open their mail. Tracking pixels (tiny or invisible images,
known tracking services and addresses) are removed for good: they are not
loaded even when you load a message's images, nor after a redirect. Links
lose their tracking parameters (`utm_*`, `fbclid`, `gclid`, `mc_eid` and
similar) before they open. A link that itself goes through a click
tracker still reports the click; the confirmation shows where it goes.
