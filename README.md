# Hannun Calendar

[한국어](README.ko.md)

A native macOS calendar board with configurable panels for projects, notes, tasks, subscriptions, world clocks and focus. It uses EventKit for calendars already connected to macOS; local board data remains on your Mac. License: [MIT](LICENSE).

The calendar stays visible beside four configurable slots. Choose from Today, Deadlines, Projects, Quick notes, Subscriptions, To-do, Habits, World Clock and Focus Timer. The reviewed static download website is added separately under `website/` when preparing the public repository; an application-only source export does not include that directory.

## Early beta download

Release **v1.0.0-beta.2**: [Hannun-Calendar-arm64.dmg](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.2/Hannun-Calendar-arm64.dmg) · [Hannun-Calendar-arm64.zip](https://github.com/ninejh/hannun-calendar/releases/download/v1.0.0-beta.2/Hannun-Calendar-arm64.zip). Check `SHA256SUMS` in the same release before installing.

This beta includes changes to calendar connection handling and board controls. A reported missing calendar permission prompt remains unverified and its cause is not confirmed; these changes do not establish that calendar connections work for every account. This early beta does not claim complete macOS integration or acceptance-test coverage.

## Requirements and build

The downloadable beta targets Apple silicon (arm64), macOS 14 or later. Building requires Xcode or Command Line Tools with Swift 6 and Python 3. From this directory:

```sh
./scripts/build.sh
open -n 'build/Hannun Calendar.app' --args --demo
```

Demo mode uses fictional events, an in-memory board and fake external adapters. Quit other instances first. To use real calendars, launch the app normally and choose whether to grant the requested calendar access. Calendar, notification, login-item, upgrade and first-launch behavior on a clean macOS account have not all been independently verified for this beta.

The build is locally ad hoc signed; the downloadable beta is not Developer ID signed or notarized. See [INSTALL.md](INSTALL.md) for installation and Gatekeeper instructions.

## Privacy and data sources

The app has no app account or analytics. Board data is local and unencrypted. Optional weather and currency requests send the chosen city's rounded coordinates or currency codes and normal network metadata to their providers; settings can disable these requests. Weather: [Open-Meteo](https://open-meteo.com/), [CC BY 4.0 attribution](https://creativecommons.org/licenses/by/4.0/); its free hosted service is subject to [non-commercial terms](https://open-meteo.com/en/terms). Exchange rates: [Frankfurter](https://frankfurter.dev/) using ECB data, subject to the [ECB disclaimer](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html). Provider terms are separate from the app's MIT license.
