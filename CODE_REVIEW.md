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

## Review coverage matrix

A systematic file-by-file deep audit is in progress, processed by subsystem
tier (one PR per tier). Status legend: **audited** = read in full against the
8-lens checklist this pass; *prior* = covered by earlier targeted reviews;
*pending* = not yet swept.

| Tier | Files | Status |
|------|-------|--------|
| **1 — input parsers & DB load** | `fastx`, `fasta`, `fastq`, `fasta2fastq`, `fastq_chars`, `sff_convert`, `udb`, `db`, `dbhash`, `dbindex`, `userfields` (+ headers) | **audited** (this pass → S13–S16, L2, plus folded sites in S5/N1/P1 and corrections to N1(c)/C1(c)) |
| **2 — core compute engines** | `searchcore`, `search`, `search_exact`, `align_simd`, `linmemalign`, `cluster`, `chimera`, `allpairs`, `sintax`, `orient`, `mask`, `kmerhash`, `unique` | **audited** (this pass → S17–S19, N2; S10 reachability confirmed; S13 generalized; folded sites in S5/S7/N1/P1/L1/L2/E6/E9) |
| 3 — dereplication & seq ops | `derep`, `derep_prefix`, `derep_smallmem`, `rereplicate`, `shuffle`, `subsample`, `sortbylength`, `sortbysize`, `cut`, `getseq` | *pending* |
| 4 — output, formatting & stats | `results`, `otutable`, `msa`, `showalign`, `fastq_stats`, `eestats`, `fastqops`, `fastq_join`, `filter`, `tax` | *pending* |
| 5 — CLI/dispatch & infra | `vsearch.cc`, `util`, `arch`, `cpu`, `attributes`, `dynlibs`, `bitmap`, `minheap`, `city`, `md5`, `sha1` | *pending* |
| 6 — headers & `utils/` | all `*.h`, `src/utils/*.hpp` | *pending* |

---

## Bugs

### B1. `--log` quality-error messages written to `stderr` instead of the log file

**Status: partially fixed upstream (2 of 3 sites).** The `eestats.cc` and
`filter.cc` sites were corrected in `trognes/master` (commit `310e7de`,
"fix: write to logfile instead of stderr"). The `fastq_mergepairs.cc` site
remains.

The "FASTQ quality value below qmin" fatal-error branch re-emits to `stderr`
from inside an `if (fp_log != nullptr)` guard, instead of writing to `fp_log`.
When a `--log` file is given, the qmin message is printed to `stderr` twice and
never reaches the log. The qmax branch immediately below each occurrence is
written correctly (`fprintf(fp_log, …)`), which confirms the qmin branch is a
copy-paste slip. An exhaustive sweep originally found three occurrences:

| File | Line | Function / context | State |
|------|------|--------------------|-------|
| `src/fastq_mergepairs.cc` | ~278 | `get_qual()`, qmin branch | **open** |
| `src/eestats.cc` | ~87 | quality check, qmin branch | fixed (`310e7de`) |
| `src/filter.cc` | ~85 | quality check, qmin branch (note `std::fprintf`) | fixed (`310e7de`) |

- **Type:** Bug (incorrect output destination)
- **Remaining fix:** one-token change at `fastq_mergepairs.cc:278`, `stderr` → `fp_log`.
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Medium
- **Note:** The three blocks are near-identical and likely share an ancestor;
  a shared quality-check helper (see E8) would collapse this to one point of
  correctness. The upstream fix patched two sites independently rather than
  introducing such a helper, so the duplication (and the third site) persists.

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
- **Effort:** Low · **Impact:** High · **Criticality:** Medium · *verified (arithmetic **and reachability**)*
- **Reachability confirmed (Tier-2 audit).** The over-write is a real ordering,
  not just arithmetic: OOB requires `opt_maxaccepts + opt_maxrejects - 1 ≥
  tophits`, i.e. `seqcount < opt_maxaccepts + opt_maxrejects - 1` so that
  `seqcount` is the binding `min` in `tophits = min(sum+MAXDELAYED, seqcount)`.
  `evaluate_extra_hits` then drives `hit_count` up to `opt_maxaccepts +
  opt_maxrejects - 1` (the trash block pins it there), past the `seqcount`-sized
  buffer. The CI suite misses it only because its default `--maxaccepts 1
  --maxrejects 32` against >33 sequences makes the *sum* the binding clamp.
  Suggested ASan repro: ~5 sequences with `--maxaccepts 100 --maxrejects 100`
  under `--cluster_size`/`--cluster_fast` with several no-hit rounds feeding
  `extra_list` → `hit_count` ~199 against a `tophits = 5` buffer. The 64-bit→`int`
  width of `tophits`/the index bound (`opt_max*` are `int64_t`) compounds it and
  is the canonical fix point (clamp the index bound to `tophits`).

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
- **Additional sites (Tier-1 audit):** `fasta.cc:417, 426, 452–456, 459–472`,
  `fastq.cc:659–675, 764–765`, `fasta2fastq.cc:110–114`. The same narrowing also
  occurs on the *storage* side in the DB index struct — see the N1(c) note on
  `seqinfo_s.seqlen`/`headerlen` being `unsigned int` with an unbounded
  `opt_maxseqlength`.
- **Additional sites (Tier-2 audit) — with a write-overflow twist:** the library
  search entry points narrow `std::strlen(query_head)` to `int head_len`
  (`search.cc:1081` `search_session_single`, `search.cc:1244`
  `search_batch_worker_fn`); a negative `head_len` then mis-drives the
  `query_head` realloc decision so a `strcpy` can overflow the buffer. Library
  API only, gated on a >2 GB header — defense-in-depth, but unlike the read-only
  print-path sites this one can corrupt the heap.

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
- **Additional caller (Tier-2):** `chimera_detect_batch` does
  `ctx.ci_array = xmalloc(nthreads * sizeof(ptr))` with `nthreads = max(1,
  opt_threads)` (`chimera.cc:2975`); on the library path `opt_threads` is
  caller-supplied, so a pathological value makes the multiply wrap and the
  following per-thread init loop write out of bounds. Bound `opt_threads` /
  use the overflow-checked helper.

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

#### S13. `opt_wordlength` range-validated only on the CLI; library path → shift UB and undersized k-mer index (Medium)

`dbindex_prepare` computes `kmerhashsize = 1U << (2 * opt_wordlength)`
(`dbindex.cc:179`) and sizes `kmercount`/`kmerbitmap`/`kmerhash`/`kmerindex`
from it. `opt_wordlength` is range-checked to `[3,15]` on **both CLI paths**
(`vsearch.cc:1683` and `:4908`), so `1U << 30` is the CLI maximum and safe. But
the library entry point `vsearch_apply_defaults_fixups()` (`vsearch.cc:1081–1087`)
only maps the `0` sentinel to a default — it does **not** enforce `[3,15]`. A
library caller (the documented "override `opt_*` → call fixups → `dbindex_prepare`"
sequence) that sets `opt_wordlength` ≥ 16 makes the shift count ≥ 32 on a 32-bit
`unsigned` (undefined behavior), and ≥ 32 makes it ≥ 64. Worse, `unique_count`
masks k-mer values to the *true* `2*wordlength` width, so the k-mer value can
exceed an undersized `kmerhashsize`, giving out-of-bounds writes to
`kmercount[kmer]` / `kmerbitmap[kmer]` (`dbindex.cc:148–153`).

- **Reachability:** library API only (not CLI); a `libvsearch_core.a` consumer
  setting `opt_wordlength` outside `[3,15]`. `LIBRARY_API.md` documents it as a
  user-set knob.
- **Fix:** move the `[3,15]` validation into `vsearch_apply_defaults_fixups()`
  (fatal on out-of-range) so CLI and library share one bound; compute the shift
  in 64-bit (`1ULL`).
- **Effort:** Low · **Impact:** High · **Criticality:** Medium · *verified
  (mechanism + missing guard); library-reachable, not CLI* · related L1/C1.
