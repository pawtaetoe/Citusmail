# mail_view

Turns a raw email into something safe to show. Pure Dart.

- **`MessageView.parse`** picks the HTML body (or plain text), resolves
  images embedded in the message (`cid:`), and lists attachments.
- **`HtmlConverter`** keeps an allow-list: text, headings, paragraphs,
  lists, quotes, preformatted text, data tables, `http`/`https`/`mailto`
  links, and images whose bytes are inside the message (PNG, JPEG, GIF,
  WebP; never SVG). Scripts, styles, frames, forms, objects, remote images,
  CSS and hidden content are dropped. Layout tables are flattened so mail
  reads well on phones.
- **`PlainTextConverter`** handles `>` quotes, `format=flowed` and links.
- **`SafeFileName`** cleans attachment names: no paths, no right-to-left
  tricks, no Windows device names, at most 200 bytes.

The result, `RichDocument`, has no way to express a remote resource, so a
renderer of it cannot make network requests. Remote images are counted
(`blockedImages`) so the app can say they were blocked.

Hostile input is bounded: nesting depth, number of blocks, text length,
image size and source length all have limits, and hitting one cuts the
document (`truncated`) instead of failing.

```bash
dart test
```
