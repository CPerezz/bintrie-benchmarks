# Upstream-port notes: fixes that made flat-state benchmarking work

This document enumerates the fixes that were required to get end-to-end flat-state benchmarks running with `state-actor`-generated databases on a `bintrie-flat-state` geth fork. It's intended for whoever ports flat state to upstream geth — for each fix, it describes what was broken, where the fix was applied, and what the cleanest upstream change would look like (so external DB-builders no longer need to know these details).

There are **two distinct classes** of fixes. Class 1 is on the **state-actor side** (or, more broadly, "any tool that writes a geth-shaped DB from outside"). Class 2 is a runtime workaround (`fix_snap`) for what *appears* to be a geth-side issue under `--cache 0` — but as documented in §Class 2 below, the actual root cause is **not yet pinned down** and the obvious-looking fix doesn't match the evidence.

---

## Class 1 — State-actor metadata fixes

Three writes that any external DB-builder must perform for a bintrie+pathdb geth to recognize the DB as initialized. All three were applied in `state-actor/genesis/genesis.go` (lines 257–276) and `state-actor/generator/writer_geth.go` (lines 107–129).

### Fix A — `WriteDatabaseVersion(9)`

**Symptom:** geth `--dev` opens the state-actor DB, sees no `DatabaseVersion` key, treats the DB as uninitialized, **silently creates a fresh dev genesis on top**, and ignores all the trie nodes / stem blobs that state-actor wrote.

**Root cause:** geth's startup uses `rawdb.ReadDatabaseVersion(db)` to gate its "is this a populated chain?" check. PR#19's state-actor never called `WriteDatabaseVersion`, so the read returned nil.

**State-actor fix** (`state-actor/genesis/genesis.go:257`):
```go
rawdb.WriteDatabaseVersion(batch, 9)  // 9 == current pathdb schema
```

**Upstream-port option:**
- *Tolerant geth:* if `DatabaseVersion` is absent **but** `HeadBlockHash + ChainConfig + GenesisStateSpec` are all present, infer the DB is valid and don't reset to a fresh genesis. The check is in `core/genesis.go` (look at `Genesis.Commit` / `MustCommit`). Currently it conflates "blank DB" with "valid DB written by another tool."
- *Or:* document the requirement explicitly in `core/rawdb/README.md` so external writers know to call `WriteDatabaseVersion` themselves.

The hard-coded `9` is the version constant from `triedb/pathdb`. Exporting this as `pathdb.SchemaVersion` would let external tools track it.

### Fix B — `"v"` prefix on PathDB metadata writes

**Symptom:** state-actor wrote `WriteSnapshotRoot(batch, root)`, `WriteStateID(...)`, `WritePersistentStateID(...)` — but geth's pathdb couldn't find them on startup, treated PathDB as uninitialized, and triggered regeneration.

**Root cause:** in bintrie mode, pathdb wraps its diskdb at construction time (`triedb/pathdb/database.go:168-170`):
```go
if isVerkle {
    db.diskdb = rawdb.NewTable(diskdb, string(rawdb.VerklePrefix))
    // ...
}
```
So every `rawdb.Read*` and `rawdb.Write*` call inside pathdb transparently prepends the `"v"` byte to keys. External writers don't see this wrapping; they write to the raw key, and pathdb later reads from the prefixed key — they miss each other entirely.

**State-actor fix** (`genesis.go:265-272` and `writer_geth.go:113-120`) — wrap the writer:
```go
type prefixWriter struct {
    prefix []byte
    w      ethdb.KeyValueWriter
}
func (pw *prefixWriter) Put(key, value []byte) error {
    return pw.w.Put(append(pw.prefix, key...), value)
}

var metadataWriter ethdb.KeyValueWriter = batch
if binaryTrie {
    metadataWriter = &prefixWriter{prefix: []byte("v"), w: batch}
}
rawdb.WriteStateID(metadataWriter, stateRoot, 0)
rawdb.WritePersistentStateID(metadataWriter, 0)
rawdb.WriteSnapshotRoot(metadataWriter, stateRoot)
```

**Upstream-port option (recommended):** export a public helper from `core/rawdb`:
```go
// NewVerkleAwareWriter returns a writer that prepends the verkle prefix
// when isVerkle is true, matching pathdb's diskdb wrapping.
func NewVerkleAwareWriter(w ethdb.KeyValueWriter, isVerkle bool) ethdb.KeyValueWriter {
    if !isVerkle {
        return w
    }
    return &prefixWriter{prefix: VerklePrefix, w: w}
}
```
External writers then just do `metadataWriter := rawdb.NewVerkleAwareWriter(batch, isBintrie)` without needing to know about the prefix scheme. This was clearly the original intent — pathdb's internal wrapping at `database.go:170` already does this — but the helper isn't exposed.

Even better: have `rawdb.WriteSnapshotRoot` etc. take an `isVerkle bool` parameter and apply the prefix internally. That way external callers can't forget.

### Fix C — `IsBintrie: true` in `SnapshotGenerator` RLP

