# background_clipboard

Puts text on the clipboard, also when no app window is open. Used by the
**Copy code** button on new-mail notifications: on Android that button is
handled in a headless Flutter engine, where Flutter's own `Clipboard` has no
handler, so a few lines of Kotlin write the clipboard with the application
context instead.

- Writes only; never reads the clipboard (Android 10+ restricts reading in
  the background, not writing).
- Codes are marked sensitive, so Android 13+ hides them in its "copied"
  preview. On Android 12 and older a short toast confirms the copy.
- On Linux and Windows the app is running whenever a notification button is
  pressed, so this is Flutter's `Clipboard`.
- No network, no permissions, no other dependencies.
