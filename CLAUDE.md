# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

VSEARCH is a 64-bit C++11 tool for metagenomics sequence analysis (search,
clustering, chimera detection, dereplication, FASTQ processing, paired-end
merging and read synchronization). It is a single CLI binary (`bin/vsearch`)
plus an optional static library. This is a development fork; upstream is
`torognes/vsearch`.

## Editing conventions

**Make minimal, focused diffs — change only the lines relevant to the task.**
**Never** reformat or "tidy" unrelated code: do not convert tabs to spaces or
spaces to tabs, re-indent, reflow, or strip trailing whitespace on lines you are
not otherwise changing, unless you are explicitly asked to and it is confirmed.
Whitespace-only churn on untouched lines bloats the diff, hides the real change,
and complicates upstream cherry-picks — keep commits small and readable.

## Build

```bash
./configure CFLAGS="-O3" CXXFLAGS="-O3"
make ARFLAGS="cr"            # produces bin/vsearch
```

- **`ARFLAGS="cr"` is required** on the `make` line — the CI and release builds
  all pass it; omitting it can break the archive step.
- The generated build files (`configure`, `Makefile.in`, `src/Makefile.in`, ...)
  are **committed and authoritative**: `configure.ac` sets
  `AM_MAINTAINER_MODE([disable])`, so `make` never regenerates them and an
  ordinary build needs **no** autoconf/automake (any version). Run `./autogen.sh`
  **only** after editing `configure.ac` / `Makefile.am` / `src/Makefile.am`, then
  commit the regenerated files alongside the source change. The pinned toolchain
  is **automake 1.16.5** (Debian oldstable) — regenerating with a different
  version rewrites every file's version stamp, so match it.
- C++11 with **`-fno-exceptions`** — there is no exception-based error handling
  anywhere (see `fatal()` below).
