# Calendar invitation fixtures

Meeting invitations as calendar services send them, for the iCalendar
reader in `packages/mail_view` and the reader's event card. Kept apart
from `test-data/mail` so the test mail server doesn't load them. Stored
with LF line endings (`*.eml -text`); the iCalendar parts inside use CRLF
where the real services do.

All addresses and links use reserved test domains (`.example`, `.test`),
except the meeting services' own hosts, which the link detection needs.

| File | What it tests |
| --- | --- |
| outlook-teams-request.eml | Outlook/Exchange REQUEST: VTIMEZONE with a Windows zone name, folded lines, base64 calendar part, Teams link in an X- property, a room among the attendees |
| google-weekly-request.eml | Google Calendar REQUEST: TZID without VTIMEZONE, weekly on two days, Meet link, the same event attached again as `invite.ics` |
| zoom-webinar.eml | Zoom PUBLISH: UTC times, link in LOCATION, only an attached `.ics`, no attendees |
| all-day-request.eml | Bare `text/calendar` message: all-day over two days (VALUE=DATE), quoted CN, attendee address in mixed case |
| outlook-cancel.eml | Outlook CANCEL with STATUS:CANCELLED |
| google-reply-accepted.eml | REPLY: an attendee accepted the user's own invitation, with a comment |
