# Transaction and Recovery Semantics

## Purpose and Scope

This document describes the transaction and recovery model used in the **ABAP Cloud Database Acquisition Lab**.

The previous document, `01-delta-semantics.md`, focuses primarily on the semantics of:

```text
numeric delta
timestamp delta
safety intervals
delete handling
transactional change-log delta
```

This document focuses on a different question:

```text
How does the system remain consistent
when processing is interrupted,
a database operation fails,
or multiple sessions execute concurrently?
```

The central topics are therefore:

```text
database LUW boundaries
COMMIT and ROLLBACK
producer atomicity
consumer atomicity
restart behavior
replay
locking
concurrent producer ordering
failure recovery
```

The purpose is not to describe ABAP transaction syntax in general.

Instead, the document explains the transaction boundaries that make the laboratory's acquisition strategies reliable.

---

## Core Reliability Principle

The project separates two independent transaction domains:

```text
Producer transaction
```

and:

```text
Consumer transaction
```

They solve different problems.

The producer transaction ensures that a business change and its corresponding change-log event cannot become inconsistent.

The consumer transaction ensures that acquired data and the consumer delta pointer cannot become inconsistent.

Conceptually:

```text
Producer:

business change
+
event-sequence state
+
change-log event
        |
        v
     COMMIT
```

and later:

```text
Consumer:

acquisition persistence
+
consumer delta pointer
        |
        v
     COMMIT
```

The two transactions are independent.

The producer does not wait for the consumer.

The consumer processes only source changes that have already been committed by the producer.

---

## Why Transaction Boundaries Matter

A delta algorithm can be logically correct and still lose data if transaction boundaries are wrong.

For example, a consumer might correctly select:

```text
EVENT_SEQ > LAST_SEQ
```

but still lose events if it commits:

```text
LAST_SEQ
```

before the corresponding acquisition data is persisted.

Similarly, a producer may correctly allocate:

```text
EVENT_SEQ
```

but still corrupt the event stream if the business update commits while the change-log insert fails.

Therefore reliability depends on two dimensions:

```text
selection semantics
```

and:

```text
transaction semantics
```

Both must be correct.

---

## Producer Atomicity

The transactional change-log producer modifies three related pieces of persistent state:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

For one business operation, the producer performs:

```text
1. Allocate the next EVENT_SEQ

2. Advance the producer event counter

3. Apply the business change

4. Insert the corresponding change-log event
```

These operations belong to one database LUW.

The valid outcomes are:

```text
all changes commit
```

or:

```text
all changes roll back
```

Partial durable states are invalid.

---

## Invalid Producer States

For example, the following state must never be committed:

```text
event counter advanced
business row updated
change-log event missing
```

because the business change would not be visible to the change-log consumer.

Likewise, this state is invalid:

```text
event counter advanced
change-log event exists
business change rolled back
```

because the event stream would describe a business operation that never became committed source state.

The producer transaction exists to prevent these partial outcomes.

---

## Consumer Atomicity

The consumer also modifies two related pieces of state:

```text
ZDB_ACQ_PRICE
ZDB_DELTA_STATE
```

A successful acquisition performs:

```text
1. Persist acquired rows

2. Advance the consumer pointer

3. COMMIT both together
```

The consumer pointer represents acknowledged processing progress.

It must therefore never move ahead of durable acquisition persistence.

---

## Invalid Consumer State

The dangerous state is:

```text
LAST_SEQ = 1006
```

while events:

```text
1005
1006
```

were never durably persisted.

The next request would use:

```text
EVENT_SEQ > 1006
```

and the missing events would no longer be selected.

Therefore:

```text
pointer advancement
```

must never be committed independently before:

```text
acquisition persistence
```

---

## COMMIT as a Reliability Boundary

Within the project, `COMMIT` has a precise semantic meaning.

For the producer:

```text
COMMIT
```

means:

```text
the business change and its event
are now part of the durable source state
```

For the consumer:

```text
COMMIT
```

means:

```text
the acquired data is durable
and the corresponding source boundary
has been acknowledged
```

Before that point, processing must remain recoverable through rollback or replay.

---

## ROLLBACK as State Restoration

`ROLLBACK` is not merely error handling.

It restores the consistency invariant of the current LUW.

For the producer:

```text
ROLLBACK
```

must restore:

```text
producer event counter
business state
change-log state
```

to their previous committed values.

For the consumer:

```text
ROLLBACK
```

must ensure that:

```text
partial acquisition persistence
```

and:

```text
partial pointer advancement
```

