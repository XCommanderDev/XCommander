# Contributing to XCommander

Thanks for your interest. XCommander is a tool I'm building for myself first, and I'm figuring out a lot as I go, so the design still changes often. Before you start on anything big, open an issue so we can talk about it. That way you don't spend time on something I'd have to turn down.

## Building

1. Clone the repo and open `XCommander/XCommander.xcodeproj` in a recent Xcode.
2. Set up signing for your own Apple account. Don't edit the project file or `Config/Signing.xcconfig`. Instead, create `XCommander/Config/Signing.local.xcconfig` (git ignores it):

   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   BUNDLE_ID_PREFIX = com.yourname
   ```

   A free Apple account works. Your Team ID is in Xcode → Settings → Accounts.
3. Run the `XCommander` scheme and grant Accessibility permission when asked.

Why sign at all: macOS ties the Accessibility permission to the app's signature. Without a stable signing identity, you'd have to grant it again after every build.

## Pull requests

- Keep each pull request focused on one change.
- Run the tests (`⌘U` in Xcode).
- Make sure your pull request doesn't touch `Config/Signing.xcconfig` or the bundle IDs.

## Sign off your commits

XCommander uses the [Developer Certificate of Origin](https://developercertificate.org) (DCO). By signing off a commit, you confirm that you wrote the change, or otherwise have the right to submit it, under the project's license (GPLv3).

Add the sign-off with `git commit -s`. It appends a line like this:

```
Signed-off-by: Your Name <you@example.com>
```

Pull requests with commits that aren't signed off can't be merged.

## Name and icon

Your contributions are under the GPLv3 like the rest of the code. The XCommander name and icon are covered separately; see [TRADEMARKS.md](TRADEMARKS.md).
