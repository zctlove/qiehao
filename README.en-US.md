# Qiehao

[简体中文](README.md) | [English](README.en-US.md)

Qiehao is a local multi-account manager for Codex Desktop on Windows. Your local project files remain available as you switch accounts, and the convenience is clearer when managing three or more accounts. Every switch is initiated by the user, and authentication state changes only after Codex has completely exited.

It supports local profiles and switching for accounts such as Plus and Team. If the official account-switching option you use provides only two account slots, Qiehao is useful for keeping three or more saved profiles while continuing to use project files on the same computer at the same paths. This comparison does not describe two accounts as a permanent limit of every official client version.

**Local project continuity means that files on disk remain available at their existing paths.** Qiehao does not synchronize official chat histories, project metadata, or Memory between accounts, and does not merge their cloud data.

> [!IMPORTANT]
> Qiehao is an unofficial community tool. It is not an official OpenAI product. It manages only local Codex Desktop authentication state and does not modify ChatGPT Web, browser, or PWA sessions.

> [!NOTE]
> **Latest official release: Qiehao v1.1.1 (2026-11-02).** This version includes read-only identity inspection after OAuth failure, explicit confirmation before saving a new profile, controlled Team recovery, and identity-bound quota caches. Download the official Windows ZIP from GitHub Releases and verify SHA-256; `Code → Download ZIP` is a source snapshot, not the official application package. Occasional Codex Desktop signed-out states and rejected official OAuth completion notifications remain known limitations.

## Usage reminders

1. Exit Codex Desktop normally before switching accounts, including its background client processes.
2. Profile deletion is protected while Codex is running. Do not force-kill processes to bypass a warning.
3. Successful OAuth does not prove that a local profile was saved. Check Qiehao's final result and account list.
4. Read-only identity inspection does not save an account automatically. A new profile requires identity verification and a separate confirmation.
5. A failed quota query is not a successful refresh. Retained historical numbers are not the result of that failed query.
6. Historical cache ownership marked unverified means that its saved-profile owner cannot be confirmed, not that quota has never been retrieved.
7. A legacy cache becomes a trusted snapshot only after a successful refresh for the current account establishes a new identity binding.
8. If Codex temporarily shows signed out at startup, wait for initialization. If it persists, fully exit and reopen the client, then inspect redacted logs if needed. Do not switch repeatedly or manually copy `auth.json`. An explicit “Do not start Codex / manual inspection required” warning takes priority.

## Product Preview

![Qiehao Arctic Sea Glass theme preview](docs/screenshots/qiehao-preview-arctic-sea-glass.jpg)

This is a real running view of one of Qiehao's current interface themes, showing local account management, active-account status, quota snapshots, and the bilingual multi-theme UI.

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

In v1.1.1, Qiehao delegates account addition to the official Codex app-server ChatGPT browser OAuth flow. The user completes sign-in on the official page. After identity verification, Qiehao stores the original authentication bytes in an encrypted snapshot protected by Windows DPAPI CurrentUser. Unsupported protocols explicitly offer the original manual-import workflow.

For a later switch, Qiehao requires Codex Desktop to exit completely. It then safely snapshots the current account, verifies the target account, atomically replaces the local Codex authentication file, rereads and verifies the written data, and updates the local Active Profile state. Local switching and official verification are reported separately. Qiehao does not fill in sign-in credentials, implement its own OAuth login API, forcibly terminate Codex, or touch browser login state.

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

Qiehao does not store account passwords, scrape browser cookies, reverse-engineer OAuth, or use the internal-only `chatgptAuthTokens` mode. Normal sign-in delegates to official Codex Managed ChatGPT OAuth. It does not upload profiles, state, or authentication files, and diagnostic logs do not contain tokens, email addresses, full account IDs, or JWTs.

## Quota Snapshot

Quota Snapshot uses the official Codex app-server `account/rateLimits/read` interface for the current Active Profile. It is a best-effort auxiliary feature dependent on the official interface and network conditions. Requests may time out, temporarily fail, or return only some quota windows:

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

Quota retrieval is an auxiliary feature and does not block account add, switch, or delete operations.

If quota retrieval fails, select Refresh Quota to try again.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 for normal use (included with Windows)
- Codex Desktop

