# Differences between the two VSEARCH manual systems

VSEARCH ships its manual in **two parallel source systems** that are meant to be
kept in sync (see `CLAUDE.md` → *Documentation*):

1. **`man/vsearch.1`** — the monolithic roff man page. One flat `.SS Options`
   section lists *all* options alphabetically-by-theme; commands appear only in
   the grouped `SYNOPSIS`. This is the autotools source man page.
2. **The per-command markdown system** under `man/` — one page per command
   (`man/commands/vsearch-<command>.1.md`), section-5 format pages
   (`man/formats/`), section-7 topic pages (`man/misc/`), the overview/changelog
   (`man/index.1.md`), and shared option snippets (`man/commands/fragments/`,
   `#(...)`-included into several pages). These build into roff via pandoc.

This document catalogues the **substantive** differences found by a systematic
comparison (option-set diff + per-option value comparison + format/topic-page
coverage + structural-section comparison). Where a value was in doubt it was
checked against the source (`src/cli.cc`, `src/results.cc`) and the authoritative
side is stated. Purely stylistic differences (the markdown is uniformly more
verbose and carries per-command `EXAMPLES` — this is by design) are **not**
listed.

Scope note: as of this review both systems declare **version 2.31.0 (April 29,
2026)**, and the option-set direction is asymmetric — **every roff option also
exists in the markdown; the markdown is a superset.** So all "missing option"
findings below are gaps in the roff.

---

## 0. Priority summary

**Correctness bugs (a documented value is wrong — fix first):**

| # | Where | Bug | Correct value (source-verified) |
|---|-------|-----|------|
| 1 | markdown `fragments/option_wordlength.md` (used by the 4 clustering pages) | states default **12** | **8** (`cli.cc:4242-4248`: only `--orient` = 12) |
| 2 | markdown `derep_fulllength`, `derep_id`, `derep_prefix`, `usearch_global` | include `option_minseqlength_1.md` (default **1**) | **32** (`cli.cc:4512-4524`) |
| 3 | roff `--minseqlength` blanket phrase "…and dereplication" | implies **32** for `derep_smallmem` & `fastx_uniques` | **1** (`cli.cc`: these two are *not* in the 32 list) |
| 4 | roff SAM field 5 (`--samout`) | "mapping quality (ignored, always set to `*`)" | **255** (`results.cc:911,943,987`; markdown is right) |

**Large content gaps in the roff (present in markdown, absent in roff):**

- Two whole commands: **`--chimeras_denovo`** and **`--fastx_syncpairs`** (§1).
- **19 live CLI options** (§2), incl. options for commands the roff *does*
  document.
- Two **binary-format specifications** (SFF, UDB) and the **IUPAC nucleotide
  table** (§4, §5).
- Roff sections **DELIBERATE CHANGES** and **NOVELTIES** have no markdown
  equivalent (§6) — but that is a gap in the *markdown*, the opposite direction.

**Unresolved contradictions (docs disagree, no code clamp — maintainer to pick):**
`--minh` range and `--xn` range (§3).

---

## 1. Commands missing from the roff

Both have full, current markdown command pages but are effectively **undocumented
in `man/vsearch.1`**.

### 1.1 `--chimeras_denovo`
- **roff status:** appears *only* in the VERSION HISTORY / changelog (as
  "undocumented experimental `chimeras_denovo` command"); it is absent from
  `SYNOPSIS`, `DESCRIPTION`, and the `Options` section.
- **What it does:** *de novo* chimera detection (no reference) for long exact
  sequences, using a modified UCHIME that auto-adapts to a wide range of lengths.
- **Synopsis:** `vsearch --chimeras_denovo inputfile (--chimeras | --nonchimeras
  | --alnout | --tabbedout) outputfile [options]`. `--sizein` always implied;
  single-threaded (`--threads` ignored).
- **Options to add:** outputs `--chimeras`, `--nonchimeras`, `--alnout`,
  `--tabbedout` (18-column TSV); core `--abskew` (≥1.0, default **1.0**),
  `--chimeras_diff_pct` (0–50, default **0.0**), `--chimeras_length_min`
  (default **10**), `--chimeras_parents_max` (2–20, default **3**),
  `--chimeras_parts` (2–100, default **seqlen/100**), `--xn` (>1.0, default
  **8.0**); pairwise-alignment `--gapext/--gapopen/--match/--mismatch`; plus the
  usual secondary/relabel options and `--alignwidth` (default **60** here, unlike
  the uchime commands' 80). Note the `--alnout` legend (Ids QA/QB/QC/QT/QModel/Div;
  QModel always 100.00; QC=0.00 with only two parents) is reference material.

