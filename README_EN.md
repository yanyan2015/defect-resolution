<p align="center">
  <a href="README.md">简体中文</a> | <b>English</b>
</p>

<p align="center">
  <h1>Defect Resolution</h1>
  <b>Pin down which release and which commit fixed a bug in open-source software</b>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow?style=flat-square" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/git-2.20%2B-F05032?style=flat-square&logo=git&logoColor=white" alt="Git 2.20+" />
  <img src="https://img.shields.io/badge/python-3.8%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.8+" />
  <img src="https://img.shields.io/badge/shell-bash-4.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash 4+" />
  <img src="https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS-471717?style=flat-square" alt="Cross platform" />
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> &nbsp;·&nbsp;
  <a href="#the-problem">The problem</a> &nbsp;·&nbsp;
  <a href="#supported-systems-and-who-benefits">Who benefits</a> &nbsp;·&nbsp;
  <a href="#how-it-works">How it works</a> &nbsp;·&nbsp;
  <a href="#input-contract">Input contract</a> &nbsp;·&nbsp;
  <a href="#output">Output</a> &nbsp;·&nbsp;
  <a href="#script-reference">Script reference</a> &nbsp;·&nbsp;
  <a href="#evidence-model">Evidence model</a> &nbsp;·&nbsp;
  <a href="#limitations">Limitations</a> &nbsp;·&nbsp;
  <a href="#contributing">Contributing</a>
</p>

---

## Quick start

Drop the skill into Claude Code and hand it three things: **the error**, **where the code lives**, and **the version range**.

### Installation

<details open>
<summary><b>npm (cross-platform, one command)</b> — recommended</summary>

```bash
# no global install needed — npx runs the installer directly
npx @yanyan2015/defect-resolution install

# or install globally first, then run the install command (global command name: defect-resolution)
npm install -g @yanyan2015/defect-resolution
defect-resolution install

# uninstall
defect-resolution uninstall
```

The installer copies the skill files into `~/.claude/skills/defect-resolution` and
checks that `git` / `bash` are available (advisory only — no network, no PATH
changes). Takes effect after restarting Claude Code.

</details>

<details>
<summary><b>Windows (PowerShell)</b></summary>

```powershell
# from the repository directory
.\install.ps1

# optional switches
.\install.ps1 -Scope AllUsers     # install for all users (requires admin)
.\install.ps1 -Target "D:\tools\dr" # install to a specific directory
.\install.ps1 -NoPath             # don't touch PATH
.\install.ps1 -Uninstall          # uninstall
```

The installer: locates Git Bash → copies the skill files → adds the Git Bash
directory to your user PATH → runs a **real smoke test** (creates a throwaway
repo, runs the forensics pipeline end to end) → reports the result.

**Prerequisites**: Git for Windows (ships with Git Bash). Without it the script
says so and prints the download URL. Python is optional — it only affects the
`extract_symbols.py` symbol extractor.

> ⚠️ If PowerShell refuses to run the script:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

</details>

<details>
<summary><b>macOS / Linux</b></summary>

```bash
# install as a skill
git clone https://github.com/yanyan2015/defect-resolution.git ~/.claude/skills/defect-resolution

# or as a Claude Code plugin
claude plugin install yanyan2015/defect-resolution
```

Requires `git` 2.20+ and `bash` 4+; `python` 3.8+ is optional (symbol extraction).

</details>

<details>
<summary><b>Windows (Git Bash)</b></summary>

```bash
git clone https://github.com/yanyan2015/defect-resolution.git ~/.claude/skills/defect-resolution
```

Or just use `install.ps1` / `npx @yanyan2015/defect-resolution install` above (the latter also
checks runtime dependencies).

</details>

### Usage

Then just talk to it:

```text
Confirm which version and which commit fixed this bug:

Repo: https://github.com/curl/curl.git
Bad version: v8.4.0
Good version: v8.5.0
Error:
  src/lib/curl_easy.c:1204: warning: implicit declaration of function 'Curl_getdate'
  src/lib/transfer.c:88: error: 'conn->bits.close' undeclared
Offending code: src/lib/transfer.c lines 80-95
```

