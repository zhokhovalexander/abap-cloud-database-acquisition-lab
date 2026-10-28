# Delta Semantics

## Purpose and Scope

This document describes the delta-acquisition semantics explored in the **ABAP Cloud Database Acquisition Lab**.

The project implements several acquisition strategies against a mutable current-state source and an explicit transactional change log:

```text
Full extraction
Numeric delta
Timestamp delta
Timestamp delta with safety intervals
Transactional change-log delta
```

The purpose of this document is not to describe the ABAP classes individually.

Instead, it focuses on the architectural question behind all experiments:

```text
When may a consumer safely advance its delta pointer
without losing a committed source change?
```

This question is more fundamental than the choice of a particular delta field.

A delta mechanism is reliable only when the semantics of the source field, source transactions, and consumer pointer are compatible.

For example, the following fields may all appear suitable as delta criteria:

```text
CREATED_SEQ
CHANGED_AT
EVENT_SEQ
```

but they represent fundamentally different things:

```text
CREATED_SEQ
-> when a business row was created

CHANGED_AT
-> when the current row was last marked as changed

EVENT_SEQ
-> position of a change event in an ordered event stream
```

The experiments therefore distinguish between:

```text
row creation
row modification
transaction visibility
event ordering
consumer progress
```

These concepts must not be treated as equivalent.

---

### Source Models

The laboratory uses two different source models.

The first is a mutable current-state table:

```text
ZDB_SRC_PRICE
```

It stores only the current representation of each business key.

A row can be:

```text
inserted
updated
physically deleted
soft deleted
```

Delta acquisition against this model must infer changes from attributes that remain on the current row, such as:

```text
CREATED_SEQ
CHANGED_AT
IS_DELETED
```

The second source model is an explicit transactional event stream:

```text
ZDB_CHANGE_LOG
```

Instead of deriving changes from the current state, it records each relevant business operation explicitly:

```text
I = INSERT
U = UPDATE
D = DELETE
```

Each event receives an ordered:

```text
EVENT_SEQ
```

This creates a fundamentally different delta contract.

---

### Consumer State

All delta strategies require persistent consumer state.

In the laboratory this state is stored explicitly in:

```text
ZDB_DELTA_STATE
```

Examples include:

```text
LAST_SEQ
LAST_CHANGED_AT
```

The meaning of the pointer depends on the extraction strategy.

For numeric delta:

```text
LAST_SEQ
```

means the highest numeric boundary already processed.

For timestamp delta:

```text
LAST_CHANGED_AT
```

represents a time boundary that the consumer considers already scanned.

For transactional change-log delta:

```text
LAST_SEQ
```

means the highest event sequence successfully persisted by the consumer.

These values look similar technically, but their correctness depends on different guarantees.

---

### Pointer Safety

The core rule used throughout this document is:

```text
A consumer may advance its delta pointer only when
every relevant source change before the new boundary is either:

1. already acquired, or
2. guaranteed to remain recoverable by a future request.
```

The individual delta strategies satisfy this rule in different ways.

Numeric delta depends on the semantics of the numeric field.

Timestamp delta depends on:

```text
reliable maintenance of CHANGED_AT
transaction visibility behavior
upper safety interval
lower overlap interval
delete representation
```

Transactional change-log delta depends on:

```text
transactional coupling of business change and log event
commit-consistent event ordering
durable event retention
atomic consumer persistence and pointer advancement
```

The experiments deliberately test the cases where these guarantees fail.

---

### What This Document Covers

The following topics are examined in detail:

```text
1. Numeric delta on a mutable current-state table

2. Timestamp delta and the difference between
   change time and visibility time

3. Delayed COMMIT as a timestamp-delta failure mode

4. Upper safety intervals

5. Lower safety intervals and controlled overlap

6. Physical and soft delete semantics

7. Transactional change-log delta

8. Commit-consistent event sequencing

9. Producer concurrency

10. Consumer restart and replay

11. Transactional rollback on producer failure

12. Comparison of timestamp and change-log correctness contracts
```

The focus is on correctness properties rather than framework implementation.

---

### What This Document Does Not Cover

This document does not attempt to reproduce or document the internal implementation of SAP BW generic delta.

It does not describe:

```text
DB Connect runtime internals
BW DataSource metadata
InfoPackage processing
PSA implementation
DTP execution
ADSO activation
Process Chain control
standard BW delta administration tables
```

Those components belong to the SAP BW runtime and are outside the ABAP Cloud laboratory.

The laboratory instead makes the underlying acquisition semantics explicit so that the behavior can be observed independently of the BW framework.

The same reasoning can later be mapped to SAP BW DB Connect, where the framework manages much of the request and pointer state but still depends on correct source-side delta semantics.


## Numeric Delta on a Current-State Table

A numeric delta is attractive because its consumer logic is simple.

The source exposes a numeric field:

```text
CREATED_SEQ
```

and the consumer stores the highest value already processed:

```text
LAST_SEQ
```

The extraction rule is then:

```text
CREATED_SEQ > LAST_SEQ
```

After successful persistence, the consumer advances:

```text
LAST_SEQ = highest acquired CREATED_SEQ
```

This mechanism is reliable only if the numeric field represents every business change that must be delivered to the consumer.

That requirement is stronger than simple monotonicity.

---

### Initial Source State

The laboratory starts with a current-state table:

```text
ZDB_SRC_PRICE
```

containing:

```text
P1001/SOUTH  PRICE 10.00  CREATED_SEQ 1001
P1002/SOUTH  PRICE 20.00  CREATED_SEQ 1002
P1003/SOUTH  PRICE 30.00  CREATED_SEQ 1003
P1001/NORTH  PRICE 11.50  CREATED_SEQ 1004
```

The initialization logic determines:

```text
MAX( CREATED_SEQ ) = 1004
```

and stores:

```text
LAST_SEQ = 1004
```

The consumer therefore considers all source rows up to sequence `1004` already covered.

---

### Insert After Initialization

A new source row is inserted:

```text
P1004/SOUTH
PRICE       = 40.00
CREATED_SEQ = 1005
```

The next extraction evaluates:

```text
CREATED_SEQ > 1004
```

and selects:

```text
P1004/SOUTH
```

This is the expected behavior.

For a newly created row:

```text
row creation
        |
        v
new CREATED_SEQ
        |
        v
numeric delta detects the row
```

After successful persistence:

```text
LAST_SEQ
1004 -> 1005
```

For append-only data, this model can be sufficient.

---

### Update of an Existing Row

The same experiment also updates an existing business row:

```text
P1001/SOUTH
PRICE 10.00 -> 12.00
```

Its original creation sequence remains:

```text
CREATED_SEQ = 1001
```

The consumer still evaluates:

```text
CREATED_SEQ > 1004
```

The updated row does not satisfy that condition.

Therefore:

```text
P1001/SOUTH
```

is not selected.

The business change exists in the source, but the delta field contains no evidence that the row changed.

---

### Why the Update Is Missed

The problem is not caused by the numeric comparison.

The comparison:

```text
CREATED_SEQ > LAST_SEQ
```

works exactly as designed.

The problem is the meaning of:

```text
CREATED_SEQ
```

It describes:

```text
when the row was created
```

but the consumer needs to know:

```text
when the row last changed
```

These are different semantics.

For the updated row:

```text
business state changed
```

while:

```text
delta field did not change
```

The source has therefore violated the requirement needed for change-based numeric delta.

---

### Monotonicity Is Not Sufficient

A common misconception is that a delta field is safe simply because it is monotonically increasing.

That is not enough.

`CREATED_SEQ` is perfectly monotonic for row creation:

```text
1001
1002
1003
1004
1005
...
```

but it does not advance when an existing row changes.

The real requirement is:

```text
Every relevant source change
must produce a delta value
that lies beyond the current consumer pointer.
```

For an append-only table:

```text
new business fact
=
new physical row
=
new sequence
```

This may hold naturally.

For a mutable current-state table:

```text
business change
=
UPDATE existing row
```

and no new row is necessarily created.

A creation sequence therefore cannot represent the complete change history.

---

### Correctness Contract

For a numeric high-water-mark delta to be lossless, the source must satisfy a contract similar to:

```text
For every relevant committed source change C:

delta_value(C) > delta pointer
at the point when C must become eligible for extraction.
```

More practically, the numeric field must:

```text
1. change for every relevant INSERT or UPDATE;

2. move monotonically forward;

3. never reuse a value in a way that makes a
   later change fall behind the consumer pointer;

4. remain available on the source row until
   the consumer can extract it.
```

`CREATED_SEQ` satisfies the second requirement but not the first.

That is enough to make it unsuitable for mutable current-state delta.

---

### Pointer Advancement Makes the Miss Permanent

Assume the source changes are:

```text
UPDATE P1001/SOUTH
CREATED_SEQ = 1001

INSERT P1004/SOUTH
CREATED_SEQ = 1005
```

The consumer sees only:

```text
1005
```

and after successful extraction advances:

```text
LAST_SEQ = 1005
```

The missed update remains:

```text
CREATED_SEQ = 1001
```

Future requests use:

```text
CREATED_SEQ > 1005
```

so the row will never be selected by this delta mechanism.

The loss is therefore permanent unless some separate repair mechanism is used.

---

### Why Re-Reading the Boundary Does Not Help

Changing the condition to:

```text
CREATED_SEQ >= LAST_SEQ
```

would not solve the problem.

The missed row still has:

```text
CREATED_SEQ = 1001
```

while the pointer is already:

```text
1005
```

The problem is not equality at the boundary.

It is that the changed row remains far behind the boundary.

---

### Append-Only Data

The same numeric design can be completely valid when the source is truly append-only.

For example:

```text
1001  transaction A
1002  transaction B
1003  transaction C
1004  transaction D
```

and existing records are never updated or deleted.

Then:

```text
EVENT CREATION
=
ROW CREATION
```

and:

```text
CREATED_SEQ
```

does represent the complete stream of relevant changes.

The consumer can safely use:

```text
CREATED_SEQ > LAST_SEQ
```

provided that sequence assignment and transaction visibility are also compatible with pointer advancement.

Therefore the conclusion is not:

```text
numeric delta is unreliable
```

but:

```text
numeric delta is reliable only when
the numeric field matches the source change model.
```

---

### Current-State Table vs Event Table

This distinction becomes clearer by comparing two source models.

Current-state table:

```text
P1001/SOUTH
PRICE = 12.00
CREATED_SEQ = 1001
```

The row tells us:

```text
what the current value is
```

but not:

```text
how many times it changed
or when those changes occurred
```

An event table could instead contain:

```text
1001  P1001/SOUTH  INSERT  10.00
1005  P1001/SOUTH  UPDATE  12.00
```

Now the numeric sequence belongs to:

```text
events
```

rather than:

```text
business rows
```

and each update can receive a new sequence.

This is the principle later used by the transactional change-log architecture.

---

### Acquisition and Pointer Atomicity

Even when the numeric source semantics are correct, the consumer must still advance its pointer safely.

The laboratory uses:

```text
persist acquired rows
        |
        v
update LAST_SEQ
        |
        v
COMMIT
```

in one database LUW.

This ensures that:

```text
if persistence fails
-> pointer does not advance
```

and:

```text
if the transaction is interrupted before COMMIT
-> the same source rows remain eligible for replay
```

The consumer must not commit:

```text
LAST_SEQ
```

before the corresponding acquired data is durably persisted.

This principle applies to all later delta strategies as well.

---

### Result of the Experiment

The numeric experiment produces:

```text
Source changes:

INSERT P1004/SOUTH
CREATED_SEQ = 1005
-> detected

UPDATE P1001/SOUTH
CREATED_SEQ remains 1001
-> missed
```

The resulting pointer becomes:

```text
LAST_SEQ = 1005
```

The experiment therefore proves:

```text
A creation sequence is a valid delta field
for row creation,
but not for arbitrary modification
of a mutable current-state table.
```

The key lesson is:

```text
Do not choose a delta field because it is numeric
or because it is monotonic.

Choose it only when its semantics represent
every source change that the consumer must receive.

```

## Timestamp Delta on a Current-State Table

A timestamp delta attempts to solve the main limitation of a creation-sequence delta on a mutable current-state table.

Instead of describing when a row was created, the source maintains:

```text
CHANGED_AT
```

and updates it whenever the business state of the row changes.

The consumer stores:

```text
LAST_CHANGED_AT
```

and reads:

```text
CHANGED_AT > LAST_CHANGED_AT
```

After successful persistence, the consumer advances the timestamp pointer.

This allows an existing row to become eligible for extraction again after an `UPDATE`.

---

### Initial Timestamp Baseline

Before the timestamp-delta experiment, the laboratory assigns the same timestamp:

```text
T0
```

to all current source rows.

Conceptually:

```text
P1001/SOUTH  PRICE 12.00  CHANGED_AT T0
P1002/SOUTH  PRICE 20.00  CHANGED_AT T0
P1003/SOUTH  PRICE 30.00  CHANGED_AT T0
P1001/NORTH  PRICE 11.50  CHANGED_AT T0
P1004/SOUTH  PRICE 40.00  CHANGED_AT T0
```

The timestamp consumer is then initialized with:

```text
LAST_CHANGED_AT = T0
```

This establishes a clean extraction boundary:

```text
CHANGED_AT <= T0
-> already covered

CHANGED_AT > T0
-> candidate for the next delta request
```

---

### Update of an Existing Row

The experiment changes:

```text
P1001/SOUTH
```

from:

```text
PRICE = 12.00
```

to:

```text
PRICE = 13.00
```

The row keeps its original:

```text
CREATED_SEQ = 1001
```

but receives a new:

```text
CHANGED_AT = T1
```

where:

```text
T1 > T0
```

The next timestamp request evaluates:

```text
CHANGED_AT > T0
```

and therefore selects the updated row.

This is exactly the case that the creation-sequence delta could not detect.

---

### Insert of a New Row

The same source transaction also inserts:

```text
P1005/SOUTH
PRICE       = 50.00
CREATED_SEQ = 1006
CHANGED_AT  = T1
```

The new row satisfies:

```text
CHANGED_AT > T0
```

as well.

The request therefore returns both:

```text
UPDATE P1001/SOUTH
INSERT P1005/SOUTH
```

even though their `CREATED_SEQ` values are very different.

The delta criterion is now based on:

```text
last modification time
```

rather than:

```text
row creation order
```

---

### Multiple Rows May Share the Same Timestamp

The experiment deliberately assigns the same timestamp:

```text
T1
```

to both source changes.

This demonstrates that:

```text
CHANGED_AT
```

is not necessarily a unique event identifier.

Several rows may satisfy:

```text
CHANGED_AT = T1
```

The extraction result can therefore contain:

```text
P1001/SOUTH  T1
P1005/SOUTH  T1
```

The timestamp represents a time boundary, not an individual event sequence.

This distinction becomes important when reasoning about pointer advancement and boundary handling.

---

### Improvement over Creation Sequence

The source now has:

```text
P1001/SOUTH
CREATED_SEQ = 1001
CHANGED_AT  = T1
```

Although the row was created long before the current numeric pointer, its new timestamp makes the update visible to timestamp delta.

The comparison is:

```text
Creation-sequence delta:

UPDATE existing row
CREATED_SEQ unchanged
-> not detected
```

versus:

```text
Timestamp delta:

UPDATE existing row
CHANGED_AT updated
-> detected
```

This makes timestamp delta a natural choice for mutable current-state tables.

---

### Source-Side Correctness Requirement

Timestamp delta is reliable only if every relevant source change updates:

```text
CHANGED_AT
```

For example, if the source performs:

```text
PRICE 13.00 -> 14.00
```

but leaves:

```text
CHANGED_AT = T1
```

