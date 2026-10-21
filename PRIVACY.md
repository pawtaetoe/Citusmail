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
| Unsubscribe addresses or links | Only when you tap Unsubscribe | What the newsletter's unsubscribe method requires |
| Remote images in an email | Only when you tap "Load images" or trust the sender | A normal image request to the sender's server |

Planned optional features (off by default, each asks first):

| Destination | What is sent |
| --- | --- |
| Google Safe Browsing | Hash prefixes downloaded to the device; links are checked locally |
| VirusTotal (your own API key) | Only links or file hashes that local checks flagged |

## What stays on your device

Mail, contacts, settings and caches are stored encrypted on the device. App
settings such as your block list can sync between your devices through a
hidden folder in your own mail account. They never go to anyone else.

## Read receipts and trackers

Read-receipt requests are ignored, and remote images (including tracking
pixels) are blocked by default.
