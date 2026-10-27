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


