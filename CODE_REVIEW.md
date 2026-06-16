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

## Security findings

Memory-safety and input-validation issues from a dedicated security pass over
the parsers, format readers, allocation paths, and output formatting. The
recurring root cause is **a value taken from a file (or from a CLI offset)
used as a length or index without a range/ordering check**. Items marked
*verified* were confirmed by reading the surrounding code.

> Scope: input parsers, binary/DB format readers, allocation/low-level code,
> output formatting, and the core algorithm files (`search.cc`, `searchcore.cc`,
> `search_exact.cc`, `cluster.cc`, `chimera.cc`, `fastq_mergepairs.cc`,
> `derep*.cc`, `kmerhash.cc`, `unique.cc`).

### Confirmed memory-safety bugs

#### S1. Out-of-bounds heap write from unvalidated sequence numbers in a UDB file (Critical)

When reading a `.udb` database, the per-kmer sequence-number table
`kmerindex` is read verbatim from the file (`udb.cc:384`) with **no check
that each entry is `< seqcount`**. Those values are then used directly as bit
offsets: `bitmap_set(kmerbitmap[i], kmerindex[kmerhash[i]+j])`
(`udb.cc:519`), and `bitmap_set` writes `bitmap[seed_value >> 3] |= …`
(`bitmap.cc:98`) with no bounds check. The bitmap holds only `seqcount + 127`
bits (`udb.cc:515`). A crafted `.udb` with a `kmerindex` entry up to
`0xFFFFFFFF` produces a near-arbitrary-offset out-of-bounds heap write.

- **Reachability:** the normal `--db file.udb` path with bitmaps enabled —
  used by search, chimera, sintax, and orient commands.
- **Related:** the same unvalidated seqno values are later used to index
  `seqindex` / `dbindex_map` during search, so an OOB *read* is reachable even
  with bitmaps disabled.
- **Fix:** validate every `kmerindex` entry `< seqcount` on load.
- **Effort:** Low · **Impact:** High · **Criticality:** High · *verified*

#### S2. SFF clip-offset underflow → ~4 GB out-of-bounds read (High)

In `sff_convert` (`sff_convert.cc:540–577`), `clip_start` and `clip_end` are
derived from the file's clip fields. Each field is individually validated only
as `<= number_of_bases`; **nothing enforces `clip_start <= clip_end`**. With
`--sff_clip`, `length = clip_end - clip_start` (`sff_convert.cc:569`, both
`uint32_t`) underflows to ~4 billion when start > end, and
`bases.data() + clip_start` plus that length is passed to
`fastq_print_general` — a massive out-of-bounds read (same for the quality
buffer).

- **Reachability:** `--sff_clip` on a crafted SFF file. (Without `--sff_clip`,
  the offsets are reset to a safe range.)
- **Fix:** reject records where `clip_start > clip_end`.
- **Effort:** Low · **Impact:** Medium–High · **Criticality:** Medium–High · *verified*

#### S3. UDB header-length underflow → ~4 GB `headerlen` (High)

In `udb_read` (`udb.cc:420`), `headerlen = header_index[i+1] - current_index - 1`.
The validation loop rejects only *strictly* decreasing indices
(`current_index < last`, `udb.cc:415`), so **equal consecutive header indices
pass**. When `header_index[i+1] == current_index`, `headerlen` underflows to
`0xFFFFFFFF`. That bogus length flows into `longestheader` and into
`header_get_size(datap + header_p, headerlen)` reads when abundances are
parsed → out-of-bounds reads over the header region.

- **Reachability:** crafted `.udb` file.
- **Fix:** require `header_index[i+1] > current_index` (reject equal), or
  bound `headerlen` against the header region size.
- **Effort:** Low · **Impact:** Medium · **Criticality:** Medium · *verified*

#### S4. `--subseq_start` not bounded by sequence length → OOB read (Medium)