- **This is a class, not a one-off.** The same "CLI-only validation, library
  fixup doesn't re-check" root cause recurs at several sites the Tier-2 audit
  found; the single fix is to validate all such knobs in
  `vsearch_apply_defaults_fixups()`:
  - **`opt_chimeras_parents_max`** → OOB *write* in `find_best_parents_long`
    (its own finding **S17**, High).
  - **`opt_wordlength`** in `orient.cc` `rc_kmer` (the `rev <<= 2U` accumulator,
    guarded only by an NDEBUG-stripped `assert(opt_wordlength*2 <= 32)` at
    `orient.cc:91`) → silent wrong reverse-complement / strand counts for
    `opt_wordlength ≥ 16`.
  - **`opt_wordlength`** in `unique_count_hash` (`unique.cc:293`), where the
    k-mer mask is computed as `(1ULL << 2*wordlength) - 1` then **narrowed to a
    32-bit `unsigned int`** — exact for `wordlength ≤ 15`, silently undersized
    (hash collisions) at `≥ 16`. The bitmap variant (`unique.cc:206`) uses a
    64-bit mask, so the two diverge exactly at the boundary the CLI bound
    protects.
  - **`opt_threads`** in `chimera_detect_batch` (`chimera.cc:2975`) →
    `nthreads * sizeof(ptr)` is an unchecked multiply (S7 class) on a
    library-supplied thread count.

#### S14. UDB header/length tables stored as `std::vector<int>` for unsigned 32-bit file values (Medium)

`udb_read` reads the per-sequence header offsets and lengths straight from the
file into **signed** containers: `std::vector<int> header_index(seqcount + 1)`
(`udb.cc:405`, filled by `largeread`) and `std::vector<int>
sequence_lengths(seqcount)` (`udb.cc:440`). A file value with the top bit set is
a negative `int`; `header_index[i+1] - current_index - 1` (`udb.cc:420`) then
mixes signed elements in the `headerlen` computation, and `header_index[seqcount]
= udb_headerchars` narrows a `uint64_t` into an `int` slot (`udb.cc:409`). This
is the type-level root cause underneath **S3** (headerlen underflow) and **S9**
(`seqcount+1` wrap): the storage type itself is wrong.

- **Reachability:** crafted `.udb` with offsets/lengths ≥ `0x80000000`.
- **Fix:** use `std::vector<uint32_t>`; validate each value against the
  header/nucleotide region before use (closes S3/S9 at the source).
- **Effort:** Low · **Impact:** Medium · **Criticality:** Medium · *verified
  (types)* · underlies S3, S9.

#### S15. SFF flowgram-skip uses the wrong short-read threshold → silent offset desync (Medium)

In `sff_convert` the flowgram section is skipped with
`if (fskip(fp_sff.get(), 2UL * flows_per_read) < flows_per_read) fatal(...)`
(`sff_convert.cc:512`). It requests `2 * flows_per_read` bytes but only fatals if
**fewer than `flows_per_read`** (half) were skipped. On a file truncated so that
between `flows_per_read` and `2*flows_per_read − 1` bytes remain, `fskip` returns
the partial count, the check passes, and `filepos` is advanced by the full
`2*flows_per_read` (`sff_convert.cc:516`) — desynchronizing every subsequent
offset test (including the `index_offset == filepos` branch) and parsing
garbage. The very next line uses `skip_sff_section`, which compares against the
full requested length, so this open-coded site is provably inconsistent with the
file's own helper.

- **Reachability:** truncated/crafted SFF with a partially present flowgram section.
- **Fix:** compare against `2UL * flows_per_read` (or route through `skip_sff_section`).
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Low–Medium · *verified*.

#### S16. UDB `kmerindexsize` summed from unchecked file counts with no consistency check (Low–Medium)

`udb_read` reads `kmercount[]` verbatim (`udb.cc:362`) and accumulates
`kmerindexsize += kmercount[i]` over `kmerhashsize` entries (`udb.cc:365–369`)
with no bound on the individual counts or the running sum; the total then sizes
`kmerindex = xmalloc(kmerindexsize * 4)` and the read of it (`udb.cc:382–384`),
and each `kmercount[i]` is later used as a loop bound in bitmap construction
(`udb.cc:517`). `largeread` fatals if the file is too short for `4*kmerindexsize`
(gating the over-read), but an attacker can pad the file, and nothing checks the
counts against the actual on-disk word-list section. Complements S1 (entries
unchecked `< seqcount`) and S6 (the additive `datap` allocation).

- **Reachability:** crafted `.udb` whose `kmercount[]` sum mismatches the word list.
- **Fix:** validate `kmerindexsize` against the remaining file size; bound the
  running sum; pairs with the S1 per-entry check.
- **Effort:** Low · **Impact:** Medium · **Criticality:** Low–Medium ·
  *needs-confirmation* · related S1, S6, S7.

#### S17. `opt_chimeras_parents_max` validated only on the CLI; library path → OOB writes in `find_best_parents_long` (High)

`find_best_parents_long` (`chimera.cc:445`) loops `for (int f = 0; f <
opt_chimeras_parents_max; ++f)` and writes `best_parents[f]` into a local
`std::vector<parents_info_s> best_parents(maxparents)` (size `maxparents` = 20,
`chimera.cc:454`), then copies into the per-query `std::array<int, maxparents>
best_parents/best_start/best_len` (`chimera.cc:176–178`). `opt_chimeras_parents_max`
is range-checked `[2, maxparents]` **only in `args_init`** (`vsearch.cc:5067`);
`vsearch_init_defaults` sets it to 3 and `vsearch_apply_defaults_fixups` does not
re-validate. A library caller that overrides `opt_chimeras_parents_max > 20`
therefore drives `f` past the 20-element containers — an out-of-bounds **write**.
This is the chimera sibling of **S13** (`opt_wordlength`): the same "CLI-only
bound, library path unguarded" root cause, but here it is a write, not just a
shift.

- **Reachability:** library API (`chimeras_denovo` path) with
  `opt_chimeras_parents_max` set above `maxparents`; not CLI.
- **Fix:** enforce `[2, maxparents]` in `vsearch_apply_defaults_fixups()` (the
  S13 fix generalizes to all such knobs); convert the `assert(parents_found <=
  20)` at `chimera.cc:1028` to a hard clamp/`fatal()`.
- **Effort:** Low · **Impact:** High · **Criticality:** Medium · *verified
  (loop bound, array sizes, CLI-only validation)* · sibling of S13.

#### S18. `chimera_detect_single` trusts the caller's `query_len` → heap overflow via `strcpy` (High)

The library entry `chimera_detect_single` (`chimera.cc:2801`) does
`ci->query_len = query_len;` straight from the caller, sizes all per-query
buffers from it via `realloc_arrays(ci)`, then `std::strcpy(ci->query_seq.data(),
query_seq)` copies the **actual** C-string (`chimera.cc:2818`). If the caller
passes `query_len < strlen(query_seq)`, `query_seq` (sized `query_len+1`)
overflows on the heap; if `query_len` is larger, downstream loops read past the
real sequence. The asymmetry is conspicuous: `query_head_len` two lines above is
correctly derived with `strlen(query_head)`. There is no `query_len ==
strlen(query_seq)` or `query_len > 0` check. (The function also always `return
0` — see the L1(a) note — so a malformed call cannot even be reported back.)

- **Reachability:** library API only; a consumer passing an inconsistent
  `query_len` (the header documents it only as "length of query sequence").
- **Fix:** validate `query_len == (int)strlen(query_seq)` and `query_len > 0`
  (fatal / non-zero return), or measure internally and stop trusting the param.
- **Effort:** Low · **Impact:** High (heap overflow) · **Criticality:** Medium ·
  *verified* · same family as S4/S5 (length used without a consistency check), L1(a).

#### S19. Chimera denovo model-string fill can over-increment `nth_parent` past `parents_found` (Medium, needs-confirmation)

`fill_in_model_string_for_query` (`chimera.cc:837`, `eval_parents_long` /
`chimeras_denovo`) advances `nth_parent` whenever `qpos >= best_start[nth_parent]
+ best_len[nth_parent]`, trusting the parent segments to tile the query exactly.
The default-initialized tail slots have `best_start = best_len = 0`, so once
`nth_parent` reaches `parents_found` the guard `qpos >= 0` fires on every
remaining position and keeps incrementing — reading `best_start[]/best_len[]`
past `parents_found` and, for a query tail longer than the array, past the
20-element `std::array` itself (OOB read), while writing `'A' + nth_parent` model
bytes beyond 'U'.

- **Reachability:** `chimeras_denovo` query whose best-parent tiling leaves a
  tail after the last segment; `pos_remaining == 0` (full coverage) makes a pure
  tail unlikely but overlapping segments can still leave a gap. Needs a crafted
  repro to confirm the tail is reachable.
