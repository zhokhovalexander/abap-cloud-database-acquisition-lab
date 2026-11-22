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

## Consumer Transaction Atomicity

The consumer side has its own atomicity requirement.

For every successful delta request, the following two pieces of state belong together:

```text
acquisition persistence
+
consumer delta-pointer advancement
```

In the laboratory, these are represented by:

```text
ZDB_ACQ_PRICE
```

and:

```text
ZDB_DELTA_STATE
```

A consumer must never durably advance its pointer beyond source data that has not also been durably persisted.

This is the central consumer-side transaction invariant.

---

### Consumer State Components

The acquisition result is stored in:

```text
ZDB_ACQ_PRICE
```

The persistent delta position is stored in:

```text
ZDB_DELTA_STATE
```

For change-log acquisition:

```text
LAST_SEQ
```

means:

```text
highest source EVENT_SEQ
successfully persisted by this consumer
```

Therefore `LAST_SEQ` is not merely a search parameter.

It is an acknowledgement boundary.

---

### Example

Assume the consumer starts with:

```text
LAST_SEQ = 1004
```

The source change log already contains committed events:

```text
1005  P1001/SOUTH  U  14.00
1006  P1001/SOUTH  U  15.00
```

The consumer selects:

```text
EVENT_SEQ > 1004
ORDER BY EVENT_SEQ
```

and obtains:

```text
1005
1006
```

The intended consumer transaction is:

```text
persist 1005
persist 1006
        |
        v
update LAST_SEQ = 1006
        |
        v
COMMIT
```

The acquisition rows and pointer advancement therefore share one durability boundary.

---

### Valid State Transition

Before the consumer transaction:

```text
ZDB_ACQ_PRICE
-> no committed acquisition for 1005 and 1006

ZDB_DELTA_STATE
LAST_SEQ = 1004
```

After successful commit:

```text
ZDB_ACQ_PRICE
-> 1005 committed
-> 1006 committed

ZDB_DELTA_STATE
LAST_SEQ = 1006
```

If the transaction fails:

```text
ZDB_ACQ_PRICE
-> 1005 and 1006 not committed

ZDB_DELTA_STATE
LAST_SEQ = 1004
```

These are the two valid durable outcomes.

---

### Invalid Partial State

The dangerous state would be:

```text
LAST_SEQ = 1006
```

while:

```text
1005
1006
```

have not been durably persisted.

The next request would evaluate:

```text
EVENT_SEQ > 1006
```

and would no longer select those events.

This creates permanent data loss from the consumer's perspective.

---

### Why the Pointer Must Not Commit First

Consider the following incorrect implementation:

```text
update LAST_SEQ = 1006
COMMIT

persist events 1005 and 1006
COMMIT
```

If execution fails between the two commits, the durable state becomes:

```text
LAST_SEQ = 1006
```

but:

```text
acquisition rows 1005 and 1006 missing
```

On restart:

```text
EVENT_SEQ > 1006
```

skips both events.

This violates the central pointer rule:

```text
A consumer may acknowledge only data
that has already been durably acquired.
```

---

### Why Persistence and Pointer Should Share One LUW

A weaker design could perform:

```text
persist events
COMMIT

update LAST_SEQ
COMMIT
```

This avoids data loss but creates a different problem.

Suppose the first commit succeeds and the process fails before pointer advancement.

The durable state becomes:

```text
1005 and 1006 persisted
LAST_SEQ = 1004
```

The next request selects:

```text
1005
1006
```

again.

This creates duplicate acquisition.

Depending on downstream semantics, duplicates may be recoverable, but the stronger design is:

```text
persist acquisition
+
advance pointer
+
one COMMIT
```

---

### Consumer LUW

The laboratory therefore uses:

```text
read committed source data
        |
        v
build acquisition rows
        |
        v
insert ZDB_ACQ_PRICE
        |
        v
update ZDB_DELTA_STATE
        |
        v
COMMIT
```

If either persistence or pointer update fails:

```text
ROLLBACK
```

restores the previous committed consumer state.

---

### Failure Before Persistence

Suppose the consumer selects:

```text
1005
1006
```

but fails before writing anything to:

```text
ZDB_ACQ_PRICE
```

The committed state remains:

```text
LAST_SEQ = 1004
```

The next consumer run selects the same events again.

No special recovery logic is required.

---

### Failure During Acquisition Persistence

Suppose the consumer begins inserting acquired events but encounters a database error before completion.

Because the insert operations are still uncommitted:

