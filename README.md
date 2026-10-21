# ABAP Cloud Database Acquisition Lab

ABAP Cloud laboratory for studying database acquisition and generic delta semantics.

## Purpose

This project explores the reliability properties of database-based data acquisition.

The focus is not on reproducing the SAP BW DB Connect runtime, but on studying the source-side and consumer-side semantics that determine whether a database delta is reliable.

The laboratory covers:

- full extraction;
- numeric delta based on a creation sequence;
- timestamp-based delta;
- delayed COMMIT and transaction visibility;
- upper and lower safety intervals;
- physical and soft deletes;
- transactional change logs;
- monotonic event sequencing;
- producer concurrency;
- consumer restart;
- transactional rollback and recovery.

The project was built in SAP BTP ABAP Environment and uses local ABAP Cloud tables to simulate an external database source.

## Scope and Limitations

This project does **not** implement SAP BW DB Connect.

It does not contain:

- a DB Connect source system;
- BW DataSources;
- InfoPackages;
- PSA runtime;
- DTPs;
- ADSOs;
- Process Chains;
- a real external Oracle, SQL Server, DB2, PostgreSQL, or other remote database connection.

Instead, `ZDB_SRC_PRICE` acts as a controlled current-state source table so that delta behavior can be reproduced and tested deterministically.

The project concentrates on the semantic boundary:

```text
database source
      |
      v
delta extraction logic
      |
      v
acquisition persistence
```

## Architecture

The laboratory uses `ZDB_SRC_PRICE` as a controlled current-state source table that represents an external database table or view.

Two alternative delta architectures are implemented on top of this source:

1. **Timestamp-based delta**
2. **Transactional change-log delta**

Both approaches persist extracted data in `ZDB_ACQ_PRICE`, which acts as a lightweight acquisition-history layer for the laboratory.

```mermaid
flowchart TD

    SRC["ZDB_SRC_PRICE<br>Current-state source simulator"]
    FULL["Full extraction"]
    TS["Timestamp delta<br>CHANGED_AT"]
    SAFE["Upper / Lower Safety Intervals"]
    SOFT["Soft delete<br>IS_DELETED"]

    PROD["Transactional producer"]
    CNT["ZDB_EVENT_COUNT<br>EVENT_SEQ allocation"]
    LOG["ZDB_CHANGE_LOG<br>I / U / D events"]

    ACQ["ZDB_ACQ_PRICE<br>Acquisition history"]
    CONS["Change-log consumer<br>EVENT_SEQ &gt; LAST_SEQ"]

    STATE["ZDB_DELTA_STATE<br>Consumer delta pointers"]

    SRC --> FULL
    SRC --> TS
    TS --> SAFE
    SRC --> SOFT

    SRC --> PROD
    PROD --> CNT
    PROD --> LOG

    FULL --> ACQ
    TS --> ACQ
    SAFE --> ACQ
    SOFT --> ACQ

    LOG --> CONS
    CONS --> ACQ

    STATE --> TS
    STATE --> SAFE
    STATE --> CONS
```

## Experiments

The project is organized around a sequence of controlled experiments.

Each experiment starts from a simple acquisition strategy, introduces a specific source-side or transaction failure mode, and observes whether the consumer can still advance its delta pointer without losing data.


### 1. Full Extraction

The initial baseline reads the complete current-state source table:

```text
ZDB_SRC_PRICE
      |
      | FULL SELECT
      v
ZDB_ACQ_PRICE

```

### 2. Numeric Delta on a Current-State Table

The first delta strategy uses the monotonically increasing source field `CREATED_SEQ`.

The consumer stores the last successfully processed value in `LAST_SEQ` and reads only rows satisfying:

```text
CREATED_SEQ > LAST_SEQ
```

The source is initially prepared with the following current-state records:

```text
P1001/SOUTH  CREATED_SEQ = 1001
P1002/SOUTH  CREATED_SEQ = 1002
P1003/SOUTH  CREATED_SEQ = 1003
P1001/NORTH  CREATED_SEQ = 1004
```

The numeric delta pointer is then initialized to:

```text
LAST_SEQ = 1004
```

Two source changes are performed in one transaction.

A new row is inserted:

```text
P1004/SOUTH
PRICE       = 40.00
CREATED_SEQ = 1005
```

An existing row is also updated:

```text
P1001/SOUTH
PRICE       10.00 -> 12.00
CREATED_SEQ remains 1001
```

The numeric delta reader selects:

```text
CREATED_SEQ > 1004
```

and therefore returns only:

```text
P1004/SOUTH
CREATED_SEQ = 1005
```

The update of `P1001/SOUTH` is not detected because its creation sequence does not change.

Result:

```text
INSERT -> detected
UPDATE -> not detected
```

The experiment demonstrates that a monotonically increasing creation sequence is suitable for append-only acquisition, but is not sufficient for a mutable current-state table.

The important distinction is:

```text
CREATED_SEQ
= identity/order of row creation

not

= identity/order of every business change
```

After the successful acquisition, the consumer pointer advances from:

```text
LAST_SEQ = 1004
```

to:

```text
LAST_SEQ = 1005
```

Only data actually persisted in the acquisition layer is allowed to advance the pointer.
### 3. Timestamp Delta

The second delta strategy uses the source field `CHANGED_AT`.

Unlike `CREATED_SEQ`, this field is updated whenever a relevant source row is inserted or changed.

The source is first prepared with a common baseline timestamp:

```text
CHANGED_AT = T0
```

for all existing rows.

The timestamp delta pointer is then initialized to:

```text
LAST_CHANGED_AT = T0
```

Two source changes are performed in one transaction.

An existing row is updated:

```text
P1001/SOUTH
PRICE       12.00 -> 13.00
CREATED_SEQ remains 1001
CHANGED_AT  = T1
```

A new row is also inserted:

```text
P1005/SOUTH
PRICE       = 50.00
CREATED_SEQ = 1006
CHANGED_AT  = T1
```

Both changes intentionally receive the same timestamp.

The timestamp delta reader selects:

```text
CHANGED_AT > LAST_CHANGED_AT
```

and therefore returns both rows:

```text
P1001/SOUTH
PRICE      = 13.00
CHANGED_AT = T1

P1005/SOUTH
PRICE      = 50.00
CHANGED_AT = T1
```

Result:

```text
INSERT -> detected
UPDATE -> detected
```

The important difference from the numeric creation-sequence delta is that the existing row `P1001/SOUTH` is detected even though:

```text
CREATED_SEQ = 1001
```

remains unchanged.

The delta criterion is now based on the time of the latest relevant modification rather than on the time or order of row creation.

The experiment demonstrates that timestamp-based delta can detect both inserts and updates on a mutable current-state table, provided that the source reliably updates `CHANGED_AT` for every relevant business change.

After the successful acquisition, the consumer pointer advances from:

```text
LAST_CHANGED_AT = T0
```

to:

```text
LAST_CHANGED_AT = T1
```

The implementation stores the acquired rows and advances the timestamp pointer in the same database transaction.

At this stage the algorithm is intentionally naive:

```text
CHANGED_AT > LAST_CHANGED_AT
```

No safety interval is used yet.

This makes the reader suitable for demonstrating the next failure mode: a source change may receive an earlier `CHANGED_AT` value but become visible only after a delayed `COMMIT`, allowing the consumer pointer to advance past it.

### 4. Delayed COMMIT Failure

A two-session experiment is used to demonstrate a failure mode of the naive timestamp-delta algorithm.

The consumer currently uses:

```text
CHANGED_AT > LAST_CHANGED_AT
```

with no safety interval.

The initial consumer pointer is:

```text
LAST_CHANGED_AT = T0
```

In Session B, an existing source row is updated:

```text
P1002/SOUTH
PRICE       20.00 -> 23.00
CHANGED_AT  = T1
```

The transaction is intentionally paused before `COMMIT`.

At this point the row has already received `CHANGED_AT = T1`, but the updated version is not yet visible to other sessions.

While Session B is still uncommitted, Session A inserts another row and commits immediately:

```text
P1008/SOUTH
PRICE       = 80.00
CHANGED_AT  = T2
```

with:

```text
T1 < T2
```

The naive timestamp reader runs in Session A.

It can see the committed row at `T2`, but it cannot see the still-uncommitted update at `T1`.

The reader therefore selects:

```text
P1008/SOUTH
CHANGED_AT = T2
```

and advances the consumer pointer to:

```text
LAST_CHANGED_AT = T2
```

Session B is then resumed and commits the older change:

```text
P1002/SOUTH
CHANGED_AT = T1
```

The row is now committed and visible, but its timestamp is already behind the consumer pointer:

```text
T1 < LAST_CHANGED_AT = T2
```

The next timestamp-delta request uses:

```text
CHANGED_AT > T2
```

and therefore does not select `P1002/SOUTH`.

Result:

```text
P1008/SOUTH -> acquired
P1002/SOUTH -> permanently missed
```

The failure is not caused by an incorrect source timestamp.

`P1002/SOUTH` received a valid `CHANGED_AT = T1` before the transaction committed.

The problem is that:

```text
time of change
!=
time at which the change becomes visible to the extractor
```

The experiment demonstrates that a naive timestamp delta can lose committed source changes when transaction visibility is delayed.

The critical sequence is:

```text
T1
P1002 updated
CHANGED_AT = T1
transaction still uncommitted

T2
P1008 inserted and committed

consumer reads source
P1008 is visible
P1002 is not visible

consumer pointer -> T2

later
P1002 commits with CHANGED_AT = T1

next request:
CHANGED_AT > T2

P1002 is never selected
```

Changing the selection condition from:

```text
CHANGED_AT > LAST_CHANGED_AT
```

to:

```text
CHANGED_AT >= LAST_CHANGED_AT
```

does not solve this failure mode because:

```text
T1 < T2
```

rather than:

```text
T1 = T2
```

This experiment motivates the use of an upper safety interval.


### 5. Upper Safety Interval

The delayed-COMMIT experiment shows that a naive timestamp delta can advance its pointer beyond a source change that is still uncommitted and therefore temporarily invisible.

To reduce this risk, the safer timestamp reader introduces an upper safety interval.

Instead of reading up to the current request time, the reader defines:

```text
UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

For example:

```text
REQUEST_START          = 12:30:00
UPPER_SAFETY_INTERVAL  = 00:05:00

UPPER_BOUND            = 12:25:00
```

The consumer then reads only:

```text
LAST_CHANGED_AT < CHANGED_AT <= UPPER_BOUND
```

All source changes newer than `UPPER_BOUND` remain temporarily outside the extraction window.

This creates a deliberate safety zone:

```text
                         safety zone
                             |
                             v
-----------------------------|-------------------->
                       UPPER_BOUND           REQUEST_START
```

The delayed-COMMIT experiment is repeated.

Session B performs:

```text
P1002/SOUTH
PRICE       20.00 -> 23.00
CHANGED_AT  = T1
```

and pauses before `COMMIT`.

Session A then inserts and commits:

```text
P1008/SOUTH
PRICE       = 80.00
CHANGED_AT  = T2
```

with:

```text
T1 < T2
```

Both timestamps are still inside the upper safety zone when the safe reader runs.

Therefore the reader does not select either row yet.

Instead, it advances the persistent pointer only to the safe upper boundary:

```text
LAST_CHANGED_AT = UPPER_BOUND
```

The important difference from the naive reader is that the pointer is no longer derived from:

```text
MAX(CHANGED_AT) of currently visible rows
```

It represents:

```text
the latest time boundary that has been safely scanned
```

Session B is then allowed to commit.

After enough time has passed, the next request calculates a later `UPPER_BOUND`.

Both source changes now fall inside the safe extraction interval:

```text
LAST_CHANGED_AT < T1 <= UPPER_BOUND
LAST_CHANGED_AT < T2 <= UPPER_BOUND
```

and both rows are acquired successfully.

Result:

```text
Naive timestamp delta
-> late-committed row lost