- **Fix:** clamp `nth_parent` to `parents_found - 1` before indexing/incrementing.
- **Effort:** Low · **Impact:** Medium–High · **Criticality:** Medium ·
  *needs-confirmation (reachability); logic verified* · related S17.

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

## I/O robustness

### I1. Output write/flush/close return values are unchecked → silent truncated output

vsearch writes **all** of its textual output (FASTA/FASTQ records, alignments,
OTU tables, blast6/UC/SAM tabular results, the `--log` file, and everything
sent to `stdout`) through `std::fprintf` to `FILE *` handles. Sequence bytes
themselves are emitted via `fprintf(output_handle, "%.*s", len, seq)`
(`fasta.cc:455`, `fprint_seq_label`). A sweep of `src/` found:

| Call | Occurrences | Return value checked? |
|------|-------------|-----------------------|
| `fprintf` | 736 | none |
| `fputs` | 1 | none |
| `fclose` | 110 | none |
| `fflush` | 0 | — (never called) |
| `ferror` / `clearerr` | 0 on output | only a read-loop comment at `sha1.c:311` |

No output stream is ever checked for error: not per write, not via `ferror`
before close, and not with a final `fflush(stdout)` + error check before the
process exits (`vsearch.cc` exits via `exit(EXIT_FAILURE)` / normal return with
no flush-and-verify). `fclose` is especially significant here — it flushes the
stdio buffer, so a deferred write error (disk full, quota exceeded, broken
pipe) first becomes visible as an `fclose` return of `EOF`, which is discarded
at all 110 sites.

**Consequence.** On any write failure mid-run — a full disk, an over-quota
filesystem, or a downstream pipe that closed early — vsearch silently produces
a **truncated** output file and still exits with status `0`. For a tool that
sits in scientific pipelines, a partial result that looks complete is worse
than a crash: downstream steps consume corrupted data with no signal that
anything went wrong.

**The one place that does check.** `largewrite()` (`udb.cc:145–170`) writes the
binary `.udb` database with the raw `write()` syscall and correctly fatals on a
short write (`"Unable to write to UDB file"`, `udb.cc:165`). That pattern is the
model for what the `FILE *` text path lacks, but it is fd-based and specific to
the UDB writer; it is not used (or usable as-is) by the stdio output paths.

**Why `-Wunused-result` will not catch this.** The build already enables
`-Wall -Wextra -Wpedantic` (`src/Makefile.am:3`). But on glibc only `fwrite`
and `fread` carry the `warn_unused_result` attribute; `fprintf`, `fputs`,
`fflush`, and `fclose` do not. Since vsearch's output path uses `fprintf`
(not `fwrite`), a `-Wunused-result` build flags essentially nothing here. The
reliable detection is a runtime `ferror`/checked-close at end of stream, not a
compile-time warning.

- **Type:** Latent correctness bug (silent data loss on I/O failure)
- **Reachability:** any write failure — full disk, quota, `ulimit -f`, broken
  pipe (`vsearch … | head`), read-only remount mid-run. Not triggered by
  well-formed runs on healthy filesystems, so the sanitizer/Valgrind CI does
  not surface it.
- **Fix direction:** a single checked-close helper (`fflush` + `ferror`, then
  `fclose` with its own return checked → `fatal` on failure) applied at the
  ~110 close sites, plus a final `fflush(stdout)` + `ferror(stdout)` guard on
  the normal exit path. This localizes the check to one place per stream rather
  than per write. Overlaps with **E5** (the open/close boilerplate is already a
  dedup target — the checked-close logic should land in that shared helper).
- **Effort:** Medium · **Impact:** Medium–High · **Criticality:** Low–Medium
- **Status:** *verified (call-site counts and absence of checks); failure-mode
  is by construction, not yet reproduced with a forced ENOSPC/`SIGPIPE` run*

---

## Portability / undefined behavior

### P1. Portability / UB sweep — width narrowing and endianness assumptions

A pass for the portability/UB class. Two existing findings are concrete
instances of it: **S5** (64-bit length → `int` in the print path) and **S12**
(signed-`int` left-shift overflow in DUST, CI-confirmed). The sweep below
covers the broader class and, importantly, records the two sub-areas that turn
out to be **already handled** so no effort is spent re-checking them.

#### Active issues

**(a) Integer width-narrowing is wholesale, not isolated.** A `-Wconversion
-Wsign-conversion` syntax pass over three files alone reports many narrowings:

| File | `-Wconversion`/`-Wsign-conversion` warnings |
|------|---------------------------------------------|
| `src/fasta.cc` | 19 |
| `src/sff_convert.cc` | 9 |
| `src/mask.cc` | 43 |

The specific `uint64_t length → int → "%.*s"` pattern that S5 documented for the
fasta/fastq print interface recurs well beyond those sites — e.g. chimera output
casts header lengths to `int` for `%.*s` in at least eight places
(`chimera.cc:983, 985, 990, 995, 1580, 1582, …`, `(int)db_getheaderlen(...)`).
Most warnings are benign sign-conversions, but they are the same family that
produced S5 and S12, and there is no width-narrowing guard in the build.

- **Tooling:** `-Wconversion`/`-Wsign-conversion` flags the narrowing at compile
  time (not currently enabled — the build uses `-Wall -Wextra -Wpedantic`,
  `src/Makefile.am:3`); UBSan catches the signed-overflow subset at runtime
  (already wired up, and it found S12).
- **`"%ldI"` with an `int64_t` argument is non-portable on LLP64 (Tier-2).**
  `align_simd.cc:1324` (`search16`, the `qlen == 0` path) does
  `xsprintf(&cigar, "%ldI", length)` with `int64_t length`. `%ld` consumes a
  `long`; on LP64 (Linux/macOS) `long == int64_t` and it is fine, but on LLP64
  (64-bit Windows / MinGW) `long` is 32-bit → format/argument width mismatch
  (UB). The sibling `linmemalign.cc:228,230` already does it correctly with
  `PRId64`. The `build-all` matrix makes this a reachable target. Fix: `"%"
  PRId64 "I"`.
- **Effort:** Medium–High (wholesale) · **Impact:** Medium · **Criticality:** Low–Medium

**(b) Endianness assumptions — the code is little-endian-only in two places.**