unchanged after the consumer has already processed `T1`, the later business update becomes invisible.

Therefore the source contract must include:

```text
Every relevant INSERT or UPDATE
must assign a new CHANGED_AT value
that makes the changed row eligible
for a future extraction request.
```

This guarantee must come from the source application or database logic.

The consumer cannot reconstruct a modification that leaves no trace in the delta field.

---

### Timestamp Precision

A timestamp delta also depends on the precision and semantics of the source timestamp.

If many transactions can receive the same timestamp value, then the timestamp cannot be treated as a unique event identifier.

For example:

```text
T1  row A
T1  row B
T1  row C
```

A consumer must treat:

```text
T1
```

as a boundary containing potentially multiple rows.

This is one reason why timestamp delta requires more careful boundary management than an ordered event sequence.

---

### Naive Pointer Advancement

The initial laboratory implementation uses the simple rule:

```text
SELECT rows
WHERE CHANGED_AT > LAST_CHANGED_AT
ORDER BY CHANGED_AT, PRODUCT_ID, STORE_GROUP
```

After the selected rows have been persisted successfully, the pointer is moved to the highest processed timestamp.

Because the result is ordered by:

```text
CHANGED_AT
```

the last row contains the maximum timestamp in the selected set.

For the first experiment:

```text
old pointer = T0

selected:
P1001/SOUTH  T1
P1005/SOUTH  T1

new pointer = T1
```

Persistence and pointer advancement are committed in one LUW.

This provides consumer restart safety for the rows that were actually selected.

---

### Consumer Atomicity Is Necessary but Not Sufficient

The consumer follows the safe transaction pattern:

```text
persist acquired rows
        |
        v
update LAST_CHANGED_AT
        |
        v
COMMIT
```

If this LUW fails:

```text
acquisition persistence is rolled back
and
LAST_CHANGED_AT remains unchanged
```

so the same source rows remain eligible for another request.

This protects against consumer-side failures.

However, it does not yet prove that every relevant source change was visible when the consumer performed its `SELECT`.

That is a separate problem.

---

### Change Time and Visibility Time

The timestamp value describes when the source assigns:

```text
CHANGED_AT
```

to a row.

But another session can select that row only after the source transaction becomes visible.

These two moments are not necessarily identical.

A transaction may conceptually behave as:

```text
T1:
business row updated
CHANGED_AT = T1

        |
        | transaction remains open
        |
        v

later:
COMMIT
```

During the interval before `COMMIT`, another session may not see the row in its new state.

This introduces two different times:

```text
change time
-> represented by CHANGED_AT

visibility time
-> moment when another transaction can read the committed change
```

A reliable timestamp delta must account for the relationship between them.

---

### The Hidden Assumption of the Naive Algorithm

The simple rule:

```text
CHANGED_AT > LAST_CHANGED_AT
```

implicitly assumes that when the consumer advances its pointer to a timestamp:

```text
T
```

there cannot later appear a newly committed relevant row with:

```text
CHANGED_AT <= T
```

In other words, pointer advancement assumes:

```text
all relevant changes at or before T
are already visible and extractable
```

This assumption is stronger than merely requiring `CHANGED_AT` to be maintained correctly.

It is a transaction-visibility assumption.

---

### A New Failure Mode

Timestamp delta therefore solves one problem:

```text
existing rows can become eligible again after UPDATE
```

but introduces another correctness question:

```text
Can a transaction receive an old CHANGED_AT,
remain uncommitted,
while another later change becomes visible
and moves the consumer pointer past it?
```

If the answer is yes, then a simple timestamp high-water mark is not sufficient by itself.

The next experiment reproduces exactly this condition.

---

### Result of the Basic Timestamp Experiment

For the controlled case where both changes are committed before extraction:

```text
UPDATE P1001/SOUTH
CHANGED_AT = T1
-> detected

INSERT P1005/SOUTH
CHANGED_AT = T1
-> detected
```

The consumer advances:

```text
LAST_CHANGED_AT
T0 -> T1
```

The experiment therefore proves:

```text
CHANGED_AT can represent both row creation
and modification in a mutable current-state table,
provided every relevant change updates the field.
```

But this is not yet a complete reliability guarantee.

The next question is whether:

```text
timestamp order
```

and:

```text
transaction visibility order
```

can diverge.

That question is examined in the delayed-COMMIT experiment.
```


## Delayed COMMIT and the Visibility Gap

The basic timestamp experiment assumes that all relevant source changes are already committed when the consumer reads the source.

The next experiment removes that assumption.

Its purpose is to demonstrate that:

```text
change timestamp order
```

and:

```text
commit / visibility order
```

can differ.

This creates a failure mode in which a correctly maintained `CHANGED_AT` value is still not sufficient for lossless delta acquisition.

---

### Initial Consumer State

Assume the timestamp consumer currently stores:

```text
LAST_CHANGED_AT = T0
```

All source changes with:

```text
CHANGED_AT <= T0
```

are considered already processed.

The naive consumer reads:

```text
CHANGED_AT > LAST_CHANGED_AT
```

and moves the pointer to the highest timestamp it successfully acquires.

---

### Session B Creates an Older Change

In one database session, the source updates:

```text
P1002/SOUTH
```

from:

```text
PRICE = 20.00
```

to:

```text
PRICE = 23.00
```

The transaction assigns:

```text
CHANGED_AT = T1
```

where:

```text
T1 > T0
```

but does not commit yet.

Conceptually:

```text
Session B

UPDATE P1002/SOUTH
PRICE      = 23.00
CHANGED_AT = T1

        |
        v

transaction remains open
COMMIT has not occurred
```

The new row version exists inside Session B's transaction but is not yet visible to the independent consumer session.

---

### Session A Creates a Later Visible Change

While Session B is still uncommitted, another database session creates a later change.

For example:

```text
P1008/SOUTH
PRICE      = 80.00
CHANGED_AT = T2
```

with:

```text
T2 > T1
```

This transaction commits immediately.

The source now has two logically relevant changes:

```text
P1002/SOUTH  CHANGED_AT = T1
P1008/SOUTH  CHANGED_AT = T2
```

but their visibility differs:

```text
T1 change
-> still uncommitted
-> invisible

T2 change
-> committed
-> visible
```

The important ordering is therefore:

```text
timestamp order:

T1 -> T2
```

but:

```text
visibility order:

T2 becomes visible first
```

---

### The Naive Consumer Runs

The consumer starts with:

```text
LAST_CHANGED_AT = T0
```

and executes:

```text
SELECT ...
WHERE CHANGED_AT > T0
```

At this moment, the consumer can see:

```text
P1008/SOUTH  T2
```

but cannot see:

```text
P1002/SOUTH  T1
```

because Session B has not committed.

The extraction result is therefore:

```text
selected:
P1008/SOUTH  T2
```

The consumer persists the visible row and advances:

```text
LAST_CHANGED_AT
T0 -> T2
```

From the consumer's perspective, the request completed successfully.

There was no SQL error, no failed transaction, and no missing row among the data that was visible at request time.

---

### The Older Transaction Commits Later

Session B now resumes and executes:

```text
COMMIT
```

The update becomes visible:

```text
P1002/SOUTH
PRICE      = 23.00
CHANGED_AT = T1
```

But the consumer pointer is already:

```text
LAST_CHANGED_AT = T2
```

where:

```text
T1 < T2
```

The next naive request evaluates:

```text
CHANGED_AT > T2
```

The newly visible row does not satisfy the condition.

It remains permanently behind the consumer pointer.

---

### Lost Change

The complete sequence is:

```text
Consumer pointer = T0

Session B:
assign T1
do not commit

Session A:
assign T2
commit

Consumer:
sees T2
does not see T1
advances pointer to T2

Session B:
commit T1

Next consumer request:
CHANGED_AT > T2
```

Result:

```text
T1 is never acquired
```

The business update is committed successfully in the source but is permanently invisible to the delta consumer.

---

### Why the Timestamp Is Not Wrong

The source timestamp itself is correct.

For the delayed transaction:

```text
CHANGED_AT = T1
```

accurately represents when the business row was modified inside the transaction.

For the later transaction:

```text
CHANGED_AT = T2
```

and:

```text
T1 < T2
```

is also correct.

The failure occurs because:

```text
change time
```

and:

```text
commit visibility time
```

are different concepts.

The consumer uses the first as its ordering criterion but can observe rows only according to the second.

---

### Change Order vs Visibility Order

This distinction can be represented as:

```text
Change order:

T1 -------------------- T2
P1002                    P1008
```

while visibility may be:

```text
Visibility order:

                T2 visible
                     |
                     v
---------------------+-------------------
                         T1 visible later
                              |
                              v
```

The timestamp order therefore does not necessarily define the order in which rows become extractable.

That is the core problem.

---

### Why Consumer Atomicity Does Not Help

The consumer still uses the correct LUW pattern:

```text
persist acquired rows
        |
        v
advance LAST_CHANGED_AT
        |
        v
COMMIT
```

This protects against failures inside the consumer transaction.

However, the consumer can commit only what it actually selected.

The missing row:

```text
P1002/SOUTH
```

was invisible during the `SELECT`.

Consumer-side atomicity therefore cannot protect against a source transaction that becomes visible only after the pointer has moved past its timestamp.

This demonstrates two different correctness requirements:

```text
Consumer atomicity
-> protects against consumer failure
```

and:

```text
Source visibility handling
-> protects against late-visible source changes
```

Both are required for reliable timestamp delta.

---

### Why `>=` Does Not Solve the Problem

A possible reaction is to replace:

```text
CHANGED_AT > LAST_CHANGED_AT
```

with:

```text
CHANGED_AT >= LAST_CHANGED_AT
```

This can help with rows that share exactly the same timestamp as the current pointer.

It does not solve the delayed-COMMIT scenario.

After the first request:

```text
LAST_CHANGED_AT = T2
```

The delayed row has:

```text
CHANGED_AT = T1
```

and:

```text
T1 < T2
```

Therefore even:

```text
CHANGED_AT >= T2
```

does not select it.

The failure is not an equality problem.

It is an ordering problem.

---

### Equality Boundary and Visibility Gap Are Different Problems

Two separate cases must be distinguished.

Boundary equality:

```text
row A = T1
row B = T1
pointer = T1
```

This is a question of how to handle multiple rows sharing one timestamp.

Visibility gap:

```text
row A = T1
row B = T2
T1 < T2

row A becomes visible only after
the pointer has advanced to T2
```

This is a different problem.

Changing the comparison operator addresses only the first category.

It cannot recover a row whose timestamp is already strictly below the pointer.

---

### Hidden Correctness Requirement

The naive timestamp algorithm is correct only if the source can guarantee:

```text
Once the consumer advances to timestamp T,
no relevant transaction can later become visible
with CHANGED_AT <= T.
```

This is a strong requirement.

It means that source transaction behavior must be compatible with the time-based high-water mark.

Without such a guarantee, the consumer cannot know whether the time interval it has just scanned is truly complete.

---

### Visibility Lag

Define:

```text
visibility lag
```

as the time between:

```text
assigning CHANGED_AT
```

and:

```text
the change becoming committed and visible
to the extraction session
```

For an immediately committed transaction:

```text
visibility lag ≈ small
```

For a long-running transaction:

```text
visibility lag = potentially much larger
```

The delayed-COMMIT experiment intentionally creates a visibility lag long enough for another transaction to:

```text
receive a later timestamp
commit
be extracted
move the pointer forward
```

before the older transaction becomes visible.

---

### Why This Is a Delta-Pointer Problem

The consumer cannot simply ask:

```text
What rows changed?
```

It must also decide:

```text
Up to what point in the source history
is it safe to declare extraction complete?
```

The naive reader assumes:

```text
highest visible CHANGED_AT
=
safe completed boundary
```

The experiment proves that this equality is not generally valid.

The highest visible timestamp only means:

```text
this is the newest timestamp currently visible
```

It does not necessarily mean:

```text
all older timestamps are already visible
```

---

### Result of the Experiment

The experiment demonstrates:

```text
T0  consumer pointer

T1  P1002 updated
    transaction remains uncommitted

T2  P1008 inserted
    transaction commits

consumer sees T2
consumer advances T0 -> T2

T1 transaction commits later

next request uses:
CHANGED_AT > T2

T1 is lost
```

The key conclusion is:

```text
A correct CHANGED_AT field is necessary
but not sufficient for reliable timestamp delta.
```

The consumer also needs a way to avoid declaring the most recent time region complete while transactions belonging to that region may still be invisible.

This motivates the next mechanism:

```text
Upper Safety Interval
```

Instead of extracting up to the current request time, the consumer deliberately leaves a recent time window unprocessed.

That window gives delayed transactions time to commit before the delta pointer is allowed to move past their timestamps.


## Upper Safety Interval

The delayed-COMMIT experiment shows that the newest visible timestamp is not necessarily a safe delta boundary.

A transaction may already have:

```text
CHANGED_AT = T1
```

while remaining uncommitted and therefore invisible to the extraction session.

At the same time, another transaction with:

```text
CHANGED_AT = T2
```

where:

```text
T1 < T2
```

may commit earlier and become visible.

If the consumer immediately advances its pointer to `T2`, the later-visible `T1` change can be lost.

The upper safety interval addresses this problem by deliberately leaving the most recent time region unprocessed.

---

### Basic Idea

Instead of reading all changes up to the current request time:

```text
LAST_CHANGED_AT < CHANGED_AT <= REQUEST_START
```

the consumer defines:

```text
UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

and reads only:

```text
LAST_CHANGED_AT < CHANGED_AT <= UPPER_BOUND
```

The interval:

```text
UPPER_BOUND < CHANGED_AT <= REQUEST_START
```

is intentionally excluded from the current request.

This is the upper safety zone.

---

### Safety Zone

Assume:

```text
REQUEST_START = 10:10:00
UPPER_SAFETY_INTERVAL = 5 minutes
```

Then:

```text
UPPER_BOUND = 10:05:00
```

The consumer may safely scan only:

```text
CHANGED_AT <= 10:05:00
```

while changes in:

```text
10:05:00 < CHANGED_AT <= 10:10:00
```

remain outside the current request.

Conceptually:

```text
past                                      now

--------- safe scan ---------|--- safety zone ---|
                             |
                         UPPER_BOUND
```

The consumer intentionally accepts additional latency in exchange for a stronger visibility guarantee.

---

### Why the Delay Helps

Consider again a delayed source transaction.

Session B performs:

```text
UPDATE P1002/SOUTH
PRICE      = 23.00
CHANGED_AT = T1
```

but does not commit immediately.

A second session creates:

```text
P1008/SOUTH
PRICE      = 80.00
CHANGED_AT = T2
```

and commits it.

As before:

```text
T1 < T2
```

but:

```text
T2 becomes visible before T1
```

With the naive reader, `T2` could move the pointer beyond `T1`.

With an upper safety interval, both timestamps may still lie inside the protected recent region:

```text
T1 > UPPER_BOUND
T2 > UPPER_BOUND
```

The current request therefore selects neither row.

The consumer does not advance beyond them.

---

### Waiting for the Safety Zone to Move

Time passes.

The delayed transaction commits.

A later extraction request starts at a newer time:

```text
REQUEST_START = T3
```

and computes:

```text
UPPER_BOUND =
T3 - UPPER_SAFETY_INTERVAL
```

Eventually:

```text
T1 <= UPPER_BOUND
T2 <= UPPER_BOUND
```

Both changes now lie in the extractable region.

Because the delayed transaction has already committed, the consumer can see:

```text
P1002/SOUTH  T1
P1008/SOUTH  T2
```

in the same request.

The time boundary therefore moves forward only after the source has had additional time to make older transactions visible.

---

### Laboratory Selection Rule

The safe timestamp reader uses:

