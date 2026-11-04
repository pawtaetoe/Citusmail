# mail_view

Turns a raw email into something safe to show. Pure Dart.

- **`MessageView.parse`** picks the HTML body (or plain text), resolves
  images embedded in the message (`cid:`), and lists attachments.
- **`HtmlConverter`** keeps an allow-list: text, headings, paragraphs,
  lists, quotes, preformatted text, data tables, `http`/`https`/`mailto`
  links, and images whose bytes are inside the message (PNG, JPEG, GIF,
  WebP; never SVG). Scripts, styles, frames, forms, objects, CSS and hidden
  content are dropped. Remote images become `RemoteImageInline` (an
  address, never loaded here), except tracking pixels (`TrackingPixels`:
  tiny, invisible, known tracking hosts and paths), which are left out and
  counted. Layout tables are flattened so mail reads well on phones.
- **`ImageHeader`** reads an image's real type and size from its first
  bytes; images that aren't PNG, JPEG, GIF or WebP, or are larger than
  16384 pixels a side or 40 megapixels (decompression bombs), are refused.
- **`PlainTextConverter`** handles `>` quotes, `format=flowed` and links.
- **`CalendarInvite`** reads the meeting invitation, cancellation or
  answer in a message's `text/calendar` part (or attached `.ics`) with
  our own RFC 5545 reader (`ICalParser`): line folding, parameters,
  escaped text, all-day, UTC, floating and zoned times (the file's
  VTIMEZONE, else a table of common IANA and Windows zone names in
  `CalendarTimeZones`), organizer, attendees and their answers, and
  Teams/Zoom/Meet links. `CalendarText` says when it is ("Thu, 12 Nov ·
  2:00–3:00 pm", "Repeats weekly on Monday") in the reader's time zone;
  `CalendarReply` builds the iTIP REPLY (RFC 5546) that accepts,
  declines or tentatively accepts it. Files over 2 MB, deep nesting and
  broken lines are cut or skipped, never fatal.
- **`SafeFileName`** cleans attachment names: no paths, no right-to-left
  tricks, no Windows device names, at most 200 bytes.

The result, `RichDocument`, names no remote resource except content
images, as addresses, so a renderer of it makes no network request by
itself: the app fetches images only after the user asks (through
`mail_web`). `remoteImages` and `trackers` (with `trackerHosts`) let the
app say what it held back.

Hostile input is bounded: nesting depth, number of blocks, text length,
image size and source length all have limits, and hitting one cuts the
document (`truncated`) instead of failing.

```bash
dart test
```