- **SFF reader:** `bswap_16/32/64` are applied **unconditionally** to convert
  big-endian SFF fields to host order, with the explicit assumption that the
  host is little-endian (`sff_convert.cc:195–197`, "vsearch expects
  little-endian"). There is no `BYTE_ORDER` guard, so on a big-endian host every
  multi-byte SFF field is swapped the wrong way and parsing is silently wrong.
- **UDB database:** no byteswapping anywhere (`udb.cc`). The binary `.udb`
  format is read and written in **host** byte order, so a `.udb` is not portable
  across endianness — and, combined with the `int`-typed `header_index`
  (see S9), not portable across int width either.
- `sha1.c:105` carries a self-flagged `FIXME` about doing the transform in an
  endian-proof way.
- **k-mer hashing reads raw int bytes (Tier-2).** `unique.cc:328, 396` and
  `kmerhash.cc:91, 183, 259` hash a prefix of the in-memory bytes of an
  `unsigned int kmer` via `CityHash64((char*)&kmer, (wordlength+3)/4)`. Reading
  only the low `n < 4` bytes is little-endian-dependent: on a big-endian host the
  hashed bytes are the high-order (often zero) bytes, collapsing the hash
  distribution to near-linear probing. Correctness is preserved (same value
  hashes consistently within a run); only performance degrades, and only on BE.
- **Not exercised in CI:** the `build-all.yml` target matrix (x86-64, aarch64,
  ppc64le, mips64el, riscv64) is **entirely little-endian**, so the big-endian
  paths above are never built or run.
- **Effort:** Medium · **Impact:** Low (no big-endian target in practice) ·
  **Criticality:** Low — but it is a real gap against the cross-platform
  portability the build matrix advertises.

**(c) `fread` directly into a struct (SFF) relies on ABI layout.**
`read_sff_header` does `std::fread(&sff_header, 1, n_bytes_in_header, …)`
(`sff_convert.cc:190`), reading the file image straight into
`struct sff_header_s`. Field layout/padding is implementation-defined; a
`static_assert(n_bytes_in_header == 32, …)` guards the total size (the struct is
documented as 31 meaningful bytes + 1 padding byte) but not the internal padding
offsets across compilers/ABIs. Deterministic in practice given the field
ordering, but a latent ABI assumption. (The 31-vs-32 read — one byte past the
fixed header into the struct padding — is worth verifying against the SFF flow
section that follows, but is not confirmed as a bug here.)

- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *latent ABI assumption*

#### Checked and found already handled (no action)

- **char-signedness in table indexing.** The `chrmap_*` lookup tables are
  `unsigned char` / `unsigned int` vectors (`utils/maps.cpp`) and are reached
  through `to_uchar()` accessors. A sweep found no site indexing a `chrmap_*`
  table with a possibly-signed `char`; the original concern (signed `char`
  sequence byte used as a negative index) does not appear in the current tree.
  **However**, the Tier-1 audit found two char-signedness sites the `chrmap_*`
  sweep did not cover, both in the SFF path (active, low criticality): (i)
  `std::tolower`/`std::toupper` are called on a plain `std::vector<char>` element
  (`sff_convert.cc:550, 554`) — passing a negative value (a base byte ≥ 0x80,
  which is not alphabet-validated) to these functions is UB; cast to `unsigned
  char` first. (ii) `convert_quality_scores` (`sff_convert.cc:334–350`) clamps
  and offsets quality in **signed** `char`, so an SFF quality byte ≥ 128 is
  negative and the `std::max(.., qmin)` clamp corrupts it (wrong output), plus a
  latent signed-`char` add overflow; do the clamp/offset in `unsigned char`/`int`.
  The **Tier-2 audit found two more** of the same `<cctype>`-on-`char` sites in
  the masker: `toupper(seq[i])` (`mask.cc:157`, `dust_core`) and `isupper(seq[j])`
  (`mask.cc:402`, `fastx_mask`). Same fix (cast to `unsigned char`); gated by
  upstream alphabet validation, so latent.
- **Strict aliasing in the SIMD code.** Even with strict aliasing on (the build
  has no `-fno-strict-aliasing`), `align_simd.cc` does not type-pun: the
  `(VECTOR_SHORT *)` casts are either on fresh `xmalloc` memory (legal — the
  first store sets the effective type, e.g. `align_simd.cc:1131, 1238, 1245`) or
  feed `_mm_load_si128` / `_mm_store_si128` intrinsics (the blessed pattern,
  `align_simd.cc:186–187`); `memcpy` is used for the remaining copies. The
  byteswap helpers (`utils/os_byteswap.*`) use builtins, no casts.

- **Overall — Effort:** Medium–High · **Impact:** Medium · **Criticality:** Low–Medium
- **Status:** *verified (warning counts, endianness handling, mitigations);
  big-endian misbehavior is by construction, not reproduced (no BE target)*

---

## Resource & lifecycle management

### L1. Error-path resource handling — benign on the CLI, real leaks in the library API

The premise of this class needs correcting before the real issues show up.
`fatal()` is `__attribute__((noreturn))` and unconditionally calls
`std::exit(EXIT_FAILURE)` (`utils/fatal.cpp`) — there is **no** recoverable
error channel anywhere (no return codes, `setjmp`/`longjmp`, exceptions, or
`atexit` handlers). Two consequences:

1. On the **CLI**, every `fatal()` ends the process, so the open file handles
   and `xmalloc`'d memory abandoned at an error are reclaimed by the OS — these
   are **not real leaks**. The Valgrind CI confirms the happy path is clean:
   "in use at exit: 0 bytes" across all 48 representative command runs.
2. The real resource problems are all in the **library API** (`vsearch_api.h`,
   shipped as `libvsearch_core.a`), where the process is *not* expected to exit.

#### (a) `fatal()` terminates the caller's process — the dominant library issue

Every core error path (parsers, allocators, the UDB/SFF readers behind S1–S4,
and the search/cluster/chimera engines) bottoms out in `fatal()` →
`std::exit()`. A library user who passes malformed input — and S1–S4 show such
inputs exist — has their **entire host process killed**, with no chance to
clean up. This is not a leak so much as the root cause that makes "error-path
cleanup" moot on the CLI and unacceptable in a library. Overlaps E4 (global
state) but is a distinct, higher-severity concern for library consumers.

- **Effort:** High (thread a recoverable error channel through the core) ·
  **Impact:** High · **Criticality:** Medium (library API) · *verified*
- **Concrete instance (Tier-2):** `chimera_detect_single` returns `int` and its
  header says "Returns 0 on success" — but it **always** returns 0
  (`chimera.cc:2848`); every internal error is `fatal()`. The documented error
  channel is dead, so a malformed call (see S18) can neither be reported nor
  recovered. Also a `-fno-exceptions` hazard nearby: `cluster.cc:1901, 2072` use
  `std::map::at()`, which *throws* `std::out_of_range`; under the project's
  `-fno-exceptions` build a missing key becomes `terminate()`/abort rather than a
  graceful `fatal()`. By construction only centroids are looked up so it should
  not fire today, but it is an unchecked invariant enforced by a throwing call in
  a no-exceptions build — replace with `find()` + `fatal()`.

#### (b) Session-mutex deadlock when the lifecycle is not completed

