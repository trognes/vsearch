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
| **3 — dereplication & seq ops** | `derep`, `derep_prefix`, `derep_smallmem`, `rereplicate`, `shuffle`, `subsample`, `sortbylength`, `sortbysize`, `cut`, `getseq` | **audited** (this pass → S20–S22; folded sites in S4/S5/B1/N1/L2/E7/E9) |
| **4 — output, formatting & stats** | `results`, `otutable`, `msa`, `showalign`, `fastq_stats`, `eestats`, `fastqops`, `fastq_join`, `filter`, `tax` | **audited** (this pass → S23–S25, B2; folded sites in S5/I1/N1/E2/E9) |
| **5 — CLI/dispatch & infra** | `vsearch.cc`, `util`, `arch`, `cpu`, `attributes`, `dynlibs`, `bitmap`, `minheap`, `city`, `md5`, `sha1` | **audited** (this pass → S26, N3, C1(d)/(e); folded into S7/S8/A1/I1/P1/E1/E2/E9; F-C1 ruled safe) |
| **6 — headers & `utils/`** | all `*.h`, `src/utils/*.hpp` | **audited** (this pass → corrected A1's round_up cite; U5→I1, U4/U7→P1, cigar/span asserts→A1, H1→E1; output structs verified bounded) |

**The file-by-file sweep is complete — all six tiers audited.** What remains is
not unreviewed code but a few analysis *methods* a source read cannot substitute
for (ThreadSanitizer for the data-race surface CC1, parser fuzzing, a big-endian
build) — see **"Analysis methods not yet applied"** at the end of this document.

---

## Bugs

### B1. `--log` quality-error messages written to `stderr` instead of the log file

**Status: FIXED (all 3 sites + the `rereplicate.cc` sibling slip).** The
`eestats.cc` and `filter.cc` sites were corrected in commit `310e7de`; the
remaining `fastq_mergepairs.cc` `get_qual()` site was fixed in commit `6dbba98`
("Write to logfile instead of stderr in fastq_mergepairs.cc"). All three qmin
branches now write to `fp_log`. The `rereplicate.cc` sibling slip was
subsequently fixed in commit `273c40d` ("Write missing-abundance warning to
logfile in rereplicate.cc"; merged via PR #16 here and upstreamed as PR #628).
Retained here for the record and the E8 dedup note; **no open work.**

The "FASTQ quality value below qmin" fatal-error branch re-emits to `stderr`
from inside an `if (fp_log != nullptr)` guard, instead of writing to `fp_log`.
When a `--log` file is given, the qmin message is printed to `stderr` twice and
never reaches the log. The qmax branch immediately below each occurrence is
written correctly (`fprintf(fp_log, …)`), which confirms the qmin branch is a
copy-paste slip. An exhaustive sweep originally found three occurrences:

| File | Line | Function / context | State |
|------|------|--------------------|-------|
| `src/fastq_mergepairs.cc` | ~278 | `get_qual()`, qmin branch | fixed (`6dbba98`) |
| `src/eestats.cc` | ~87 | quality check, qmin branch | fixed (`310e7de`) |
| `src/filter.cc` | ~85 | quality check, qmin branch (note `std::fprintf`) | fixed (`310e7de`) |

- **Type:** Bug (incorrect output destination) — **resolved**
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Medium
- **Note:** The three blocks are near-identical and likely share an ancestor;
  a shared quality-check helper (see E8) would collapse this to one point of
  correctness. The upstream fix patched two sites independently rather than
  introducing such a helper, so the duplication (and the third site) persists.
- **Related slip (Tier-3 audit) — FIXED (`273c40d`):** `rereplicate.cc:133` wrote
  a WARNING to `stderr` from inside the `if (fp_log != nullptr)` log branch — the
  same `stderr`-instead-of-`fp_log` copy-paste pattern as B1 (the message was
  missing from the log and duplicated on `stderr`). Corrected to write to
  `fp_log`; same one-token class as the three qmin sites above.

### B2. MSA consensus `;length=` reported one too large (off-by-one)

**Status: FIXED (`bb45598`).** `print_consensus_sequence` (`msa.cc`) now passes
`cons_v.size() - 1`, excluding the `'\0'` terminator slot, so the reported length
matches the true residue count. Merged via the `bugfixes` branch here and
upstreamed as PR #629. Original analysis retained below.

`compute_and_print_consensus` (`msa.cc`) sizes `cons_v.resize(conslen + 1)` (the
last slot is the `'\0'`), but `print_consensus_sequence` (`msa.cc:493`) passed
`static_cast<int>(cons_v.size())` — i.e. `conslen + 1` — as the **sequence
length** argument to `fasta_print_general`. Every other caller passes the true
residue count (e.g. `alignment_length`, `db_getsequencelen`). The sequence body
is unaffected (it is printed via `"%.*s"`, which stops at the embedded NUL), so
the only visible effect was the `;length=` field: with `--cluster_* --consout
--lengthout`, each cluster's consensus length was reported one too high.

- **Type:** Bug (incorrect output value)
- **Reachability:** `--consout --lengthout` — every cluster.
- **Fix:** pass `cons_v.size() - 1` (or carry `conslen`), matching the convention
  used everywhere else.
- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *verified*

---

## Security findings

Memory-safety and input-validation issues from a dedicated security pass over
the parsers, format readers, allocation paths, and output formatting. The
recurring root cause is **a value taken from a file (or from a CLI offset)
used as a length or index without a range/ordering check**. Items marked
*verified* were confirmed by reading the surrounding code.

> **Not all of these need a crafted file.** Six items below are reachable on
> ordinary, non-malicious input or a normal option choice — `S4` (`--subseq_start`
> on a mixed-length file), `S10` (large `--maxaccepts`/`--maxrejects` on a small
> dataset), `S12` (DUST on any masking run), `S20` (`--sizein` subsampling), and
> `S23`/`S24` (`fastq_eestats` on long reads / `--fastq_qmin ≥ 2`). They are plain
> bugs, **typed `Bug` in the summary table** and prioritized in Bands 1–2 of the
> sequencing; they keep their `S` ids only because this pass is where they were
> found. The remaining `S` items are gated on a crafted/corrupt `.udb`/`.sff` and
> are the genuine "security" subset (Band 4).

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
- **Fix scope (Tier-3 audit):** the quality-pointer twin is at `getseq.cc:493`
  (`fastx_get_quality(h1) + start - 1`) and is reached whenever `--fastqout` is
  set, *independently* of `--fastaout`. The guard must be applied once, **before**
  computing `length` and offsetting *both* the sequence and quality pointers — not
  just the FASTA path.

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
  `seqinfo_s.seqlen`/`headerlen` being `unsigned int`; `opt_maxseqlength` is now
  bounded to `UINT32_MAX` (`749b439`), though those fields stay `unsigned int`.
- **Additional sites (Tier-2 audit) — with a write-overflow twist:** the library
  search entry points narrow `std::strlen(query_head)` to `int head_len`
  (`search.cc:1081` `search_session_single`, `search.cc:1244`
  `search_batch_worker_fn`); a negative `head_len` then mis-drives the
  `query_head` realloc decision so a `strcpy` can overflow the buffer. Library
  API only, gated on a >2 GB header — defense-in-depth, but unlike the read-only
  print-path sites this one can corrupt the heap.
- **Additional sites (Tier-3 audit):** `getseq.cc` `test_label_match` narrows
  several `size_t` lengths to `int` (`:179, 186, 190, 194, 237, 279, 284`) and
  computes `int field_buffer_size = field_len + 2 + longest_label` (`:187–196`)
  in `int` — a >2 GB header/label or pathological `--label_field` makes these
  negative and feeds a negative/overflowed `resize()` then `strcpy`/`std::copy`
  into `field_buffer` (write-overflow twist again). Gated on >2 GB; same fix
  (carry as `size_t`/`int64_t`).
- **Additional sites (Tier-4 audit):** with `--rowlen 0`, `int const rowlen =
  qseqlen + dseqlen` (`results.cc:722`) sums two `int64_t` lengths into an `int`
  that then sizes the `showalign` line buffers (`q_line.resize(width+1)`) while
  `putop` walks the full alignment — a narrowing with a real **size-vs-walk
  mismatch** (`align_show` already stores `int64_t width`; only the computation
  and the `int alignwidth` parameter narrow). Also `otutable_add`
  (`otutable.cc:181–262`) narrows `regoff_t`/`size_t` match lengths to `int`
  before `vector.resize(len+1)` — a >2 GB header yields a negative/overflowed
  resize. Both gated on >2 GB; carry as `size_t`/`int64_t`.

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
- **Additional caller (Tier-5):** `minheap_init` (`minheap.cc:149–153`) takes a
  signed `int size` (from `tophits = opt_maxrejects + opt_maxaccepts + MAXDELAYED`,
  built from the 64-bit `--maxaccepts/--maxrejects`); a value overflowing `int` to
  negative makes `size * sizeof(elem_t)` (size_t, sign-extended) an enormous
  allocation. Take `size` as `size_t`, range-check, reject non-positive.

#### S8. `md5.c` `body()` unsigned-underflow loop if called with `size == 0` (Low)

`body()` ends with `} while (size -= 64);` (`md5.c:200`); a `size` of 0 would
underflow to ~`ULONG_MAX` and read far out of bounds. All current callers pass
a non-zero multiple of 64, so it is **not currently reachable** — latent only.
The same loop also under-runs on **any** non-multiple-of-64 `size` (Tier-5): it
decrements by 64 and tests the result, so a caller passing e.g. 100 wraps `size`.
`MD5_Update` always feeds multiples of 64, so latent — but the routine has no
internal guard on its contract.

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

#### S20. `random_subsampling` reads one element past `seqindex` (reachable OOB read, ASan-detectable)

`random_subsampling` (`subsample.cc:256–277`) advances the amplicon cursor at the
*bottom* of the loop: after the mass bookkeeping, `if (accumulated_mass >=
amplicon_mass) { ++amplicon_number; amplicon_mass = sizein_requested ?
db_getabundance(amplicon_number) : 1; … }`. On the iteration that consumes the
last unit of the final amplicon's mass, `++amplicon_number` makes
`amplicon_number == db_getsequencecount()`, and `db_getabundance(amplicon_number)`
reads `seqindex[dbsequencecount].size` — **one struct past the array** — before
the `while (n_reads_left > 0)` test exits. Unlike most Tier-2/3 findings this is a
genuinely reachable out-of-bounds heap read (the value is discarded, but ASan /
Valgrind will flag it).

- **Reachability:** with `--sizein` (so the `db_getabundance` branch is taken)
  whenever the final selected read is the last read of the last amplicon —
  *always* when sampling the whole dataset (`--sample_size` = total mass /
  `--sample_pct 100`), and otherwise whenever the RNG selects that last unit.
  Without `--sizein` the constant `1` branch is taken, so no OOB.
- **Fix:** only fetch the next amplicon's mass when the loop will continue
  (`amplicon_number < dbsequencecount`), e.g. advance the cursor at the top of
  the next iteration rather than the bottom of the current one.
- **Effort:** Low · **Impact:** Low–Medium · **Criticality:** Medium · *verified
  (reachable; one-struct over-read, value unused)*.

#### S21. `derep_prefix` hash mask declared `int` while the table size is `int64_t` → OOB at extreme scale (latent)

`derep_prefix` grows `int64_t hashtablesize` by `<<= 1` until `3*dbsequencecount
<= 2*hashtablesize` (`derep_prefix.cc:198–202`), then truncates it into `int const
hash_mask = hashtablesize - 1` (`derep_prefix.cc:203`). Once the table reaches
2³¹ buckets (input ≈ 1.43 billion sequences), `hashtablesize - 1` overflows `int`
to negative; sign-extended in `hashtable[hash & hash_mask]` (`:265, :304`) it no
longer confines the index → out-of-bounds `std::vector::operator[]` (no bounds
check under `-DNDEBUG`). The full-length `derep.cc` uses a wider mask, so this is
prefix-only.

- **Reachability:** ~1.4e9 sequences in one `--derep_prefix` run — not reachable
  in practice today, but a real latent index-overflow.
- **Fix:** declare `hash_mask` as `uint64_t`/`int64_t` to match `hashtablesize`.
- **Effort:** Low · **Impact:** High · **Criticality:** Low (extreme-scale only) ·
  *verified (overflow path); latent (trigger)* · narrowing family, distinct from N1(c).

#### S22. Non-finite CLI floats (NaN) bypass range validation → NaN→`uint64_t` cast UB (Low)

`args_getdouble` uses `sscanf("%lf")` (`vsearch.cc:763`), which accepts `nan`/`inf`.
Range checks of the form `if ((x < lo) or (x > hi))` are **false for NaN** (every
NaN comparison is false), so a NaN passes validation. Concrete instance:
`--sample_pct nan` survives the `<0 || >100` check (`vsearch.cc:4949`) and reaches
`std::floor(mass_total * nan / 100.0)` = NaN in `number_of_reads_to_sample`
(`subsample.cc:228`); casting NaN to `uint64_t` is undefined behavior (typically 0
or implementation-defined). `inf` is caught by the `> hi` branch; only NaN slips
through, and only for options whose validation is a pure range test.

- **Reachability:** any float option validated solely by a range comparison, e.g.
  `--fastx_subsample --sample_pct nan`.
- **Fix:** reject non-finite values in `args_getdouble` (a single `std::isfinite`
  check covers every such option at once).
- **Effort:** Low · **Impact:** Low · **Criticality:** Low · *verified* · I1-class
  input-validation gap.

#### S23. `fastq_eestats` `ee_start()` overflows 32-bit `int` for reads > ~2074 bp → heap OOB (High, reachable)

`ee_start(int pos, int resolution)` returns `pos * ((resolution * (pos + 1)) + 2)
/ 2` (`eestats.cc:127–130`). Every operand is `int`, so the whole product is
computed in 32-bit `int` and only *then* widened to the `int64_t` return type.
With the typical `resolution` (~1000) the value grows ~`500·pos²` and exceeds
`INT_MAX` once `pos ≳ 2074`. That overflowed (signed-UB, often negative) value is
used **both** to size the table — `ee_size = ee_start(len_alloc, resolution)` →
`ee_length_table(ee_size)` (`:163, 167, 187–196`) — **and** to index it:
`++ee_length_table[ee_start(i, resolution) + e_int]` (`:227`) and the read at
`:354`. Once it overflows, allocation size and indices disagree → out-of-bounds
heap writes and reads.

- **Reachability:** `vsearch --fastq_eestats f.fastq --output o` on **any dataset
  with reads longer than ~2074 nt** — routine for PacBio/Nanopore and merged
  amplicons. No special options. (The sanitizer CI misses it because the suite
  uses short reads.)
- **Fix:** do the arithmetic in 64-bit (`static_cast<int64_t>(pos) * …` inside
  `ee_start`). Note the table also grows ~quadratically with read length — a
  separate memory concern, but the overflow is the bug.
- **Effort:** Low · **Impact:** High (heap corruption) · **Criticality:** High ·
  *verified (int arithmetic; sizes + indexes the table)*.

#### S24. `fastq_eestats` writes past the per-position quality row when `--fastq_qmin ≥ 2` → heap OOB write (High, reachable)

Each per-position row of `qual_length_table` has width `max_quality + 1` where
`max_quality = opt_fastq_qmax - opt_fastq_qmin + 1` (`eestats.cc:161, 166, 190`),
so valid in-row indices are `0 … qmax-qmin+1`. But the write index uses the **raw**
quality value: `++qual_length_table[((max_quality + 1) * i) + qual]` (`:213`),
where `qual ∈ [opt_fastq_qmin, opt_fastq_qmax]` (range-checked, fatal outside,
`:79–94`). When `qmin > 1`, a high-quality base (`qual` near `qmax`) indexes up to
`qmin - 1` slots past the row — corrupting the next position's row and, at the
last position, writing past the whole allocation. The default `qmin = 0` masks it
(then `qual ∈ [0,qmax]`, row width `qmax+2`, in-bounds); the reader loops (`:257,
303`) iterate `0..max_quality`, so only the write at `:213` is out of bounds.

- **Reachability:** `vsearch --fastq_eestats f.fastq --output o --fastq_qmin 10`
  (any `qmin ≥ 2`) on data containing a near-`qmax` score. (CI uses default
  `qmin`, so misses it.)
- **Fix:** index by the offset from `qmin` (`qual - opt_fastq_qmin`) and translate
  back in the reader loops, or size rows to `qmax + 2`.
- **Effort:** Low–Medium · **Impact:** High (heap OOB write) · **Criticality:**
  High · *verified (row width vs raw-`qual` index)*.

#### S25. `build_sam_strings` walks the CIGAR into the sequences with no length bound (latent)

`build_sam_strings` (`results.cc:753–852`) parses a hit's CIGAR (`12M3I…`) and,
per op, advances `qpos`/`tpos` and reads `queryseq[qpos]` / `targetseq[tpos]`
with **no check that the positions stay within the sequence lengths** —
correctness rests entirely on the CIGAR's run-lengths summing to exactly the
sequence lengths. The `sscanf(p, "%d%n", …)` return is also unchecked. Safe today
because the CIGAR is produced by the in-tree aligner consistently with the
sequences; becomes an over-read only if a CIGAR/sequence pairing is ever
corrupted (e.g. a stale `nwalignment`, or mismatched lengths from a crafted DB).

- **Reachability:** latent (no user-triggered overflow on well-formed input today).
- **Fix:** pass query/target lengths and clamp/`fatal()` on `qpos`/`tpos` overrun;
  check the `sscanf` return.
- **Effort:** Medium · **Impact:** Medium · **Criticality:** Medium ·
  *latent; verified (no bound)* · same family as S4/S5 (length used without a check).

#### S26. SHA-1/MD5 transform: write-through-`const` and unaligned type-punning (UB)

`SHA1_Transform` (`sha1.c:137`) is compiled with `SHA1HANDSOFF` **undefined**
(it is commented out, `sha1.c:87`), so the `#else` path runs `block =
(CHAR64LONG16 *) buffer;` (`sha1.c:155`) — casting the `const uint8_t buffer[64]`
parameter to a non-`const` struct and, on little-endian, `blk0` **writes**
byte-swapped words back into it. `SHA1_Update` calls
`SHA1_Transform(context->state, data + i)` (`sha1.c:232`) where `data` is a
`const uint8_t *` parameter — so this writes through a pointer derived from a
`const` argument (UB) and mutates the **caller's input buffer**; today's callers
discard the buffer afterward, so no corruption is observed, but it is live UB on
every SHA-1 hash. The cast is also over an unaligned `uint8_t *` reinterpreted as
`uint32_t[16]` (misaligned access / strict-aliasing UB). `md5.c:78–79` has the
analogous misaligned `*(MD5_u32plus *)&ptr[n*4]` fast path on x86. `city.cc` is
clean by contrast — it uses `memcpy` (`Fetch32`/`Fetch64`).

- **Reachability:** every SHA-1 hash (`--derep_id`/hashing); observable
  corruption would need a caller that reuses its input buffer (none today). UBSan
  (`alignment`) would flag the misaligned loads.
- **Fix:** define `SHA1HANDSOFF` (copy into an aligned local workspace) for SHA-1;
  use `memcpy` into a `uint32_t`/`MD5_u32plus` (the city.cc pattern) for MD5.
- **Effort:** Low · **Impact:** Medium · **Criticality:** Medium · *verified
  (SHA1HANDSOFF off; const-cast write-through; unaligned cast)* · related P1 (the
  endianness FIXME on the same line is a different aspect).

#### S27. zlib/bzip2 loaded by bare soname at runtime — library-search-path trust (Low; Windows DLL-planting)

`.gz`/`.bz2` support is provided by `dlopen`/`LoadLibrary` of the compression
libraries at runtime, by **bare name**: on Linux `dlopen("libz.so.1", …)` /
`dlopen("libbz2.so.1", …)` (`dynlibs.cc:113, 134`), on Windows
`LoadLibraryA("zlib1.dll")` / `LoadLibraryA("libbz2.dll")` (`dynlibs.cc:111, 132`).
A bare name is resolved through the platform loader's search path, so whichever
matching library appears first on that path is loaded and its `gzread`/`BZ2_bzRead`
symbols are called on user input.

- **POSIX:** low risk — `dlopen` of a plain soname honours `LD_LIBRARY_PATH`,
  `RPATH`/`RUNPATH`, then the default trusted dirs; it does **not** include the
  current working directory. Hijacking requires an attacker who can already set the
  victim's environment or write a trusted library dir (i.e. already-privileged).
- **Windows:** higher risk — `LoadLibraryA` with an unqualified DLL name uses the
  Windows DLL search order, which (depending on `SafeDllSearchMode` / the app's
  config) can include the **current working directory** and the directory of the
  executable. Running `vsearch` from a directory an attacker can drop a
  `zlib1.dll` / `libbz2.dll` into enables classic **DLL planting** → arbitrary code
  in the vsearch process. The first `--gzip_decompress`/auto-sniffed `.gz` input
  triggers the load.
- **Fix direction:** on Windows, load with an absolute path (resolve next to the
  executable) and/or call `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 |
  …)` / pass `LOAD_LIBRARY_SEARCH_*` flags to `LoadLibraryEx`; on POSIX the bare
  soname is acceptable. (Cross-ref the E9 `dynlibs` entry, which covers the dead
  `gz*_p` declarations, the silent-when-absent behaviour, and the double-open
  handle leak — distinct, non-security aspects of the same file.)
- **Type:** Security (untrusted library load) · **Effort:** Low ·
  **Impact:** Low (POSIX) / Medium (Windows) · **Criticality:** Low ·
  *verified (bare-name load); Windows search-order risk by construction, no Windows
  CI target* · cross-ref E9.

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
- **Tier-4 sites:** `otutable.cc` (~40 `fprintf` + the `strftime` at `:408`),
  `eestats.cc` (the whole table dump), `msa.cc`, `showalign.cc`, `fastq_join.cc`,
  `fastqops.cc` — all unchecked. The `fastq_eestats`/`fastq_eestats2` commands
  additionally do no domain validation of their `opt_fastq_*` parameters (unlike
  `filter.cc`, which routes through `check_parameters`).
- **The named helper (Tier-6) — this is where the fix should land.** The
  `CloseFileHandle` `unique_ptr` deleter (`utils/open_file.hpp:76–80`) does
  `static_cast<void>(std::fclose(file_handle))` — discarding the `fclose` return
  for **every** `FileHandle`-managed output stream. Since `fclose` flushes stdio,
  a deferred write error first surfaces here. Adding `fflush`+`ferror`+checked
  `fclose`→`fatal()` to this one deleter covers all RAII-owned output at a single
  point (the I1 remedy, concretely sited).

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

**(d) More portability gaps (Tier-5/6).**
- **`open_output_file` opens `"w"`, not `"wb"`** (`utils/open_file.cpp:144`),
  while input uses `"rb"` (the comment even questions it). On Windows/MinGW text
  mode does LF→CRLF translation, corrupting FASTA/FASTQ/tabular byte streams.
  No-op on POSIX, so CI never sees it. Fix: `"wb"`.
- **`os_byteswap` has no portable fallback** (`utils/os_byteswap.{hpp,cpp}`): the
  final `#else` `#include <byteswap.h>` and an empty `.cpp` else — a non-BSD/Apple/
  Windows host lacking glibc's `<byteswap.h>` (musl/uClibc/exotic) fails to build.
- **`xrealloc` doesn't preserve `xmalloc`'s 16-byte alignment** on POSIX
  (`arch.cc:241–255` calls plain `realloc`; `_WIN32` uses `_aligned_realloc`). If
  any SIMD buffer (`counters`/alignment arrays) is ever `xrealloc`'d, an aligned
  load/store (`align_simd.cc`, `cpu.cc`'s `__m128i` store) could fault on a
  platform whose `realloc` returns 8-byte alignment. Couples with the `cpu.cc`
  `(__m128i*)counters` aligned-store assumption. *needs audit of whether SIMD
  buffers pass through `xrealloc`.*
- **Effort:** Low–Medium · **Impact:** Low–Medium · **Criticality:** Low · *latent
  (no Windows / non-glibc / mis-aligned-realloc target in CI)*

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
- **(e) `derep_session_init` does not free before re-init (Tier-3).**
  `derep_session_init` (`derep.cc:985`) resizes `hashtable` and resets `clusters`
  but does **not** free the `seq`/`header` strings `derep_add_sequence`
  `xstrdup`'d (`derep.cc:1056–1057`). A library client that reuses a session
  (`init → add* → get_results → init …`) leaks every prior string and drops the
  old buckets; the symmetric `init`/`cleanup` naming invites exactly this loop.
  Fix: have `derep_session_init` call `derep_session_cleanup` first (idempotent),
  or document that cleanup is mandatory before re-init. Also `derep_get_results`
  (`derep.cc:1069`) doesn't null-check `results` when `max_results > 0` (null +
  populated session → null-pointer write). *verified; library-reuse path.*
- **(f) `subsample` uses raw `fopen`/`fclose` instead of the RAII handle
  (Tier-3).** `subsample()` (`subsample.cc:367–414`) opens outputs with
  `fopen_output` and closes them at the end, so a `fatal()` in between (e.g. the
  `abort_if_fastq_out_of_fasta` or `n_reads > mass_total` checks) leaks the
  `FILE*` on the library path — inconsistent with the `open_output_file` RAII used
  by its four sibling commands. Fix: use the RAII wrapper, or run the checks
  before opening outputs. *verified; benign on the CLI (exit reclaims).*

---

## Concurrency / data races

### CC1. Multi-threaded commands have an unaudited data-race surface (no ThreadSanitizer coverage)

The findings above (E4, L1, C1) address **reentrancy** — single-threaded
reasoning about file-`static` state surviving between sessions. They do **not**
cover *data races* inside a single run: `search`, `cluster`, `chimera`, `sintax`,
`allpairs`, and `orient` all spin up a pthread worker pool (`--threads`) whose
workers concurrently read the shared database (`datap`/`seqindex` from `db.cc`,
the k-mer index from `dbindex.cc`) and update shared output/counters under
hand-placed mutexes. A code read can show the lock *placement* but cannot reliably
prove the *absence* of a torn read, a missing-mutex counter update, or a memory
ordering bug — that requires runtime race detection.

Specific spots a read flags as worth a race check (none confirmed as races, all
candidates for ThreadSanitizer):

- **`scorematrix` written by `search16_init` unsynchronized** (`align_simd.cc:111`,
  already noted under E4) — if any worker can observe it mid-write, that is a race.
- **Partly-guarded global counters** in `search.cc`/`chimera.cc` (the E4 table
  notes several counters live "on both sides of a pthread wall",
  `chimera.cc:110`) — confirm every cross-thread counter update is either
  thread-local-then-reduced or mutex-protected.
- **The save/overwrite/restore of `si_plus`/`si_minus` and `tophits`** in
  `cluster_assign_batch` / `chimera_detect_batch` (L2(d), E4) is safe only if no
  two sessions/threads touch those file-statics concurrently — a single-thread
  assumption that the batch/library entry points do not enforce.

- **Why no current signal:** the project's sanitizer CI builds **ASan+UBSan**, not
  **TSan** (ASan and TSan are mutually exclusive — a separate build/run), and
  Valgrind CI uses Memcheck, not Helgrind/DRD. So the entire data-race class is
  outside today's automated coverage. The vsearch-tests suite *does* exercise
  multi-threaded runs, so a TSan lane would get real coverage immediately.
- **Type:** Concurrency (latent; unaudited) · **Effort:** Medium (stand up a TSan
  lane + triage) · **Impact:** Medium–High (silent wrong results / rare crashes
  under threading) · **Criticality:** Medium · *not yet analysed — flagged as a
  method gap, see "Analysis methods not yet applied"* · cross-ref E4, L1, L2(d).

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

**Status: FIXED (`441ffff`).** The scalar increment in `search_topscores` now
saturates at `INT16_MAX` (32767) instead of wrapping —
`count_t & counter = searchinfo->kmers[list[j]]; if (counter < INT16_MAX) { ++counter; }`
(`searchcore.cc`). Merged via the `bugfixes` branch. Two refinements to the
original analysis below informed the fix:

- **The fix is the "clamp on increment" option, not the `uint32_t` widening.**
  The SIMD bitmap path (`increment_counters_from_bitmap*` in `cpu.cc`) already
  increments these counters with *signed* saturating ops (`_mm_subs_epi16`, NEON
  `vqsubq_s16`, AltiVec `vec_subs`) and so caps at 32767. Both paths update the
  same array, so letting the scalar path run past 32767 is also unsafe: a value
  it pushes into 32768..65535 is negative under the SIMD path's signed
  reinterpretation, and a later saturating increment there can drive it back
  through zero. Capping the scalar path at `INT16_MAX` keeps every counter in
  `[0, 32767]`, where the two paths agree and neither can wrap — zero memory cost
  and no per-architecture SIMD rewrite (the `uint32_t` widening would require
  re-coding the SSE2/SSSE3/NEON/AltiVec/SIMDe kernels for 32-bit lanes and
  doubling the per-thread `kmers` array).
- **Overflow needs >65 535 *distinct* shared k-mers, and a CLI repro is blocked
  by the aligner cap.** The counter rises at most once per distinct shared k-mer
  (the db index dedups k-mers per sequence, `dbindex.cc:187–196`), so both
  sequences must exceed ~32 k bp — which also exceeds the SIMD aligner's 25 M
  sequence-length-product cap (`align_simd.cc:1346`), so such a pair never yields
  an observable hit. This is why the item stayed *needs-confirmation*. The fix is
  verified by no-regression (pre/post-fix binaries byte-identical on normal
  search/cluster output) plus an isolated boundary check (old `++` wraps to 0 at
  65 536; new saturates at 32 767).

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
- **Fix (applied):** clamp on increment — saturate the scalar path at
  `INT16_MAX` to match the SIMD path's existing cap (see the Status block above).
  The alternative of widening `count_t` to `uint32_t` was not taken because it
  would require rewriting the per-architecture SIMD kernels for 32-bit lanes and
  doubling the per-thread `kmers` array, for precision only relevant in an edge
  the aligner cap makes unobservable.
- **Effort:** Low–Medium · **Impact:** High · **Criticality:** Medium
  (long-read workflows) · *verified (mechanism + fix); end-to-end CLI repro
  unobservable by construction (aligner product cap)*
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
| `derep.cc:722`, `derep_prefix.cc:378` | `average = 1.0 * sumsize / clusters` | `clusters == 0` (empty input) |

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

**Status: FIXED (`3b1ee82` + `677b2ee` + `be53758` + `54d18f6`).** Rather than
widening the counters, the fix bounds what the SIMD aligner accepts: a new
`search16_fits(qlen, dlen)` helper requires `qlen + dlen ≤ 65535` (so the path
length can never exceed the 16-bit counters) **in addition to** the existing
`qlen * dlen ≤ 25e6` product limit, diverting any pair that exceeds either to the
linear-memory aligner (`linmemalign`, which already reports `int64` statistics).
The `qlen == 0` truncation is fixed the same way — an over-long empty-query target
is diverted to `linmemalign` instead of being written into the `unsigned short`
outputs. Three follow-up commits also widened the aligner's own `int`
length-arithmetic to 64-bit (`dirbuffersize = qlen*maxdlen*4`, the `16*qlen`
backtrack index and fill-loop pointer advance, and the `hearray` allocation) —
latent today but would bite if the product limit were raised. Merged via the
`bugfixes` branch.

**Reachability refinement.** The original "`qlen=1, dlen=25e6` wraps `aligned`"
example does not actually trigger: `usearch_global` uses free end-gaps, so the
unaligned target tail is a *terminal* gap that is **not** counted, and optimal
alignment minimises columns — so in the SIMD regime (product ≤ 25e6) the counter
stays well bounded and the wrap is not observably reachable on the search path.
This is therefore verified **hardening / defense-in-depth** plus the real
`qlen == 0` truncation fix, not a demonstrated-output bug — consistent with the
Latent rating. (Verified: pre/post-fix binaries byte-identical on normal
search / cluster / allpairs / alnout; the sum-guard divert case is
behaviour-preserving — SIMD and `linmemalign` agree.)

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
- **Fix (applied):** sum guard + `linmemalign` divert (see Status above), keeping
  the counters 16-bit rather than widening the `search16` API. The alternative —
  widening the counters / `p*` output params / `searchcore` lists to
  `uint32_t`/`int64_t` — was not taken; bounding the input is smaller and reuses
  the existing fallback.
- **Effort:** Low (applied) · **Impact:** Medium (wrong stats, no crash) ·
  **Criticality:** Low–Medium · *verified (fix + behaviour-preserving); wrap not
  observably reachable on the search path* · distinct from N1(a).

#### (c) Accumulator widths — mostly safe, recorded for completeness

- **Abundance — correction.** An earlier draft of this note said abundance is
  "stored `int64_t size`." That is wrong: the per-sequence field is
  `unsigned int size` in `seqinfo_s` (`db.h:74`). `db_add` assigns an `int64_t
  abundance` into it (`db.cc:212`) and `db_getabundance` widens the already-
  truncated 32-bit value back to `uint64_t` (`db.h:92`). So a **per-sequence**
  abundance above `UINT_MAX` (~4.29e9) silently wraps, and a negative value
  becomes large-positive; the sort comparators compare the 32-bit field.
  Reachable only with a `;size=` (or summed) abundance above ~4.29 billion on a
  single sequence — realistic only on very large pooled datasets. **FIXED
  (`a7d7a0e`):** `seqinfo_s.size` widened to `uint64_t` (matching the return type
  and the `int64_t` source); it fits the struct's existing tail padding, so
  `sizeof(seqinfo_s)` is unchanged. *verified.*
- **Per-record lengths** `seqinfo_s.seqlen` / `headerlen` are likewise
  `unsigned int` (`db.h:72–73`); `db_add` stores `size_t` lengths into them, and
  `opt_maxseqlength` has **no upper bound** (only `< 1` is rejected,
  `vsearch.cc:5092`). A single record > `UINT_MAX` (~4 GB) with `--maxseqlength`
  raised above it truncates `seqlen`, which then feeds k-mer indexing,
  alignment, and `%.*s` output — same class as **S5**, distinct site (the DB
  index struct + the unbounded option). Gated on >4 GB input. **Partially FIXED
  (`749b439`):** `--maxseqlength` above `UINT32_MAX` is now rejected, so the
  option can no longer push `seqlen` past the field width; the `seqlen` /
  `headerlen` fields themselves remain `unsigned int`, so a >4 GB single record
  arriving from input still truncates (the S5 class). *verified.*
- **Abundance narrowed *below* the 32-bit storage (Tier-3 audit).** Two sites
  narrow the `int64_t` abundance even further, to `int`, before use — diverging
  from their siblings: `derep_smallmem.cc:390` (`int const abundance =
  fastx_get_abundance(h)`, then widened to `int64_t ab` — the full-length
  `derep.cc:527` and `derep_prefix.cc:235` keep `int64_t` directly), and
  `subsample.cc:199` where the per-amplicon deck is `std::vector<int>` so an
  abundance in `(INT_MAX, UINT_MAX]` becomes negative and corrupts the `uint64_t
  mass_total` accumulate (`subsample.cc:383`). `rereplicate.cc:110` likewise casts
  the cumulative `int64_t n_reads` to `int` for the output ordinal → wraps past
  2³¹ on very large re-replications. Reachable with `;size=` annotations above
  the relevant bound (the regime N1(c) already concerns). **FIXED:**
  `derep_smallmem` reads the abundance as `int64_t` directly (`0eb7f24`); the
  subsample deck is now `std::vector<uint64_t>` (`80af472`); and the rereplicate
  ordinal stays `int64_t` end-to-end (`31a4d30`).
- **Query abundance and `;size=` / `;centroid_size=` / `;seqs=` output — FIXED
  in the same batch.** `searchinfo_s.qsize` and `chimera_info_s.query_size`
  widened to `int64_t` (`350c7fe`); the query-abundance reads and the public
  library API widened to `int64_t` (`8c28156`, ABI bumped 0.1.0 → 0.2.0); and the
  abundance / centroid-size / cluster-size output fields print at full 64-bit
  width (`31a4d30` / `344a091` / `b423c3c`). Together with the size-ratio
  precision fix (N4, `4dbf556`) this completes 64-bit abundance handling across
  storage → filtering → output.
- **Statistics sums** (`sum_error_probabilities`, `sumee_length_table`,
  `qsum`) are `double` (`fastq_stats.cc:302–304`): no integer overflow, but
  floating-point summation drifts on very large inputs (a precision, not
  correctness-cliff, concern; Kahan summation would remove it if it ever
  matters).

- **Overall — Effort:** Low–Medium · **Impact:** High (a) / Medium (b) ·
  **Criticality:** Medium
- **Status:** **Largely FIXED** by the PR #22 64-bit-abundance batch — storage
  truncation (`a7d7a0e`), the sub-32-bit narrowings (`0eb7f24` / `80af472` /
  `31a4d30`), query-abundance and library-API widening (`350c7fe` / `8c28156`),
  the 64-bit output fields (`344a091` / `b423c3c`), and the `--maxseqlength`
  bound (`749b439`); the size-ratio precision half is N4 (`4dbf556`). *Remaining
  here:* `seqlen` / `headerlen` stay `unsigned int` (S5 class, >4 GB single
  record) and the `double` statistics sums are a precision-only note.

### N3. RNG quality, reproducibility, and reentrancy (Tier-5)

The shared random-number path has several correctness/quality issues, none a
memory bug:
- **(a) `random_ulong` builds 64 bits from four overlapping 31-bit draws.**
  `(arch_random()<<48) ^ (arch_random()<<32) ^ (arch_random()<<16) ^
  arch_random()` (`util.cc:268–288`): `arch_random()`/`random()` yields ≤31 bits,
  so the shifted terms **overlap** and are XORed — the result is not a uniform
  64-bit value, weakening any consumer needing uniform 64-bit randomness (large
  shuffles). Fix: take non-overlapping low-16-bit slices, or use a real 64-bit PRNG.
- **(b) `--randseed` is truncated to 32 bits on the shared path.** Stored
  `int64_t` (`vsearch.cc:1976`, no range check) but narrowed to `unsigned int` in
  `arch_srandom` (`arch.cc:177`), so `--randseed 4294967297` ≡ `--randseed 1` —
  two documented seeds silently collide. (Extends the E9 `shuffle.cc`-RNG note to
  the main `arch_srandom` path; `shuffle` additionally uses a *separate*
  `mt19937_64` engine, so the two RNG paths aren't comparable.)
- **(c) `random_int` re-derives the generator range from `RAND_MAX`** in `util.cc`
  while `arch_random` independently wraps `random()`/`rand()` — they agree only by
  coincidence of the platform `RAND_MAX`, a portability/coupling hazard.
- **(d) Global RNG state is not reentrant/thread-safe.** `srandom`/`random`
  operate on one process-global state; threaded use (search/cluster) gives
  non-deterministic results and breaks `--randseed` reproducibility under threads.
- **(e) `arch_srandom` accepts a short read of `/dev/urandom`** — only checks
  `read(...) < 0`, so a partial read leaves the seed partly at its `0` init.
- **(f) `random_int`/`random_ulong` guard `upper_limit != 0` only with an
  NDEBUG-stripped `assert`** (`util.cc:256, 274`) → `% 0` if a zero ever reaches
  them; current callers pass non-zero, so latent (A1 class).

- **Effort:** Low–Medium · **Impact:** Low–Medium (statistical quality /
  reproducibility) · **Criticality:** Low · *verified (logic); (d)/(b) reachable,
  others latent*

### N4. `opt_maxqsize` default caps query abundance at `int_max`; abskew/size-ratio comparison loses precision above 2⁵³

Two entangled issues, surfaced while widening the query abundance to 64-bit
(the N1(c) batch).

- **(a) `opt_maxqsize` defaults to `int_max`, not `int64_max`** (`vsearch.cc:929`).
  The sibling abundance limits `opt_maxsize`/`opt_maxuniquesize` default to
  `int64_max` (no effective cap), but `opt_maxqsize` defaults to `INT_MAX`
  (~2.1e9) — a leftover from when the query abundance (`qsize`) was `int`. Now
  that `qsize` is `int64_t`, this default **silently drops every query whose
  `;size=` exceeds ~2.1e9** from search/usearch_global/chimera, with no message
  and no user-set `--maxqsize`. Reachable on deeply pooled data; the workaround
  is to pass an explicit `--maxqsize`. Fix is one line (`int_max` → `int64_max`),
  **but see (b)** — it un-masks the precision issue below.

- **(b) The abskew / size-ratio comparison is done in `double` and cannot
  distinguish abundances differing by less than ~1 ULP above 2⁵³.**
  `searchcore.cc:492–495` evaluates `qsize >= opt_minsizeratio * tsize` and
  `qsize <= opt_maxsizeratio * tsize` (with `opt_maxsizeratio = 1/abskew`) in
  `double`. For abundances above 2⁵³ (~9.0e15) an integer `+1` is below double
  precision, so e.g. a query of `1e16+1` against a parent of `2e16` at
  `--abskew 2` is treated as exactly half — the parent is wrongly accepted and
  the query mis-flagged as a chimera. The `frederic-mahe/vsearch-tests`
  `chimeras_denovo` "distinguish … below DBL_EPSILON" test exercises exactly
  this (abundances ~2e16) and **only ever passed by accident**: first via 32-bit
  abundance truncation (pre-N1(c)), then via the `opt_maxqsize = int_max` cap in
  (a) dropping the high-abundance query before the comparison runs. Fixing (a)
  removes that cap and exposes (b), so the two must be addressed together.

- **Status:** **FIXED** (`4dbf556`). Both parts landed together in one commit
  (they are unseparable — fixing (a) alone regresses the DBL_EPSILON test
  through (b)):
  - **(a)** `opt_maxqsize` default raised `int_max` → `int64_max`
    (`vsearch.cc:929`), matching the `--maxsize`/`--maxuniquesize` defaults.
  - **(b)** the two size-ratio comparisons now route through a new
    `abundance_ratio_cmp()` (`searchcore.cc`) that returns the exact sign of
    `value − ratio·reference`. It keeps the historical `double` comparison while
    both abundances are below 2⁵³ (where `double` is exact, preserving boundary
    behaviour for non-dyadic ratios such as `1/9` when `--abskew 9` — the old
    code accepted the equal case because `double(1/9)·9` rounds up to `1.0`),
    and switches to exact 128-bit integer arithmetic above 2⁵³, decomposing the
    stored ratio as `mantissa · 2^exponent` (via `frexp`/`ldexp`) and
    cross-multiplying in `unsigned __int128` with a per-bit overflow guard.
  - The `chimeras_denovo` test is unchanged and now passes **for the right
    reason**: the FLT/DBL_EPSILON "distinguish" cases plus the abskew
    greater/equal/smaller boundary cases all pass (full suite 297/297). The
    chosen 2⁵³ threshold means the *only* behaviour change versus the old code
    is at abundances above 2⁵³, exactly where `double` was already wrong.
- **Effort:** (a) Low · (b) Medium · **Impact:** Medium (silent query drop;
  wrong chimera calls at extreme abundance) · **Criticality:** Low–Medium ·
  *verified (unit-checked sign table + full `chimeras_denovo` suite)* ·
  related N1(c).

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
| `sff_convert.cc:136` | `n_bytes <= UINT16_MAX - stub` | SFF flow/key region size — the **live** `round_up_to_8(uint16_t)` (see correction below) |
| `sff_convert.cc:258` | `flows_per_read <= UINT16_MAX - (header + key_length)` | `sff_header.flows_per_read`, read from file |
| `sff_convert.cc:288` | `name_length <= UINT16_MAX - read_header_size` | `read_header.name_length`, read from file |
| `sff_convert.cc:323` | `n_bytes_to_read < SIZE_MAX` | input-derived read length |

> **Correction (Tier-6 audit):** an earlier draft cited `utils/round_up.hpp:117`
> as "the SFF overflow guard." That header is **dead code** — its templated
> `round_up_to_8<>` is referenced only by its own `static_assert` block, included
> by no source file. The SFF path uses a **separate, non-template
> `round_up_to_8(uint16_t)`** at `sff_convert.cc:131` (guard at `:136`). The sum
> `n_bytes_in_header + flows_per_read + key_length` is computed in `size_t` then
> **narrowed to the `uint16_t` parameter** (a crafted `flows_per_read` near
> `0xFFFF` wraps it), with only the NDEBUG-stripped asserts protecting it. Fix in
> `sff_convert.cc`, and either delete `round_up.hpp` or make the SFF path use it.

**More assert-as-validation sites (Tier-5/6).** Beyond the SFF set above, the
default-`NDEBUG` build also strips these (all latent today — the inputs are
internally produced — but they are validation written as `assert`):
- **`utils/cigar.cpp:92–101`** (`convert_to_operation`): an unrecognized CIGAR op
  char hits only `assert(op == 'M'|'I'|'D')`, then **falls through to
  `return Operation::match`** — invalid ops silently become matches. (The
  *missing*-op case at `:157` correctly `fatal()`s.) Reusable parser; would bite a
  future SAM-import / external-CIGAR caller. Related to S25.
- **`utils/cigar.cpp:124–140`** (run-length): `strtoll` parses up to `LLONG_MAX`,
  guarded only by `assert(<= INT_MAX)`; `print_uncompressed_cigar` then loops that
  many times → unbounded output (DoS) on a crafted CIGAR.
- **`utils/span.hpp`** bounds (`operator[]`/`front`/`back`/`subspan`/`first`/`last`)
  and **`city.cc:140` `Rotate`** (`assert(shift != 64)`) are assert-only; both are
  safe in practice (callers supply in-range args; all `Rotate` shifts are compile-
  time constants 18–53), recorded for the NDEBUG caveat.

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
| `opt_notmatchedfq` | `search.cc` etc. | unmatched-reads FASTQ output — **never reset (confirmed bug)** |

**Smoking gun (Tier-5 audit):** `vsearch_init_defaults()` writes
`opt_notmatched = nullptr;` **twice** (`vsearch.cc:957–958`); line 958 was plainly
meant to be `opt_notmatchedfq = nullptr;`. `opt_notmatchedfq` is declared
(`vsearch.h:190`) and set by `--notmatchedfq` (`vsearch.cc:2661`) but assigned
nowhere in `init_defaults` — so a second library session that omits
`--notmatchedfq` silently inherits the first session's path and writes an
unmatched-reads FASTQ the caller never requested. One-line fix (change line 958).

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

#### (d) `vsearch_apply_defaults_fixups()` is not idempotent — double-call corrupts gap penalties (Tier-5)

The fixups function unconditionally does `opt_gap_open_* -= opt_gap_extension_*`
(`vsearch.cc:1089–1098`), with a comment claiming it is "safe to call repeatedly"
— but that holds **only if `vsearch_init_defaults()` runs between every pair of
fixups calls** (it re-reads the resets). The documented "override `opt_*` → call
fixups" lifecycle invites a caller to set a gap option, call fixups, adjust
another option, and call fixups **again without re-init** — which double-subtracts
the extension penalty from every gap-open penalty → silently wrong alignment
scores. Nothing guards a second invocation (no "already applied" flag), and
`vsearch_api.h:115` even advertises that fixups "re-applies gap penalty"
adjustments. Fix: make the adjustment idempotent (guard flag, or compute adjusted
penalties into separate fields) or document that fixups must follow init.
*verified; library-reachable; Medium.*

#### (e) The CLI-only validation gap is a class, not two sites (Tier-5; generalizes S13/S17)

A full enumeration of the `args_init` validation block (`vsearch.cc:4833–5095`)
vs. `vsearch_apply_defaults_fixups` confirms the S13/S17 root cause applies to
**every** check there — the library path runs none of them. The memory-relevant
ones to move into the shared fixup: `opt_wordlength` (S13), `opt_chimeras_parents_max`
(S17), **`opt_threads`** (no upper bound → the `chimera.cc:2975` `nthreads*sizeof`
multiply, S7), and **`opt_maxaccepts`/`opt_maxrejects`** (non-negative → feed the
S10 `tophits` sizing). Others are silent-wrong-config only (`opt_iddef [0,4]`
selects an undefined identity definition; `opt_chimeras_parts`/`chimeras_length_min`
are re-clamped or used only as thresholds — verified safe). Single fix: validate
bounds in `vsearch_apply_defaults_fixups()`.

- **Overall — Effort:** Low (for the live (a) part) · **Impact:** Medium–High ·
  **Criticality:** Medium
- **Status:** *verified (reset gap incl. opt_notmatchedfq, config read sites, db
  re-init safety, non-idempotent fixups, validation-gap enumeration); multi-session
  effects are by construction, want a two-session regression test (see
  `api_examples/example_reinit.cc`)*

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
- **Concrete drift hazard (Tier-2/6):** `Parameters::opt_strand` is a **`bool`**
  (`vsearch.h:561`) while the global `opt_strand` is `int64_t` with **tri-state**
  semantics (`1`=plus, `2`=both, tested as `opt_strand > 1` in `searchcore.cc`,
  `search.cc`, `cluster.cc`). The struct mirror cannot represent "both strands".
  Not live today (the core engines read the `int64_t` global; `args_init` sets
  both in lockstep; the only struct readers — `derep*` — use it as a boolean), but
  the moment a strand-sensitive dispatcher is migrated to `parameters.opt_strand`
  it silently loses minus-strand search with no compile error. Also seen as the
  allocate-vs-iterate skew in `search_exact.cc` (allocation keyed on the bool,
  loops on the int). Fix: make the struct field `int64_t`.

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
- **Confirmed consumer (Tier-4):** `results_show_userout_one` (`results.cc:344–509`)
  is exactly that consumer — a `switch` on the field index with cases 0–42 and
  **no `default`**, so the case numbers must stay in lockstep with the order of
  `userfields_names[]`; nothing asserts the coupling, and an out-of-range index
  would silently print nothing. Add `default: fatal(...)` as an interim guard.
- **Latent OOB from the matrix itself (Tier-5):** the `valid_options[k][]` scan
  loops (`vsearch.cc:4785–4793, 4817–4821`) do `while (valid_options[k][j] >= 0)
  ++j;` with **no index ceiling**, trusting each row of the
  `std::array<std::array<int,100>,50>` to contain a `-1` sentinel before slot 100.
  A future edit filling a row to exactly 100 valid options (no room for `-1`) reads
  past the inner array. Not triggered today (longest row is well under 100). Bound
  the loop with `j < max_number_of_options_per_command`.

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
- **`shuffle.cc` / `sortbylength.cc` / `sortbysize.cc`** (Tier-3) carry ~4 copies
  of the same deck-build → sort → median → truncate → output scaffold, differing
  only in the sort key: `truncate_deck` is triplicated (`shuffle.cc:103`,
  `sortbylength.cc:178`, `sortbysize.cc:191`), `find_median_length` /
  `find_median_abundance` are byte-for-byte duplicates bar the field name, and the
  three `output_*` bodies match. Two of them already carry a `// refactoring:
  extract as a template` breadcrumb. A `<Key>`-templated deck pipeline would
  collapse `sortbylength`/`sortbysize` to a comparator + projection each. (The
  `find_median_*` even-case `a + (b - a)*0.5` is correct only because the sort
  direction guarantees `b >= a` on the unsigned subtraction — fragile, undocumented
  coupling worth a comment.)

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
- `src/derep_smallmem.cc` — the comment at ~352–356 still claims sequences are
  compared "exactly identical … With 64-bit hashes", but the code matches on
  the 128-bit hash *only* (no `seqcmp`, unlike `derep.cc`/`derep_prefix.cc`); a
  128-bit CityHash collision would silently merge two distinct sequences. By
  design (memory tradeoff), but the comment misrepresents it — update it
  (Tier-3).
- `src/sortbysize.cc` — dead commented-out `trim_deck`/`erase_high_abundances`
  blocks (~173–188, 213–222) (Tier-3).
- `src/cut.cc` — `locate_*_restriction_site`/`remove_restriction_sites`
  (~360–379) pass `pattern.find('^'|'_')` straight to `erase`/`static_cast<int>`
  with no `npos` check; safe only because `cut()` validates presence first
  (`:461–462`) — fragile against reordering/reuse (`npos`→`int` would be `-1`)
  (Tier-3).
- `src/shuffle.cc` — uses its own `std::mt19937_64` seeded locally
  (`std::random_device` when `--randseed 0`), diverging from the global
  `random()`/`arch_srandom` engine every other randomized command uses; a given
  `--randseed` yields a different permutation than the shared path, and the seed
  is truncated `int64_t`→`unsigned int` (same silent >32-bit drop as
  `arch_srandom`). Reproducibility/consistency, not a bug (Tier-3).
- `src/derep.cc` — `convert_probability_to_quality_symbol` (~180–187) can
  `log10(0.0)`→`-inf` then `static_cast<int64_t>(+inf)` (float→int UB) if a
  probability underflows to exactly 0.0; not reachable with single-byte FASTQ
  quality (q would need ≳3500), but the cast is unguarded (Tier-3, latent).
- `src/otutable.cc` — `otutable_print_biomout` captures
  `static const time_t time_now = time(nullptr)` once, so every biom file after
  the first in a long-running/library process carries the **first** call's
  timestamp; also `localtime()` returns a shared static (not thread-safe). Drop
  `static`; use `localtime_r` (Tier-4).
- `src/otutable.cc` — `otutable_print_otutabout`/`mothur` (~314–392) build the
  dense table by advancing a single `std::map` iterator in lockstep with nested
  `std::set` loops; correct only because the `pair`-keyed map orders identically
  to the set loops — a desync would silently shift every count. A per-cell
  `map::find` is clearer/robust (Tier-4, latent).
- `src/showalign.cc` — `--rowlen 0` combined with a zero-width alignment would
  overrun the `width+1` line buffers (`putop` resets only on `==width`); not
  reachable (no zero-length alignment reaches `align_show`), latent (Tier-4).
- `src/fastq_stats.cc` — `compute_distributions` stores `NaN` in the unreachable
  top bucket (`x/0.0`); harmless today (no consumer reads it), latent N1(b)-class
  (Tier-4).
- `src/fastq_join.cc` — dead `reserve()` blocks (~249–257) before the strings are
  reassigned via `operator+` (Tier-4).
- `src/utils/round_up.hpp` — **dead code**: the templated `round_up_to_8<>` is
  referenced only by its own `static_assert` block, included by no source file
  (the SFF path uses the separate `sff_convert.cc:131` copy). Delete it, or make
  the SFF path use it (collapsing the two). (Tier-6; see the A1 correction.)
- `src/dynlibs.{h,cc}` — `gzgetc_p`/`gzrewind_p`/`gzungetc_p`/`gzerror_p` are
  `extern`-declared (`dynlibs.h:72–75`) but never defined, resolved, or called —
  dead declarations. Also: `dynlibs_open` is silent when a library is absent
  (`dlopen`→null skips resolution, returns success; failure surfaces later as a
  null `*_p` call) and leaks the handle if called twice without `dynlibs_close`
  (library re-init). (Tier-5, latent.)
- `src/util.cc` — `xsprintf` has a dead `if (buffer == nullptr)` branch (xmalloc
  never returns null) and doesn't check the **second** `vsnprintf` return; `len +
  1` overflows if a formatted string ever reached `INT_MAX` (not realistic).
  `fatal(format, …)` overloads (`utils/fatal.cpp:81–114`) forward a runtime format
  string with no `__attribute__((format(printf,…)))`, so `-Wformat` can't police
  call sites (fragility; no bad caller today). (Tier-5/6.)
- `src/bitmap.cc` — `bitmap_init(0)` → `xmalloc(0)` then a `bitmap[0]` access is a
  1-byte OOB (no caller passes 0 today); `bitmap_free` dereferences `a_bitmap`
  without a null check (xmalloc guarantees non-null, so dead-defensive). (Tier-5.)
- `src/arch.cc` — `getrusage`/`sysconf` returns unchecked in `arch_get_memused`/
  `arch_get_user_system_time` (garbage on failure), and `arch_get_cores` can
  return `sysconf(...) == -1`, which flows into thread-pool sizing — clamp to ≥1.
  (Tier-5, latent.)
- `src/attributes.cc` — `header_get_size` (`;size=`) accepts any value up to
  `LLONG_MAX` with no sane upper bound, so one crafted header can inject a huge
  abundance into sum-of-sizes accumulators elsewhere (overflow lives in the
  accumulators). `src/sortbysize.cc`-style dead blocks not applicable here.
  (Tier-5, latent.)

- **Effort:** Low · **Impact:** Low · **Criticality:** Low

### E10. Per-file license header duplicated across the tree

The ~52-line GPL/BSD header block is repeated in 107 source files. Low value
and low risk; listed for completeness only.

- **Effort:** Low · **Impact:** Low · **Criticality:** Low

---

## Summary table

**Status legend** (workflow state, not severity — severity is in the other columns):

- **Fixed** — corrected in the codebase (commit referenced in the finding).
- **Partially fixed** — a multi-part finding whose sub-items are split across
  states; the per-sub-item status is given in the finding (commit referenced for
  the fixed parts).
- **Pending** — verified by reading the source *and* reachable on supported
  inputs/platforms; fix recommended, not yet made. The actionable backlog.
- **Latent** — mechanism verified, but not reachable on today's inputs/config/
  platforms (e.g. gated on >2 GB input, a big-endian host, or library-only
  misuse); the fix is hardening/portability rather than a live-bug repair.
- **Needs-confirm** — detected by reading; reachability not yet proven. Wants a
  crafted repro or a runtime (ASan/TSan/fuzz) check before it is fixed.

No item is marked "Ignored" — nothing has been triaged as won't-fix; the
"recorded for completeness, no action" observations live in the per-section
*Checked and found safe* lists, not here.

| ID | Title | Type | Effort | Impact | Criticality | Status |
|----|-------|------|--------|--------|-------------|--------|
| S1 | UDB `kmerindex` seqno → OOB heap write (`bitmap_set`) | Security | Low | High | High | Pending |
| S2 | SFF clip-offset underflow → OOB read (`--sff_clip`) | Security | Low | Med–High | Med–High | Pending |
| S3 | UDB header-length underflow → ~4 GB `headerlen` | Security | Low | Medium | Medium | Pending |
| S4 | `--subseq_start` unbounded → OOB read | Bug | Low | Medium | Medium | Pending |
| S10 | Hit-list alloc vs. index-bound mismatch (cluster/search) | Bug | Low | High | Medium | Pending |
| S5 | 64-bit length → `int` truncation in print path | Security | Medium | Medium | Low | Latent |
| S6 | UDB additive allocation size unchecked | Security | Low | Medium | Low | Needs-confirm |
| S7 | `xmalloc`/`xrealloc` no overflow check; `count*size` callers | Security | Low | Medium | Low | Needs-confirm |
| S8 | `md5.c` `body()` underflow if `size==0` (latent) | Security | Low | Low | Low | Latent |
| S9 | UDB `seqcount+1` wrap at `UINT_MAX` | Security | Low | Low | Low | Needs-confirm |
| S11 | Wrong `sizeof` in `dbmatched` alloc (latent) | Security | Low | Low | Low | Latent |
| S12 | DUST k-mer accumulator `int` left-shift overflow (CI-confirmed) | Bug | Low | Low | Low | Pending |
| S13 | `opt_wordlength` unvalidated on library path → shift UB + undersized k-mer index OOB | Security | Low | High | Medium | Pending |
| S14 | UDB header/length tables stored as `std::vector<int>` (signed) for unsigned 32-bit values | Security | Low | Medium | Medium | Pending |
| S15 | SFF flowgram-skip wrong short-read threshold → silent offset desync | Security | Low | Low–Med | Low–Med | Pending |
| S16 | UDB `kmerindexsize` summed from unchecked file counts, no consistency check | Security | Low | Medium | Low–Med | Needs-confirm |
| S17 | `opt_chimeras_parents_max` unvalidated on library path → OOB write in `find_best_parents_long` | Security | Low | High | Medium | Pending |
| S18 | `chimera_detect_single` trusts caller `query_len` → heap overflow via `strcpy` | Security | Low | High | Medium | Pending |
| S19 | Chimera denovo model-string fill over-increments `nth_parent` → OOB read | Security | Low | Med–High | Medium | Needs-confirm |
| S20 | `random_subsampling` reads one element past `seqindex` (reachable OOB read, `--sizein`) | Bug | Low | Low–Med | Medium | Pending |
| S21 | `derep_prefix` `int` hash mask vs `int64_t` table size → OOB at 2³¹ buckets | Security | Low | High | Low | Latent |
| S22 | Non-finite (NaN) CLI float bypasses range validation → NaN→`uint64_t` cast UB | Security | Low | Low | Low | Pending |
| S23 | `fastq_eestats` `ee_start()` 32-bit overflow on reads >~2074 bp → heap OOB | Bug | Low | High | High | Pending |
| S24 | `fastq_eestats` per-position quality-row OOB write when `--fastq_qmin ≥ 2` | Bug | Low–Med | High | High | Pending |
| S25 | `build_sam_strings` walks CIGAR into sequences with no length bound (latent) | Security | Medium | Medium | Medium | Latent |
| S26 | SHA-1/MD5 transform: write-through-`const` + unaligned type-punning (UB) | Security | Low | Medium | Medium | Pending |
| S27 | zlib/bzip2 loaded by bare soname → search-path trust (Windows DLL planting) | Security | Low | Low/Med | Low | Latent |
| ST1 | `memset` on `searchinfo_s` (has `std::vector` members) → leak/UB | Static analysis | Low–Med | Medium | Low–Med | Latent |
| ST2 | `printf` format/arg signedness mismatches (batch, ~13 sites) | Static analysis | Low | Low | Low | Latent |
| B1 | `--log` qmin message → `stderr` not `fp_log` (3 sites `310e7de`+`6dbba98`; `rereplicate.cc` sibling `273c40d`) | Bug | Low | Low–Med | Medium | Fixed |
| B2 | MSA consensus `;length=` reported one too large (`--consout --lengthout`, `bb45598`) | Bug | Low | Low | Low | Fixed |
| I1 | Unchecked output write/flush/close → silent truncation | I/O robustness | Medium | Med–High | Low–Med | Pending |
| P1 | Width narrowing (wholesale) + little-endian-only SFF/UDB | Portability/UB | Med–High | Medium | Low–Med | Latent |
| L1 | Library-API lifecycle leaks (fatal=exit, session-lock deadlock, re-init leak) | Resource/lifecycle | High | High | Medium | Pending |
| L2 | Index-side re-init lacks free-then-null (`dbindex`/`dbhash`/`userfields`) → double-free / leak | Resource/lifecycle | Low | Medium | Low–Med | Pending |
| CC1 | Threaded commands' data-race surface unaudited (no TSan coverage) | Concurrency | Medium | Med–High | Medium | Needs-confirm |
| N1 | `count_t` saturation mis-ranks long-read hits (a, FIXED `441ffff`); unguarded `/0` → `inf`/`nan` (b, pending) | Numerical | Low–Med | High | Medium | Partially fixed |
| N2 | SIMD alignment counters (`aligned`/`matches`/…) are `unsigned short` → wrap on long alignment paths (sum guard + `qlen==0` fix + 64-bit widening, `3b1ee82`/`677b2ee`/`be53758`/`54d18f6`) | Numerical | Low | Medium | Low–Med | Fixed |
| N3 | RNG quality/reproducibility/reentrancy (weak `random_ulong`, 32-bit seed, global state) | Numerical | Low–Med | Low–Med | Low | Pending |
| N4 | `opt_maxqsize` default `int_max` drops queries >2.1e9; abskew/size-ratio comparison loses precision above 2⁵³ (entangled; exact 128-bit cmp + int64_max default, `4dbf556`) | Numerical | Low/Med | Medium | Low–Med | Fixed |
| A1 | Input validation via `assert()` compiled out under NDEBUG (SFF overflow guards) | Assert/NDEBUG | Low | Medium | Medium | Pending |
| C1 | Library config: `init_defaults` misses globals (incl. `opt_notmatchedfq`, confirmed); non-idempotent fixups; CLI-only validation gap | Library lifecycle | Low | Med–High | Medium | Pending |
| E1 | Finish `opt_*` → `Parameters` migration | Enhancement | High | High | Medium | Pending |
| E2 | Single source of truth for option metadata | Enhancement | High | High | Medium | Pending |
| E3 | Split `vsearch.cc` monolith | Enhancement | High | High | Low–Med | Pending |
| E4 | Remove module-scope global state (reentrancy) | Enhancement | High | High | Med–High | Pending |
| E5 | Deduplicate output-file open/close boilerplate | Enhancement | Low–Med | Medium | Low | Pending |
| E6 | Decompose oversized functions | Enhancement | Med–High | Medium | Low | Pending |
| E7 | Merge near-identical code paths | Enhancement | Medium | Medium | Low | Pending |
| E8 | Shared `struct Scoring` initializer | Enhancement | Low | Low–Med | Low | Pending |
| E9 | Remove dead/debug code | Enhancement | Low | Low | Low | Pending |
| E10 | Deduplicate license headers | Enhancement | Low | Low | Low | Pending |

## Suggested sequencing

**Prioritized for a scientific tool, not a network service.** The guiding question
is *"can this produce a wrong result or a crash on reasonable real input?"* — not
*"can a crafted file exploit it?"*. So the order leads with **silent
scientific-correctness errors** and **plain bugs on realistic data/options**, and
pushes **crafted-/malicious-input hardening down**. (Note: six findings that turned
up in the security pass are really *plain bugs reachable on non-malicious input* and
have been **re-typed `Bug`** in the summary table accordingly — **S23, S24, S20, S12,
S4, S10** — which is why they rank high here; they still carry an `S` id and live in
the Security-findings section because that pass found them. The items left as
`Type = Security` are the ones gated on a crafted/corrupt `.udb`/`.sff`, which drop
to Band 4.) **B1** is already **Fixed**. Each band groups findings that share a fix site or one regression test
so each lands as a single atomic commit.

### Band 1 — Silent wrong scientific results on realistic data (highest)

No crash, no sanitizer signal — just wrong numbers in the output. The worst class
for a scientific tool, and invisible without reference-output regression.

- **N1(a)** — the headline. `count_t` (`unsigned short`) saturates k-mer match
  counts above 65 535, so on **long-read data (PacBio/Nanopore)** — which vsearch
  supports — a true best hit is silently dropped or mis-ranked in search/cluster.
  Widen to `uint32_t`; pair with a long-read reference-output regression case.
- **B2** — MSA consensus `;length=` reported one too high for **every** cluster
  under `--consout --lengthout`. Trivial fix, pure wrong-output-value bug.
- **N1(b)** — secondary output fields (qcov, tcov, LCA, ee stats, masked %) divide
  without a zero guard → `inf`/`nan` emitted on empty/zero-length/degenerate
  records. One guarded-divide helper.
- **N2** — *FIXED* (`3b1ee82` et al.): alignment counters (`aligned`/`matches`/
  `mismatches`/`gaps`) are `unsigned short` and could wrap on long alignment paths;
  addressed by a sum guard that diverts oversized pairs to `linmemalign` (plus the
  `qlen==0` fix and 64-bit length arithmetic). Hardening — see the N2 finding.
- **N3** — RNG reproducibility: `--randseed` truncated to 32 bits and global RNG
  state is not thread-safe, so seeded runs are **not reproducible under threads** —
  a real reproducibility problem for subsample/shuffle/bootstrap.
- **Investigate threaded correctness early (CC1).** Data races in the default
  multi-threaded search/cluster/chimera path would corrupt results
  non-deterministically on ordinary input. It is unaudited (needs-confirm), so the
  **ThreadSanitizer lane (Band 8) is the highest-value of the three methods** under
  this philosophy — promote it ahead of fuzzing/portability.

### Band 2 — Crashes / heap corruption on reasonable input or option settings

Reachable with normal data or a sensible option choice — no crafted file:

- **S23** + **S24** — `fastq_eestats` heap OOB: 32-bit overflow in `ee_start()` for
  reads > ~2074 bp (**routine long reads**), and the per-position quality-row
  over-write when **`--fastq_qmin ≥ 2`** (an ordinary option). Both Low effort, one
  `eestats.cc` pass.
- **S10** — the hit-list buffer overflows when `--maxaccepts + --maxrejects` exceeds
  a small `seqcount` — a **legitimate option combination on small datasets**, not an
  attack. Size the buffer by the same bound used for indexing; confirm with the
  small-seqcount / large-`maxaccepts` ASan repro.
- **S4** — `--subseq_start` past a sequence's length (trivially hit on a
  **mixed-length file**) reads out of bounds. Clamp/skip; fix the quality pointer
  twin too.
- **S20** — `random_subsampling` reads one element past `seqindex` on `--sizein`.
  ASan-detectable; Low effort.
- **S12** — DUST `int` left-shift UB, UBSan-confirmed, fires on the **first masking
  command** of normal data. Make the accumulator `unsigned`. Trivial.

### Band 3 — Output integrity & robustness on imperfect (non-malicious) files

Real files get truncated by failed downloads or full disks; real pipelines lose
disks mid-run. Not adversarial, but they corrupt science silently:

- **I1** — every textual output goes through unchecked `fprintf`/`fclose`, so a full
  disk / quota / broken pipe (`vsearch … | head`) yields a **truncated output that
  still exits 0**. Add a checked-close helper (fold into the **E5** dedup so it lands
  once, at `utils/open_file.hpp`).
- **S2** + **S15** + **A1** — the SFF reader against a **truncated/corrupt** SFF
  (incomplete download): clip-offset underflow (S2), wrong flowgram-skip threshold
  (S15), and the four overflow `assert()`s that vanish under the default `-DNDEBUG`
  (A1) → convert to `fatal()`. One SFF pass; also fold the SFF char-signedness fixes
  (P1 checked-safe (i)/(ii)) here.
- **S5** / **N1(c)** — 64-bit sequence/header length → `int` truncation (>2 GB single
  record) and abundance/length truncation at `>UINT_MAX` — reachable on **genuinely
  large real datasets** (large assemblies, deeply pooled `;size=`), not crafted.

### Band 4 — Crafted-/malicious-input hardening (deprioritized)

Real memory-safety bugs, but they require a **deliberately malformed** `.udb`/`.sff`
— outside the practical threat model for this tool. Worth doing, low urgency:

- **S1** (the most serious — OOB *write* from a crafted `.udb`), bundled with the UDB
  type/validation set **S3/S9/S14/S16** (switch tables to `uint32_t`, validate
  offsets/lengths/counts against the file regions) and **S6** (overflow-check the
  additive `datap` alloc).
- **S25** (CIGAR walk bound), **S22** (`std::isfinite` in `args_getdouble`), **S26**
  (SHA-1/MD5 const-write-through UB), **S27** (Windows DLL-planting load path), **S7**
  /**S8**/**S11**/**S21** (latent overflow/scale), **ST2** (format signedness). The
  shared "validate-on-load" helpers in the note below cover most of these at once.

### Band 5 — Library-API correctness & lifecycle

Matters to `libvsearch` consumers, not CLI users feeding reasonable data:

- **C1(a)** — the confirmed `opt_notmatchedfq`-never-reset bug (`vsearch.cc:958`) +
  the other behavioral globals `init_defaults` misses; **C1(d)** — make
  `apply_defaults_fixups` idempotent.
- **S13/S17/S18** — the "CLI-only validation, library path unguarded" class: one
  shared bound-check gate in `vsearch_apply_defaults_fixups()` (C1(e) enumerates it),
  plus the `chimera_detect_single` `query_len` check. **S19** rides this (clamp
  `nth_parent`; confirm with a repro).
- **L1(b)** (scope-guard the session-mutex unlock), **L1(c)** (free before re-alloc),
  **L2** (null-after-free + self-free-on-reinit across `dbindex`/`dbhash`/`userfields`
  /`derep`; add `tophits` to the chimera save/restore). Pair Band 5 with a two-session
  API regression test (`api_examples/example_reinit.cc`).

### Band 6 — Quick, low-risk cleanups

**E5** (open/close dedup — vehicle for I1), **E8** (shared `Scoring` initializer),
**E9** (dead code: the B1 `rereplicate.cc:133` sibling, `kh_find_best_diagonal`,
`unique_compare`, `round_up.hpp`, the `dynlibs` dead decls), **ST1** (drop the
`memset` on `searchinfo_s` — it has `std::vector` members).

### Band 7 — Architecture

**E2 → E1 → E4** (single option table; finish the `opt_*`→`Parameters` migration in
one direction, closing the **C1(b)** drift trap; then eliminate global state). **E4**
directly improves library reentrancy and is the foundation under **CC1**'s
thread-safety. **L1(a)** rides this — a recoverable error channel instead of
`fatal()`→`exit()` only becomes tractable once E4 removes the global state it would
unwind. Then **E3/E6/E7** structural decomposition. For **P1**, the cheap first step
is a non-gating `-Wconversion`/`-Wsign-conversion` CI lane to size the width-narrowing
backlog before touching code.

### Band 8 — Different methods, not more reading

See "Analysis methods not yet applied." Under this philosophy the order is:
**(1) ThreadSanitizer** (CC1 — threaded correctness on *normal* runs, so promoted),
**(2) parser fuzzing** (turns the needs-confirm items S6/S7/S9/S16/S19 into
repros-or-clears), **(3) big-endian/non-glibc build** (validates the P1 portability
items; lowest, as no such platform is supported today).

> Note: most of Band 4 (S1–S4, S6, S9, S14, S16) plus the S13/S17/S18 library class
> trace to one root cause — a file- or caller-derived value used as a length or
> index without a range/ordering check. A small set of shared "validate-on-load"
> helpers for the binary parsers, plus the single `apply_defaults_fixups` validation
> gate, would address most of them at once and prevent recurrence.

---

## Analysis methods not yet applied (recommended next)

The findings above come from a **complete file-by-file source read** of `src/`
(all six tiers — see the coverage matrix) cross-checked against ASan/UBSan,
Valgrind/Memcheck, cppcheck, and CodeQL. That reading sweep has saturated: the
last tiers turned up mostly low-severity items, the usual signal that hand-reading
has reached diminishing returns. The remaining high-value work is not *more
reading* but a small number of **different techniques** a read cannot substitute
for. Each is scoped as separate, tool-driven effort, not part of this review.

1. **ThreadSanitizer on the threaded commands.** The single biggest coverage gap.
   Our concurrency reasoning (E4, L1, C1) is single-threaded; the actual data-race
   surface (**CC1**) — workers in `search`/`cluster`/`chimera`/`sintax`/`allpairs`/
   `orient` sharing `datap`/`seqindex`/the k-mer index and updating global counters
   — is entirely outside today's CI (ASan/UBSan + Memcheck, none of which detect
   races). Stand up a TSan build (mutually exclusive with ASan, so a separate lane)
   and run the multi-threaded parts of the vsearch-tests suite under it. Highest
   expected value of the three.

2. **Coverage-guided fuzzing of the parsers.** We found the crafted-input bugs
   (S1 UDB, S2/S15 SFF, S20 subsample, S18 chimera) by hand; the binary/text format
   readers — **UDB, SFF, FASTQ, BIOM, FASTA** — are exactly where a fuzzer
   (libFuzzer/AFL++ on a small harness per format) systematically beats reading.
   Two properties make vsearch unusually fuzz-friendly: `-fno-exceptions` plus
   `fatal()`→`std::exit()` means every malformed-input path is either a clean exit
   or a memory bug (no exception noise), and ASan instrumentation turns the
   latent/needs-confirmation S-items (S3, S6, S9, S16, S19, S25) into crashing
   repros or clears them. The sanitizer CI runs only **well-formed** inputs (its
   own caveat), so this is the natural way to reach the S1–S4/S14–S19 crafted-input
   class.

3. **Big-endian / non-glibc build-and-run matrix.** P1(b) documents the
   little-endian-only assumptions in the UDB and SFF readers (and the BE hash-
   distribution degradation), and P1(d) the non-glibc `os_byteswap` build break and
   the Windows `"w"`-vs-`"wb"` text-mode corruption — but **nobody has built or run
   on a big-endian or musl/uClibc target.** The dormant `build-all.yml` matrix is
   entirely little-endian, so these paths are never exercised. Add a big-endian
   target (e.g. s390x under QEMU) and a musl build to the matrix to turn the P1
   "by construction" items into pass/fail evidence. Lowest priority while no
   big-endian platform is actually supported, but it is the only way to validate
   the portability the build matrix advertises.

These are **method gaps, not unreviewed code** — the source itself has been read
in full. Treat them as the next tier of effort (separate PRs / CI lanes), to be
scheduled when the static backlog above is being worked, not as an extension of
this reading audit.