### 1.2 `--fastx_syncpairs`
- **roff status:** **0 occurrences** — entirely absent.
- **What it does:** reorders paired-end reads so mates line up positionally in
  the forward and reverse files (reorder only — no join/merge). Reverse file held
  in memory, forward streamed; neither needs to be seekable. Single-threaded.
- **Synopsis:** `vsearch --fastx_syncpairs fastxfile --reverse fastxfile
  (--fastaout | --fastqout) filename [options]`.
- **Options to add:** mandatory `--reverse`; core `--fastaout[_rev]`,
  `--fastqout[_rev]`, and the four **orphan** outputs
  `--fasta/fastqout_orphans[_rev]`; `--read_separators` *string* (chars marking a
  trailing mate marker to strip, default **`/`** → strips `/1`,`/2`); secondary
  decompress/width/log/quiet; ignored quality options (`--fastq_ascii`,
  `--fastq_qmax`, `--fastq_qmin`, `--threads`).

---

## 2. Options missing from the roff (present in markdown)

All 19 were confirmed to be **live options** in `src/cli.cc` (each present in the
`long_options` table), so these are genuine roff omissions, not markdown
inventions. Grouped by owning command:

### 2.1 Options for the two undocumented commands
- **`--chimeras_denovo`:** `--chimeras_diff_pct`, `--chimeras_length_min`,
  `--chimeras_parents_max`, `--chimeras_parts`.
- **`--fastx_syncpairs`:** `--fastaout_orphans`, `--fastaout_orphans_rev`,
  `--fastqout_orphans`, `--fastqout_orphans_rev`, `--read_separators`.

### 2.2 Options for commands the roff DOES document (more serious — these are silent gaps)
| Option | Owning commands (per markdown) | roff mentions |
|--------|-------------------------------|---------------|
| `--band` | allpairs_global, cluster_fast/size/smallmem/unoise, usearch_global | none (0) |
| `--hspw` | allpairs_global, cluster_*, usearch_global | none (0) |
| `--minhsp` | allpairs_global, cluster_*, usearch_global | none (0) |
| `--xdrop_nw` | allpairs_global, cluster_*, usearch_global | none (0) |
| `--slots` | allpairs_global, cluster_*, usearch_global, fastx_subsample | none (0) |
| `--n_mismatch` | search_exact, usearch_global, allpairs_global, cluster_*, uchime_denovo/2/3, uchime_ref, chimeras_denovo | prose only (2 mentions, 0 as an option) |
| `--ee_cutoffs` | fastq_eestats2 | prose only (1 mention, 0 as an option) |
| `--length_cutoffs` | fastq_eestats2 | prose only (1 mention, 0 as an option) |

`--n_mismatch`, `--ee_cutoffs`, `--length_cutoffs` appear in roff *prose/changelog*
but are never defined as options; the rest have no roff presence at all.

---

## 3. Value / default contradictions on shared options

### 3.1 `--wordlength` default — markdown wrong for clustering *(source-verified)*
- The four clustering pages (`cluster_fast`, `cluster_size`, `cluster_smallmem`,
  `cluster_unoise`) `#include` `fragments/option_wordlength.md`, which says the
  default is **12**.