do not become durable.

The next attempt can then restart from the previous committed boundary.

---

## Restart and Replay

The project deliberately treats replay as a normal recovery mechanism.

If a consumer fails before commit:

```text
LAST_SEQ remains unchanged
```

Therefore the same events remain eligible:

```text
EVENT_SEQ > LAST_SEQ
```

and can be selected again.

This means that a failed consumer attempt does not need to determine exactly how far it progressed internally.

The database transaction defines the recovery boundary.

---

## Concurrency and Ordering

Transaction atomicity alone is not sufficient for the change-log producer.

Concurrent producers introduce another problem.

Two sessions could otherwise allocate:

```text
1002
1003
```

and commit them in the opposite order.

The project therefore also uses:

```text
EZDBEVCOUNT
```

to serialize event-sequence allocation and publication.

The lock protects ordering between producer transactions.

The database LUW protects consistency inside one producer transaction.

These are separate guarantees.

---

## Locking vs Transaction Atomicity

The distinction can be summarized as:

```text
Lock
-> controls interaction between concurrent producers
```

while:

```text
COMMIT / ROLLBACK
-> controls atomic durability within one producer
```

The lock prevents:

```text
1003 becoming visible
while 1002 is still unresolved
```

The transaction prevents:

```text
business state changing
without its event
```

Both are required for the laboratory change-log design.

---

## Recovery Layers

The project therefore contains several different recovery mechanisms.

```text
Producer SQL failure
-> ROLLBACK producer LUW

Producer concurrency conflict
-> reject or retry producer after lock release

Consumer interruption before COMMIT
-> rollback consumer LUW
-> replay same events

Consumer restart
-> continue from last committed LAST_SEQ

Explicit reinitialization
-> intentionally reset pointer
-> replay earlier events
```

These scenarios should not be treated as the same type of recovery.

Each operates at a different boundary.

---

## Persistent State Ownership

The data model reflects this separation of responsibilities.

Producer-owned state:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

Consumer-owned state:

```text
ZDB_DELTA_STATE
ZDB_ACQ_PRICE
```

The producer should not advance consumer state.

The consumer should not modify producer sequencing state.

This separation allows the producer and consumer to recover independently.

---

## Transaction Boundaries in the Laboratory

The main transaction boundaries are:

```text
Producer transaction
--------------------

lock EVENT counter
update counter
change business state
write change-log event
COMMIT / ROLLBACK
unlock
```

and:

```text
Consumer transaction
--------------------

read committed source events
persist acquisition rows
advance consumer pointer
COMMIT / ROLLBACK
```

The source log sits between these two boundaries:

```text
Producer
   |
 COMMIT
   |
   v
ZDB_CHANGE_LOG
   |
   v
Consumer
   |
 COMMIT
   |
   v
ZDB_ACQ_PRICE
```

This durable intermediate boundary is what makes replay possible.

---

## What This Document Covers

The following topics are examined in detail:

```text
1. Database LUW and commit boundaries

2. Producer transaction atomicity

3. Consumer transaction atomicity

4. Producer locking and event ordering

5. Failure before COMMIT

6. Failure after COMMIT

7. Consumer restart and replay

8. Producer rollback and retry

9. Sequence reuse after rollback

10. State invariants

11. Recovery scenarios

12. Reliability guarantees and remaining limitations
```

---

## What This Document Does Not Cover

This document does not attempt to describe:

```text
general ABAP transaction programming
all SAP LUW concepts
update-task processing
tRFC / qRFC
bgRFC
SAP BW request internals
distributed transactions
two-phase commit
database-specific recovery internals
```

The scope is limited to the transaction behavior directly exercised by the laboratory.

The objective is to make one principle explicit:

```text
Reliable delta processing requires
a clearly defined durable boundary
on both the producer side
and the consumer side.
```

Everything before that boundary must remain recoverable.

Everything after that boundary must be safe to treat as committed progress.overy


## Database LUW and Commit Boundaries

The transaction model of the laboratory is based on explicit database LUW boundaries.

A database LUW defines which changes become durable together.

Inside one LUW, several SQL operations may execute successfully, but none of them should be treated as permanent until:

```text
COMMIT
```

completes.

If the LUW is rolled back, all uncommitted changes belonging to that LUW must return to their previous committed state.

This gives the project a clear distinction between:

```text
temporary in-transaction state
```

and:

```text
durable committed state
```

That distinction is fundamental for both producer and consumer recovery.

---

### Two Independent LUWs

