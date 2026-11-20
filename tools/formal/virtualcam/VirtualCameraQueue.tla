------------------------------ MODULE VirtualCameraQueue ------------------------------
(* Safety model of the virtual camera frame path, queue protocol 2.
   Producer: src/engine/VirtualCamera.cpp (render thread record/submitted/discarded,
   worker thread State::run). Queue: third_party/obs_virtualcam/ipc/shared-memory-queue.c
   (one named mapping, FrameMutex). Consumers: third_party/obs_virtualcam/module/
   virtualcam-filter.cpp (VCamFilter Pace/Refresh/Deliver, Run/Pause/Stop).
   Each action is one indivisible step of that code; the coverage table in
   .claude/skills/verify-virtualcam-queue/SKILL.md maps actions to lines. *)
EXTENDS Naturals

CONSTANTS Readers,     \* camera consumers, each a process with a VCamFilter
          EngineSlots, \* readback slots: `count` in VirtualCamera.cpp (4)
          RingSlots,   \* SLOTS in shared-memory-queue.c (6)
          MaxFrames,   \* frames the render thread records in one behavior
          MaxChanges   \* UI stop/start, new sessions and resizes in one behavior

ASSUME EngineSlots >= 1 /\ RingSlots >= 1 /\ MaxFrames >= 1

Slots == 1..EngineSlots
RingIdx == 0..(RingSlots - 1)
Epochs == 0..(MaxChanges + 1)
NoFrame == [s |-> 0, order |-> 0, ep |-> 0, fmt |-> 0]
FreeSlot == [st |-> 0, order |-> 0, ep |-> 0, fmt |-> 0, done |-> FALSE]

VARIABLES
    armed, epoch, format, changes,          \* VirtualCamera::State controls
    slot, pending, nextOrder,               \* render thread and readback slots
    wpc, wgen, wpick,                       \* worker thread (State::run)
    qOpen, qEpoch, qFmt,                    \* the worker's video_queue_t
    exists, mapFmt, hstate, seq, ring,      \* the named mapping and its header
    rstatus, rpc, holds, prev, last, want,  \* each consumer's VCamFilter
    shown, stepBack                         \* what each consumer delivered

control  == <<armed, epoch, format, changes>>
engine   == <<slot, pending, nextOrder>>
worker   == <<wpc, wgen, wpick>>
producer == <<qOpen, qEpoch, qFmt>>
mapping  == <<exists, mapFmt, hstate, seq, ring>>
readers  == <<rstatus, rpc, holds, prev, last, want, shown, stepBack>>
vars == <<control, engine, worker, producer, mapping, readers>>

TypeOK ==
    /\ armed \in BOOLEAN /\ epoch \in Epochs /\ format \in {0, 1} /\ changes \in 0..MaxChanges
    /\ slot \in [Slots -> [st : 0..3, order : 0..MaxFrames, ep : Epochs, fmt : {0, 1}, done : BOOLEAN]]
    /\ pending \in 0..EngineSlots /\ nextOrder \in 0..MaxFrames
    /\ wpc \in {"top", "pick", "recheck", "write"} /\ wgen \in Epochs /\ wpick \in 0..EngineSlots
    /\ qOpen \in BOOLEAN /\ qEpoch \in Epochs /\ qFmt \in {0, 1}
    /\ exists \in BOOLEAN /\ mapFmt \in {0, 1} /\ hstate \in {"none", "starting", "ready", "stopping"}
    /\ seq \in 0..MaxFrames
    /\ ring \in [RingIdx -> [s : 0..MaxFrames, order : 0..MaxFrames, ep : Epochs, fmt : {0, 1}]]
    /\ rstatus \in [Readers -> {"running", "paused", "stopped"}]
    /\ rpc \in [Readers -> {"idle", "check", "peek", "read"}]
    /\ holds \in [Readers -> BOOLEAN]
    /\ prev \in [Readers -> {"invalid", "none", "starting", "ready", "stopping"}]
    /\ last \in [Readers -> 0..MaxFrames] /\ want \in [Readers -> 0..MaxFrames]
    /\ shown \in [Readers -> 0..MaxFrames] /\ stepBack \in [Readers -> BOOLEAN]