Timestamp delta with upper safety
-> late-committed row acquired later
```

The experiment demonstrates that the upper safety interval protects the consumer from advancing too close to the current time, where source transactions may still be incomplete.

The trade-off is additional latency:

```text
larger upper safety interval
-> stronger protection against delayed visibility
-> older data delivered to the consumer
```

The configured interval must therefore be compatible with the source transaction behavior.

For the timestamp architecture to be reliable, the delay between:

```text
assigning CHANGED_AT
and
the transaction becoming committed and visible
```

must be bounded.

The upper safety interval must be large enough to cover that expected visibility lag.

If source transactions can remain uncommitted for an arbitrarily long time, no finite upper safety interval can provide a strict lossless guarantee.

This limitation is one of the main differences between timestamp-based delta and the transactional change-log architecture explored later in the project.

### 6. Lower Safety Interval

The upper safety interval protects the consumer from reading too close to the current time.

A lower safety interval addresses a different problem: it intentionally re-reads part of the time range that was already considered processed.

Without a lower safety interval, the next request starts strictly after the persistent pointer:

```text
LAST_CHANGED_AT < CHANGED_AT <= UPPER_BOUND
```

With a lower safety interval, the reader calculates:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

and reads:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

For example:

```text
LAST_CHANGED_AT        = 10:04:51
LOWER_SAFETY_INTERVAL  = 00:05:00

LOWER_BOUND            = 09:59:51
```

The interval:

```text
09:59:51 < CHANGED_AT <= 10:04:51
```

has already been covered by an earlier request, but it is intentionally read again.

This creates an overlap between consecutive extraction windows:

```text
Previous request
-----------------------------> LAST_CHANGED_AT
                         |
                         | already scanned
                         |
                  <------+
                  overlap
                  |
                  v
LOWER_BOUND ------------------------------> new UPPER_BOUND
               Next request
```

The persistent pointer itself is **not** moved backwards.

`LOWER_BOUND` is only a temporary selection boundary.

After the request completes successfully, the pointer still advances forward to the new safe upper boundary:

```text
LAST_CHANGED_AT = UPPER_BOUND
```

In the laboratory, previously acquired rows such as:

```text
P1002/SOUTH
P1008/SOUTH
```

fall inside the lower overlap and are therefore selected again in a later acquisition run.

Result:

```text
same business after-image
-> acquired in more than one run
```

This duplicate acquisition is intentional.

For after-image semantics, repeated delivery is normally safe.

For example, if the consumer receives:

```text
P1002/SOUTH
PRICE = 23.00
```

twice, the downstream state remains:

```text
PRICE = 23.00
```

The second delivery overwrites the target with the same state.

The important principle is:

```text
controlled duplicate delivery
is preferable to
an irreversible delta gap
```

This makes lower safety particularly suitable for after-image based acquisition.

However, the same approach would require additional protection for additive semantics.

For example:

```text
SALES_AMOUNT += 100
```

applied twice would incorrectly produce:

```text
SALES_AMOUNT += 200
```

Therefore overlap safety must always be evaluated together with the downstream record semantics.

The lower safety interval complements the upper safety interval:

```text
Upper safety
-> delays very recent changes
-> avoids advancing too close to unfinished source transactions

Lower safety
-> re-reads a small part of the already scanned past
-> creates controlled overlap and duplicate acquisition
```

Together they define the effective timestamp extraction window:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

where:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL

UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

The laboratory uses five-minute values for both intervals only to make the experiments easy to reproduce.

These values are not production recommendations.

In a real implementation, the intervals must be chosen according to the source transaction and visibility behavior.

Lower safety also does not remove the fundamental requirement that source visibility lag must be bounded.

If a transaction becomes visible only after the consumer has moved beyond both:

```text
the upper safety zone
and
the lower overlap window
```

the timestamp-based architecture can still lose the change.

The experiment therefore demonstrates that safety intervals reduce the risk of timestamp-boundary failures, but they do not replace a reliable source-side timing contract.

### 7. Physical vs Soft Delete

Timestamp-based delta reads changes from the current-state source table by evaluating `CHANGED_AT`.

This creates an important problem for physical deletes.

A physical delete removes the source row completely:

```text
DELETE FROM source
WHERE PRODUCT_ID = 'P1003'
  AND STORE_GROUP = 'SOUTH'
```

After the delete, the row no longer exists in `ZDB_SRC_PRICE`.

The timestamp reader can only select rows that are still present:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

but a physically deleted row has no remaining `CHANGED_AT` value to evaluate.

The experiment performs a physical delete of:

```text
P1003/SOUTH
```

Result:

```text
source row removed
timestamp delta selects 0 rows
consumer receives no deletion information
```

The delta pointer can still move forward normally, even though a real business change has occurred.

This demonstrates an important limitation of current-state timestamp delta:

```text
INSERT -> visible
UPDATE -> visible
physical DELETE -> invisible
```

The problem is not caused by the timestamp value.

The problem is that the source row no longer exists.

To make deletion visible to timestamp delta, the project uses a soft-delete convention.

The deleted business object remains physically present in the source table and is marked with:

```text
IS_DELETED = 'X'
```

At the same time:

```text
CHANGED_AT = current timestamp
```

is assigned.

The source row therefore becomes an ordinary changed after-image:

```text
P1003/SOUTH
PRICE       = 30.00
IS_DELETED  = X
CHANGED_AT  = T1
```

The timestamp reader can now select the row normally:

```text
LOWER_BOUND < T1 <= UPPER_BOUND
```

and the acquisition layer receives the deletion marker.

Result:

```text
Soft DELETE
-> source row remains
-> CHANGED_AT changes
-> timestamp delta detects the row
-> IS_DELETED carries deletion semantics downstream
```

The deletion marker can then be propagated through later storage layers and interpreted according to the contract of each layer.

For example:

```text
IS_DELETED = ''
-> insert or update current business state

IS_DELETED = 'X'
-> delete, deactivate, or close validity
```

The important distinction is:

```text
CHANGED_AT
= tells the consumer that the row changed

IS_DELETED
= tells the consumer what the change means
```

The soft-delete approach fits naturally with timestamp-based after-image acquisition because the deletion marker travels together with the source row.

The trade-off is that deleted business objects must remain physically stored as tombstone records until they can be safely archived or removed according to a separate retention policy.

The experiment therefore demonstrates:

```text
Physical DELETE
-> invisible to current-state timestamp delta

Soft DELETE
-> visible as a normal timestamped after-image
```

This is the deletion strategy used by the timestamp-based architecture in this laboratory.

A different solution is explored later with the transactional change-log architecture, where physical deletes are represented explicitly as `D` events and no tombstone row is required in the current-state table.

### 8. Transactional Change Log

The second delta architecture does not derive changes from the current-state table.

Instead, every relevant business change is recorded explicitly in a separate transactional change log.

The source still maintains the current business state in:

```text
ZDB_SRC_PRICE
```

but changes are additionally written to:

```text
ZDB_CHANGE_LOG
```

Each log entry contains:

```text
EVENT_SEQ
PRODUCT_ID
STORE_GROUP
OPERATION
PRICE
CURRENCY
EVENT_AT
```

The operation field describes the business event:

```text
I = INSERT
U = UPDATE
D = DELETE
```

Unlike `CREATED_SEQ` in the current-state table, `EVENT_SEQ` identifies a change event rather than a business object.

For example:

```text
1001  P1010  SOUTH  I  100.00
1002  P1001  SOUTH  U   14.00
1003  P1011  SOUTH  I  110.00
1004  P1010  SOUTH  D
```

This allows multiple changes to the same business key to be represented independently and in order.

The producer maintains the next event number in:

```text
ZDB_EVENT_COUNT
```

The important requirement is that the following three operations belong to the same database transaction:

```text
1. Advance the event counter
2. Apply the business change to ZDB_SRC_PRICE
3. Insert the corresponding event into ZDB_CHANGE_LOG
```

The producer therefore follows the pattern:

```text
lock event counter
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
apply INSERT / UPDATE / DELETE to ZDB_SRC_PRICE
        |
        v
insert I / U / D event into ZDB_CHANGE_LOG
        |
        v
COMMIT
        |
        v
release lock
```

If any database operation fails before `COMMIT`, the entire producer LUW is rolled back.

The business state, event counter, and change log therefore remain consistent.

For example, an update is represented as:

```text
Current state:

P1001/SOUTH
PRICE = 14.00
```

together with:

```text
Change log:

1002
P1001/SOUTH
OPERATION = U
PRICE     = 14.00
```

A physical delete can also be represented explicitly.

The current-state row is removed:

```text
P1010/SOUTH
-> physically deleted from ZDB_SRC_PRICE
```

while the same transaction writes:

```text
1004
P1010/SOUTH
OPERATION = D
```

to `ZDB_CHANGE_LOG`.

This means that the current-state table does not need to retain a tombstone row for the deleted object.

The consumer has its own independent delta pointer in:

```text
ZDB_DELTA_STATE
```

For the change-log source:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
LAST_SEQ    = last successfully acquired EVENT_SEQ
```

The consumer reads:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

The first consumer run in the laboratory starts with:

```text
LAST_SEQ = 1000
```

and acquires:

```text
1001  P1010  I
1002  P1001  U
1003  P1011  I
```

The consumer then advances:

```text
LAST_SEQ = 1003
```

A later physical delete creates:

```text
1004  P1010  D
```

and the same unchanged consumer logic acquires it using:

```text
EVENT_SEQ > 1003
```

Result:

```text
INSERT -> explicit I event
UPDATE -> explicit U event
DELETE -> explicit D event
```

The important architectural difference from timestamp delta is that the consumer no longer infers change semantics from the current-state table.

Instead, the source publishes an ordered event stream.

The delta criterion becomes:

```text
EVENT_SEQ > LAST_SEQ
```

rather than:

```text
CHANGED_AT > LAST_CHANGED_AT
```

This removes the need for timestamp safety windows, provided that event sequencing and transaction commit order are kept consistent.

The reliability of this architecture therefore depends on a different contract:

```text
Timestamp delta
-> correctness depends on a bounded timing / visibility contract

Transactional change log
-> correctness depends on transactional coupling
   and ordered event publication
```

The following experiments test these requirements explicitly:
producer concurrency, consumer restart, and rollback when change-log persistence fails.

### 9. Producer Concurrency

A monotonically increasing `EVENT_SEQ` is not sufficient by itself.

The sequence must also remain consistent with the order in which producer transactions become committed and visible.

Without synchronization, two producer sessions could behave like this:

```text
Session A
allocate EVENT_SEQ = 1002
business change prepared
log event prepared
COMMIT delayed
```

while another session continues:

```text
Session B
allocate EVENT_SEQ = 1003
business change prepared
log event prepared
COMMIT immediately
```

This would create the dangerous situation:

```text
1003 committed and visible
while
1002 is still uncommitted
```

A consumer using:

```text
EVENT_SEQ > LAST_SEQ
```

could then read `1003`, advance its pointer, and permanently skip `1002` when Session A commits later.

Therefore event allocation must be serialized.

The project uses the lock object:

```text
EZDBEVCOUNT
```

to protect the counter row in:

```text
ZDB_EVENT_COUNT
```

for:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
```

The producer acquires the lock before reading and advancing the event counter.

The lock is held until after the complete producer transaction is committed.

The producer sequence is therefore:

```text
ENQUEUE EZDBEVCOUNT
        |
        v
read LAST_EVENT_SEQ
        |
        v
allocate next EVENT_SEQ
        |
        v
update event counter
        |
        v
apply business change
        |
        v
insert change-log event
        |
        v
COMMIT
        |
        v
DEQUEUE
```

A two-session experiment verifies this behavior.

Session A acquires the lock and allocates:

```text
EVENT_SEQ = 1002
```

It then prepares the business update and change-log event but pauses before `COMMIT`.

At this point:

```text
counter change      -> uncommitted
business change     -> uncommitted
change-log event    -> uncommitted
counter lock        -> still held
```

While Session A is paused, Session B attempts to produce another event.

Session B cannot acquire `EZDBEVCOUNT` and receives a foreign-lock condition.

It does not receive a new event number and does not change:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

Session A is then resumed and commits event `1002`.

Only after the lock is released can Session B run again.

The second attempt succeeds and allocates:

```text
EVENT_SEQ = 1003
```

The observed order is therefore:

```text
allocation order:
1002 -> 1003

commit order:
1002 -> 1003