```text
ROLLBACK
```

removes the partial acquisition rows.

The pointer remains:

```text
LAST_SEQ = 1004
```

The entire source range can then be replayed.

---

### Failure After Persistence but Before Pointer Update

This is the restart scenario explicitly tested in the laboratory.

The consumer successfully executes:

```text
INSERT ZDB_ACQ_PRICE
```

for:

```text
1005
1006
```

but is deliberately interrupted before:

```text
UPDATE ZDB_DELTA_STATE
```

and before:

```text
COMMIT
```

The acquisition rows exist only inside the current LUW.

When the session is terminated, they are rolled back.

The persistent pointer remains:

```text
LAST_SEQ = 1004
```

The next run therefore selects:

```text
1005
1006
```

again.

---

### Failure After Pointer Update but Before COMMIT

Suppose the consumer has already executed:

```text
INSERT acquisition rows
```

and:

```text
UPDATE LAST_SEQ = 1006
```

but has not yet committed.

If execution fails before `COMMIT`, both changes roll back:

```text
acquisition rows removed
LAST_SEQ restored to 1004
```

The same events remain replayable.

---

### COMMIT Is the Acknowledgement Boundary

This leads to an important interpretation:

```text
SELECT
```

does not acknowledge an event.

```text
INSERT
```

does not acknowledge an event.

```text
UPDATE LAST_SEQ
```

inside an uncommitted transaction does not acknowledge an event.

The event becomes acknowledged only when:

```text
acquisition persistence
+
pointer advancement
+
COMMIT
```

have completed successfully.

---

### Failure After COMMIT

If the consumer crashes after a successful:

```text
COMMIT
```

the durable state already contains:

```text
acquisition rows 1005 and 1006
LAST_SEQ = 1006
```

The next consumer run correctly starts with:

```text
EVENT_SEQ > 1006
```

There is no reason to replay the earlier events.

---

### Consumer Pointer as Durable Acknowledgement

For the change-log consumer:

```text
LAST_SEQ = N
```

should be interpreted as:

```text
All required source events up to N
have been successfully persisted
by this consumer.
```

This semantic interpretation is stronger than:

```text
N was the last sequence observed
```

Observation is not enough.

Durable persistence is required.

---

### Replay After Rollback

Suppose:

```text
LAST_SEQ = 1004
```

and an attempt processes:

```text
1005
1006
```

but rolls back.

The next attempt again evaluates:

```text
EVENT_SEQ > 1004
```

and retrieves the same events.

This replay is expected behavior.

The architecture deliberately prefers:

```text
reprocessing after failed acknowledgement
```

over:

```text
advancing the pointer too early
```

---

### Durable Source Log Makes Replay Possible

Consumer atomicity depends on the source events remaining durable independently from the consumer LUW.

The producer has already committed:

```text
1005
1006
```

to:

```text
ZDB_CHANGE_LOG
```

before the consumer starts.

A consumer rollback therefore does not affect the source events.

They remain available for another attempt.

Conceptually:

```text
Producer COMMIT
        |
        v
durable events
        |
        v
Consumer attempt
        |
     failure
        |
     ROLLBACK
        |
        v
same durable events still available
```

---

### Producer and Consumer Ownership

The producer owns:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

The consumer owns:

```text
ZDB_ACQ_PRICE
ZDB_DELTA_STATE
```

This separation matters for recovery.

A consumer failure must not roll back a source business transaction.

Likewise, a producer failure must not modify consumer progress.

Each side recovers independently from its own last committed boundary.

---

### Consumer Atomicity for Timestamp Delta

The same principle applies to timestamp acquisition.

For a timestamp request, the consumer may:

```text
persist selected after-images
```

and then advance:

```text
LAST_CHANGED_AT
```

to the new safe boundary.

These changes must share one transaction:

```text
persist rows
+
advance LAST_CHANGED_AT
+
COMMIT
```

If the request fails before commit:

```text
LAST_CHANGED_AT
```

must remain at the previous boundary.

Otherwise part of the source-time range could be declared processed without corresponding acquisition persistence.

---

### Empty Timestamp Request

A safe request may select:

```text
0 rows
```

but still successfully scan a new time interval.

For example:

```text
old LAST_CHANGED_AT = 10:00
new UPPER_BOUND      = 10:05
```

with no rows in:

```text
10:00 < CHANGED_AT <= 10:05
```

The consumer may still commit:

```text
LAST_CHANGED_AT = 10:05
```