Init ==
    /\ armed = TRUE /\ epoch = 1 /\ format = 0 /\ changes = 0
    /\ slot = [i \in Slots |-> FreeSlot] /\ pending = 0 /\ nextOrder = 0
    /\ wpc = "top" /\ wgen = 0 /\ wpick = 0
    /\ qOpen = FALSE /\ qEpoch = 0 /\ qFmt = 0
    /\ exists = FALSE /\ mapFmt = 0 /\ hstate = "none" /\ seq = 0
    /\ ring = [k \in RingIdx |-> NoFrame]
    /\ rstatus = [r \in Readers |-> "running"] /\ rpc = [r \in Readers |-> "idle"]
    /\ holds = [r \in Readers |-> FALSE] /\ prev = [r \in Readers |-> "invalid"]
    /\ last = [r \in Readers |-> 0] /\ want = [r \in Readers |-> 0]
    /\ shown = [r \in Readers |-> 0] /\ stepBack = [r \in Readers |-> FALSE]

(* ---------------- Render thread: VirtualCamera::record/submitted/discarded ---------------- *)

\* record (VirtualCamera.cpp:363-402): one recording at a time (364); a group of an old
\* session or size is replaced only when idle (389-395); the first free slot (396-398).
Record ==
    /\ armed /\ pending = 0 /\ nextOrder < MaxFrames
    /\ \A j \in Slots : slot[j].st # 0 => (slot[j].ep = epoch /\ slot[j].fmt = format)
    /\ \E i \in Slots :
        /\ slot[i].st = 0
        /\ \A j \in Slots : slot[j].st = 0 => i <= j
        /\ slot' = [slot EXCEPT ![i] = [st |-> 1, order |-> nextOrder + 1, ep |-> epoch,
                                        fmt |-> format, done |-> FALSE]]
        /\ pending' = i
    /\ nextOrder' = nextOrder + 1
    /\ UNCHANGED <<control, worker, producer, mapping, readers>>

\* submitted (404-410)
Submit ==
    /\ pending # 0
    /\ slot' = [slot EXCEPT ![pending].st = 2]
    /\ pending' = 0
    /\ UNCHANGED <<control, nextOrder, worker, producer, mapping, readers>>

\* discarded (411-415)
Discard ==
    /\ pending # 0
    /\ slot' = [slot EXCEPT ![pending] = FreeSlot]
    /\ pending' = 0
    /\ UNCHANGED <<control, nextOrder, worker, producer, mapping, readers>>

\* The GPU queue finishes submitted readbacks in submission order (fence values rise).
GpuFinish ==
    /\ \E i \in Slots :
        /\ slot[i].st = 2 /\ ~slot[i].done
        /\ \A j \in Slots : (slot[j].st = 2 /\ ~slot[j].done) => slot[i].order <= slot[j].order
        /\ slot' = [slot EXCEPT ![i].done = TRUE]
    /\ UNCHANGED <<control, pending, nextOrder, worker, producer, mapping, readers>>

(* ---------------- Worker thread: State::run (VirtualCamera.cpp:199-275) ---------------- *)

\* video_queue_close by the producer (shared-memory-queue.c:90-99): STOPPING, then unmap;
\* the mapping lives on while a reader still holds it.
CloseProducer ==
    /\ qOpen' = FALSE /\ hstate' = "stopping"
    /\ exists' = \E r \in Readers : holds[r]