Defect Resolution answers with:

```markdown
## Conclusion
- **Fix commit**: `a1b2c3d4` (`transfer: fix connection reuse after TLS renegotiation`)
- **Fixed in**: v8.4.1 (first release containing the fix, 2026-01-14)
- **Broken in**: v8.4.0 (last release still carrying the defect)
- **Branch**: main
- **Confidence**: High — single strong candidate + real bisect passed + message references issue #9876

## Evidence chain
1. Version anchors: bad c1f23bc (v8.4.0), good d4e5f6a (v8.5.0), 412 commits in range
   - Release sequence: v8.4.0 → v8.4.1 → v8.5.0 (the fix landed in v8.4.1)
2. How it was located:
   - blame: v8.4.1:src/lib/transfer.c:88 → a1b2c3d4 (parent attributes that line to 9f8e7d6)
   - pickaxe: `git log -S'close'` hits a1b2c3d4; `-G'bits\.close'` hits a1b2c3d4
   - -L: a1b2c3d4 appears in the history of 80,95:src/lib/transfer.c
3. Semantic screen: the diff moves the write to `conn->bits.close` into
   `Curl_conn_shutdown()`, fixing a read of an uninitialized bit on the reuse path
4. Cross-validation:
   - Method A (real bisect): first bad commit = a1b2c3d4 ✓
   - Method B (parent comparison): bit uninitialized in parent, initialized in candidate ✓
   - Method C (reverse verification): trigger condition rebuilt after revert ✓
5. Version attribution: first release containing the fix = v8.4.1; last broken release = v8.4.0
```

> **The fix is not necessarily the release the user named.** People usually only know "v8.4.0 was broken, v8.5.0 was fine" — the fix may have landed much earlier, in v8.4.1. Defect Resolution checks each release in the range on the **version axis** first, finds where the bug disappears, then narrows commit-level forensics to that much smaller window.

### Works on private code too

**Non-open-source ≠ non-git.** Most private projects use git; they're just not published. The workflow is identical, and it runs entirely locally:

```text
Confirm which version and which commit fixed this bug:

Repo: D:\projects\my-private-service (local git repository)
Bad version: v2.3.0
Good version: v2.4.0
Error:
  src/session.py:88: AttributeError: 'NoneType' object has no attribute 'get'
Offending code: src/session.py lines 80-95
```

Private repositories default to **zero network access** — no code, error text, or commit message ever leaves your machine.

---

## The problem

In an open-source project, the hard question is never *"how do I fix this?"* — it's **"who caused it, which change did it, and in which upstream commit was it actually fixed?"**

What you usually have:

- an error log, stack trace, or compiler diagnostic
- a rough idea of which file (or function) is involved
- a version or a snippet that shows the code working

What's missing is the causal chain. Hunting it by hand is expensive:

| Manual approach | What it costs |
|---|---|
| Scroll `git log --oneline` through hundreds of commits | The real fix is usually buried under later refactors |
| `git blame` one line | Blame shows the *last touch*, which is often a formatting commit |
| `git log -S<symbol>` | A common symbol matches dozens of commits; unrelated ones rank first |
| Read diffs and guess | Ends in "I think it's around here" — no defensible confidence level |

Defect Resolution turns this into a **reproducible, auditable, cross-validated** pipeline: six complementary evidence channels → a weighted evidence table → semantic triage → at least two cross-validation methods → a conclusion with a stated confidence level.

The output isn't "I think it's here". **Every claim cites the command that produced it.**

---

## Supported systems and who benefits

**Mainstream Linux distributions are covered**: CentOS, Ubuntu, openEuler, AnolisOS, UOS, and KylinOS — both desktop and server editions. When the exact source tree running on one of these systems can't be located, a stand-in is usually easy to find in the open-source community: RPM packages of the same version carry **virtually identical source code** across these distributions, differing only in package file suffixes. In other words, **starting from any distribution's source package, you can still trace your way back to the upstream fix commit**.