because the pointer represents:

```text
successfully scanned source time
```

rather than:

```text
timestamp of the last persisted row
```

---

### Atomicity Does Not Solve Source Visibility

Consumer transaction atomicity is necessary for timestamp delta, but it does not solve delayed source visibility.

A consumer can perfectly execute:

```text
persist selected rows
+
advance pointer
+
COMMIT
```

and still lose a source change if that change was invisible during the `SELECT`.

Therefore:

```text
consumer atomicity
```

protects:

```text
restart and acknowledgement correctness
```

while:

```text
upper / lower safety intervals
```

protect:

```text
timestamp source-boundary correctness
```

These mechanisms solve different problems.

---

### Consumer Concurrency

The laboratory assumes:

```text
one active consumer
for one logical source pointer
```

Suppose two consumer sessions both read:

```text
LAST_SEQ = 1004
```

and both select:

```text
1005
1006
```

They could process the same events concurrently.

Depending on table keys and transaction timing, this could produce:

```text
duplicate acquisition
database conflicts
pointer races
```

The current project does not implement a dedicated consumer lock.

Therefore consumer concurrency is outside the reliability guarantee demonstrated by the laboratory.

---

### Single-Consumer Invariant

The consumer transaction model assumes:

```text
one logical owner of LAST_SEQ
```

at a time.

Under that assumption:

```text
read pointer
select events
persist data
advance pointer
commit
```

forms one serial consumer progression.

A production system requiring parallel consumers would need additional coordination or partitioned consumer state.

---

### Batch Atomicity

The current change-log reader treats one selected event set as one acquisition transaction.

Conceptually:

```text
selected batch:
1005
1006
1007
```

results either in:

```text
all persisted
LAST_SEQ = 1007
COMMIT
```

or:

```text
ROLLBACK
LAST_SEQ unchanged
```

This simplifies recovery reasoning.

For very large production data volumes, package-level commits might be necessary, but then each package would require its own clearly defined durable pointer boundary.

---

### Consumer Restart Invariant

The restart rule can be summarized as:

```text
Restart always begins from
the last committed consumer pointer.
```

The consumer does not need to know:

```text
which SQL statement was last executed
before the previous session failed
```

The database commit boundary already answers the recovery question.

If the pointer was not committed:

```text
replay
```

If the pointer was committed:

```text
continue after it
```

---

### State Table as Recovery Metadata

`ZDB_DELTA_STATE` therefore serves not only as a selection parameter but also as recovery metadata.

It tells the consumer:

```text
where durable processing ended
```

The pointer should never represent:

```text
work merely attempted
```

It must represent:

```text
work durably acknowledged
```

This makes restart deterministic.

---

### Relationship to Producer Atomicity

Producer atomicity guarantees:

```text
Every committed source event
corresponds to a committed business change.
```

Consumer atomicity guarantees:

```text
Every acknowledged source event
corresponds to committed acquisition persistence.
```

Together:

```text
business change
        |
Producer COMMIT
        |
durable event
        |
Consumer COMMIT
        |
durable acquisition
```

Each transition has a clear transaction boundary.

---

### End-to-End Invariant

The full reliability chain can therefore be expressed as:

```text
If consumer LAST_SEQ = N,
then every required source event <= N
was previously committed by the producer
and successfully persisted by the consumer.
```

This assumes:

```text
producer ordering is correct
event retention is sufficient
one logical consumer owns the pointer
```

Within those assumptions, `LAST_SEQ` becomes a trustworthy high-water mark.

---

### Result of the Laboratory Restart Experiment

The experiment begins with:

```text
LAST_SEQ = 1004
```

and committed source events:

```text
1005
1006
```

The consumer:

```text
selects 1005 and 1006
persists them inside the LUW
is interrupted before COMMIT
```

After the failed run:

```text
ZDB_ACQ_PRICE
-> no committed acquisition rows for 1005 and 1006

ZDB_DELTA_STATE
-> LAST_SEQ remains 1004

ZDB_CHANGE_LOG
-> 1005 and 1006 remain available
```

The next run again selects:

```text
1005
1006
```

and successfully commits:

```text
acquisition rows
+
LAST_SEQ = 1006
```

This confirms the consumer-side atomicity invariant.

---

### Core Conclusion

Consumer transaction atomicity can be summarized as:

```text
Persist first.
Acknowledge in the same transaction.
Commit both together.
```

The central rule is:

```text
No committed consumer pointer advancement
without corresponding committed acquisition persistence.
```

