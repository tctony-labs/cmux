# cmux agent notes

## Initial setup

Run the setup script to initialize submodules, build GhosttyKit, and install the pbxproj normalization pre-commit hook:

```bash
./scripts/setup.sh
```

## Local dev

After making code changes, always run the reload script with a tag to build the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

By default, `reload.sh` builds but does **not** launch the app. The script prints the `.app` path so the user can cmd-click to open it. After a successful build, it always terminates any running app with the same tag (so cmd-clicking launches the freshly-built binary instead of foregrounding the stale instance). Pass `--launch` to open the app automatically after the build:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --launch
```

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use that path to build a cmd-clickable `file://` URL. Steps:

1. Grab the path from the `App path:` line in `reload.sh` output.
2. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode any part of the path.
3. Format it as a markdown link using the template for your agent type.

Example. If `reload.sh` output contains:

```text
App path:
  /Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux DEV my-tag.app
```

**Claude Code** outputs:

```markdown
=======================================================
[cmux DEV my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
=======================================================
```

**Codex** outputs:

```markdown
=======================================================
[my-tag: file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
=======================================================
```

Never use `/tmp/cmux-<tag>/...` app links in chat output.

For CLI or socket dogfood against a tagged Debug app, use the tag-bound helper and set `CMUX_TAG`.
Do not use `/tmp/cmux-cli` for tagged dogfood, since that symlink points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/...`. It also scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, and debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the selected tag.

After making code changes, always use `reload.sh --tag` to build. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`.** Untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

If you only need to verify the build compiles (no launch), use a tagged derivedDataPath:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<your-tag> build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

When rebuilding cmuxd for release/bundling, always use ReleaseFast:

```bash
cd cmuxd && zig build -Doptimize=ReleaseFast
```

`reload` = build the Debug app (tag required) and terminate any running app with the same tag. Pass `--launch` to also open the freshly-built app:

```bash
./scripts/reload.sh --tag <tag>
./scripts/reload.sh --tag <tag> --launch
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "cmux STAGING" (isolated from production cmux):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI (Commits tab, check statuses) that the test genuinely fails without the fix.

## Shared behavior policy

- When a behavior is exposed through multiple entrypoints (keyboard shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action/model path and verify every entrypoint that should invoke it. Do not patch one surface while leaving the others with duplicated logic.
- For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and handle failure with an explicit rollback or error state. Do not let each entrypoint maintain its own optimistic copy.
- When a user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`: called on every event including keyboard. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
  - `TabItemView` in `ContentView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its permanent tracked remote branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. For Ghostty, push to `origin/cmux` and verify with: `cd ghostty && git merge-base --is-ancestor HEAD origin/cmux`.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Localization audit is required for every user-facing change.** Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips, enumerate the changed user-facing surfaces and verify each one has entries for every supported locale. `defaultValue`, English fallback text, schema descriptions, or copied English strings do not count as localization. For Swift/AppKit strings, update `Resources/Localizable.xcstrings`; for localized web/docs content, update every supported message catalog (currently `web/messages/en.json` and `web/messages/ja.json`) and any localized data structures that carry inline translations. Parse touched localization files, compare changed message keys across locales, and use `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English. The final handoff must state what localization audit was performed or explicitly say what could not be verified.