\* Loop top (204-207): the session it serves; a stopped or ended session's queue closes.
WorkerTop ==
    /\ wpc = "top"
    /\ wgen' = epoch
    /\ IF qOpen /\ (~armed \/ epoch # qEpoch)
         THEN CloseProducer
         ELSE UNCHANGED <<qOpen, exists, hstate>>
    /\ wpc' = "pick"
    /\ UNCHANGED <<control, engine, wpick, qEpoch, qFmt, mapFmt, seq, ring, readers>>

Submitted(i) == slot[i].st = 2
\* 214-221: of the submitted slots, the first recorded
Oldest(i) == \A j \in Slots : Submitted(j) => slot[i].order <= slot[j].order
NextSlot(i) == Submitted(i) /\ Oldest(i)
\* 228: published only for the session this loop serves
SameSession(i) == slot[i].ep = wgen
\* shared-memory-queue.c:115: create fails while the old mapping still exists
CreateSucceeds(alive) == ~alive

\* 221: nothing submitted; wait for a wake
WorkerIdle ==
    /\ wpc = "pick" /\ ~\E i \in Slots : Submitted(i)
    /\ wpc' = "top"
    /\ UNCHANGED <<control, engine, wgen, wpick, producer, mapping, readers>>

\* 223-224: its readback has not landed; wait for gpuDone
WorkerWaitGpu ==
    /\ wpc = "pick" /\ \E i \in Slots : NextSlot(i) /\ ~slot[i].done
    /\ wpc' = "top"
    /\ UNCHANGED <<control, engine, wgen, wpick, producer, mapping, readers>>

\* 227-228, 262: landed, but the camera is off or the slot is of another session
WorkerDrop ==
    /\ wpc = "pick"
    /\ \E i \in Slots :
        /\ NextSlot(i) /\ slot[i].done
        /\ ~(armed /\ SameSession(i))
        /\ slot' = [slot EXCEPT ![i] = FreeSlot]
    /\ UNCHANGED <<control, pending, nextOrder, worker, producer, mapping, readers>>

\* 229-243, 260: a queue of the slot's size, reopened on a resize; create fails while a
\* reader holds the old mapping, and the frame is dropped.
WorkerOpen ==
    /\ wpc = "pick"
    /\ \E i \in Slots :
        /\ NextSlot(i) /\ slot[i].done /\ armed /\ SameSession(i)
        /\ LET f == slot[i].fmt
               resize == qOpen /\ qFmt # f
               alive == IF resize THEN \E r \in Readers : holds[r] ELSE exists
           IN IF qOpen /\ ~resize
              THEN /\ slot' = [slot EXCEPT ![i].st = 3] /\ wpick' = i /\ wpc' = "recheck"
                   /\ UNCHANGED <<producer, mapping>>
              ELSE IF CreateSucceeds(alive)
              THEN \* video_queue_create (shared-memory-queue.c:101-123): fresh header, empty ring
                   /\ qOpen' = TRUE /\ qEpoch' = wgen /\ qFmt' = f
                   /\ exists' = TRUE /\ mapFmt' = IF alive THEN mapFmt ELSE f
                   /\ hstate' = "starting" /\ seq' = 0 /\ ring' = [k \in RingIdx |-> NoFrame]
                   /\ slot' = [slot EXCEPT ![i].st = 3] /\ wpick' = i /\ wpc' = "recheck"
              ELSE /\ qOpen' = FALSE
                   /\ hstate' = IF resize THEN "stopping" ELSE hstate
                   /\ exists' = alive
                   /\ slot' = [slot EXCEPT ![i] = FreeSlot]
                   /\ UNCHANGED <<qEpoch, qFmt, mapFmt, seq, ring, wpick, wpc>>
    /\ UNCHANGED <<control, pending, nextOrder, wgen, readers>>

\* 253: after mapping the readback, a UI stop or new session drops the frame (254)
WorkerRecheck ==
    /\ wpc = "recheck"
    /\ IF armed /\ epoch = wgen
         THEN wpc' = "write" /\ UNCHANGED slot
         ELSE wpc' = "pick" /\ slot' = [slot EXCEPT ![wpick] = FreeSlot]
    /\ UNCHANGED <<control, pending, nextOrder, wgen, wpick, producer, mapping, readers>>

\* video_queue_write under FrameMutex (shared-memory-queue.c:155-173), then the slot is free (262)
WorkerWrite ==
    /\ wpc = "write"
    /\ LET k == seq + 1
           i == wpick
       IN /\ seq' = k
          /\ ring' = [ring EXCEPT ![k % RingSlots] =
                        [s |-> k, order |-> slot[i].order, ep |-> slot[i].ep, fmt |-> slot[i].fmt]]
          /\ slot' = [slot EXCEPT ![i] = FreeSlot]
    /\ hstate' = "ready"
    /\ wpc' = "pick"
    /\ UNCHANGED <<control, pending, nextOrder, wgen, wpick, producer, exists, mapFmt, readers>>

(* ---------------- Consumers: VCamFilter (virtualcam-filter.cpp) ---------------- *)

\* The mapping outlives a reader's close while the producer or another reader holds it.
AliveWithout(r) == qOpen \/ \E o \in Readers \ {r} : holds[o]

