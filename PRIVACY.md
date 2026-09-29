# Privacy Policy

*Effective September 30, 2026 · [Русский](PRIVACY.ru.md)*

Island is a Mac app that runs entirely on your Mac. It has no account, no server, no analytics,
no crash reporting and no ads. Nobody, including the developer, receives any information about
you or how you use it.

## What Island connects to

Island goes online only in these cases, and only directly, never through a server of its own:

- **Spotify, if you connect it.** Island signs in to Spotify with your own app key (Client ID)
  and uses the Spotify Web API for the queue, playlists, search, likes and repeat. Cover images
  of Spotify tracks come from Spotify too. What Spotify does with this is covered by
  [Spotify's privacy policy](https://www.spotify.com/legal/privacy-policy/).
- **Sites you save as links.** To show a link's icon, Island asks that site for its icon
  (`apple-touch-icon.png` or `favicon.ico`), once, and keeps it. The site sees a request from your
  Mac, as when you open it in a browser.

Nothing else. Island doesn't check for updates and doesn't load anything from the internet on
its own.

## What stays on your Mac

| What | Where | For how long |
| --- | --- | --- |
| Clipboard history | memory only | until you quit Island; never written to disk |
| Notes | `~/Library/Application Support/DynamicIsland/notes.txt` | until you delete them |
| Voice notes | `~/Library/Application Support/DynamicIsland/Recordings` | until you delete them |
| Things on the shelf | the shelf only remembers where your files are; pictures and archives it makes itself are kept in `…/DynamicIsland/Shelf` | until you take them off the shelf |
| Spotify sign-in | `…/DynamicIsland/spotify-token.json`, readable only by your user | until you disconnect Spotify |
| Chats, links, meetings, settings | the app's preferences (`com.andrei.dynamicisland`) | until you delete them |
| Link icons | `~/Library/Caches/DynamicIsland/Favicons` | cache, can be deleted any time |

Clipboard history skips anything that apps mark as private or temporary, such as passwords
from password managers, and can be turned off in Settings. Pictures you drag out of the
clipboard history are written to a temporary folder that is emptied when Island starts and quits.

## What Island reads, and why

Each of these is used only on your Mac and only when you use the feature. macOS asks for your
permission first, and you can take it back any time in System Settings → Privacy & Security.

- **Calendars.** Events for the week ahead, to show meetings and remind you about them. Events
  are only read, never changed or sent anywhere.
- **Microphone.** Only while you record a voice note.
- **System audio recording.** Only if you turn on the live equalizer (it's off by default):
  the sound of the music app that's playing is split into levels for the bars on the island,
  in memory, and never recorded or stored.
- **Automation (Spotify, Music).** To control playback and see what's playing.
- **Accessibility.** For the three-finger middle click: Island watches trackpad touches to
  recognize the gesture and sends a middle click. Touches and clicks aren't stored.
- **Clipboard.** For the clipboard history, as described above.

Translation of clipboard text uses Apple's on-device translation, so the text doesn't leave
your Mac either.

## Removing your data

Quit Island and delete the app, then remove:

```sh
rm -rf ~/Library/Application\ Support/DynamicIsland ~/Library/Caches/DynamicIsland
defaults delete com.andrei.dynamicisland
```

To revoke Spotify's access as well, remove the app on
[spotify.com/account/apps](https://www.spotify.com/account/apps/).

## Changes

If this policy changes, the new version will be published here with a new date, and the change
noted in the [changelog](CHANGELOG.md).

## Contact

Questions about privacy: open an issue at
[github.com/uzarixx/island](https://github.com/uzarixx/island/issues).