- **Shortcut policy:** Every new cmux-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented in the keyboard shortcut and configuration docs.
- **Snapshot boundary for list subtrees.** In any SwiftUI panel whose `body` contains a `LazyVStack` / `LazyHStack` / `List` / `ForEach` of rows, no view below that boundary may hold a reference to an `ObservableObject` / `@Observable` store (no `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or even a plain `let store: SomeStore` property). Rows and drop-gaps receive immutable value snapshots plus closure action bundles only. Violating this reintroduces the "orthogonal @Published change invalidates every row and thrashes `LazyLayoutViewCache`" class of 100% CPU spin loop that hit the Sessions panel and the workspace sidebar (https://github.com/manaflow-ai/cmux/issues/2586). Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **No state mutation inside view-body computations.** A function called from `body` (directly or through a helper) must not write `@Published` state, schedule a `Task { @MainActor in store.x = … }`, or `DispatchQueue.main.async` a store write. That creates a re-render feedback loop and pegs the main thread (same root-cause family as the snapshot-boundary rule). State-changing work triggered by "new data appeared" belongs in a `reload()` completion, a `didSet`, or a property-observer — never in the projection that feeds `ForEach`.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change silently between macOS major versions.** A function that "obviously" returns the same value on every macOS is not a reliable assumption. Concrete case from https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 — Apple silently fixed the underlying CFURL normalization. The repo's `macos-26` CI and every maintainer's dev machine were on the fixed-behavior side; every reporter on the issue was on the broken side. Always test on the reporter's macOS before declaring a user-reported repro disproven. AWS M4 Pro builders (`cmux-aws-mac`, `cmux-aws-m4pro`, `aws-m4pro-1..6`) are pre-provisioned on macOS 15.7.4 and the preferred empirical-repro path; see the `regression-hunt` skill in the cmuxterm-hq sibling repo for the full playbook.
- **Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`.** A `.swift` file added to the worktree without a matching `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently ignored by Xcode and never compiles or runs on CI. Both `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews pass with "Executed 0 tests" — so the missing wiring is indistinguishable from a clean two-commit red/green regression test until a real user hits the bug. The `workflow-guard-tests` job runs `./scripts/lint-pbxproj-test-wiring.sh` to catch this at PR time; surfaced during the https://github.com/manaflow-ai/cmux/issues/4529 investigation against https://github.com/manaflow-ai/cmux/pull/4536. Add via Xcode (drag the file into the cmuxTests target) or hand-edit the four pbxproj entries; reference any wired sibling like `TabManagerUnitTests.swift` as a template.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `tctony-labs/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = tctony fork, manaflow = parent fork
git checkout cmux
git add <files>
git commit -m "..."
git push origin HEAD:cmux
git fetch origin cmux
git merge-base --is-ancestor HEAD origin/cmux
```

The permanent `cmux` branch carries cmux-specific patches. Keep `main` available for synchronizing the fork with its parent:

```bash
cd ghostty
git fetch manaflow
git checkout main
git merge manaflow/main
git push origin main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

Manual release steps (if not using the command):

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: update `CHANGELOG.md`; docs changelog is rendered from it.

## Skills

Detailed cmux contributor rules live in repo skills under `skills/`; use the task-specific skill before changing that area.

Core skill map:

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, local dev build isolation.
- `cmux-architecture`: package boundaries, refactor architecture, file/API discipline, testability, Swift concurrency rules.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, and localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, and release asset workflow.

## tctony fork

改完代码之后，使用固定的 tag `dev` 来 reload：

```bash
./scripts/reload.sh --tag dev
```

只有修改会被 `cmux` scheme 编译或打包进 App 的源码、资源或工程配置后，才运行上述 reload。仅修改独立脚本（包括 `build-cmux.sh`）、文档、测试、CI 配置、Agent instructions 或其他不进入 App 构建产物的文件时，不要运行 reload；改用与改动直接相关的最小验证。用户明确要求 reload 时除外。

## tctony release workflow

本节是 `tctony-labs/cmux` fork 唯一有效的 release 流程，也是相关操作的最高优先级依据。发布 tctony 版本时，不遵循上方为 `manaflow-ai/cmux` 编写的 `Release` 说明，也不照搬 `skills/cmux-release/` 中的上游仓库名、默认版本策略、资产名、Secrets 或命令；如有冲突，一律以本节和当前两个 tctony workflow 的实际配置为准。

不要继承上游“默认 bump minor”的规则。版本号以用户明确指定的 patch、minor、major 或具体版本为准；用户未指定时先确认，不要自行套用 `manaflow-ai/cmux` 的默认值。

发布流程与 `tctony-labs/EmacsCtl` 一致：由 release workflow 调用可复用的构建 workflow，完成 App 构建、签名、公证、DMG 打包、GitHub Release 创建和 Sparkle 更新文件发布。

Release 过程中不要在本地运行 `reload.sh`、`xcodebuild` 或 `build-cmux.sh`。本地只运行 workflow 和脚本的静态检查、受影响的 CI 测试、`git diff --check` 与 `./scripts/release-pretag-guard.sh`；实际 App 构建、签名、公证和打包只在 tag 触发的 GitHub Actions 中执行。本规则覆盖上方 `tctony fork` 中修改工程配置后需要 reload 的一般规则。

- Release workflow：`.github/workflows/release-tctony.yml`
- 可复用构建 workflow：`.github/workflows/build-tctony.yml`
- 构建架构：仅 `arm64`；除非用户明确要求，不要恢复 `x86_64` 或 universal 打包
- Release 资产：`cmux-tctony.dmg`、`appcast.xml`
- Sparkle feed：`https://github.com/tctony-labs/cmux/releases/latest/download/appcast.xml`

此 fork 的 `.github/workflows/` 只保留上述两个 tctony workflow。除非用户明确要求，不要恢复上游的 CI、nightly、Cloud VM、TestFlight、Homebrew 或其他 GitHub Actions workflow。

此 fork 不发布或下载 GhosttyKit 预构建 Release 产物，`build-tctony.yml` 固定使用源码构建和 GitHub Actions cache。每次更新 `ghostty` submodule 指针后，必须先将 cmux 变更推送到默认分支 `develop`，等待 `build-tctony.yml` 成功并写入按 Ghostty SHA 隔离的 cache，然后才能创建 release tag。release 调用构建 workflow 时会强制检查精确 cache key；未命中时直接失败，不会在 release 中重新构建 GhosttyKit。若 cache 被 GitHub 清理，可在 `develop` 上手动触发 `build-tctony.yml` 重新预热。

```bash
gh workflow run build-tctony.yml --repo tctony-labs/cmux --ref develop
gh run watch --repo tctony-labs/cmux
```

发布前：

1. 更新 `CHANGELOG.md`。
2. 使用 `./scripts/bump-version.sh` 更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
3. 提交并推送版本与 changelog 变更。
4. 确保发布 tag 为 `v<MARKETING_VERSION>`，例如版本 `0.64.15` 对应 `v0.64.15`。

推荐通过 tag push 发布：

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo tctony-labs/cmux
```

也可以像 EmacsCtl 一样手动触发，并传入相同格式的 tag：

```bash
gh workflow run release-tctony.yml \
  --repo tctony-labs/cmux \
  -f tag=vX.Y.Z
```

发布 workflow 会校验 tag 与 App 版本是否一致，然后：

1. 调用 `build-tctony.yml`。
2. 复用组织级 Apple 证书完成签名和公证。
3. 从 `SPARKLE_PRIVATE_KEY` 派生公钥，将 tctony Sparkle feed 和公钥注入 App。
4. 生成带 EdDSA 签名的 `appcast.xml`。
5. 创建对应 tag 的 GitHub Release，并上传 DMG 和 appcast。

需要以下组织级配置：

- Variables：`APPLE_ID`、`APPLE_TEAM_ID`、`MACOS_APPLICATION_CERT_NAME`
- Secrets：`APPLE_ID_PASS`、`MACOS_APPLICATION_CERT_P12`、`MACOS_APPLICATION_CERT_P12_PASS`、`SPARKLE_PRIVATE_KEY`

不要恢复或使用上游 `manaflow-ai` 的 `.github/workflows/release.yml`，以免同一个 tag 同时触发两套 release workflow。
