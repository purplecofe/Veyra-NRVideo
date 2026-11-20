---
name: verify-virtualcam-queue
description: Model-check the virtual camera frame path (Veyra's producer worker, the protocol-2 shared-memory queue, and the camera module's reader) with TLA+/TLC. Use when a change touches src/engine/VirtualCamera.cpp, third_party/obs_virtualcam/ipc/shared-memory-queue.c, or the queue, pacing or Run/Pause/Stop code in third_party/obs_virtualcam/module/virtualcam-filter.cpp, or when a camera consumer shows frames out of order, a picture of an old session, or stays on the placeholder after a resize, source switch, frame-rate change or stop/start.
---

# Verify the virtual camera queue

Unit tests (`tests/unit/VirtualCameraTransportTests.cpp`) drive the queue one call at a time. This check explores every interleaving of the render thread, the worker thread, the GPU and two camera consumers, within the bounds below.

## What it checks

| Rule | In plain words | Harm if broken |
| --- | --- | --- |
| `NoStepBack` (Safety) | Within one stream (Run to Stop), a consumer never shows a picture older than one it already showed. | The camera jumps back in time in a call or recording. |
| `OneSessionPerQueue` (Safety) | A session's queue carries only that session's pictures. | After a source switch or stop/start, the old content appears in the new session. |
| `ProducerFits` (Safety) | The producer writes only into a mapping created at its frame size. | Veyra writes past the shared mapping after a resize and crashes. |
| `Recovery` (AllRunning) | After the producer replaces its queue, every consumer that keeps running shows the new session. | A consumer stays on the placeholder after a resize, source switch, frame-rate change or stop/start. |
| `Recovery` (PausedReader) | The same rule for consumer r1 while consumer r2 stays paused. | One paused app keeps every other app on the placeholder (F1, fixed by #188). |

## Run

From the repo root (Windows: `py -3` instead of `python3`). Needs Java 11 or later.

```sh
python3 tools/formal/virtualcam/check.py --fetch     # first run: downloads tla2tools 1.7.4, checks its SHA-256
python3 tools/formal/virtualcam/check.py             # the three checks, about 35 s on 10 cores
python3 tools/formal/virtualcam/check.py --mutants   # also prove each rule still fails on a broken copy, about 30 s more
```

A line `TLC finished without a violation, then its collision estimate threw; counted as pass` is expected: TLC 1.7.4 often throws `Division by zero` in `reportSuccess`, which it reaches only after a complete search without a violation. The runner counts it as a pass only when the JVM exception log (`jvm-exceptions.log` in the run folder) shows the throw in `reportSuccess`.

The jar goes to `E:/项目/Veyra/deps/tla2tools/1.7.4/` on Windows and `~/.cache/veyra/deps/...` elsewhere (`VEYRA_TLA2TOOLS` overrides). Each run writes its TLC output to `E:/项目/Veyra/tmp/formal-virtualcam/<time>/<check>/tlc.out` (elsewhere `~/.cache/veyra/tmp/...`, `VEYRA_FORMAL_OUT` overrides), never into the repo.

Expected baseline (exit 0):

```
safety                   ok     pass (expected pass)  states=9609407
recovery-all-running     ok     pass (expected pass)  states=2706
recovery-paused-reader   ok     pass (expected pass)  states=2706
```

and with `--mutants`, m1 to m6 each `ok`. A `WARNING covered code changed since sync commit` line means the model may no longer describe the code: review the coverage table first.

## Read a result

Every `DIFFER` line names its `tlc.out`; the same folder holds the `.tla` and `.cfg` that TLC checked, with any patch or mutant applied. Run the pstack `/statechart` skill on that `.tla` and `.cfg`: it gives the shortest path to the broken rule in plain words. Then replay that path against the code, one step per action, using the coverage table:

- **Real bug**: every step is something the cited code can do in that order. Report it as steps in the code's words (which thread or consumer, which function, what it saw). Do not weaken the rule or the model until it passes, and do not change product code unless the user asks.
- **Modeling error**: some step has no counterpart in the code (the model allows a choice, an order or a merged step the code does not). Fix the action to match the cited lines, then rerun with `--mutants`.
- **`error: ...`**: TLC did not finish (parse error, timeout). Not a result.
- **A mutant `DIFFER` or `STALE`**: the check can no longer fail the way it should, so its passes prove nothing. A `STALE` mutant's model text changed: update its `MUTANTS` entry to the new text of the same rule.

`Recovery` is an implication: when its assumptions (`KeepsRunning`, `StaysPaused`, `WindowsLeaveGaps`) never hold in a behavior, it passes there for free. Mutant m5 guards that; rerun `--mutants` after any change to those assumptions.

## F1: a paused consumer blocked the camera for everyone (fixed by #188)

This check found it at `9c0c5352`; #188 (`68d17363`) fixed it in the same way the model confirms. Before #188, with consumers r1 and r2 on the queue:

1. r2's graph goes to Paused. `VCamFilter::Pause` (`virtualcam-filter.cpp:124-143`) clears `active` but keeps `vq` open.
2. Veyra changes session (source switch, frame-rate cap, stop/start, resize). The worker closes its queue: STOPPING (`VirtualCamera.cpp:205-206`, on a resize 230-232).
3. r1 sees STOPPING, closes (`virtualcam-filter.cpp:304-308`), and on every later Pace reopens the old mapping r2 still holds, sees STOPPING and closes again.
4. Every `video_queue_create` fails with `ERROR_ALREADY_EXISTS` (`shared-memory-queue.c:115`); the worker drops each frame (`VirtualCamera.cpp:260`).

r1 stayed on the placeholder until r2 ran, stopped or exited. Since #188 the paused thread lets go of a STOPPING queue every 100 ms (`virtualcam-filter.cpp:240-259`, model `ReaderPausedRelease`). Mutant m6 removes that and must break `recovery-paused-reader` again.

## Coverage

Each action is one indivisible step of the cited code. Two code steps may share one action only when no other thread can see or change shared state between them.

| Code | Model actions | Notes |
| --- | --- | --- |
| `src/engine/VirtualCamera.cpp:363-402` record | Queue `Record` | First free slot; a group of another session or size is replaced only when idle. Grid stamping (`CameraGrid`) and `try_lock` drops are not modeled. |
| `src/engine/VirtualCamera.cpp:404-415` submitted, discarded | Queue `Submit`, `Discard` | |
| `src/engine/VirtualCamera.cpp:223-224` fences | Queue `GpuFinish`, `WorkerWaitGpu` | Readbacks finish in submission order. Device lost (225-226) is not modeled. |
| `src/engine/VirtualCamera.cpp:204-208` loop top | Queue `WorkerTop`; Recovery `ProducerClose` | |
| `src/engine/VirtualCamera.cpp:214-221` pick | Queue `WorkerIdle`, `Oldest`, `NextSlot` | |
| `src/engine/VirtualCamera.cpp:227-228` take, session check | Queue `WorkerDrop`, `SameSession` | |
| `src/engine/VirtualCamera.cpp:229-243` reopen, create | Queue `WorkerOpen`; Recovery `ProducerCreate` | Close then create are one action: between them a reader can open only a mapping that still exists, which fails the create either way. Recovery creates for the current session directly. |
| `src/engine/VirtualCamera.cpp:253-262` recheck, write, free | Queue `WorkerRecheck`, `WorkerWrite`; Recovery `ProducerWrite` | Map/Unmap failures (255-259) are not modeled. |
| `src/engine/VirtualCamera.cpp:290-351` start, stop, sessionEnded | Queue `UiToggle`, `NewSession`, `Resize`; Recovery `SessionChange` | |
| `third_party/obs_virtualcam/ipc/shared-memory-queue.c:90-123` close, create | Queue `CloseProducer`, `CreateSucceeds` | The mapping lives while any handle holds it. |
| `third_party/obs_virtualcam/ipc/shared-memory-queue.c:155-173` write | Queue `WorkerWrite` | One step: all under FrameMutex. The 2 ms lock timeout (157-158) only drops a frame. |
| `third_party/obs_virtualcam/ipc/shared-memory-queue.c:185-221` copy_out, peek | Queue `ReaderPeek`, `ReaderRead`, `Held`, `SlotStillHolds` | Each peek and each copy is one step under FrameMutex. |
| `third_party/obs_virtualcam/module/virtualcam-filter.cpp:124-176` Pause, Run, Stop | `ReaderPause`, `ReaderRun`, `ReaderStop` in both | Stop takes frame_mutex, so it never lands inside a Pace. |
| `third_party/obs_virtualcam/module/virtualcam-filter.cpp:240-259` paused loop | `ReaderPausedRelease` in both | Under frame_mutex, between Paces; every 100 ms (weak fairness). |
| `third_party/obs_virtualcam/module/virtualcam-filter.cpp:281-311` Refresh | `ReaderOpen`, `ReaderCheck` in both | Open and the state check are separate steps. |
| `third_party/obs_virtualcam/module/virtualcam-filter.cpp:391-448` Pace | Queue `ReaderPeek`; Recovery `ReaderDeliver` | No clock: a due frame may be skipped, delivered or waited on in any order. |
| `third_party/obs_virtualcam/module/virtualcam-filter.cpp:537-549` Deliver | Queue `ReaderRead`; Recovery `ReaderDeliver` | |

Sync commit: `b0ba6e86fa12fea56aa90dce69acb1667965acb8`

Move the sync commit forward only after you have confirmed, line by line against the table, that the model describes the code at the new commit, and the checks and mutants give the expected results there. Update the line numbers in the same edit.

## When the code changes on purpose

1. Find the changed lines in the coverage table, then the actions that cite them.
2. Change those actions to match the new code. Keep one action per indivisible code step. Cite the new lines in the comment above the action.
3. A new rule gets a plain-sentence comment and a mutant in `MUTANTS` that mirrors a real code mistake and must break it.
4. Run `check.py --mutants`. Update the coverage table, F1 and the sync commit.

## Bounds and what this does not cover

- Safety: 2 consumers, 2 readback slots (code: 4), a 2-frame ring (code: 6), 3 frames, 2 session or size changes. The ring is smaller than the frame count, so a consumer can find its slot reused. Recovery: 2 consumers, 1 session change. A pass covers these bounds only.
- Recovery assumes the worker keeps receiving frames and retries the create on each one, and that running consumers' open-to-close windows (microseconds per frame) do not cover all time. Without that, two running consumers could keep a stopped mapping alive forever; on real timing that is not expected.
- No clock: frame pacing, `Adapt`, `Align`, `CameraGrid`, repeats and skips are free choices. The rules hold for any timing; the rhythm is not checked.
- Across a consumer Stop then Run, the reader starts again from the oldest held frame, and the model may then show an older frame than before the stop. The code's due and behind logic (427-433) usually skips ahead; this is not checked.
- Not modeled: crashes of either side, the abandoned-mutex path and `dirty`, the 2 s heartbeat and owner-process checks, consumer-interval slots (`video_queue_set_consumer`, `video_queue_consumer_interval`), the producer ownership mutex, protocol-1 modules, registration, D3D12 states and pixel contents.
- One frame can still be written after `stop()` or `sessionEnded` returns (recheck at `VirtualCamera.cpp:253`, then the write). It lands only in the old session's queue, which closes next; `OneSessionPerQueue` checks that it never reaches a new one.
