# vsearch — Code Review Findings

This document collects code-quality issues identified during a review of the
vsearch source tree. It is **review only** — no code has been changed.
Testing and documentation are out of scope and not covered here.

Issues are split into two groups:

- **Bugs** — defects that produce incorrect behaviour.
- **Enhancements** — refactoring, deduplication, and structural improvements
  that do not change observable behaviour (except where noted).

Line numbers are approximate and refer to the tree at commit `6157fc3`.

Effort / Impact / Criticality are rated **Low / Medium / High**:
- **Effort** — estimated work to implement.
- **Impact** — value gained (maintainability, correctness, performance, safety).
- **Criticality** — urgency / risk of leaving it unaddressed.

---

## Bugs

### B1. `--log` quality-error messages written to `stderr` instead of the log file

The "FASTQ quality value below qmin" fatal-error branch re-emits to `stderr`
from inside an `if (fp_log != nullptr)` guard, instead of writing to `fp_log`.
When a `--log` file is given, the qmin message is printed to `stderr` twice and
never reaches the log. The qmax branch immediately below each occurrence is
written correctly (`fprintf(fp_log, …)`), which confirms the qmin branch is a
copy-paste slip. An exhaustive sweep found exactly three occurrences:

| File | Line | Function / context |
|------|------|--------------------|
| `src/fastq_mergepairs.cc` | ~278 | `get_qual()`, qmin branch |
| `src/eestats.cc` | ~87 | quality check, qmin branch |
| `src/filter.cc` | ~85 | quality check, qmin branch (note `std::fprintf`) |

- **Type:** Bug (incorrect output destination)
- **Fix:** one-token change per site, `stderr` → `fp_log` (keep `std::` prefix in filter.cc).
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Medium
- **Note:** The three blocks are near-identical and likely share an ancestor;
  a shared quality-check helper (see E8) would collapse this to one point of
  correctness.

---

## Enhancements

### E1. Half-finished migration from global `opt_*` variables to the `Parameters` struct

A migration to move configuration out of global state into a `Parameters`
struct (`src/vsearch.h:435`) is stuck halfway. ~334 global `opt_*` declarations
still live in `vsearch.h`, while `Parameters` duplicates ~150 of the same
fields. `args_init` dual-writes both (~433 bare `opt_x = …` assignments
alongside ~265 `parameters.opt_x = …`). Some options set both, some only one.
Two parallel copies of the same state that can silently drift is a latent
bug source. Breadcrumbs in the struct confirm the in-progress state
(e.g. `progname … // refactoring: unused?`).

- **Location:** `src/vsearch.cc` (`args_init`), `src/vsearch.h:435`
- **Effort:** High · **Impact:** High · **Criticality:** Medium
- **Direction:** finish in one direction — everything reads from `Parameters`,
  remove the globals.

### E2. Parallel option-metadata tables (five places to edit per option)

Each of ~248 CLI options is declared in five separate, manually-synchronized
places inside `args_init`: the `option_*` enum (~line 1125), the
`long_options[]` getopt table (~1376), the `switch (options_index)` handler
(~1643), the `command_options[]` / `valid_options[][]` matrices (~2815, ~2876),
and the hand-written help text in `cmd_help` (~5249). Adding or renaming an
option means editing all five in lockstep with nothing enforcing consistency
(enum order must match the array; `valid_options` is a hand-maintained ~50×100
integer matrix). This is the main source of the file's bulk.

- **Location:** `src/vsearch.cc`, `args_init` / `cmd_help`
- **Effort:** High · **Impact:** High · **Criticality:** Medium
- **Direction:** single declarative option table (name, arg type, target field,
  owning commands, help string) consumed by parser, validator, and help printer.

### E3. `vsearch.cc` monolith dominated by one ~4,000-line function

`src/vsearch.cc` is ~6,340 lines; `args_init` alone runs ~1106–5187 (~4,000
lines), and `cmd_help` adds ~490 more. The file also mixes CPU detection,
argument-value parsers, CLI definition/validation, help text, and command
dispatch. Should be split into separate translation units (e.g. `cli_parse.cc`,
`cli_help.cc`, `cli_dispatch.cc`).

