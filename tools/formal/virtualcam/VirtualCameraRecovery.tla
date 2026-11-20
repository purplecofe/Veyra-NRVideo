----------------------------- MODULE VirtualCameraRecovery -----------------------------
(* Liveness model of the same code as VirtualCameraQueue.tla, with pictures reduced to
   "the queue has a frame of session g". Question: after the producer must replace its
   queue (UI stop/start, new session, frame-rate change, resize), does every running
   camera consumer get the new session's pictures? Frames always keep arriving at the
   worker; a stop/start counts as one session change. The coverage table in
   .claude/skills/verify-virtualcam-queue/SKILL.md maps actions to lines. *)
EXTENDS Naturals

CONSTANTS Readers,    \* camera consumers
          Steady,     \* consumers assumed to stay running in the end; Recovery is about them
          Parked,     \* consumers assumed to stay paused in the end
          MaxChanges  \* session changes in one behavior

ASSUME Steady \subseteq Readers /\ Parked \subseteq Readers /\ Steady \cap Parked = {}

VARIABLES epoch, changes,
          qOpen, exists, mapGen, hstate, hasFrame,
          rstatus, rpc, holds, prev, seen

vars == <<epoch, changes, qOpen, exists, mapGen, hstate, hasFrame, rstatus, rpc, holds, prev, seen>>

TypeOK ==
    /\ epoch \in 1..(MaxChanges + 1) /\ changes \in 0..MaxChanges
    /\ qOpen \in BOOLEAN /\ exists \in BOOLEAN /\ mapGen \in 0..(MaxChanges + 1)
    /\ hstate \in {"none", "starting", "ready", "stopping"} /\ hasFrame \in BOOLEAN
    /\ rstatus \in [Readers -> {"running", "paused", "stopped"}]
    /\ rpc \in [Readers -> {"idle", "check", "peek"}]
    /\ holds \in [Readers -> BOOLEAN]
    /\ prev \in [Readers -> {"invalid", "none", "starting", "ready", "stopping"}]
    /\ seen \in [Readers -> 0..(MaxChanges + 1)]

Init ==
    /\ epoch = 1 /\ changes = 0
    /\ qOpen = FALSE /\ exists = FALSE /\ mapGen = 0 /\ hstate = "none" /\ hasFrame = FALSE
    /\ rstatus = [r \in Readers |-> "running"] /\ rpc = [r \in Readers |-> "idle"]
    /\ holds = [r \in Readers |-> FALSE] /\ prev = [r \in Readers |-> "invalid"]
    /\ seen = [r \in Readers |-> 0]

readerVars == <<rstatus, rpc, holds, prev, seen>>

(* ---------------- Producer: worker thread State::run (VirtualCamera.cpp:199-275) ---------------- *)

\* 205-206 (and 230-232 on a resize): video_queue_close (shared-memory-queue.c:90-99)
ProducerClose ==
    /\ qOpen /\ mapGen # epoch
    /\ qOpen' = FALSE /\ hstate' = "stopping"
    /\ exists' = \E r \in Readers : holds[r]
    /\ UNCHANGED <<epoch, changes, mapGen, hasFrame, readerVars>>

\* 233-243: video_queue_create (shared-memory-queue.c:101-123) succeeds only when no
\* reader still holds the old mapping (115); otherwise the frame is dropped (260).
ProducerCreate ==
    /\ ~qOpen /\ ~exists
    /\ qOpen' = TRUE /\ exists' = TRUE /\ mapGen' = epoch
    /\ hstate' = "starting" /\ hasFrame' = FALSE
    /\ UNCHANGED <<epoch, changes, readerVars>>

\* 253: video_queue_write (shared-memory-queue.c:155-173)
ProducerWrite ==
    /\ qOpen /\ mapGen = epoch
    /\ hstate' = "ready" /\ hasFrame' = TRUE
    /\ UNCHANGED <<epoch, changes, qOpen, exists, mapGen, readerVars>>

(* ---------------- Consumers: VCamFilter (virtualcam-filter.cpp) ---------------- *)

AliveWithout(r) == qOpen \/ \E o \in Readers \ {r} : holds[o]

\* Refresh (292-296): video_queue_open
ReaderOpen(r) ==
    /\ rstatus[r] = "running" /\ rpc[r] = "idle" /\ ~holds[r] /\ exists
    /\ holds' = [holds EXCEPT ![r] = TRUE]
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ rpc' = [rpc EXCEPT ![r] = "check"]
    /\ UNCHANGED <<epoch, changes, qOpen, exists, mapGen, hstate, hasFrame, rstatus, seen>>

\* Refresh (298-311): a changed state; STOPPING closes (304-308). Pace goes on only when READY.
ReaderCheck(r) ==
    /\ \/ rpc[r] = "check"
       \/ rpc[r] = "idle" /\ rstatus[r] = "running" /\ holds[r]
    /\ IF hstate = "stopping" /\ prev[r] # "stopping"
         THEN /\ holds' = [holds EXCEPT ![r] = FALSE]
              /\ exists' = AliveWithout(r)
              /\ rpc' = [rpc EXCEPT ![r] = "idle"]
         ELSE /\ rpc' = [rpc EXCEPT ![r] = IF hstate = "ready" THEN "peek" ELSE "idle"]
              /\ UNCHANGED <<holds, exists>>
    /\ prev' = [prev EXCEPT ![r] = hstate]
    /\ UNCHANGED <<epoch, changes, qOpen, mapGen, hstate, hasFrame, rstatus, seen>>

