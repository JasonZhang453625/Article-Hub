---
name: build-pipeline
description: "One-command build pipeline for Memora: detects changes, generates Conventional Commit messages, bumps version, builds release APK, pushes code + tag, and triggers GitHub Release via Actions. Trigger with /build."
---

# Build Skill

The `/build` command automates the entire **check → commit → bump → build → push → tag → release** pipeline for the Memora Flutter project. It enforces a hard gate: the APK must compile successfully before any code is pushed. After push, it creates a version tag that triggers a GitHub Actions workflow to publish the APK as a GitHub Release.

## Prerequisites

The GitHub Actions release workflow requires the following repository secrets (set once in `https://github.com/JasonZhang453625/Article-Hub/settings/environments/production-download`):

| Secret | Content |
|---|---|
| `KEYSTORE_B64` | Base64 of `android/app/upload-keystore.jks` — generate with: `base64 -w0 android/app/upload-keystore.jks` |
| `KEY_PROPERTIES_B64` | Base64 of `android/key.properties` — generate with: `base64 -w0 android/key.properties` |
| `APK_DEPLOY_HOST` | `47.103.95.241` |
| `APK_DEPLOY_PORT` | `22` |
| `APK_DEPLOY_USER` | `memora-deploy` |
| `APK_DEPLOY_SSH_KEY` | Private key for server deploy SSH (see `docs/RELEASE_AUTOMATION_SETUP.md`) |
| `APK_DEPLOY_KNOWN_HOSTS` | Server host key line |

The same 5 `APK_DEPLOY_*` secrets are needed in the **`Memora-Landing-Page`** repo's `production-download` environment for the landing deploy workflow.

> **Server prerequisites:** the server must have the `memora-deploy` user, the deploy SSH key in `authorized_keys`, `/opt/memora-apk` + `/opt/memora-landing` writable by that user, and `/usr/local/bin/memora-deploy-landing` installed. See `docs/RELEASE_AUTOMATION_SETUP.md`.

### CI Buildability Check

Before starting the pipeline, verify that the repository can be built from a clean checkout (i.e., GitHub Actions). The most common failure is missing Gradle wrapper files that are excluded by `.gitignore`.

Run:

```bash
git check-ignore -v android/gradlew android/gradlew.bat android/gradle/wrapper/gradle-wrapper.jar
```

If any of these three files are ignored by `.gitignore`:

1. **Remove** the corresponding lines from `android/.gitignore` (the lines for `gradle-wrapper.jar`, `/gradlew`, `/gradlew.bat`).
2. **Force-add** them to git: `git add -f android/gradlew android/gradlew.bat android/gradle/wrapper/gradle-wrapper.jar android/.gitignore`
3. Proceed with the build pipeline — these files will be included in the current commit.

> **Why this matters:** Without these files in the repository, `flutter build apk` on a clean CI checkout cannot start the Gradle build and fails immediately. Local builds work because the files already exist on disk from a previous `flutter create`.

### SSH Remote (required on this dev machine)

**This machine's network resets HTTPS connections to GitHub** (TCP connects, then the data stream is dropped — same behavior that stalls overseas CDN downloads). Therefore:

- The main repo remote is **SSH**, not HTTPS: `git@github.com:JasonZhang453625/Article-Hub.git`
- SSH goes through **port 443** (`ssh.github.com:443`) via `~/.ssh/config`:
  ```
  Host github.com
      HostName ssh.github.com
      Port 443
      User git
      IdentityFile ~/.ssh/id_ed25519
      StrictHostKeyChecking accept-new
  ```
- Verify SSH auth with `ssh -o ConnectTimeout=20 git@github.com` (expect `Hi JasonZhang453625! You've successfully authenticated`).
- If a push ever fails with `Connection was reset` / `Could not connect to github.com port 443`, it's this network issue — retry, or use SSH if the remote was somehow switched back to HTTPS (`git remote set-url origin git@github.com:JasonZhang453625/Article-Hub.git`).
- The SSH key (`~/.ssh/id_ed25519`, titled `memora-build`) is registered on the GitHub account.