visibility order:
1002 -> 1003
```

The dangerous order:

```text
1003 committed before 1002
```

cannot occur as long as all producers follow the same lock protocol.

The experiment demonstrates an important property:

```text
monotonic numbering alone
is not enough
```

What is required is:

```text
monotonic EVENT_SEQ
+
producer serialization
+
transactional commit ordering
```

Only then can `EVENT_SEQ` be used safely as a high-water-mark delta pointer.

The reliability contract therefore includes the rule:

```text
Every producer that writes to PRODUCT_PRICE_LOG
must acquire EZDBEVCOUNT before allocating EVENT_SEQ.
```

If any producer bypasses this protocol and writes directly to the event counter or change log, the ordering guarantee is lost.

### 10. Consumer Restart

The change-log consumer maintains its own independent pointer:

```text
ZDB_DELTA_STATE
SOURCE_NAME = PRODUCT_PRICE_LOG
LAST_SEQ    = last successfully acquired EVENT_SEQ
```

The consumer reads committed events using:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

and then performs two persistence steps in the same database LUW:

```text
1. Persist acquired events in ZDB_ACQ_PRICE
2. Advance consumer LAST_SEQ
```

Only after both operations succeed is:

```text
COMMIT WORK
```

executed.

This creates an important restart invariant:

```text
acquisition persistence
+
consumer pointer advancement
=
one atomic transaction
```

The laboratory verifies this by intentionally interrupting the consumer after the acquired events have been inserted into `ZDB_ACQ_PRICE`, but before the consumer pointer is updated and before `COMMIT`.

Before the experiment, the consumer state is:

```text
LAST_SEQ = 1004
```

and the producer has already committed two later events:

```text
1005  P1001/SOUTH  U  14.00
1006  P1001/SOUTH  U  15.00
```

The consumer selects both events:

```text
EVENT_SEQ > 1004
```

and prepares them for persistence in one acquisition run.

Execution is then intentionally terminated before the final commit.

Because the LUW has not been committed, the partial consumer work is rolled back.

After termination:

```text
ZDB_CHANGE_LOG
-> events 1005 and 1006 still exist

ZDB_ACQ_PRICE
-> no committed acquisition rows for 1005 and 1006

ZDB_DELTA_STATE
-> LAST_SEQ remains 1004
```

This is the required restart-safe state.

The producer events remain durable because they were committed independently before the consumer started.

The consumer pointer also remains unchanged because the failed consumer LUW never committed.

The same consumer is then started again.

It again selects:

```text
1005
1006
```

using:

```text
EVENT_SEQ > 1004
```

The retry succeeds and commits both the acquired events and the new pointer.

The final state becomes:

```text
ZDB_ACQ_PRICE
-> 1005 persisted
-> 1006 persisted

ZDB_DELTA_STATE
-> LAST_SEQ = 1006
```

Result:

```text
consumer interrupted before COMMIT
        |
        v
acquisition rows rolled back
consumer pointer unchanged
        |
        v
same committed source events selected again
        |
        v
successful retry
        |
        v
events persisted
pointer advanced
```

The experiment demonstrates that the consumer can safely restart after an interrupted acquisition without losing committed events.

The critical rule is:

```text
Never advance the consumer pointer
before the corresponding acquired data
has been successfully persisted.
```

If the implementation instead performed:

```text
advance LAST_SEQ
COMMIT

then later

persist acquired events
```

a crash between these steps could permanently lose events.

The project therefore uses the opposite order:

```text
persist events
        |
        v
advance LAST_SEQ
        |
        v
COMMIT both together
```

This gives the consumer replay semantics:

```text
before COMMIT
-> the same events may be read again

after COMMIT
-> the pointer moves past them
```

The change log therefore acts as the durable replay source, while `LAST_SEQ` represents only the highest event sequence that the consumer has successfully committed to its acquisition layer.

### 11. Producer Rollback on Log Failure

The transactional change-log producer must keep three source-side changes consistent:

```text
1. Advance ZDB_EVENT_COUNT
2. Apply the business change to ZDB_SRC_PRICE
3. Insert the corresponding event into ZDB_CHANGE_LOG
```

All three operations are executed in the same database LUW.

The intended producer pattern is:

```text
lock event counter
        |
        v
allocate EVENT_SEQ
        |
        v
update ZDB_EVENT_COUNT
        |
        v
apply business change
        |
        v
insert event into ZDB_CHANGE_LOG
        |
        v
COMMIT
```

If the change-log insert fails, the producer must not leave either the business row or the event counter in a partially updated state.

The laboratory verifies this requirement by creating a deliberate duplicate-key conflict for the next event sequence.

Assume the current producer counter is:

```text
LAST_EVENT_SEQ = 1006
```

The failure-preparation class inserts an artificial conflict record:

```text
EVENT_SEQ   = 1007
PRODUCT_ID  = PFAIL
STORE_GROUP = TEST
```

into `ZDB_CHANGE_LOG`.

The producer counter itself remains unchanged:

```text
LAST_EVENT_SEQ = 1006
```

The normal producer is then started.

It acquires the counter lock and allocates:

```text
EVENT_SEQ = 1007
```

Within the same LUW it performs:

```text
ZDB_EVENT_COUNT
1006 -> 1007
```

and applies the business change:

```text
P1001/SOUTH
PRICE 15.00 -> 16.00
```

The producer then attempts to insert the real event:

```text
1007
P1001/SOUTH
OPERATION = U
PRICE     = 16.00
```

into `ZDB_CHANGE_LOG`.

This insert fails because the artificial record already occupies the primary key for:

```text
PRODUCT_PRICE_LOG + EVENT_SEQ 1007
```

The producer error branch executes:

```text
ROLLBACK WORK
```

The complete producer LUW is therefore reversed.

After the rollback:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1006
```

The business row is restored:

```text
P1001/SOUTH
PRICE = 15.00
```

and the real change-log event is not created.

The only remaining `1007` row is the artificial conflict record that had been committed before the producer transaction started.

Result:

```text
counter update
+
business update
+
change-log insert failure
        |
        v
ROLLBACK
        |
        +--> counter restored
        +--> business state restored
        +--> real event not created
```

The artificial conflict is then removed by the cleanup class.

The producer is started again.

Because the failed transaction did not commit the counter advancement, the producer allocates the same sequence again:

```text
EVENT_SEQ = 1007
```

The retry now succeeds:

```text
ZDB_EVENT_COUNT
1006 -> 1007

ZDB_SRC_PRICE
P1001/SOUTH
15.00 -> 16.00

ZDB_CHANGE_LOG
1007  P1001/SOUTH  U  16.00
```

The consumer subsequently reads:

```text
EVENT_SEQ > 1006
```

and acquires event `1007` normally.

This experiment demonstrates that producer reliability depends on keeping:

```text
event-sequence allocation
+
business change
+
change-log event
```

inside the same database transaction.

The event counter must not be committed independently from the business change or the log event.

Otherwise a failure could create states such as:

```text
counter advanced
but
business change rolled back
```

or:

```text
business change committed
but
change-log event missing
```

Either case would break the reliability of the delta stream.

The lock object and the database transaction therefore serve different purposes:

```text
EZDBEVCOUNT
-> preserves producer ordering across concurrent sessions

COMMIT / ROLLBACK
-> preserves atomic consistency of counter, business state, and log event
```

Together they provide the source-side guarantee required for reliable `EVENT_SEQ`-based acquisition.

## Timestamp Delta vs Transactional Change Log

The laboratory implements two different approaches to reliable database delta acquisition:

1. timestamp-based delta on a mutable current-state table;
2. transactional change-log delta based on an ordered event stream.

Both approaches can be correct, but they rely on different source-side contracts.

| Criterion | `CHANGED_AT + IS_DELETED` | Transactional Change Log |
|---|---|---|
| **Correctness foundation** | Timing contract: `CHANGED_AT` and configured safety intervals must cover the delay until a change becomes committed and visible | Transaction and ordering contract: business change and log event are committed atomically, and events are published in commit-consistent sequence order |
| **Dependency on source transaction duration** | Yes. Safety intervals must be large enough to cover the maximum expected commit / visibility lag | For delta correctness, effectively no dependency on transaction duration |
| **Arbitrarily long delayed COMMIT** | No finite safety interval can provide a strict guarantee if visibility lag is unbounded | The event remains invisible until commit and cannot be skipped by a later event when producer ordering is enforced |
| **Protection cost** | Additional latency and intentional overlap | More complex producer logic, event log maintenance, and serialized event-sequence allocation |
| **INSERT** | Detected through a new `CHANGED_AT` value | Explicit `I` event |
| **UPDATE** | Detected if every relevant update changes `CHANGED_AT` | Explicit `U` event |
| **Physical DELETE** | Not visible because the source row disappears | Explicit `D` event |
| **Delete strategy** | Requires `IS_DELETED` or another tombstone convention | Physical delete can be represented directly as a `D` event |
| **Ordering** | Time-based ordering; multiple changes may share the same timestamp and commit visibility may differ from timestamp order | Explicit ordering through `EVENT_SEQ` |
| **Safety intervals** | Required when transaction visibility may lag behind `CHANGED_AT` | Not required for normal delta correctness when event ordering and transactional coupling are guaranteed |
| **Duplicate acquisition** | Expected when lower safety creates overlap | Normally not required with strict sequence-based consumption |
| **Consumer pointer** | Safe time boundary in `LAST_CHANGED_AT` | Last successfully acquired event in `LAST_SEQ` |
| **Replay source** | Current-state table plus safety overlap | Durable ordered change log |
| **Operation history** | Limited to the current after-image and retained tombstones | Explicit sequence of `I`, `U`, and `D` events |
| **Producer complexity** | Relatively low | Higher: counter, locking, transactional log write, and ordering discipline |
| **Consumer complexity** | More complex time-window logic | Simpler ordered sequence consumption |
| **Cleanup / retention** | Tombstone and historical-row retention must be managed | Change-log retention must be managed without deleting events still required by consumers |

The central difference is the basis on which correctness is established.

Timestamp delta relies on time:

```text
source change
    |
    v
CHANGED_AT assigned
    |
    | bounded delay required
    v
COMMIT / visibility
```

The consumer must choose safety intervals large enough to ensure that a row cannot become visible only after the extraction pointer has already moved beyond its timestamp.

This works well when the source can guarantee a bounded transaction or visibility delay.

However, if that delay can grow unpredictably because of:

```text
long-running transactions
database locks
batch processing
external dependencies
system load
```

then choosing a practical upper safety interval becomes difficult.

A larger interval improves protection but also increases acquisition latency.

A lower safety interval can re-read part of the past and reduce boundary risk, but it still depends on a finite overlap window.

Therefore:

```text
timestamp-delta reliability
depends on a bounded timing contract
```

The transactional change-log approach replaces this timing dependency with an ordering guarantee.

A business transaction performs:

```text
allocate EVENT_SEQ
+
change current-state data
+
write change-log event
+
COMMIT
```

while the event counter remains protected from competing producers.

As a result, a later event cannot become visible before an earlier uncommitted event has completed.

The consumer only needs:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

and does not need to know how long the producer transaction took.

Therefore:

```text
change-log reliability
depends on transactional coupling
and commit-consistent event ordering
```

This makes the change-log architecture more robust when transaction duration or commit visibility cannot be bounded reliably.

The trade-off is increased source-side complexity.

The project therefore does not treat one architecture as universally superior.

A practical decision can be summarized as:

```text
Use CHANGED_AT + IS_DELETED
when:
- the source is a current-state table;
- updates reliably maintain CHANGED_AT;
- delete tombstones are acceptable;
- transaction visibility lag is bounded;
- moderate overlap and duplicate after-images are acceptable.

Use a transactional change log
when:
- explicit I / U / D events are required;
- physical deletes must be propagated;
- strict event ordering is important;
- transaction duration may be unpredictable;
- the source can maintain a durable ordered event stream transactionally.
```

The laboratory demonstrates that the main design question is not simply:

```text
timestamp or sequence?
```

but rather:

```text
What guarantee allows the consumer
to advance its delta pointer
without losing a committed source change?

## Data Model

## Data Model

The laboratory uses a small set of ABAP Cloud database tables to separate:

```text
current source state
acquisition history
consumer delta state
producer event sequencing
transactional change history
```

This separation is intentional.

Each table represents a different responsibility in the acquisition process.

### ZDB_SRC_PRICE — Current-State Source

`ZDB_SRC_PRICE` simulates a mutable table or view in an external database.

Its business key is:

```text
PRODUCT_ID
+
STORE_GROUP
```

Main fields:

```text
PRODUCT_ID
STORE_GROUP
PRICE
CURRENCY
CREATED_SEQ
CHANGED_AT
IS_DELETED
```

Example:

```text
P1001  SOUTH  16.00  EUR  1001  <timestamp>  ''
P1002  SOUTH  23.00  EUR  1002  <timestamp>  ''
```

The table contains only the current source state.

An update changes the existing row:

```text
P1001/SOUTH
PRICE 15.00 -> 16.00
```

A physical delete removes the row completely.

For timestamp-based deletion handling, the row can instead remain present with:

```text
IS_DELETED = 'X'
```

The fields have different delta semantics:

```text
CREATED_SEQ
-> order of row creation
-> suitable for append-only numeric delta

CHANGED_AT
-> timestamp of the latest relevant row modification
-> used by timestamp delta

IS_DELETED
-> logical deletion marker
-> makes delete semantics visible while the row remains present
```

`CREATED_SEQ` and `CHANGED_AT` deliberately represent two different acquisition strategies.

---

### ZDB_ACQ_PRICE — Acquisition History

`ZDB_ACQ_PRICE` stores what individual extraction runs actually acquired.

It is not a current-state target.

Its purpose is to preserve extraction history so that different strategies can be compared experimentally.

The key includes:

```text
CLIENT
RUN_ID
EVENT_SEQ
PRODUCT_ID
STORE_GROUP
```

Main fields include:

```text
RUN_ID
EVENT_SEQ
PRODUCT_ID
STORE_GROUP
LOAD_TYPE
OPERATION
PRICE
CURRENCY
CREATED_SEQ
CHANGED_AT
IS_DELETED
ACQUIRED_AT
```

Typical `LOAD_TYPE` values are:

```text
FULL
NUMERIC
TIMESTAMP
TS_SAFE
LOG_DELTA
```

Each acquisition run receives its own `RUN_ID`.

For example:

```text
RUN_A  EVENT_SEQ 0     P1001 SOUTH  FULL
RUN_A  EVENT_SEQ 0     P1002 SOUTH  FULL

RUN_B  EVENT_SEQ 0     P1004 SOUTH  NUMERIC

RUN_C  EVENT_SEQ 1005  P1001 SOUTH  LOG_DELTA  U
RUN_C  EVENT_SEQ 1006  P1001 SOUTH  LOG_DELTA  U
```

For non-change-log acquisitions:

```text
EVENT_SEQ = 0
OPERATION = initial
```

For change-log acquisition, `EVENT_SEQ` becomes part of the event identity.

This is necessary because the same business key may change several times inside one acquisition run:

```text
1005  P1001/SOUTH  U  14.00
1006  P1001/SOUTH  U  15.00
```

Both events must be preserved.

For `LOG_DELTA`, the source `EVENT_AT` value is stored in the generic acquisition field `CHANGED_AT` for information only.

It is not used as the change-log delta criterion.

---

### ZDB_DELTA_STATE — Consumer Delta State

`ZDB_DELTA_STATE` stores persistent consumer-side acquisition pointers.

Key:

```text
SOURCE_NAME
```

Main state fields:

```text
LAST_SEQ
LAST_CHANGED_AT
```

Different logical acquisition strategies use independent source rows.

The project currently uses:

```text
PRODUCT_PRICE
PRODUCT_PRICE_SAFE
PRODUCT_PRICE_LOG
```

Their meanings are:

```text
PRODUCT_PRICE

LAST_SEQ
-> numeric delta pointer based on CREATED_SEQ

LAST_CHANGED_AT
-> naive timestamp-delta pointer
```

```text
PRODUCT_PRICE_SAFE

LAST_CHANGED_AT
-> safe timestamp boundary used with
   upper and lower safety intervals
```

```text
PRODUCT_PRICE_LOG

LAST_SEQ
-> last EVENT_SEQ successfully acquired
   by the change-log consumer
```

This table contains **consumer state only**.

It must not be confused with the producer event counter.

---

### ZDB_EVENT_COUNT — Producer Event Counter

`ZDB_EVENT_COUNT` belongs to the transactional change-log producer.

Key:

```text
SOURCE_NAME
```

Main field:

```text
LAST_EVENT_SEQ
```

Example:

```text
SOURCE_NAME        LAST_EVENT_SEQ
PRODUCT_PRICE_LOG  1007
```

This value means:

> The producer has successfully allocated and committed events up to sequence 1007.

It does not mean that the consumer has already acquired those events.

For example:

```text
Producer:

ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1007
```

while the consumer may still have:

```text
ZDB_DELTA_STATE
LAST_SEQ = 1004
```

This state is valid.

It means that committed source events:

```text
1005
1006
1007
```

are still waiting to be acquired.

---

### ZDB_CHANGE_LOG — Transactional Event Stream

`ZDB_CHANGE_LOG` stores explicit source change events.

Key:

```text
SOURCE_NAME
+
EVENT_SEQ
```

Main fields:

```text
EVENT_SEQ
PRODUCT_ID
STORE_GROUP
OPERATION
PRICE
CURRENCY
EVENT_AT
```

Operation semantics:

```text
I = INSERT
U = UPDATE
D = DELETE
```

Example:

```text
1001  P1010  SOUTH  I  100.00  EUR
1002  P1001  SOUTH  U   14.00  EUR
1003  P1011  SOUTH  I  110.00  EUR
1004  P1010  SOUTH  D
```

For `I` and `U`, the event stores the business after-image required by the consumer.

For `D`, the business key and operation are sufficient:

```text
PRODUCT_ID
STORE_GROUP
OPERATION = D
```

`PRICE` and `CURRENCY` may remain initial for a delete event.

`EVENT_AT` is diagnostic information.

The actual change-log delta pointer is:

```text
EVENT_SEQ
```

not the timestamp.

---

### Producer and Consumer State Are Different

A central design decision in the project is the separation of:

```text
producer progress
```

from:

```text
consumer progress
```

For the change-log architecture:

```text
ZDB_EVENT_COUNT-LAST_EVENT_SEQ
```

means:

```text
highest event committed by the producer
```

while:

```text
ZDB_DELTA_STATE-LAST_SEQ
```

means:

```text
highest event successfully persisted
by the consumer
```

The difference between these values represents the acquisition backlog.

Example:

```text
Producer LAST_EVENT_SEQ = 1010
Consumer LAST_SEQ       = 1007
```

means:

```text
1008
1009
1010
```

are committed source events that have not yet been successfully acquired.

---

### Logical Relationships

The main relationships can be summarized as:

```text
                           ZDB_SRC_PRICE
                    Current source business state
                             /        \
                            /          \
                           v            v
                 Timestamp delta   Transactional producer
                        |                  |
                        |                  +--> ZDB_EVENT_COUNT
                        |                  |
                        |                  +--> ZDB_CHANGE_LOG
                        |                           |
                        v                           v
                  ZDB_ACQ_PRICE            Change-log consumer
                  Acquisition history              |
                                                    v
                                             ZDB_ACQ_PRICE

                         ZDB_DELTA_STATE
                    Persistent consumer pointers
```

For timestamp acquisition:

```text
ZDB_SRC_PRICE
      |
      | CHANGED_AT
      v
ZDB_DELTA_STATE
      |
      v
ZDB_ACQ_PRICE
```

For transactional change-log acquisition:

```text
ZDB_SRC_PRICE
      +
ZDB_EVENT_COUNT
      +
ZDB_CHANGE_LOG
      |
      v
change-log consumer
      |
      v
ZDB_DELTA_STATE
      +
ZDB_ACQ_PRICE
```

The lock object:

```text
EZDBEVCOUNT
```

is not a persistence table.

It protects the `ZDB_EVENT_COUNT` row while a producer transaction allocates the next `EVENT_SEQ`, changes business data, and writes the corresponding log event.

The data model therefore separates five concerns:

```text
ZDB_SRC_PRICE
-> current business state

ZDB_ACQ_PRICE
-> acquisition history

ZDB_DELTA_STATE
-> consumer progress

ZDB_EVENT_COUNT
-> producer sequencing

ZDB_CHANGE_LOG
-> durable ordered change events
```

This separation makes it possible to test source semantics, consumer restart behavior, transaction boundaries, and producer concurrency independently.

## Main Classes

## Main Classes

The project is implemented as a set of small executable ABAP Cloud classes.

Each class represents one controlled acquisition scenario or one part of a reproducible experiment.

The classes are intentionally kept separate instead of being combined into a generic framework. This makes the behavior of each acquisition strategy and failure mode easier to observe.

### Source Initialization and Full Extraction

#### `ZCL_DB_SOURCE_INIT`

Resets and initializes the current-state source simulator:

```text
ZDB_SRC_PRICE
```

with a controlled baseline data set.

The initial records use:

```text
PRODUCT_ID + STORE_GROUP
```

as the business key and contain predefined `CREATED_SEQ` values.

`CHANGED_AT` is intentionally left initial at this stage because timestamp values are prepared separately for the timestamp-delta experiments.

---

#### `ZCL_DB_FULL_READER`

Implements the baseline full extraction.

It reads all rows from:

```text
ZDB_SRC_PRICE
```

and persists the acquired snapshot in:

```text
ZDB_ACQ_PRICE
```

Each extraction receives a unique:

```text
RUN_ID
```

so repeated full loads remain independently visible in the acquisition history.

This class establishes the baseline against which the later delta strategies are compared.

---

### Numeric Delta Experiment

#### `ZCL_DB_NUM_DELTA_INIT`

Initializes the numeric delta pointer from:

```text
MAX( CREATED_SEQ )
```

in the current-state source.

The resulting value is stored in:

```text
ZDB_DELTA_STATE-LAST_SEQ
```

for:

```text
SOURCE_NAME = PRODUCT_PRICE
```

The class initializes only the numeric pointer and preserves timestamp state for the same logical source.

---

#### `ZCL_DB_SOURCE_UPDATE`

Prepares the numeric-delta experiment by performing two source changes in one LUW:

```text
INSERT a new row with a new CREATED_SEQ

