# Procedure instrumentation — the long form of rule 8

`SKILL.md` rule 8 states the rule in four lines and points here. This file holds the reasoning,
the shapes to copy, and the decisions behind them. Read it when you are writing or reviewing a
procedure; you do not need it to write a table or a view.

`SKILL.md` and this file are together the authority on the rule; there is nothing else to consult.
The objects the rule calls are installed by `scripts/logExecutionLogging.sql`, which also documents
each of them at the point of definition. **Run it against the database before deploying anything
instrumented** — until it has, both templates reference objects that do not exist, and the failure
arrives on the procedure's first call rather than at deploy time.

---

## Which procedures get what

| Kind of procedure | Instrumentation |
|---|---|
| Writes anything | **Full** — `TRY`/`CATCH`, a `logs.ExecutionLog` row opened before the transaction and closed after the commit, the row re-created in the `CATCH` if a rollback destroyed it, a bare `;THROW;` |
| Reads only | **Error-only** — header block, `SET NOCOUNT ON`, `SET XACT_ABORT ON`, `TRY`/`CATCH` whose `CATCH` records, bare `;THROW;`. No start row, no completion `UPDATE`, no resurrection block, no transaction |
| Reads *and* writes | It writes. Full. |
| `logs.uspStartExecutionLogging`, `logs.uspStartExecutionLoggingInsert`, `logs.uspRecordExecutionError`, `logs.uspRecordExecutionErrorUpdate`, `util.uspSetObjectDescription` | **Exempt**, and structurally so: the procedure that records a failure cannot open a row to record its own. Four rather than two because each half is a wrapper over an inner procedure — the seam that lets logging be redirected to a central database without editing a caller. Nothing else is exempt, whatever schema it is in. |

A read has its own file: copy `templates/procedure-readonly.sql`. Do not copy
`templates/procedure.sql` and delete the parts a read does not need — that is how a start block
ends up half present, and a start row with no completion makes every call read as a failure in the
monitoring grid.

For anything that writes, copy the block from `templates/procedure.sql` verbatim. Only the
parameter list, `@KeyParameters`, the work between the two `=====` banners, and `@Comments` change.

---

## Why reads are opt-in

Decided at the design review on 2026-09-05.

On a write, two extra round trips and one log row are nothing measured against the merge itself.
On a read they are not. A monitoring page that refreshes is the highest-frequency caller in the
system, and instrumenting every read turns `logs.ExecutionLog` into a record of people looking at
things — which is also how it fills up. A probe defect wrote about 70,000 rows in one
afternoon.

**`logs.uspGetExecutionLogPage` is the one instrumented read**, kept deliberately as the standing
witness that the rule 8 wrapping does not break a result set a client has to materialize. If that
ever stops being true, it is the procedure that will show it.

What an error-only read drops is the **successful path** only: the `uspStartExecutionLogging`
call, the completion `UPDATE`, and the resurrection block. Everything else — the header block,
`SET NOCOUNT ON`, `SET XACT_ABORT ON`, a whitelist-validated `@SortBy` — is unchanged.

---

## An error-only read still records, from the `CATCH`

A review finding worth stating in full. A procedure whose body was a
single `SELECT` called a scalar UDF inside that `SELECT`, the UDF errored, and **nothing was
recorded anywhere** — because "it only reads" had been read as "it cannot fail in a way worth
recording".

A read owns no `INSERT`, but everything it calls can fail: a UDF, a view over a view, a computed
column, a conversion, a deadlock, a permission it turns out not to hold.

```sql
BEGIN CATCH
    SELECT @ErrorNumber = ERROR_NUMBER (), ... ;      -- FIRST, always
    EXEC logs.uspRecordExecutionError
          @ProcedureName = @ProcName, @KeyParameters = @KeyParameters
        , @ExecutionLogId = NULL                      -- orphan branch, deliberately
        , @ErrorMessage = @ErrorMsg, ... , @ContextMessage = @ContextMessage;
    ;THROW;
END CATCH;
```

`@ExecutionLogId` is **always `NULL`** here, because no start row was opened. That sends
`logs.uspRecordExecutionErrorUpdate`'s `MERGE` down its `NOT MATCHED` branch, which inserts a row
and notes that execution logging never started for the call. For a fully instrumented procedure
that state means a start row was lost; **here it is correct** — so an error-only read passes a
`@ContextMessage` saying so, otherwise every read failure reads as a second defect in the logging
chain.

There is **no transaction**, because nothing writes. State that in the header alongside the reason
the start row is skipped.

Do not add half a start block. A start that is never completed makes every call read as a failure
in the monitoring grid.

A permission-posture check in the build asserts the same thing from the other side: a log row
appearing under an error-only procedure's name on a **successful** call fails the check.

Reference implementation: `512_config.uspGetLoadWatermark.sql`.

### The one limit, stated rather than glossed

If a **caller** has a transaction open and the error dooms it (`XACT_STATE () = -1`), the `INSERT`
cannot write and `uspRecordExecutionError` swallows that by design — the row is lost while the
error still reaches the caller. Rolling back the caller's transaction to make the write possible
would be worse: it is not this procedure's transaction to end. EF Core calls these reads without
an ambient transaction, so the common path records.

---

## The resurrection block leaves gaps in `ExecutionLogId`, permanently