## Trigger

User says `/build`, `build apk`, `构建`, or any variant requesting a release build.

## Step-by-Step Workflow

### Phase 1: Detect Changes

Run `git status --short`. Then filter the results:

- **Exclude** lines matching `node_modules/`, `.commandcode/skills/`, `.commandcode/taste/`, `package.json`, `package-lock.json` — these are project tooling noise, not application code.
- **Exclude** deleted files that are not tracked losses (e.g., ` D ` prefix on deleted-only items that were never meaningful).

After filtering:

- **If no meaningful changes remain** → tell the user: "没有检测到新改动" and **stop immediately**. Do NOT proceed to any subsequent phase.
- **If there are meaningful changes** → proceed to Phase 2, and report the changed/added file count to the user.

### Phase 2: Stage Changes

Run these commands in order:

```bash
git add -A
git reset -- node_modules/ package.json package-lock.json .commandcode/taste/ .commandcode/skills/
```

This stages everything except the known noise files.

### Phase 3: Generate Commit Message

Run `git diff --cached --stat` to get a summary of staged file changes.

Analyze the file paths and change types (new files, modifications, deletions) to determine the **primary change type**:

| Type | Use when… |
|---|---|
| `feat` | New feature or new screen/widget added |
| `fix` | Bug fix |
| `refactor` | Code restructuring without feature/behavior change |
| `chore` | Build tooling, config, dependencies, non-app-code changes |
| `docs` | Documentation only |
| `style` | Formatting, whitespace, semicolons — no logic changes |
| `test` | Adding or modifying tests |

Then generate a **Conventional Commit message** in this format:

```
type(scope): description
```

- **scope** is optional but recommended. Use the feature name or module (e.g., `chat`, `settings`, `home`, `pipeline`).
- **description** must be in English, concise, under 72 characters if possible. Start with a lowercase verb.

Examples:
- `feat(chat): add citation chips and typing indicator widgets`
- `fix(backup): handle empty article list during export`
- `refactor(chat): split chat_screen into focused widget files`
- `chore: bump version to 2.0.4`

**Show the generated commit message to the user** before proceeding.

### Phase 4: Bump Version

Run:

```bash
dart run tools/bump_version.dart
git add pubspec.yaml
```

This is a project convention: every release build gets a unique patch version. It increments `pubspec.yaml` version (e.g., `2.0.4` → `2.0.5`) and renames an existing `app-release.apk` to `Memora.apk` if one exists.

**CRITICAL:** After running `bump_version.dart`, you MUST re-stage `pubspec.yaml` with `git add pubspec.yaml`. The file was already staged in Phase 2 at the old version — the bump only modifies it on disk. Without re-staging, the commit will contain the old version and the GitHub Release title will be wrong (e.g., tag v2.0.13 but title shows "Memora v2.0.12").

### Phase 5: Commit

Run:

```bash
git commit -m "TYPE(scope): description" -m "More detailed body if the change warrants it." -m "Co-authored-by: CommandCodeBot <noreply@commandcode.ai>"
```

- The first `-m` is the Conventional Commit subject line.
- The second `-m` is an optional body — include it if the change is non-trivial and needs explanation. Otherwise omit it.
- The third `-m` is the required co-author trailer. **Always include it.**

### Phase 6: Build APK

Run:

```bash
flutter build apk --release
```

Set a generous timeout (300000ms = 5 minutes) as this can take a while.

**Build gate — this is the critical decision point:**

- **If the build succeeds** (exit code 0):
  - Proceed to Phase 7 (push).
- **If the build fails** (non-zero exit code):
  - **DO NOT push.** The commit is already local — do not amend or revert it; the user may want to fix and retry.
  - Report: "构建失败，请检查报错后重试。"
  - Show the error output from the build.
  - **Stop immediately.** Do NOT run `git push`.

### Phase 7: Push

