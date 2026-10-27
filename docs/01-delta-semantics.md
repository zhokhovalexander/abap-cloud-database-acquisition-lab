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
