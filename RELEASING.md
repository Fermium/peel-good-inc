# Releasing Peel Good Inc. (draft)

The app was formerly Labelize. The bundle is now `Peel Good Inc.app`. These stay the same: the executable
`Contents/MacOS/Labelize`, the bundle id `com.fermiumlabs.labelize`, the repo name `peel-good-inc`, the `peelgood` CLI,
and the support/log folders `~/Library/{Application Support,Logs}/Labelize`.

Drafts for copying into the `peelgood` repo (`.github/`, `scripts/`) and a separate
`homebrew-tap` repo. Nothing here has run against real credentials yet.

```
.github/workflows/release.yml   tag v1.2.3 -> build -> sign -> notarize -> DMG/zip -> Release -> bump tap
scripts/release-build.sh        universal build, version injection, Developer ID + hardened runtime
scripts/make-dmg.sh             hdiutil DMG with an /Applications symlink, then signs it
scripts/notarize.sh             notarytool submit --wait (API key), prints the log, staples
scripts/entitlements/*.entitlements   Labelize (none), Share (sandbox), Helper (none)
homebrew-tap/Casks/peel-good-inc.rb  the cask (the workflow rewrites version + sha256)
homebrew-tap/Formula/peelgood.rb optional: the CLI built from source
```

Owner: the `fermium` GitHub org (Fermium Ltd). It is set in
`release.yml` (`TAP_REPO`), in the cask `url`/`homepage`, and in the formula. Commit
`Package.resolved` too, because the SwiftPM cache key hashes it.

## Bundle layout

```
Peel Good Inc.app/Contents/
  MacOS/Labelize            main executable (hardened runtime, not sandboxed)
  MacOS/peel-good-mcp        MCP stdio shim, copied when Package.swift has that product
  Helpers/peelgood          CLI. It can't go in MacOS/: "peelgood" and "Labelize" are the same name on case-insensitive APFS
  PlugIns/LabelizeShare.appex   Share extension (sandboxed, as all app extensions must be)
```

Signing goes from the inside out, without `--deep`: helpers, then the appex, then the app.
Each piece gets its own entitlements, plus `--options runtime --timestamp`. Outside the
sandbox, printing (`lp`, `lpadmin`, CUPS) and a local Hummingbird listener need no
entitlements. `com.apple.security.print` and `network.server` only apply to sandboxed code.

## One-time setup

1. **Apple Developer Program** ($99/yr). The Account Holder creates a **Developer ID
   Application** certificate: Xcode > Settings > Accounts > Manage Certificates > + , or
   developer.apple.com > Certificates.
2. **Export the .p12.** In Keychain Access > My Certificates, right-click
   "Developer ID Application: … (TEAMID)", choose Export, and set a strong password.
   `base64 -i DeveloperID.p12 | pbcopy`
3. **App Store Connect API key** (for notarization). Go to App Store Connect > Users and Access >
   Integrations > App Store Connect API > Team Keys and add a key with the *Developer* role.
   Download `AuthKey_XXXX.p8` (you can only download it once). Note the Key ID and the Issuer ID.
   `base64 -i AuthKey_XXXX.p8 | pbcopy`
4. **Create the tap repo**: a public repo `<owner>/homebrew-tap` containing the files in `homebrew-tap/`
   (`Casks/peel-good-inc.rb`, plus `Formula/peelgood.rb` if wanted) from `homebrew-tap/`. Homebrew maps
   `<owner>/tap` to `github.com/<owner>/homebrew-tap`.
5. **Tap token**: a fine-grained PAT, limited to the repository `<owner>/homebrew-tap`, with
   Permissions > Contents: Read and write. Set it to expire and put a renewal reminder in the calendar.
6. **GitHub secrets** in the `peelgood` repo (Settings > Secrets and variables > Actions):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | base64 of the exported .p12 |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 export password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Fermium LABS … (TEAMID)` (exact `security find-identity` name) |
| `ASC_API_KEY_P8_BASE64` | base64 of `AuthKey_XXXX.p8` |
| `ASC_API_KEY_ID` | Key ID, e.g. `ABC123DEFG` |
| `ASC_API_ISSUER_ID` | Issuer UUID |
| `TAP_GITHUB_TOKEN` | the fine-grained PAT from step 5 |

The workflow generates the temporary keychain's password at random, so it needs no secret.
Optionally, move the secrets into a protected `release` environment that only accepts `v*` tags.

## Cutting a release

```sh
git tag v1.2.3 && git push origin v1.2.3
```

`CFBundleShortVersionString` = `1.2.3` (from the tag); `CFBundleVersion` = the workflow run
number, which always increases. A manual run (`workflow_dispatch`) builds `0.0.0` artifacts
only. Notarization usually takes 1–10 minutes per submission. There are two submissions,
the app zip and then the DMG.

Local dry run without credentials (ad hoc, no notarization):

```sh
VERSION=1.2.3 BUILD_NUMBER=1 scripts/release-build.sh
scripts/make-dmg.sh "build/release/Peel Good Inc.app" build/release/PeelGoodInc-1.2.3.dmg
```

## How users install

```sh
brew install --cask fermium/tap/peel-good-inc   # app + `peelgood` CLI on PATH
brew upgrade --cask peel-good-inc
brew uninstall --zap --cask peel-good-inc            # also removes prefs, logs, app support
```

Without Homebrew, download `PeelGoodInc-x.y.z.dmg` from Releases and drag the app to Applications.
Users who only want the CLI, built from source: `brew install fermium/tap/peelgood`.

## Without an Apple Developer account (fallback)

If the signing secrets are missing, the workflow still builds an **ad hoc** signed DMG/zip,
publishes it as a *pre-release* and skips the tap bump. The UX cost is real:

- Gatekeeper blocks the first launch ("Apple could not verify…"). On macOS 15+ there is no
  right-click > Open bypass any more. Users must open System Settings > Privacy & Security >
  "Open Anyway" and authenticate, or run `xattr -dr com.apple.quarantine "/Applications/Peel Good Inc.app"`.
- Homebrew 5 deprecated `--no-quarantine`, and it has said it will disable casks in its
  official repo that fail Gatekeeper (September 2026). A personal tap can still ship an
  unsigned cask, but it needs a `caveats` block telling users to do the steps above.
  Expect Homebrew to tighten this further.
- Ad hoc signatures change on every build, so TCC permissions (Files and Folders for watched
  folders) may be asked for again after each update.

A fallback cask would add:

```ruby
  caveats <<~EOS
    Peel Good Inc. is not notarized. On first launch, open System Settings > Privacy & Security
    and click "Open Anyway", or run:
      xattr -dr com.apple.quarantine "#{appdir}/Peel Good Inc.app"
  EOS
```