The remote is SSH (`git@github.com:...`) — see "SSH Remote" above. Do NOT switch it to HTTPS; HTTPS pushes are unreliable on this network.

Detect the current branch and push:

```bash
git rev-parse --abbrev-ref HEAD
git push origin <branch>
```

### Phase 8: Tag and Trigger GitHub Release

After a successful push, create a version tag that will trigger the GitHub Actions release workflow.

1. **Get the current version** — `bump_version.dart` already printed it in Phase 4 as `VERSION=X.Y.Z`. Parse this line to extract the version string.

2. **Create and push a lightweight tag** with the version:

```bash
git tag -a "v<VERSION>" -m "Release v<VERSION>"
git push origin "v<VERSION>"
```

Replace `<VERSION>` with the actual version string, e.g. `git tag -a "v2.0.7" -m "Release v2.0.7"`.

3. After pushing the tag, report:
   -  "✅ 已推送标签 v<VERSION>，GitHub Actions 将自动构建并发布 Release。"

The GitHub Actions workflow (`.github/workflows/release.yml`) listens for tag pushes matching `v*` and:
- Checks out the tagged commit
- Sets up Flutter + Java
- Builds the release APK
- Creates a GitHub Release with the APK attached as an asset
- Auto-generates description from the commit messages since the last tag
- **Automatically uploads the APK to the China server** (`/opt/memora-apk/android/app-release.apk`) via SSH, verifies SHA-256/size, and activates it with `update-manifest.sh`

### Phase 9: Update Landing Page

The landing page is a separate Astro project in `landing-page/`. **Pushing to the landing repo's `master` branch automatically triggers the deploy workflow** (`landing-page/.github/workflows/deploy.yml`): it builds the site on the Actions runner (`npm ci` + `astro build`), then rsyncs `dist/` over SSH to the server's site root (`/opt/memora-landing`). No manual server steps needed.

> **Why build on the runner:** the server's network resets HTTPS connections to GitHub, so server-side `git pull`/`npm` is unreliable. Building on GitHub's runner and pushing only the built `dist/` avoids that entirely.

The page has a fallback version constant that must be updated to match the current release (the live version is otherwise driven by `api.memora.wang/downloads/android/latest.json` at runtime).

1. **Check for uncommitted changes** in the landing page repo:

```bash
cd landing-page && git status --short
```

2. **Update the fallback version constant** in `landing-page/src/pages/index.astro` (the new version `<VERSION>` is known from Phase 4):

```astro
const fallbackVersion = '<VERSION>';
```

3. **Commit and push** in the landing page repo (this triggers the automatic deploy):

```bash
cd landing-page
git add -A
git commit -m "chore: bump landing page version to <VERSION>" -m "Co-authored-by: CommandCodeBot <noreply@commandcode.ai>"
git rev-parse --abbrev-ref HEAD
git push origin $(git rev-parse --abbrev-ref HEAD)
```

> **Note:** The deploy is automatic via GitHub Actions → server SSH (`memora-deploy-landing`). Push is the only step needed; do NOT manually SSH or run server commands.
>
> If there are no changes to commit (version already up to date), skip the commit and push step.

4. **Optional verification** (after ~2-3 minutes, the deploy run should have completed):

```bash
curl -s https://memora.wang/ | grep -o 'data-fallback-version="[^"]*"'
```

Expect `data-fallback-version="<VERSION>"`.

### Phase 10: Summary

After Phase 9 completes, report a summary:

```
✅ 构建完成
- 版本: <VERSION>
- APK: build\app\outputs\flutter-apk\app-release.apk
- 标签: v<VERSION>（已推送）
- Landing page: 版本已更新并推送至 Memora-Landing-Page（自动部署已触发）
- Release: GitHub Actions 正在构建…
```

> **Note:** The GitHub Actions release workflow (`.github/workflows/release.yml`) now also handles the **server APK upload** automatically: after building the APK, it SCPs it to `/opt/memora-apk/android/app-release.apk`, verifies SHA-256/size on the server, and runs `update-manifest.sh <VERSION>` to atomically switch `latest.json`/`latest.apk`. No manual `scp`/`ssh` needed.