The laboratory contains two main transaction domains:

```text
Producer LUW
```

and:

```text
Consumer LUW
```

They are independent.

The producer LUW creates durable source events.

The consumer LUW acknowledges and persists those already committed source events.

Conceptually:

```text
Producer LUW
        |
        v
ZDB_CHANGE_LOG
        |
        v
Consumer LUW
```

The durable change log sits between the two transaction boundaries.

---

### Producer LUW

The transactional change-log producer modifies:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

within one LUW.

The logical sequence is:

```text
acquire producer lock
        |
        v
read LAST_EVENT_SEQ
        |
        v
allocate next EVENT_SEQ
        |
        v
update ZDB_EVENT_COUNT
        |
        v
apply business change
to ZDB_SRC_PRICE
        |
        v
insert event
into ZDB_CHANGE_LOG
        |
        v
COMMIT
        |
        v
release producer lock
```

The persistent state before and after `COMMIT` must be interpreted differently.

---

### Before Producer COMMIT

Assume the committed producer state is:

```text
LAST_EVENT_SEQ = 1006

P1001/SOUTH
PRICE = 15.00
```

The producer begins a new update and performs:

```text
LAST_EVENT_SEQ
1006 -> 1007
```

then:

```text
P1001/SOUTH
15.00 -> 16.00
```

and inserts:

```text
1007  P1001/SOUTH  U  16.00
```

into the change log.

Inside the producer session, all three changes may already be visible to the current transaction.

However, before `COMMIT`, they do not yet represent durable producer progress.

Conceptually:

```text
transaction-local state:

counter = 1007
price   = 16.00
event   = 1007

but

durable committed state:

counter = 1006
price   = 15.00
event 1007 not yet published
```

The producer must therefore not treat the event as successfully published before the commit succeeds.

---

### After Producer COMMIT

After:

```text
COMMIT
```

the three changes become one durable producer state:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1007
```

```text
ZDB_SRC_PRICE

P1001/SOUTH
PRICE = 16.00
```

```text
ZDB_CHANGE_LOG

1007  P1001/SOUTH  U  16.00
```

Only now may the event be regarded as part of the committed source stream.

---

### Producer ROLLBACK

If any operation fails before commit, the producer executes:

```text
ROLLBACK
```

The committed state must return to:

```text
LAST_EVENT_SEQ = 1006
```

```text
P1001/SOUTH
PRICE = 15.00
```

and:

```text
no legitimate event 1007
```

The producer therefore has only two valid durable outcomes:

```text
old state
```

or:

```text
complete new state
```

A partially committed producer state is not acceptable.

---

### Why the Counter Belongs to the Same LUW

It may appear that:

```text
ZDB_EVENT_COUNT
```

is only technical metadata.

However, its transaction boundary is part of correctness.

Suppose the counter were committed separately:

```text
LAST_EVENT_SEQ
1006 -> 1007
COMMIT
```

and only afterwards the producer attempted:

```text
business update
+
change-log insert
```

If the second part failed, the committed state could become:

```text
counter = 1007
business state unchanged
event 1007 absent
```

The producer would have advanced its sequence state without publishing a corresponding event.

The laboratory therefore keeps the event counter inside the same LUW as the business change and event record.

---

### Why the Business Change Belongs to the Same LUW

The business change cannot be committed separately either.

Suppose:

```text
P1001/SOUTH
15.00 -> 16.00
```

were committed first.

If the subsequent log insert failed, the source would contain:

```text
PRICE = 16.00
```

but the change-log consumer would have no event describing that transition.

The source event stream would no longer represent the committed business state completely.

Therefore:

```text
business update
```

and:

```text
event publication
```

must share the same durability boundary.

---

### Why the Event Belongs to the Same LUW

The opposite order is also unsafe.

Suppose the event were committed first:

```text
1007  P1001/SOUTH  U  16.00
```

but the business update later failed.

The event stream would claim:

```text
P1001/SOUTH became 16.00
```

while the committed current-state table still contained:

```text
15.00
```

The event would describe a business state that never actually committed.

Therefore the event cannot be durable before the corresponding business change.

---

### Producer LUW Invariant

For every committed event:

```text
N
```

the producer must maintain:

```text
counter state
business state
event record
```

as one consistent committed version.

The intended invariant is:

```text
If EVENT_SEQ = N exists as a committed event,
then the corresponding business operation
must also be committed,
and the producer counter must be at least N.
```

For the laboratory's serialized sequence:

```text
LAST_EVENT_SEQ = N
```

also identifies the highest successfully committed event.

---

### Consumer LUW

The consumer transaction is different.

It does not modify source business state.

Instead, it updates:

```text
ZDB_ACQ_PRICE
```

and:

```text
ZDB_DELTA_STATE
```

The logical sequence is:

```text
read committed source events
        |
        v