**It saves real money for two kinds of users:**

| Who | What they get |
|---|---|
| **Open-source software users** (enterprises / teams) | **Self-service patch location**: when an open-source component misbehaves, find the official fix commit, confirm which release to upgrade to, and backport the upstream patch to your own version — without buying vendor consulting for every error. Lower R&D effort, lower consulting spend |
| **System vendors** (OSVs / distribution maintainers) | Dramatically faster triage for pre-sales, operations, and technical support teams: each incoming report quickly yields an **issue analysis report** (fix release + fix commit + evidence chain + resolution mechanism). This keeps R&D-level support costs down — engineering resources stay focused on core R&D and higher-impact work instead of chasing commits for frontline support |

---

## How it works

```text
  Stage 0                Stage 1                 Stage 1.5              Stage 2
  Repo ready      ──▶    Establish anchors  ──▶   Version-axis check ──▶ Trace the change
  ─────────────          ─────────────          ───────────────        ─────────────────
  local/remote get       A/B → commits          check each release      ① -L line-range history
  integrity check        merge-base             "is the bug still       ② two-version blame diff
                         candidate range        there?"                ③ pickaxe -S/-G
                         release sequence       → FIX_VERSION          ④ fixed-code reverse lookup
                                              → narrow the window      ⑤ commit message
                                                                         ⑥ cross-path spread
                         │                          │                          │
                         ▼                          ▼                          ▼
  Stage 5                Stage 4                 Stage 3
  Explain mechanism ◀──▶  Deterministic     ◀──▶   Semantic triage
  ─────────────          verification      ──▶    ─────────────
  trigger condition      A bisect               strong / weak / excluded
  what changed           B parent comparison     ──▶ confirmation gate ⏸
  elimination mechanism  C reverse verify              (your call)
  counterfactual check   D version attribution               │
                                                               ▼
                                                         Stage 6 conclusion
```

Design choices worth knowing:

**Version first, then commit.** The question is "which release fixed it", and the release sequence is **discrete and individually checkable** — a natural coarse filter. Find the first release where the bug disappears on the version axis, then do commit-level forensics inside that much narrower window. That window often shrinks from hundreds of commits to a handful.

**Line drift is handled.** The line numbers in an error belong to the **bad version**; the fixed version shifts them as lines are inserted or removed. So blame attribution uses **content anchoring** rather than line-number filtering: each line of the error region is located by its content in the fixed version, producing an anchored interval, and attribution is then taken over that interval. This covers both "rewrote the offending line" and "inserted a guard before it".

**Evidence is weighted, not counted.** Matching a line of the user's known-good code (weight 5) is far stronger than "some sibling file changed" (weight 1). Ranking reflects evidence strength, not hit count.

**Verification is mandatory.** Stage 4 runs at least two methods. When a method can't run, the conclusion says "could not verify" and the confidence drops — speculation is never used as filler.

**A human gate.** Stage 3 pauses and shows you the strong/weak/excluded triage before spending time on builds and bisects.

---

## Input contract

| Input | Required | Form | If missing |
|---|:---:|---|---|
| Error output | ✅ | log / stack trace / compiler error | — |
| Offending code path | ✅ | `file[:function][:line-range]` | — |
| Repository | ✅ | **local path** (open-source clone / private project) or `https://…/owner/repo.git` | — |
| Bad version | strongly recommended | tag / branch / commit / local HEAD | use the fix commit's parent |
| Good version | recommended | tag / branch / commit | see the fallback chain |
| Fixed code | optional | (a) resolvable ref (b) text snippet (c) both | see the fallback chain |
| Reproduction command | optional | one line; fails on bad, passes on good | static verification only; confidence capped at Medium |

**The version range is the primary input.** The typical case gives two versions: "v1.2.0 throws this error, v1.3.0 is fine". The skill first checks each release in that range on the **version axis** to find where the bug disappears, then locks onto the specific commit inside that much narrower window.