- **Location:** `src/vsearch.cc`
- **Effort:** High · **Impact:** High · **Criticality:** Low–Medium
- **Note:** Largely unlocked by E1 + E2; sequence them E2 → E1 → E3.

### E4. Pervasive module-scope mutable global state (reentrancy / thread-safety)

Across the large command files, working state (file handles, counters, thread
coordination, data tables) lives in file-`static` variables rather than being
passed through context. This makes the commands non-reentrant and unsafe to use
concurrently — significant because the project ships a library API
(`vsearch_api.h`, `LIBRARY_API.md`).

| File | Lines | Examples |
|------|-------|----------|
| `src/chimera.cc` | ~110–132 | `tophits`, `pthread`, `cia`, chimera/nonchimera/borderline counters & abundances, 5 `fp_*` (comment at :110 notes "on both sides of a pthread wall") |
| `src/cluster.cc` | ~89–123 | `clusterinfo`, `clusters`, `cluster_abundance`, 13 `fp_*`, `si_plus`/`si_minus` |
| `src/search.cc` | ~83–120 | `si_plus`/`si_minus`, `tophits`, `seqcount`, `query_fastx_h`, 16 `fp_*`, partly-guarded counters |
| `src/fastq_mergepairs.cc` | ~97–247 | ~31 statics: 7 file handles, ~15 `failed_*` counters, accumulators, chunk-coordination block |
| `src/align_simd.cc` | ~111 | `scorematrix` written unsynchronized by `search16_init` |

- **Effort:** High · **Impact:** High · **Criticality:** Medium–High (library API)
- **Direction:** fold state into per-invocation context structs (same shape as E1).
- **Related fragility:** `cluster.cc` `cluster_assign_batch` (~1954–1968) saves
  `si_plus`/`si_minus`, overwrites them with fresh allocations, then restores —
  an early return between save and restore corrupts global state.

### E5. Output-file open/close boilerplate duplicated 50+ times

The identical pattern
`if (opt_X != nullptr) { fp_X = fopen_output(opt_X); if (fp_X == nullptr) fatal(...); }`
(and the mirrored close) is repeated per output format across files. A
table-driven helper would erase several hundred lines. A breadcrumb already
exists (`// refactoring: replace with check_optional_output_handle()` at
`fastq_mergepairs.cc:250`) and a helper already lives in
`src/utils/check_output_filehandle.*`.

| File | Lines | Count |
|------|-------|-------|
| `src/search.cc` | open ~584–711; close ~760–813 | ~13 open + ~12 close |
| `src/cluster.cc` | ~1194–1321 | ~14 |
| `src/fastq_mergepairs.cc` | open ~1619–1646; close ~1678–1705 | 7 + 7 |
| `src/chimera.cc` | (same pattern) | several |

- **Effort:** Low–Medium · **Impact:** Medium · **Criticality:** Low
- **Note:** Easiest large line-count win; low risk.

### E6. Oversized functions mixing orchestration, I/O, and computation

Long functions that interleave setup, computation, and output and should be
decomposed:

| File | Function | Approx. lines | Size |
|------|----------|---------------|------|
| `src/chimera.cc` | `eval_parents` | ~1165–1794 | ~629 |
| `src/chimera.cc` | `chimera` | ~2353–2689 | ~336 |
| `src/chimera.cc` | `chimera_thread_core` | ~2067–2299 | ~232 |
| `src/align_simd.cc` | `search16` | ~1281–1857 | ~577 (easy/hard-path state machine) |
| `src/cluster.cc` | `cluster` | ~1190–1772 | ~582 |
| `src/cluster.cc` | `evaluate_extra_hits` | ~626–869 | ~244 |
| `src/search.cc` | `usearch_global` | ~816–1019 | ~204 |
| `src/search.cc` | `search_output_results` | ~121–322 | ~202 (10+ format dispatch) |
| `src/fastq_mergepairs.cc` | `print_stats` | ~1429–1532 | ~199 (15+ repeated if-blocks) |
| `src/fastq_mergepairs.cc` | `optimize` | ~159 | ~159 |

