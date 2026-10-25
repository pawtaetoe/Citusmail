# Privacy

The app collects nothing. There is no account with us, no server of ours,
no analytics, no crash reporting and no advertising.

## What leaves your device

| Destination | When | What is sent |
| --- | --- | --- |
| Your mail servers | Always, to read and send mail | Your login and mail, over TLS |
| Your mail server's rules service (ManageSieve, port 4190) | Only with "Rules on the mail server" turned on, when your rules change (and once a day to check) | Your login over TLS, and a script with your blocked senders and folder rules, so the server sorts mail as it arrives |
| Microsoft's sign-in service | Only for Outlook / Hotmail accounts: when you add one (in your own browser), and to renew access about every hour | Your sign-in happens on Microsoft's page; the app sends only the one-time code it gets back, and later its refresh token, to get access to your mail. Your password never passes through the app |
| Google's sign-in service | Only for Gmail accounts you add with "Sign in with Google": when you add one (in your own browser), and to renew access about every hour | As for Microsoft: the one-time code, then the refresh token, with the app's (or your own) client ID. Your password never passes through the app |
| Google Cloud console | Only when you tap "Open Google Cloud" while entering your own client ID | Your browser opens the page |
| Your mail provider's settings file | When adding an account (not for Gmail, whose settings are built in) | Your email domain (in the web address only; no app name, no cookies) |
| Your system's DNS resolver | When adding an account | Lookups for your domain's mail records (MX, to recognise Google Workspace and Microsoft 365, and SRV) |
| Common server names of your domain | When adding an account, if nothing else found them | A connection test without any login |
| Mozilla's mail server database | Only if you allow it during setup | Your email domain, never the full address |
| A newsletter's one-click unsubscribe address | Only when you tap Unsubscribe and confirm | One request with the fixed text `List-Unsubscribe=One-Click` and a generic user agent. No cookies, no referrer, no language. Like any connection, it shows your IP address |
| A newsletter's unsubscribe email address | Only when you tap Unsubscribe and confirm | An email from your account saying "unsubscribe" (a copy is kept in Sent) |
| A newsletter's unsubscribe page | Only when you tap Unsubscribe and choose to open it | Your browser opens the page |
| Your own mail account's "Citusmail Sync" folder | Only with sync between devices turned on, with each mail check | This device's blocked senders, unsubscribes, folder rules and image senders, end-to-end encrypted |
| Google's app password page | Only when you tap "Create an app password" while adding a Gmail account | Your browser opens myaccount.google.com/apppasswords |
| Google Safe Browsing | Only with "Check links with Google Safe Browsing" turned on (it asks first): the lists of dangerous sites are downloaded every half hour or so, and when a link you open matches the start of a listed fingerprint | List downloads send the app's API key (or yours) and the lists' versions. A confirmation sends only the first 4 bytes of the matching SHA-256 fingerprint, never the link. Google sees your IP address |
| VirusTotal (your own API key) | Only with "Ask VirusTotal" turned on, and only when you tap "Check with VirusTotal" on an attachment or link the on-device checks flagged | For a file, its SHA-256 fingerprint only (the file is never uploaded); for a link, the address. Your key goes with it. VirusTotal keeps what it is asked and sees your IP address |
| A link in an email | Only when you tap it and confirm the address | Your browser opens the link, without tracking parameters such as `utm_source` |
| Images in an email | Only when you tap "Load images", or for a sender you chose "Always from this sender" for (and only when your mail server verified the mail is from them) | A request for each image with a generic user agent: no cookies, no referrer, no language. Like any connection, it shows your IP address, and the sender can tell the message was opened. Tracking pixels are never requested |

Nothing else: the app's typeface (IBM Plex Sans) and icons are part of the
app, and sender pictures are initials drawn on the device, so no fonts,
avatars or other assets are ever downloaded.


## What stays on your device

Mail, contacts, settings and caches are stored encrypted on the device.
Sorting into Important, General, Newsletters and Notifications runs on the
device from a few message headers and your Sent folder. Phishing checks
(sender verification, lookalike addresses, deceptive links, risky
attachments) also run on the device only, using the results your own mail
server already wrote into the message and a built-in list of domain
endings. No link, address or file is looked up anywhere, unless you turn on Google
Safe Browsing (see above), which still checks links on the device first.

Blocking a sender is private: they aren't told, and the block list is kept
on the device. Their new mail is moved to the Junk folder in your own mail
account and never shown as a notification.

## Sync between devices

Off until you turn it on. Then your blocked senders, unsubscribes, folder
rules and image senders are kept the same on all your devices. They travel
through a "Citusmail Sync" folder in your own mail account (one message per
device), never through a server of ours. Each message is end-to-end
encrypted with your sync code: your mail provider, and anyone else with
access to your mailbox, sees only sealed data plus which of your devices
wrote it. The code is a random 128-bit secret kept only in each device's
system keychain; with the app lock on, showing it asks for your PIN. App
settings, the app lock and your PIN never sync.

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

## App lock

With the app lock on, Citusmail asks for your PIN (or, on Android and
Windows, your fingerprint, face or Windows Hello) when it starts and after
you have been away for the time you choose. The PIN is never stored: only
a slow, salted hash of it, kept in your system keychain. Fingerprints and
faces are checked by the operating system; the app only learns "yes" or
"no". While the lock is on, notifications show only that there is new
mail, and the app switcher shows no picture of your mail.

## Unsubscribing

Citusmail remembers on your device which lists you unsubscribed from, so it
can tell you when one keeps sending. It never offers to unsubscribe from
mail that looks like a scam, because that would only confirm your address
is read.

## Read receipts and trackers

Read receipts are never sent. When a sender asks for one, the message
says so, and that nothing was sent.

You can ask for a read receipt yourself when writing (off by default). That
adds only the standard request (`Disposition-Notification-To`); the
recipient's mail app decides whether to answer, and many never do.
Citusmail never uses tracking pixels or tracked links to find out whether
someone read your mail. Receipts that come back are matched to your sent
message on your device and filed under Notifications.

Images stay hidden until you load them, so senders can't see when or
where you open their mail. Tracking pixels (tiny or invisible images,
known tracking services and addresses) are removed for good: they are not
loaded even when you load a message's images, nor after a redirect. Links
lose their tracking parameters (`utm_*`, `fbclid`, `gclid`, `mc_eid` and
similar) before they open. A link that itself goes through a click
tracker still reports the click; the confirmation shows where it goes.