In `getseq` (`getseq.cc:459–497`), `--fastx_getsubseq` validates only
`start >= 1`, `end >= 1`, `start <= end` — never `start <= sequence_length`.
At runtime `start = max(opt_subseq_start, 1)`, `end = min(opt_subseq_end,
seqlen)`, `length = end - start + 1` (`getseq.cc:466`). For a sequence shorter
than `subseq_start` (e.g. seqlen 10, `--subseq_start 100`), `length` goes
negative and `fastx_get_sequence(h1) + start - 1` points past the buffer; the
negative length becomes a `printf` precision (treated as "none"), so the
formatter reads from the out-of-bounds pointer until a NUL byte. Same for the
quality pointer in the FASTQ path.

- **Reachability:** operator sets `--subseq_start` larger than some input
  sequence; trivially hit in a file with mixed-length sequences.
- **Fix:** skip/clamp when `start > seqlen` (emit empty or skip the record).
- **Effort:** Low · **Impact:** Medium · **Criticality:** Medium · *verified*

#### S10. Hit-list allocation vs. index-bound mismatch in clustering/search (High)

`si->hits` is allocated `sizeof(struct hit) * tophits` (`cluster.cc:366`), where
`tophits = min(opt_maxrejects + opt_maxaccepts + MAXDELAYED, seqcount)`
(`cluster.cc:1365–1366`). But `opt_maxaccepts` and `opt_maxrejects` are each
clamped only to `seqcount` individually (`cluster.cc:1355–1363`), so in
`evaluate_extra_hits` the insertion gate and the trash-bottom condition both use
`opt_maxaccepts + opt_maxrejects - 1` (`cluster.cc:669, 674`) — up to
`2*seqcount - 1`. When that bound exceeds the clamped `tophits`, `hit_count` is
allowed to grow past the `tophits`-sized buffer, and the shift loop /
`si->hits + x` writes (`cluster.cc:684–690`) run out of bounds. The
allocation-vs-bound inconsistency is verified; whether `hit_count` can actually
be driven past `tophits` for a given input (there are only `seqcount` distinct
DB targets, and insertion at `cluster.cc:690` does not dedup against existing
hits) needs runtime confirmation. The same `tophits` clamp pattern is used in
`search.cc` and `searchcore.cc`.

- **Reachability:** clustering a small input (small `seqcount`) with large
  `--maxaccepts` / `--maxrejects` whose sum exceeds `seqcount`.
- **Fix:** size the buffer by the same `opt_maxaccepts + opt_maxrejects(+MAXDELAYED)`
  bound used for indexing, or clamp the index bound to `tophits`.
- **Effort:** Low · **Impact:** High · **Criticality:** Medium · *verified (arithmetic); needs-confirmation (reachability) — suggest an ASan run*

### Hardening / latent issues (defense-in-depth)

#### S5. 64-bit sequence/header lengths truncated to `int` in the print path (Medium)

`fasta_print_sequence` casts `uint64_t len` to `int` (`fasta.cc:417`), and
`fasta_print_general` / `fastq_print_general` take `int` length parameters
(`fasta.cc:459`, `fastq.cc:666`); callers narrow `uint64_t` lengths to `int`
(`fasta2fastq.cc:110–116`, `fastqops.cc:172–195`). A single sequence or header
larger than `INT_MAX` (~2 GB) makes the length negative, producing wrong
offsets / out-of-bounds reads in the `"%.*s"` formatting. The buffer *sizing*
itself is correct; only the print interface narrows.

- **Reachability:** requires a >2 GB single sequence/header.
- **Fix:** carry these lengths as `int64_t`/`size_t` through the print interfaces.
- **Effort:** Medium · **Impact:** Medium · **Criticality:** Low · *verified (truncation); gated on >2 GB input*

#### S6. Unchecked additive allocation size in UDB load (Medium)

`datap = xmalloc(udb_headerchars + nucleotides + seqcount)` (`udb.cc:428`)
sums three file-derived 64-bit values with no overflow guard; a wrap yields an
undersized buffer that the following `largeread`/`memmove` would overflow. In
practice gated by real file size (`largeread` fatals if the file is shorter,
and a final `pos == filesize` check exists), so hard to hit, but unguarded.

- **Effort:** Low · **Impact:** Medium · **Criticality:** Low · *needs-confirmation (gated by file size)*