\* Refresh (292-296): video_queue_open; a new session numbers frames from 1 (ResetPacing)
ReaderOpen(r) ==
    /\ rstatus[r] = "running" /\ rpc[r] = "idle" /\ ~holds[r] /\ exists
    /\ holds' = [holds EXCEPT ![r] = TRUE]
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ last' = [last EXCEPT ![r] = 0]
    /\ rpc' = [rpc EXCEPT ![r] = "check"]
    /\ UNCHANGED <<control, engine, worker, producer, mapping, rstatus, want, shown, stepBack>>

\* Refresh (298-311): a changed state; STOPPING closes. Pace goes on only when READY (402-411).
ReaderCheck(r) ==
    /\ \/ rpc[r] = "check"
       \/ rpc[r] = "idle" /\ rstatus[r] = "running" /\ holds[r]
    /\ IF hstate = "stopping" /\ prev[r] # "stopping"
         THEN /\ holds' = [holds EXCEPT ![r] = FALSE]
              /\ exists' = AliveWithout(r)
              /\ last' = [last EXCEPT ![r] = 0]
              /\ rpc' = [rpc EXCEPT ![r] = "idle"]
         ELSE /\ rpc' = [rpc EXCEPT ![r] = IF hstate = "ready" THEN "peek" ELSE "idle"]
              /\ UNCHANGED <<holds, exists, last>>
    /\ prev' = [prev EXCEPT ![r] = hstate]
    /\ UNCHANGED <<control, engine, worker, producer, mapFmt, hstate, seq, ring,
                   rstatus, want, shown, stepBack>>

\* video_queue_peek under FrameMutex (shared-memory-queue.c:206-221): sequence k still in its slot
Held(k) == k >= 1 /\ ring[k % RingSlots].s = k
Newer(r, k) == k > last[r] /\ Held(k)

\* Pace's peek loop (419-446): the oldest held frame after `last` is skipped (421-424,
\* 430-433), leaves now (434), or waits (427-428); with nothing new, the last picture again.
ReaderPeek(r) ==
    /\ rpc[r] = "peek"
    /\ IF hstate = "ready" /\ \E k \in 1..seq : Newer(r, k)
         THEN LET k == CHOOSE k \in 1..seq : Newer(r, k) /\ \A j \in 1..seq : Newer(r, j) => k <= j
              IN \/ last' = [last EXCEPT ![r] = k] /\ UNCHANGED <<rpc, want>>
                 \/ /\ last' = [last EXCEPT ![r] = k] /\ want' = [want EXCEPT ![r] = k]
                    /\ rpc' = [rpc EXCEPT ![r] = "read"]
                 \/ rpc' = [rpc EXCEPT ![r] = "idle"] /\ UNCHANGED <<last, want>>
         ELSE \/ /\ last[r] > 0 /\ want' = [want EXCEPT ![r] = last[r]]
                 /\ rpc' = [rpc EXCEPT ![r] = "read"] /\ UNCHANGED last
              \/ rpc' = [rpc EXCEPT ![r] = "idle"] /\ UNCHANGED <<last, want>>
    /\ UNCHANGED <<control, engine, worker, producer, mapping, rstatus, holds, prev, shown, stepBack>>

\* copy_out line 193: the slot still holds that sequence
SlotStillHolds(f, k) == f.s = k

\* Deliver (537-549) -> video_queue_read_sequence -> copy_out under FrameMutex
\* (shared-memory-queue.c:185-199); a reused slot gives no sample (543-546).
ReaderRead(r) ==
    /\ rpc[r] = "read"
    /\ LET k == want[r]
           f == ring[k % RingSlots]
       IN IF holds[r] /\ hstate = "ready" /\ SlotStillHolds(f, k)
            THEN /\ stepBack' = [stepBack EXCEPT ![r] = stepBack[r] \/ f.order < shown[r]]
                 /\ shown' = [shown EXCEPT ![r] = f.order]
            ELSE UNCHANGED <<shown, stepBack>>
    /\ want' = [want EXCEPT ![r] = 0]
    /\ rpc' = [rpc EXCEPT ![r] = "idle"]
    /\ UNCHANGED <<control, engine, worker, producer, mapping, rstatus, holds, prev, last>>