UPDATE an existing row while keeping
its original CREATED_SEQ unchanged
```

This creates the test condition used to demonstrate that creation-sequence delta detects inserts but misses updates of existing rows.

---

#### `ZCL_DB_NUM_DELTA_READER`

Reads:

```text
CREATED_SEQ > LAST_SEQ
```

from `ZDB_SRC_PRICE`.

The selected rows are persisted in `ZDB_ACQ_PRICE`, after which the numeric consumer pointer is advanced.

Acquisition persistence and pointer advancement are committed in the same LUW.

This class intentionally demonstrates the limitation of numeric delta on a mutable current-state table.

---

### Timestamp Delta Experiment

#### `ZCL_DB_TS_SOURCE_PREP`

Assigns the same baseline `CHANGED_AT` value to all existing source rows.

This creates a deterministic timestamp baseline before initialization of timestamp delta.

Existing timestamp values are intentionally overwritten.

---

#### `ZCL_DB_TS_DELTA_INIT`

Initializes:

```text
ZDB_DELTA_STATE-LAST_CHANGED_AT
```

from:

```text
MAX( CHANGED_AT )
```

for:

```text
SOURCE_NAME = PRODUCT_PRICE
```

Only the timestamp pointer is initialized or reset; numeric delta state is preserved.

---

#### `ZCL_DB_TS_SOURCE_UPDATE`

Prepares the timestamp-delta experiment.

It performs:

```text
UPDATE of an existing row
+
INSERT of a new row
```

and intentionally assigns both changes the same `CHANGED_AT`.

The existing row retains its old `CREATED_SEQ`.

This demonstrates that timestamp delta can detect both inserts and updates independently of row-creation sequence.

---

#### `ZCL_DB_TS_DELTA_READER`

Implements the intentionally naive timestamp-delta algorithm:

```text
CHANGED_AT > LAST_CHANGED_AT
```

Selected rows are persisted in `ZDB_ACQ_PRICE`, and the highest timestamp actually acquired becomes the next pointer.

The class intentionally uses no safety intervals.

Its purpose is to demonstrate that timestamp delta detects updates but can still lose changes when transaction visibility is delayed.

---

### Delayed-COMMIT Experiment

#### `ZCL_DB_TS_DELAYED_UPDATE`

Performs an update with:

```text
CHANGED_AT = current timestamp
```

but contains a manual debugging anchor before:

```text
COMMIT WORK
```

The class is used in one Eclipse session to keep a source change temporarily uncommitted and invisible to other sessions.

The debugging anchor is intentional and forms part of the reproducible delayed-COMMIT experiment.

---

#### `ZCL_DB_TS_VISIBLE_INSERT`

Creates a second source change in another session and commits it immediately.

Its `CHANGED_AT` is later than the timestamp assigned by `ZCL_DB_TS_DELAYED_UPDATE`.

This allows the naive timestamp reader to advance its pointer beyond the still-uncommitted older change and reproduces the delayed-COMMIT data-loss scenario.

---

### Timestamp Safety Intervals

#### `ZCL_DB_TS_SAFE_INIT`

Creates or resets an independent timestamp-delta state for:

```text
SOURCE_NAME = PRODUCT_PRICE_SAFE
```

The initial pointer is copied from the naive timestamp reader:

```text
PRODUCT_PRICE
```

This allows the safe and naive timestamp algorithms to be tested independently against the same source table.

---

#### `ZCL_DB_TS_SAFE_READER`

Implements timestamp delta with both upper and lower safety intervals.

The effective extraction boundaries are:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL

UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

The reader selects:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

The upper interval prevents the pointer from moving too close to recent potentially uncommitted source changes.

The lower interval intentionally re-reads part of the already scanned range and can therefore generate duplicate after-images.

After a successful request, the persistent pointer advances to:

```text
UPPER_BOUND
```

rather than to the maximum timestamp of selected rows.

The configured five-minute intervals are laboratory values only and are not production recommendations.

---

### Delete Experiments

#### `ZCL_DB_PHYSICAL_DELETE`

Physically removes:

```text
P1003/SOUTH
```

from the current-state source table.

The class demonstrates that timestamp delta cannot detect a physical delete because no source row remains whose `CHANGED_AT` can be selected.

---

#### `ZCL_DB_SOFT_DELETE_PREP`

Restores `P1003/SOUTH` after the physical-delete experiment.

The class intentionally uses `INSERT` and expects the row to be absent.

It prepares the source for the subsequent soft-delete experiment.

---

#### `ZCL_DB_SOFT_DELETE`

Performs a logical delete by setting:

```text
IS_DELETED = 'X'
CHANGED_AT = current timestamp
```

while keeping the row physically present.

This makes the deletion visible to timestamp-based acquisition as a normal changed after-image.

---

### Transactional Change-Log Producer

#### `ZCL_DB_LOG_INIT`

Resets the producer-side change-log infrastructure.

It:

```text
deletes PRODUCT_PRICE_LOG events
and
resets ZDB_EVENT_COUNT to the laboratory baseline
```

It does not reset:

```text
ZDB_SRC_PRICE
```

or the consumer pointer in:

```text
ZDB_DELTA_STATE
```

Consumer state is reset separately by `ZCL_DB_LOG_DELTA_INIT`.

---

#### `ZCL_DB_LOG_INSERT`

Implements a transactional producer `INSERT`.

The class:

```text
1. Locks the event counter with EZDBEVCOUNT
2. Allocates the next EVENT_SEQ
3. Advances ZDB_EVENT_COUNT
4. Inserts the business row into ZDB_SRC_PRICE
5. Inserts an I event into ZDB_CHANGE_LOG
6. Commits all three database changes
7. Releases the lock
```

The counter, business row, and log event therefore belong to one database LUW.

A manual debugging anchor is retained before commit for the producer-concurrency experiment.

---

#### `ZCL_DB_LOG_UPDATE`

Implements the same producer protocol for a business update.

The source after-image and the `U` event are generated from the same test values so that:

```text
current-state source
```

and:

```text
change-log after-image
```

remain consistent.

The class is also used in producer concurrency and rollback experiments.

---

#### `ZCL_DB_LOG_DELETE`

Implements a physical business delete together with an explicit change-log event:

```text
OPERATION = D
```

The business row is physically removed from `ZDB_SRC_PRICE`, while the same transaction preserves the deletion information in `ZDB_CHANGE_LOG`.

This demonstrates how a transactional change log can propagate physical deletes without keeping a tombstone row in the current-state table.

---

### Transactional Change-Log Consumer

#### `ZCL_DB_LOG_DELTA_INIT`

Initializes or resets the change-log consumer pointer to the laboratory baseline:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
LAST_SEQ    = 1000
```

Re-running this class intentionally causes later log events to be replayed.

Producer and consumer state remain independent.

---

#### `ZCL_DB_LOG_DELTA_READER`

Reads committed change-log events using:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

The acquired events are persisted in `ZDB_ACQ_PRICE`.

The consumer pointer is then advanced to the last successfully acquired `EVENT_SEQ`.

Both operations are committed in the same LUW:

```text
persist acquisition
+
advance consumer pointer
+
COMMIT
```

This provides restart-safe replay behavior.

The class assumes a single active consumer for a logical source.

`EVENT_AT` is stored in the generic acquisition timestamp field for information only; it is not used as the change-log delta criterion.

---

### Failure-Test Support

#### `ZCL_DB_LOG_FAIL_PREP`

Creates a deliberate duplicate-key conflict for the next producer `EVENT_SEQ`.

The artificial event uses:

```text
PRODUCT_ID  = PFAIL
STORE_GROUP = TEST
```

The class is used to force the producer's change-log insert to fail after the event counter and business state have already been changed in the current LUW.

This allows producer rollback behavior to be tested.

---

#### `ZCL_DB_LOG_FAIL_CLEANUP`

Removes only the artificial `PFAIL/TEST` records created by the failure-preparation class.

The cleanup is independent of the current producer counter and can safely be repeated.

---

### Supporting Lock Object

The transactional change-log producer uses:

```text
EZDBEVCOUNT
```

to serialize access to the event counter for a logical source.

The lock is acquired before reading `LAST_EVENT_SEQ` and is released only after the producer transaction commits.

Its purpose is to prevent a later event from being allocated and committed while an earlier sequence is still uncommitted.

---

The classes can therefore be grouped by responsibility:

```text
Source baseline / full acquisition
----------------------------------
ZCL_DB_SOURCE_INIT
ZCL_DB_FULL_READER

Numeric delta
-------------
ZCL_DB_NUM_DELTA_INIT
ZCL_DB_SOURCE_UPDATE
ZCL_DB_NUM_DELTA_READER

Timestamp delta
---------------
ZCL_DB_TS_SOURCE_PREP
ZCL_DB_TS_DELTA_INIT
ZCL_DB_TS_SOURCE_UPDATE
ZCL_DB_TS_DELTA_READER

Timestamp safety experiments
----------------------------
ZCL_DB_TS_DELAYED_UPDATE
ZCL_DB_TS_VISIBLE_INSERT
ZCL_DB_TS_SAFE_INIT
ZCL_DB_TS_SAFE_READER

Delete experiments
------------------
ZCL_DB_PHYSICAL_DELETE
ZCL_DB_SOFT_DELETE_PREP
ZCL_DB_SOFT_DELETE

Transactional change-log producer
---------------------------------
ZCL_DB_LOG_INIT
ZCL_DB_LOG_INSERT
ZCL_DB_LOG_UPDATE
ZCL_DB_LOG_DELETE
EZDBEVCOUNT

Transactional change-log consumer
---------------------------------
ZCL_DB_LOG_DELTA_INIT
ZCL_DB_LOG_DELTA_READER

Failure-test support
--------------------
ZCL_DB_LOG_FAIL_PREP
ZCL_DB_LOG_FAIL_CLEANUP

## How to Run

## How to Run

The project is intended to be executed as a sequence of controlled laboratory experiments.

It is not a single end-to-end application.

Individual classes intentionally modify or reset source data, delta pointers, event counters, and acquisition history. Run them in the documented order when reproducing a specific experiment.

### Prerequisites

The project requires:

```text
SAP BTP ABAP Environment / ABAP Cloud system
Eclipse with ABAP Development Tools
abapGit integration for ADT
```

The repository should be linked to an ABAP package, for example:

```text
ZDB_ACQ_LAB
```

After importing the repository, activate all ABAP objects before running the experiments.

The project uses only ABAP Cloud database tables and classes.

No external database connection or SAP BW runtime is required.

---

### 1. Initialize the Source

Start with:

```text
ZCL_DB_SOURCE_INIT
```

This resets `ZDB_SRC_PRICE` and creates the initial current-state data set.

Expected baseline:

```text
P1001/SOUTH  10.00  CREATED_SEQ 1001
P1002/SOUTH  20.00  CREATED_SEQ 1002
P1003/SOUTH  30.00  CREATED_SEQ 1003
P1001/NORTH  11.50  CREATED_SEQ 1004
```

`CHANGED_AT` is intentionally left initial.

---

### 2. Full Extraction

Run:

```text
ZCL_DB_FULL_READER
```

The class reads the complete source table and persists the extracted rows in:

```text
ZDB_ACQ_PRICE
```

Each execution receives a new `RUN_ID`.

Running the class repeatedly therefore produces independent acquisition snapshots.

---

### 3. Numeric Delta Experiment

Initialize the numeric pointer:

```text
ZCL_DB_NUM_DELTA_INIT
```

Expected state:

```text
PRODUCT_PRICE
LAST_SEQ = 1004
```

Prepare the source changes:

```text
ZCL_DB_SOURCE_UPDATE
```

This performs:

```text
INSERT P1004/SOUTH
CREATED_SEQ = 1005
```

and:

```text
UPDATE P1001/SOUTH
PRICE 10.00 -> 12.00
CREATED_SEQ remains 1001
```

Then run:

```text
ZCL_DB_NUM_DELTA_READER
```

Expected result:

```text
P1004/SOUTH -> acquired
P1001/SOUTH -> not acquired
```

The consumer pointer should advance to:

```text
LAST_SEQ = 1005
```

---

### 4. Prepare Timestamp Delta

Assign a common timestamp baseline:

```text
ZCL_DB_TS_SOURCE_PREP
```

Then initialize the timestamp pointer:

```text
ZCL_DB_TS_DELTA_INIT
```

Expected state:

```text
PRODUCT_PRICE
LAST_CHANGED_AT = baseline timestamp
```

Prepare timestamp-based source changes:

```text
ZCL_DB_TS_SOURCE_UPDATE
```

This performs:

```text
UPDATE P1001/SOUTH
INSERT P1005/SOUTH
```

with the same new `CHANGED_AT`.

Run:

```text
ZCL_DB_TS_DELTA_READER
```

Expected result:

```text
2 rows selected
```

Both the insert and the update should be acquired.

---

### 5. Reproduce the Delayed-COMMIT Failure

This experiment requires two independent Eclipse / ADT sessions connected to the same ABAP Cloud system.

Use:

```text
Session A
Session B
```

In `ZCL_DB_TS_DELAYED_UPDATE`, set a breakpoint at the manual debugging anchor immediately before:

```text
COMMIT WORK
```

In Session B, run:

```text
ZCL_DB_TS_DELAYED_UPDATE
```

The class updates `P1002/SOUTH`, assigns:

```text
CHANGED_AT = T1
```

and stops before commit.

Leave Session B suspended.

In Session A, run:

```text
ZCL_DB_TS_VISIBLE_INSERT
```

This creates and immediately commits a later source change:

```text
P1008/SOUTH
CHANGED_AT = T2
```

where:

```text
T1 < T2
```

Still in Session A, run:

```text
ZCL_DB_TS_DELTA_READER
```

The naive reader should see the committed row at `T2` but not the uncommitted row at `T1`.

The pointer advances to:

```text
LAST_CHANGED_AT = T2
```

Now return to Session B and continue execution through:

```text
COMMIT WORK
```

Run `ZCL_DB_TS_DELTA_READER` again in Session A.

Expected result:

```text
0 rows selected
```

The committed `P1002/SOUTH` change is now behind the timestamp pointer and is lost to the naive delta algorithm.

---

### 6. Initialize the Safe Timestamp Reader

Run:

```text
ZCL_DB_TS_SAFE_INIT
```

This creates or resets the independent state:

```text
PRODUCT_PRICE_SAFE
```

using the current timestamp pointer of:

```text
PRODUCT_PRICE
```

---

### 7. Upper and Lower Safety Intervals

Run:

```text
ZCL_DB_TS_SAFE_READER
```

The laboratory implementation uses:

```text
UPPER_SAFETY_INTERVAL = 300 seconds
LOWER_SAFETY_INTERVAL = 300 seconds
```

These values are for demonstration only.

The reader calculates:

```text
LOWER_BOUND =
LAST_CHANGED_AT - 300 seconds

