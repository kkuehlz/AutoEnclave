# AutoEnclave

A macOS menu bar app that keeps your SSH access short-lived without touching
Secretive or the Secure Enclave for every connection.

**Model.** The enclave key in Secretive is a certificate authority. AutoEnclave
generates a throwaway ed25519 key with no passphrase and asks the agent to sign
it once (one Touch ID). Servers trust the CA line in your own
`~/.ssh/authorized_keys`, so the certificate gets you in until it expires.
AutoEnclave then deletes the throwaway key on the session events you choose
(sleep, screen lock, logout, idle…) and mints a fresh one on the events you
choose (login, wake, unlock…).

Nothing on the host is customised beyond one authorized_keys entry, deployed
like any other public key.

## Build

Needs only Command Line Tools (no Xcode).

```sh
make            # builds build/AutoEnclave.app
make run        # builds and launches it
make install    # copies to /Applications and launches (use this for launch-at-login)
```

## First run

1. Click the key icon in the menu bar → **Open AutoEnclave**.
2. **General** tab: pick the Secretive key that acts as the CA from the
   dropdown. With a single key in Secretive this happens automatically.
3. **Certificate** tab: copy the `cert-authority,principals="…" …` line into
   `~/.ssh/authorized_keys` on each host (or into whatever manages your keys),
   and the `IdentityFile` snippet into `~/.ssh/config` for those hosts.
4. **Mint**. Secretive prompts once. (With "mint on launch" enabled this
   already happened when the app started.)

The Certificate tab shows the current state and offers one action at a time:
**Revoke** while a certificate is valid, **Mint** once nothing valid is on disk,
so there is never a second, overlapping key. The menu bar item only shows
status, opens the window, or quits.

## What it does under the hood

Mint:

```sh
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/ephemeral_enclave
SSH_AUTH_SOCK=<secretive socket> ssh-keygen -Us ~/.ssh/secretive-ca.pub -I kkuehler -n kkuehler -V +10h ~/.ssh/ephemeral_enclave.pub
```

Delete: unlinks `~/.ssh/ephemeral_enclave`, `~/.ssh/ephemeral_enclave.pub`, `~/.ssh/ephemeral_enclave-cert.pub`.

Session events used:

| Trigger | Source |
|---|---|
| Sleep / lid close | `NSWorkspace.willSleepNotification` |
| Wake | `NSWorkspace.didWakeNotification` |
| Screen lock / unlock | `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` |
| Screensaver | `com.apple.screensaver.didstart` |
| Logout, restart, shutdown | `NSWorkspace.willPowerOffNotification`, plus the Quit Apple event's reason as a backstop |
| Fast user switch | `NSWorkspace.sessionDidResignActive/BecomeActive` |
| Idle | polled via `CGEventSource.secondsSinceLastEventType` |
| Certificate expiry | timer at the cert's `Valid: to` time |
| Login | app launch, with Launch at Login enabled in Settings → General |

Mint triggers only fire when no valid certificate is on disk, so wake and
unlock don't cause repeated Touch ID prompts.

All settings live in `defaults read xyz.category.autoenclave`.

## ssh config

AutoEnclave keeps one marked block at the top of `~/.ssh/config`:

```
# >>> AutoEnclave managed block: edit in the AutoEnclave app, not here >>>
Host github.com *.devcore4.com
    IdentityFile ~/.ssh/ephemeral_enclave
    IdentitiesOnly yes
# <<< AutoEnclave managed block <<<
```

Set the host patterns in the Certificate tab. ssh takes the first value it
sees for each option, so this block decides the key while every other option
still comes from your own entries below it. The first time the file is touched
a copy is kept at `~/.ssh/config.autoenclave-backup`.

## GitHub (optional)

GitHub does not accept user certificates on personal accounts, so the CA trick
can't apply there. With **General → Use the ephemeral key for GitHub** on,
AutoEnclave:

- adds `github.com` to the managed ssh config block,
- checks that `gh` can manage keys, and if not runs
  `gh auth refresh -h github.com -s admin:public_key` for you, showing the
  one-time code to paste into the browser page it opens,
- adds the throwaway public key to your account on every mint and removes it
  on revoke. Stale keys from an earlier day are swept on the next mint or launch.

AutoEnclave checks your existing config before writing: any Host, Match or
global entry whose patterns cover a managed host and that sets IdentityFile,
IdentitiesOnly, IdentityAgent or CertificateFile is listed with its file and
line, and the block is only written after an explicit "Apply anyway".
Include directives are followed.

## Tests

```sh
make test   # parser and conflict-detection checks (plain executable, no XCTest needed)
```