**Fallback chain** (don't stall — degrade and label it in the conclusion):

1. Fixed code as text only → per-line pickaxe reverse lookup (strongest signal, weight 5)
2. Good version only → bad version anchored at `<fix>^`
3. Bad version only → good version defaults to the default branch HEAD; pickaxe locates the fix
4. No release tags → use branches/commits as anchors and state that the repository has no tags, so only a commit and branch can be given
5. Incomplete history → `git fetch --unshallow` first, otherwise label the confidence limit
6. **Not a git directory** → version attribution is impossible (no history, no evidence chain). The skill explains why and offers three ways forward rather than manufacturing a conclusion

---

## Output

A fixed four-part template: **Conclusion → Evidence chain → Resolution mechanism → Open questions**.

- **Conclusion** — commit, release/branch, confidence (High/Medium/Low) with the reason
- **Evidence chain** — version anchors → how it was located (blame / pickaxe / -L hits) → semantic screen → cross-validation → corroboration
- **Resolution mechanism** — trigger condition → what changed → how that breaks the trigger → counterfactual check ("if only this line were reverted, would the error necessarily return?")
- **Open questions** — when candidates can't be separated: every candidate, its confidence, and one concrete suggestion for telling them apart

**Confidence is gated, not vibes**:

| Level | Condition |
|---|---|
| **High** | single strong candidate + Method B passed + any of: real bisect passed / reverse verification passed / message clearly maps to the issue |
| **Medium** | single strong candidate with static evidence only; or multiple candidates where one hits 3 channels and the rest hit 1 |
| **Low** | single-channel hit with weak semantic link; or candidates can't be separated; or repository history is incomplete |

The downgrade reason must be written into the confidence line — a bare label isn't enough.

---

## Script reference

The skill ships six forensic scripts, each usable standalone.

| Script | Purpose | Key options |
|---|---|---|
| `acquire.sh` | Stage 0: obtain a repository | `--checkout` `--full` `--offline` (forces zero network) |
| `anchor.sh` | Stage 1: version anchors | `--path` `--limit`; pass `-` as the good version for fallback mode |
| `version_bisect.sh` | Stage 1.5: **version-axis** determination | `--path` `--range` `--contains` `--sym` `--missing` `--run-cmd` `--tag-list` |
| `extract_symbols.py` | Stage 2: symbol/keyword extraction | `--kind syms\|greps\|paths` |
| `collect.sh` | Stage 2: six-channel evidence collection | `--path` `--range` `--sym` `--symfile` `--grepfile` `--fixed` `--wide` |
| `inspect.sh` | Stage 3: candidate triage card + version attribution | `--path` `--sym` `--fixed` `--error-file` `--context` |
| `verify.sh` | Stage 4: three verification methods | `--A` `--B` `--path` `--sym` `--range` `--fixed` `--run-cmd` |

`collect.sh` emits a **weighted evidence table**; the machine-readable line format is:

```text
CAND|<short-sha>|<full-sha>|<weight>|<evidence-count>|<date>|<subject>|<branches>
```

Using a script directly:

```bash
# from the repository directory
S=./scripts

# Step 1: version axis — find where the bug disappears
bash "$S/version_bisect.sh" <repo> v1.0.0 v2.0.0 \
  --path src/foo.c --contains 'strcpy(buf, s);'
# → FIX_VERSION=v1.1.0   STILL_BROKEN_BEFORE=v1.0.1

# Step 2: commit-level forensics inside the narrowed window
bash "$S/collect.sh" <repo> v1.0.1 v1.1.0 \
  --path src/foo.c --range 80,95 \
  --fixed /tmp/fixed.txt --error-file /tmp/error.log

# Step 3: real bisect evidence (criterion: exit 0 while the trigger still holds)
bash "$S/verify.sh" <repo> <candidate> --A v1.0.1 --B v1.1.0 \
  --path src/foo.c --run-cmd 'make 2>&1 | grep -q "error: .FOO_H. undeclared"'
```

In Windows PowerShell (assuming Git Bash lives in `C:\Program Files\Git`):

```powershell
& 'C:\Program Files\Git\bin\bash.exe' 'C:\path\to\defect-resolution\scripts\collect.sh' `
    <repo> v1.0 v2.0 --path src/foo.c --range 80,95
```

---

## Evidence model

Every piece of evidence carries a weight; the weights sum to the candidate's rank. **High weight ≠ high confidence** — confidence also depends on verification results.

| Evidence | Weight | Note |
|---|:---:|---|
| Fixed-code line pickaxe (path-scoped) | 5 | Strongest: the known-good text appears in this commit |
| Error-symbol pickaxe (path-scoped) | 4 | `-S` hit |
| `-G` regex hit (path-scoped) | 3 | Content rewritten but occurrence count unchanged (conditions, bounds) |
| `-L` line-range history | 3 | Full evolution of that region |
| Blame attribution inside the anchored interval | 3 | Where the error region actually lives in the fixed version |
| Error line deleted/rewritten | 3 | Content vanished in the fixed version |
| Error-symbol pickaxe (repo-wide) | 3 | The fix may live elsewhere |
| Commit message mentions the issue | 2 | `#1234` / `fixes #1234` / `Closes:` |
| Original attribution of the error line in the bad version | 2 | |
| Sibling file / build file / repo-wide symbol change | 1 | **Weak — requires human confirmation** |

---

## When to use it / when not to

**Use it when:**

- An upstream project throws an error and you want to know **which release** fixed it
- An upstream project throws an error and you want to know **which commit** fixed it
- You need to confirm whether a backport or cherry-pick carries the real fix
- You want to find **which change introduced** a bug (reverse attribution — same evidence chain)
- You're chasing a flaky CI failure and need the commit it started at (real bisect)
- The same question about **private projects / local code** (any git repository; runs entirely locally)
- You need to explain to your team *why* the error went away

**Skip it when:**

- You want to **write** a new fix (that's a coding task, not forensics)
- You only want to know who wrote a given line (`git blame` answers that in one command)
- The fix commit is already known and you just need the code explained
- It's a code review or routine git operations

---

## Limitations

Stating the edges honestly is more useful than pretending it handles everything:

- **Shallow clones distort conclusions.** blame / pickaxe / merge-base all need full history. The skill enforces a blobless clone and runs an integrity check, but if you feed it a `--depth=1` repository, confidence must come down.
- **Upstream rebase/squash erases the original commit.** Once a fix is squashed, the original is gone; the best answer becomes "the first release tag containing the fix", labeled as such.
- **No reproduction command means no real bisect.** Static evidence can only exclude "an earlier equivalent fix"; it cannot prove the original error disappeared. The conclusion says so, and confidence is capped at Medium.
- **Weak signal when the fix isn't in the offending file.** Changes to Makefiles, headers, dependency pins, or CI config surface only as weight-1 leads from channel 6 and need human confirmation.
- **Version determination depends on release tags.** Projects without tags, projects releasing from branches, or releases that are tarballs rather than git tags cannot yield a release number — you get a commit and a branch, with the limitation stated.
- **One bug may have several fixes.** When `main` and `X.Y-stable` each carry a fix (a backport), the skill reports both candidates with the branch and release each applies to.
- **Git only.** Mercurial and SVN histories can't be analyzed directly.
- **It doesn't fetch issue bodies.** Issue numbers are matched against local commit messages only; open the link yourself to read the discussion.

---

## Contributing

Bug reports, new evidence channels, or improvements to the verification design are all welcome.

```bash
git clone https://github.com/yanyan2015/defect-resolution.git
cd defect-resolution
bash test/run-tests.sh        # regression tests for the forensic scripts
```

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR. Report security issues privately per [SECURITY.md](SECURITY.md) — not as a public issue.

Design trade-offs and the reasoning behind them are in [DESIGN.md](DESIGN.md).

---

## License

[MIT](LICENSE) © 2026 yanshuai

Both scripts and documentation are released under the MIT License. Use, modify, and redistribute freely in your own projects.