A failure **inside a caller's open transaction** is the path the block exists for, and the one whose
evidence confuses people. `ROLLBACK TRANSACTION` in the `CATCH` unwinds the **outermost**
transaction, not the procedure's own — so it destroys the start row `uspStartExecutionLogging`
wrote. The block re-inserts it with the original `@StartDateUtc` and `@ReCreatedAfterRollback = 1`.

**IDENTITY allocation is not transactional.** The value the rolled-back insert consumed is not
returned, so the re-created row gets the *next* number and the destroyed one's number is gone for
good. Every execution that takes this path costs one value in the sequence:

```
ExecutionLogId   Successful   ReCreatedAfterRollback
           41            1                        0
           42            0                        0     -- flat failure: start row survived, MATCHED branch
          (43)                                          -- destroyed by the caller's ROLLBACK
           44            0                        1     -- the same execution, re-recorded
```

Three consequences, all of which someone eventually asks about:

- **A gap is not a lost execution.** The execution is recorded, under the next number, with
  `ReCreatedAfterRollback = 1`. The pair of adjacent rows is not two calls.
- **Nothing may treat `ExecutionLogId` as gapless.** Not a monitoring page inferring missing rows
  from arithmetic, not an export asserting `COUNT (*) = MAX (Id)`, not a retention job. Order and
  join on it; do not count with it.
- **`ReCreatedAfterRollback = 1` on a call with no ambient transaction is a defect**, and a
  different one: it means the start row went missing without an outer transaction to take it, so
  either the insert never committed or something deleted it. The flag is the discriminator between
  the expected gap and the unexpected one.

`IDENT_CURRENT` therefore runs ahead of `COUNT (*)` by exactly the number of executions that have
taken this path. A gap-free `logs.ExecutionLog` on a database that has had failures inside caller
transactions is the thing to be suspicious of: it means the re-creation is not happening and the
only executions never recorded are the failures.

`database/_tests/010_phase0_instrumentation.sql` in the authorization template exercises the path
deliberately and reports the arithmetic, which is the cheapest way to see this once rather than
discover it during an incident.

---

## Logging other than `logs.ExecutionLog` must be flushed from the `CATCH`

Settled at review; the worked shape is the four steps above.

`logs.ExecutionLog` is covered by the resurrection block. Any *other* logging the procedure does —
`logs.FacilityLoadStatus`, `logs.FacilityLoadAttempt`, `logs.DataQualityObservation` — is rolled
back with the data, and the batch that failed is the one whose detail matters most.

The pattern:

1. Accumulate in a **table variable**, which a rollback does not unwind.
2. Populate it **before `BEGIN TRANSACTION`**, so a validation failure is covered too.
3. Write the success rows **inside** the transaction.
4. Flush the failure rows in the `CATCH`, inside a nested swallowing `TRY`/`CATCH` so the flush
   cannot replace the error being reported.

Do **not** carry the intended outcome onto a failure row. The rollback means nothing was applied.

---

## The `@ProcName` fallback is this procedure's own name

Forget this and the procedure logs anonymously.

The `COALESCE` fallback on `@ProcName` must be **this** procedure's own name as a literal,
bracket-quoted to match `QUOTENAME` output — `N'[logs].[uspGetExecutionLogPage]'`. Never a placeholder,
and never the name copied from the template.

`OBJECT_NAME (@@PROCID)` returns `NULL` for a principal denied metadata visibility, which is what
the permission model denies to both application logins. **The fallback is therefore the branch every
application call takes**, not a guard for ad-hoc batches. `ProcedureName` is the column the
monitoring web app groups by.

Keep the literal in step with the `CREATE OR ALTER PROCEDURE` name. The dynamic half stays,
because it still resolves for the developer and it catches a rename.

---

## `THROW`, not `RAISERROR`

A bare `;THROW;` in a `CATCH` re-raises the original error with its **original number**, which is
what lets the .NET client branch on it: 1205 is a deadlock and the call should be retried, 2627
and 547 are constraint violations and it should not. `RAISERROR` replaces the number with 50000
and destroys that.

The leading semicolon is required: a bare `THROW` as the first statement after `BEGIN` is a syntax
error.

**Originating an error is the same rule seen from the other end.** Where a module raises an error
of its own rather than re-raising one — an immutable-key rejection in an `INSTEAD OF` trigger, an
argument check in a helper — use `THROW` with a number a caller can branch on, not
`RAISERROR (..., 16, 1)` followed by `RETURN`. `RETURN` ends the module and nothing else: the
statement is silently not applied and the caller's batch runs on to the next one believing it was.
`THROW` terminates the batch.

Numbers currently in use by this skill:

| Number | Meaning | Raised by |
|---|---|---|
| 50010 | Immutable key rejected through a view | the `INSTEAD OF UPDATE` triggers in `scripts/logdBChanges.sql` and `templates/table-temporal.sql` |
| 50000 | Argument validation in a helper | `util.uspSetObjectDescription` |

---

## `@KeyParameters` and friends carry identifiers and counts only

`@KeyParameters`, `@Comments`, `@ContextMessage` and `@DynamicSql`: identifiers and counts. Never
a credential, an API key or bearer token, a URL query string, a request header, or `@Payload`.

The monitoring web app reads `logs`. Anything written there is readable by whoever can open that
page.