- `-O3` is the recommended level and is safe. The historical GCC ≥ 9 `-O3`
  miscompile of `align_simd.cc` (issue #589) was a strict-aliasing bug — SIMD
  vector lanes were punned through a reinterpreted pointer — fixed at the root in
  commit `32a3dd2` by accessing lanes via `std::memcpy` (`get_channel`/
  `set_channel`); the old `-fno-tree-partial-pre` workaround was then removed.
  Don't reintroduce raw `(CELL *)`/`(short *)` lane access in `align_simd.cc`.
- zlib/bzip2 are optional and **loaded dynamically at runtime** (`dynlibs.cc`)
  for `.gz`/`.bz2` input; disable with `--disable-zlib` / `--disable-bzip2`.

### Debug builds and the NDEBUG default

`./configure --enable-debug` switches the compile profile to `-UNDEBUG`
(asserts **on**), `-D_GLIBCXX_DEBUG`, and a large extra-warning set — which now
includes `-Wconversion -Wsign-conversion` (plus `-Wcast-qual -Wold-style-cast
-Woverloaded-virtual -Wnon-virtual-dtor -Wuseless-cast`; see `src/Makefile.am`).
The width-narrowing backlog (CODE_REVIEW.md P1) has been swept and the debug
build is now the gate that keeps it from regressing, so a new narrowing will
fail `--enable-debug` even though the default build is silent. **The default
build defines `-DNDEBUG`, so every `assert()` is compiled out** — including in CI
and release binaries. Do not use `assert()` for input validation; use `fatal()`.

### Sanitizer / Valgrind builds

```bash
./configure CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1" \
            CXXFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1" \
            LDFLAGS="-fsanitize=address,undefined"
```

See `.github/workflows/{sanitizers,valgrind}.yml` for the exact CI invocations.

### Static library

```bash
make -C src libvsearch.a    # built with -DVSEARCH_NO_MAIN -fPIC
```

The library API is documented in `src/vsearch_api.h` and `LIBRARY_API.md`;
runnable examples are in `api_examples/`.

## Test

Tests live in a **separate repository** (`frederic-mahe/vsearch-tests`), not in
this tree:

```bash
git clone https://github.com/frederic-mahe/vsearch-tests
export PATH=$PWD/bin:$PATH
cd vsearch-tests
bash ./run_all_tests.sh                 # whole suite
bash ./scripts/cluster_fast.sh          # one command's tests (resolves vsearch via PATH)
bash ./scripts/cluster_fast.sh /abs/path/to/vsearch   # or pass the binary as $1
```

- Each `scripts/<command>.sh` resolves the binary with `which vsearch` unless a
  path is given as `$1`.
- Every test script ends with a `valgrind --leak-check=full` block **gated by
  `which valgrind`** — so installing valgrind turns the suite into a
  leak/Memcheck check (this is exactly how `valgrind.yml` works; no wrapper).
- API examples have their own harness: `cd api_examples && make test` (compares
  output against ground-truth files in `api_examples/data/`).

CI workflows (`.github/workflows/`): `build-and-test` (default gate),
`sanitizers` (ASan/UBSan, non-gating inventory, weekly + dispatch),
`threadsanitizer` (TSan, non-gating inventory, weekly + dispatch; mutually
exclusive with ASan, so a separate lane),
`valgrind` (Memcheck, gating), `static-analysis` (cppcheck, per-PR non-gating
inventory) and `static-analysis-clang-tidy` (clang-tidy, weekly; scoped to
bug-finding checks via the repo `.clang-tidy` — split into its own file because
its `clang-analyzer-*` checks are slow), `codeql` (C/C++ `security-extended`),
`build-all` (cross-platform matrix, manual dispatch), plus `jekyll-gh-pages` and
`prune-pages-deployments` (docs-site build and weekly deployment housekeeping).
Note: the `build-and-test` FreeBSD lane is `continue-on-error` (non-gating). The
FreeBSD-only test-suite hang — orphaned `<()` FIFO writers left blocked in
`fifoow` when a negative test's vsearch rejects its options before opening the
`<()` input (on Linux `<()` is a `/dev/fd` pipe, so it does not occur) — is
handled in-lane: the watcher reaps those writers and pass/fail is taken from
FAIL lines in the log. Non-gating now only guards residual vmactions/QEMU infra
flakiness.

## Architecture

The README has a per-file table. The points below are the cross-file structure
that isn't obvious from reading any single file.

**CLI and option handling are a (now-split) monolith.** The option parser was
lifted out of `vsearch.cc` into **`src/cli.cc`** (~4,500 lines; `args_init` is
almost all of it). `vsearch.cc` is now ~1,900 lines holding `main()`, the
command dispatch, the `cmd_help` help text, and the global state. Each of ~254
CLI options is still declared in **five parallel, manually-synchronized
places**, now spread across two files: in `cli.cc` the `option_*` enum, the
`long_options[]` getopt table, the `switch (options_index)` handler, and the
`command_options[]` / `valid_options[][]` matrices; and in `vsearch.cc` the
`cmd_help` help text. Adding or renaming an option still means editing all five
in lockstep (now across `cli.cc` *and* `vsearch.cc`). The extraction moved the
duplication; it did not remove it — see E2/E3 in `CODE_REVIEW.md`.

**Configuration lives in global state, mid-migration.** ~255 `opt_*` globals are
declared in `vsearch.h`. A half-finished refactor introduced a `Parameters`
struct that duplicates ~150 of them. Today the top-level command *dispatchers*
read `parameters.opt_*` while the *core compute* paths (`searchcore.cc`,
chimera scoring, etc.) read the bare `opt_*` globals. The library entry point
`vsearch_init_defaults()` resets only the globals, not the struct. Treat config
as global, single-threaded setup; be aware which copy a given code path reads.

**One shared search engine underlies search, clustering, and chimera
detection.** `db.cc` loads all sequences into one large buffer (`datap`) indexed
by `seqindex`; `dbindex.cc` builds the k-mer index; `searchcore.cc` is the
common engine those three commands call. The actual alignment is
`align_simd.cc` — SIMD parallel global Needleman-Wunsch of **1 query against 8
database sequences at once**, with `linmemalign.cc` for the linear-memory case.
Nucleotides are 2-bit/4-bit encoded via `utils/maps.cpp` (index lookup tables
through `to_uchar()` accessors).

**SIMD is dispatched at runtime.** `cpu.cc` is still compiled multiple times into
`libcpu_sse2.a` / `libcpu_ssse3.a` (plus `_pic` variants; see `src/Makefile.am`)
for the instruction-set-specific code (e.g. `increment_counters_from_bitmap`).
The runtime *detection* was extracted from `vsearch.cc` into
`utils/cpu_features.cpp/.hpp` — `cpu_features_detect()` / `cpu_features_show()`,
called from `main()`, set the `sse2_present` / `ssse3_present` / `avx*_present`
globals used to pick SSE2 vs SSSE3 on x86_64. AltiVec/VSX and Neon have native
paths; `riscv64`/`mips64el` and other little-endian targets use the SIMDe
fallback (`libsimde-dev`). Binary on-disk formats (UDB, SFF) assume a
little-endian host.

**64-bit only — never built for 32-bit.** Every supported target
(`x86_64`, `aarch64`, `ppc64le`, `riscv64`, `mips64el`, …) is 64-bit, so
`size_t`/pointers are 64-bit everywhere vsearch runs. This matters when reasoning
about allocation overflow: a `count * sizeof(T)` product where `count` is bounded
by `int` (or an option cap) **cannot** wrap a 64-bit `size_t` — the process
exhausts memory and `xmalloc`-fatals long before any wrap — so guarding those
multiplies buys nothing here. What *can* still overflow is the **addition of
multiple 64-bit values** (e.g. summing file-derived UDB region sizes), which is
why those additions are overflow-checked (`udb_checked_add`) while the `int`-bounded
`count*size` multiplies are not.

**I/O flow.** `fastx.cc` sniffs FASTA vs FASTQ and dispatches to `fasta.cc` /
`fastq.cc`; `results.cc` formats all the output flavours (alnout, userout,
blast6, uc, SAM). All textual output goes through `fprintf` to `FILE *`.

**Error handling is process termination.** `fatal()` (`utils/fatal.cpp`) is
`__attribute__((noreturn))` and calls `std::exit(EXIT_FAILURE)`. There is no
recoverable error channel — important for the library API, where an error in a
core routine terminates the caller's process.

**Concurrency model.** The multithreaded commands (search, cluster, chimera,
sintax, allpairs, orient, mask, fastq_mergepairs) use a small RAII worker pool,
`ThreadRunner` (`utils/threads.hpp`, `std::thread`), which replaced the older
hand-rolled pthread pools. Because `fatal()` calls `std::exit()`, **a worker
thread must never call `fatal()`/`std::exit()`** — terminating from a non-main
thread crashes intermittently (the CC2–CC4 class in `CODE_REVIEW.md`). Instead a
worker records the first error in shared state and stops cooperatively — or, for
query-parse errors, uses the `fastx` deferred-error channel
(`fastx_set_deferred_error()`) — and the **main** thread calls `fatal()` *after*
the `ThreadRunner` join. A ThreadSanitizer CI lane (`threadsanitizer.yml`) guards
this class of bug.

**Random numbers are reproducible across platforms.** `util.h` provides an
in-house RNG facility — `SplitMix64`, a 64-bit `random_base_seed()` (set once by
`random_init()` from `opt_randseed`, or the OS when 0), `random_substream_seed()`,
and `random_bounded()` (Lemire) / `random_shuffle()` (Fisher–Yates) used instead
of `std::uniform_int_distribution`/`std::shuffle` (both implementation-defined).
A given `--randseed` therefore reproduces on every platform; `sintax` seeds a
per-query `SplitMix64` from `(base seed, query number)` so results are also
independent of `--threads`. The legacy C-library `random()`/`arch_random` path
was removed (N3 in `CODE_REVIEW.md`).

**The library API has a strict lifecycle.** `vsearch_api.h` documents a required
sequence (`vsearch_init_defaults` → override `opt_*` → `apply_defaults_fixups`
→ `db_init`/`db_add` → `dust_all` → `dbindex_prepare` → per-subsystem session
init → per-thread state → per-query calls → teardown → `vsearch_session_end`).
A global session mutex serializes sessions; skipping `vsearch_session_end()`
deadlocks the next init. Per-command files also keep working state (file
handles, counters, thread coordination) in file-`static` variables, so the
commands are not reentrant.

## Documentation (two manual systems — keep both in sync)

The manual exists in **two parallel systems, both maintained upstream**, so a
user-visible documentation change must be made in *both*:

1. **`man/vsearch.1`** — the monolithic roff man page. It is the autotools
   source man page (`man/Makefile.am`: `dist_man_MANS = vsearch.1`) and the
   input from which the PDF/HTML manual is generated. Edit the roff directly.
2. **The per-command markdown system under `man/`** — one page per command in
   `man/commands/vsearch-<command>.1.md` (section 1), format/reference pages in
   `man/formats/` (section 5, e.g. fasta/fastq/sam/sff/udb/cigar), topic pages
   in `man/misc/` (section 7, e.g. `expected_error`, `nucleotides`,
   `pairwise_alignment_parameters`, `userfields`), the overview/changelog in
   `man/index.1.md`, and **shared option snippets** in
   `man/commands/fragments/` (and `man/formats/fragments/`) that are `#include`d
   into several pages (e.g. `option_randseed.md` is used by sintax, shuffle and
   subsample — edit the fragment once and it propagates). These build into roff
   pages via `man/scripts/generate_manpage*.sh` using **pandoc** (so a build
   check needs pandoc installed; em dashes are written `---`).

When changing option behaviour, update the roff in `vsearch.1` **and** the
matching markdown — either the per-command `.md` body or the shared
`fragments/option_*.md`, whichever holds that text. Keep these as separate man
commits from the source fix (same "one fix = one atomic commit" habit), but note
both manual systems are real source and **do** go upstream (unlike
`CODE_REVIEW.md` / `CLAUDE.md`).

## Known issues

`CODE_REVIEW.md` catalogues known bugs, security findings, and structural
issues with file:line references, severity ratings, and a suggested fix
sequence. Consult it before changing the option parser, the binary-format
parsers (UDB/SFF), the search/cluster hit handling, or the library lifecycle.

## Contributing a fix upstream

This is a development fork; upstream is `torognes/vsearch`. The fork keeps a
small set of files that must **never** go upstream — `CODE_REVIEW.md`,
`CLAUDE.md`, `.clang-tidy`, and the fork-only CI workflows
(`.github/workflows/{sanitizers,valgrind,threadsanitizer,static-analysis,static-analysis-clang-tidy,codeql}.yml`).
So you never merge a whole fork branch upstream; you lift the individual fix
commit(s) onto a branch based on upstream's tip and open a PR with exactly that
diff.

**Branch layout (important).** `trognes/master` is an **exact mirror of
`upstream/master`** — it carries *none* of the fork-only files, so it stays a
clean fast-forward of upstream. All fork work lives on **`trognes/dev`**, which
is `upstream/dev` plus a single fork-only commit (the docs, `.clang-tidy`, and
the extra CI workflows). **Develop on `dev`** (or a short-lived branch off it);
treat `master` as read-only-from-upstream and never commit to it directly.
Keeping it in sync:

- `master`: `git fetch upstream && git merge --ff-only upstream/master` (no
  fork commits → pure fast-forward, no force-push).
- `dev`: `git fetch upstream && git rebase upstream/dev` (re-stacks the lone
  fork-only commit) then `git push --force-with-lease origin dev`.

**The enabling habit: one fix = one atomic commit** touching only the real
source files for that fix, with a message written as if addressing upstream.
Keep edits to the review docs / CI workflows in *separate* commits (they live on
`dev` only). When fixes are isolated this way, sending one upstream is a single
`git cherry-pick`.

### Division of work (read this first)

Claude (in the cloud session) is **scoped to `trognes/vsearch` only**. It cannot
fetch from, push to, or open a PR against `torognes/vsearch`, and the cloud
session's git remote reaches only `trognes/vsearch`. The upstream PR is opened by
**you (the maintainer) on your own machine**, where both repositories are
reachable. The split is:

| Step | Who |
|------|-----|
| Make the fix as one atomic, source-only commit on `dev` (or a branch off it) | **Claude** |
| Push that commit to `trognes/vsearch` and report its SHA | **Claude** |
| Cherry-pick the commit onto a clean branch based on `upstream/master` | **You** |
| Build-check, push the clean branch to your fork, open the upstream PR | **You** |

Why you (not Claude) must do the cherry-pick: the cloud session's git remote
reaches only `trognes/vsearch`, never `torognes/vsearch`, so Claude can neither
fetch `upstream/master` nor push/PR there. You cherry-pick the lone fix commit
onto a clean branch off the real `upstream/master` (reachable only from your
machine) and open the PR. The fix commit is source-only, so its diff is exactly
the fix — no review-doc or CI noise rides along.

### What Claude hands you

When a fix is ready, Claude will give you: (1) the **fix commit SHA**, (2) the
**dev branch** it's on in `trognes/vsearch`, and (3) a suggested `fix/<name>`
branch name. Claude makes sure that commit touches only real source files so the
cherry-pick is clean.

### What you do to open the upstream PR (`torognes/vsearch`)

One-time setup, in your local clone (`origin` = your fork `trognes/vsearch`):

```bash
git remote add upstream https://github.com/torognes/vsearch.git
```

Per fix (substitute the SHA / names Claude reported):

```bash
git fetch upstream                                 # refresh upstream's tip
git fetch origin <dev-branch>                      # get Claude's commit from the fork
git switch -c fix/short-name upstream/master       # clean branch off upstream, not the fork
git cherry-pick <sha-of-fix>                        # lift just the fix commit(s)
./autogen.sh && ./configure CFLAGS="-O3" CXXFLAGS="-O3" && make ARFLAGS="cr"   # sanity build
git push -u origin fix/short-name                   # push the clean branch to YOUR fork
```

Then open the cross-fork PR (`trognes/vsearch` is a GitHub fork of
`torognes/vsearch`, so this works without a second fork) — either:

- **Web UI:** after the push, `trognes/vsearch` shows a "Compare & pull request"
  banner for `fix/short-name`. Click it, then set **base repository =
  `torognes/vsearch`**, **base = `master`**, head = `trognes/vsearch:fix/short-name`,
  and submit. (Double-check the base repo — GitHub sometimes defaults it to your
  fork.)
- **Direct compare URL:**
  `https://github.com/torognes/vsearch/compare/master...trognes:vsearch:fix/short-name?expand=1`

Because the branch is based on `upstream/master` and contains only the fix
commit, the PR diff is exactly the fix — no review-doc or CI noise.

### If a fix is entangled with unrelated changes

Isolate it before cherry-picking: `git cherry-pick -n <sha>` then unstage/keep
only the relevant hunks, or `git format-patch -1 <sha>`, edit the patch, and
`git am` it onto the clean branch.

