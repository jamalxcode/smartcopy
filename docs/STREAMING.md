# The streaming engine (v13)

From v13, a copy is one continuous pipeline. Earlier versions ran three stages, one after another: list both drives completely, copy in batches, then check. Now listing, copying and checking overlap. Copying starts as soon as the first files are found, and copied files are checked while later ones are still being copied. The v12.3 engine is still there: as a fallback the pipeline uses by itself, and as `--engine batch`.

The general ideas behind fast transfer tools inspired this design: keep every stage busy, start early, bound every queue, and let the slowest stage set the pace. It isn't based on any other product's implementation. rsync still does all the copying, so the destination holds ordinary individual files, never archives or containers.

## The pipeline

```
 source drive                                                            destination drive
 ───────────                                                             ────────────────
 listing ──▶ router ──▶ batch queue ──▶ copiers (pool of K rsyncs) ──▶ check queue ──▶ checkers
 (rsync, source  (awk)     (≤ 4 in memory,     │ fingerprints → journal     (≤ 16)        (rsync,
  only, streams)  │        plus a pipe of a    │ changed items → log                      destination
                  │        few dozen fixed-    ▼                                           only)
                  │        size lines)        folders' contents written                       │
                  ▼                                                                           ▼
          plan (every file), folders & links                              confirmed files → checkpoint
                  │
                  └─▶ sorted in the background as soon as the listing ends
 then:  final pass (folders' dates and permissions, links, hard links)  ─▶  final check (everything not yet confirmed)
```

| Stage | What it does | Runs |
|---|---|---|
| Listing | `rsync --dry-run -ii` from the source into an empty folder in the run's folder on the destination. With nothing to compare against, rsync lists folder by folder and prints each item as it goes. The source is listed once. Extended attributes and ACLs aren't read here. | 1 process |
| Router | Reads the listing once. Every file goes to the plan (name, size, date); folders and links go to a second list; files are cut into batches as they appear. The first batch is 100 files or 32 MB, and sizes double up to 5,000 files or 1 GB, so the first copy starts within moments while later batches stay efficient. | 1 awk process, constant memory |
| Dispatcher | The main loop. It takes batch announcements while the in-memory queue has room, hands batches to free copier slots, hands copied batches to free checker slots, reads each finished batch's output once, and draws the progress line. | the main shell |
| Copiers | One `rsync --files-from` per batch, writing from inside the destination folder. Each reports every file it looked at (`-ii`): copied files with their fingerprint, files already up to date too. | pool of K (1 or 4, tuned automatically on big jobs; `--jobs N`) |
| Checkers | Read back the files a batch just copied, from the destination only, and compare them with the fingerprints taken while copying. Confirmed files go in the checkpoint, so the final check skips them. | pool of 1 |
| Final pass | Folders' dates and permissions, after their contents are written. Links. Hard links (a full pass with `-H` when the listing found any). | after copying |
| Final check | Everything not confirmed yet: files that were already there, batches the checkers didn't get to, and the folders-and-links check over everything. | after the final pass |

## Bounded queues and backpressure

- **Batch queue:** the dispatcher holds at most 4 announced batches in memory. When it's full, it stops reading the router's pipe. The router writes each announcement as one fixed-size 400-byte line, written whole, and the pipe holds only a few dozen. Once that fills, the router blocks, and so does the listing behind it. So the listing never runs far ahead of copying, and memory doesn't grow with the size of the job.
- **Check queue:** at most 16 copied batches wait to be checked. Beyond that, a batch isn't queued. Its files are checked in the final check instead, so slow checking never holds back copying.
- **Lists on disk:** batch lists and the plan are files in the run's folder on the destination: one per queued batch, plus the plan. They're deleted as soon as they've been used.
- **Memory:** a few counters in the router, at most 4 + 16 batch numbers and 16 + 4 process slots in the dispatcher, and one batch at a time when a batch's output is read. Sorting the plan uses sort's capped buffer (256 MB, `SMARTCOPY_SORT_MEM`).