UPPER_BOUND =
REQUEST_START - 300 seconds
```

and selects:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

To reproduce the upper-safety experiment, repeat the two-session delayed-COMMIT scenario using:

```text
ZCL_DB_TS_DELAYED_UPDATE
ZCL_DB_TS_VISIBLE_INSERT
```

but run:

```text
ZCL_DB_TS_SAFE_READER
```

instead of the naive reader.

While both source changes are still inside the upper safety zone, they should not yet be acquired.

After the delayed transaction commits and enough time has passed for both timestamps to move behind `UPPER_BOUND`, run the safe reader again.

Expected result:

```text
both rows acquired
```

To observe lower-safety overlap, run the safe reader again after the pointer has advanced.

Rows whose `CHANGED_AT` falls between:

```text
LOWER_BOUND
```

and:

```text
LAST_CHANGED_AT
```

may be acquired again under a new `RUN_ID`.

This duplicate acquisition is intentional.

---

### 8. Physical DELETE Experiment

If necessary, reinitialize the source first.

Run:

```text
ZCL_DB_PHYSICAL_DELETE
```

This physically removes:

```text
P1003/SOUTH
```

from `ZDB_SRC_PRICE`.

Then run:

```text
ZCL_DB_TS_SAFE_READER
```

Expected result:

```text
no deletion record is acquired
```

The physical delete is invisible because no source row remains.

---

### 9. Soft DELETE Experiment

Restore the deleted row:

```text
ZCL_DB_SOFT_DELETE_PREP
```

Then run:

```text
ZCL_DB_SOFT_DELETE
```

The row remains present with:

```text
IS_DELETED = 'X'
CHANGED_AT = current timestamp
```

After the row has moved behind the configured upper safety boundary, run:

```text
ZCL_DB_TS_SAFE_READER
```

Expected result:

```text
P1003/SOUTH acquired
IS_DELETED = X
```

---

### 10. Initialize the Transactional Change Log

Reset the producer-side log infrastructure:

```text
ZCL_DB_LOG_INIT
```

This:

```text
deletes PRODUCT_PRICE_LOG events
resets ZDB_EVENT_COUNT to 1000
```

It does not reset the consumer pointer.

Initialize the change-log consumer separately:

```text
ZCL_DB_LOG_DELTA_INIT
```

Expected states:

```text
Producer:
LAST_EVENT_SEQ = 1000

Consumer:
LAST_SEQ = 1000
```

---

### 11. Produce Change-Log Events

Run the producer classes as required:

```text
ZCL_DB_LOG_INSERT
ZCL_DB_LOG_UPDATE
ZCL_DB_LOG_DELETE
```

They generate explicit events:

```text
I
U
D
```

in:

```text
ZDB_CHANGE_LOG
```

Each producer transaction follows:

```text
lock counter
allocate EVENT_SEQ
update counter
apply business change
insert log event
COMMIT
release lock
```

Inspect:

```text
ZDB_EVENT_COUNT
ZDB_SRC_PRICE
ZDB_CHANGE_LOG
```

after each run.

---

### 12. Consume the Change Log

Run:

```text
ZCL_DB_LOG_DELTA_READER
```

The consumer selects:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

and persists the events in:

```text
ZDB_ACQ_PRICE
```

After a successful run, inspect:

```text
ZDB_DELTA_STATE
```

and verify that:

```text
LAST_SEQ
```

has advanced to the highest successfully acquired `EVENT_SEQ`.

---

### 13. Producer Concurrency Experiment

Use two independent Eclipse / ADT sessions.

Set a breakpoint at the manual debugging anchor in one producer class, for example:

```text
ZCL_DB_LOG_UPDATE
```

Session A:

```text
run producer
allocate next EVENT_SEQ
stop before COMMIT
hold EZDBEVCOUNT
```

While Session A is suspended, run another producer in Session B:

```text
ZCL_DB_LOG_INSERT
```

Expected result:

```text
Event counter is locked by another session
```

Session B must not allocate the next event sequence.

Resume Session A and allow it to commit.

Then run Session B again.

It should now receive the next sequence and commit successfully.

---

### 14. Consumer Restart Experiment

Create one or more committed producer events that have not yet been consumed.

Set a breakpoint in:

```text
ZCL_DB_LOG_DELTA_READER
```

after:

```text
INSERT zdb_acq_price FROM TABLE ...
```

but before:

```text
UPDATE zdb_delta_state
```

Run the consumer and terminate the debug session before `COMMIT`.

Verify:

```text
ZDB_CHANGE_LOG
-> producer events still exist

ZDB_ACQ_PRICE
-> interrupted acquisition rows are not committed

ZDB_DELTA_STATE
-> LAST_SEQ has not advanced
```

Run the consumer again without interruption.

The same events should be selected again and committed successfully.

---

### 15. Producer Rollback Experiment

Prepare an artificial change-log conflict:

```text
ZCL_DB_LOG_FAIL_PREP
```

This creates a deliberate record for the next producer `EVENT_SEQ`.

Run:

```text
ZCL_DB_LOG_UPDATE
```

The producer should:

```text
advance the counter in its LUW
apply the business change
fail when inserting the duplicate log event
ROLLBACK
```

Verify that after rollback:

```text
ZDB_EVENT_COUNT
-> restored to its previous value

ZDB_SRC_PRICE
-> business value restored

ZDB_CHANGE_LOG
-> no legitimate event was created
```

Remove the artificial conflict:

```text
ZCL_DB_LOG_FAIL_CLEANUP
```

Run the producer again.

The same event sequence should now be reused successfully.

Finally run:

```text
ZCL_DB_LOG_DELTA_READER
```

and verify that the successfully committed event reaches `ZDB_ACQ_PRICE`.

---

### Inspecting Results

The most useful tables to inspect during the experiments are:

```text
ZDB_SRC_PRICE
-> current source state

ZDB_ACQ_PRICE
-> rows actually acquired by each run

ZDB_DELTA_STATE
-> consumer delta pointers

ZDB_EVENT_COUNT
-> producer event-sequence state

ZDB_CHANGE_LOG
-> durable I / U / D event stream
```

For acquisition history, compare:

```text
RUN_ID
LOAD_TYPE
EVENT_SEQ
OPERATION
PRODUCT_ID
STORE_GROUP
PRICE
CHANGED_AT
IS_DELETED
```

to see exactly what each extraction strategy returned.

---

### Important

Several classes are destructive laboratory utilities.

They may:

```text
delete source rows
reset delta pointers
reset event counters
delete change-log events
replay previously consumed events
```

Run them only in the intended experimental sequence.

The project is designed for a disposable ABAP Cloud laboratory environment, not for production business data.


## Mapping to SAP BW DB Connect

This project does not implement the SAP BW DB Connect runtime.

Instead, it isolates and reproduces the source-side and consumer-side semantics that determine whether a database delta can be acquired reliably.

The laboratory objects can therefore be mapped only **conceptually** to classical SAP BW DB Connect components.

### High-Level Mapping

A classical DB Connect flow can be represented as:

```text
External relational database
        |
        | table / view
        v
DB Connect source system
        |
        v
DataSource
        |
        v
InfoPackage
        |
        v
PSA / acquisition layer
        |
        v
Transformation / DTP
        |
        v
BW target
```

The laboratory models mainly the upper part of this flow:

```text
database source
        |
        v
delta selection
        |
        v
acquisition persistence
        |
        v
delta pointer advancement
```

The corresponding conceptual mapping is:

| Laboratory object / mechanism | SAP BW DB Connect concept |
|---|---|
| `ZDB_SRC_PRICE` | External database table or view |
| `ZCL_DB_FULL_READER` | Full extraction through a DB Connect DataSource |
| `CREATED_SEQ` delta | Generic numeric delta criterion |
| `CHANGED_AT` delta | Generic date/timestamp delta criterion |
| Upper / lower safety intervals | Generic delta safety intervals |
| `ZDB_ACQ_PRICE` | Conceptually similar to an acquisition / PSA persistence layer |
| `ZDB_DELTA_STATE` | Laboratory replacement for BW-managed delta state |
| `LAST_SEQ` | Conceptual numeric delta high-water mark |
| `LAST_CHANGED_AT` | Conceptual timestamp delta boundary |
| `IS_DELETED` | Source-side delete/tombstone convention exposed through the DataSource |
| `ZDB_CHANGE_LOG` | Source-side change-log table or view used as the extraction source |
| `EVENT_SEQ` | Numeric generic-delta field on an ordered change stream |
| `I / U / D` | Source-provided change semantics carried into BW processing |
| `ZDB_EVENT_COUNT` | Source-side event sequencing infrastructure; not a BW runtime object |
| `EZDBEVCOUNT` | Source-side concurrency control; not a BW DB Connect object |

### External Table or View

In a real DB Connect scenario, BW reads from an external relational database.

The extraction source may be a physical table or, preferably in many integration designs, a database view that exposes a stable interface to BW.

In the laboratory:

```text
ZDB_SRC_PRICE
```

plays this role.

It represents a mutable current-state source with fields such as:

```text
PRODUCT_ID
STORE_GROUP
PRICE
CURRENCY
CREATED_SEQ
CHANGED_AT
IS_DELETED
```

The important point is not that this table physically resides in the ABAP Cloud system.

Its role is to reproduce the semantics of an external database object whose rows can be inserted, updated, deleted, and committed concurrently with extraction.

### Full Extraction

`ZCL_DB_FULL_READER` corresponds conceptually to a DB Connect DataSource executed in full mode.

The laboratory performs:

```text
SELECT all current source rows
        |
        v