```text
CHANGED_AT > LAST_CHANGED_AT
AND
CHANGED_AT <= UPPER_BOUND
```

before lower overlap is introduced.

Conceptually:

```text
LAST_CHANGED_AT
        |
        | extractable region
        v
--------+--------------------+---------- REQUEST_START
                             |
                         UPPER_BOUND
                             |
                             +---- recent region not yet scanned
```

This changes the meaning of pointer advancement.

The consumer is no longer asking:

```text
What is the newest visible timestamp?
```

It is asking:

```text
Up to what time boundary am I prepared
to declare the source safely scanned?
```

---

### Pointer Advances to the Boundary

An important property of the safe reader is that the persistent pointer represents the scanned time boundary:

```text
LAST_CHANGED_AT = UPPER_BOUND
```

after a successful request.

It does not necessarily become:

```text
MAX( CHANGED_AT )
```

from the rows returned by that request.

These are different concepts.

---

### Empty Request Can Still Advance the Pointer

Suppose:

```text
old LAST_CHANGED_AT = 09:30
UPPER_BOUND          = 09:35
```

and no source rows exist with:

```text
09:30 < CHANGED_AT <= 09:35
```

The request returns:

```text
0 rows
```

but the interval has still been successfully scanned.

The consumer may therefore advance:

```text
LAST_CHANGED_AT
09:30 -> 09:35
```

This is correct because the pointer means:

```text
source time successfully scanned
```

rather than:

```text
timestamp of the last row received
```

This distinction is important for safety-window delta processing.

---

### Pointer as a Time Frontier

The safe timestamp pointer can therefore be interpreted as a frontier:

```text
everything at or before LAST_CHANGED_AT
has been declared processed
according to the visibility contract
```

The next request extends that frontier:

```text
old frontier
     |
     v
-----+---------------------+--------->
                           |
                      new UPPER_BOUND
```

After successful completion:

```text
new frontier = UPPER_BOUND
```

whether the interval contained:

```text
many rows
one row
zero rows
```

---

### Reproducing the Experiment

The laboratory reproduces the delayed-COMMIT scenario using two sessions.

The delayed transaction assigns approximately:

```text
T1 = 10:00:50
```

and remains uncommitted.

A later transaction commits approximately at:

```text
T2 = 10:01:13
```

The safe reader initially calculates upper boundaries that are still earlier than both changes, for example:

```text
UPPER_BOUND = 09:59:16
```

and later:

```text
UPPER_BOUND = 10:00:32
```

The requests select:

```text
0 rows
```

because the protected region has not yet moved past the source changes.

The pointer can still advance to each successfully scanned `UPPER_BOUND`.

After the delayed transaction commits and sufficient time passes, a later request calculates approximately:

```text
REQUEST_START = 10:09:51
UPPER_BOUND   = 10:04:51
```

Now:

```text
T1 <= 10:04:51
T2 <= 10:04:51
```

and both rows are visible.

The reader selects:

```text
P1002/SOUTH  T1
P1008/SOUTH  T2
```

The previously demonstrated loss no longer occurs.

---

### What the Upper Safety Interval Guarantees

The mechanism works if the source satisfies a bounded visibility-lag contract.

Let:

```text
D
```

be the maximum possible delay between:

```text
assigning CHANGED_AT
```

and:

```text
the transaction becoming committed and visible
to the extraction session
```

Then the upper safety interval must be large enough to cover that delay:

```text
UPPER_SAFETY_INTERVAL >= D
```

subject to the exact timestamp and transaction semantics of the source system.

Under that assumption, when a timestamp passes behind:

```text
UPPER_BOUND
```

all relevant transactions carrying that timestamp should already be visible.

Only then is it safe to move the time frontier beyond them.

---

### The Guarantee Is Conditional

The upper safety interval is not a universal solution.

Its correctness depends on the existence of a finite maximum visibility lag.

Suppose the safety interval is:

```text
5 minutes
```

but a source transaction can remain open for:

```text
20 minutes
```

after assigning `CHANGED_AT`.

Then the consumer may eventually move:

```text
UPPER_BOUND
```

past that transaction's timestamp while the transaction is still invisible.

The original failure becomes possible again.

Therefore:

```text
finite upper safety
+
unbounded visibility lag
=
no strict lossless guarantee
```

---

### Larger Safety Interval vs Latency

Increasing the safety interval provides more protection.

For example:

```text
1 minute
5 minutes
30 minutes
2 hours
```

progressively reduce the risk that an old timestamp still belongs to an uncommitted transaction.

But the cost is acquisition latency.

With:

```text
UPPER_SAFETY_INTERVAL = 30 minutes
```

a newly committed change may intentionally wait up to approximately 30 minutes before becoming eligible for extraction.

Therefore the parameter represents a trade-off:

```text
larger safety interval
-> stronger tolerance for delayed visibility
-> higher data latency

smaller safety interval
-> lower latency
-> stronger requirement on source transaction duration
```

---

### Safety Value Must Come from the Source Contract

The laboratory uses:

```text
UPPER_SAFETY_INTERVAL = 300 seconds
```

only because five minutes makes the experiment easy to observe.

This is not a production recommendation.

A real value must be based on source-system behavior such as:

```text
maximum transaction duration
batch commit behavior
locking patterns
database isolation
application processing time
operational SLA
```

The correct configuration therefore cannot be determined from the extractor alone.

It is part of the interface contract between source and consumer.

---

### Upper Safety Does Not Require Duplicate Delivery

The upper safety interval moves the upper boundary backward.

It does not, by itself, move the lower boundary backward.

If the previous pointer is:

```text
LAST_CHANGED_AT = T0
```

and the new safe boundary is:

```text
UPPER_BOUND = T1
```

the request can read:

```text
T0 < CHANGED_AT <= T1
```

without intentionally rereading the already processed region.

The mechanism therefore primarily introduces:

```text
latency
```

rather than:

```text
overlap
```

Intentional overlap is introduced separately by the lower safety interval.

---

### Upper Safety and Consumer Atomicity

The same transaction rule still applies:

```text
persist selected rows
        |
        v
advance LAST_CHANGED_AT to UPPER_BOUND
        |
        v
COMMIT
```

If persistence or pointer update fails:

```text
ROLLBACK
```

leaves the previous pointer unchanged.

The interval can then be scanned again.

The upper safety interval protects the source-side visibility boundary.

Consumer transaction atomicity protects restart behavior.

These are complementary guarantees.

---

### Architectural Meaning

The upper safety interval changes the timestamp-delta model from:

```text
extract everything visible up to now
```

to:

```text
extract only the part of source time
that is old enough to be considered stable
```

This is the essential idea.

The consumer intentionally stays behind real time so that:

```text
timestamp assignment
```

and:

```text
transaction visibility
```

have time to converge.

---

### Result of the Experiment

The delayed-COMMIT scenario changes from:

```text
Naive delta:

T1 uncommitted
T2 committed
consumer sees T2
pointer -> T2
T1 commits later
T1 lost
```

to:

```text
Upper-safety delta:

T1 uncommitted
T2 committed

both still inside recent safety zone
consumer does not move past them

T1 commits

time advances
T1 and T2 move behind UPPER_BOUND

consumer sees both
pointer -> safe time boundary
```

The experiment therefore demonstrates:

```text
An upper safety interval can protect timestamp delta
against delayed COMMIT
when the maximum source visibility lag is bounded
by the configured safety window.
```

It also establishes an important semantic change:

```text
LAST_CHANGED_AT
```

should be understood as:

```text
the latest source-time boundary
successfully and safely scanned
```

rather than simply:

```text
the maximum timestamp returned by the previous request
```

The next step is to extend this model with a lower safety interval, which intentionally rereads part of the already scanned time range and introduces controlled overlap


## Lower Safety Interval and Controlled Overlap

The upper safety interval protects the newest time region by delaying extraction until source changes are old enough to be considered stable.

The lower safety interval addresses a different problem.

Instead of moving the upper boundary backward, it moves the lower extraction boundary backward.

This intentionally re-reads part of the time range that the consumer has already processed.

The purpose is controlled overlap.

---

### Basic Idea

Assume the persistent timestamp pointer is:

```text
LAST_CHANGED_AT = T0
```

Without lower overlap, the next request would start from:

```text
CHANGED_AT > T0
```

With a lower safety interval, the reader calculates:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

and uses:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

The interval:

```text
LOWER_BOUND < CHANGED_AT <= LAST_CHANGED_AT
```

has already been scanned by the previous request.

It is deliberately read again.

---

### Complete Safe Timestamp Window

With both safety intervals, the request becomes:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL

UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

and the source selection is:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

Conceptually:

```text
past                                                     now

---- overlap ----|--------- new scan ---------|-- upper safety --|
                 |                            |
         LAST_CHANGED_AT                 UPPER_BOUND
        /
LOWER_BOUND
```

The three regions have different meanings:

```text
LOWER_BOUND < CHANGED_AT <= LAST_CHANGED_AT
-> already scanned before
-> intentionally re-read

LAST_CHANGED_AT < CHANGED_AT <= UPPER_BOUND
-> newly scanned region

UPPER_BOUND < CHANGED_AT <= REQUEST_START
-> intentionally delayed recent region
```

---

### Why Re-Read the Past

The lower interval gives the consumer another opportunity to see source rows close to the previous boundary.

Suppose a previous request advanced:

```text
LAST_CHANGED_AT = T0
```

The next request does not start exactly at `T0`.

Instead, it may restart from:

```text
T0 - 5 minutes
```

This means that rows near the previous boundary can appear again.

The mechanism therefore prefers:

```text
possible duplicate delivery
```

over:

```text
a perfectly non-overlapping sequence of requests
```

---

### Pointer Does Not Move Backward

The lower boundary is temporary.

It affects only the current selection.

The persistent pointer remains:

```text
LAST_CHANGED_AT
```

until the request completes successfully.

For example:

```text
persistent pointer = 10:04:51
lower safety       = 5 minutes

LOWER_BOUND = 09:59:51
```

The request reads from:

```text
09:59:51
```

but the stored pointer is not changed to that value.

After successful processing, the pointer moves forward to the new:

```text
UPPER_BOUND
```

Therefore:

```text
LOWER_BOUND
-> request read boundary

LAST_CHANGED_AT
-> persistent consumer frontier
```

These values have different purposes.

---

### Repeated After-Images

In the laboratory, the first successful safe request acquires rows such as:

```text
P1002/SOUTH
P1008/SOUTH
```

After the request completes, the pointer advances.

A later request calculates a lower boundary that reaches back into the timestamp range containing those same rows.

As a result, the rows can be selected again.

For example:

```text
Run A

P1002/SOUTH  T1
P1008/SOUTH  T2
```

and later:

```text
Run B

P1002/SOUTH  T1
P1008/SOUTH  T2
```

The acquisition table therefore contains multiple after-images of the same business keys under different:

```text
RUN_ID
```

values.

This behavior is intentional.

---

### Duplicate Delivery Is Not Data Corruption

The repeated rows are not necessarily incorrect data.

They represent repeated delivery of the same current-state after-image.

For example:

```text
P1002/SOUTH
PRICE = 23.00
```

may be delivered twice.

If the downstream target applies overwrite semantics:

```text
target value = source after-image
```

then processing the same value twice produces the same final state.

Conceptually:

```text
apply 23.00
apply 23.00 again
```

still results in:

```text
23.00
```

This makes duplicate delivery compatible with idempotent or overwrite-style processing.

---

### Additive Processing Is Different

The same duplicate behavior can be dangerous for additive semantics.

Suppose an extracted row means:

```text
add 10 units
```

instead of:

```text
current value = 10 units
```

If the row is delivered twice:

```text
+10
+10
```

the target becomes:

```text
+20
```

even though the business event occurred only once.

Therefore lower-overlap timestamp delta is naturally compatible with:

```text
after-image / overwrite semantics
```

but requires additional duplicate handling for:

```text
additive
non-idempotent
event-based
```

processing.

---

### Current-State Semantics Matter

The source in this laboratory is a mutable current-state table.

A selected row represents:

```text
the current after-image of a business key
```

rather than:

```text
a unique business event
```

This makes controlled overlap practical.

If the same row is re-read without any further source modification, the consumer receives the same current state again.

This is fundamentally different from replaying a transactional event such as:

```text
SALE +100
```

where duplicate execution would change the business result.

---

### Lower Safety and Delayed Visibility

The lower safety interval can also provide additional tolerance near a previous boundary.

Suppose a row becomes visible slightly later than expected but its:

```text
CHANGED_AT
```

still lies within the overlap range.

The next request may select it because the lower boundary has moved backward.

This provides an additional opportunity for recovery.

However, this protection is limited.

---

### Lower Safety Is Not an Unlimited Recovery Window

Suppose:

```text
LAST_CHANGED_AT = 10:10
LOWER_SAFETY_INTERVAL = 5 minutes
```

The next request begins from approximately:

```text
10:05
```

Now consider a transaction with:

```text
CHANGED_AT = 10:00
```

that becomes visible only after the pointer has already moved beyond:

```text
10:10
```

Its timestamp is already older than:

```text
LOWER_BOUND = 10:05
```

The overlap request will not recover it.

Therefore:

```text
lower safety
```

does not eliminate the requirement for bounded source visibility lag.

It only creates a finite reread window.

---

### Combined Protection

The two safety intervals serve different purposes.

Upper safety:

```text
delays the newest region
```

Lower safety:

```text
re-reads part of the previous region
```

Together:

```text
                 persistent pointer
                        |
                        v

---- overlap -----------|-------- new region --------|-- delayed --|
                        |                            |
                 LAST_CHANGED_AT                UPPER_BOUND
        ^
        |
   LOWER_BOUND
```

The resulting strategy is:

```text
do not trust the newest source time immediately
+
do not trust the previous boundary only once
```

This is stronger than a simple non-overlapping timestamp high-water mark.

---

### Persistent Pointer Semantics

After a successful request:

```text
LAST_CHANGED_AT = UPPER_BOUND
```

The lower safety interval does not change this rule.

The pointer still means:

```text
latest source-time frontier
that the consumer considers safely scanned
```

The overlap is reconstructed dynamically from that pointer:

```text
next LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

This keeps the persistent state simple.

---

### Example

Assume:

```text
LAST_CHANGED_AT = 10:04:51

LOWER_SAFETY_INTERVAL = 5 minutes
UPPER_SAFETY_INTERVAL = 5 minutes

REQUEST_START = 10:15:00
```

Then:

```text
LOWER_BOUND = 09:59:51
UPPER_BOUND = 10:10:00
```

The request reads:

```text
09:59:51 < CHANGED_AT <= 10:10:00
```

This includes:

```text
09:59:51 .. 10:04:51
-> overlap with previously processed source time

10:04:51 .. 10:10:00
-> newly scanned source time
```

After successful persistence:

```text
LAST_CHANGED_AT
10:04:51 -> 10:10:00
```

The pointer moves only forward.

---

### Next Request

Suppose the next request starts at:

```text
10:20:00
```

Then:

```text
LOWER_BOUND = 10:05:00
UPPER_BOUND = 10:15:00
```

The new request reads:

```text
10:05:00 < CHANGED_AT <= 10:15:00
```

Part of the previous request:

```text
10:05:00 .. 10:10:00
```

is read again.

The new region:

```text
10:10:00 .. 10:15:00
```

is scanned for the first time.

This pattern repeats for every request.

---

### Controlled At-Least-Once Behavior

At the acquisition boundary, lower overlap creates behavior similar to:

```text
at least once
```

for rows near the timestamp frontier.

The consumer may receive:

```text
one copy
or
multiple copies
```

of the same after-image.

The design therefore does not attempt to guarantee:

```text
exactly once delivery
```

at the extraction boundary.

Instead, it relies on:

```text
safe replay
+
idempotent downstream application
```

where appropriate.

---

### Why This Can Be Preferable

Trying to eliminate every duplicate at the extraction boundary can make the design more fragile.

Controlled rereading is often simpler than trying to construct a perfectly exact timestamp boundary from a source whose transaction visibility is not perfectly synchronized with timestamp assignment.

The trade-off is explicit:

```text
more overlap
-> more duplicate acquisition
-> more protection near boundaries

