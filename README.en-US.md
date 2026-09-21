# Qiehao

[简体中文](README.md) | [English](README.en-US.md)

Qiehao is a local account switcher for Codex Desktop on Windows. It provides a bilingual WPF interface and treats two rules as hard safety boundaries: every switch is initiated by the user, and authentication state is not changed until Codex has completely exited.

> [!IMPORTANT]
> Qiehao is an unofficial community tool. It is not an official OpenAI product. It manages only local Codex Desktop authentication state and does not modify ChatGPT Web, browser, or PWA sessions.

## First things first: Qiehao is not a reverse proxy

Qiehao is **not a reverse-proxy tool, and it is not intended to become one.**

No proxying, no multi-account polling, and no quota pool.

It does not proxy Codex or API traffic, forward requests for users, maintain an account pool, automatically rotate accounts, switch accounts based on quota, or jump to another account after an HTTP 429 response.

If you are looking for a reverse proxy, unattended account farming, a background account pool, or automatic account rotation, this project is simply not built for that.

Qiehao exists to make switching between accounts that I already sign into and use normally less painful.

## Why I built Qiehao

The reason I built Qiehao is actually very simple:

**I got tired of staring at login pages spinning when all I wanted to do was switch accounts.**

Sometimes I just wanted to move to another account I already use normally, but that meant signing out, signing in again, waiting for OAuth, and then waiting again for Codex to recognize the account. When the network or login flow was having a bad day, the spinner could sit there for a very long time.

Doing that once in a while is tolerable. Doing it repeatedly between several accounts I legitimately use gets annoying very quickly.

So the original idea was never to bypass login. It was almost the opposite:

**sign in normally through the official flow the first time, then safely preserve that already-authenticated local state and switch back to it later when I choose to.**

That is why Qiehao keeps several rules:

- new accounts still use the official Codex OAuth flow;
- no login emulation;
- no browser-cookie scraping;
- no control over ChatGPT Web/PWA sessions;
- no reverse proxy;
- no automatic account pool;
- no background polling across multiple accounts;
- every switch is explicitly triggered by the user;
- authentication files are not changed until Codex has really exited.

In plain terms:

**Qiehao is not here to run a pool of accounts. It is here so I do not have to stare at a login spinner every time I switch between accounts I already use normally.**

## How I want Qiehao to be used

My own view is pretty simple:

**if I can use the platform normally and conservatively, I would rather do that. The goal is long-term stability.**

That is why Qiehao does not poll multiple accounts in the background, switch automatically when quota changes, rotate after HTTP 429 responses, or run an unattended account pool.

If an official login flow is available, use the official login flow. If Codex already exposes an interface that can do the job, use that interface. If a request does not need to be made, do not make it. If something does not need to be automated, I would rather click it myself.

I also hope that this conservative style of use means fewer unnecessary risk-control events, fewer of the model-quality changes that users sometimes casually call “getting dumber,” and a lower chance of account restrictions or suspension.

That is only my usage philosophy and hope. It is not a platform promise, and Qiehao cannot guarantee that an account will never be risk-controlled, limited, experience model-quality degradation, or be suspended.

Platform rules, risk controls, and model behavior are outside Qiehao's control.

What Qiehao can do is avoid adding unnecessary high-frequency polling, automatic rotation, unusual request patterns, and excessive automation.

**I am not trying to game the system. I am trying to use it normally and make account switching less annoying.**

## Project scope

- Codex Desktop only; no automatic account rotation.
- No access to browser cookies, LocalStorage, IndexedDB, or other browser session data.
- No modification or sign-out of ChatGPT Web/PWA sessions.
- No quota-triggered, HTTP 429-triggered, or error-triggered account switching.
- No round-robin or background switching.
- Every account switch must be explicitly initiated by the user.

## How it works

When a new account is added, the user still signs in manually through the official Codex OAuth flow. After Codex has completely exited, Qiehao stores the account's local authentication state in an encrypted snapshot protected by Windows DPAPI CurrentUser.

For a later switch, Qiehao requires Codex Desktop to exit completely. It then safely snapshots the current account, verifies the target account, atomically replaces the local Codex authentication file, rereads and verifies the written data, and finally updates the local Active Profile state. Qiehao does not automate OAuth, forcibly terminate Codex, or touch browser login state.

## Safety design

- **Manual-only switching**: every switch starts with an explicit user action.
- **DPAPI CurrentUser**: authentication snapshots and identity markers are protected in the current Windows user's scope.
- **Atomic replace**: critical files use same-volume temporary files and atomic replacement to avoid partial writes.
- **Reread verification**: the replaced data is read back and compared byte for byte.
- **Rollback**: if post-write verification or state commit fails, Qiehao attempts to restore the original active account.
- **Named mutex**: write operations are serialized so that multiple instances cannot change authentication state concurrently.
- **Process gate**: authentication writes are allowed only after Codex is confirmed to have completely exited.
- **Unknown fail closed**: if process or authentication state cannot be determined reliably, Qiehao stops instead of guessing.
- **No forced kill**: users exit Codex normally through its official menu or system tray.
- **Browser/PWA untouched**: Qiehao does not read or modify browser session data.

DPAPI CurrentUser primarily protects authentication snapshots at rest so they are not stored as plaintext. It does not defend against malicious software that is already running as the same Windows user. It is not a claim that the data is absolutely secure, impossible to decrypt, or impossible to steal.

## Quota Snapshot

Quota Snapshot asks the Codex app-server for the current Active Profile's quota information:

