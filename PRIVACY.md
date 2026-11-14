# Privacy

The app collects nothing. There is no account with us, no server of ours,
no analytics, no crash reporting and no advertising.

## What leaves your device

| Destination | When | What is sent |
| --- | --- | --- |
| Your mail servers | Always, to read and send mail | Your login and mail, over TLS |
| Your mail server's rules service (ManageSieve, port 4190) | Only with "Rules on the mail server" turned on, when your rules change (and once a day to check) | Your login over TLS, and a script with your blocked senders and folder rules, so the server sorts mail as it arrives |
| Microsoft's sign-in service | Only for Outlook / Hotmail and Microsoft 365 accounts: when you add one (in your own browser), and to renew access about every hour | Your sign-in happens on Microsoft's page; the app sends only the one-time code it gets back, and later its refresh token, with the app's (or your own) client ID, to get access to your mail. Your password never passes through the app |
| Google's sign-in service | Only for Gmail accounts you add with "Sign in with Google": when you add one (in your own browser), and to renew access about every hour | As for Microsoft: the one-time code, then the refresh token, with the app's (or your own) client ID. Your password never passes through the app |
| Google Cloud console | Only when you tap "Open Google Cloud" while entering your own client ID | Your browser opens the page |
| Your mail provider's settings file (your domain's own servers, and those of the mail host your domain's MX records point to) | When adding an account (not for Gmail, whose settings are built in) | Over an encrypted connection, your email address, which some providers need to answer (no app name, no cookies). Where only an unencrypted file exists, that request names your domain alone, and its answer is used only when it points to your domain's or your mail host's own servers |
| Your domain's Exchange Autodiscover service (autodiscover.<your domain>, or your domain itself) | When adding an account, if nothing else found the settings | Your email address, over an encrypted connection, in Microsoft's Autodiscover request. Microsoft's own central service is never asked |
| Your system's DNS resolver | When adding an account | Lookups for your domain's mail records (MX, to recognise Google Workspace and Microsoft 365 and to find your mail host, and SRV); and, only when a mail server's certificate is for another name, that server's address and the name the address points back to (A, AAAA and PTR), to find a shared hosting server's own name |
| Common server names of your domain | When adding an account, if nothing else found them | A connection test without any login |
| Mozilla's mail server database | Only if you allow it during setup | Your email domain (and your mail host's domain), never the full address |
| A newsletter's one-click unsubscribe address | Only when you tap Unsubscribe and confirm | One request with the fixed text `List-Unsubscribe=One-Click` and a generic user agent. No cookies, no referrer, no language. Like any connection, it shows your IP address |
| A newsletter's unsubscribe email address | Only when you tap Unsubscribe and confirm | An email from your account saying "unsubscribe" (a copy is kept in Sent) |
| The organizer of a meeting invitation | Only when you tap Accept, Maybe or Decline on the invitation | An email from your account with your answer (and your note, if you wrote one) and the event's calendar details, through your own mail server; a copy is kept in Sent. No one else on the invitation gets it |
| Your calendar app | Only when you tap "Open in calendar app" on an invitation | The invitation's .ics file, written to a private folder of the app's own data and removed a couple of minutes later, handed to the app your system chooses on this device |
| A newsletter's unsubscribe page | Only when you tap Unsubscribe and choose to open it | Your browser opens the page |
| Your computer, on your own local network | Only when you scan the computer's code in "Send accounts to a computer" and confirm (with your PIN or fingerprint if the app lock is on) | The accounts you choose: address, name, server settings and password or sign-in, and, if you tick it, the sync code. Straight from the phone to the computer over your Wi-Fi, end-to-end encrypted, never through the internet or a server of ours. See "Adding accounts from your phone" |
| An app you choose in the share sheet | Only if your phone couldn't reach the computer and you choose "Send as a file instead" | The same accounts, sealed in a file only that computer can open while its code is showing |
| Your own mail account's "Citusmail Sync" folder | Only with sync between devices turned on, with each mail check | This device's blocked senders, Screener decisions, snoozed emails (which message, by its Message-ID, and when it comes back), unsubscribes, folder rules, image senders, your sign-offs with each account's choice of them, and your mail-handling preferences (the Screener on or off, "New since you were away", reading receipts and bookings automatically, learning from your corrections, bill and trial reminders and monthly renewals, follow-up reminders, clean-up of old codes and your agreement to it, Clean up's Keep list, and whether tips are off), end-to-end encrypted |
| Google's app password page | Only when you tap "Create an app password" while adding a Gmail account | Your browser opens myaccount.google.com/apppasswords |
| Google Safe Browsing | Only with "Check links with Google Safe Browsing" turned on (it asks first): the lists of dangerous sites are downloaded every half hour or so, and when a link you open matches the start of a listed fingerprint | List downloads send the app's API key (or yours) and the lists' versions. A confirmation sends only the first 4 bytes of the matching SHA-256 fingerprint, never the link. Google sees your IP address |
| VirusTotal (your own API key) | Only with "Ask VirusTotal" turned on, and only when you tap "Check with VirusTotal" on an attachment or link the on-device checks flagged | For a file, its SHA-256 fingerprint only (the file is never uploaded); for a link, the address. Your key goes with it. VirusTotal keeps what it is asked and sees your IP address |
| The AI provider you chose for Translate or Quick replies (your own key) | Only with that feature turned on in Settings, AI assistant (it asks once before the first email goes), and only when you tap Translate or "Suggest replies" on an email | That one email's sender, subject and text (no attachments, nothing else from your mailbox), with your key. What comes back is shown as plain text; a suggested reply is only sent if you send it yourself |
| A link in an email | Only when you tap it and confirm the address | Your browser opens the link, without tracking parameters such as `utm_source` |
| Images in an email | Only when you tap "Load images", or for a sender you chose "Always from this sender" for (and only when your mail server verified the mail is from them) | A request for each image with a generic user agent: no cookies, no referrer, no language. Like any connection, it shows your IP address, and the sender can tell the message was opened. Tracking pixels are never requested |