less overlap
-> fewer duplicates
-> stronger dependence on exact source timing
```

The correct balance depends on the source and target semantics.

---

### Lower Safety Does Not Replace Upper Safety

It is important not to treat the lower safety interval as an alternative to the upper safety interval.

Consider a transaction whose timestamp is:

```text
T1
```

but whose visibility is delayed long enough that the consumer repeatedly moves its pointer forward.

If `T1` eventually falls outside the lower overlap range before the transaction becomes visible, the change can still be lost.

Upper safety attempts to prevent the pointer from crossing such a timestamp too early.

Lower safety provides repeated observation near the boundary.

Therefore:

```text
upper safety
-> protects before pointer advancement

lower safety
-> provides overlap after pointer advancement
```

They solve related but different problems.

---

### Bounded Visibility Lag Still Required

Even with both intervals:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

the timestamp architecture still relies on a finite timing assumption.

If source transaction visibility can be delayed arbitrarily long, then eventually a timestamp may become older than both:

```text
UPPER safety protection
```

and:

```text
LOWER overlap protection
```

before the corresponding transaction becomes visible.

Therefore:

```text
finite upper safety
+
finite lower overlap
```

cannot provide a strict guarantee against:

```text
unbounded delayed COMMIT
```

This limitation is architectural, not an implementation bug.

---

### Laboratory Values

The project uses:

```text
LOWER_SAFETY_INTERVAL = 300 seconds
UPPER_SAFETY_INTERVAL = 300 seconds
```

These values exist only to make the experiments observable.

They are not production recommendations.

Production values would need to be based on:

```text
source transaction duration
visibility lag measurements
timestamp precision
request frequency
acceptable latency
duplicate-processing cost
operational SLA
```

---

### Result of the Experiment

The lower-safety experiment demonstrates:

```text
previous pointer = T0

next request starts from:
T0 - LOWER_SAFETY_INTERVAL

previously acquired rows near T0
are selected again

same business after-images
are persisted under a new RUN_ID
```

The duplicate acquisition is expected.

The experiment therefore establishes:

```text
Lower safety deliberately trades
duplicate after-images
for additional boundary tolerance.
```

The key distinction is:

```text
Upper safety
-> delays recent source time

Lower safety
-> rereads recent past source time
```

Together they form the safe timestamp window:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

but their reliability still depends on a bounded source visibility contract.

The next delta problem is different again:

```text
What happens when the source row disappears completely?
```

That question leads to physical and soft delete semantics.


## Physical and Soft Delete Semantics

Timestamp delta can detect inserts and updates as long as the current-state row remains present and its:

```text
CHANGED_AT
```

is updated correctly.

Deletion introduces a different problem.

If the source physically removes a row, the row no longer exists when the consumer performs its next query.

The consumer therefore has nothing left to select.

This means that a timestamp field alone cannot make a physical delete visible.

---

### Physical DELETE

Assume the source contains:

```text
P1003/SOUTH
PRICE      = 30.00
CHANGED_AT = T1
```

The source application performs:

```text
DELETE P1003/SOUTH
```

After commit, the current-state table contains no row for:

```text
P1003/SOUTH
```

The timestamp consumer executes:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

but there is no remaining source row whose:

```text
CHANGED_AT
```

can satisfy the condition.

The physical delete is therefore invisible.

---

### Why Updating CHANGED_AT Is Impossible After DELETE

For inserts and updates, the source can maintain:

```text
CHANGED_AT
```

on the row itself.

For a physical delete:

```text
row removed
```

means that all row attributes disappear together:

```text
PRODUCT_ID
STORE_GROUP
PRICE
CURRENCY
CHANGED_AT
IS_DELETED
```

The consumer cannot later query a timestamp from an object that no longer exists.

The problem is therefore not:

```text
insufficient timestamp precision
```

or:

```text
incorrect safety intervals
```

It is a source-model problem.

The current-state table no longer contains evidence that the deleted business key ever existed.

---

### Full Extraction and Physical DELETE

A full extraction can indirectly reveal a missing row by comparing two complete snapshots.

For example:

```text
Previous snapshot:

P1001
P1002
P1003
```

Later snapshot:

```text
P1001
P1002
```

A downstream reconciliation process could infer:

```text
P1003 disappeared
```

However, this is not ordinary timestamp delta.

It requires:

```text
complete snapshot comparison
```

and retained knowledge of the previous state.

The laboratory delta consumer intentionally does not use that strategy.

---

### Timestamp Delta Needs Explicit Delete Semantics

For a current-state timestamp source, deletion must remain represented in some extractable form.

One common approach is:

```text
soft delete
```

Instead of physically removing the row, the source changes a deletion marker such as:

```text
IS_DELETED = 'X'
```

and updates:

```text
CHANGED_AT
```

The row remains queryable and can therefore participate in the normal timestamp-delta mechanism.

---

### Soft DELETE

The laboratory restores the previously deleted business key and then performs:

```text
P1003/SOUTH
IS_DELETED = 'X'
CHANGED_AT = T2
```

The row remains in:

```text
ZDB_SRC_PRICE
```

but its business meaning changes.

The source state becomes conceptually:

```text
P1003/SOUTH
PRICE       = 30.00
IS_DELETED  = X
CHANGED_AT  = T2
```

The timestamp reader can now evaluate:

```text
LOWER_BOUND < T2 <= UPPER_BOUND
```

and acquire the row normally.

---

### Two Independent Pieces of Information

A soft-delete record carries two different kinds of information.

`CHANGED_AT` answers:

```text
When did this row become relevant
for delta extraction?
```

`IS_DELETED` answers:

```text
What does this changed row mean?
```

The two fields therefore serve different purposes.

Conceptually:

```text
CHANGED_AT
-> delta eligibility

IS_DELETED
-> delete semantics
```

The consumer needs both.

A changed timestamp without a delete marker would look like an ordinary update.

A delete marker without a new timestamp might never become eligible for delta extraction.

---

### Resulting Delta Behavior

With a soft delete:

```text
before:

P1003/SOUTH
IS_DELETED = ''
CHANGED_AT = T1
```

after:

```text
P1003/SOUTH
IS_DELETED = 'X'
CHANGED_AT = T2
```

The timestamp consumer receives:

```text
P1003/SOUTH
IS_DELETED = X
```

as a normal after-image.

The downstream layer can then interpret the marker according to its own target semantics.

For example:

```text
delete target record
```

or:

```text
mark target object inactive
```

or:

```text
close validity interval
```

The acquisition layer only needs to preserve the delete meaning.

---

### Physical and Soft DELETE Compared

The difference is:

```text
Physical DELETE

source row disappears
        |
        v
no CHANGED_AT remains
        |
        v
timestamp delta sees nothing
```

versus:

```text
Soft DELETE

source row remains
        |
        v
IS_DELETED = X
CHANGED_AT updated
        |
        v
timestamp delta selects the row
```

This is why soft deletion fits naturally with a current-state timestamp source.

---

### Tombstone Semantics

A soft-deleted row can be treated as a tombstone.

A tombstone means:

```text
this business key no longer represents
an active source object,
but the deletion information must remain
available to downstream consumers
```

The source therefore retains a technical representation of the deleted object even though the business object is no longer active.

This retention is necessary because consumers may not read the source immediately.

---

### Tombstone Retention

A soft-delete architecture introduces a new lifecycle question:

```text
How long must the tombstone remain?
```

The answer depends on the acquisition contract.

If the source removes the tombstone too early:

```text
soft delete
        |
        v
consumer has not yet acquired it
        |
        v
physical purge
```

then the delete can become invisible again.

Therefore a tombstone must remain until the source can guarantee that every required consumer has had sufficient opportunity to receive it.

The laboratory does not implement a tombstone-retention mechanism.

It only demonstrates the acquisition semantics.

---

### Safety Intervals Still Apply

A soft delete is still a timestamp-based change.

Therefore it is subject to the same visibility rules as any other update.

For example:

```text
IS_DELETED = X
CHANGED_AT = T1
```

may be assigned inside a transaction that does not commit immediately.

The timestamp consumer must still rely on:

```text
upper safety
lower overlap
bounded visibility lag
```

to avoid moving its pointer past a late-visible tombstone.

Soft deletion solves:

```text
representation of DELETE
```

but does not solve:

```text
transaction visibility
```

These are separate concerns.

---

### Repeated Tombstones

Lower safety overlap may cause the same soft-delete row to be delivered more than once.

For example:

```text
Run A:
P1003/SOUTH  IS_DELETED = X
```

and later:

```text
Run B:
P1003/SOUTH  IS_DELETED = X
```

This should be treated as repeated delivery of the same delete after-image.

A downstream target should therefore ideally support idempotent delete handling.

Conceptually:

```text
delete P1003
delete P1003 again
```

should not produce an incorrect state.

This is another reason why downstream semantics matter when timestamp overlap is used.

---

### Soft DELETE Preserves Current-State Modeling

Even with tombstones, the source remains fundamentally a current-state model.

For each business key, the table stores one current representation:

```text
active current row
```

or:

```text
deleted current row / tombstone
```

It does not preserve the complete history:

```text
INSERT
UPDATE
UPDATE
DELETE
```

as separate events.

Only the latest row state remains.

This distinction becomes important when comparing timestamp delta with a transactional change log.

---

### Loss of Intermediate Changes

Suppose the same business key changes several times between extraction requests:

```text
10.00
-> 12.00
-> 15.00
```

and the consumer finally reads:

```text
PRICE = 15.00
```

A current-state timestamp source may deliver only the latest after-image.

The intermediate value:

```text
12.00
```

may no longer exist.

Similarly, a row could conceptually undergo:

```text
UPDATE
UPDATE
SOFT DELETE
```

before the next extraction.

The consumer may see only:

```text
IS_DELETED = X
```

This can be completely correct when the integration requirement is:

```text
synchronize current state
```

but it is not sufficient when the requirement is:

```text
preserve every business event
```

---

### Current-State Synchronization vs Event History

Soft-delete timestamp delta is appropriate when the consumer primarily needs to know:

```text
What should the current target state be?
```

It is less suitable when the consumer needs to know:

```text
Exactly what sequence of operations occurred?
```

For example:

```text
current-state requirement:

P1003 is deleted
```

may be enough.

But an audit or transactional process may require:

```text
P1003 inserted
P1003 updated
P1003 updated again
P1003 deleted
```

A current-state table does not necessarily retain that history.

---

### Alternative: Separate Delete Log

Another possible source design is to maintain physical current-state data together with a separate deletion log.

Conceptually:

```text
CURRENT_TABLE
+
DELETE_LOG
```

The current table may physically remove rows, while the delete log preserves keys and deletion timestamps.

This can make physical deletion visible to a delta consumer.

However, once separate change records are introduced, the architecture begins to move toward an explicit change-log model.

The laboratory explores that stronger model directly with:

```text
ZDB_CHANGE_LOG
```

---

### Transactional Change Log

In the change-log architecture, physical deletion is no longer a problem because the delete itself becomes an event.

For example:

```text
EVENT_SEQ = 1004
PRODUCT_ID = P1010
STORE_GROUP = SOUTH
OPERATION = D
```

The current-state row may then be physically removed:

```text
DELETE P1010/SOUTH
```

while the deletion information remains durable in the event stream.

This separates:

```text
current business state
```

from:

```text
change history
```

---

### Timestamp Soft DELETE vs Change-Log DELETE

The two approaches can be compared as:

```text
Timestamp + soft delete

current-state row remains
IS_DELETED = X
CHANGED_AT updated

consumer detects deletion
through current-state after-image
```

versus:

```text
Transactional change log

current-state row may disappear
D event remains in log

consumer detects deletion
through explicit event
```

The first architecture modifies the current-state model to preserve delete information.

The second preserves delete information outside the current-state table.

---

### Source Contract for Soft DELETE

For soft-delete timestamp delta to be reliable, the source must guarantee:

```text
1. Physical deletion is not performed
   before the tombstone is safely retained.

2. Every logical deletion sets IS_DELETED.

3. Every logical deletion updates CHANGED_AT.

4. The tombstone remains available long enough
   for required consumers to acquire it.

5. Timestamp visibility still satisfies
   the configured safety-window contract.
```

If any of these conditions fails, deletion information can be lost.

---

### Source Contract for Physical DELETE

A pure current-state timestamp source cannot reliably communicate physical deletion after the row has disappeared.

Therefore a system that requires physical deletion must provide some additional durable representation, such as:

```text
delete log
change-log table
CDC stream
transactional outbox
database redo-log based CDC
```

The exact technology is not important for the laboratory conclusion.

The important requirement is:

```text
DELETE must leave an extractable trace.
```

---

### Result of the Experiment

The physical-delete experiment produces:

```text
DELETE P1003/SOUTH

source row disappears

timestamp reader:
0 deletion rows
```

The consumer cannot detect the change.

The soft-delete experiment produces:

```text
P1003/SOUTH
IS_DELETED = X
CHANGED_AT = T2
```

and after the timestamp enters the safe extraction window:

```text
timestamp reader:
P1003/SOUTH acquired
IS_DELETED = X
```

The central conclusion is:

```text
A current-state timestamp delta can detect deletion
only if deletion remains represented
in the extractable source state.
```

For this architecture:

```text
physical DELETE
-> invisible

soft DELETE / tombstone
-> visible
```

This solves deletion for current-state synchronization, but it still does not provide a durable ordered history of all source operations.

That requirement leads to the next source model:

```text
Transactional Change Log
```



## Transactional Change Log

Timestamp delta derives changes from the current state of a business row.

The transactional change-log architecture uses a different source model.

Instead of asking:

```text
Which current rows appear to have changed
after the previous timestamp boundary?
```

the consumer asks:

```text
Which committed change events occurred
after the previous event-sequence boundary?
```

This changes both the source representation and the basis of correctness.

---

### Current State and Change History Are Separated

The laboratory keeps the current business state in:

```text
ZDB_SRC_PRICE
```

and the ordered change history in:

```text
ZDB_CHANGE_LOG
```

The two tables answer different questions.

`ZDB_SRC_PRICE` answers:

```text
What is the current state
of PRODUCT_ID + STORE_GROUP?
```

`ZDB_CHANGE_LOG` answers:

```text
What business changes occurred,
and in what order?
```

For example, the current-state table may contain only:

```text
P1001/SOUTH
PRICE = 16.00
```

while the change log may contain:

```text
1002  P1001/SOUTH  U  14.00
1005  P1001/SOUTH  U  15.00
1007  P1001/SOUTH  U  16.00
```

The current state preserves only the latest after-image.

The change log preserves the sequence of relevant events.

---

### Event Model

Each source change is represented explicitly as an event.

The laboratory uses:

```text
I = INSERT
U = UPDATE
D = DELETE
```

Each event contains an ordered:

```text
EVENT_SEQ
```

together with the business key and event payload.

Conceptually:

```text
EVENT_SEQ
PRODUCT_ID
STORE_GROUP
OPERATION
PRICE
CURRENCY
EVENT_AT
```

Example:

```text
1001  P1010  SOUTH  I  100.00  EUR
1002  P1001  SOUTH  U   14.00  EUR
1003  P1011  SOUTH  I  110.00  EUR
1004  P1010  SOUTH  D
```

The sequence belongs to:

```text
change events
```

rather than:

```text
business rows
```

This is the critical difference from the earlier `CREATED_SEQ` experiment.

---

### Why EVENT_SEQ Solves the Update Problem

With `CREATED_SEQ`, an existing row may change without receiving a new sequence.

For example:

```text
P1001/SOUTH
CREATED_SEQ = 1001

