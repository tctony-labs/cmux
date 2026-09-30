# Release symbols / Release 符号

## Download from GitHub Release / 从 GitHub Release 下载

Open the [tctony cmux releases](https://github.com/tctony-labs/cmux/releases), select the version from the crash or sample report, and download **`cmux-tctony-symbols.zip`** from **Assets**. Releases made with the symbol archive workflow retain this ZIP alongside `cmux-tctony.dmg` and `appcast.xml`. Older releases may have no symbol archive.

打开 [tctony cmux Release 页面](https://github.com/tctony-labs/cmux/releases)，选择崩溃或采样报告对应的版本，从 **Assets** 下载 **`cmux-tctony-symbols.zip`**。启用符号归档流程后的 Release 会将该 ZIP 与 `cmux-tctony.dmg`、`appcast.xml` 一起长期保存。旧版本可能没有符号归档。

The direct URL is `https://github.com/tctony-labs/cmux/releases/download/vX.Y.Z/cmux-tctony-symbols.zip`. Replace `vX.Y.Z` with the required version tag. To download and extract with GitHub CLI on macOS:

直接下载地址为 `https://github.com/tctony-labs/cmux/releases/download/vX.Y.Z/cmux-tctony-symbols.zip`，将 `vX.Y.Z` 替换为所需版本的 tag。也可以在 macOS 上使用 GitHub CLI 下载并解压：

```bash
release_tag='vX.Y.Z'
symbols_dir="$PWD/symbols/$release_tag"
gh release download "$release_tag" --repo tctony-labs/cmux \
  --pattern cmux-tctony-symbols.zip --dir "$symbols_dir"
ditto -x -k "$symbols_dir/cmux-tctony-symbols.zip" "$symbols_dir"
```

## Download from Actions / 从 Actions 下载

Manual builds upload an artifact named **`cmux-tctony-symbols`**, retained for **90 days**, without creating a GitHub Release. Release builds also upload this artifact immediately after building and validating symbols, before notarization; it remains available if a later packaging step fails. Find the relevant run under [Actions](https://github.com/tctony-labs/cmux/actions), inspect its checkout commit and build result, and download the artifact. For GitHub CLI, replace `RUN_ID` with that run's numeric ID:

手动构建上传名为 **`cmux-tctony-symbols`** 的 artifact，保留 **90 天**，不创建 GitHub Release。正式发布的构建也会在构建和符号校验成功后、公证之前立即上传该 artifact；即使后续打包失败，符号仍可下载。在 [Actions](https://github.com/tctony-labs/cmux/actions) 中找到对应运行，核对其实际 checkout 提交和构建结果，然后下载 artifact。使用 GitHub CLI 时，将 `RUN_ID` 替换为该运行的数字 ID：

```bash
run_id='RUN_ID'
symbols_dir="$PWD/symbols/run-$run_id"
gh run download "$run_id" --repo tctony-labs/cmux \
  --name cmux-tctony-symbols --dir "$symbols_dir"
ditto -x -k "$symbols_dir/cmux-tctony-symbols.zip" "$symbols_dir"
```

## Check the archive and UUID / 核对归档和 UUID

The extracted `cmux-tctony-symbols/` directory contains:

解压后的 `cmux-tctony-symbols/` 目录包含：

| File / 文件 | Contents / 内容 |
| --- | --- |
| `cmux.app.dSYM` | Main App symbols / 主 App 符号 |
| `cmux.dSYM` | Bundled cmux CLI symbols / App 内附带的 cmux CLI 符号 |
| `CmuxDockTilePlugin.plugin.dSYM` | Dock plugin symbols / Dock 插件符号 |
| `metadata.json` | Source commit, App version, build number, Xcode version, and each executable's path, architecture and UUID / 源码提交、App 版本、build number、Xcode 版本及各可执行文件的路径、架构和 UUID |

Select the dSYM for the image containing the unresolved address. Compare its **arm64 UUID** with that image's UUID in the crash report or sample's **Binary Images** section. Version and build number alone are insufficient. If the exact App from that build is available, compare it too; the example below uses `/Applications/cmux.app`, which must be that same build:

选择未解析地址所属镜像对应的 dSYM，将其 **arm64 UUID** 与崩溃或采样报告中 **Binary Images** 部分的镜像 UUID 核对。仅凭版本号和 build number 不足以确认匹配。如果保留了该次构建的 App，也应核对其 UUID；下例使用 `/Applications/cmux.app`，它必须来自同一次构建：

```bash
symbols_root="$symbols_dir/cmux-tctony-symbols"
cat "$symbols_root/metadata.json"
app_dwarf="$symbols_root/cmux.app.dSYM/Contents/Resources/DWARF/cmux"
xcrun dwarfdump --uuid "$app_dwarf"
xcrun dwarfdump --uuid /Applications/cmux.app/Contents/MacOS/cmux
```

A rebuild of the same tag can produce a different UUID. Do not use mismatched symbols. These archives cover the three Xcode products above; the current build does not archive separate symbols for Rust/Zig helpers or prebuilt third-party frameworks.

同一 tag 重新构建也可能生成不同 UUID，不能使用 UUID 不匹配的符号。这些归档覆盖上述三个 Xcode 产物；当前构建不归档 Rust/Zig helper 或预编译第三方 framework 的独立符号。

## Resolve an address with atos / 用 atos 解析地址

On macOS with Xcode tools installed, set `load_address` to the image's runtime load address from **Binary Images**, and `sample_address` to the unresolved absolute address within that image. Then run the command below. For CLI or Dock plugin frames, replace `app_dwarf` with the matching DWARF file from the table above.

在安装了 Xcode 工具的 macOS 上，将 `load_address` 设置为 **Binary Images** 中该镜像的运行时加载地址，将 `sample_address` 设置为该镜像内未解析的绝对地址，再执行下列命令。解析 CLI 或 Dock 插件帧时，将 `app_dwarf` 替换为上表中对应 dSYM 内的 DWARF 文件。

```bash
xcrun atos -arch arm64 -o "$app_dwarf" -l "$load_address" "$sample_address"
```

App dSYMs resolve application code; unresolved system SwiftUI or other system framework frames require their own matching symbols. An App dSYM cannot recover frames missing from a sample.

App dSYM 用于解析应用代码；系统 SwiftUI 或其他系统 framework 的未解析帧需要其自身匹配的符号。App dSYM 无法恢复采样中没有记录的调用帧。

## Implementation / 实现位置

Symbol validation and packaging are implemented in [`scripts/archive-release-symbols.py`](../scripts/archive-release-symbols.py). Upload and publication are configured in [`build-tctony.yml`](../.github/workflows/build-tctony.yml) and [`release-tctony.yml`](../.github/workflows/release-tctony.yml).

符号校验和打包由 [`scripts/archive-release-symbols.py`](../scripts/archive-release-symbols.py) 实现；上传和发布分别配置在 [`build-tctony.yml`](../.github/workflows/build-tctony.yml) 和 [`release-tctony.yml`](../.github/workflows/release-tctony.yml) 中。
