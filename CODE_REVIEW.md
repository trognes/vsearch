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
| I1 | Unchecked output write/flush/close → silent truncation | I/O robustness | Medium | Med–High | Low–Med |
| P1 | Width narrowing (wholesale) + little-endian-only SFF/UDB | Portability/UB | Med–High | Medium | Low–Med |
| L1 | Library-API lifecycle leaks (fatal=exit, session-lock deadlock, re-init leak) | Resource/lifecycle | High | High | Medium |
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
   state it would have to unwind.
5. **E3**, **E6**, **E7** — structural decomposition, largely unlocked by the above.

> Note: several findings (S1–S4, S5, S6, S9) trace to file/CLI-derived values
> used as lengths or indices without validation. A small set of shared
> "validate-on-load" helpers for the binary parsers would address several at
> once and prevent recurrence.