PRICE 10.00 -> 12.00
CREATED_SEQ remains 1001
```

A numeric high-water-mark consumer cannot see that update.

With an event log, the same business key may produce multiple sequence values:

```text
1001  P1001/SOUTH  I  10.00
1005  P1001/SOUTH  U  12.00
1008  P1001/SOUTH  U  15.00
```

Each relevant change creates a new event.

Therefore the numeric delta field now represents:

```text
change order
```

rather than:

```text
row creation order
```

This makes numeric high-water-mark acquisition appropriate again.

---

### Consumer Rule

The change-log consumer stores:

```text
LAST_SEQ
```

for:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
```

The extraction rule is:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

For example:

```text
LAST_SEQ = 1004
```

and the log contains:

```text
1005
1006
1007
```

The consumer selects all three events.

After successful persistence:

```text
LAST_SEQ = 1007
```

The pointer therefore means:

```text
highest event sequence
successfully persisted by this consumer
```

---

### EVENT_SEQ Is Not a Timestamp

The event sequence is intentionally independent of:

```text
EVENT_AT
```

`EVENT_AT` may still be useful for diagnostics or business analysis.

However, it is not the delta criterion.

The consumer does not evaluate:

```text
EVENT_AT > LAST_EVENT_AT
```

It evaluates:

```text
EVENT_SEQ > LAST_SEQ
```

This avoids the timestamp-specific problem in which:

```text
change time
```

and:

```text
visibility time
```

may diverge.

However, sequence-based correctness introduces its own ordering requirement.

---

### The Producer Must Create the Event Transactionally

The business change and corresponding log event must belong to the same database LUW.

For an update, the required logical unit is:

```text
update business state
+
write U event
+
COMMIT
```

For an insert:

```text
insert business state
+
write I event
+
COMMIT
```

For a delete:

```text
delete business state
+
write D event
+
COMMIT
```

The event must not be written independently from the business change.

Otherwise the source could reach inconsistent states.

---

### Dangerous Partial States

If the business change commits but the log event does not:

```text
ZDB_SRC_PRICE changed
ZDB_CHANGE_LOG unchanged
```

then the change-log consumer never learns about the business change.

If the log event commits but the business change rolls back:

```text
ZDB_CHANGE_LOG contains event
ZDB_SRC_PRICE did not change
```

then the event stream reports a business operation that never actually became part of the committed source state.

Both situations violate the source contract.

---

### Producer Transaction

The laboratory therefore performs:

```text
allocate next EVENT_SEQ
        |
        v
update producer counter
        |
        v
apply business change
        |
        v
insert change-log event
        |
        v
COMMIT
```

as one logical transaction.

If any database operation fails before `COMMIT`:

```text
ROLLBACK
```

must restore the entire producer-side state.

This rule is tested explicitly later in the producer rollback experiment.

---

### Producer Counter

The next event sequence is maintained in:

```text
ZDB_EVENT_COUNT
```

using:

```text
LAST_EVENT_SEQ
```

For:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
```

the producer may start from a laboratory baseline such as:

```text
LAST_EVENT_SEQ = 1000
```

The next producer transaction allocates:

```text
1001
```

then:

```text
1002
```

and so on.

This state belongs to the producer.

It must not be confused with the consumer pointer.

---

### Producer State and Consumer State

The project intentionally separates:

```text
ZDB_EVENT_COUNT-LAST_EVENT_SEQ
```

from:

```text
ZDB_DELTA_STATE-LAST_SEQ
```

The first means:

```text
highest event sequence
committed by the producer
```

The second means:

```text
highest event sequence
successfully acquired by the consumer
```

For example:

```text
Producer LAST_EVENT_SEQ = 1007
Consumer LAST_SEQ       = 1004
```

This is a valid state.

It means:

```text
1005
1006
1007
```

are committed source events waiting to be consumed.

The difference represents the acquisition backlog.

---

### Physical DELETE Becomes Explicit

The change-log architecture also solves the physical-delete problem.

Suppose the producer physically removes:

```text
P1010/SOUTH
```

from:

```text
ZDB_SRC_PRICE
```

The same transaction writes:

```text
EVENT_SEQ  = 1004
PRODUCT_ID = P1010
STORE_GROUP = SOUTH
OPERATION  = D
```

to:

```text
ZDB_CHANGE_LOG
```

After commit:

```text
current-state row
-> gone
```

but:

```text
delete event
-> remains durable
```

The consumer can therefore acquire the deletion even though the business row no longer exists.

A tombstone in the current-state table is no longer required.

---

### INSERT and UPDATE as After-Images

For `I` and `U`, the laboratory stores the business after-image in the event.

For example:

```text
1002
P1001/SOUTH
OPERATION = U
PRICE     = 14.00
CURRENCY  = EUR
```

The event therefore carries the new state produced by that business operation.

This allows the acquisition consumer to persist the event without rereading the current-state table.

That distinction is important.

If the consumer reread the current-state table later, it might see a newer value and lose the exact after-image associated with event `1002`.

---

### Event Stream vs Current-State Re-Read

Consider:

```text
1002  P1001/SOUTH  U  14.00
1005  P1001/SOUTH  U  15.00
1007  P1001/SOUTH  U  16.00
```

If the consumer processes event `1002` but reads the current-state table at that moment, the current row may already contain:

```text
16.00
```

The original `14.00` after-image would be lost.

Therefore a change log that is intended to preserve event semantics must contain enough event payload to reconstruct the required event itself.

The laboratory follows this principle for `I` and `U`.

---

### Operation History

Unlike the current-state timestamp architecture, the event log can preserve multiple changes to the same business key.

Current state:

```text
P1001/SOUTH
PRICE = 16.00
```

may correspond to event history:

```text
1002  U  14.00
1005  U  15.00
1007  U  16.00
```

This allows the consumer to observe:

```text
14.00
then 15.00
then 16.00
```

rather than only:

```text
current value = 16.00
```

This is a stronger information model.

---

### Numeric Delta Becomes Valid Again

The consumer now uses a simple numeric criterion:

```text
EVENT_SEQ > LAST_SEQ
```

but unlike `CREATED_SEQ`, this numeric field represents every relevant source event.

The important lesson is therefore not:

```text
numeric delta failed earlier
but works now
```

The deeper lesson is:

```text
the correctness of numeric delta
depends on what the number represents
```

`CREATED_SEQ` represented row creation.

`EVENT_SEQ` represents change-event position.

Only the second matches the requirements of a mutable event stream.

---

### Ordering Requirement

A monotonically increasing `EVENT_SEQ` is still not sufficient by itself.

The sequence must also be compatible with:

```text
commit order
```

and:

```text
visibility order
```

Suppose:

```text
Transaction A allocates 1002
but remains uncommitted
```

while:

```text
Transaction B allocates 1003
and commits immediately
```

The consumer could then see:

```text
1003
```

while:

```text
1002
```

is still invisible.

If it advances:

```text
LAST_SEQ = 1003
```

then event `1002` may be skipped after it commits.

This is the sequence-based equivalent of the timestamp visibility-gap problem.

---

### Required Ordering Property

For the event sequence to be a safe high-water mark, the source must guarantee:

```text
If EVENT_SEQ A < EVENT_SEQ B,
then B must not become committed and visible
while A is still an earlier uncommitted event
that the consumer is expected to receive.
```

A simpler operational form is:

```text
allocation order
=
commit order
=
visibility order
```

for the serialized event stream.

The laboratory enforces this with producer locking.

That mechanism is examined in the next section on producer concurrency.

---

### Different Correctness Contract

Timestamp delta depends on a temporal contract:

```text
CHANGED_AT
+
bounded visibility lag
+
safety intervals
```

The transactional change log depends on a different contract:

```text
business change and log event
in one LUW
+
commit-consistent EVENT_SEQ ordering
+
durable log retention
```

The two architectures therefore solve reliability differently.

---

### No Upper Safety Interval Is Needed

If event sequencing is commit-consistent, the change-log consumer does not need to ask:

```text
Is EVENT_SEQ 1007 old enough
to be considered stable?
```

A committed visible event is already safe to consume because no lower event sequence can later appear behind the consumer pointer.

Therefore the consumer can read:

```text
EVENT_SEQ > LAST_SEQ
```

without an upper time delay.

This removes the timestamp-specific latency introduced by:

```text
UPPER_SAFETY_INTERVAL
```

---

### No Lower Overlap Is Required for Normal Operation

Likewise, a correctly ordered durable event stream does not normally need:

```text
LAST_SEQ - overlap
```

to recover boundary events.

The sequence boundary is exact.

If:

```text
LAST_SEQ = 1004
```

then the next request can begin with:

```text
EVENT_SEQ > 1004
```

and read:

```text
1005
1006
1007
```

without intentionally rereading:

```text
1001 .. 1004
```

Replay is still possible when required, but it is not needed as a normal boundary-protection mechanism.

---

### Long-Running Transactions

The transactional change-log model handles long-running producer transactions differently from timestamp delta.

Suppose Transaction A allocates the next sequence and then remains open for a long time.

If producer ordering is correctly serialized, later producers cannot publish higher sequences ahead of it.

Therefore the consumer does not move past the uncommitted event.

The duration of Transaction A may affect:

```text
producer throughput
```

and:

```text
latency
```

but not necessarily:

```text
delta correctness
```

This is a major architectural difference.

---

### Transaction Duration and Correctness

In timestamp delta:

```text
long transaction
-> may exceed safety window
-> may become visible behind pointer
-> possible data loss
```

In commit-consistent change-log delta:

```text
long transaction
-> event remains uncommitted
-> later event publication is blocked
-> consumer cannot skip it
```

Therefore the change-log architecture does not rely on estimating a maximum source transaction duration for delta correctness.

It relies instead on correct producer serialization and transaction coupling.

---

### Cost of the Stronger Contract

This stronger correctness model is not free.

The source must maintain:

```text
event counter
change-log table
operation semantics
event payload
transactional coupling
producer concurrency control
retention policy
```

The producer is therefore more complex than a source that simply updates:

```text
CHANGED_AT
```

The architecture also creates an ever-growing event history unless retention or archiving is implemented.

---

### Source-Side Responsibility

Every source writer that modifies the relevant business state must follow the change-log protocol.

If one writer performs:

```text
UPDATE ZDB_SRC_PRICE
```

without creating the corresponding event, the business change becomes invisible to the change-log consumer.

Therefore:

```text
all relevant producers
must participate in the same event-publication contract
```

This requirement is fundamental.

The consumer cannot detect missing events that were never created.

---

### Durable Replay Source

Because committed events remain in:

```text
ZDB_CHANGE_LOG
```

the log also acts as a replay source.

If the consumer fails after events are committed but before they are successfully persisted downstream, the events remain available.

The consumer pointer can stay unchanged and the same:

```text
EVENT_SEQ
```

values can be selected again.

This property is explored later in the consumer restart experiment.

---

### Change Log Is Not the Current State

It is important not to treat:

```text
ZDB_CHANGE_LOG
```

as another form of current-state table.

The log may contain many rows for the same business key.

For example:

```text
1001  P1001/SOUTH  I
1002  P1001/SOUTH  U
1005  P1001/SOUTH  U
1007  P1001/SOUTH  U
1010  P1001/SOUTH  D
```

Each row represents a distinct source event.

The business key alone is therefore not unique in the log.

The event identity is based on:

```text
SOURCE_NAME
+
EVENT_SEQ
```

---

### Current State and Event Stream Can Coexist

The two source models serve different purposes and can coexist naturally.

Current state:

```text
ZDB_SRC_PRICE
```

is efficient for questions such as:

```text
What is the current price now?
```

Change log:

```text
ZDB_CHANGE_LOG
```

is suitable for:

```text
What changed since EVENT_SEQ 1004?
```

The producer keeps them consistent transactionally.

This is a common architectural pattern:

```text
current-state representation
+
ordered durable change stream
```

---

### Resulting Consumer Model

The change-log consumer can be summarized as:

```text
read LAST_SEQ
        |
        v
SELECT events
WHERE EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
        |
        v
persist acquired events
        |
        v
advance LAST_SEQ
        |
        v
COMMIT
```

This consumer logic is simpler than the safe timestamp window:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

because source complexity has moved into the producer-side event contract.

---

### Architectural Trade-Off

The two approaches distribute complexity differently.

Timestamp architecture:

```text
simpler producer
more complex consumer boundary logic
timing dependency
possible overlap
soft-delete requirement
```

Transactional change log:

```text
more complex producer
simpler consumer boundary
explicit I / U / D
strict event ordering
durable replay
```

Neither architecture is universally superior.

The correct choice depends on the guarantees the source can provide and the information the consumer requires.

---

### Result of the Laboratory Experiment

The laboratory event stream contains ordered events such as:

```text
1001  P1010/SOUTH  I
1002  P1001/SOUTH  U
1003  P1011/SOUTH  I
1004  P1010/SOUTH  D
```

Starting from:

```text
LAST_SEQ = 1000
```

the consumer reads:

```text
1001
1002
1003
```

and advances:

```text
LAST_SEQ = 1003
```

After the physical delete produces:

```text
1004  P1010/SOUTH  D
```

the same consumer rule selects:

```text
EVENT_SEQ > 1003
```

and acquires the delete normally.

The experiment therefore demonstrates:

```text
INSERT
UPDATE
DELETE
```

through one ordered numeric delta stream.

The central conclusion is:

```text
Transactional change-log delta replaces
a timing-based correctness contract
with a transaction-and-ordering-based contract.
```

However, that contract is reliable only if:

```text
EVENT_SEQ allocation
```

and:

```text
transaction commit order
```

remain consistent.

The next section examines exactly that requirement:

```text
Producer Concurrency and Commit-Consistent Ordering
```

## Producer Concurrency and Commit-Consistent Ordering

A monotonically increasing `EVENT_SEQ` is not enough by itself to guarantee a correct change-log delta.

The sequence must also remain consistent with the order in which producer transactions become committed and visible.

Otherwise the consumer may observe a later sequence first, advance its pointer, and permanently skip an earlier event that commits afterwards.

---

### The Dangerous Scenario

Assume two producer sessions operate concurrently.

Session A allocates:

```text
EVENT_SEQ = 1002
```

but its transaction remains open.

Session B then allocates:

```text
EVENT_SEQ = 1003
```

and commits immediately.

The source can temporarily reach the state:

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

executes:

```text
EVENT_SEQ > 1001
ORDER BY EVENT_SEQ
```

At that moment, it can see:

```text
1003
```

but not:

```text
1002
```

If it advances:

```text
LAST_SEQ = 1003
```

and Session A later commits `1002`, then the next request uses:

```text
EVENT_SEQ > 1003
```

Event `1002` is now permanently behind the consumer pointer.

---

### Sequence Order Alone Is Not Sufficient

The event numbers may still be perfectly monotonic:

```text
1001
1002
1003
```

The problem is not the numeric ordering itself.

The problem is that:

```text
allocation order
```

and:

```text
commit / visibility order
```

have diverged.

The consumer uses `EVENT_SEQ` as a high-water mark.

That is safe only if lower sequence numbers cannot become visible after higher sequence numbers have already been consumed.

---

### Required Ordering Property

For a sequence-based high-water mark to be reliable, the producer side must guarantee:

```text
If EVENT_SEQ A < EVENT_SEQ B,
then B must not become committed and visible
before A is resolved.
```

For the serialized laboratory stream, the intended invariant is:

```text
allocation order
=
commit order
=
visibility order
```

This is stronger than simple monotonic numbering.

---

### Producer Serialization

The laboratory protects the event counter with:

```text
EZDBEVCOUNT
```

The lock is acquired before reading and advancing:

```text
ZDB_EVENT_COUNT-LAST_EVENT_SEQ
```

and is held until the producer transaction has completed.

Conceptually:

```text
acquire counter lock
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
insert change-log event
        |
        v
