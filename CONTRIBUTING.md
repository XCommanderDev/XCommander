# Contributing to XCommander

Thanks for your interest. XCommander is a tool I'm building for myself first, and I'm figuring out a lot as I go, so the design still changes often. Before you start on anything big, open an issue so we can talk about it. That way you don't spend time on something I'd have to turn down.

## Building

1. Clone the repo and open `XCommander.xcodeproj` in Xcode 27 or later.
2. Set up signing for your own Apple account. Don't edit the project file or `Config/Signing.xcconfig`. Instead, create `Config/Signing.local.xcconfig` (git ignores it):

   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   BUNDLE_ID_PREFIX = com.yourname
   ```

   A free Apple account works. Your Team ID is in Xcode → Settings → Accounts.
3. Run the `XCommander` scheme and grant Accessibility permission when asked.

Why sign at all: macOS ties the Accessibility permission to the app's signature. Without a stable signing identity, you'd have to grant it again after every build.

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). If you add, remove or rename files, edit `project.yml` and run `xcodegen` rather than changing the project in Xcode.

New to the codebase? Start with [ARCHITECTURE.md](ARCHITECTURE.md) and the guides in [docs/](docs/README.md).

## Pull requests

- Keep each pull request focused on one change.
- Run the tests with `swift test`. Logic belongs in `XCommanderCore`, with tests.
- Make sure your pull request doesn't touch `Config/Signing.xcconfig` or the bundle IDs.

## Sign off your commits

XCommander uses the [Developer Certificate of Origin](https://developercertificate.org) (DCO). By signing off a commit, you confirm that you wrote the change, or otherwise have the right to submit it, under the project's license (GPLv3).

Add the sign-off with `git commit -s`. It appends a line like this:

```
Signed-off-by: Your Name <you@example.com>
```

Pull requests with commits that aren't signed off can't be merged.

## Xcode betas

If you're on an Xcode beta and something stopped working, please open an issue with the Xcode version and build number (Xcode → About Xcode) and the output of `swift run xcmdr doctor`. A capture of the beta's menus helps even more: [docs/xcode-upgrades.md](docs/xcode-upgrades.md) explains how to make one.

## Name and icon

Your contributions are under the GPLv3 like the rest of the code. The XCommander name and icon are covered separately; see [TRADEMARKS.md](TRADEMARKS.md).
