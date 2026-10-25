# Security policy

## Supported versions

Only the latest release is supported; fixes ship as a new release.

## Scope

InkSweep runs as your user (never root) and its whole job is deciding what to
delete, so these are the areas we care most about:

- **Deletion safety.** Every regular clean moves files to the Trash; emptying
  the Trash and the Shredder are the only irreversible actions, each behind an
  explicit confirmation. Reports that a category removes something it should
  not, or that sizes/counts shown differ from what a clean actually does, are
  especially welcome.
- **Protected locations.** A curated protection list keeps Apple namespaces,
  password managers, EDR agents and stateful "cache" names out of findings.
  False positives are treated as security issues.
- **Full Disk Access** is optional and only widens coverage (Trash, Safari
  data); InkSweep works without it and says so.
- **Smart Care** installs a per-user LaunchAgent (`~/Library/LaunchAgents/
  com.amosw.inksweep.smartcare.plist`) that runs the bundled `inksweep` CLI
  once a day for a scan-only report. It never deletes anything.
- **Network.** The only network use is the Updater: it reads apps'
  SUFeedURL appcasts over HTTPS and verifies a SHA-256 digest (from the feed
  or the release page) before replacing an app, with the old version going to
  the Trash. There is no telemetry, no account and no other request.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately instead:
on GitHub, open the **Security** tab of this repository and choose **Report a vulnerability**.

Please include as much as you can:

- the affected version or commit
- your macOS version and Mac model
- steps to reproduce, or a proof of concept
- what an attacker could do with it
- any ideas for a fix

## Response

- New reports are acknowledged within 72 hours.
- A first assessment follows within 7 days.
- Once a fix is out, we agree on a disclosure timeline with the reporter.
