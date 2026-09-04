# Submodule Safety

Submodule commits can be easy to lose. The parent repository records only a commit SHA, not the branch that made the SHA reachable.

## Safe sequence

1. Enter the submodule.
2. Create or select the intended branch.
3. Commit the submodule changes.
4. Push the submodule commit to the correct remote.
5. Verify the pushed branch contains the commit.
6. Return to the parent repository.
7. Commit the updated submodule pointer.

For Ghostty:

```bash
cd ghostty
git remote -v
git checkout cmux
git add <files>
git commit -m "..."
git push origin HEAD:cmux
```

The parent pointer tracks the tctony fork's permanent `cmux` patch branch. Make sure the commit is an ancestor of that remote branch:

```bash
git fetch origin cmux
git merge-base --is-ancestor HEAD origin/cmux
```

In this repository's Ghostty submodule, `origin` is `tctony-labs/ghostty` and `manaflow` is the parent fork. Keep `origin/main` free for parent synchronization; cmux-specific commits belong on `origin/cmux`.

## Detached HEAD hazard

Do not commit submodule changes on a detached HEAD and then update the parent pointer. That creates a parent commit pointing at a SHA that may not be reachable from any remote branch. A future checkout or CI job can fail to fetch it.

## Fork documentation

Keep `docs/ghostty-fork.md` updated when fork changes or conflict notes matter for future upstream merges. The point is to preserve why the fork diverged, not just that it diverged.

## GhosttyKit optimization

Rebuild GhosttyKit.xcframework with ReleaseFast:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Debug or default optimization builds can hide performance characteristics and should not be used for the checked-in framework refresh path.