`vsearch_init_defaults()` locks a global `session_mutex` (`vsearch.cc:803`) that
only `vsearch_session_end()` unlocks (`vsearch.cc:1023`). Nothing guarantees the
unlock runs: there is no scope guard, and the ~13-step teardown is manual. If a
caller's session is abandoned before `vsearch_session_end()` (an exception in
the embedding code, an early return, or a partial-failure handler), the mutex
stays locked and the **next `vsearch_init_defaults()` blocks forever**. The
header documents exactly this ("Forgetting to call `vsearch_session_end()` will
cause the next `vsearch_init_defaults()` call to block indefinitely"). It is a
lock leak with a deadlock payload, released on no error path.

- **Effort:** Low (RAII/scope-guard unlock, or a try-lock with diagnostic) ·
  **Impact:** Medium · **Criticality:** Medium · *verified*

#### (c) Acknowledged heap leak across re-initialization

`vsearch_init_defaults()` `xmalloc`s `opt_ee_cutoffs_values`, and the code
comment (`vsearch.cc:785–787`) states plainly that "calling
`vsearch_init_defaults` again … leaks the old allocation." Yet the header
advertises "Multiple sequential sessions in the same process are supported."
So the documented multi-session path leaks one allocation per session by
design — small, but real and self-contradictory.

- **Effort:** Low (free before re-alloc) · **Impact:** Low · **Criticality:** Low · *verified*

#### (d) Manual, ordering-dependent teardown

Cleanup is a hand-ordered reverse sequence (per-thread teardown → per-subsystem
cleanup → `dbindex_free()` + `db_free()` → `vsearch_session_end()`). Nothing
enforces it; a caller that mis-orders or skips a step leaks subsystem/thread
state or the session lock (b). This compounds with E4: much per-command working
state lives in file-`static` globals that the next session overwrites without
freeing.

- **Effort:** Medium · **Impact:** Medium · **Criticality:** Low–Medium

#### Already clean (no action)

- **Happy-path CLI runs** — Valgrind CI reports 0 bytes in use at exit for every
  representative command (the `Valgrind (Memcheck)` workflow).
- **Worker-thread mutex/alloc balance** — e.g. the allpairs worker unlocks
  `mutex_output` and frees per-hit alignment strings on the normal path and
  unlocks `mutex_input` on the no-work branch (`allpairs.cc:526, 540`); no
  `fatal()` sits between a lock and its unlock in that worker.

**Tooling note.** LeakSanitizer / Valgrind on *normal* runs will not surface any
of the above — normal runs are clean. Catching (a)–(d) needs (i) error-input
runs under Valgrind and (ii) an API-lifecycle test that runs **two** sessions
and checks the mutex and heap. The recently added `api_examples/example_reinit.cc`
is the natural vehicle for (ii).

- **Overall — Effort:** High (driven by (a)) · **Impact:** High · **Criticality:** Medium
- **Status:** *verified (fatal()=exit, session-lock/leak code paths, happy-path
  cleanliness); library mis-use leaks are by construction, not reproduced*

### L2. Index-side subsystems lack the free-then-null re-init discipline that `db.cc` has

`db.cc` is the model: `db_init()` self-frees and `db_free()` nulls. Three other
subsystems on the library-reachable path do not follow it, so a second session
(or a teardown-ordering slip) double-frees, dereferences stale state, or leaks.
This is the concrete, verified content behind the L1(d) "manual teardown" theme
and the correction to C1(c).

- **(a) `dbindex_free()` / `dbindex_prepare()`** (`dbindex.cc:267–283`,
  `:177+`). `dbindex_free()` frees `kmerhash`/`kmerindex`/`kmercount`/
  `dbindex_map`/`kmerbitmap` but **nulls none of them**, and the cleanup loop
  unconditionally dereferences `kmerbitmap[kmer]`. `dbindex_prepare()` does **not**
  call `dbindex_free()` first (unlike `db_init`→`db_free`). So: calling
  `dbindex_free()` twice double-frees; calling it without a prior successful
  prepare derefs a stale `kmerbitmap` using a stale `kmerhashsize`; and a second
  `dbindex_prepare()` without an intervening free leaks all five buffers.
  *verified · Impact Medium · Criticality Low–Medium.*
- **(b) `dbhash_close()`** (`dbhash.cc:97–101`) frees/nulls only `dbhash_bitmap`;
  it never clears the file-static `dbhash_table` vector or resets
  `dbhash_size`/`dbhash_shift`/`dbhash_mask`, so contents and size globals
  persist between sessions (stale state, not a malloc leak — the vector reclaims
  at exit). *verified · Low.*
- **(c) `parse_userfields_arg()`** (`userfields.cc:130`) `xmalloc`s
  `userfields_requested` with no `xfree` of a prior allocation, so a duplicate
  `--userfields` or a second library session leaks the previous array
  (the global is never reset by `vsearch_init_defaults`). It also rejects empty
  tokens only incidentally (the zero-length `strncmp` falls through to the
  end-of-table return) rather than with an explicit check — worth making
  explicit. *verified · Low.* (Refines the "userfields rejects empty tokens"
  entry in the checked-safe list.)

- **Fix:** null the globals after `xfree` (and guard the `kmerbitmap` loop) in
  `dbindex_free`; have `dbindex_prepare` self-free first; clear the `dbhash`
  table/size globals in `dbhash_close`; free-before-realloc and reset in
  `parse_userfields_arg`. All small and local.
- **Effort:** Low · **Impact:** Medium (library multi-session) · **Criticality:**
  Low–Medium (CLI frees once before exit, so benign there) · *verified* ·
  cross-ref C1(c), L1(d).
- **(d) Shared file-static `tophits`/`seqcount` not re-derived or restored
  (Tier-2).** Two more sites of the same class: (i) `cluster_assign_batch`
  (`cluster.cc:1939`) sizes its per-query buffers from the file-static
  `seqcount`/`tophits` that only `cluster_session_init` sets — a second session
  with a larger DB, or interleaving with the CLI `cluster()` path that shares
  those statics, leaves the buffers undersized while indexing proceeds. (ii)
  `chimera_detect_batch` saves/restores seven globals around a session but
  **omits `tophits`** (`chimera.cc:2954–2960, 3022–3028`), so after a chimera
  batch the shared `tophits` is left at the chimera value and silently corrupts
  a subsequent unrelated search/cluster session that reads the same global.
  Fix: re-derive (or store-and-assert) `seqcount`/`tophits` per session; add
  `tophits` to the chimera save/restore set. *verified; latent on the
  single-session CLI.*

## Numerical correctness

### N1. Silent numerical-correctness issues (wrong results, no crash)

The highest-stakes class for a scientific tool: a wrong identity percentage,
abundance, or candidate ranking is worse than a crash because nothing signals
it. A key meta-point first: **most of this class evades the sanitizer CI.**
UBSan catches *signed* integer overflow and *integer* division-by-zero, but the
issues below are *unsigned* wraparound (defined, silent) and *floating-point*
division-by-zero (produces `inf`/`nan`, also defined). Neither trips ASan/UBSan
or Valgrind — they need reference-output regression on a known dataset.

#### (a) `count_t` (`unsigned short`) silently saturates k-mer match counts → wrong search/cluster ranking on long reads — *headline*

The per-target shared-k-mer counter is `using count_t = unsigned short`
(`searchcore.h:128`). In `searchcore.cc` it is incremented once per matching
query k-mer sample with **no saturation guard** —
`searchinfo->kmers[list[j]]++` (`searchcore.cc:309`) — and the result then
drives candidate selection: `count = searchinfo->kmers[i]; if (count >=
minmatches) { … novel.count = count; minheap_add(…); }`
(`searchcore.cc:318–328`). The minheap keeps the top candidates **by
`count`**.

A query that shares more than 65 535 k-mer samples with one target overflows
the `unsigned short` and wraps toward 0. The wrapped (small) count then either
falls below `minmatches` and the target is **dropped from the candidate set
entirely**, or it under-ranks in the minheap and is evicted when the heap
fills. Result: a true best hit is silently missed or mis-ranked.

- **Reachability:** real for **long-read data** (PacBio/Nanopore, 10⁴–10⁵ bp),
  which vsearch supports. The query k-mer sample count scales with sequence
  length, so a long query against a long, highly similar target exceeds 65 535
  shared samples. Short-read data stays well under the limit.
- **Not caught by tooling:** unsigned overflow is not UB, so UBSan stays silent
  (this is why the class-1 note flagged regression testing, not sanitizers).
- **Fix:** widen `count_t` to `uint32_t` (the matched `unsigned int count`
  field at `searchcore.h:83` already implies the wider domain), or clamp on
  increment. Widening costs memory in the per-target `kmers` array
  (`indexed_count * sizeof(count_t)`), so measure.
- **Effort:** Low–Medium · **Impact:** High · **Criticality:** Medium
  (long-read workflows) · *verified (mechanism); needs-confirmation (a crafted
  long-read regression case)*
- Cross-ref: previously noted as a parenthetical under "Checked and found safe"
  (memory-safety context, where it is correctly *not* a safety bug); this is its
  correctness writeup.
- **Scope (Tier-2 audit):** the consequence lands concretely at the *read* site
  `searchcore.cc:318` (`count >= minmatches` and the copy into `novel.count`
  the minheap ranks on), so the wrap can drop a true hit below `minmatches`, not
  just mis-rank it. **sintax is immune**: each bootstrap subsamples exactly 32
  k-mers (`sintax.cc:410`), so a target's counter is incremented ≤ 32 times per
  call — nowhere near 65 535. So N1(a) is specific to the `searchcore` engine
  (search/cluster/chimera), not the sintax path.

#### (b) Inconsistent division-by-zero guarding in output fields → `inf`/`nan` emitted silently

The primary percent-identity fields are correctly guarded
(`internal_alignmentlength > 0 ? 100.0 * matches / internal_alignmentlength :
0.0`, `results.cc:359, 362, 747`). But several secondary/statistics fields
divide by a length/count that is only guarded against a null pointer, not
against zero:

| Site | Expression | Zero denominator when… |
|------|-----------|------------------------|
| `results.cc:473` | `100.0 * (matches+mismatches) / qseqlen` (qcov) | empty/zero-length query |
| `results.cc:477` | `… / tseqlen` (tcov) | zero-length target |
| `results.cc:636` | `1.0 * level_match[j] / tophitcount` (LCA) | `tophitcount == 0` |
| `eestats.cc:244` | `100.0 * reads / seq_count` | empty input (`seq_count == 0`) |
| `eestats.cc:384` | `sum_ee_length_table[i] / reads` | a length bucket with no reads |
| `mask.cc:408` | `100.0 * unmasked / len` | zero-length sequence |
| `fastq_chars.cc:218` | `100.0 / total_chars` frequency factor | `seq_count > 0` but all reads zero-length (`total_chars == 0`) |
| `searchcore.cc:702` | `100.0 * (nwalignmentlength - nwdiff) / nwalignmentlength` (`nwid`, `align_delayed`) | zero-length alignment (the `id0..id4` fields below it *are* guarded) |
| `allpairs.cc:479–480`, `cluster.cc:818–820` | `nwid = 100.0 * … / nwalignmentlength` | zero-length alignment (`--minseqlength 0` + empty record) |
| `chimera.cc:973, 1547` | `divfrac = 100.0 * divdiff / QT` (`QT` = a percent-identity) | query matches neither parent over the alignment (edge) |
| `chimera.cc:1716, 1718` | `100.0 * best_left_y / sumL`, `… / sumR` (alnout) | guarded only implicitly by the `left_y > left_n` selection invariant — defensive |

These produce `inf`/`nan` (defined behaviour, so no sanitizer signal) that flow
straight into the output columns. Empty-input / zero-length handling is ad hoc
(`fastq_stats.cc:142` early-returns on empty qualities, but there is no
consistent guard), so the reachability of each is edge-case but real. (The
aligner-side `nwid`/`divfrac` rows were added by the Tier-2 audit; they are the
same pattern at algorithm sites the original list didn't enumerate.)

- **Fix:** a single guarded-divide helper (`den > 0 ? num/den : 0.0`) applied to
  the secondary fields, matching the pattern the %id fields already use.
- **Effort:** Low · **Impact:** Medium · **Criticality:** Low–Medium · *verified
  (unguarded sites); per-site reachability needs an empty/degenerate-input run*

#### (b2) Alignment counters are `unsigned short` — wrap on long alignment paths (N2)

Distinct from (a)'s `count_t`: the per-alignment counters `aligned`, `matches`,
`mismatches`, `gaps` in `backtrack16` (`align_simd.cc:995–998`) are
`unsigned short`, the `search16` output parameters are `unsigned short *`
(`align_simd.h:95–98`), and the delayed-result lists in `searchcore.cc:601–604`
are `std::array<unsigned short, MAXDELAYED>`. The alignment **path length** can
reach `qlen + dlen`, which the `maxseqlenproduct = 25,000,000` cap does **not**
bound (it bounds the *product*): e.g. `qlen = 1`, `dlen = 25,000,000` passes
`1 * 25e6 ≤ 25e6` and is aligned, then `backtrack16` increments `aligned` ~25e6
times into a 16-bit counter → wraps mod 65536. The `qlen == 0` path truncates an
`int64_t` length into the same `unsigned short` explicitly (`align_simd.cc:1303,
1306`). Result: wrong reported alignment length / match / mismatch / gap counts
(data-integrity, not memory-unsafety).

- **Reachability:** a very short query (1–few nt) vs a long target (path length
  > 65 535) under the product cap — `usearch_global`/`allpairs_global` with a
  1-mer query, or a pathological cluster input. Latent (degenerate lengths).
- **Fix:** widen the counters, the `search16` `p*` output params, and the
  `searchcore` lists to `uint32_t`/`int64_t` (an API-surface change, ~5 sites),
  or saturate at 65535 with downstream awareness.
- **Effort:** Medium · **Impact:** Medium (wrong stats, no crash) · **Criticality:**
  Low–Medium · *verified (16-bit end-to-end); trigger latent* · distinct from N1(a).

#### (c) Accumulator widths — mostly safe, recorded for completeness

- **Abundance — correction.** An earlier draft of this note said abundance is
  "stored `int64_t size`." That is wrong: the per-sequence field is
  `unsigned int size` in `seqinfo_s` (`db.h:74`). `db_add` assigns an `int64_t
  abundance` into it (`db.cc:212`) and `db_getabundance` widens the already-
  truncated 32-bit value back to `uint64_t` (`db.h:92`). So a **per-sequence**
  abundance above `UINT_MAX` (~4.29e9) silently wraps, and a negative value
  becomes large-positive; the sort comparators compare the 32-bit field.
  Reachable only with a `;size=` (or summed) abundance above ~4.29 billion on a
  single sequence — realistic only on very large pooled datasets. Fix: widen
  `seqinfo_s.size` to `uint64_t` (matches the return type and the `int64_t`
  source). *verified.*
- **Per-record lengths** `seqinfo_s.seqlen` / `headerlen` are likewise
  `unsigned int` (`db.h:72–73`); `db_add` stores `size_t` lengths into them, and
  `opt_maxseqlength` has **no upper bound** (only `< 1` is rejected,
  `vsearch.cc:5092`). A single record > `UINT_MAX` (~4 GB) with `--maxseqlength`
  raised above it truncates `seqlen`, which then feeds k-mer indexing,
  alignment, and `%.*s` output — same class as **S5**, distinct site (the DB
  index struct + the unbounded option). Gated on >4 GB input. *verified.*
- **Statistics sums** (`sum_error_probabilities`, `sumee_length_table`,
  `qsum`) are `double` (`fastq_stats.cc:302–304`): no integer overflow, but
  floating-point summation drifts on very large inputs (a precision, not
  correctness-cliff, concern; Kahan summation would remove it if it ever
  matters).

- **Overall — Effort:** Low–Medium · **Impact:** High (a) / Medium (b) ·
  **Criticality:** Medium
- **Status:** *verified (types, guards, overflow mechanism); the wrong-output
  consequences are by construction and want a reference-output regression to pin
  down exact thresholds*

---

## Assertions / NDEBUG

### A1. Input validation expressed as `assert()` is compiled out of every shipped build

**The NDEBUG cliff is real and active.** The default build defines `NDEBUG`:
`--enable-debug` defaults to `no` (`configure.ac:79–86`), so the `else` branch
`AM_CFLAGS += -DNDEBUG` (`src/Makefile.am:44`) is selected. The generated
Makefile confirms it — `am__append_6 = -DNDEBUG` is active and the `-UNDEBUG`
debug profile is commented out. Therefore **all 137 `assert()` calls evaluate to
nothing in every release/CI binary** (the `build-all.yml` release artifacts and
`build-and-test.yml` both configure without `--enable-debug`). Even the
sanitizer and Valgrind CI build without `--enable-debug`, so they do not
exercise the asserts either.

Most of the 137 are legitimate "can't happen" invariants and are fine as
asserts — e.g. `assert(input_handle != nullptr)` in the fastx/fasta/fastq
parsers (`fastx.cc:469`, `fasta.cc:175`, `fastq.cc:290`), the `log_handle !=
nullptr` guards in `fastq_stats.cc` (×6), and `assert(a_string.back() == '\0')`
(`sff_convert.cc:330, 349`). A null handle there is a program bug, not
malformed input.

**The problem is the subset that validates file-derived input.** These guard
integer-overflow bounds on values read straight from an SFF file, and they are
the *only* check on those values — so under NDEBUG a crafted SFF passes
unchecked into the overflow the assert was meant to prevent:

| Site | Asserted bound | Value source |
|------|----------------|--------------|
| `utils/round_up.hpp:117` | `input <= UINT16_MAX - stub` | the generic `round_up_to_8` overflow guard (the example the class note named) |
| `sff_convert.cc:136` | `n_bytes <= UINT16_MAX - stub` | SFF flow/key region size |
| `sff_convert.cc:258` | `flows_per_read <= UINT16_MAX - (header + key_length)` | `sff_header.flows_per_read`, read from file |
| `sff_convert.cc:288` | `name_length <= UINT16_MAX - read_header_size` | `read_header.name_length`, read from file |
| `sff_convert.cc:323` | `n_bytes_to_read < SIZE_MAX` | input-derived read length |

The tell is that the **same parser already uses `fatal()` for the other
malformed-input cases** — truncation and open failures (`sff_convert.cc:169,
176, 180, 192, 217`). So the overflow bounds are the lone validations written as
asserts; converting them to `fatal()` is consistent with the surrounding code
and closes the hole in release builds. This compounds **S2** (the SFF
`clip_start > clip_end` underflow): the SFF reader is the weakest input surface
and several of its guards either vanish under NDEBUG (here) or are missing (S2).

A borderline case worth a glance: `fastq_chars.cc:125–150` asserts a lookup
index is in `[0, char_max]`. The index derives from an input byte but is bounded
by `unsigned char` construction, so it is likely a true invariant — confirm the
table is sized `char_max + 1` and leave as-is if so.

- **Rule applied:** asserts are for "can't happen" invariants; a value read from
  a file can happen, so it needs `fatal()` (or a recoverable error in the
  library — see L1(a)), not `assert()`.
- **Fix:** convert the five input-bound asserts above to `fatal()` with a clear
  "invalid/corrupt SFF" message; leave the invariant asserts alone.
- **Effort:** Low · **Impact:** Medium (closes release-build input-overflow
  holes) · **Criticality:** Medium (crafted SFF; overlaps S2) · *verified
  (NDEBUG default and the asserted input bounds)*

---

## Library-API lifecycle correctness

### C1. Stale configuration across sequential library sessions

This is the state-*correctness* companion to **L1** (which covers the lifecycle
*leaks/locks*: `fatal()`→`exit()`, the session-mutex deadlock, the re-init heap
leak). The concern here is the half-finished `opt_*` → `Parameters` migration
(E1) leaving global configuration that persists or goes stale between API calls.

#### (a) `vsearch_init_defaults()` resets only 203 of 255 `opt_*` globals — *live*

The header promises "`vsearch_init_defaults()` … set all ~200 `opt_*` globals"
and "If you override any … sets ALL of them." In fact it assigns 203 distinct
`opt_*` names (`vsearch.cc:801–1020`) out of 255 declared in `vsearch.h` — **52
are never reset.** Most of the 52 are command-selector flags (`opt_usearch_global`,
`opt_cluster_size`, `opt_derep_*`, …) that the library path does not use (it
drives subsystems directly). But several are **behavioral and read on
library-reachable paths**, so a second session silently inherits the first
session's values:

| Unreset global | Read in | Lifecycle step affected |
|----------------|---------|-------------------------|
| `opt_max_unmasked_pct` | `mask.cc` | `dust_all()` (documented step 6) |
| `opt_min_unmasked_pct` | `mask.cc` | `dust_all()` (documented step 6) |
| `opt_clusterout_id` | `cluster.cc` | clustering output |
| `opt_clusterout_sort` | `cluster.cc` | clustering output |

Because the documented re-initialization model is "repeat the full sequence for
each session," a process that runs two sessions with different masking thresholds
gets the **first** session's thresholds in the second — a silent wrong result,
not an error. Contradicts the header's "sets ALL" guarantee.

- **Fix:** add the missing behavioral globals to `vsearch_init_defaults()` (and
  reconcile the "~200 / ALL" wording). Low effort, mechanical.
- **Effort:** Low · **Impact:** Medium–High (silent wrong output for
  multi-session library users) · **Criticality:** Medium · *verified (reset gap
  and the four globals' read sites)*

#### (b) The `opt_*` / `Parameters` split is a migration trap — *latent*

The library compute path is currently **consistent**: the per-query engines read
the bare globals — `searchcore.cc` reads `opt_minwordmatches`, `opt_iddef`,
`opt_maxqsize`, … and the chimera scoring reads `opt_xn`, `opt_dn`, `opt_minh`,
`opt_mindiv` (`chimera.cc:1374–1564`) — and those globals are what
`init_defaults()` resets. The `parameters.opt_*` reads are on the **CLI** command
dispatchers (`search.cc:848` in `usearch_global`, `chimera.cc:2359–2447` in
`chimera(parameters)`), which the documented library lifecycle does not call.

The trap: `init_defaults()` touches **only** the globals, never the `Parameters`
struct (0 references to `parameters.`/`Parameters` in its body). So as the E1
migration proceeds, the moment a *library-reachable* compute function is switched
from `opt_x` to `parameters.opt_x`, it will silently read an unpopulated/stale
`Parameters` field instead of the user's configuration. This is the lifecycle
form of E1's "two copies that can drift," and it is why E1 should finish in one
direction (everything reads `Parameters`, and `init_defaults` populates it)
rather than leave the split half-applied.

- **Effort:** (part of E1) · **Impact:** latent · **Criticality:** Low now,
  rising as the migration advances · *verified (compute reads globals;
  init_defaults does not touch Parameters)*

#### (c) Database re-init is safe, but the k-mer **index** re-init is **not** — *correction; see L2*

The `db.cc` objects are safe across sessions: `db_init()` calls `db_free()` first
(`db.cc:97`), and `db_free()` frees and then **nulls** `datap` / `seqindex`
(`db.cc:428–436`), so repeated sessions neither double-free nor read freed memory
and do not leak the previous buffers. **However**, the Tier-1 file audit showed
the *index* half does **not** share this safety: `dbindex_free()` frees its five
globals but never nulls them and unconditionally dereferences `kmerbitmap`, and
`dbindex_prepare()` does not call `dbindex_free()` first — so a double free, a
free-before-prepare deref, or a re-prepare-without-free five-buffer leak are all
reachable. That is finding **L2** below; the earlier blanket "db/k-mer-index
re-init is safe" claim is corrected to apply to `db.cc` only.

- **Overall — Effort:** Low (for the live (a) part) · **Impact:** Medium–High ·
  **Criticality:** Medium
- **Status:** *verified (reset gap, config read sites, db re-init safety);
  multi-session stale-config effect is by construction, wants a two-session
  regression test (see `api_examples/example_reinit.cc`)*

---

## Static-analysis inventory (cppcheck)

A `cppcheck` 2.13 pass over `src/` (`--enable=warning,performance,portability
--std=c++11`, no `--inconclusive`) produced ~120 raw findings. Triaged below.
The pass **independently corroborated** three existing items — **S11** (wrong
`sizeof` in `dbmatched`), **S12** (DUST signed shift, also caught by UBSan), and
**P1(a)** (width/sign narrowing) — and turned up one new genuine bug (ST1) plus
a concrete format-mismatch batch (ST2). Notable **false positives** are recorded
so they are not re-investigated. Line numbers here refer to the current tree.

### ST1. `memset` on `searchinfo_s`, which contains three `std::vector` members — leak/UB risk

`searchinfo_s` (`searchcore.h:130`) holds three non-trivial members —
`std::vector<char> qsequence_v`, `std::vector<count_t> kmers_v`, and
`std::vector<struct hit> hits_v`. Four sites zero a whole `searchinfo_s` with
`memset` before calling the per-slot init:

| Site | Context |
|------|---------|
| `cluster.cc:1971` | `memset((void*)(si_plus + i), 0, sizeof(struct searchinfo_s))` then `cluster_query_init` |
| `cluster.cc:1977` | same, `si_minus` |
| `search.cc:1391` | `memset((void*)(ctx.batch_si_plus + t), …)` then `search_thread_init` |
| `search.cc:1395` | same, `batch_si_minus` |

The `(void*)` cast is exactly what silences the compiler's own
`-Wclass-memaccess` diagnostic, so the warning was knowingly suppressed.
`memset`-ing a `std::vector` overwrites its internal pointers/size without
destroying it: when a slot is zeroed while its vectors already hold an
allocation, those heap buffers are **orphaned (leak)** and the vector is left in
a zeroed (empty) state. On the very first init the vectors are freshly empty so
the zero is benign-by-luck, but the pattern is fragile and is UB on any STL
whose empty vector is not all-zero-bits. The correct reset is value-init /
`clear()`, not `memset`.

- **Type:** Latent bug (leak / UB depending on STL and slot reuse)
- **Fix:** drop the `memset` and rely on the `*_init` routines to (re)initialize,
  or value-initialize the struct; never `memset` a type with `std::vector` members.
- **Effort:** Low–Medium · **Impact:** Medium · **Criticality:** Low–Medium · *verified*

### ST2. `printf`-family format/argument signedness mismatches (batch)

cppcheck pinpoints ~13 sites where a `%u`/`%d` conversion does not match the
argument's signedness — concrete instances of the **P1(a)** width/sign family:

| File:line | Mismatch |
|-----------|----------|
| `chimera.cc:2522, 2534, 2552, 2562` | `%u` ← signed `int` |
| `fasta.cc:537`, `fastq.cc:719` | `%u` ← signed `int` |
| `orient.cc:430` (×2) | `%d` ← `unsigned int` |
| `sff_convert.cc:402` (×2), `:445`, `:452` | `%d` ← `unsigned int` |
| `sha1.c:125` (×2) | `%d` ← `unsigned int` |
| `udb.cc:725, 872` | `%u` ← signed `int` |

Benign for in-range values on LP64 (where `int` and `unsigned` share a width),
but a signed/unsigned format mismatch is technically UB and trivially fixed by
matching the specifier. Also in this group: `fastx.cc:175` passes three
arguments to a `format` that one caller fills with only two conversions
(`wrongPrintfScanfArgNum`) — the extra argument is evaluated and ignored, so it
is harmless, but worth aligning.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *verified*

### Notable false positives (recorded — no action)

- **`sff_convert.cc:482, 599` `containerOutOfBounds`** — *false positive*.
  `index_kind` is `std::array<char, index_header_length + 1>` (9 elements), so
  index 8 (`= index_header_length`) is the valid last slot used for the NUL
  terminator. cppcheck mis-modeled the `+1` and reported the array size as 8.
- **`util.cc:155` `returnDanglingLifetime`** — *false positive*. In `xstrdup`,
  `dest` is `xmalloc`'d heap memory; `strcpy(dest, src)` returns that heap
  pointer, not a local.
- **`dynlibs.cc:82` `unknownMacro` (`ZEXPORT`)** — analysis-config artifact
  (zlib macro not visible to cppcheck), not a code defect.
- **`align_simd.cc:250, 260` `objectIndex`** — low confidence; `&x` is used as a
  base for SIMD lane access, an intentional pattern in this file. Leave as-is.
- **`memsetClassFloat` (`cluster.cc:1874`, `chimera.cc:2822`,
  `fastq_mergepairs.cc:1784`)** — portability-only: `memset`-zeroing a struct
  with a floating-point member assumes all-zero-bits == `0.0`, which holds on
  every IEEE-754 target. Noted under **P1**; no action.

**Tooling note.** This was a one-off local run; the recommended next step is a
non-gating `Static analysis` CI lane (cppcheck + a bug-only-scoped clang-tidy:
`-*,bugprone-*,cert-*,clang-analyzer-*`) mirroring the sanitizer inventory, and
a separate **CodeQL** workflow for the input→index taint class (S1–S4) that
neither sanitizers nor cppcheck reliably reach. Auto-fix / `modernize-*` /
`readability-*` are deliberately excluded to keep upstream-cherry-pick diffs small.

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
- **Related (Tier-1):** `userfields.cc` has the same parallel-table hazard at
  smaller scale — `userfields_names[]` is indexed by *positional* integers
  (`nth_valid_userfield = valid_userfield - userfields_names`, ~:164) that
  consumers in `results.cc` hard-code; reordering/inserting a name silently
  renumbers every downstream field. Back it with a named enum or `{name,id}`
  table shared with the consumer.

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
| `src/sintax.cc` | `sintax_analyse` | ~121–269 | ~148 (5-deep nesting; duplicated per-level output block) |

- **Effort:** Medium–High (per function) · **Impact:** Medium · **Criticality:** Low
- **Note (Tier-2):** `sintax_analyse` also hardwires magic constants — the
  `(bootstrap_count+1)/2` "at least half" threshold, the 32-k-mer subsample, and
  the 100 bootstraps are compile-time constants with no option, fixing SINTAX
  confidence granularity at 1%.

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
- **`db.cc`** — the three `qsort` comparators `compare_bylength`,
  `compare_bylength_shortest_first`, `compare_byabundance` (~451–568) share the
  same abundance/header/pointer tiebreak tail verbatim; only the primary key and
  direction differ. Factor the shared tiebreak; parameterize the key.

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
- `src/fastq.cc` — `fastq_fatal` (~196–216) does `fatal(string); xfree(string);`;
  `fatal()` is `noreturn`, so the `xfree` is unreachable dead code (and a benign
  CLI / library-only leak — part of L1(a)).
- **Defensive (not dead, but fragile):** `fasta.cc:139–161`
  (`report_illegal_symbol_and_exit` / `report_unprintable_symbol_and_exit`) pass
  an assembled message as `fatal()`'s **format** string (`fatal(msg.data())`).
  Not injectable today (the only `%`-source byte maps to a stripped action before
  these fire), but the safe form is `fatal("%s", msg.data())`.
- `src/kmerhash.cc` — `kh_find_best_diagonal` (~156–227, declared `kmerhash.h:68`)
  is defined but never called anywhere in the tree; delete it and its declaration
  (Tier-2).
- `src/unique.cc` — `unique_compare` (~152–166) is both **dead** (no source
  caller) and **wrong**: it casts to `unsigned int *` and then compares the
  *pointers* (`lhs < rhs`), not the values (`*lhs`/`*rhs`), so as a `qsort`
  comparator it would sort by address. Delete it, or fix to dereference if a
  sorted order is ever needed (Tier-2).
- `src/cluster.cc` — `allpairs.cc:708` carries a `// refactoring: issue with
  parenthesis?` breadcrumb; the expression is actually correct (the `/2` applies
  to the `std::max(0, n*(n-1))` result) — remove the breadcrumb.

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
| S13 | `opt_wordlength` unvalidated on library path → shift UB + undersized k-mer index OOB | Security | Low | High | Medium |
| S14 | UDB header/length tables stored as `std::vector<int>` (signed) for unsigned 32-bit values | Security | Low | Medium | Medium |
| S15 | SFF flowgram-skip wrong short-read threshold → silent offset desync | Security | Low | Low–Med | Low–Med |
| S16 | UDB `kmerindexsize` summed from unchecked file counts, no consistency check | Security | Low | Medium | Low–Med |
| S17 | `opt_chimeras_parents_max` unvalidated on library path → OOB write in `find_best_parents_long` | Security | Low | High | Medium |
| S18 | `chimera_detect_single` trusts caller `query_len` → heap overflow via `strcpy` | Security | Low | High | Medium |
| S19 | Chimera denovo model-string fill over-increments `nth_parent` → OOB read | Security | Low | Med–High | Medium |
| ST1 | `memset` on `searchinfo_s` (has `std::vector` members) → leak/UB | Static analysis | Low–Med | Medium | Low–Med |
| ST2 | `printf` format/arg signedness mismatches (batch, ~13 sites) | Static analysis | Low | Low | Low |
| B1 | `--log` qmin message → `stderr` not `fp_log` (2/3 fixed upstream; `fastq_mergepairs.cc` open) | Bug | Low | Low–Med | Medium |
| I1 | Unchecked output write/flush/close → silent truncation | I/O robustness | Medium | Med–High | Low–Med |
| P1 | Width narrowing (wholesale) + little-endian-only SFF/UDB | Portability/UB | Med–High | Medium | Low–Med |
| L1 | Library-API lifecycle leaks (fatal=exit, session-lock deadlock, re-init leak) | Resource/lifecycle | High | High | Medium |
| L2 | Index-side re-init lacks free-then-null (`dbindex`/`dbhash`/`userfields`) → double-free / leak | Resource/lifecycle | Low | Medium | Low–Med |
| N1 | `count_t` saturation mis-ranks long-read hits; unguarded `/0` → `inf`/`nan` | Numerical | Low–Med | High | Medium |
| N2 | SIMD alignment counters (`aligned`/`matches`/…) are `unsigned short` → wrap on long alignment paths | Numerical | Medium | Medium | Low–Med |
| A1 | Input validation via `assert()` compiled out under NDEBUG (SFF overflow guards) | Assert/NDEBUG | Low | Medium | Medium |
| C1 | `init_defaults` misses 52 globals → stale config across library sessions | Library lifecycle | Low | Med–High | Medium |
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
   hardening/latent and can follow. Fix **A1** together with **S2** — both are
   SFF-reader input checks (A1's overflow guards are asserts that vanish under
   the default `-DNDEBUG`); convert them to `fatal()` in the same pass.
2. **B1** — isolated, low-risk correctness fix.
2b. **N1(a)** — high value for the cost: widening `count_t` removes a silent
   wrong-ranking bug on long-read data. Pair it with a long-read reference-output
   regression case, since no sanitizer will catch a regression here. **N1(b)** is a
   cheap guarded-divide cleanup alongside it.
3. **E5**, **E8**, **E9** — quick, low-risk cleanups with immediate line-count payoff.
   Fold **I1**'s checked-close logic into the **E5** shared open/close helper so
   the write-error guard lands in one place rather than at ~110 call sites.
   For **P1**, the cheap first step is tooling: add a non-gating `-Wconversion`
   `-Wsign-conversion` CI lane (mirroring the sanitizer inventory) to size the
   width-narrowing backlog before touching code; the endianness items are low
   priority while no big-endian target is supported.
4. **E2 → E1 → E4** — the core architectural thread (single option table, finish
   the `Parameters` migration, then eliminate global state); E4 directly improves
   library-API safety. **L1** rides this thread: L1(b)/L1(c) are quick standalone
   fixes (scope-guard the session unlock; free before re-init), but L1(a) — giving
   the core a recoverable error channel instead of `fatal()`→`exit()` — is the
   large library-API change that only becomes tractable once E4 removes the global
   state it would have to unwind. **C1(a)** is a quick standalone fix (add the 52
   missing globals — at least the behavioral ones — to `init_defaults`); **C1(b)**
   is the reason to finish E1 in one direction rather than leave the
   `opt_*`/`Parameters` split half-applied. Pair C1 with a two-session regression
   test.
5. **E3**, **E6**, **E7** — structural decomposition, largely unlocked by the above.

> Note: several findings (S1–S4, S5, S6, S9) trace to file/CLI-derived values
> used as lengths or indices without validation. A small set of shared
> "validate-on-load" helpers for the binary parsers would address several at
> once and prevent recurrence.
