# Hannun Calendar

[한국어](README.ko.md)

A native macOS calendar board for events, projects, notes, subscriptions, tasks, habits, world clocks and focus. Calendars use EventKit and the accounts already connected to macOS. Board data stays on this Mac. License: [MIT](LICENSE).

Move and resize the calendar and four configurable panels on a free grid. Hold an empty board background to enter layout editing; choose a panel from its title while editing. Panel choices and layout are saved locally. Editing outlines stay still. Routine saved/Undo banners are reduced while partial-save information and errors remain visible.

## Beta download

The prepared release is **v1.0.0-beta.3**, for Apple Silicon and macOS 14 or later. The app and DMG are **Developer ID signed, Apple notarized and stapled**. The ZIP contains the same stapled app. Signature, ticket and Gatekeeper checks passed for these exact artifacts. The app's bundle version remains **1.0**, build **1**; the release tag and SHA-256 identify this update.

[Release notes](https://github.com/ninejh/hannun-calendar/releases/tag/v1.0.0-beta.3) · [DMG](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.3/Hannun-Calendar-arm64.dmg) · [ZIP](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.3/Hannun-Calendar-arm64.zip) · [Checksums](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.3/SHA256SUMS)

See [INSTALL.md](INSTALL.md) before installing or upgrading. A reported calendar-access/permission problem remains unresolved in the last local-install evidence. Calendar connections, clean-account first launch, notification/login-item permissions, upgrades, and every account/OS combination have not all been independently verified. This beta does not claim full acceptance-test coverage. Back up important calendar and board data; older apps may not read the new layout format.

## Build from source

Requires an Apple Silicon Mac, macOS 14 or later, Swift 6, Python 3 and Xcode or Command Line Tools. No third-party application dependencies are required. From this directory:

```sh
zsh scripts/check.sh
zsh scripts/build.sh
```

The app is written to `build/Hannun Calendar.app`. Local source builds are **ad hoc signed**, even when official release downloads use Developer ID signing. Signing and notarization are separate distribution steps and require the publisher's credentials. This source package includes production code and build checks. Development test fixtures are not included.

For an optional fictional-data demo, quit another running copy deliberately and run:

```sh
open -n 'build/Hannun Calendar.app' --args --demo
```

Demo mode uses fictional events, an in-memory board and fake external adapters. A normal launch can request calendar access and use macOS-connected calendars. Optional command-line diagnostic report output must be an absolute descendant of the build directory; when an app is moved outside a build tree, its diagnostic fallback is the chosen working directory's `build/` folder.

## Privacy and data providers

There is no app account, app server or analytics. Local board data is not encrypted. macOS manages calendar account authentication and synchronization; saving or moving an event changes the original calendar event. Optional weather and exchange-rate requests send the selected city's coordinates or currency codes and normal connection metadata to their providers. Settings can disable these requests. Calendar events, notes and subscription names/amounts are not sent in those requests.

Weather: [Open-Meteo](https://open-meteo.com/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), summarized as icons. Its free hosted API is subject to [noncommercial terms](https://open-meteo.com/en/terms). Exchange rates: [Frankfurter](https://frankfurter.dev/) using ECB data, subject to the [ECB disclaimer](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html). Provider terms are separate from the app's MIT license.