If the consumer fails before that boundary:

```text
rollback and replay
```

If it fails after that boundary:

```text
continue from the committed pointer
```

This makes the database `COMMIT` the definitive boundary between:

```text
attempted processing
```

and:

```text
acknowledged processing
```
## Producer Locking and Event Ordering

Producer transaction atomicity guarantees that one producer operation is internally consistent.

It does not by itself guarantee that multiple concurrent producer transactions become visible in the same order in which their event numbers were allocated.

This distinction is critical because the consumer uses:

```text
EVENT_SEQ
```

as a high-water-mark delta field.

For that pointer to be safe, event publication order must be compatible with sequence order.

---

### Why Atomicity Alone Is Not Enough

Consider two concurrent producer sessions.

Session A allocates:

```text
EVENT_SEQ = 1002
```

Session B later allocates:

```text
EVENT_SEQ = 1003
```

Each transaction may be perfectly atomic.

However, if Session B commits first, the event stream can temporarily become:

```text
1003
-> committed and visible

1002
-> still uncommitted and invisible
```

A consumer starting from:

```text
LAST_SEQ = 1001
```

could then select:

```text
1003
```

and advance:

```text
LAST_SEQ = 1003
```

If Session A commits afterwards, event:

```text
1002
```

appears behind the consumer pointer and is no longer eligible for:

```text
EVENT_SEQ > LAST_SEQ
```

The event is lost from the consumer's perspective.

---

### The Required Ordering Property

The event stream therefore needs a stronger invariant than:

```text
EVENT_SEQ is monotonically increasing
```

The required property is:

```text
lower EVENT_SEQ values
must be transactionally resolved
before higher EVENT_SEQ values
can become visible
```

For the laboratory's single ordered stream, the intended relationship is:

```text
allocation order
=
commit order
=
visibility order
```

This is what makes:

```text
EVENT_SEQ
```

safe as a consumer high-water mark.

---

### Event Counter Serialization

The producer sequence is stored in:

```text
ZDB_EVENT_COUNT
```

for:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
```

The current producer position is:

```text
LAST_EVENT_SEQ
```

The laboratory protects this counter with lock object:

```text
EZDBEVCOUNT
```

The lock is acquired before reading and advancing the counter.

Conceptually:

```text
acquire lock
        |
        v
read LAST_EVENT_SEQ
        |
        v
allocate next EVENT_SEQ
        |
        v
update counter
        |
        v
apply business change
        |
        v
write change-log event
        |
        v
COMMIT / ROLLBACK
        |
        v
release lock
```

Only one producer for the same logical stream can execute this sequence at a time.

---

### Why the Lock Covers More Than the Counter Update

It would not be enough to lock only while calculating the next sequence.

For example:

```text
LOCK
allocate 1002
update counter
UNLOCK
```

followed by:

```text
business change
write event
COMMIT
```

would still allow another producer to:

```text
LOCK
allocate 1003
UNLOCK
COMMIT 1003
```

before event `1002` commits.

The sequence numbers would remain unique, but commit order could still differ from allocation order.

Therefore the lock must remain held while the event is transactionally unresolved.

---

### Lock Held Until Transaction Resolution

The laboratory keeps the lock through:

```text
sequence allocation
business change
event insertion
```

and releases it only after:

```text
COMMIT
```

or:

```text
ROLLBACK
```

has resolved the producer transaction.

Conceptually:

```text
LOCK
 |
 +-- allocate EVENT_SEQ
 |
 +-- update counter
 |
 +-- modify business state
 |
 +-- insert change-log event
 |
 +-- COMMIT / ROLLBACK
 |
UNLOCK
```

This prevents another producer from publishing a later event while the current event is still undecided.

---

### Two-Session Concurrency Experiment

The laboratory verifies this behavior using two independent ADT sessions.

Assume the committed producer counter is:

```text
LAST_EVENT_SEQ = 1001
```

Session A starts a producer update.

It acquires:

```text
EZDBEVCOUNT
```

and allocates:

```text
EVENT_SEQ = 1002
```

The producer then:

```text
updates the counter
applies the business change
inserts event 1002
```

but execution is paused before:

```text
COMMIT
```

At this point:

```text
1002
```

exists only inside Session A's uncommitted LUW.

The lock is still held.

---

### Concurrent Session B

While Session A is paused, Session B starts another producer.

Session B attempts to acquire:

```text
EZDBEVCOUNT
```

for the same logical source.

The lock attempt fails because Session A still owns the lock.

Session B therefore does not:

```text
read a newer committed counter
allocate 1003
modify business state
write another log event
```

No later event can be published while `1002` remains unresolved.

---

### Session A Commits

Session A is resumed and executes:

```text
COMMIT
```

The following become durable together:

```text
LAST_EVENT_SEQ = 1002
business change for event 1002
change-log event 1002
```

The lock is then released.

The committed event stream now ends at:

```text
1002
```

---

### Session B Retries

Session B retries after the lock is released.

It now reads:

```text
LAST_EVENT_SEQ = 1002
```

and allocates:

```text
EVENT_SEQ = 1003
```

It performs its complete producer transaction and commits.

The durable stream becomes:

```text
1002
1003
```

The observed order is therefore:

```text
allocation:
1002 -> 1003