COMMIT
        |
        v
release counter lock
```

While one producer owns the lock, another producer for the same logical source cannot allocate a later sequence.

---

### Why the Lock Is Held Until COMMIT

It would not be sufficient to lock only the counter update.

For example:

```text
lock
allocate 1002
update counter
unlock
```

followed later by:

```text
business update
log insert
COMMIT
```

would allow a second producer to allocate and commit `1003` while the `1002` transaction is still open.

The dangerous visibility order would remain possible.

Therefore the lock must protect the complete interval from:

```text
sequence allocation
```

through:

```text
transaction completion
```

---

### Laboratory Lock Implementation

The project uses the ABAP Cloud released lock API:

```text
CL_ABAP_LOCK_OBJECT_FACTORY
```

with lock object:

```text
EZDBEVCOUNT
```

The protected key includes:

```text
CLIENT
SOURCE_NAME
```

For the laboratory change log:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
```

This means all producers for the same logical event stream are serialized through the same counter lock.

---

### Two-Session Experiment

The laboratory verifies the behavior with two independent ADT sessions.

Assume the producer counter is:

```text
LAST_EVENT_SEQ = 1001
```

Session A starts an update producer.

It:

```text
acquires EZDBEVCOUNT
allocates EVENT_SEQ = 1002
updates the counter in its transaction
applies the business change
inserts event 1002
```

and then pauses before:

```text
COMMIT
```

At this point:

```text
event 1002
-> uncommitted

business change
-> uncommitted

counter update
-> uncommitted

EZDBEVCOUNT
-> still held
```

---

### Concurrent Producer Attempt

While Session A is paused, Session B starts another producer.

Session B attempts to acquire:

```text
EZDBEVCOUNT
```

for the same:

```text
PRODUCT_PRICE_LOG
```

The attempt fails because Session A still owns the lock.

The second producer does not proceed to sequence allocation.

It therefore does not create:

```text
1003
```

while `1002` remains unresolved.

The laboratory reports the lock conflict and exits without changing source state.

---

### First Producer Commits

Session A is resumed.

It executes:

```text
COMMIT
```

The following become visible together:

```text
counter = 1002
business change
change-log event 1002
```

The lock is then released.

Only now can another producer continue.

---

### Second Producer Retries

Session B is started again.

This time it acquires the lock successfully.

It reads:

```text
LAST_EVENT_SEQ = 1002
```

and allocates:

```text
EVENT_SEQ = 1003
```

It then performs its business change and log insert and commits.

The observed ordering becomes:

```text
allocation:
1002 -> 1003

commit:
1002 -> 1003

visibility:
1002 -> 1003
```

This is the required property.

---

### Why Blocking Is Better Than Out-of-Order Publication

The lock introduces waiting or temporary producer failure under contention.

That cost is deliberate.

The alternative would be to allow:

```text
1003
```

to become visible while:

```text
1002
```

is still unresolved.

For a consumer using:

```text
EVENT_SEQ > LAST_SEQ
```

that would make the high-water mark unsafe.

The design therefore prefers:

```text
producer serialization
```

over:

```text
out-of-order event visibility
```

---

### Long-Running Producer Transaction

Suppose Session A remains open for a long time after allocating:

```text
1002
```

Later producers remain unable to allocate:

```text
1003
```

until Session A either:

```text
COMMITs
```

or:

```text
ROLLBACKs
```

This can increase producer latency.

However, it preserves delta correctness.

The consumer cannot move beyond the unresolved event because no later sequence can become visible first.

---

### Difference from Timestamp Safety

The timestamp architecture handles delayed transactions by delaying the consumer:

```text
UPPER_SAFETY_INTERVAL
```

The change-log architecture handles them by controlling the producer:

```text
serialize event publication
```

The two approaches therefore place the protection at different points.

Timestamp model:

```text
producer may commit in arbitrary timing order
consumer waits before trusting recent timestamps
```

Change-log model:

```text
producer publication order is constrained
consumer can trust committed sequence order
```

---

### Locking and Transaction Atomicity Are Different Guarantees

The producer lock guarantees:

```text
ordering between concurrent producers
```

The database transaction guarantees:

```text
atomic consistency of
counter
business change
change-log event
```

These are separate concerns.

The lock alone cannot prevent a partial producer commit.

The transaction alone does not necessarily prevent two concurrent producers from publishing sequence numbers out of order.

The change-log architecture requires both.

---

### What Happens on Rollback

If Session A allocates:

```text
1002
```

but later rolls back, its counter update is rolled back as well.

The committed producer state remains:

```text
LAST_EVENT_SEQ = 1001
```

After the lock is released, the next producer can reuse:

```text
1002
```

This is safe because the failed `1002` transaction never became part of the committed event stream.

The rollback behavior is tested separately in a later experiment.

---

### No Sequence Gap Is Required

The laboratory design therefore does not require preserving unused numbers from failed transactions.

If an event allocation rolls back before commit:

```text
1002
```

can be allocated again.

What matters is not:

```text
every attempted sequence value is unique forever
```

but:

```text
every committed event has a unique ordered sequence
```

and:

```text
committed sequence order is safe for high-water-mark consumption
```

---

### All Producers Must Follow the Same Protocol

The ordering guarantee exists only if every producer for:

```text
PRODUCT_PRICE_LOG
```

uses the same synchronization mechanism.

If another writer bypasses:

```text
EZDBEVCOUNT
```

and directly updates:

```text
ZDB_EVENT_COUNT
```

or writes:

```text
ZDB_CHANGE_LOG
```

independently, the guarantee can be broken.

The source contract therefore includes:

```text
All producers of the logical event stream
must use the same sequence-allocation
and commit-order protocol.
```

This is not optional.

---

### Serialization Scope

The laboratory uses one counter for one logical source:

```text
PRODUCT_PRICE_LOG
```

This provides a total event order.

The benefit is simplicity:

```text
one stream
one counter
one consumer high-water mark
```

The cost is serialization.

At higher event volumes, the counter lock can become a bottleneck.

---

### Scalability Trade-Off

The laboratory intentionally favors correctness visibility over throughput.

A production system may use different mechanisms such as:

```text
database log sequence numbers
partitioned event streams
transactional outbox
database-native CDC
redo-log based CDC
message broker offsets
```

Some of these systems can provide scalable ordered publication without a single application-level counter lock.

The laboratory does not attempt to reproduce those mechanisms.

Its purpose is to make the ordering requirement explicit.

---

### Total Order vs Partitioned Order

The current implementation provides:

```text
one total order
```

for all events in:

```text
PRODUCT_PRICE_LOG
```

A more scalable architecture might provide several independent partitions.

For example:

```text
partition A
sequence 1, 2, 3

partition B
sequence 1, 2, 3
```

Such a design would require multiple consumer pointers rather than one global:

```text
LAST_SEQ
```

That complexity is outside the scope of this laboratory.

---

### Consumer Assumption

Because producer ordering is serialized, the consumer can safely assume:

```text
if event N is committed and visible,
then every required event with sequence < N
has already been resolved
```

Therefore:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

is a safe extraction rule.

This is the guarantee that makes the numeric high-water mark reliable.

---

### Result of the Experiment

The concurrency experiment produces the sequence:

```text
Initial producer counter:
1001
```

Session A:

```text
allocates 1002
pauses before COMMIT
holds EZDBEVCOUNT
```

Session B:

```text
attempts producer run
cannot acquire lock
does not allocate 1003
```

Session A:

```text
commits 1002
releases lock
```

Session B retry:

```text
allocates 1003
commits 1003
```

The final committed stream is:

```text
1002
1003
```

in the same order in which the events became visible.

The experiment therefore proves:

```text
Monotonic EVENT_SEQ alone is insufficient.
```

The stronger requirement is:

```text
monotonic sequence
+
producer serialization
+
transactional commit
=
safe high-water-mark ordering
```

The next question moves from producer correctness to consumer recovery:

```text
What happens if the consumer fails
after reading events but before advancing LAST_SEQ?
```

That is examined in:

```text
Consumer Restart and Replay
```

## Consumer Restart and Replay

A reliable change-log architecture must remain correct not only while the consumer is running normally, but also when the consumer stops unexpectedly.

The critical question is:

```text
What happens if the consumer has already read
and persisted some events,
but fails before advancing LAST_SEQ?
```

The system must be able to restart without losing committed source events.

This requires the consumer to treat:

```text
acquisition persistence
```

and:

```text
delta-pointer advancement
```

as one atomic database transaction.

---

### Consumer State Before the Experiment

Assume the change-log consumer currently stores:

```text
LAST_SEQ = 1004
```

The producer has already committed additional events:

```text
1005  P1001/SOUTH  U  14.00
1006  P1001/SOUTH  U  15.00
```

These events exist durably in:

```text
ZDB_CHANGE_LOG
```

but have not yet been successfully acquired.

The source-side state is therefore:

```text
Producer LAST_EVENT_SEQ = 1006
Consumer LAST_SEQ       = 1004
```

The difference:

```text
1005
1006
```

represents the current acquisition backlog.

---

### Normal Consumer Flow

The consumer reads:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

With:

```text
LAST_SEQ = 1004
```

the result is:

```text
1005
1006
```

The intended processing sequence is:

```text
read events
        |
        v
persist acquired events
        |
        v
advance LAST_SEQ
        |
        v
COMMIT
```

The acquisition rows and the new pointer belong to the same LUW.

---

### Why the Order Matters

A dangerous implementation would do:

```text
advance LAST_SEQ
        |
        v
COMMIT
        |
        v
persist acquired events
```

Suppose the consumer advances:

```text
LAST_SEQ
1004 -> 1006
```

and commits that state.

If the process then fails before persisting events `1005` and `1006`, the next request starts with:

```text
EVENT_SEQ > 1006
```

The source events still exist, but they are now behind the consumer pointer.

They will not be selected again.

This would create permanent data loss.

---

### Safe Processing Order

The laboratory therefore uses the opposite order:

```text
persist events
        |
        v
advance LAST_SEQ
        |
        v
COMMIT both together
```

The key property is:

```text
no committed pointer advancement
without committed acquisition persistence
```

If the LUW fails before `COMMIT`, neither change becomes durable.

---

### Restart Experiment

The experiment intentionally interrupts the consumer after:

```text
INSERT acquisition rows
```

but before:

```text
UPDATE LAST_SEQ
```

and before:

```text
COMMIT
```

At that point, inside the consumer session:

```text
ZDB_ACQ_PRICE
contains uncommitted rows for 1005 and 1006
```

while:

```text
ZDB_DELTA_STATE-LAST_SEQ
still represents 1004
```

The consumer session is then terminated.

Because no commit occurred, the database rolls back the incomplete LUW.

---

### State After Interruption

After the failed consumer run:

```text
ZDB_CHANGE_LOG
```

still contains:

```text
1005
1006
```

because these events were committed independently by the producer before the consumer started.

The acquisition table does not contain committed copies of the interrupted rows:

```text
ZDB_ACQ_PRICE
-> no committed 1005
-> no committed 1006
```

The consumer pointer remains:

```text
LAST_SEQ = 1004
```

The resulting state is therefore:

```text
source events durable
consumer persistence rolled back
consumer pointer unchanged
```

This is exactly the state required for safe restart.

---

### Replay After Restart

The consumer is started again.

It again evaluates:

```text
EVENT_SEQ > 1004
```

and therefore selects:

```text
1005
1006
```

The same source events are replayed.

This time the consumer completes successfully:

```text
persist 1005
persist 1006
update LAST_SEQ = 1006
COMMIT
```

The final state becomes:

```text
ZDB_ACQ_PRICE
-> 1005 persisted
-> 1006 persisted

ZDB_DELTA_STATE
-> LAST_SEQ = 1006
```

The source events have now been successfully acknowledged by the consumer.

---

### Replay Is Expected Behavior

The second selection of:

```text
1005
1006
```

is not an error.

It is the intended recovery mechanism.

Before the consumer transaction commits, the system must behave as if the request has not been completed.

Therefore:

```text
before COMMIT
-> events remain replayable

after COMMIT
-> pointer moves beyond them
```

This creates a clear acknowledgement boundary.

---

### Commit as the Consumer Acknowledgement

For the consumer, the effective acknowledgement of an event is not:

```text
event selected
```

and not:

```text
event inserted into an uncommitted table buffer
```

It is:

```text
event persistence
+
pointer advancement
+
COMMIT
```

Only after that point may the consumer safely exclude the event from future requests.

---

### Durable Source Log Enables Replay

Replay is possible because:

```text
ZDB_CHANGE_LOG
```

is a durable source-side event store.

The consumer does not remove events when it reads them.

Therefore a failed consumer does not destroy the source evidence needed for recovery.

The consumer pointer simply determines which committed events are still considered unprocessed.

This is a major advantage of separating:

```text
source event durability
```

from:

```text
consumer progress
```

---

### Producer and Consumer Transactions Are Independent

The producer commits its event first:

```text
producer transaction
        |
        v
ZDB_CHANGE_LOG durable
```

Later, the consumer performs its own transaction:

```text
consumer transaction
        |
        v
ZDB_ACQ_PRICE
+
ZDB_DELTA_STATE
```

The producer does not wait for the consumer.

Likewise, a consumer rollback does not affect already committed source events.

This separation allows:

```text
producer progress
```

and:

```text
consumer recovery
```

to evolve independently.

---

### Pointer as an Acknowledgement Boundary

For the change-log consumer:

```text
LAST_SEQ
```

can be interpreted as:

```text
all events up to this sequence
have been successfully committed
to the acquisition layer
```

If:

```text
LAST_SEQ = 1004
```

then:

```text
1005+
```

remain unacknowledged.

If the consumer successfully commits:

```text
1005
1006
```

then:

```text
LAST_SEQ = 1006
```

becomes the new acknowledgement boundary.

---

### Why Selecting Events Is Not Enough

A consumer may successfully execute:

```text
SELECT EVENT_SEQ > LAST_SEQ
```

and still fail later.

Possible failures include:

```text
persistence error
database exception
session termination
application error
manual debug termination
pointer-update failure
```

Therefore the extraction query itself cannot define completion.

Completion must be tied to durable persistence.

---

### Why Persisting Events Alone Is Not Enough

The opposite partial state is also undesirable.

Suppose the consumer commits acquired rows but fails to advance:

```text
LAST_SEQ
```

Then the next request selects the same events again.

This may create duplicates in the acquisition layer.

Depending on downstream semantics, such duplication may be recoverable, but it is unnecessary.

The stronger design is:

```text
acquisition rows
+
consumer pointer
```

in the same LUW.

This ensures that they move together.

---

### Atomicity Invariant

The consumer should preserve the invariant:

```text
For every committed LAST_SEQ = N,
all events <= N required by this consumer
have already been successfully persisted.
```

The reverse also holds for the laboratory flow:

```text
If persistence of events up to N is rolled back,
LAST_SEQ must remain below N.
```

This makes the pointer trustworthy.

---

### Failure Before Persistence

If the consumer fails before writing any acquisition rows:

```text
no acquisition data committed
LAST_SEQ unchanged
```

The next run simply selects the same events again.

This is straightforward replay.

---

### Failure After Persistence but Before Pointer Update

This is the laboratory restart experiment.

Because both operations belong to one LUW:

```text
uncommitted acquisition rows
```

are rolled back.

The pointer remains unchanged.

The same events are replayed.

---

### Failure After Pointer Update but Before COMMIT

Even if the code has already executed:

```text
UPDATE ZDB_DELTA_STATE
```

inside the transaction, a failure before:

```text
COMMIT
```

still rolls back both:

```text
acquisition persistence
```

and:

```text
pointer update
```

The restart behavior remains safe.

The important boundary is the database commit, not the execution order of individual SQL statements inside the LUW.

---

### Failure After COMMIT

If the consumer fails after:

```text
COMMIT
```

then:

```text
acquisition rows
```

and:

```text
LAST_SEQ
```

are already durable.

The next consumer run begins after the committed pointer and does not replay those events.

This is also correct because the acquisition was successfully completed before the failure.

---

### At-Least-Once Selection, Atomic Completion

From the perspective of source selection, an event may be read more than once if the consumer repeatedly fails before commit.

For example:

```text
run 1:
select 1005
fail before COMMIT

run 2:
select 1005
fail before COMMIT

run 3:
select 1005
COMMIT
```

The event is selected multiple times but committed once to the acquisition state.

The architecture therefore tolerates repeated attempts while preserving a single committed progress boundary.

---

### Change-Log Retention Requirement

Replay works only while the required source events remain available.

If the producer deletes:

```text
1005
1006
```

from:

```text
ZDB_CHANGE_LOG
```

before the consumer has advanced beyond them, restart recovery becomes impossible.

Therefore event retention must respect consumer progress.

Conceptually:

```text
do not purge event N
while any required consumer may still need N
```

The laboratory does not implement retention management, but the architectural requirement remains.

---

### Multiple Consumers

A production event log may have several independent consumers:

```text
Consumer A LAST_SEQ = 1006
Consumer B LAST_SEQ = 1003
Consumer C LAST_SEQ = 1005
```

In that case, event retention must consider the slowest required consumer.

For example:

```text
event 1004
```

cannot be removed if Consumer B may still need it.

The laboratory uses only one logical consumer and therefore does not implement this consumer-group model.

---

### Consumer Concurrency

The laboratory also assumes:

```text
one active consumer
for PRODUCT_PRICE_LOG
```

If two consumers use the same:

```text
LAST_SEQ
```

concurrently, additional coordination would be required.

For example, both could read:

```text
LAST_SEQ = 1004
```

and process the same events simultaneously.

This does not necessarily cause source-event loss, but it can create duplicate acquisition and pointer races.

Consumer concurrency control is outside the current laboratory scope.

---

### Restart vs Reinitialization

Restart and reinitialization are different operations.

Restart means:

```text
continue from the last committed LAST_SEQ
```

For example:

```text
LAST_SEQ = 1004
-> replay 1005+
```

Reinitialization means deliberately resetting the consumer pointer:

```text
LAST_SEQ = 1000
```

and replaying the log from an earlier boundary.

The laboratory provides:

```text
ZCL_DB_LOG_DELTA_INIT
```

for explicit reinitialization.

It should not be confused with ordinary restart behavior.

---

### Replaying Previously Committed Events

If the consumer pointer is intentionally reset from:

```text
1006
```

to:

```text
1000
```

then:

```text
1001 .. 1006
```

become eligible again.

This is a deliberate replay.

It may be useful for:

```text
testing
reconstruction
recovery
rebuilding a downstream target
```

but it can also create duplicate downstream effects unless processing is designed accordingly.

The laboratory uses this capability only as an explicit test operation.

---

### Comparison with Timestamp Replay

Timestamp delta uses overlap such as:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

to create controlled rereading.

The change-log consumer does not need routine overlap for boundary correctness.

Replay occurs instead when:

```text
LAST_SEQ has not advanced
```

because the previous consumer LUW did not commit.

This is more precise.

The source event identity:

```text
EVENT_SEQ
```

remains stable across retries.

---

### Exact Event Identity

Because each log event has its own:

```text
EVENT_SEQ
```

the consumer can distinguish:

```text
replay of event 1005
```

from:

```text
a new business event 1006
```

This is different from a current-state timestamp reread, where the same business key may simply appear again as an after-image.

Explicit event identity makes recovery behavior easier to reason about.

---

### Result of the Experiment

The laboratory restart experiment starts with:

```text
Consumer LAST_SEQ = 1004
```

and committed source events:

```text
1005  P1001/SOUTH  U  14.00
1006  P1001/SOUTH  U  15.00
```

The consumer:

```text
selects 1005 and 1006
persists them inside its LUW
is interrupted before COMMIT
```

After termination:

```text
ZDB_CHANGE_LOG
-> 1005 and 1006 remain committed

ZDB_ACQ_PRICE
-> interrupted rows not committed

ZDB_DELTA_STATE
-> LAST_SEQ remains 1004
```

The consumer is restarted.

It again selects:

```text
1005
1006
```

and this time commits:

```text
acquisition rows
+
LAST_SEQ = 1006
```

The experiment therefore demonstrates:

```text
Consumer restart is safe when
acquisition persistence and pointer advancement
are committed atomically.
```

The key rule is:

```text
Never acknowledge an event in LAST_SEQ
before the corresponding acquired data
is durably committed.
```

The next reliability question is on the producer side:

```text
What happens if the business change succeeds,
but writing the corresponding change-log event fails?
```

That is examined in:

```text
Producer Rollback on Change-Log Failure
```
```
## Producer Rollback on Change-Log Failure

The transactional change-log architecture depends on a strong producer-side invariant:

```text
event-sequence advancement
+
business-state change
+
change-log event
```

must either all commit together or all roll back together.

It is not sufficient for the producer to create the correct event under normal conditions.

The architecture must also remain consistent when one of the database operations fails after earlier operations in the same producer transaction have already succeeded.

The laboratory reproduces this case by deliberately forcing the change-log insert to fail.

---

### Producer Transaction Boundary

A normal producer update performs:

```text
acquire counter lock
        |
        v
allocate next EVENT_SEQ
        |
        v
update ZDB_EVENT_COUNT
        |
        v
update ZDB_SRC_PRICE
        |
        v
insert ZDB_CHANGE_LOG event
        |
        v
COMMIT
        |
        v
release lock
```

The important point is that:

```text
counter update
business update
change-log insert
```

belong to the same database LUW.

Before `COMMIT`, none of them represents durable producer progress.

---

### Initial State

Before the failure experiment, assume:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1006
```

and the current business state is:

```text
P1001/SOUTH
PRICE = 15.00
```

The next legitimate producer event would therefore receive:

```text
EVENT_SEQ = 1007
```

---

### Preparing the Failure

The laboratory uses:

```text
ZCL_DB_LOG_FAIL_PREP
```

to create a deliberate conflict.

The preparation class determines the next expected sequence:

```text
LAST_EVENT_SEQ + 1
```

which in this example is:

```text
1007
```

It then inserts and commits an artificial change-log row:

```text
SOURCE_NAME = PRODUCT_PRICE_LOG
EVENT_SEQ   = 1007
PRODUCT_ID  = PFAIL
STORE_GROUP = TEST
OPERATION   = I
PRICE       = 999.00
```

The producer counter is not changed.

The resulting state is intentionally inconsistent from a business perspective:

```text
Producer counter:
1006

Change log:
contains artificial row 1007
```

This condition exists only to force a database error in the next producer transaction.

---

### Producer Starts Normally

The normal update producer is then executed.

It acquires:

```text
EZDBEVCOUNT
```

and reads:

```text
LAST_EVENT_SEQ = 1006
```

It therefore allocates:

```text
EVENT_SEQ = 1007
```

Inside the producer LUW it first updates the counter:

```text
1006 -> 1007
```

and then applies the business change:

```text
P1001/SOUTH
PRICE 15.00 -> 16.00
```

At this point, inside the still-uncommitted transaction:

```text
counter = 1007
business price = 16.00
```

The producer then attempts to insert the corresponding log event.

---

### Change-Log Insert Fails

The intended event is:

```text
EVENT_SEQ   = 1007
PRODUCT_ID  = P1001
STORE_GROUP = SOUTH
OPERATION   = U
PRICE       = 16.00
```

However, the artificial preparation row already occupies the primary-key position for:

```text
PRODUCT_PRICE_LOG
+
EVENT_SEQ 1007
```

The insert therefore fails with a duplicate-key conflict.

This reproduces an important failure point:

```text
some earlier producer SQL operations succeeded
but the event could not be persisted
```

---

### Why Partial Commit Would Be Dangerous

If the producer were to preserve the earlier changes despite the failed log insert, the source could become:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1007

ZDB_SRC_PRICE
P1001/SOUTH = 16.00

ZDB_CHANGE_LOG
no legitimate U event 1007
```

The business state would have changed without a corresponding event.

The change-log consumer would never learn about:

```text
15.00 -> 16.00
```

This would violate the fundamental producer contract.

---

### Rollback

The producer error path therefore executes:

```text
ROLLBACK
```

Because the counter update and business update belong to the same LUW as the failed log insert, they are reversed.

After rollback:

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

The legitimate event:

```text
1007  P1001/SOUTH  U  16.00
```

does not exist.

The producer transaction has therefore left no committed partial state.

---

### The Artificial Conflict Remains

The fake row:

```text
1007  PFAIL/TEST
```

does remain in:

```text
ZDB_CHANGE_LOG
```

This is expected.

It was committed by:

```text
ZCL_DB_LOG_FAIL_PREP
```

before the failing producer transaction began.

The producer rollback cannot undo an earlier independent committed transaction.

This distinction is important:

```text
ROLLBACK
```

affects only the current LUW.

---

### State After Producer Failure

Immediately after the failed producer attempt:

```text
Producer counter:
LAST_EVENT_SEQ = 1006

Business state:
P1001/SOUTH = 15.00

Legitimate event 1007:
not created

Artificial conflict:
1007 PFAIL/TEST still present
```

The key producer invariant has been preserved:

```text
No committed business change exists
without its corresponding committed log event.
```

---

### Cleanup

The laboratory then runs:

```text
ZCL_DB_LOG_FAIL_CLEANUP
```

The cleanup removes the artificial:

```text
PFAIL/TEST
```

record from the change log.

The cleanup intentionally identifies the artificial record by:

```text
PRODUCT_ID  = PFAIL
STORE_GROUP = TEST
```

rather than relying on a hard-coded event sequence.

This makes cleanup independent of the current producer counter.

---

### Retry

After the artificial conflict is removed, the normal producer is executed again.

The committed counter is still:

```text
LAST_EVENT_SEQ = 1006
```

because the previous attempt rolled back.

Therefore the retry allocates:

```text
EVENT_SEQ = 1007
```

again.

This reuse is correct.

The failed `1007` event never became part of the committed producer stream.

---

### Successful Retry

The producer now performs:

```text
counter:
1006 -> 1007
```

then:

```text
business state:

P1001/SOUTH
15.00 -> 16.00
```

and inserts:

```text
1007
P1001/SOUTH
U
16.00
```

into:

```text
ZDB_CHANGE_LOG
```

The complete producer transaction commits successfully.

The resulting state is:

```text
ZDB_EVENT_COUNT
LAST_EVENT_SEQ = 1007

ZDB_SRC_PRICE
P1001/SOUTH = 16.00

ZDB_CHANGE_LOG
1007  P1001/SOUTH  U  16.00
```

All three representations agree.

---

### Sequence Reuse After Rollback

The experiment demonstrates that a sequence number allocated inside an uncommitted transaction does not need to be permanently discarded.

The relevant distinction is:

```text
attempted EVENT_SEQ
```

versus:

```text
committed EVENT_SEQ
```

If:

```text
1007
```

was allocated but the entire producer LUW rolled back, then from the committed event stream's perspective:

```text
1007 was never published
```

It can therefore be reused safely.

---

### Gaps Are Not the Main Correctness Issue

A production sequencing mechanism might choose never to reuse sequence values and therefore leave gaps after failures.

For example:

```text
1006
1008
```

with no committed:

```text
1007
```

A gap by itself does not necessarily make an ordered event stream incorrect.

The critical property for high-water-mark consumption is:

```text
a lower event must not appear later
after the consumer has already advanced
past a higher committed event
```

The laboratory uses transactional counter rollback and therefore naturally reuses the failed sequence, but sequence continuity is not the fundamental guarantee.

Commit-consistent ordering is.

---

### Lock Behavior During Failure

The producer still holds:

```text
EZDBEVCOUNT
```

while the transaction is being resolved.

On failure, the producer:

```text
ROLLBACKs
```

and then releases the lock.

This prevents another producer from allocating a later event while the failed transaction is still unresolved.

The lock and rollback therefore cooperate:

```text
lock
-> prevents concurrent ordering violation

ROLLBACK
-> restores transactional consistency
```

Again, they solve different problems.

---

### Three-Way Atomicity

The experiment makes the source-side atomicity requirement explicit.

For a producer event `N`, these states must not be committed independently:

```text
1. producer counter = N

2. business state reflecting event N

3. change-log event N
```

The valid committed outcomes are:

```text
all three old
```

or:

```text
all three new
```

A state such as:

```text
counter new
business new
log old
```

is invalid.

So is:

```text
counter new
business old
log new
```

or:

```text
counter old
business new
log new
```

The database LUW prevents these partial outcomes.

---

### Transactional Outbox Principle

Although the laboratory uses its own change-log table, the underlying principle is closely related to a transactional outbox pattern:

```text
business state
+
event representation
```

are committed together.

The important architectural idea is not the specific table name.

It is:

```text
event publication must be transactionally coupled
to the business change it represents
```

Without this coupling, reliable downstream acquisition cannot be guaranteed.

---

### Why the Consumer Cannot Repair a Missing Event

Suppose the business change were allowed to commit without its log event.

The consumer only reads:

```text
ZDB_CHANGE_LOG
```

using:

```text
EVENT_SEQ > LAST_SEQ
```

It has no general way to discover:

```text
P1001 changed to 16.00
but no event was written
```

The current-state table may contain the new value, but the event consumer does not know that a change is missing.

Therefore:

```text
producer correctness
```

must be established before the event reaches the consumer boundary.

A consumer cannot reconstruct arbitrary events that were never published.

---

### Why Retry Is Safe

After rollback:

```text
business state = old value
producer counter = old value
legitimate event absent
```

The retry therefore starts from a clean committed state.

It does not need to determine which of the previous producer operations partially succeeded.

The database transaction has already resolved that ambiguity.

The retry can simply perform the complete producer operation again.

This greatly simplifies recovery logic.

---

### Consumer View After Retry

Assume the consumer pointer is:

```text
LAST_SEQ = 1006
```

After the successful retry, the log contains:

```text
1007  P1001/SOUTH  U  16.00
```

The normal consumer rule:

```text
EVENT_SEQ > 1006
```

selects the event.

No special recovery logic is needed on the consumer side.

From the consumer's perspective, event `1007` simply appeared as the next correctly ordered committed event.

---

### Producer Failure vs Consumer Failure

The project therefore has two complementary recovery patterns.

Consumer failure:

```text
source event already committed
consumer LUW fails
        |
        v
consumer pointer unchanged
        |
        v
event replayed
```

Producer failure:

```text
business change and event not yet committed
producer LUW fails
        |
        v
counter + business state + event rolled back
        |
        v
producer operation retried
```

The recovery boundaries are different because producer and consumer own different transactions.

---

### End-to-End Reliability Chain

The complete event path can now be expressed as:

```text
Producer:

lock
allocate EVENT_SEQ
change business state
write event
COMMIT
unlock

        |
        v

durable ordered ZDB_CHANGE_LOG

        |
        v

Consumer:

read EVENT_SEQ > LAST_SEQ
persist acquired events
advance LAST_SEQ
COMMIT
```

Correctness requires both sides to maintain their own atomicity guarantees.

---

### Result of the Experiment

The failure experiment starts with:

```text
Producer counter = 1006
P1001/SOUTH       = 15.00
```

A deliberate conflict is created at:

```text
EVENT_SEQ = 1007
```

The producer attempts:

```text
counter 1006 -> 1007
price   15.00 -> 16.00
insert legitimate event 1007
```

The log insert fails.

The producer executes:

```text
ROLLBACK
```

and the committed state returns to:

```text
counter = 1006
price   = 15.00
```

After cleanup, the producer retries and successfully commits:

```text
counter = 1007
price   = 16.00

1007  P1001/SOUTH  U  16.00
```

The experiment therefore proves:

```text
Reliable event publication requires
the producer counter,
business change,
and change-log event
to share one transactional commit boundary.
```

The broader principle is:

```text
No committed business change
without a committed event,
and no committed event
without its corresponding committed business change.
```

Together with commit-consistent producer ordering and atomic consumer pointer advancement, this completes the core reliability contract of the transactional change-log architecture.



## Timestamp Delta vs Transactional Change Log

The laboratory implements two fundamentally different delta architectures:

```text
Timestamp delta on a mutable current-state table
```

and:

```text
Transactional delta over an ordered change log
```

Both can provide reliable acquisition, but they rely on different correctness contracts.

The main difference is not:

```text
timestamp
vs
numeric sequence
```

The deeper difference is:

```text
time-based inference of changes
```

versus:

```text
explicit transactional publication of changes
```

---

### Two Different Source Models

Timestamp delta operates directly on:

```text
current business state
```

For each business key, the source contains one current row:

```text
P1001/SOUTH
PRICE      = 16.00
CHANGED_AT = T
```

The consumer infers that a change occurred because:

```text
CHANGED_AT
```

falls inside the extraction window.

The transactional change log instead stores explicit events:

```text
1002  P1001/SOUTH  U  14.00
1005  P1001/SOUTH  U  15.00
1007  P1001/SOUTH  U  16.00
```

The consumer does not infer changes from the current state.

It reads the events directly.

---

### Basis of Correctness

This is the most important distinction.

Timestamp delta relies on a temporal contract:

```text
Every relevant change updates CHANGED_AT

+

source visibility lag is bounded

+

safety intervals cover that lag

+

deletion remains represented in the source
```

Transactional change-log delta relies on a transactional and ordering contract:

```text
Every relevant business change creates an event

+

business change and event are committed in one LUW

+

EVENT_SEQ publication is commit-order-consistent

+

events remain durable until the consumer no longer needs them
```

The two approaches therefore achieve reliability by different mechanisms.

---

### Comparison

| Criterion | `CHANGED_AT + IS_DELETED` | Transactional Change Log |
|---|---|---|
| **Basis of correctness** | Temporal contract: timestamp maintenance and safety intervals must cover source visibility lag | Transactional and ordering contract: business change and event share one LUW, and events are published in commit-consistent order |
| **Source model** | Mutable current-state table | Current-state table plus durable event stream |
| **Delta criterion** | `CHANGED_AT` | `EVENT_SEQ` |
| **Consumer pointer** | `LAST_CHANGED_AT` | `LAST_SEQ` |
| **Meaning of pointer** | Latest source-time boundary considered safely scanned | Highest event sequence successfully persisted by the consumer |
| **INSERT** | Visible through new `CHANGED_AT` | Explicit `I` event |
| **UPDATE** | Visible if every relevant update changes `CHANGED_AT` | Explicit `U` event |
| **Physical DELETE** | Invisible after row removal | Explicit `D` event |
| **Delete strategy** | Requires soft delete / tombstone or another retained representation | Physical delete can be represented directly in the event stream |
| **Ordering** | Time-based; several rows may share one timestamp | Explicit event order through `EVENT_SEQ` |
| **Delayed COMMIT** | Requires safety interval protection | Safe if producer event publication is commit-order-consistent |
| **Dependency on transaction duration** | Yes | Not directly for delta correctness |
| **Upper safety interval** | Required when visibility can lag behind timestamp assignment | Not required for normal sequence-based consumption |
| **Lower overlap** | Useful for controlled rereading near the boundary | Not normally required |
| **Duplicate acquisition** | Expected with lower overlap | Normally caused only by retry/reinitialization rather than normal boundary handling |
| **Intermediate changes** | May disappear because only current state remains | Can be preserved as separate events |
| **Consumer restart** | Depends on atomic persistence and timestamp pointer update | Depends on atomic persistence and sequence pointer update |
| **Producer complexity** | Relatively low | Higher |
| **Consumer boundary logic** | More complex | Simpler |
| **Retention requirement** | Tombstones may require retention | Event log requires retention |
| **Scalability concern** | Mainly source query and timestamp-window behavior | Event sequencing and log growth may become bottlenecks |

---

### Timestamp Delta: Correctness Through Time

The timestamp architecture assumes that source time can be divided into safely processed and not-yet-safe regions.

The consumer calculates:

```text
LOWER_BOUND =
LAST_CHANGED_AT - LOWER_SAFETY_INTERVAL
```

and:

```text
UPPER_BOUND =
REQUEST_START - UPPER_SAFETY_INTERVAL
```

then reads:

```text
LOWER_BOUND < CHANGED_AT <= UPPER_BOUND
```

The upper boundary protects against recent changes whose transactions may not yet be visible.

The lower boundary intentionally rereads part of the previously scanned region.

The architecture therefore depends on:

```text
time
```

as its primary ordering model.

---

### Timestamp Delta Requires Bounded Visibility Lag

Let:

```text
D
```

be the maximum time between:

```text
assigning CHANGED_AT
```

and:

```text
the transaction becoming committed and visible
```

A finite upper safety interval can provide strict protection only if:

```text
D
```

is itself bounded.

Conceptually:

```text
UPPER_SAFETY_INTERVAL >= maximum visibility lag
```

If the source can occasionally keep transactions open much longer than the configured safety window, the consumer can still move its pointer past an invisible older change.

Therefore:

```text
finite safety interval
+
unbounded delayed COMMIT
=
no strict lossless guarantee
```

This is the fundamental limitation of the timestamp model explored by the laboratory.

---

### Change Log: Correctness Through Transaction Order

The change-log architecture replaces this temporal assumption with an ordered publication contract.

A producer performs:

```text
lock event counter
        |
        v
allocate EVENT_SEQ
        |
        v
update producer counter
        |
        v
apply business change
        |
        v
write change-log event
        |
        v
COMMIT
        |
        v
release lock
```

The consumer then reads:

```text
EVENT_SEQ > LAST_SEQ
ORDER BY EVENT_SEQ
```

The important guarantee is:

```text
a later committed sequence
cannot become visible
while an earlier required sequence
is still unresolved
```

Under this guarantee, the consumer can safely treat:

```text
EVENT_SEQ
```

as an exact high-water mark.

---

### Long-Running Transactions

The two architectures behave differently when a source transaction remains open for a long time.

Timestamp architecture:

```text
transaction gets CHANGED_AT = T1
        |
        | remains uncommitted
        |
        v
later timestamp T2 becomes visible
        |
        v
consumer may move beyond T1
```

Safety intervals reduce this risk only while the transaction delay remains inside the configured timing contract.

Change-log architecture:

```text
transaction allocates EVENT_SEQ = N
        |
        | remains uncommitted
        |
        v
producer ordering prevents N+1
from being published ahead of N
```

The long transaction may delay later producers, but it does not cause the consumer to skip event `N`.

Therefore:

```text
timestamp architecture
-> transaction duration affects correctness assumptions

change-log architecture
-> transaction duration primarily affects latency and throughput
```

---

### Where the Complexity Lives

Timestamp delta keeps the producer relatively simple.

The source only needs to maintain fields such as:

```text
CHANGED_AT
IS_DELETED
```

The complexity appears mainly in the consumer-side extraction contract:

```text
safety intervals
overlap
duplicate handling
visibility assumptions
tombstone retention
```

The change-log architecture moves more complexity to the producer:

```text
event creation
event sequencing
locking
transactional coupling
log persistence
log retention
```

The consumer then becomes simpler:

```text
EVENT_SEQ > LAST_SEQ
```

This is an architectural trade-off rather than a universally better or worse design.

---

### Current State vs Event History

Timestamp delta is naturally aligned with:

```text
current-state synchronization
```

The main question is:

```text
What should the target state be now?
```

Intermediate source changes may disappear before the consumer reads them.

For example:

```text
10.00
-> 12.00
-> 15.00
```

may result in the consumer receiving only:

```text
15.00
```

This can be completely correct for current-state replication.

The change log can preserve:

```text
10.00
-> 12.00
-> 15.00
```

as separate events.

It is therefore more appropriate when the consumer requires:

```text
operation history
strict change order
auditability
event-level processing
```

---

### Delete Semantics

Deletion highlights the difference between the models especially clearly.

Timestamp current-state source:

```text
physical DELETE
-> row disappears
-> no CHANGED_AT remains
-> delete invisible
```

Therefore the source must retain a tombstone:

```text
IS_DELETED = X
CHANGED_AT = new timestamp
```

The change-log architecture instead records:

```text
EVENT_SEQ = N
OPERATION = D
```

The current-state row can then be physically removed.

Delete information remains durable independently of the business row.

---

### Duplicate Delivery

Timestamp delta with lower overlap intentionally permits repeated after-images:

```text
Run A:
P1002/SOUTH = 23.00

Run B:
P1002/SOUTH = 23.00
```

This is compatible with overwrite-style or otherwise idempotent processing.

The change-log consumer does not need routine overlap.

If:

```text
LAST_SEQ = 1004
```

the next normal request begins exactly at:

```text
EVENT_SEQ > 1004
```

A source event can still be replayed after consumer failure if `LAST_SEQ` was not committed, but this is restart behavior rather than normal boundary overlap.

---

### Consumer Restart Is Similar in Both Models

Despite their different source semantics, both architectures follow the same fundamental consumer transaction rule:

```text
persist acquired data
        |
        v
advance delta pointer
        |
        v
COMMIT
```

The pointer must never be committed before the corresponding acquisition data.

For timestamp delta:

```text
pointer = LAST_CHANGED_AT
```

For change-log delta:

```text
pointer = LAST_SEQ
```

The pointer type differs, but the atomicity principle is the same.

---

### Producer Atomicity Is Unique to the Change Log

Timestamp delta usually relies on the source application updating:

```text
business state
+
CHANGED_AT
```

correctly.

The transactional event architecture has an additional explicit producer obligation:

```text
business state
+
event sequence
+
event record
```

must commit together.

This requirement is stronger but gives the consumer a durable event representation.

If event creation fails:

```text
business change must roll back
```

or the event stream no longer represents the committed business state reliably.

---

### Unbounded Transaction Duration

This is the strongest difference demonstrated by the laboratory.

Suppose source transaction duration cannot be reliably bounded.

Timestamp approach:

```text
No practical finite safety interval
can prove that every timestamp
behind the pointer is already visible.
```

Transactional change log:

```text
An unresolved earlier event prevents
later sequence publication,
so the consumer cannot advance past it.
```

This makes the change-log architecture stronger when strict lossless acquisition is required and source transaction duration is unpredictable.

The trade-off is producer serialization and greater infrastructure complexity.

---

### Change Log Is Not Automatically Better

The transactional change log should not be interpreted as the universally preferred design.

Timestamp delta can be simpler and entirely appropriate when:

```text
the source is naturally current-state oriented

CHANGED_AT is maintained reliably

source transaction duration is bounded

safety-window latency is acceptable

soft-delete semantics are available

duplicate after-images are acceptable
```

In such a system, introducing a full transactional event log may add unnecessary complexity.

---

### When Timestamp Delta Is a Good Fit

Timestamp delta is a strong candidate when:

```text
1. The consumer primarily needs current state.

2. Every relevant INSERT and UPDATE
   reliably updates CHANGED_AT.

3. Physical deletes can be represented
   through tombstones or another retained marker.

4. Maximum visibility lag is known and bounded.

5. Safety intervals can be configured
   without unacceptable latency.

6. Downstream processing tolerates
   repeated after-images caused by overlap.
```

Under these conditions, timestamp delta can provide a practical and relatively simple solution.

---

### When Transactional Change Log Is a Good Fit

A transactional change log becomes more attractive when:

```text
1. Every business operation must be preserved.

2. Physical deletes must be propagated explicitly.

3. Strict event ordering matters.

4. Source transaction duration may be unpredictable.

5. Consumers require durable replay.

6. The source can transactionally couple
   business changes with event creation.

7. The additional producer complexity
   and event-log storage are acceptable.
```

In this case, the explicit event stream provides stronger semantics.

---

### Different Meanings of "Delta"

The project therefore demonstrates that the word:

```text
delta
```

can describe very different things.

Creation-sequence delta asks:

```text
Which rows were created after the pointer?
```

Timestamp delta asks:

```text
Which current rows were marked as changed
inside this source-time window?
```

Transactional change-log delta asks:

```text
Which ordered business events occurred
after this event sequence?
```

These are not equivalent questions.

The correct acquisition design depends on which question the integration actually needs to answer.

---

### Pointer Meaning

The same distinction appears in the persistent pointers.

Numeric creation delta:

```text
LAST_SEQ
-> highest creation sequence processed
```

Timestamp delta:

```text
LAST_CHANGED_AT
-> latest source-time frontier considered safely scanned
```

Change-log delta:

```text
LAST_SEQ
-> highest event sequence durably acknowledged by the consumer
```

A pointer is therefore meaningful only together with the source semantics behind it.

---

### Core Correctness Question

Across both architectures, the central question remains:

```text
When is it safe to advance the consumer pointer?
```

For timestamp delta, the answer is:

```text
when the source-time region before the new boundary
is old enough that all relevant transactions
are guaranteed to be visible,
with configured overlap where required
```

For transactional change-log delta:

```text
when all events up to the new sequence
are already committed in safe publication order
and have been durably persisted by the consumer
```

---

### Reliability Contracts

The complete timestamp contract can be summarized as:

```text
Every relevant change updates CHANGED_AT

+

DELETE remains represented through a tombstone
or another extractable source record

+

visibility lag is bounded

+

UPPER_SAFETY_INTERVAL covers that lag

+

LOWER_SAFETY_INTERVAL provides controlled overlap

+

downstream processing tolerates repeated after-images

+

acquisition persistence and pointer advancement
are committed atomically
```

The complete transactional change-log contract is:

```text
Every relevant business change creates an event

+

business change, event counter,
and event record share one LUW

+

all producers follow the same sequencing protocol

+

EVENT_SEQ publication is commit-order-consistent

+

events remain durable until consumers no longer need them

+

acquisition persistence and consumer LAST_SEQ
are committed atomically
```

---

### Final Comparison

The timestamp architecture protects the consumer by saying:

```text
Do not trust source time too quickly.
```

The transactional change-log architecture protects the consumer by saying:

```text
Do not publish a later event
before an earlier event is transactionally resolved.
```

The first strategy manages uncertainty through:

```text
time delay
+
overlap
```

The second manages it through:

```text
transactional coupling
+
ordered publication
```

This is the central architectural distinction demonstrated by the laboratory.

---

### Final Principle

The experiments lead to one general rule:

```text
A delta pointer may advance only when
all relevant source changes before that boundary
are either:

1. already durably acquired,

or

2. guaranteed to remain recoverable
   by a future request.
```

Timestamp delta satisfies this rule through a bounded time-based safety contract.

Transactional change-log delta satisfies it through durable ordered events and transactional sequencing.

The choice between them should therefore be based not on the technical type of the delta field, but on the guarantees that the source system can actually provide.