Nothing else: the app's typeface (IBM Plex Sans) and icons are part of the
app, and sender pictures are initials drawn on the device, so no fonts,
avatars or other assets are ever downloaded.


## What stays on your device

Mail, contacts, settings and caches are stored encrypted on the device.
Sorting into Important, General, Verification, Newsletters and
Notifications runs on the device from a few message headers, the subject
and your Sent folder. Codes in verification mail are found on the device
too; for this, new verification mail (from the last day) is downloaded
from your own mail server, as if you had opened it, but it stays unread. Phishing checks
(sender verification, lookalike addresses, deceptive links, risky
attachments, and mail that claims to speak for your own organisation or a
big company while coming from elsewhere) also run on the device only, using the results your own mail
server already wrote into the message and a built-in list of domain
endings. No link, address or file is looked up anywhere, unless you turn on Google
Safe Browsing (see above), which still checks links on the device first.

Subscriptions are found the same way, on the device: receipts and
renewal emails from the last two years are read for the company, price
and dates. Where a price or date is missing, those receipts are
downloaded from your own mail server, as if you had opened them, but they
stay unread: ahead of time with "Read receipts and bookings
automatically" (Settings, on by default), or when you tap "Read
receipts" with it off. Only their text is read; no remote images load
and no read receipt is sent.

Deliveries are found the same way: order and shipping emails from the
last year are read on the device for tracking numbers, order numbers,
status and dates, including the order details some shops and carriers
add to their emails for mail apps (read as data, never run). Small ones
are downloaded from your own mail server the same way (ahead of time,
or with "Read shipping emails" when that setting is off); they stay
unread. A carrier's tracking page opens in
your browser only when you choose "Track", after asking.

Trips are found the same way: booking emails (flights, hotels, trains,
buses, rental cars, tables and tickets) are read on the device, with the
booking details airlines and booking sites add for mail apps (read as
data, never run). Small ones are downloaded from your own mail server
the same way (ahead of time, or with "Read booking emails" when that
setting is off); they stay unread. "Add to
calendar" hands a calendar file to your own calendar app; "Manage
booking" opens the booking's page only after asking.

Appointments are found the same way: booking emails from clinics,
salons, garages, offices and booking sites are read on the device,
with the booking details and calendar files they carry (read as data,
never run). "Add to calendar" hands a calendar file to your own calendar
app; a link from the email opens only after asking.

Online accounts are found the same way, from welcome, sign-in, password
and security emails on the device; welcome emails whose preview says
too little are downloaded the same way, and stay unread.

Blocking a sender is private: they aren't told, and the block list is kept
on the device. Their new mail is moved to the Junk folder in your own mail
account and never shown as a notification.

## Sync between devices