**Symptom:** state-actor wrote a `journalGenerator{Done: true, Marker: nil}` (no `IsBintrie` set, so it defaulted to `false`). On geth startup, `loadGenerator` discarded it as "for a different scheme" and triggered full regeneration.

**Root cause:** at `triedb/pathdb/journal.go:163-171`:
```go
// Scheme mismatch — drop the journal and force a full regeneration.
// IsBintrie defaults to false on legacy v3 entries (the field is
// rlp:"optional"), which is exactly the right answer for a merkle
// database opened against an old journal.
if generator.IsBintrie != isBintrie {
    log.Info("State snapshot generator is for a different scheme, discarding",
        "journalIsBintrie", generator.IsBintrie, "dbIsBintrie", isBintrie)
    return nil, trieRoot, nil
}
```

**State-actor fix** (`genesis.go:295-329`) — mirror the unexported geth struct and set `IsBintrie: true`:
```go
type snapshotGenerator struct {
    Wiping    bool   // deprecated, kept for backward compatibility
    Done      bool
    Marker    []byte
    Accounts  uint64
    Slots     uint64
    Storage   uint64
    IsBintrie bool   `rlp:"optional"`
}

func WriteCompletedSnapshotGenerator(w ethdb.KeyValueWriter, isBintrie bool) error {
    blob, _ := rlp.EncodeToBytes(snapshotGenerator{Done: true, IsBintrie: isBintrie})
    rawdb.WriteSnapshotGenerator(w, blob)
    return nil
}
```

**Upstream-port options:**
- *Easy:* export the `journalGenerator` struct as `pathdb.JournalGenerator` (or similar). External writers then don't need to redefine the wire format. Currently every external tool re-mirrors the RLP shape — a fragile pattern that breaks as soon as a field is added.
- *Better:* expose `pathdb.WriteCompletedGenerator(w ethdb.KeyValueWriter, isBintrie bool) error` as a standalone helper that handles the encoding internally. Pair with the prefix-wrapping helper from Fix B for a clean external API.

---

## Class 2 — `--cache 0` snapshot consistency: workaround in place, root cause not yet diagnosed

`fix_snap` makes flat-state benchmarks runnable under `--cache 0` by resetting `SnapshotRoot` and `SnapshotGenerator` before every geth restart. **The workaround is empirically correct** (without it, every restart triggers a 24h+ snapshot regeneration; with it, geth opens cleanly and benchmarks proceed). But the underlying mechanism is **not yet pinned down**, and the obvious-looking diagnosis doesn't match the evidence.

### What `fix_snap` does (`tools/fix_snap/main.go`, ~80 lines)

```go
gen := snapshotGenerator{Done: true, IsBintrie: true}
blob, _ := rlp.EncodeToBytes(gen)
pw := &prefixWriter{prefix: []byte("v"), db: db}

rawdb.WriteSnapshotGenerator(pw, blob)            // reset generator marker
rawdb.WriteSnapshotRoot(pw, root)                 // reset SnapshotRoot to the supplied root
db.Put([]byte("SnapshotRoot"), root[:])           // also write unprefixed (defensive)
```
Run before every cold-cache geth start, with `root` set to the state-actor-emitted genesis state root. Result: geth opens, `loadGenerator` sees a matching `SnapshotRoot` and a `Done=true, IsBintrie=true` generator, and skips regeneration.

### Initial diagnosis (rejected — does not fit the evidence)

The intuitive theory was: under `--cache 0`, pathdb's `dirtyBuffer` size is also zero, so diff layers never get capped to disk. The disk layer's root stays at the genesis state root; meanwhile, the in-memory layer-tree HEAD advances with each block. On graceful shutdown, geth persists *HEAD* root as `SnapshotRoot`. On next startup, `loadGenerator` sees `trieRoot = genesis ≠ SnapshotRoot = HEAD`, declares inconsistency, and triggers regeneration.

**Why this diagnosis is probably wrong:** if shutdown were really persisting HEAD-root as `SnapshotRoot`, the bug would manifest under `--cache > 0` as well (at any cap-size where HEAD still moves between flushes — i.e., essentially always). The `--cache 0`-specificity is the signal that the mechanism is something else. The deployment phase (`--cache 4096`) does many cycles of restart-without-fix_snap and never trips this; only the cold-cache benchmark phase does.