persist acquisition result
```

A real BW implementation would perform the extraction through the DB Connect source system and DataSource, with BW request management handling the acquisition process.

The laboratory does not reproduce that runtime.

It only preserves the extracted result in:

```text
ZDB_ACQ_PRICE
```

so that later delta experiments can be compared with the full baseline.

### Generic Numeric Delta

The experiment based on:

```text
CREATED_SEQ
```

corresponds conceptually to a generic numeric delta field.

The consumer reads:

```text
CREATED_SEQ > LAST_SEQ
```

The experiment demonstrates an important source-design requirement:

```text
a monotonically increasing creation number
is suitable for append-only data
```

but:

```text
it does not detect updates
to previously created rows
```

In a real DB Connect design, selecting a numeric generic-delta field is therefore not merely a technical DataSource setting.

The source field must have semantics that actually correspond to all business changes that BW needs to receive.

### Generic Timestamp Delta

The timestamp experiment corresponds conceptually to a DB Connect generic delta based on a timestamp field.

The source maintains:

```text
CHANGED_AT
```

and the consumer initially uses:

```text
CHANGED_AT > LAST_CHANGED_AT
```

The laboratory demonstrates that this strategy can detect both:

```text
INSERT
UPDATE
```

provided that every relevant source update also updates `CHANGED_AT`.

This requirement belongs to the source interface contract.

If a business row changes but `CHANGED_AT` does not, no BW configuration can recover that missing delta information.

### Safety Intervals

The upper and lower safety experiments correspond directly to the safety-window concept used with generic timestamp or date delta.

The laboratory implements:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL

UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

and reads:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

The upper safety interval protects against changes that have already received a timestamp but are not yet committed and visible to the extractor.

The lower safety interval intentionally re-reads part of the previously scanned range.

This can generate duplicate after-images.

The laboratory makes this behavior explicit by preserving repeated acquisition rows under different `RUN_ID` values.

In a real BW system, the framework manages the generic-delta request boundaries and corresponding pointer state.

The project reimplements this state only so that the behavior can be observed directly.

### Delta State

`ZDB_DELTA_STATE` is a laboratory object.

It should not be interpreted as a table that must be created for standard SAP BW DB Connect.

Its purpose is to make the normally framework-managed extraction state visible.

For example:

```text
PRODUCT_PRICE
LAST_SEQ
LAST_CHANGED_AT
```

represents the laboratory state for the naive numeric and timestamp experiments.

```text
PRODUCT_PRICE_SAFE
LAST_CHANGED_AT
```

represents the independent safe-timestamp experiment.

In a real standard generic-delta scenario, BW manages the corresponding request and delta state.

The project implements its own state only because there is no BW runtime in the ABAP Cloud Trial environment.

### PSA / Acquisition Persistence

`ZDB_ACQ_PRICE` is conceptually similar to an acquisition-history or PSA-like persistence layer.

It stores:

```text
what a particular extraction run actually returned
```

rather than the final business state.

For example, it can show separately:

```text
FULL
NUMERIC
TIMESTAMP
TS_SAFE
LOG_DELTA
```

runs.

This is useful for the laboratory because it makes failure modes observable.

It should not be interpreted as an implementation of the actual SAP BW PSA runtime.

A real BW request provides additional functionality such as:

```text
request management
technical status
package handling
monitoring
restart processing
integration with downstream DTP execution
```

which this laboratory intentionally does not reproduce.

### Delete Semantics

The physical-delete experiment demonstrates a source-side issue that also applies to real database extraction.

If a row is physically removed from a current-state table:

```text
DELETE FROM source
```

a later timestamp-based `SELECT` has no row left to return.

DB Connect cannot infer a deletion that is no longer represented in the extraction source.

One solution is a source contract based on soft deletion:

```text
IS_DELETED = 'X'
CHANGED_AT = new timestamp
```

The delete then becomes an ordinary extractable after-image.

BW can carry this field into later processing and interpret it according to the target contract:

```text
delete
deactivate
close validity
```

The important point is that delete semantics must be represented by the source.

They cannot be reconstructed automatically from an incremental timestamp query against a current-state table.

### Transactional Change Log as a DB Connect Source

The change-log branch represents an alternative source design.

Instead of extracting directly from the mutable current-state table, BW could conceptually read from a source-side table or view containing:

```text
EVENT_SEQ
BUSINESS KEY
OPERATION
AFTER-IMAGE
```

For example:

```text
1001  P1010/SOUTH  I  100.00
1002  P1001/SOUTH  U   14.00
1003  P1011/SOUTH  I  110.00
1004  P1010/SOUTH  D
```

A DB Connect DataSource could then use:

```text
EVENT_SEQ
```

as a numeric delta field.

This changes the meaning of the numeric pointer.

In the earlier experiment:

```text
CREATED_SEQ
```

identified creation of a business row.

In the change-log architecture:

```text
EVENT_SEQ
```

identifies every relevant business change.

Therefore a simple selection such as:

```text
EVENT_SEQ > LAST_SEQ
```

can transport:

```text
INSERT
UPDATE
DELETE
```

through one ordered stream.

### What SAP BW Would Manage

In a real classical DB Connect implementation, BW would provide the surrounding acquisition infrastructure.

Conceptually, BW would manage areas such as:

```text
DB connection configuration
DataSource metadata
full / delta request execution
generic-delta state
request monitoring
PSA persistence
downstream processing
DTP execution
Process Chain orchestration
```

The laboratory deliberately replaces these mechanisms with small ABAP classes and tables so that the delta semantics remain directly visible.

For example:

```text
ZCL_DB_NUM_DELTA_READER
```

is not a replacement for a DB Connect DataSource.

It is a controlled experiment that exposes what a numeric delta criterion actually sees.

Similarly:

```text
ZCL_DB_TS_SAFE_READER
```

is not an implementation of the SAP generic-delta runtime.

It is a transparent model of the boundary and overlap logic used to study the effect of safety intervals.

### What Remains Source Responsibility

Even when SAP BW provides the extraction framework, several guarantees must still come from the source design.

For numeric delta:

```text
the numeric field must represent every relevant change
```

For timestamp delta:

```text
CHANGED_AT must be updated reliably
for every relevant source modification
```

and:

```text
transaction / visibility lag must be bounded
if finite safety intervals are expected
to prevent gaps
```

For deletes:

```text
the source must expose deletion semantics
```

through a tombstone, soft-delete marker, or change log.

For an event-log source:

```text
event creation must be transactionally coupled
to the business change
```

and:

```text
EVENT_SEQ ordering must be safe for use
as a high-water mark
```

These requirements are outside the ability of a BW DataSource to repair after the fact.

### What This Lab Does Not Reproduce

The project does not contain:

```text
DB Connect source-system configuration
remote database drivers
real external database connectivity
BW DataSource metadata
InfoPackages
PSA runtime
DTPs
Transformations
ADSOs
Process Chains
BW request monitor
standard BW generic-delta administration
```

It also uses SAP HANA as the underlying database of the ABAP Cloud environment, so the observed database behavior must not be treated as a universal implementation model for every external RDBMS.

The project instead focuses on the portable architectural questions:

```text
What defines a new change?

When is that change visible?

How can DELETE be represented?

When may the consumer safely advance its pointer?

What happens after a crash?

What happens when producer transactions overlap?
```

These questions remain relevant regardless of whether the actual source database is Oracle, Microsoft SQL Server, SAP HANA, PostgreSQL, or another relational system.

### Conceptual Summary

The mapping can be summarized as:

```text
Laboratory                           Classical SAP BW DB Connect
--------------------------------------------------------------------------

ZDB_SRC_PRICE                       external table / view

ZCL_DB_FULL_READER                  full extraction concept

CREATED_SEQ                         numeric generic-delta field

CHANGED_AT                          date / timestamp generic-delta field

upper / lower safety logic          generic-delta safety intervals

ZDB_DELTA_STATE                     visible laboratory model of
                                    BW-managed delta state

ZDB_ACQ_PRICE                       acquisition / PSA-like persistence
                                    used only for the laboratory

IS_DELETED                          source-provided deletion semantics

ZDB_CHANGE_LOG                      alternative source-side change-log
                                    table / view

EVENT_SEQ                           numeric delta field over event stream

ZCL_DB_LOG_DELTA_READER             conceptual ordered-log consumer

ZDB_EVENT_COUNT / EZDBEVCOUNT       source-side implementation details,
                                    not BW DB Connect objects
```

The main purpose of the mapping is not to reproduce SAP BW internals.

It is to show which parts of reliable database acquisition are provided by the BW extraction framework and which guarantees must already exist in the source interface design.

## Project Limitations

This project is a laboratory for studying database acquisition and delta reliability.

It intentionally simplifies many aspects of a real enterprise integration landscape.

The limitations are part of the project boundary and should be considered when interpreting the experiments.

### No Real SAP BW Runtime

The project runs in:

```text
SAP BTP ABAP Environment / ABAP Cloud
```

and not in a real SAP BW or BW/4HANA system.

It therefore does not use:

```text
DB Connect source systems
BW DataSources
InfoPackages
PSA runtime
Transformations
DTPs
ADSOs
Process Chains
BW request management
standard BW delta administration
```

The project models only the acquisition semantics that are relevant for understanding:

```text
full extraction
numeric delta
timestamp delta
safety intervals
delete handling
ordered change logs
restart behavior
transactional consistency
```

The laboratory classes must not be interpreted as replacements for standard BW runtime components.

---

### No Real External Database

`ZDB_SRC_PRICE` is a local ABAP Cloud database table.

It simulates an external relational source.

There is no actual connection to:

```text
Oracle
Microsoft SQL Server
PostgreSQL
SAP HANA remote source
or another external RDBMS
```

This provides a controlled environment for reproducible experiments, but it also means that:

```text
network failures
remote database drivers
connection pooling
remote transaction boundaries
vendor-specific isolation behavior
remote SQL dialect differences
```

are outside the project scope.

---

### Database Behavior Is Observed in One Platform

The laboratory runs on the database infrastructure underlying SAP BTP ABAP Environment.

The experiments should therefore be interpreted primarily as demonstrations of acquisition architecture, not as universal proofs of exact database behavior across all relational database systems.

Different source databases may differ in:

```text
transaction isolation
locking behavior
timestamp precision
commit visibility
snapshot semantics
sequence implementation
concurrency behavior
```

The architectural conclusions remain useful, but production behavior must be validated against the actual source RDBMS.

---

### Simplified Source Data Model

The business model is intentionally small.

The source contains only a simple price structure:

```text
PRODUCT_ID
STORE_GROUP
PRICE
CURRENCY
CREATED_SEQ
CHANGED_AT
IS_DELETED
```

This is sufficient for the experiments but does not represent complexities such as:

```text
multiple related tables
referential integrity across objects
multi-row business transactions
header/item structures
large payloads
hierarchies
time-dependent master data
high-volume fact tables
```

A production extraction design may need to preserve consistency across several related tables or business objects.

---

### Simplified Acquisition Persistence

`ZDB_ACQ_PRICE` preserves acquisition history for laboratory analysis.

It is deliberately lightweight.

It does not provide the complete behavior of a BW PSA or request framework, including:

```text
request lifecycle management
package processing
technical request status
error stacks
restart metadata
parallel package execution
monitor integration
downstream request dependencies
```

Its main purpose is to make visible:

```text
what each extraction run actually acquired
```

---

### Simplified Delta-State Management

`ZDB_DELTA_STATE` is a laboratory representation of persistent consumer state.

It makes the delta pointer explicit so that the experiments can show exactly when it changes.

In a real BW generic-delta scenario, the relevant state is maintained by the BW framework.

The project does not reproduce the complete internal logic of SAP BW delta administration.

---

### Timestamp Safety Values Are Demonstration Values

The safe timestamp reader uses:

```text
UPPER_SAFETY_INTERVAL = 300 seconds
LOWER_SAFETY_INTERVAL = 300 seconds
```

These values were chosen to make the experiments easy to reproduce.

They are not production recommendations.

A real system would need safety values derived from measurable source-system behavior such as:

```text
maximum transaction duration
commit visibility lag
batch-processing characteristics
clock behavior
operational SLA
```

The correct values depend on the actual source environment.

---

### Timestamp Delta Still Depends on Source Discipline

The timestamp architecture assumes that every relevant source change reliably updates:

```text
CHANGED_AT
```

If a business field changes without changing `CHANGED_AT`, the delta reader cannot detect it.

The project does not attempt to enforce this rule automatically.

It is treated as part of the source interface contract.

Similarly, safe timestamp extraction assumes that commit / visibility lag is bounded.

If a transaction can remain uncommitted for arbitrarily long periods after `CHANGED_AT` is assigned, no finite safety interval provides a strict lossless guarantee.

---

### Soft Delete Requires a Source-Side Contract

Timestamp-based delete handling uses:

```text
IS_DELETED = 'X'
```

while retaining the source row.

This requires the source application to support tombstone semantics.

The laboratory does not implement:

```text
tombstone retention policy
physical purge scheduling
archive management
downstream delete confirmation
```

A production design must define when a tombstone can safely be removed.

---

### The Change Log Is a Laboratory Implementation

`ZDB_CHANGE_LOG` demonstrates an ordered transactional event stream.

The project does not claim to implement a production CDC platform.

It does not use technologies such as:

```text
database redo-log CDC
LSN-based replication
SAP SLT
SAP SDI
Kafka
outbox infrastructure
database-native change streams
```

Instead, the source application explicitly writes change events in the same LUW as the business change.

This makes the transactional principle easy to observe.

---

### Single Counter Serialization

The transactional producer uses one protected event counter for:

```text
PRODUCT_PRICE_LOG
```

This guarantees commit-consistent ordering in the laboratory.

The trade-off is serialization.

At high producer volumes, a single counter lock could become a bottleneck.

Production architectures may instead use more scalable mechanisms such as:

```text
database log sequence numbers
partitioned event streams
transactional outbox patterns
database-native CDC
distributed messaging infrastructure
```

The project intentionally prioritizes clarity of correctness over throughput.

---

### All Producers Must Follow the Protocol

The reliability of the change-log architecture depends on every producer using the same protocol:

```text
lock
allocate EVENT_SEQ
update counter
apply business change
write log event
COMMIT
unlock
```

If another writer modifies the same business table but does not produce a corresponding log event, the change can be invisible to the change-log consumer.

If another producer allocates sequences without the same ordering protocol, the `EVENT_SEQ` high-water-mark guarantee can be broken.

The project does not technically prevent external code from bypassing this contract.

---

### Single Active Change-Log Consumer Assumption

`ZCL_DB_LOG_DELTA_READER` assumes one active consumer instance for:

```text
PRODUCT_PRICE_LOG
```

The consumer pointer itself is not protected by a dedicated concurrency lock.

Two consumers running concurrently against the same logical source could therefore require additional coordination.

This scenario is intentionally outside the current project scope.

---

### No Consumer Group Model

The project maintains one consumer pointer per logical source.

It does not implement multiple independent subscribers such as:

```text
Consumer A LAST_SEQ = 1007
Consumer B LAST_SEQ = 1003
Consumer C LAST_SEQ = 1009
```

A production event-stream design may need one pointer per consumer or consumer group.

That would also affect change-log retention because events cannot be removed until all required consumers have passed them.

---

### No Change-Log Retention Management

`ZDB_CHANGE_LOG` acts as a durable replay source during the experiments.

The project does not implement:

```text
event retention windows
archiving
log partitioning
purge rules
consumer-aware cleanup
```

In production, change-log growth must be managed carefully.

Deleting events too early could make consumer restart or replay impossible.

---

### No Performance or Volume Benchmark

The laboratory uses only a very small number of rows.

It does not measure:

```text
throughput
latency under load
lock contention
database growth
large delta package behavior
memory consumption
parallel extraction performance
```

The project therefore demonstrates correctness properties, not scalability characteristics.

---

### No Production Error-Handling Framework

The classes contain explicit checks, rollback paths, and diagnostic output, but there is no general application framework for:

```text
central logging
alerting
monitoring
retry scheduling
dead-letter processing
operations dashboards
support workflows
```

Failure handling is implemented only to the extent required to demonstrate the relevant acquisition behavior.

---

### Debug Anchors Are Intentional

Some classes contain manual debugging anchors before `COMMIT`.

These are intentionally retained.

They allow two-session experiments such as:

```text
delayed COMMIT
producer lock contention
consumer interruption
```

to be reproduced in ADT.

They are laboratory instrumentation and would not belong in normal production processing.

---

### No Generic Extraction Framework

The project intentionally contains separate classes for individual scenarios.

It does not attempt to provide a reusable abstraction such as:

```text
generic source adapter
generic delta strategy interface
generic persistence framework
configuration-driven acquisition engine
```

This is deliberate.

The main goal is to keep transaction boundaries, pointer updates, and failure conditions directly visible in the code.

---

### Not a Production Template

The repository should therefore be read as:

```text
an executable architectural laboratory
```

rather than:

```text
a production-ready integration framework
```

Its purpose is to demonstrate why different acquisition strategies succeed or fail under specific conditions and to make their reliability contracts explicit.

The production design for a real SAP BW / BW/4HANA system must additionally consider:

```text
actual source database behavior
SAP-supported connectivity
data volume
security
authorization
monitoring
operational ownership
retention
performance
recovery SLA
source-system constraints
```

The project deliberately stops before those implementation-specific concerns.


## Key Takeaways

This laboratory is built around one central acquisition question:

```text
Under what conditions can the consumer
advance its delta pointer
without losing a committed source change?
```

The experiments show that the answer depends on the semantics of the source data and on the reliability contract behind the chosen delta field.

### 1. A Delta Field Is Only as Good as Its Semantics

A field may be technically monotonic or time-dependent and still be unsuitable for reliable delta acquisition.

For example:

```text
CREATED_SEQ
```

works for newly created rows but does not detect later updates to existing rows.

Therefore:

```text
creation order
!=
change order
```

A numeric delta field is reliable only if its value changes for every business event that must be extracted.

---

### 2. Timestamp Delta Detects Updates, but Visibility Matters

A correctly maintained:

```text
CHANGED_AT
```

can detect both inserts and updates in a mutable current-state table.

However:

```text
time when CHANGED_AT is assigned
```

is not necessarily the same as:

```text
time when the transaction becomes committed
and visible to another session
```

A later committed row can therefore move the consumer pointer past an older still-uncommitted change.

This is the fundamental delayed-COMMIT failure demonstrated by the project.

---

### 3. `>=` Does Not Solve the Delayed-COMMIT Problem

Changing:

```text
CHANGED_AT > LAST_CHANGED_AT
```

to:

```text
CHANGED_AT >= LAST_CHANGED_AT
```

does not solve the general problem.

If the delayed change has:

```text
T1
```

and a later visible change advances the pointer to:

```text
T2
```

where:

```text
T1 < T2
```

then the delayed row is still behind the pointer after it commits.

The issue is therefore not equality at the extraction boundary.

It is the difference between:

```text
change time
```

and:

```text
visibility time
```

---

### 4. Upper Safety Protects the Recent Time Region

An upper safety interval deliberately prevents the consumer from reading too close to the current time.

Instead of scanning up to:

```text
REQUEST_START
```

the reader scans only up to:

```text
REQUEST_START - UPPER_SAFETY_INTERVAL
```

This allows recent transactions additional time to commit before the consumer declares that time region fully scanned.

The cost is extraction latency.

A larger upper safety interval provides more protection but delays delivery of recent changes.

---

### 5. Lower Safety Creates Controlled Overlap

A lower safety interval moves the lower extraction boundary backward:

```text
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