- **Effort:** Medium–High (per function) · **Impact:** Medium · **Criticality:** Low

### E7. Near-identical code paths that should be merged

- **`align_simd.cc`** — `aligncolumns_first` (~570–735) and `aligncolumns_rest`
  (~738–873) are ~95% identical; the difference is boundary masking that could
  be a flag/parameter. ~165 duplicated lines.
- **`search.cc`** — `search_session_single` (~1072–1168) and
  `search_batch_worker_fn` (~1218–1334) share ~50–60 lines of identical
  query-processing and result-population logic (session API vs batch API).
- **`fastq_mergepairs.cc`** — forward/reverse read handling is copy-pasted in
  `process` (truncation + N-counting, ~946–1026) and `discard` (output blocks,
  ~578–634).

- **Effort:** Medium · **Impact:** Medium · **Criticality:** Low

### E8. Duplicated `struct Scoring` initialization (with a redundant line)

The ~18-line `struct Scoring` setup is copy-pasted across `chimera.cc` and
`cluster.cc` (multiple times each). Within each block,
`scoring.gap_open_query_interior = opt_gap_open_query_interior;` appears
**twice** (`chimera.cc` ~2076 & ~2080; `cluster.cc` ~921 & ~925). The value is
identical so behaviour is unaffected (a smell, not a bug), but it's a clear
copy-paste artifact. A shared initializer helper would remove the duplication
and prevent recurrence.

- **Location:** `src/chimera.cc` ~2073–2089; `src/cluster.cc` ~918–934 (and other call sites)
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Low

### E9. Dead code / leftover debug blocks

- `src/align_simd.cc` — ~60 lines of `#if 0` debug printing in `backtrack16`
  (~935–993); smaller `#if 0` dumps at ~303–312 and ~479–481.
- `src/cluster.cc` — always-true `#if 1` blocks (~961, ~1114), leftover debug toggles.
- Assorted refactoring-breadcrumb comments in `chimera.cc` / `cluster.cc`
  (e.g. "refactoring: …", "this is a test").

- **Effort:** Low · **Impact:** Low · **Criticality:** Low

### E10. Per-file license header duplicated across the tree

The ~52-line GPL/BSD header block is repeated in 107 source files. Low value
and low risk; listed for completeness only.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low

---

## Summary table

| ID | Title | Type | Effort | Impact | Criticality |
|----|-------|------|--------|--------|-------------|
| B1 | `--log` qmin message → `stderr` not `fp_log` (×3) | Bug | Low | Low–Med | Medium |
| E1 | Finish `opt_*` → `Parameters` migration | Enhancement | High | High | Medium |
| E2 | Single source of truth for option metadata | Enhancement | High | High | Medium |
| E3 | Split `vsearch.cc` monolith | Enhancement | High | High | Low–Med |
| E4 | Remove module-scope global state (reentrancy) | Enhancement | High | High | Med–High |
| E5 | Deduplicate output-file open/close boilerplate | Enhancement | Low–Med | Medium | Low |
| E6 | Decompose oversized functions | Enhancement | Med–High | Medium | Low |
| E7 | Merge near-identical code paths | Enhancement | Medium | Medium | Low |
| E8 | Shared `struct Scoring` initializer | Enhancement | Low | Low–Med | Low |
| E9 | Remove dead/debug code | Enhancement | Low | Low | Low |
| E10 | Deduplicate license headers | Enhancement | Low | Low | Low |

## Suggested sequencing

1. **B1** — isolated, low-risk correctness fix.
2. **E5**, **E8**, **E9** — quick, low-risk cleanups with immediate line-count payoff.
3. **E2 → E1 → E4** — the core architectural thread (single option table, finish
   the `Parameters` migration, then eliminate global state); E4 directly improves
   library-API safety.
4. **E3**, **E6**, **E7** — structural decomposition, largely unlocked by the above.