\* Run (153-164); Pace starts only while running (396)
ReaderRun(r) ==
    /\ rstatus[r] # "running"
    /\ rstatus' = [rstatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<control, engine, worker, producer, mapping, rpc, holds, prev, last, want, shown, stepBack>>

\* Pause (124-143): no new Pace (240-259)
ReaderPause(r) ==
    /\ rstatus[r] # "paused"
    /\ rstatus' = [rstatus EXCEPT ![r] = "paused"]
    /\ UNCHANGED <<control, engine, worker, producer, mapping, rpc, holds, prev, last, want, shown, stepBack>>

\* Thread (240-259): while paused, every 100 ms under frame_mutex, a queue its producer
\* has closed is let go (ResetPacing); a live one stays open.
ReaderPausedRelease(r) ==
    /\ rstatus[r] = "paused" /\ rpc[r] = "idle" /\ holds[r] /\ hstate = "stopping"
    /\ holds' = [holds EXCEPT ![r] = FALSE]
    /\ exists' = AliveWithout(r)
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ last' = [last EXCEPT ![r] = 0]
    /\ UNCHANGED <<control, engine, worker, producer, mapFmt, hstate, seq, ring, rstatus, rpc, want, shown, stepBack>>

\* Stop (166-176) takes frame_mutex, so never inside a Pace, closes the queue and ends the
\* stream (last_sample_time = -1): the next Run starts a new one.
ReaderStop(r) ==
    /\ rstatus[r] # "stopped" /\ rpc[r] = "idle"
    /\ rstatus' = [rstatus EXCEPT ![r] = "stopped"]
    /\ holds' = [holds EXCEPT ![r] = FALSE]
    /\ exists' = IF holds[r] THEN AliveWithout(r) ELSE exists
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ shown' = [shown EXCEPT ![r] = 0]
    /\ UNCHANGED <<control, engine, worker, producer, mapFmt, hstate, seq, ring, rpc, last, want, stepBack>>

(* ---------------- User and session changes ---------------- *)

\* stop()/start() (290-338): the camera turns off or on; either starts a new session
UiToggle ==
    /\ changes < MaxChanges
    /\ armed' = ~armed /\ epoch' = epoch + 1 /\ changes' = changes + 1
    /\ UNCHANGED <<format, engine, worker, producer, mapping, readers>>

\* sessionEnded (351), or start() with a new frame-rate cap (294)
NewSession ==
    /\ changes < MaxChanges /\ armed
    /\ epoch' = epoch + 1 /\ changes' = changes + 1
    /\ UNCHANGED <<armed, format, engine, worker, producer, mapping, readers>>

\* The processed picture changes size: record builds a new group (389-395)
Resize ==
    /\ changes < MaxChanges
    /\ format' = 1 - format /\ changes' = changes + 1
    /\ UNCHANGED <<armed, epoch, engine, worker, producer, mapping, readers>>

Next ==
    \/ Record \/ Submit \/ Discard \/ GpuFinish
    \/ WorkerTop \/ WorkerIdle \/ WorkerWaitGpu \/ WorkerDrop \/ WorkerOpen
    \/ WorkerRecheck \/ WorkerWrite
    \/ \E r \in Readers : ReaderOpen(r) \/ ReaderCheck(r) \/ ReaderPeek(r) \/ ReaderRead(r)
    \/ \E r \in Readers : ReaderRun(r) \/ ReaderPause(r) \/ ReaderPausedRelease(r) \/ ReaderStop(r)
    \/ UiToggle \/ NewSession \/ Resize

Spec == Init /\ [][Next]_vars

(* ---------------- Rules ---------------- *)

\* Within one stream (Run to Stop), a consumer never shows a picture older than one it
\* already showed. The model has no clock: it lets Pace deliver any held frame, where the
\* code skips a frame while a newer one is due (430-433).
NoStepBack == \A r \in Readers : ~stepBack[r]

\* A session's queue carries only that session's pictures.
OneSessionPerQueue == qOpen => \A k \in RingIdx : ring[k].s # 0 => ring[k].ep = qEpoch

\* The producer writes only into a mapping created at its frame size.
ProducerFits == qOpen => mapFmt = qFmt
=============================================================================
