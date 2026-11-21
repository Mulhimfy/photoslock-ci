# photoslock-ci

Workflows only, for Photos Lock. The app source is checked out at run time with a read-only deploy key; every output is encrypted before upload, so a run page shows only PASS / FAIL lines and ids.

- `device-test` (inputs `ref`, `checks`: `all`, or `new` for a quicker round of the first run and the newest checks only): builds an x86_64 release APK and drives it on an Android emulator (Maestro + adb): first run, the + menu, import, camera, album delete, a tour of every screen, Share, screen-change stress, the lock screen with fast taps, fullscreen video (Home closes it, the way back is locked), a download in the browser (the vault's save sheet, nothing in the public Download folder; it loads the `test-assets` release's `pl_dl.png`), the reminder (saved, scheduled, posted at 8pm), animation-engine and JS error lines in logcat, crashes and ANRs. One run per ref at a time.
- `ios-check` (input `ref`): a Release build for the iOS simulator, signed ad hoc so the Keychain works (nothing uploaded): the notes cipher (CryptoKit against the JS library, `ci/ios/cipher`, and the module linked), the app runs, Documents (the vault) is excluded from backup, and through Maestro the first run and a secure note saved and opened again after a relaunch (`ci/ios/*.yaml`).
- `apk` (input `ref`): a phone test APK (arm64, debug-signed).
- `eas` (inputs `job`, `ref`, `runtime`, `message`): `update` bundles the JS and publishes it as an OTA update (Android, branch production); `build` starts the production Android build on EAS. Both first check that the commit's Android fingerprint equals `runtime`. `EXPO_TOKEN` is an encrypted secret seen by that one step.

`tool/fetch.sh <run-id> <dest>` downloads a run's sealed output and decrypts it with the local key.