commit:
1002 -> 1003

visibility:
1002 -> 1003
```

This is the ordering required by the consumer high-water mark.

---

### Why a Later Producer Is Rejected Instead of Queued

In the laboratory, a conflicting producer receives a lock error and exits.

A production implementation could instead:

```text
wait
retry automatically
queue the request
```

The exact contention policy is secondary.

The correctness requirement is simply:

```text
do not publish a higher EVENT_SEQ
while a lower allocated sequence is unresolved
```

The laboratory uses explicit rejection because it makes the concurrency behavior easy to observe.

---

### Long-Running Producer Transactions

If one producer remains open for a long time, the lock remains held.

Later producers are therefore delayed.

For example:

```text
Session A
EVENT_SEQ = 1002
transaction open for 10 minutes
```

means that no later producer can publish:

```text
1003
```

during those 10 minutes.

This affects:

```text
latency
throughput
producer concurrency
```

but preserves:

```text
delta correctness
```

The architecture deliberately trades producer parallelism for a simple globally ordered event stream.

---

### Difference from Timestamp Delta

The delayed-transaction problem also appears in timestamp acquisition, but the protection mechanism is different.

Timestamp delta allows producers to proceed independently.

The consumer protects itself with:

```text
UPPER_SAFETY_INTERVAL
```

and optionally:

```text
LOWER_SAFETY_INTERVAL
```

The change-log architecture instead constrains the producer side.

Conceptually:

```text
Timestamp delta:

producer timing may vary
        |
        v
consumer delays trust in recent time
```

versus:

```text
Change-log delta:

producer publication is serialized
        |
        v