## Dynamic work distribution

Copier and checker slots are pools. Whichever slot finishes first takes the next batch, so a slow batch (one big file) doesn't hold up the others. Each batch is one rsync process, so a "persistent" worker is a slot that's refilled immediately, not a long-lived process. With up to 5,000 files per batch, starting a process costs little. Speed tuning (1 against 4 copies at a time) starts once the listing has found at least 20 GB in 2,000 files.

## Dependencies: folders, links, hard links, details

- **Folders** are created as needed by the copiers (rsync creates the folders above each file). Their dates and permissions are set in the final pass, after everything inside them has been written. Setting them earlier would be undone by later writes.
- **Symbolic links, devices and special files** are listed by the router and created in the final pass.
- **Hard links:** the listing reports the second and later names of a hard-linked file as links (`hf`). These are left out of the batches, and when there are any, the final pass goes through everything with `-H` (with `--no-inc-recursive`, which is reliable with `-H`) and links them.
- **File details** (owners, permissions, extended attributes, ACLs, creation dates) are copied with each file by the copiers, using the same rsync options as before.

## Progress: found so far against final totals

While the listing runs, totals are still growing, so the line says so and shows no percentage or time left:

```
Copying · 1.2 GB of 3.4 GB found so far · 41000 files found · 180 MB/s · STILL LISTING
```

Once the listing ends, the totals are final, and the usual percentage, time left and finish time appear:

```
Copying 56% · 179.2 MB of 318.8 MB · 4521 files left · 187 MB/s · 1400 checked · TIME LEFT: 2 min · FINISHES ≈ 14:05
```

"Done" counts every file the copiers have looked at, copied or already up to date, so a resumed copy shows real progress. "checked" counts copied files already confirmed by reading them back.

## Interruptions, restarts and disconnections

- **Stopped or crashed:** each finished batch's fingerprints are already in the journal on the destination. Batches cut off mid-way are read when the run ends, dropping their last line. Running the same command again lists the source again. rsync skips what's already copied, and the checkpoint lets the final check skip files confirmed while copying, as long as the source file still has the same size and date.
- **A drive unplugged:** before starting each batch, the dispatcher checks that both drives are mounted, and waits if not. Copiers write from inside the destination folder, so an unplugged drive makes their writes fail; they can't land on the Mac's drive. A failed batch makes the final pass go through everything.
- **The listing cut off** (unplugged drive, rsync error, killed): what was copied is kept, and the run continues with the batch engine: a full listing of both drives, copying whatever is still missing, then the final pass and check as usual. If the file list is missing for any reason, a full listing is always made before checking.
- **Independent verification is unchanged:** every file is still confirmed by reading the destination copy and comparing it with a fingerprint of the source (taken while copying, or read from the source in the final check), followed by the folders-and-links check over everything. A note on caching: like the old engine on small jobs, checking straight after copying can read data still in the operating system's memory. On big jobs most of it has long been written out. For a check that reads the drive itself, run `--verify-only` later, after ejecting and reconnecting the drive.

## Privacy

Nothing changes: the pipes between stages are anonymous pipes in memory, and every list, batch, log and temporary file is in the run's folder on the destination drive. The listing only reads the source. The empty folder it lists against is in the run's folder on the destination. There is no network use. The automated tests check all of this for both engines.

## Choosing the engine

- `--engine stream` (default for copies), or `--engine batch` for v12.3's list-then-copy engine. You can also set `SMARTCOPY_ENGINE`.
- `--verify-only` and `--dry-run` use the batch engine's listing (they don't copy).
- On a spinning hard drive, listing and copying at the same time make the drive's head move between the two. Copying starts much sooner, but the total time can be a little longer than with `--engine batch`. If the total time matters more than getting started, use `--engine batch` for hard-drive sources.
