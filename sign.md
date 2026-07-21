# Signing and notarizing a release

Codex Status Dashboard is distributed directly rather than through the Mac App
Store. The build script always signs the completed bundle so its code and
resources pass macOS integrity checks. Without configuration it uses an ad-hoc
signature suitable for local development. A public release should use a
Developer ID Application certificate and Apple notarization.

## Requirements

- macOS 13 or later and current Xcode command-line tools
- An Apple Developer Program membership
- A **Developer ID Application** certificate installed in the login keychain
- `librsvg` for generating the icon (`brew install librsvg`)
- Notary credentials stored in the keychain using `notarytool`

List available signing identities:

```sh
security find-identity -v -p codesigning
```

The desired entry normally looks like:

```text
Developer ID Application: Your Name (TEAMID)
```

## Store notarization credentials once

Choose a local profile name, then have `notarytool` store the credentials in
your keychain. The password is an app-specific password from your Apple ID:

```sh
xcrun notarytool store-credentials "codex-status-dashboard-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "APP-SPECIFIC-PASSWORD"
```

The secret remains in the macOS keychain; it does not go in this repository or
an environment variable.

## Build a signed universal app

Set the certificate name for this shell invocation:

```sh
DASHBOARD_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  zsh scripts/build-app.sh
```

The script builds both `arm64` and `x86_64`, combines each executable with
`lipo`, enables hardened runtime, signs the nested helper first and the complete
app second, and runs strict signature verification.

For an ad-hoc local build, omit `DASHBOARD_SIGN_IDENTITY`:

```sh
zsh scripts/build-app.sh
```

An ad-hoc signature verifies bundle integrity but does not identify a trusted
developer and cannot be notarized.

## Notarize and create the release ZIP

The release script rebuilds with the Developer ID identity, submits a ZIP to
Apple, waits for the result, staples the ticket to the app, validates it with
Gatekeeper, then creates the final ZIP and prints its SHA-256 checksum:

```sh
DASHBOARD_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
DASHBOARD_NOTARY_PROFILE="codex-status-dashboard-notary" \
  zsh scripts/notarize-release.sh
```

The finished artifact is written to `.build/releases/` and named from
`CFBundleShortVersionString`, for example
`Codex-Status-Dashboard-0.3.0.zip`.

If notarization fails, inspect the submission log using the submission ID shown
by `notarytool`:

```sh
xcrun notarytool log SUBMISSION-ID \
  --keychain-profile "codex-status-dashboard-notary"
```

Do not publish an archive until all of these pass:

```sh
codesign --verify --deep --strict --verbose=2 \
  ".build/Codex Status Dashboard.app"
spctl --assess --type execute --verbose=4 \
  ".build/Codex Status Dashboard.app"
xcrun stapler validate ".build/Codex Status Dashboard.app"
```

Create a stable GitHub Release whose tag matches the plist version (for
example, `v0.3.0`), attach the final ZIP from `.build/releases/`, and include
its printed SHA-256 checksum in the release notes. Drafts and prereleases are
not returned by the app's manual update check.

## Apple references

- [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