consumer can trust EVENT_SEQ order
```

---

### Locking and Atomicity Solve Different Problems

It is important to keep these mechanisms conceptually separate.

Transaction atomicity guarantees:

```text
counter
+
business state
+
event
```

commit or roll back together.

Locking guarantees:

```text
another producer cannot publish
a later sequence
while the current event is unresolved
```

Atomicity protects:

```text
consistency inside one producer transaction
```

Locking protects:

```text
ordering between producer transactions
```

Both are necessary.

---

### Atomic but Incorrect Ordering

Consider two perfectly atomic transactions:

```text
Transaction A:
1002
business change A
event 1002
COMMIT
```

and:

```text
Transaction B:
1003
business change B
event 1003
COMMIT
```

If B commits first, each transaction is internally correct.

Yet the combined event stream is unsafe for:

```text
LAST_SEQ
```

because:

```text
1003
```

can become visible before:

```text
1002
```

Atomicity alone therefore does not imply safe global ordering.

---

### Monotonic Sequence Alone Is Also Insufficient

Likewise, a counter that always returns:

```text
1001
1002
1003
1004
```

does not guarantee a safe stream.

The important question is not only:

```text
Are numbers unique and increasing?
```

but:

```text
Can a higher committed number become visible
while a lower required number is still uncommitted?
```

If the answer is yes, a simple high-water-mark consumer is unsafe.

---

### Producer Ordering Invariant

For the laboratory stream, the ordering invariant can be stated as:

```text
If committed event N is visible,
then every required event with EVENT_SEQ < N
has already been transactionally resolved.
```

For the current implementation, resolution means:

```text
committed
```

or:

```text
rolled back and therefore never published
```

No unresolved lower sequence may remain behind a visible higher sequence.

---

### Rollback and Ordering

Suppose Session A allocates:

```text
1002
```

but its transaction fails.

Because the event counter update is part of the same LUW:

```text
ROLLBACK
```

restores:

```text
LAST_EVENT_SEQ = 1001
```

The failed `1002` never becomes part of the committed stream.

After the lock is released, the next producer may allocate:

```text
1002
```

again.

This preserves both:

```text
atomicity
```

and:

```text
ordered publication
```

---

### Sequence Gaps

A production sequence implementation may choose not to reuse numbers after failed attempts.

For example, a durable stream could contain:

```text
1001
1003
1004
```

with no event `1002`.

A gap is not automatically a correctness problem.

The consumer can still safely advance from:

```text
1001
```

to:

```text
1003
```

if the source contract guarantees that:

```text
1002 can never appear later
```

The critical property is therefore not perfect numerical continuity.

It is final ordering.

---

### No Late Appearance Behind the Pointer

The strongest consumer-facing rule is:

```text
Once the consumer safely advances to EVENT_SEQ = N,
no new required committed event with EVENT_SEQ <= N
may appear later.
```

The producer locking protocol exists specifically to guarantee this property for the laboratory stream.

---

### Lock Scope

The lock key contains:

```text
CLIENT
SOURCE_NAME
```

This means serialization is scoped to one logical source stream.

For:

```text
PRODUCT_PRICE_LOG
```

all producers share one event counter and one ordering domain.

A different source name could theoretically use an independent counter and independent lock scope.

This allows separate streams to progress independently.

---

### Single Global Order Within the Stream

Because the laboratory uses one counter for:

```text
PRODUCT_PRICE_LOG
```

all events receive one total order:

```text
1001
1002
1003
1004
...
```

This makes consumer processing simple:

```text
one LAST_SEQ
one ORDER BY EVENT_SEQ
one high-water mark
```

The cost is producer serialization.

---

### Scalability Trade-Off

A single serialized event counter may become a bottleneck at high event volume.

Potential production alternatives include:

```text
database-native CDC
log sequence numbers
partitioned event streams
transactional outbox processing
message-broker offsets
```

Such systems may provide stronger scalability while preserving ordering within defined partitions.

The laboratory intentionally uses a simpler model because the goal is to make the correctness requirement directly observable.

---

### Partitioned Ordering

A scalable system may not require one global order.

For example:

```text
Partition A:
1
2
3

Partition B:
1
2
3
```

Each partition could have its own consumer pointer.

However, a consumer could no longer use one global:

```text
LAST_SEQ
```

for the complete source.

It would need:

```text
LAST_SEQ_A
LAST_SEQ_B
```

or equivalent partition-aware state.

This complexity is outside the current project scope.

---

### All Producers Must Follow the Protocol

The lock guarantee is only as strong as producer compliance.

Every writer that publishes events to:

```text
PRODUCT_PRICE_LOG
```

must use the same protocol.

If one producer bypasses:

```text
EZDBEVCOUNT
```

and directly writes a later event, the ordering invariant can be broken.

Therefore the source-side contract includes:

```text
All producers of one logical event stream
must use the same sequence-allocation
and publication-order protocol.
```

---

### Consumer Benefit

Because the producer guarantees commit-consistent ordering, the consumer does not need:

```text
upper safety intervals
lower overlap
time-based boundary heuristics
```

The consumer can use the exact sequence condition:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

and safely advance:

```text
LAST_SEQ
```

after successful persistence.

The complexity has moved from consumer boundary logic to producer publication discipline.

---

### Result of the Laboratory Experiment

The concurrency experiment starts with:

```text
LAST_EVENT_SEQ = 1001
```

Session A:

```text
acquires EZDBEVCOUNT
allocates 1002
prepares business change
writes event 1002
pauses before COMMIT
```

Session B:

```text
attempts to acquire EZDBEVCOUNT
fails because Session A still holds the lock
does not allocate 1003
```

Session A:

```text
COMMIT
release lock
```

Session B retries:

```text
reads LAST_EVENT_SEQ = 1002
allocates 1003
COMMIT
```

The final committed stream is:

```text
1002
1003
```

in the same order in which the events became visible.

---

### Core Conclusion

Safe sequence-based delta requires more than:

```text
monotonically increasing EVENT_SEQ
```

It requires:

```text
monotonic event identity
+
transactional producer atomicity
+
commit-consistent publication ordering
```

The lock object:

```text
EZDBEVCOUNT
```

provides the ordering part of that contract for the laboratory.

The resulting guarantee is:

```text
A higher EVENT_SEQ cannot become visible
while a lower required EVENT_SEQ
is still transactionally unresolved.
```

That guarantee is what makes:

```text
LAST_SEQ
```

a safe consumer high-water mark.