PowerShell 7 is used only for compatibility and development testing. Regular users do not need to install it to run Qiehao. The current version supports Windows only, not macOS.

## Download

Latest published release:

**[Qiehao v1.1.1](https://github.com/zctlove/qiehao/releases/tag/v1.1.1)**

The official Windows ZIP contains this version's program and runtime dependencies, with no user account profiles or runtime data. Do not treat the repository source ZIP as the official application package.

[Download Windows ZIP](https://github.com/zctlove/qiehao/releases/download/v1.1.1/Qiehao-v1.1.1-Windows.zip) · [SHA256 checksum file](https://github.com/zctlove/qiehao/releases/download/v1.1.1/Qiehao-v1.1.1-SHA256.txt)

New users should download the latest version.

Previous releases are kept for version history and troubleshooting purposes. New users should use the latest release.

## Download, install, and start

Regular users should download the latest Qiehao Release ZIP from GitHub Releases:

1. Download the latest Release ZIP.
2. Fully extract the ZIP to a local directory where your Windows user has write access.
3. Do not run Qiehao directly inside the ZIP archive.
4. Regular users should double-click this file only from the root of the fully extracted official Windows Release ZIP:

~~~text
Qiehao.exe
~~~

The recommended entry is `Qiehao.exe`, a Windows GUI launcher that normally does not display a console window. This thin launcher invokes system Windows PowerShell 5.1; scripts and modules remain separate.

**Regular users must not launch `Qiehao.exe` from the source-code repository or treat GitHub's `Code → Download ZIP` snapshot as a runnable package.** The source repository is for development and version control only. Qiehao may create local `profiles/`, `state/`, `logs/`, and `backup/` directories beside the application. `.gitignore` keeps these files out of Git tracking; it does not prevent them from being written to disk.

If the EXE cannot start, use `Start-Qiehao.cmd` as the compatibility/troubleshooting entry. Both entries ultimately run the same Qiehao program logic.

`Qiehao.exe` is currently not commercially code-signed. Verify the GitHub Release source and check the included SHA256 file for integrity. A checksum is not a digital signature.

Qiehao does not require administrator privileges, Node.js, Python, Visual Studio, or third-party PowerShell modules.

Regular users do not need to run the following PowerShell command. It is only for advanced troubleshooting:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\gui\QiehaoGui.ps1"
~~~

`ExecutionPolicy Bypass` applies only to that PowerShell process. It does not permanently change the system execution policy, write to the registry, or require administrator privileges.

## Usage

> ⚠ **First-time Team / Workspace account addition:**
>
> Start the official OAuth flow from Qiehao's Add Account action, and confirm that the intended Team workspace is selected on the official sign-in page.
>
> Do not infer workspace identity from an email address, display name, or a Plus / Team plan label alone. If the Team / Personal context cannot be verified reliably, Qiehao will not save it as a verified account; follow the UI guidance and sign in again through the official flow.

For both first and subsequent account additions in v1.1.1, prefer the official browser flow:

1. Completely exit Codex Desktop.
2. Open Qiehao and click Add Account.
3. Qiehao requests ChatGPT OAuth through the official Codex app-server. Your default browser opens the official sign-in page.
4. Complete sign-in for the target account in the browser. Press Esc to cancel while waiting.
5. After identity verification, enter a local name. Addition completes only after the credentials are securely saved.

Official sign-in and identity reads may take time. The v1.1.1 login budget is up to about 180 seconds, depending on network and service response. Do not repeatedly click Add Account or run multiple Qiehao instances in parallel. If it times out, follow the OAuth recovery guidance below; do not assume the authorization remained unchanged.

You generally do not need to start Codex Desktop to sign in first. Repeat this flow for subsequent accounts and select the intended account in the browser. New credentials are never written into the previous Active Profile.

If the installed Codex version does not support Managed Login, the official protocol is incompatible, or direct OAuth addition is temporarily unavailable, follow Qiehao's instructions for the legacy workflow: sign in or switch to the target account using the official Codex Desktop flow, confirm success, completely exit the client, then return to Qiehao to add it. The previous account is never silently imported as a new account. The new OAuth path is not guaranteed to remain available forever.

Team / Workspace accounts can be saved and used normally when direct OAuth addition identifies their workspace correctly. Keep the first-add warning above; current real-user acceptance is not a promise that future workspace selection will never change.

“Exit Codex” means closing the Codex client, including any process still running in the system tray. It does not mean signing out of the account. Each account only needs to be added once; later switching between saved accounts does not require repeating OAuth sign-in.

Closing the main Codex window is not necessarily the same as exiting it; Codex may still be running in the system tray. Qiehao does not treat force-killing Codex in Task Manager as the normal workflow.

## Account identity and recovery (important)

Qiehao checks three separate things: **the saved local account profile**, **Qiehao's active-profile record**, and **the identity actually loaded by Codex**. They are not interchangeable. A display name, email address, or old quota number is not sufficient proof that they match. When a mismatch is detected, the application should stop the affected write or quota query rather than guess, overwrite a profile, or rotate accounts automatically.

### Official OAuth reports failure, but the sign-in state may have changed

A rejected OAuth completion notification, timeout, or read failure **does not necessarily mean the current Codex authorization remained unchanged**. If the current build offers “Check identity after sign-in failure,” follow this sequence:

1. Exit Codex Desktop normally and confirm that it has fully exited. Do not merely close the main window or force-kill the process.
2. Only if Qiehao explicitly offers it, select “Check current identity (read-only).” This checks the actual current identity; it does not immediately create a profile or write the current credentials into an existing profile.
3. If the identity is reliably verified and is not already saved, Qiehao will ask for a local name and a separate confirmation to “Save new profile.” This creates a separate profile and does not overwrite existing profiles. If the identity is already saved, no duplicate is created.
4. If the identity cannot be verified, authorization changes after inspection, or the check expires, Qiehao will not save a new profile. Follow the UI guidance to sign in again through the official flow. Do not manually edit or copy auth.json, and do not delete profiles/ or state/.

This fallback path does not require you to force-sync Qiehao's active-profile record before adding a new account; **it does not bypass identity verification**. A successful browser page does not mean Qiehao saved the account. Trust Qiehao's final result and profile list.

### Current Codex identity differs from the active profile: the Plus / Team recovery case

If Qiehao confirms that the current Codex sign-in is Personal Plus while the active profile is a valid, identity-verified Team profile, it may offer “Restore saved Team sign-in.” This is a **narrowly scoped recovery from confirmed Personal Plus to a saved Team profile**, not a general identity-repair button.

- Read the confirmation carefully: confirming replaces the current Codex Plus sign-in with the saved Team credentials. It does not delete or rewrite the saved Team profile.
- If the current Plus sign-in has not been saved as a separate profile, you may need to sign in to Plus again through official OAuth afterward. If you need to keep the current Plus sign-in, cancel; do not confirm the replacement.
- If the current identity, Team workspace, target-profile integrity, or Codex exit state does not meet the required conditions, recovery stops. Do not try to bypass the prompt.
- If the result says the local Team switch was committed but official identity remains unverified, that means the local credentials and active record were committed; **it does not mean official sign-in verification succeeded**. Recheck the actual identity and do not repeat the switch rapidly.
- If the message explicitly says “Do not start Codex” or “manual inspection required,” follow it: do not launch Codex, repeat add/switch/recovery, or edit authentication files manually.

### Quota shows old data or reports an identity mismatch

Quota is an identity-bound snapshot, not proof of account identity and not real-time monitoring:

- “The current sign-in differs from the active profile. Quota queries are paused.” means identity verification did not pass and quota requests were paused. Resolve the identity mismatch first; do not treat an old number as the current account's quota.
- “Legacy quota cache ownership unverified” or “Historical cache” means an older cache lacks sufficient identity-binding evidence. It may be retained for historical reference, but it cannot establish the current account's plan or remaining quota. Qiehao will not silently reassign an old cache to another account.
- “The service responded, but returned no displayable quota” does not mean the remaining quota is zero. The official interface may not have returned a displayable quota window.

After the identity is reconciled and verified, manually refresh quota for the current account. A quota issue does not mean an account profile was overwritten and is not a reason to switch accounts repeatedly.

## FAQ

### What should I do if Qiehao says Codex is still running?

If the Codex client was just closed, Windows may need a short time to release its background processes.

During that interval, Qiehao may report that Codex is still running.

Wait briefly, then try the switch or delete operation again.

To avoid Windows process-state refresh delays affecting the result, do not rapidly switch between several accounts in a short period.

Wait until the current switch is complete and the client state is stable before starting another switch.

### What if Windows Sandbox Service keeps running?

Newer Codex Windows versions may keep `codex-windows-sandbox-service.exe` running. v1.1.1 strictly validates official persistent Sandbox Services; a confirmed trusted service alone does not block account operations. You normally do not need to terminate it, disable it, or change Windows service settings. Actual Codex Desktop or external Codex execution processes still safely block account operations. Uncertain classification continues to fail closed.

### What does a locally switched but unverified account mean?

After committing the local Profile switch, Qiehao attempts official sign-in verification through `account/read`. It reports switch success only after verification succeeds. A temporary network or official-interface timeout shows "Local account switched; sign-in status could not be verified yet." This does not mean the local switch failed. You may start Codex normally to check, or select Verify later. A genuine identity mismatch still follows the safe rollback policy.

### What if Codex Desktop shows signed out after reopening?

This remains a known limitation to monitor: Codex Desktop may occasionally show signed out after reopening, and the official OAuth completion notification may still be rejected. The current source fixes improve read-only identity inspection and explicit saving after a reported failure, but **they do not guarantee that all Codex Desktop sign-in issues are eliminated or that the official service will accept every sign-in state**.

Check Qiehao's final result first. A saved local profile, a committed local switch, and verified official identity are different states. Wait for client initialization; if it continues to show signed out, fully exit normally and reopen it. Do not repeatedly add or switch accounts, delete saved profiles or authentication files, or manually copy auth.json. If needed, fully exit and use the Verify entry when offered, and inspect or share only redacted logs, safe messages, and error codes. Never attach real credentials. An explicit “Do not start Codex / manual inspection required” warning takes priority.

### What if Qiehao closes unexpectedly during add or switch?

The window disappearing does not prove that the operation succeeded or failed. Reopen Qiehao and first inspect the profile list, active-profile record, and UI status. Do not repeat add or switch operations rapidly before the state is clear. If you previously saw “Do not start Codex / manual inspection required,” do not launch Codex. Preserve local profiles/, state/, logs/, and backup/; they may contain data needed for recovery, but must not be uploaded to a public issue.

### When must I stop and wait for manual inspection?

If Qiehao explicitly says “Do not start Codex; manual inspection required,” do not launch Codex or repeat add, switch, recovery, or delete operations. Do not replace auth.json manually, and do not delete or rename files under profiles/ or state/. Preserve the current state and share only redacted message text and safe error codes through a private, secure channel. Never publicly upload real tokens, email addresses, account IDs, cookies, authentication files, or complete logs.

## Updating

Regular users should update with the latest GitHub Releases ZIP. These steps cover upgrading from v1.0.3 or v1.1.0 to v1.1.1:

1. Completely exit both Qiehao and Codex Desktop.
2. Download the v1.1.1 Release ZIP and verify its SHA256.
3. Fully extract its contents over the existing Qiehao directory, replacing only program files with the same names. Do not delete the whole old directory.
4. Preserve `profiles/`, `state/`, `logs/`, and `backup/` in the existing directory.
5. v1.1.1 includes a rebuilt `Qiehao.exe`; double-click it after extracting. `Start-Qiehao.cmd` remains a backup. Replacing program files does not require adding saved accounts again.

If you extract into a new directory, manually copy the old `profiles/` and `state/` to continue using your saved accounts. This is only supported on the same Windows computer, under the same Windows user and DPAPI CurrentUser protection environment. `logs/` and `backup/` are not required to restore the account list. Never upload these private directories publicly.

The Release ZIP does not contain `profiles/`, `state/`, `logs/`, or `backup/`. Replacing program files normally does not remove private runtime data. Do not directly migrate DPAPI profiles across computers or Windows users.

### v1.1.1 reliability and rollback

v1.1.1 preserves Profile format and DPAPI CurrentUser compatibility and includes real-user-accepted account-flow fixes and the thin EXE launcher.

This version series refreshes the GUI immediately after account operations. Current Account is read from the committed local Active Profile without starting Codex Desktop; official verification is a separate status, and older refresh results cannot overwrite newer state. Sequential failed/cancelled additions clean up safely. Persistent Windows Sandbox Service processes are distinguished from actual Desktop processes.

Local switching and official sign-in verification have separate outcomes. A verification timeout preserves the completed local switch but does not claim success: "Local account switched; sign-in status could not be verified yet." Explicit invalidation requires sign-in; an identity mismatch stops safely and rolls back. Stable `account/read` establishes the authentication loaded by the official process, not an enduring guarantee of server acceptance or Desktop workspace selection. Experimental workspaceRouting is not used, and email is not an identity key.

The existing Team first-add warning remains because long-term real-user coverage is still limited. Quota is an auxiliary feature and never blocks add, switch, delete, or verify. Failed queries can be refreshed manually, preserve the last successful snapshot, and do not trigger high-frequency background polling. Refreshed authentication is saved as original bytes only after strict identity matching. Profile format and DPAPI CurrentUser remain unchanged.

When rolling back the software, prefer keeping the latest `profiles/` and `state/` and replacing only program files. Codex may have refreshed authentication tokens; do not prioritize restoring stale authentication backups. v1.1.1 uses a Profile format compatible with v1.0.3. Any future format change requires a separate migration and rollback design.

Advanced Git users should first run `git status --short`. If there are no local source changes, run `git pull --ff-only`. The `--ff-only` option prevents Git from creating an automatic merge commit when histories have diverged.

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
- Account data is protected by Windows DPAPI CurrentUser and bound to the current Windows user and local protection environment.
- Do not copy the `profiles/` directory directly to another computer and assume it can be decrypted there.
- **Browser/PWA untouched**: browser session data is neither read nor modified.
- No telemetry or analytics are included.
- This project does not operate a relay server.
- Inactive accounts are not queried for quota.
- `profiles/`, `state/`, `logs/`, `backup/`, `auth.json`, DPAPI containers, and quota cache must never be committed to Git.

Protect your Windows account, Codex login, and local computer. Never upload `profiles/`, `state/`, `logs/`, `backup/`, or `auth.json` to GitHub, cloud drives, chat tools, or public issues. Never paste tokens, email addresses, account IDs, cookies, or logs containing credentials into a public issue.

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
- `MultiAccountStressSelfTest.ps1`
- `GuiSelfTest.ps1`
- `LongTermSafetyAuditSelfTest.ps1`
- `ProfileDeleteTransactionSelfTest.ps1`
- `CleanInstallSelfTest.ps1`
- `VisualPolishSelfTest.ps1`
- `AccountGridLayoutSelfTest.ps1`
- `LocalizationSelfTest.ps1`
- Quota and Switch-before-Quota test suites
- `LauncherSelfTest.ps1`
- `LauncherExeSelfTest.ps1` (EXE, no-console, path, and safe-failure tests)

All automated tests use fake-only data or hidden/offscreen WPF. Development and CI must not read real authentication profiles or send real quota requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing and [SECURITY.md](SECURITY.md) before reporting a security issue.

## Release status and version history

The current recommended download is **[Qiehao v1.1.1 (Latest)](https://github.com/zctlove/qiehao/releases/tag/v1.1.1)**.

- v1.1.1 — Latest
- v1.1.0 — Previous official release
- v1.0.3
- v1.0.2
- v1.0.1
- v1.0.0

v1.0.0, v1.0.1, and v1.0.2 remain available for version history and troubleshooting. New users should use the latest release.

v1.1.1 includes a thin Windows EXE launcher, not an installer. PowerShell source and modules remain separate for inspection.

## Community

This project recognizes and links to the [LINUX DO](https://linux.do/) community. Feedback, testing, suggestions, and discussion from community members are welcome.

Qiehao is also shared in other technical communities, and I appreciate everyone who takes the time to try it and report real-world feedback.

## Risk and license

Qiehao changes local Codex authentication state. Verify the source before use and keep your environment recoverable. Codex local file formats or behavior may change in the future; when Qiehao encounters an unknown structure, it should fail closed rather than guess.

This project is licensed under the [MIT License](LICENSE), Copyright (c) 2026 ZCT. The root `LICENSE` file contains the complete terms.
