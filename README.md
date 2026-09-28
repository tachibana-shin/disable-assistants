# Disable Assistants

A minimal rootless jailbreak tweak (iOS 15+) that does exactly one job:

> **Hide the Siri / "Assistants" UI while the device is jailbroken and the
> `Gestures15` tweak is installed and enabled.**

It ships a PreferenceLoader settings panel (`Settings → Disable Assistants`)
with a live status row, but it contains no other feature: no theming, no extra
toggles for unrelated behaviour.

## Requirements

| Item | Value |
| --- | --- |
| Minimum iOS | 15.0 |
| Jailbreak | Rootless (Dopamine / Sileo / roothide) |
| Dependencies | `mobilesubstrate` (ElleKit), `preferenzloader` |
| Gestures15 | Only required if you want the tweak to actually do something |

## Build

```bash
export THEOS=/opt/theos
make package            # -> packages/com.shin.disableassistants_1.0.0_iphoneos-arm64.deb
make package install    # install straight to the device
```

`Makefile` already exports `THEOS_PACKAGE_SCHEME = rootless` and
`TARGET = iphone:clang:latest:15.0`, so no extra flags are needed.

### Build with GitHub Actions (no local Theos)

`.github/workflows/build.yml` builds the same deb on `macos-14` (via the
`.github/actions/setup-theos` composite action: `ldid` + Theos + patched SDKs)
and uploads `packages/*.deb` as a build artifact. It also verifies that the
dylib, the Substrate filter and `Root.plist` really ended up inside the package.

```bash
git push      # Actions tab -> "com.shin.disableassistants" artifact
```

## Releases

`.github/workflows/release.yml` runs
[semantic-release](https://semantic-release.gitbook.io/) on every push to `main`.
Conventional Commits decide the version:

| Commit | Bump |
| --- | --- |
| `feat: …` | minor |
| `fix: …` / `perf: …` | patch |
| `feat!: …` or `BREAKING CHANGE: …` | major |
| `docs:`, `ci:`, `chore:`, `build:` | none (no release) |

Each run bumps `Version:` in `control`, runs `make package FINALPACKAGE=1`
(`scripts/prepare-release.sh`), commits `CHANGELOG.md` + `control` back to
`main` as `chore(release): vX.Y.Z [skip ci]`, then creates the GitHub release
with the `.deb` attached.

```bash
git commit -m "feat: also hide the assistants panel on iOS 16"   # -> v1.1.0
git push
```

> Careful: the literal string `BREAKING CHANGE` anywhere in a commit body marks
> that commit as a major release. Write "breaking change" as one word when you
> only mean it in prose.


## How it works

1. **Condition check** (`DASettings.m`)
   * *Jailbroken*: `/var/jb`, roothide's `tweaksupport`, or classic rootful
     markers (`/private/var/lib/apt`, `/bin/bash`, …).
   * *Gestures15 enabled*: a `*.dylib` whose name contains the match string is
     present in one of the injection directories
     (`MobileSubstrate/DynamicLibraries`, `TweakInject`, …), is not marked
     `*.disabled`, and the matching dpkg package is in the
     `install ok installed` state. A bundle id can be used as the match string
     too, in which case the Substrate filter plists are scanned as well.
2. **Hiding** (`DAHiders.m`)
   Apple ships no stable class name for the Assistants panel and renames it
   between releases, so the tweak does not hardcode one. At load time it walks
   the Objective-C runtime class list and hooks `viewDidLoad`,
   `viewWillAppear:`, `viewDidAppear:`, `didMoveToWindow` and
   `makeKeyAndVisible` on every `UIView` / `UIViewController` subclass whose
   class name refers to Siri or the assistant (classes belonging to the
   Settings app are skipped). A `UIWindowDidBecomeVisible` observer acts as a
   fallback: any overlay window that hosts a Siri-named root view controller or
   subview is hidden as soon as it appears, which also stops the white panel
   from flashing. The list is re-scanned after 3/6/9/12 seconds and whenever a
   window shows up, so lazily loaded frameworks are still caught.
3. **Nothing else is touched** — no preferences of other tweaks are written, no
   daemons are killed, and the hiding is fully reversible with the master
   switch.

## Settings panel

| Row | Key | Default | Meaning |
| --- | --- | --- | --- |
| Hide the Siri (Assistants) UI | `enabled` | on | Master switch |
| Only run while Gestures15 is enabled | `requireGestures15` | on | Require the Gestures15 condition |
| Status: … | – | live | Tap it for a full report (jailbreak, Gestures15 path, hide state) |
| Tweak name to look for | `gesturesMatch` | `gestures15` | Name or bundle id used for detection |
| Write diagnostic log | `verbose` | off | Log to `/var/mobile/Library/Logs/DisableAssistants.log` |
| Respring to apply changes | – | – | Kills SpringBoard |

Switch changes are pushed to SpringBoard over a Darwin notification, so they
take effect without a respring; a respring is still the safest way to apply
them, and it is required after the first install.

## Files

| File | Role |
| --- | --- |
| `Tweak.x` | `%ctor`, Settings panel hooks, preference-change notification |
| `DASettings.m` | Preference reading, jailbreak + Gestures15 detection, status text, log |
| `DAHiders.m` | Runtime class discovery, hooks, window fallback, shared hook helpers |
|  `Resources/Root.plist` | PreferenceLoader panel layout (installed as `DisableAssistants.bundle`) |
| `Filter.plist` | Injects into SpringBoard, SiriViewService and Settings |
| `DATweak.h` | Shared declarations |
| `release.config.cjs` | semantic-release plugins, version and asset rules |
| `scripts/prepare-release.sh` | Bumps `control` and builds the deb during a release |
| `.github/actions/setup-theos` | Composite action: ldid + Theos + patched SDKs |

## Troubleshooting

* **Status says “waiting for Gestures15”** — the match string does not match any
  installed tweak. Set it to the exact tweak name or bundle id, then respring.
  Enable the log to see the exact reason.
* **Nothing is hidden** — respring once after installing, make sure
  `Hide the Siri (Assistants) UI` is on, and check the log: it prints the number
  of assistant classes that were hooked. Send that log along if you need to
  extend the class matching rules.