#### S7. Allocation wrappers do no overflow checking; callers pass `count * size` (Low–Medium)

`xmalloc`/`xrealloc` (`arch.cc:220–255`) only enforce a minimum size of 1 and
a non-null result — **no overflow detection**. So any `count * sizeof(T)`
computed at a call site that wraps silently under-allocates. Notable callers
to confirm upstream bounds for: `minheap_init` (`minheap.cc:153`,
`size * sizeof(elem_t)` with signed `int size` from `tophits`) and
`search16_qprep` (`align_simd.cc:1238, 1245`, `2 * qlen * sizeof(VECTOR_SHORT)`
with `int qlen`). Currently bounded in practice by the SIMD
`maxseqlenproduct = 25,000,000` cap and option limits, but the wrappers offer
no safety net.

- **Effort:** Low (add overflow-checked helper) · **Impact:** Medium · **Criticality:** Low · *needs-confirmation per caller*

#### S8. `md5.c` `body()` unsigned-underflow loop if called with `size == 0` (Low)

`body()` ends with `} while (size -= 64);` (`md5.c:200`); a `size` of 0 would
underflow to ~`ULONG_MAX` and read far out of bounds. All current callers pass
a non-zero multiple of 64, so it is **not currently reachable** — latent only.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *latent, not reachable*

#### S9. `seqcount + 1` vector sizing can wrap at `UINT_MAX` (Low)

`std::vector<int> header_index(seqcount + 1)` (`udb.cc:405`) with `seqcount`
only checked `!= 0`; at `0xFFFFFFFF` the `+1` wraps to 0 and subsequent writes
go out of bounds. Large allocations elsewhere would likely fail first.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *needs-confirmation*

#### S11. Wrong `sizeof` in `dbmatched` allocation (Low, latent)

`dbmatched = (uint64_t *) xmalloc(seqcount * sizeof(uint64_t *))`
(`search_exact.cc:748`, `search.cc:838`) sizes an array of `uint64_t` using
`sizeof(uint64_t *)`. Benign on mainstream 64-bit platforms (both are 8 bytes,
so it is an exact-fit, not an overflow), but it is a wrong-type `sizeof` worth
correcting for portability/correctness.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *verified, benign on 64-bit*

#### S12. Signed `int` left-shift overflow in DUST k-mer accumulator (Low — confirmed by CI sanitizers)

`mask.cc:101` in `wo()` (called from `dust_core` → `dust`): the k-mer
accumulator `word` is a signed `int` (`auto word = 0;`) and is shifted with
`word <<= 2U` before being masked. Once enough 2-bit codes accumulate, the
left shift exceeds `INT_MAX`, which is undefined behavior. UBSan flagged it on
the very first masking command of the test suite:

```
mask.cc:101:12: runtime error: left shift of <value> by 2 places cannot be represented in type 'int'
```

Behaviour-preserving fix (later): make `word` unsigned — the stored value is
already masked, so downstream indexing is unaffected. This is the same
*class* as S5 (signed-overflow / width issues) but a distinct, concrete site.

- **Effort:** Low · **Impact:** Low (UB; benign in practice as the value is masked) · **Criticality:** Low · *verified by CI ASan/UBSan run*

### Sanitizer inventory — CI run (ASan + UBSan over the vsearch-tests suite)

The `Sanitizers (ASan/UBSan)` CI workflow builds vsearch with
AddressSanitizer + UndefinedBehaviorSanitizer and runs the full
`frederic-mahe/vsearch-tests` suite under instrumentation. A non-gating
"inventory" run over the whole suite produced exactly one finding:

- **UBSan:** `mask.cc:101` — the signed left-shift overflow above (S12), the
  only UB site reported.
- **AddressSanitizer:** **no errors** anywhere in the suite — no
  out-of-bounds, use-after-free, or related memory corruption on the inputs
  the suite exercises.

Important caveat: the suite uses **valid / well-formed inputs**, so this run
does **not** exercise the malformed-input bugs S1–S4 (crafted `.udb`/`.sff`
files, out-of-range `--subseq_start`). Those still require targeted crafted
inputs and/or fuzzing; the green ASan result here is not evidence they are
absent.