- Actual default is **8** (`cli.cc:4242-4248` sets 12 **only** for `--orient`,
  8 otherwise). The roff agrees (default 8 at line 3312; it correctly documents
  orient's 12 at line 2464).
- **Fix:** the clustering pages should include the correct 8-default fragment
  (`option_wordlength_8.md`); `option_wordlength.md` (12) is right only for
  `--orient`, which shares it.

### 3.2 `--minseqlength` per-command default — errors on BOTH sides *(source-verified)*
Source (`cli.cc:4512-4524`) sets the default to **32** for cluster_fast/size/
smallmem/unoise, derep_fulllength, derep_id, derep_prefix, makeudb_usearch,
sintax, usearch_global; and **1** for everything else (including `derep_smallmem`,
`fastx_uniques`, `search_exact`, `allpairs_global`).
- **markdown too low (says 1, should be 32):** `derep_fulllength`, `derep_id`,
  `derep_prefix`, `usearch_global` — all wrongly include `option_minseqlength_1.md`.
  (`makeudb_usearch` correctly uses the 32 fragment; `sintax` inlines 32.)
- **roff too high (implies 32, should be 1):** the roff phrase "32 nucleotides for
  clustering **and dereplication** as well as …" sweeps in *all* derep commands,
  but `derep_smallmem` and `fastx_uniques` actually default to **1** (markdown is
  correct for those two).
- `search_exact` and `allpairs_global`: markdown default 1 is correct; roff is
  silent (does not name them in the 32 list) — no contradiction.

### 3.3 SAM MAPQ (field 5) — roff wrong *(source-verified)*
- roff (`--samout`): "mapping quality (ignored, always set to `*`)".
- markdown `formats/vsearch-sam.5.md`: MAPQ is always **255**.
- Source emits **255** (`results.cc:911` comment "mapq … (255)"; `results.cc:943,
  987` write `255`). The roff `*` is wrong.

### 3.4 `--minh` accepted range — docs contradict (no code clamp)
- roff: default 0.28, "values ranging from **0.0 to 1.0 included**".
- markdown `fragments/option_minh.md`: default 0.28, "**strictly greater than
  0.0; values above 1.0 are accepted** but uncommon".
- No range check exists in the source (value is parsed and used directly), so
  neither bound is enforced — the two docs simply disagree. Maintainer should
  pick the intended wording. (Materially applies to `uchime_denovo`/`uchime_ref`;
  the option is documented as ignored for uchime2/uchime3.)

### 3.5 `--xn` accepted range — docs contradict (no code clamp)
- roff: argument is a "**strictly positive real number**" (allows 0<x≤1),
  default 8.0.
- markdown `fragments/option_xn.md`: "**real number strictly greater than 1.0**",
  default 8.0.
- Again no source-level clamp; the stated ranges disagree. Reconcile.

*(Everything else compared across ~220 shared options matched: `--abskew` per-command
defaults, `--iddef`, `--maxaccepts`/`--maxrejects`, `--fastq_qmax`/`--fastq_ascii`,
`--strand`, `--match`/`--mismatch`, `--gapopen`/`--gapext`, the `--eetabbedout`/
`--fastq_eestats` column counts, `--ee_cutoffs`/`--length_cutoffs` defaults, etc.)*

---

## 4. Format pages (section 5) vs roff

The roff has **no per-format sections**; format facts are scattered into option
descriptions and the `DESCRIPTION > Input` subsection.

| markdown page | roff coverage | Substantive gap |
|---------------|---------------|-----------------|
| `formats/vsearch-fasta.5.md` | partial | Header-annotation *set* (`size`, `ee`, `length`, `sample`) is not collected as a format description — only `size=` is described (in Input); the others live under their options. |
| `formats/vsearch-fastq.5.md` | partial | phred+33 / phred+64 valid ranges and the default accepted Q range are only piecemeal under options, not stated as a format; same annotation-set gap as fasta. |
| `formats/vsearch-sam.5.md` | partial + **contradiction** | MAPQ `*` vs `255` (§3.3). Roff also omits `@HD/@SQ/@PG` sub-field semantics, the MD5/`UR:file:` detail, the MD:Z encoding, the "no `@RG`/`@CO`" note, SAM version and the worked example. |
| `formats/vsearch-sff.5.md` | **none** | The entire SFF **binary-format spec** is roff-absent (no common/read headers, no `magic_number` 0x2E736666, no big-endian rule, no padding/flowgram/clip fields). Roff mentions SFF only as `--sff_convert` I/O. |
| `formats/vsearch-udb.5.md` | **none** | The entire UDB **binary-format spec** is roff-absent (no magic numbers, no little-endian statement, no k-mer index/header/offset layout). Roff mentions UDB only operationally. |
| `formats/vsearch-cigar.5.md` | partial | Roff shows the M/D/I ops and the `=` shorthand inside output descriptions, but omits the run-length encoding rules, the query-vs-SAM-target viewpoint, the rejection of `X`/`=`/`N`/`S`/`H`/`P` and ill-formed-string errors, and the per-output placeholder table. No dedicated CIGAR section. |

---

## 5. Topic pages (section 7) vs roff

| markdown page | roff coverage | Notes |
|---------------|---------------|-------|
| `misc/vsearch-userfields.7.md` | **in sync** | Same **43 fields**, set-diff = 0 both ways (aln…tstrand). Only minor wording differences; no field or value discrepancy. No action. |
| `misc/vsearch-pairwise_alignment_parameters.7.md` | largely equivalent | Match/mismatch (+2/-4), ambiguous-symbol zero-score, `+` vs `|` alnout rendering, the `--gapopen`/`--gapext` grammar and defaults (`20I/2E`, `2I/1E`), and `--iddef 0..4` all agree. |
| `misc/vsearch-expected_error.7.md` | partial | Roff has the EE concept, the Poisson k=0..5 percentages, and all EE options with matching values, but omits the Q→error-probability→accuracy table (Q10…Q40), the `P_e = 10^(-Q/10)` formula, and the "why EE beats averaging quality" rationale. |
| `misc/vsearch-nucleotides.7.md` | **none (table absent)** | Roff names the IUPAC alphabet string and the ambiguous set but has **no IUPAC symbol table** — no per-symbol meaning column and, notably, **no complement column** (A–T, R–Y, S–S, W–W, K–M, B–V, D–H, N–N). The "`X` not accepted" note and the gap-`-` row are not tabulated. |

---

## 6. Structural / narrative sections

### 6.1 Present in roff, absent from the entire markdown system
- **DELIBERATE CHANGES** — the 12 intentional divergences from usearch
  (blast6out field count, `raw` userfield, added qilo/qihi/tilo/tihi, output_no_hits
  in alignment output, `--cluster_size`, reintroduced `--iddef`, `--topn` for
  sorting, `--sizein` for derep_fulllength/cluster_fast, T=U in dereplication,
  stabilized sorting, DUST on by default). No markdown equivalent.
- **NOVELTIES** — new commands/options beyond usearch 7 (uchime2/3_denovo,
  alignwidth, borderline, fasta_score, cluster_size, cluster_unoise, clusterout_*,
  profile, fasta_width, gz/bz2 decompress, iddef, maxuniquesize, relabel_md5/self/sha1,
  shuffle, fastq_eestats/2, fastq_maxlen, fastq_truncee, fasta/fastqout_discarded,
  rereplicate). No markdown equivalent.
- **DESCRIPTION > Input** — the consolidated general "how vsearch reads input"
  narrative (header/label rules, ASCII validation, `size=` annotation, IUPAC
  handling, fastq offset rules, case/DUST masking, T=U, pipe/stdin-stdout and the
  `--db -` exception, gz/bz2 pipe decompression). In markdown this material is
  dispersed across format/topic/command pages; there is no single equivalent.
- **AUTHORS** — a dedicated section in roff; markdown has only the `index.1.md`
  byline and the names inside COPYRIGHT.

### 6.2 Present in markdown, absent from roff
- Navigation index sections in `index.1.md`: **VSEARCH COMMANDS**, **FILE
  FORMATS**, **REFERENCE PAGES** link tables (the per-page nav model).

### 6.3 Divergent content (both present but disagree)
- **SEE ALSO:** roff lists **swipe** and **swarm** with one-line descriptions and
  no usearch; `index.1.md` lists **swarm, swipe, and usearch** as GitHub links
  (usearch → `github.com/rcedgar/usearch12`) but drops the descriptions. Roff
  omits usearch; markdown omits the descriptions.
- **COPYRIGHT / license URL:** roff uses `https://www.gnu.org/licenses/`;
  `fragments/footer.md` uses `http://www.gnu.org/licenses/` (http). Also roff
  folds third-party credits into COPYRIGHT while markdown splits them into a
  separate `# ACKNOWLEDGMENTS` heading (same items).

### 6.4 Confirmed in sync (no action)
- **VERSION HISTORY / changelog** — both current, both topping out at v2.31.0
  (Apr 29 2026); newest entries match.
- **CITATION** (Rognes et al. 2016, PeerJ 4:e2584), **REPORTING BUGS** (same URLs
  + `torognes@ifi.uio.no`), **AVAILABILITY** — identical.

---

## 7. Minor roff hygiene items noted in passing
- Duplicate `.TAG wordlength` anchor in `vsearch.1` (lines 3299 and 3794).
- roff masking `--output` text contains a typo `--mask_fasta` (the markdown does
  not propagate it).

---

## 8. Suggested reconciliation order

1. **Fix the four wrong values** (§0 table): `option_wordlength.md`→8 for
   clustering; `minseqlength` 32 for derep_fulllength/derep_id/derep_prefix/
   usearch_global; the roff `derep_smallmem`/`fastx_uniques` = 1 wording; SAM
   MAPQ `*`→255 in the roff.
2. **Reconcile the two range contradictions** (§3.4 `--minh`, §3.5 `--xn`) —
   decide the intended wording (no code clamp exists) and align both systems.
3. **Add the two missing commands to the roff** (§1) with their options (§2.1).
4. **Add the 8 missing options for already-documented commands** to the roff
   (§2.2).
5. **Port the roff-only reference content into the markdown** where it belongs:
   DELIBERATE CHANGES / NOVELTIES (e.g. into `index.1.md`), and the AUTHORS
   section; and the roff format/topic gaps the other way (SFF/UDB specs, IUPAC
   complement table, expected-error Q/accuracy table, SAM header sub-fields,
   CIGAR run-length rules) are markdown-only reference material the roff lacks.
6. Housekeeping: unify the GPL URL (§6.3), the SEE ALSO set (§6.3), and the roff
   hygiene items (§7).