persist acquisition rows
        |
        v
advance consumer pointer
        |
        v
COMMIT
```

The source events themselves are already durable before this LUW begins.

---

### Consumer Reads Only Committed Source State

The consumer reads:

```text
ZDB_CHANGE_LOG
```

using:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

The consumer must base its progress only on events that are committed and visible.

Uncommitted producer state must not be interpreted as part of the event stream.

This is why the producer commit boundary exists before the consumer transaction.

Conceptually:

```text
Producer transaction
        |
        | COMMIT
        v
durable event log
        |
        | SELECT
        v
Consumer transaction
```

---

### Before Consumer COMMIT

Assume:

```text
LAST_SEQ = 1004
```

and the source log contains committed:

```text
1005
1006
```

The consumer selects both events and inserts corresponding rows into:

```text
ZDB_ACQ_PRICE
```

It may then execute:

```text
UPDATE ZDB_DELTA_STATE
SET LAST_SEQ = 1006
```

Inside the consumer transaction, the session may now see:

```text
acquisition rows for 1005 and 1006
LAST_SEQ = 1006
```

But before `COMMIT`, this is still only transaction-local progress.

If the transaction fails, neither part should remain durable.

---

### After Consumer COMMIT

After:

```text
COMMIT
```

the durable consumer state becomes:

```text
ZDB_ACQ_PRICE
-> 1005 persisted
-> 1006 persisted
```

and:

```text
ZDB_DELTA_STATE
LAST_SEQ = 1006
```

Only now may the consumer regard:

```text
1005
1006
```

as successfully acknowledged.

---

### Consumer ROLLBACK

If processing fails before commit:

```text
ROLLBACK
```

must restore:

```text
LAST_SEQ = 1004
```

and remove any uncommitted acquisition rows from the failed attempt.

The source log remains unchanged because it belongs to the already committed producer state.

The next consumer run therefore again selects:

```text
1005
1006
```

This creates safe replay.

---

### Durable Boundary Between Producer and Consumer

The most important architectural boundary is:

```text
ZDB_CHANGE_LOG
```

after producer commit.

It separates:

```text
source transaction recovery
```

from:

```text
consumer transaction recovery
```

The producer can complete and commit even when the consumer is offline.

The consumer can fail and retry without affecting the already committed business transaction.

This decoupling is essential for restart behavior.

---

### Why One End-to-End LUW Is Not Used

The producer and consumer are not part of one distributed transaction.

The project does not attempt:

```text
business update
+
source log insert
+
remote acquisition persistence
+
consumer pointer update
```

inside one global commit.

Instead, reliability is achieved through two local commit boundaries connected by durable storage:

```text
Producer LUW
        |
      COMMIT
        |
        v
durable change log
        |
        v
Consumer LUW
        |
      COMMIT
```

This is simpler to recover because each side owns its own transaction.

---

### The Change Log as a Recovery Boundary

The committed event log serves several roles at once:

```text
source change history
```

```text
consumer input
```

```text
replay source
```

```text
transaction boundary between producer and consumer
```

If the consumer fails, the log still contains the committed event.

If the producer fails before commit, the event never becomes part of the durable log.

This gives the architecture a clean recovery rule:

```text
Committed log event
-> consumer may process or replay it