- only the current Active Profile is queried on demand;
- inactive profiles show only their last successful cached snapshot;
- there is no continuous polling or real-time quota monitoring;
- a failed query preserves the old snapshot and does not invent a new timestamp;
- a snapshot represents the last successful query and is not guaranteed to be current;
- quota failure never triggers an automatic account switch.

### About quota refresh speed

There is one part of Qiehao that can sometimes feel less pleasant:

**quota refresh can be slow.**

Qiehao does not scrape a web page and does not run its own private quota service. It asks the Codex app-server for the active account's quota snapshot.

That makes quota refresh a best-effort operation:

**if the data is available, Qiehao shows it; if it is not, Qiehao keeps the previous successful snapshot. It is not guaranteed to return instantly every time you click Refresh.**

Sometimes the Codex app-server takes longer to start. Sometimes the quota response takes longer to arrive. Sometimes it times out. I know that is not as satisfying as clicking a button and getting an instant result.

But I do not want to make the UI look faster by falling back to:

- scraping login or account web pages;
- reading browser cookies;
- continuously polling in the background;
- probing several accounts at once;
- using a third-party private quota endpoint;
- automatically switching accounts because quota did not return.

So I would rather accept that this feature can occasionally be slow.

When a refresh fails, Qiehao keeps the last successful snapshot whenever possible and lets the user retry manually later.

That is why the feature is called **Quota Snapshot**, not **real-time quota monitoring**.

One more important distinction:

**a slow or failed quota refresh does not mean account switching failed.**

Quota refresh and account switching are separate operations. My tradeoff is simple:

**account switching prioritizes safety and correctness; quota refresh is allowed to be slower and occasionally fail.**

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 for normal use (included with Windows)
- Codex Desktop

PowerShell 7 is used only for compatibility and development testing. Regular users do not need to install it to run Qiehao. The current version supports Windows only, not macOS.

## Starting Qiehao

For normal use, double-click this file in the repository or fully extracted ZIP directory:

~~~text
Start-Qiehao.bat
~~~

`Start-Qiehao.cmd` remains available. You can also start Qiehao manually from the root directory:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\gui\QiehaoGui.ps1"
~~~

`ExecutionPolicy Bypass` applies only to that PowerShell process. It does not permanently change the system execution policy, write to the registry, or require administrator privileges.

## Usage

1. Start Qiehao.
2. Sign in through the official Codex login flow.
3. Follow the UI to add a local profile.
4. When you want to switch, select the target profile and click the switch button.
5. Exit Codex normally through its official menu or system tray when prompted.
6. Qiehao performs the safe switch only after it detects that Codex has completely exited.
7. Start Codex again manually after the switch completes.

Closing the main Codex window is not necessarily the same as exiting it; Codex may still be running in the system tray. Qiehao does not treat force-killing Codex in Task Manager as the normal workflow.

## Themes and languages

The UI supports zh-CN and en-US and includes seven themes:

1. 01 Tech Blue
2. 02 Navy Gold
3. 03 Ice Glass
4. 04 Purple Nebula
5. 05 Light Flow
6. 06 Aurora Silver Blue
7. 07 Arctic Sea Glass

Themes change only the visual presentation. They do not change account data, authentication protection, process gates, or switching behavior.

## Privacy

- **Local-first**: profiles, state, and quota cache stay in the local runtime directory.
- **Browser/PWA untouched**: browser session data is neither read nor modified.
- No telemetry or analytics are included.
- This project does not operate a relay server.
- Inactive accounts are not queried for quota.
- `profiles/`, `state/`, `logs/`, `backup/`, `auth.json`, DPAPI containers, and quota cache must never be committed to Git.

Protect your Windows account, Codex login, and local computer. Never paste authentication files, tokens, email addresses, account IDs, cookies, or logs containing credentials into a public issue.

## Command-line entry point

`qiehao.ps1` provides safe backend commands such as:

~~~powershell
.\qiehao.ps1 status
.\qiehao.ps1 list
.\qiehao.ps1 active
.\qiehao.ps1 verify-profile ExampleProfile
~~~

Commands that save, add, rename, delete, or switch profiles have additional process gates, identity checks, and confirmation requirements. The GUI is recommended for regular use.

## Development

The project is tested under both Windows PowerShell 5.1 and PowerShell 7. Core self-tests in `tests/` include:

- `SelfTest.ps1`
- `GuiSelfTest.ps1`
- `VisualPolishSelfTest.ps1`
- `AccountGridLayoutSelfTest.ps1`
- `LocalizationSelfTest.ps1`
- Quota and Switch-before-Quota test suites
- `LauncherSelfTest.ps1`

All automated tests use fake-only data or hidden/offscreen WPF. Development and CI must not read real authentication profiles or send real quota requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing and [SECURITY.md](SECURITY.md) before reporting a security issue.

## v1.0.0 status

Qiehao v1.0.0 is the first public release. It is still being validated across more real Windows environments.

There is no Windows EXE or installer yet. For the first release, keeping the PowerShell source and launchers transparent and simple makes the code easier to inspect and feedback easier to act on. An EXE or installer can be evaluated later based on real user feedback.

## Risk and license

Qiehao changes local Codex authentication state. Verify the source before use and keep your environment recoverable. Codex local file formats or behavior may change in the future; when Qiehao encounters an unknown structure, it should fail closed rather than guess.

This project is licensed under the [MIT License](LICENSE), Copyright (c) 2026 ZCT. The root `LICENSE` file contains the complete terms.
