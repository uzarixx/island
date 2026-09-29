# Changelog

All notable changes to Island. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-09-30

### Added
- **Apple Music.** The music tab controls Apple Music as well as Spotify and follows whichever
  started playing last. Cover, seeking, volume, shuffle, repeat (including repeating one song)
  and favorites, through Music's own AppleScript.
- **Paste onto the shelf.** A Paste button, and <kbd>⌘</kbd><kbd>V</kbd> on the shelf tab, put
  what's on the clipboard on the shelf: a screenshot, a copied picture, files copied in Finder,
  a link or text.
- [Privacy policy](PRIVACY.md), in English and Russian: what Island connects to, what it keeps
  on your Mac, and how to remove it.

### Changed
- **Settings** are laid out like System Settings: a sidebar with General, Tabs, Music, Meetings,
  Chats & Links and Controls.
- Tabs, chats and links are reordered in Settings by dragging instead of with arrow buttons.
- Without the Spotify Web API connected, the music tab shows just the player, larger; the queue,
  playlists and search appear once Spotify is connected.
- The live equalizer follows the app that's playing, Spotify or Apple Music.
- The disk image opens as a small window with a background: an arrow from Island to
  Applications, and how to open the app the first time. The disk has Island's icon.
- The open notch draws its Liquid Glass and controls as active right away, not only after the
  first click in it.

### Fixed
- After the notch closed, typing in other apps sometimes only beeped until <kbd>Esc</kbd> was
  pressed: the closed notch could keep the keyboard. Closing Settings or the AirDrop sheet no
  longer leaves the app active with nothing to type into either.
- Dragging a card out of the shelf or the clipboard, or a voice memo, showed a yellow placeholder
  with a crossed-out circle over it; the drag now shows the picture or a small label.

## [0.1.0] - 2026-09-29

First release: music (Spotify), shelf, meetings, clipboard history, notes and voice notes, chats
and links, battery charge limit, color picker, three-finger middle click, keyboard control.

[1.1.0]: ../../compare/v1.0.0...v1.1.0
[1.0.0]: ../../compare/v0.1.0...v1.0.0
[0.1.0]: ../../releases/tag/v0.1.0
