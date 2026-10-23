# Fixed signing verification — 2026-10-23

- Created the fixed signing identity in the release machine's login keychain;
  user trust is limited to the code-signing policy. No private key is in the repo.
- `bash -n build.sh` and `git diff --check` passed.
- Missing-identity self-check passed: the build exits before running Swift or
  creating an output app. No ad-hoc fallback is used.
- Two isolated release builds passed signature and pinned-requirement checks.
  The second changes the permission diagnostic message and bundle build number
  to simulate a real binary update. Their executable SHA-256 hashes differ:
  - First: `e9fefc1aad9e8fd670d199d1e49cf492c2c2d6aab32dbdc8c77f01fbd65a491b`
  - Second: `c679f55cf5488bb1a44ea89ec66fd45afce65d61e6fbac68827cd849c3f1cbb5`
- CDHashes differ, but both designated requirements are identical:

  ```text
  identifier "local.clipshelf.app" and certificate leaf = H"e6124ab6c7079d7f1e764992ca61167210660010"
  ```

- First build installed at `/Applications/ClipShelf.app`; previous app backed up
  at `/private/tmp/clipshelf-fixed-signing/previous-installed.app`. User data was
  not removed.
- Direct shell execution reported granted, but an independent LaunchServices
  launch reported **not granted**. The direct shell result is not valid evidence
  of the application's own authorization.
- User granted the first build permission. An independent LaunchServices check
  then reported `Accessibility: granted`.
- Replaced the installed app with the second build without changing permissions.
  Its independent LaunchServices check reported
  `Accessibility: granted (update verification build)` (bundle build 27).
- Restored the first build (the actual repository code, without the experimental
  diagnostic wording); an independent check again reported `Accessibility: granted`.
  The installed app now uses the fixed certificate.
- **Result:** permission was retained across two replacements on this Mac, including
  a changed executable. Actual pasting into another application and retention on
  other Macs/macOS versions were not tested.
- No GitHub release or Homebrew cask was changed for this experiment.