No committed log event
-> producer operation was not successfully published
```

---

### Visibility and Durability

Two concepts should be distinguished:

```text
visible inside current transaction
```

and:

```text
durably committed
```

A producer may see its own uncommitted:

```text
counter update
business update
log insert
```

but another session should not treat them as durable source progress.

Likewise, a consumer may see its own uncommitted acquisition rows and pointer update, but those changes do not represent acknowledged progress until commit.

The project therefore reasons about recovery only from:

```text
committed state
```

not from temporary session-local state.

---

### Failure Before COMMIT

For either producer or consumer, failure before commit means:

```text
current LUW has not established durable progress
```

Producer:

```text
counter change
business change
event insert
-> rollback
```

Consumer:

```text
acquisition rows
pointer update
-> rollback
```

The next attempt starts from the previous committed boundary.

---

### Failure After COMMIT

Failure after commit has a different meaning.

Producer:

```text
event is already durable
```

Even if the producer process terminates immediately after `COMMIT`, the event remains valid input for the consumer.

Consumer:

```text
acquisition rows and pointer are already durable
```

Even if the consumer terminates immediately afterwards, the next request continues from the new pointer.

This makes `COMMIT` the definitive recovery boundary.

---

### Commit Outcome Must Be Reflected in Diagnostics

A practical consequence is that success messages should be emitted only after the transaction has committed successfully.

For example, reporting:

```text
Event 1007 successfully created
```

before `COMMIT` would be misleading.

A later failure could still roll the event back.

The cleaned laboratory classes therefore place success diagnostics after the relevant commit where rollback could invalidate earlier work.

The same principle applies to acquisition diagnostics.

---

### Empty Consumer Request

A consumer LUW may also contain no acquired rows.

For example, the safe timestamp reader may scan a time interval containing:

```text
0 rows
```

but still advance its time boundary after successfully scanning that interval.

In that case, the transaction may contain:

```text
no acquisition INSERT
+
pointer update
+
COMMIT
```

This is still valid consumer progress because the pointer represents:

```text
successfully scanned boundary
```

rather than:

```text
last returned row
```

The meaning of the pointer therefore determines what must be committed atomically.

---

### Transaction Boundaries and Timestamp Delta

The same consumer-side atomicity applies to timestamp acquisition.

For example:

```text
persist selected after-images
+
advance LAST_CHANGED_AT
+
COMMIT
```

must remain one LUW.

However, timestamp transaction correctness alone does not solve source-side visibility gaps.

The transaction guarantees:

```text
consumer restart safety
```

while safety intervals address:

```text
source visibility uncertainty
```

These are different concerns.

---

### Transaction Boundaries and Change-Log Delta

For the transactional change log, both sides have explicit transaction responsibilities.

Producer:

```text
counter
+
business change
+
event
+
COMMIT
```

Consumer:

```text
acquisition data
+
LAST_SEQ
+
COMMIT
```

The durable log exists between them.

This creates the complete reliability chain:

```text
Producer LUW
        |
      COMMIT
        |
        v
ZDB_CHANGE_LOG
        |
        v
Consumer LUW
        |
      COMMIT
        |
        v
ZDB_ACQ_PRICE
+
ZDB_DELTA_STATE
```

---

### Main Invariants

The transaction model can be summarized through four invariants.

Producer invariant:

```text
No committed business change
without its committed log event.
```

Event invariant:

```text
No committed log event
without its corresponding committed business change.
```

Consumer invariant:

```text
No committed pointer advancement
without corresponding committed acquisition persistence.
```

Replay invariant:

```text
If consumer progress is not committed,
the required source event remains available
for another attempt.
```

These invariants define the transaction boundaries used throughout the project.

---

### Core Conclusion

The laboratory does not attempt to make an entire acquisition flow one transaction.

Instead, it divides the flow into two reliable local transactions:

```text
source publication transaction
```

and:

```text
consumer acknowledgement transaction
```

connected by a durable change log.

The central principle is:

```text
Producer COMMIT
defines when a source change becomes publishable.

Consumer COMMIT
defines when that published change becomes acknowledged.
```

Everything before either commit remains recoverable.

Everything after either commit must be safe to treat as durable progress.


## Producer Transaction Atomicity

The transactional change-log producer must publish one business change as one indivisible committed unit.

For every producer operation, the following state changes belong together:

```text
event-sequence advancement
+
business-state modification
+
change-log event
```

The producer must never allow only part of this group to become durable.

This requirement is the core source-side atomicity rule of the change-log architecture.

---

### Producer State Components

A producer operation modifies three persistent structures.

The producer sequence state is stored in:

```text
ZDB_EVENT_COUNT
```

The current business state is stored in:

```text
ZDB_SRC_PRICE
```

The durable event representation is stored in:

```text
ZDB_CHANGE_LOG
```

For one committed event:

```text
EVENT_SEQ = N
```

all three structures must describe one consistent source state.

---

### Example: Update Event

Assume the committed state is:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1006
```

and:

```text
ZDB_SRC_PRICE

P1001/SOUTH
PRICE = 15.00
```

The producer wants to apply:

```text
PRICE 15.00 -> 16.00
```

The next event sequence is:

```text
1007
```

The producer transaction therefore performs:

```text
ZDB_EVENT_COUNT
1006 -> 1007
```

```text
ZDB_SRC_PRICE

P1001/SOUTH
15.00 -> 16.00
```

and creates:

```text
ZDB_CHANGE_LOG

1007  P1001/SOUTH  U  16.00
```

Only after all three operations succeed does the producer execute:

```text
COMMIT
```

---

### Atomic Success

The successful committed result is:

```text
counter = 1007
business state = 16.00
event 1007 exists
```

These three facts describe the same source operation.

The producer has therefore published:

```text
event 1007
```

as part of the durable event stream.

---

### Atomic Failure

If any database operation fails before commit, the producer performs:

```text
ROLLBACK
```

The committed state must return to:

```text
counter = 1006
business state = 15.00
event 1007 absent
```

From the perspective of the durable source stream:

```text
event 1007 never happened
```

The producer may later retry the complete business operation.

---

### Why Atomicity Is Required

Without atomicity, several inconsistent states are possible.

Consider:

```text
counter = new
business state = new
event = missing
```

The source business data changed, but the consumer has no event describing that change.

The event stream is incomplete.

---

Another invalid state is:

```text
counter = new
business state = old
event = new
```

The change log contains an event describing a business state that never committed.

The event stream is false.

---

A third invalid state is:

```text
counter = old
business state = new
event = new
```

The event and business state exist, but the producer sequence state no longer identifies the highest committed event correctly.

Future sequence allocation may conflict with an already committed event.

---

### Valid State Transition

The valid producer transition is therefore:

```text
Before transaction:

Counter = N
Business = S0
Event N+1 absent
```

to:

```text
After successful COMMIT:

Counter = N+1
Business = S1
Event N+1 present
```

or, after failure:

```text
After ROLLBACK:

Counter = N
Business = S0
Event N+1 absent
```

There must be no durable intermediate state between these two outcomes.

---

### State Transition Model

Conceptually:

```text
                 producer transaction
                        begins
                           |
                           v

Committed S0 -------------------------------+
                                            |
                  counter -> N+1            |
                  business -> S1            |
                  event N+1 inserted        |
                                            |
                     +----------------------+
                     |
              +------+------+
              |             |
              v             v
           COMMIT         ROLLBACK
              |             |
              v             v

Committed S1           Committed S0
```

Only:

```text
S0
```

and:

```text
S1
```

are valid durable states.

Everything between them is temporary transaction-local state.

---

### Atomicity for INSERT

For an insert producer, the same rule applies.

The transaction performs:

```text
advance event counter
+
insert business row
+
insert I event
```

For example:

```text
EVENT_SEQ = 1003
```

and:

```text
P1011/SOUTH
PRICE = 110.00
```

produce:

```text
1003  P1011/SOUTH  I  110.00
```

All three changes must commit together.

If the event insert fails:

```text
P1011/SOUTH
```

must not remain committed in the source without its `I` event.

---

### Atomicity for UPDATE

For an update:

```text
advance event counter
+
update current-state row
+
insert U event
```

must share one LUW.

The event payload should represent the same after-image as the business state written by that transaction.

For example:

```text
source after-image:

P1001/SOUTH
PRICE = 16.00
```

must correspond to:

```text
event after-image:

1007  P1001/SOUTH  U  16.00
```

Using the same business values for both operations reduces the risk of semantic divergence between current state and event history.

---

### Atomicity for DELETE

Physical delete uses the same principle.

The producer performs:

```text
advance event counter
+
delete current-state row
+
insert D event
```

For example:

```text
DELETE P1010/SOUTH
```

together with:

```text
1004  P1010/SOUTH  D
```

must commit as one unit.

If the `D` event cannot be written:

```text
P1010/SOUTH
```

must not disappear permanently from the current-state table.

Otherwise the delete would become invisible to the change-log consumer.

---

### DELETE Demonstrates Why the Event Must Be Durable

An update may still leave evidence in the current-state table.

A physical delete does not.

After:

```text
DELETE
```

the business row no longer exists.

Therefore, once the delete commits, the change-log event may be the only remaining durable evidence that the business key was removed.

This makes transactionally coupled delete-event creation especially important.

---

### Event Allocation Is Part of the Business Transaction

The project treats event-sequence allocation as part of the producer LUW.

This means:

```text
LAST_EVENT_SEQ
```

does not represent:

```text
highest number ever attempted
```

It represents:

```text
highest event successfully committed
by the producer stream
```

This interpretation is possible because failed sequence advancement is rolled back together with the failed producer transaction.

---

### Why Sequence Allocation Is Not Committed Early

A tempting design would be:

```text
allocate EVENT_SEQ
COMMIT counter
```

followed by:

```text
perform business operation
write event
COMMIT
```

This separates sequence allocation from event publication.

A failure after the first commit could leave:

```text
counter = 1007
```

without:

```text
event 1007
```

The stream would contain a reserved but unpublished sequence.

A gap alone may not always be incorrect, but the producer counter would no longer represent the highest committed event under the laboratory's semantics.

The project therefore keeps sequence advancement inside the producer LUW.

---

### Sequence Reuse After Rollback

Because the counter update is transactional, a failed producer can return from:

```text
temporary counter = 1007
```

to:

```text
committed counter = 1006
```

The next retry can therefore allocate:

```text
1007
```

again.

This is safe because the failed transaction never published event `1007`.

The committed event stream has not observed that sequence value yet.

---

### Attempted Sequence vs Committed Sequence

This distinction is useful:

```text
attempted EVENT_SEQ
```

is transaction-local.

```text
committed EVENT_SEQ
```

is part of the durable event stream.

Only committed event identities matter to the consumer.

The consumer must never reason about sequence values that existed only inside rolled-back producer transactions.

---

### Failure Points Inside the Producer LUW

Several failure points are possible.

#### Failure Before Counter Update

```text
lock acquired
counter read
failure occurs
```

No persistent producer state has changed.

Recovery:

```text
ROLLBACK
release lock
retry
```

---

#### Failure After Counter Update

```text
counter updated
business state not yet changed
failure occurs
```

The counter update is uncommitted.

Recovery:

```text
ROLLBACK
```

restores the previous committed counter.

---

#### Failure After Business Change

```text
counter updated
business state changed
event not yet inserted
failure occurs
```

Both changes are still inside the same LUW.

Recovery:

```text
ROLLBACK
```

restores:

```text
counter
+
business state
```

---

#### Failure During Event Insert

This is the laboratory's deliberate duplicate-key experiment.

The transaction has already performed:

```text
counter update
business update
```

but:

```text
event insert
```

fails.

Recovery:

```text
ROLLBACK
```

must reverse the earlier successful SQL operations.

---

#### Failure After Event Insert but Before COMMIT

At this point all intended SQL operations may have succeeded, but nothing is yet durable.

If execution terminates before commit:

```text
counter
business state
event
```

must still be treated as uncommitted.

Recovery is again based on rollback of the whole LUW.

---

### Failure After COMMIT

Once:

```text
COMMIT
```

succeeds, the producer operation is durable.

If the application process fails immediately afterwards, the correct recovery behavior is not:

```text
ROLLBACK
```

because the transaction has already completed.

The durable source state now contains:

```text
counter
business change
event
```

and the consumer may process the event normally.

A retry mechanism must therefore distinguish:

```text
failure before COMMIT
```

from:

```text
failure after successful COMMIT
```

to avoid producing the same business operation twice.

---

### Success Reporting

This distinction also affects diagnostics.

A producer should not report:

```text
Event 1007 committed successfully
```

before:

```text
COMMIT
```

has completed.

Before commit, the event is only prepared.

A later error could still invalidate the transaction.

The cleaned laboratory classes therefore place success messages after the successful commit where appropriate.

---

### Lock Ownership During the LUW

The event-counter lock is acquired before sequence allocation.

It remains held while the producer performs:

```text
counter update
business change
event insert
COMMIT or ROLLBACK
```

Only after the transaction is resolved is the lock released.

Conceptually:

```text
LOCK
 |
 +-- allocate sequence
 |
 +-- change business state
 |
 +-- write event
 |
 +-- COMMIT / ROLLBACK
 |
UNLOCK
```

This ensures that another producer cannot publish a later sequence while the current event is still transactionally unresolved.

---

### Lock and LUW Form One Producer Protocol

The complete producer protocol therefore combines two mechanisms:

```text
Locking
-> serializes producers
```

and:

```text
Database LUW
-> makes one producer operation atomic
```

Together:

```text
LOCK
        |
        v
begin logical producer operation
        |
        +--> counter
        +--> business state
        +--> event
        |
        v
COMMIT / ROLLBACK
        |
        v
UNLOCK
```

Removing either mechanism weakens the reliability guarantee.

---

### Producer Atomicity Invariant

The strongest form of the producer invariant is:

```text
For every committed event N,
the corresponding business operation
is committed in the same source transaction.
```

and conversely:

```text
For every relevant committed business operation,
the corresponding event must exist
in the committed event stream.
```

This creates a one-to-one relationship between:

```text
relevant committed business changes
```

and:

```text
committed change-log events
```

