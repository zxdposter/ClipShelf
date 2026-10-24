# Release signing

`./build.sh` signs with the fixed **ClipShelf Release Signing** identity and
verifies the signature. It stops before building if that identity is unavailable;
there is no ad-hoc fallback.

The script builds `arm64` and `x86_64` separately, verifies both slices in the
combined Universal executable, then signs the complete app with this identity.
For architecture-specific release packages, pass `arm64` or `x86_64` as the
second argument to `build.sh`; each complete app is signed separately.
Do not merge or replace executable slices after signing; doing so invalidates
the signature.

- Certificate SHA-1: `E6124AB6C7079D7F1E764992CA61167210660010`
- Bundle identifier: `local.clipshelf.app`
- Certificate expires: 2036-10-20 UTC
- `ClipShelf-Release.cer` is the public certificate only. The private key is in
  the release machine's login keychain and must never be committed or uploaded.

All updates must use this certificate and bundle identifier. The designated
requirement pins both, so code changes do not change the application's identity.
Back up the certificate **with its private key** as a password-protected `.p12`
using Keychain Access and store it securely outside this repository. Import that
same identity on any future release machine; creating another certificate with
the same name does not preserve identity. Do not revoke/delete the existing key
or replace the certificate as part of routine releases.

Users must grant device control/accessibility once when switching from the old
ad-hoc builds. Self-signing does not provide Apple notarization or remove
Gatekeeper warnings. Do not ask end users to install this signing certificate.

## Verify an update

1. Build and install the first fixed-signature app at `/Applications/ClipShelf.app`.
2. Launch it and grant device control/accessibility in System Settings.
3. Run this through LaunchServices so the check is attributed to ClipShelf,
   rather than inheriting the terminal's permission:

   ```sh
   open -n -g --stdout /tmp/clipshelf-accessibility.txt \
     /Applications/ClipShelf.app --args --check-accessibility
   ```

   Once the check has exited, `/tmp/clipshelf-accessibility.txt` must contain
   `Accessibility: granted`. Directly executing the binary from a terminal can
   report the terminal's permission and is not a valid independent check.
4. Install a changed build signed with the same identity at the same path.
5. Run the same LaunchServices check again and test pasting into another app. Both builds must
   report granted without changing the permission in System Settings.

Use `codesign -dr - /Applications/ClipShelf.app` to compare designated requirements
and `codesign -dv --verbose=4 /Applications/ClipShelf.app` to compare CDHashes.
The requirements should match while the CDHashes differ. Matching requirements
alone does not prove that macOS retained the user's permission.
