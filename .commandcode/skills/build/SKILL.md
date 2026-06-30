---
name: build
description: One-command build pipeline for Article-Hub: detects changes, generates Conventional Commit messages, bumps version, builds release APK, and pushes. Trigger with /build.
---

# Build Skill

The `/build` command automates the entire **check → commit → bump → build → push** pipeline for the Article-Hub Flutter project. It enforces a hard gate: the APK must compile successfully before any code is pushed.

## Trigger

User says `/build`, `build apk`, `构建`, or any variant requesting a release build.

## Step-by-Step Workflow

### Phase 1: Detect Changes

Run `git status --short`. Then filter the results:

- **Exclude** lines matching `node_modules/`, `.commandcode/skills/`, `package.json`, `package-lock.json` — these are project tooling noise, not application code.
- **Exclude** deleted files that are not tracked losses (e.g., ` D ` prefix on deleted-only items that were never meaningful).

After filtering:

- **If no meaningful changes remain** → tell the user: "没有检测到新改动" and **stop immediately**. Do NOT proceed to any subsequent phase.
- **If there are meaningful changes** → proceed to Phase 2, and report the changed/added file count to the user.

### Phase 2: Stage Changes

Run these commands in order:

```bash
git add -A
git reset -- node_modules/ package.json package-lock.json
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
```

This is a project convention: every release build gets a unique patch version. It increments `pubspec.yaml` version (e.g., `2.0.4` → `2.0.5`) and renames an existing `app-release.apk` to `Article-Hub.apk` if one exists.

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

Run:

```bash
git push
```

Or detect the current branch and push to the correct remote:

```bash
git rev-parse --abbrev-ref HEAD
```

Then `git push origin <branch>`.

After successful push:

- Report the APK path: `build\app\outputs\flutter-apk\app-release.apk`
- Report the file size from the build output (e.g., "60.7MB").
- If `bump_version.dart` renamed the APK to `Article-Hub.apk`, mention both paths.

## Edge Cases

### User has uncommitted version bump from a prior build

If `pubspec.yaml` is already modified before Phase 4, the version bump still runs — it will increment again. This is fine; the convention is one bump per build.

### Push fails (network, permissions)

If `git push` fails after a successful build, the commit is still local. Tell the user:

```
构建成功但推送失败：[error details]。请手动执行 git push。
```

Do NOT try to reset or undo the commit.

### Currently on a non-main branch

Always push to the current branch, not a hardcoded `main`:

```bash
git push origin $(git rev-parse --abbrev-ref HEAD)
```

### Build takes very long or hangs

The 5-minute timeout should cover most cases. If it times out, treat it as a build failure and report the timeout.

## Verification

After the skill runs end-to-end, confirm:

1. Only application code was committed (no `node_modules/`).
2. The commit message follows Conventional Commits format.
3. The APK file exists at `build\app\outputs\flutter-apk\app-release.apk`.
4. The code is pushed to the remote repository.

## Red Flags

- Do NOT run `git reset` or `git commit --amend` after a build failure — the user may need the staged state to debug.
- Do NOT skip the version bump — it is required by project convention.
- Do NOT push if the build fails. This is non-negotiable.
- Do NOT include `node_modules/`, `package.json`, or `package-lock.json` in the commit.
