# Security Policy

## Supported versions

Only the latest release gets security fixes. Please update to it before reporting.

| Version | Supported |
| --- | --- |
| latest release | ✅ |
| older releases | ❌ |

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Open [Report a vulnerability](https://github.com/uzarixx/island/security/advisories/new)
   (the repository's **Security** tab → **Report a vulnerability**).
2. Describe the problem, the macOS version and Island version, and how to reproduce it.

You'll get a reply within 7 days. Once the problem is confirmed, a fix is released as soon as
possible and the advisory is published with it, crediting you unless you'd rather not be named.

## Scope

Island runs only on your Mac and has no server (see the [privacy policy](PRIVACY.md)). Useful
reports include, for example:

- a way for another app or a website to read Island's data (notes, clipboard history, the
  Spotify sign-in) or to make Island act on your behalf;
- the Accessibility, microphone, calendar or audio access Island is given being usable for
  something other than what it's for;
- the Spotify sign-in (OAuth with PKCE on `127.0.0.1`) being open to interception.

Not in scope: Island isn't notarized by Apple (see the README for how to open it the first
time), and it relies on the security of macOS and of the Spotify and Apple Music apps
themselves.