\* Pace's peek and Deliver (418-439, 537-549): a frame of the mapping it holds
ReaderDeliver(r) ==
    /\ rpc[r] = "peek"
    /\ IF holds[r] /\ hstate = "ready" /\ hasFrame
         THEN seen' = [seen EXCEPT ![r] = mapGen]
         ELSE UNCHANGED seen
    /\ rpc' = [rpc EXCEPT ![r] = "idle"]
    /\ UNCHANGED <<epoch, changes, qOpen, exists, mapGen, hstate, hasFrame, rstatus, holds, prev>>

\* Run (153-164)
ReaderRun(r) ==
    /\ rstatus[r] # "running"
    /\ rstatus' = [rstatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<epoch, changes, qOpen, exists, mapGen, hstate, hasFrame, rpc, holds, prev, seen>>

\* Pause (124-143): no new Pace (240-259)
ReaderPause(r) ==
    /\ rstatus[r] # "paused"
    /\ rstatus' = [rstatus EXCEPT ![r] = "paused"]
    /\ UNCHANGED <<epoch, changes, qOpen, exists, mapGen, hstate, hasFrame, rpc, holds, prev, seen>>

\* Thread (240-259): while paused, every 100 ms under frame_mutex, a queue its producer
\* has closed is let go; a live one stays open.
ReaderPausedRelease(r) ==
    /\ rstatus[r] = "paused" /\ rpc[r] = "idle" /\ holds[r] /\ hstate = "stopping"
    /\ holds' = [holds EXCEPT ![r] = FALSE]
    /\ exists' = AliveWithout(r)
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ UNCHANGED <<epoch, changes, qOpen, mapGen, hstate, hasFrame, rstatus, rpc, seen>>

\* Stop (166-176): takes frame_mutex, closes the queue
ReaderStop(r) ==
    /\ rstatus[r] # "stopped" /\ rpc[r] = "idle"
    /\ rstatus' = [rstatus EXCEPT ![r] = "stopped"]
    /\ holds' = [holds EXCEPT ![r] = FALSE]
    /\ exists' = IF holds[r] THEN AliveWithout(r) ELSE exists
    /\ prev' = [prev EXCEPT ![r] = "invalid"]
    /\ UNCHANGED <<epoch, changes, qOpen, mapGen, hstate, hasFrame, rpc, seen>>

\* stop()/start(), sessionEnded, a new frame-rate cap, or a resize: the queue must be replaced
SessionChange ==
    /\ changes < MaxChanges
    /\ epoch' = epoch + 1 /\ changes' = changes + 1
    /\ UNCHANGED <<qOpen, exists, mapGen, hstate, hasFrame, readerVars>>

Next ==
    \/ ProducerClose \/ ProducerCreate \/ ProducerWrite
    \/ \E r \in Readers : ReaderOpen(r) \/ ReaderCheck(r) \/ ReaderDeliver(r)
    \/ \E r \in Readers : ReaderRun(r) \/ ReaderPause(r) \/ ReaderPausedRelease(r) \/ ReaderStop(r)
    \/ SessionChange

\* The worker retries the create on every new frame, so a free moment that recurs is
\* eventually hit (strong fairness). Running consumers keep pacing; a paused one keeps its
\* 100 ms loop. Run/Pause/Stop are the consumer application's choice and get no fairness.
Fairness ==
    /\ WF_vars(ProducerClose) /\ WF_vars(ProducerWrite) /\ SF_vars(ProducerCreate)
    /\ \A r \in Readers : WF_vars(ReaderOpen(r)) /\ WF_vars(ReaderCheck(r)) /\ WF_vars(ReaderDeliver(r))
                          /\ WF_vars(ReaderPausedRelease(r))

Spec == Init /\ [][Next]_vars /\ Fairness

(* ---------------- Rule ---------------- *)

\* Timing assumption: inside one Pace a running consumer opens a stopped mapping and closes
\* it again (Refresh, microseconds, once per frame), so those windows do not cover all time.
\* Without it, two running consumers whose windows always overlap starve the create. A
\* consumer that keeps the mapping after its check is not in such a window.
InOpenWindow == \E r \in Readers : rstatus[r] = "running" /\ rpc[r] = "check" /\ holds[r] /\ hstate = "stopping"
WindowsLeaveGaps == []<>~InOpenWindow
KeepsRunning == \A r \in Steady : <>[](rstatus[r] = "running")
StaysPaused == \A r \in Parked : <>[](rstatus[r] = "paused")

\* After the queue is replaced, every consumer that keeps running shows the new session.
Recovery == (KeepsRunning /\ StaysPaused /\ WindowsLeaveGaps) => \A r \in Steady : <>[](seen[r] = epoch)
=============================================================================