### Checked and found safe (no action)

- **No format-string vulnerabilities.** Across `results.cc`, `otutable.cc`,
  `getseq.cc`, `cut.cc`, `showalign.cc`, `msa.cc`, every header/label/user
  string is passed as a `%s`/`%.*s` *argument*, never as the format string.
- **SIMD CIGAR / direction buffers** in `align_simd.cc` are internally
  consistent and bounded by the `maxseqlenproduct = 25,000,000` product cap;
  the backtrack CIGAR buffer sizing (`qlen + maxdlen + 1`) is provably
  sufficient.
- **Hash/digest routines** (`city.cc`, `md5.c`, `sha1.c`) handle their length
  parameters with in-bounds reads; lengths flow only into hashing math, not
  allocations (except S8's latent case).
- **FASTA/FASTQ line buffers** (`fastx.cc`) grow via bounded realloc; header /
  sequence / quality copies use correctly-derived `memcpy` lengths, and
  256-element lookup tables are indexed by `unsigned char`. The quality-vs-
  sequence length mismatch is caught and fatal (`fastq.cc:565`).
- **`userfields.cc`** rejects empty tokens; the requested-fields array is sized
  to the token count.
- **Core algorithm k-mer/merge math** traced and found bounded: k-mer sample
  values are masked to the table size before indexing (`unique.cc`,
  `kmerhash.cc`); the pair-merge buffers in `fastq_mergepairs.cc` are sized
  `fwd_length + rev_length + 1` with merge offsets provably within that; the
  chimera alignment buffers are sized from query + parent lengths with the
  partition asserting its length fits; and the derep hash tables are
  power-of-two masked. (Note: `count_t` is `unsigned short` and can saturate at
  65535 matches — a ranking-accuracy limitation, not a memory-safety bug.)

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
| S1 | UDB `kmerindex` seqno → OOB heap write (`bitmap_set`) | Security | Low | High | High |
| S2 | SFF clip-offset underflow → OOB read (`--sff_clip`) | Security | Low | Med–High | Med–High |
| S3 | UDB header-length underflow → ~4 GB `headerlen` | Security | Low | Medium | Medium |
| S4 | `--subseq_start` unbounded → OOB read | Security | Low | Medium | Medium |
| S10 | Hit-list alloc vs. index-bound mismatch (cluster/search) | Security | Low | High | Medium |
| S5 | 64-bit length → `int` truncation in print path | Security | Medium | Medium | Low |
| S6 | UDB additive allocation size unchecked | Security | Low | Medium | Low |
| S7 | `xmalloc`/`xrealloc` no overflow check; `count*size` callers | Security | Low | Medium | Low |
| S8 | `md5.c` `body()` underflow if `size==0` (latent) | Security | Low | Low | Low |
| S9 | UDB `seqcount+1` wrap at `UINT_MAX` | Security | Low | Low | Low |
| S11 | Wrong `sizeof` in `dbmatched` alloc (latent) | Security | Low | Low | Low |
| S12 | DUST k-mer accumulator `int` left-shift overflow (CI-confirmed) | Security | Low | Low | Low |
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

1. **Security first.** **S1** (critical OOB write from a crafted `.udb`), then
   **S2**, **S3**, **S4**, **S10** — all small, localized input/range checks.
   Confirm **S10** with an AddressSanitizer run. **S5–S9, S11** are
   hardening/latent and can follow.
2. **B1** — isolated, low-risk correctness fix.
3. **E5**, **E8**, **E9** — quick, low-risk cleanups with immediate line-count payoff.
4. **E2 → E1 → E4** — the core architectural thread (single option table, finish
   the `Parameters` migration, then eliminate global state); E4 directly improves
   library-API safety.
5. **E3**, **E6**, **E7** — structural decomposition, largely unlocked by the above.

> Note: several findings (S1–S4, S5, S6, S9) trace to file/CLI-derived values
> used as lengths or indices without validation. A small set of shared
> "validate-on-load" helpers for the binary parsers would address several at
> once and prevent recurrence.