The actual mechanism is more likely an interaction between **bintrie generator initialization** and the **pre-existing on-disk state shaped by external tooling** (state-actor's writes from Class 1) that only surfaces when `--cache 0` defeats some intermediate caching/buffering layer that would otherwise mask it. Pinning this down requires tracing what `loadGenerator` actually reads on the second startup vs the first, and what state-actor's initial writes vs geth's first-run writes leave in the DB.

### Proposed minimal upstream fix (recommended path, *if* diagnosis confirms)

Rather than the structural rework suggested in earlier drafts of this doc (renaming consistency checks, journal-bridgeable replay, etc.), the more defensible upstream change appears to be a **self-healing write at the start of `Journal()`** plus a **louder failure at the loadGenerator entry point**:

```go
// In triedb/pathdb/database.go Journal():
//   Before journaling, anchor SnapshotRoot to the actual disk-layer root.
//   Prevents drift between SnapshotRoot and trieRoot from accumulating
//   across runs, regardless of whether diff-layer capping has occurred.
rawdb.WriteSnapshotRoot(db.diskdb, db.tree.bottom().rootHash())
```

```go
// In triedb/pathdb/journal.go loadGenerator(), at the existing
// "State snapshot generator is not found" log site (~line 154):
//   Promote from log.Info to log.Warn (or log.Error with explicit
//   user-facing message) so the failure mode is immediately visible
//   instead of disappearing into a silent 24h regeneration.
log.Warn("State snapshot generator is not found; will regenerate (this is expensive — minutes to hours on large DBs)")
```

Both changes are small and defensible:
- The `Journal()` self-healing write makes shutdown idempotent w.r.t. `SnapshotRoot`/disk-layer-root drift, which is a useful invariant regardless of whether it strictly fixes the `--cache 0` case.
- Promoting the loadGenerator log severity surfaces a regen trigger that today is buried at info level and easy to miss in a verbose geth log stream — orthogonal to the actual bug, but valuable.

### Earlier proposals (do **not** port)

The following options were proposed in an earlier draft of this document. **None should be ported as-is**: they all assume the rejected "HEAD-root persistence" diagnosis, and the cures introduce semantic changes that would need their own justification.

1. ~~"Don't persist HEAD root as `SnapshotRoot` when no diff-layer capping has occurred. On shutdown, write `SnapshotRoot = disk_layer_root` instead."~~ — The general idea (anchor `SnapshotRoot` to disk-layer root) is preserved in the minimal fix above as a self-healing write at the start of `Journal()`, but framing it as "don't persist HEAD" misdescribes the current behavior.
2. ~~"Make the startup consistency check tolerant of 'journal-bridgeable' mismatch — replay the journal from `trieRoot` and validate that it lands on `SnapshotRoot` before triggering regeneration."~~ — Adds substantial new replay logic to a hot startup path; would need its own justification independent of the `--cache 0` issue.
3. ~~"Refuse to start with `--cache 0` and a non-genesis `SnapshotRoot`."~~ — Treats a symptom as a contract; reasonable as a temporary loud-fail guard, but not as a permanent fix.

### What needs to happen before any upstream patch

1. **Reproduce the failure in a controlled test** that varies *only* `--cache` between two restart cycles (with state-actor as the DB seed in both cases), and confirm the regen trigger is `--cache 0`-specific. The current evidence is operational (the benchmark protocol works with `fix_snap`, doesn't without) but doesn't isolate the cause to a specific code path.
2. **Trace `loadGenerator` reads vs writes** across the second startup. Specifically: which key returns what value on the broken vs working paths? `rawdb.ReadAccountTrieNode(db, nil)`, `rawdb.ReadSnapshotGenerator(db)`, `rawdb.ReadSnapshotRoot(db)` — log the bytes returned for each.
3. **If the diagnosis confirms the proposed minimal fix**, the patch is ~5 lines across two files in the geth fork.
4. **If the diagnosis points elsewhere** (e.g., a bintrie-generator init path that races state-actor's pre-existing on-disk state), the fix may differ entirely from anything proposed in this document. Diagnose first, port second.

---

## Summary

| # | Class | Fix today | Where | Upstream-port opportunity |
|:--|:------|:----------|:------|:--------------------------|
| A | State-actor | Call `WriteDatabaseVersion(9)` after genesis | `state-actor/genesis/genesis.go:257` | Tolerate missing version when other genesis keys are present; export `pathdb.SchemaVersion` |
| B | State-actor | Wrap metadata writer with `"v"` prefix | `state-actor/genesis/genesis.go:265-272` | Export `rawdb.NewVerkleAwareWriter(w, isVerkle)`; or have verkle-aware `Write*` functions take the flag |
| C | State-actor | Write `SnapshotGenerator{Done:true, IsBintrie:true}` mirroring unexported pathdb struct | `state-actor/genesis/genesis.go:295-329` | Export `pathdb.JournalGenerator` + `WriteCompletedGenerator(w, isBintrie)` helper |
| D | Geth (root cause not pinned down) | Run `fix_snap` to reset `SnapshotRoot`+`SnapshotGenerator` before every restart | `tools/fix_snap/main.go` | Diagnose first. Likely path: self-healing `WriteSnapshotRoot(db.diskdb, db.tree.bottom().rootHash())` at start of `Journal()` + louder log at `journal.go:154`. **Do not** port the earlier "don't persist HEAD" / "journal-bridgeable replay" proposals as-is. |

**Class 1** fixes are clearly correct and the upstream changes are mechanical (export a few helpers, document the contract).

**Class 2** has a working operational fix (`fix_snap`) but the underlying mechanism deserves diagnosis before an upstream patch lands — the obvious-looking explanation doesn't account for the `--cache 0`-specificity and would invite a fix that misses the real bug.