## Edge Cases

### User has uncommitted version bump from a prior build

If `pubspec.yaml` is already modified before Phase 4, the version bump still runs — it will increment again. This is fine; the convention is one bump per build.

### Push fails (network, permissions)

If `git push` fails after a successful build, the commit is still local. First check it's not the known network issue: verify the remote is SSH (`git remote -v` shows `git@github.com:...`) and that `ssh -o ConnectTimeout=20 git@github.com` authenticates. If HTTPS was used or auth fails, fix the remote/key, then retry. Tell the user if it still fails:

```
构建成功但推送失败：[error details]。请手动执行 git push。
```

Do NOT try to reset or undo the commit. If push succeeded but tag push fails, push the tag manually:

```
git push origin v<VERSION>
```

### Tag already exists

If `git tag v<VERSION>` fails because the tag already exists, ask the user whether to:
- Delete and recreate the tag (force push): `git tag -d v<VERSION> && git push --delete origin v<VERSION>` then retry.
- Skip tagging (the commit is still pushed, just without a release trigger).

### GitHub Actions workflow fails after push + tag

If Phase 8 completes but the GitHub Actions workflow (visible at `https://github.com/JasonZhang453625/Article-Hub/actions`) reports failure:

1. **Do NOT re-tag or re-push.** The code is already on the remote.
2. Investigate the workflow logs to find the root cause (common failures: missing Gradle wrapper files, signing errors, Gradle download failure).
3. Fix the issue, bump the version again with `dart run tools/bump_version.dart`, commit the fix, push, and create a new tag.
4. The failed v<X> tag stays — do not delete it unless the user specifically asks.

### gh CLI not installed

The `/build` skill does NOT require `gh` — it only pushes the tag. The GitHub Actions workflow handles Release creation server-side. If the user wants to create a release locally, they can install `gh` separately.

### Currently on a non-main branch

Always push to the current branch, not a hardcoded `main`:

```bash
git push origin $(git rev-parse --abbrev-ref HEAD)
```

### Build takes very long or hangs

The 5-minute timeout should cover most cases. If it times out, treat it as a build failure and report the timeout.

### Landing page commit or push fails

If `git commit` or `git push` fails in the `landing-page/` repo:

- Warn the user: "Landing page 推送失败：[error details]。主仓库推送不受影响。请手动进入 landing-page/ 目录处理。"
- Do NOT abort the overall pipeline — the main repo APK push and tag have already succeeded.

## Verification

After the skill runs end-to-end, confirm:

1. **CI buildability:** `android/gradlew`, `android/gradlew.bat`, and `android/gradle/wrapper/gradle-wrapper.jar` are tracked by git and NOT listed in `android/.gitignore`.
2. Only application code was committed (no `node_modules/`).
3. The commit message follows Conventional Commits format.
4. The APK file exists at `build\app\outputs\flutter-apk\app-release.apk`.
5. The code is pushed to the remote repository.
6. The version tag `v<version>` is pushed to the remote.
7. Landing page `index.astro` `fallbackVersion` matches the current `<VERSION>` (the live version shown on the page is fetched from `latest.json` at runtime).
8. Landing page changes are pushed to `https://github.com/JasonZhang453625/Memora-Landing-Page` and its deploy workflow completed (page shows the new version).
9. GitHub Actions `release.yml` workflow is triggered and completes successfully (check at `https://github.com/JasonZhang453625/Article-Hub/actions`).

## Red Flags

- Do NOT run `git reset` or `git commit --amend` after a build failure — the user may need the staged state to debug.
- Do NOT skip the version bump — it is required by project convention.
- Do NOT push if the build fails. This is non-negotiable.
- Do NOT include `node_modules/`, `package.json`, or `package-lock.json` in the commit.
- Do NOT let `android/.gitignore` exclude `gradle-wrapper.jar`, `gradlew`, or `gradlew.bat` — CI cannot build without them.