This intentionally re-reads part of the previously scanned time range.

The result is:

```text
possible duplicate after-images
```

rather than:

```text
a strict one-time delivery guarantee
```

This is usually acceptable only when downstream processing is compatible with repeated after-images, for example overwrite-style semantics.

It can be unsafe for additive or non-idempotent processing.

---

### 6. Timestamp Delta Depends on a Bounded Visibility Contract

Safety intervals can protect timestamp delta only if the delay between:

```text
assigning CHANGED_AT
```

and:

```text
transaction commit / visibility
```

has a practical upper bound.

If source transactions can remain uncommitted for arbitrarily long periods, then:

```text
no finite upper safety interval
can guarantee lossless extraction
```

A lower overlap window does not remove this fundamental dependency.

Timestamp delta is therefore correct only under an explicit timing contract.

---

### 7. Physical DELETE Is Invisible in a Current-State Timestamp Source

A physical delete removes the row that the extractor would need to select.

After:

```text
DELETE FROM source
```

there is no remaining:

```text
CHANGED_AT
```

to evaluate.

Therefore a current-state timestamp extractor cannot discover that deletion automatically.

The source must expose deletion semantics explicitly.

---

### 8. Soft DELETE Makes Deletion Extractable

A soft-delete model keeps the row and changes:

```text
IS_DELETED = 'X'
CHANGED_AT = new timestamp
```

The deletion then becomes an ordinary timestamped after-image.

This works naturally with current-state timestamp extraction.

The trade-off is the need to retain tombstone rows until they can be safely archived or purged.

---

### 9. A Transactional Change Log Uses a Different Correctness Model

The change-log architecture does not try to infer all business changes from the current-state table.

Instead, the source publishes explicit events:

```text
I
U
D
```

with a monotonically increasing:

```text
EVENT_SEQ
```

The consumer then reads:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

The reliability contract is no longer primarily temporal.

It becomes:

```text
business change
+
event creation
+
sequence allocation
```

must be transactionally consistent and ordered correctly.

---

### 10. Monotonic Sequence Alone Is Not Enough

A source can still lose events even with a perfectly increasing event number if producers can commit out of sequence.

The dangerous state is:

```text
1003 committed and visible
1002 still uncommitted
```

A consumer could read `1003`, advance its pointer, and later skip `1002`.

Therefore:

```text
monotonic sequence
```

must be combined with:

```text
commit-consistent ordering
```

In the laboratory this is achieved by serializing producer access to the event counter with:

```text
EZDBEVCOUNT
```

---

### 11. Producer Locking and Transaction Atomicity Solve Different Problems

The producer lock guarantees:

```text
event ordering across concurrent producers
```

The database transaction guarantees:

```text
atomic consistency of
event counter
business state
change-log event
```

Both are required.

The lock does not replace `COMMIT` / `ROLLBACK`.

The transaction does not by itself guarantee safe sequence ordering between concurrent producers.

---

### 12. The Change Log Handles Physical Deletes Naturally

Because deletion is represented explicitly as:

```text
OPERATION = D
```

the business row may be physically removed from the current-state table.

The delete remains durable in:

```text
ZDB_CHANGE_LOG
```

This removes the requirement for permanent tombstones in the current-state source.

---

### 13. Change-Log Correctness Does Not Depend on Transaction Duration

With commit-consistent sequence allocation:

```text
a long-running transaction remains invisible
and prevents later sequence publication
```

until it commits or rolls back.

The consumer therefore cannot move past that uncommitted event.

This means that change-log delta correctness is not based on estimating how long source transactions may remain open.

This is one of the strongest architectural differences from timestamp delta.

---

### 14. Consumer Pointer Advancement Must Be Atomic with Persistence

A consumer must never do:

```text
advance pointer
COMMIT

then

persist acquired data
```

because a crash between these steps would permanently lose data.

The safe pattern is:

```text
persist acquired data
        |
        v
advance consumer pointer
        |
        v
COMMIT both together
```

If the transaction fails before commit:

```text
acquisition rows disappear
pointer remains unchanged
source events remain available
```

and the same events can be replayed.

---

### 15. Producer Rollback Must Restore the Entire Source-Side State

For the change-log producer:

```text
counter update
+
business change
+
log event
```

must be one LUW.

If the log insert fails, rollback must restore:

```text
event counter
business state
```

and prevent a partial event from being published.

Only then can the same event sequence be safely reused on retry.

---

### 16. Producer State and Consumer State Are Independent

The producer pointer:

```text
ZDB_EVENT_COUNT-LAST_EVENT_SEQ
```

means:

```text
highest event committed by the producer
```

The consumer pointer:

```text
ZDB_DELTA_STATE-LAST_SEQ
```

means:

```text
highest event successfully persisted
by the consumer
```

These values do not need to be equal.

Their difference represents the current acquisition backlog.

---

### 17. Full, Numeric, Timestamp, and Log Delta Answer Different Questions

The experiments show that these strategies should not be treated as interchangeable technical options.

They rely on different source semantics:

```text
FULL
-> what exists now?

CREATED_SEQ delta
-> what rows were created after the pointer?

CHANGED_AT delta
-> what current rows changed inside a time range?

Transactional log delta
-> what business events occurred after the event pointer?
```

Choosing a delta method therefore starts with understanding the source model, not with choosing a configuration checkbox.

---

### 18. Reliability Comes from an Explicit Contract

The most important conclusion of the project is that reliable acquisition is not created by the consumer alone.

The source and consumer must share a contract.

For timestamp delta:

```text
every relevant change updates CHANGED_AT
+
delete semantics are exposed
+
visibility delay is bounded
+
safety intervals match that bound
```

For transactional change log:

```text
every relevant business change creates an event
+
business change and event are one LUW
+
EVENT_SEQ is commit-order-consistent
+
the consumer advances only after successful persistence
```

If any part of the contract is violated, a technically correct `SELECT` statement can still produce an incorrect delta.

---

### 19. SAP BW Can Manage Delta State, but It Cannot Repair Missing Source Semantics

A real SAP BW DB Connect implementation provides the surrounding extraction framework:

```text
DataSource
request management
generic delta state
PSA
monitoring
downstream processing
```

But BW still depends on the source to provide meaningful and reliable delta information.

BW cannot automatically reconstruct:

```text
an update that did not change the delta field
a physical delete that left no trace
an event that was never logged
a timestamp contract that is violated by unbounded delayed commits
```

Therefore source-interface design remains part of BW acquisition architecture.

---

### 20. The Main Design Question Is About Safe Pointer Advancement

Across all experiments, the same principle appears repeatedly:

```text
A delta pointer may advance only when
all source changes before that boundary
are guaranteed to be either:

1. already acquired,
or
2. still recoverable by a future request.
```

For timestamp delta, this guarantee comes from carefully defined time boundaries and overlap.

For transactional change log, it comes from durable ordered events and transactional sequencing.

That is the central architectural lesson of the project.