Off until you turn it on. Then your blocked senders, Screener decisions,
snoozed emails, unsubscribes, folder rules, image senders, sign-offs and
mail-handling preferences (the Screener on or off, "New since you were away", reading receipts and bookings automatically, learning from your corrections, bill and trial reminders and monthly renewals, follow-up reminders, clean-up of old codes and your agreement to it, Clean up's Keep list, and whether tips are off) are kept the same on all your devices. They travel
through a "Citusmail Sync" folder in your own mail account (one message per
device), never through a server of ours. Each message is end-to-end
encrypted with your sync code: your mail provider, and anyone else with
access to your mailbox, sees only sealed data plus which of your devices
wrote it. The code is a random 128-bit secret kept only in each device's
system keychain; with the app lock on, showing it asks for your PIN. Other
app settings never sync: notifications and their previews, instant mail
and battery settings, the theme and layout, the app lock and your PIN,
and Safe Browsing and VirusTotal (they send data to another company, so
each device agrees to them itself). Older versions of the app can't read
the synced data once it holds these preferences: update every device.

## Adding accounts from your phone

On a computer, "Add accounts from your phone" shows a QR code; on the
phone, Settings > Send accounts to a computer scans it. The code holds
the computer's local network addresses, a one-time public key and a
random one-time token. The phone connects straight to the computer over
your own network: nothing goes through the internet or any server (there
is none of ours), and a code naming an address outside your local network
is refused. Both screens show the same six-digit check code. You choose
the accounts and confirm (with your PIN or fingerprint if the app lock is
on) before anything is sent.

What is sent, end-to-end encrypted (X25519, HKDF-SHA256,
ChaCha20-Poly1305) with keys only the two devices have: each chosen
account's address, name, server settings and password, or for Google its
sign-in tokens; your own OAuth client IDs if you entered any; and, if you
tick it, the code of Sync between devices. Outlook / Microsoft 365
sign-ins are never sent: Microsoft renews them in a way two devices can't
share, so the computer signs in itself. The computer checks each account
with a real sign-in before saving it, and keeps passwords and tokens only
in its system keychain.

A code works once and stops after 5 minutes on the network (15 for a
file); the computer then forgets its key. The camera is used only while
the scanner is open; nothing is recorded or kept.

If the phone can't reach the computer, it can make a file instead
(`citusmail-accounts.cmpair`), which you send to the computer yourself
with any app (Quick Share, a cable, a message to yourself). The file is
sealed to the key of the code the computer is showing, which never leaves
the computer's memory: only that computer can open it, and only while
the code is still showing. After that the file is useless; the phone
deletes its copy after 15 minutes.

## Notifications

New-mail notifications show the sender, the subject and the first lines
of the message (turn off "Show message previews" to leave the text out),
and only for Verification, Important, General and Notifications mail (and
pins; Notifications can be turned off; never newsletters). A
verification code is shown in the title, with a Copy code button that puts
it on the clipboard (marked sensitive, so Android 13+ hides it in its
preview). On Android the lock screen shows only that there is new mail;
with the app lock on, so do the notifications themselves. They are created
on your device; no push service is involved. On Android, Citusmail keeps
a live connection to your own mail server ("Instant mail", on unless you
turn it off), which shows a quiet permanent notification, as Android
requires; it asks Android once to let it run while the phone sleeps.
With Instant mail off, it checks about every 5 minutes in the background
(Android may wait longer to save battery).

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
mail that looks like a scam (a lookalike or imitating sender, deceptive
links, dangerous files), because that would only confirm your address is
read, and it says so instead. The unsubscribe address itself gets the same
checks as links in a message; an unsafe one is never used. When only the
sender couldn't be verified (forwarded mail often can't be), you can still
unsubscribe, after a warning.

## Read receipts and trackers

Read receipts are never sent. When a sender asks for one, the message
says so, and that nothing was sent.

You can ask for a read receipt yourself when writing (off by default). That
adds only the standard request (`Disposition-Notification-To`); the
recipient's mail app decides whether to answer, and many never do.
Citusmail never uses tracking pixels or tracked links to find out whether
someone read your mail. Receipts that come back are matched to your sent
message on your device and shown on it ("Read on …"); they stay in your
Inbox folder but not in the Smart Inbox, and never cause a notification.

Images stay hidden until you load them, so senders can't see when or
where you open their mail. Tracking pixels (tiny or invisible images,
known tracking services and addresses) are removed for good: they are not
loaded even when you load a message's images, nor after a redirect. Links
lose their tracking parameters (`utm_*`, `fbclid`, `gclid`, `mc_eid` and
similar) before they open. A link that itself goes through a click
tracker still reports the click; the confirmation shows where it goes.