---

### Relationship to the Transactional Outbox Pattern

The laboratory change log follows the same central principle as a transactional outbox:

```text
business data
+
event representation
```

are persisted within one local database transaction.

The project additionally maintains an explicitly ordered:

```text
EVENT_SEQ
```

and serializes event publication.

The objective is the same:

```text
avoid a dual-write problem
between business state
and downstream event publication
```

The consumer can trust the committed change log because the source does not publish business state independently from its event representation.

---

### Avoiding the Dual-Write Problem

Without one shared transaction, the producer might need two independent durable operations:

```text
write business database
```

and:

```text
publish event somewhere else
```

A failure between them creates ambiguity:

```text
business committed
event missing
```

or:

```text
event published
business failed
```

By storing:

```text
ZDB_CHANGE_LOG
```

inside the same database transaction as:

```text
ZDB_SRC_PRICE
```

the laboratory avoids that split durability boundary.

---

### Consumer Trust Boundary

The consumer does not need to validate the current-state table for every event.

Once an event is committed in:

```text
ZDB_CHANGE_LOG
```

the consumer relies on the producer invariant:

```text
this event represents a committed business operation
```

This is an important architectural separation.

The consumer does not repair source-side inconsistencies.

The producer is responsible for preventing them.

---

### Why Atomicity Simplifies Recovery

Without transaction atomicity, recovery code would need to inspect several possible partial states:

```text
Did the counter update commit?

Did the business row change?

Did the event insert commit?

Which combination survived?
```

With one LUW, recovery is simpler.

Before commit:

```text
treat the producer operation as incomplete
```

After commit:

```text
treat the producer operation as complete
```

The database transaction collapses many possible intermediate states into two durable outcomes.

---

### Atomicity Does Not Guarantee Ordering

Producer atomicity alone does not solve concurrent ordering.

Two transactions could each be internally atomic but still commit sequences out of order:

```text
A owns 1002
B owns 1003

B commits first
A commits later
```

Each transaction could be perfectly atomic.

The stream would still be unsafe for a single high-water-mark consumer.

Therefore:

```text
atomicity
```

and:

```text
commit-consistent ordering
```

must remain separate requirements.

Atomicity is handled by:

```text
COMMIT / ROLLBACK
```

Ordering is handled by:

```text
EZDBEVCOUNT
```

and the producer sequencing protocol.

---

### Atomicity Does Not Guarantee Event Retention

A perfectly atomic producer can also be undermined if events are deleted too early.

For example:

```text
event 1007 committed correctly
```

but later removed before the consumer has reached it.

The producer transaction was correct, but replay is no longer possible.

Therefore full end-to-end reliability additionally depends on:

```text
event retention
```

This concern belongs outside the individual producer LUW.

---

### Producer Atomicity vs Consumer Atomicity

The two transaction invariants are symmetrical but operate on different state.

Producer:

```text
business operation
+
event publication
+
producer sequence state
```

Consumer:

```text
acquired data
+
consumer acknowledgement pointer
```

Producer atomicity answers:

```text
Was this source change published correctly?
```

Consumer atomicity answers:

```text
Was this published source change
durably acknowledged?
```

Both are required for the complete acquisition path.

---

### Result of the Failure Experiment

The laboratory explicitly tests producer atomicity.

Initial committed state:

```text
LAST_EVENT_SEQ = 1006
P1001/SOUTH    = 15.00
```

A deliberate duplicate-key conflict is created for:

```text
EVENT_SEQ = 1007
```

The producer temporarily performs:

```text
counter 1006 -> 1007
price   15.00 -> 16.00
```

but the event insert fails.

The producer executes:

```text
ROLLBACK
```

and the committed state remains:

```text
LAST_EVENT_SEQ = 1006
P1001/SOUTH    = 15.00
```

After the artificial conflict is removed, retry succeeds:

```text
LAST_EVENT_SEQ = 1007
P1001/SOUTH    = 16.00

1007  P1001/SOUTH  U  16.00
```

This confirms that the producer does not leave partial durable state after an event-publication failure.

---

### Core Conclusion

Producer atomicity can be summarized as:

```text
business change
+
event identity
+
event payload
```

must have one durability boundary.

The producer must never create a state in which the consumer-visible event stream and the committed business state disagree because only part of a producer operation survived.

The central rule is:

```text
No committed business change
without its committed event.

No committed event
without its committed business change.
```

The next section applies the same transaction reasoning to the other side of the pipeline:

```text
Consumer Transaction Atomicity
