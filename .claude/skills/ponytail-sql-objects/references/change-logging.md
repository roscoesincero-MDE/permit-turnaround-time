# Database change logging

Every database in this project records its own DDL: who changed which object, the statement they ran, and the object's
definition as it stood immediately before the change, so a previous version can be recovered without a backup.

Two scripts, and they are meant to be run in this order:

| Script | Does |
|---|---|
| `scripts/checkDbChangeLogging.sql` | Read-only. Reports what is missing or out of date, and the fix for each. Changes nothing. |
| `scripts/logdBChanges.sql` | Applies all of it. Additive and re-runnable — nothing is dropped, no audit history is discarded, and a clean second run changes nothing. |

Then, from a monitoring job: `exec logs.uspDdlAuditVerify;` — that one checks whether the trail has been *tampered
with*, which is a different question from whether the machinery is installed.

## Deploying it into a database that does not have it

1. Run `checkDbChangeLogging.sql` and read the report. On a database with nothing installed every line says MISSING;
   that is the expected reading, not a problem.
2. Run `logdBChanges.sql`, naming the database twice:
   `sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i logdBChanges.sql`.
   `-I` is not optional — see `QUOTED_IDENTIFIER` in `SKILL.md` — and neither is `-v DbName`: the file carries no
   default for it, deliberately, so the run stops rather than guessing. Everything after section 2 is
   database-agnostic, which is why the same file serves every database.
3. Re-run `checkDbChangeLogging.sql`. Everything should read OK.
4. `exec logs.uspDdlAuditVerify;`

**The two names have to agree, and the script stops if they do not.** It asserts `DB_NAME()` against `$(DbName)`
before changing anything. The file used to hard-code `USE [<one fixed database>]`, so an operator who passed `-d` and forgot to
edit the file installed the whole subsystem into that database and then got a clean report — run, from inside
there, by the same script. A later draft replaced that with a `:setvar DbName` default, which was
worse rather than better: an in-file `:setvar` **overrides** `-v` on the command line instead of yielding to it, so every
documented invocation was silently targeting the hard-coded name again. There is now no in-file default at all. Do not add one
back. The file needs sqlcmd mode: sqlcmd itself, or SSMS with *Query > SQLCMD Mode* on.

**The DDL trigger is disabled while the script runs, not dropped**, and enabled again in section 15 — so the install
does not audit itself, and a run that fails part way through leaves a *disabled* trigger. Both
`checkDbChangeLogging.sql` and `logs.uspDdlAuditVerify` report that as a problem. A dropped one would have read
exactly like "never installed", which is what the previous version left behind on any failure between sections 3
and 13.

Section 1 needs `ALTER ANY LOGIN` in `master`; without it that one section reports and continues. Everything else needs
`db_owner` in the target database.

## Shape, and why it is three schemas

| Schema | Holds | Access |
|---|---|---|
| `logsData` | The base tables. System-versioned. | Nothing application-facing. `logsAuditReader` reads it. **Not** `readOnlyRole` — `scripts/permissions.sql` denies that role on every data schema. |
| `history` | The history tables. | Written only by the engine. |
| `logs` | The views the world reads and writes, their INSTEAD OF triggers, and the helper modules. | `applicationRole` has CRUD here and nowhere else. |

**A temporal table cannot carry an INSTEAD OF trigger.** That single fact drives the layout. Soft delete and
caller-overridable audit columns both need INSTEAD OF semantics, so the base table moves to `logsData` and a view in
`logs` takes the name the table used to have — existing consumers did not change a line.

All three schemas must share an owner (`dbo`). An unbroken ownership chain means a caller's permissions are checked on
the view only, which is what lets `applicationRole` write through the view while being denied the base table. Break the
ownership and every write through the view fails; `checkDbChangeLogging.sql` and `logs.uspDdlAuditVerify` both check it.

Two tables:

- `logsData.DdlChange` — **append-only** event log. One row per DDL event, with `PriorDefinition` and
  `NewDefinition`. Its history table should therefore be **empty**: a row in `history.DdlChange` means an event row
  was updated or deleted, and that row holds the version that was overwritten. This is the tamper evidence.
- `logsData.DdlObjectState` — current definition of each schema-scoped object, one row per object, source of the
  "before" image on the next event. Its history table holds every definition the object has ever had:
  `select Definition from logsData.DdlObjectState for system_time as of '2026-03-01' where ...`.

## The audit contract on the views

Stated here because it is a deliberate trade and not the obvious default.

**On INSERT**, `auditCreatedBy`, `auditCreatedDateUtc`, `auditModifiedBy`, `auditModifiedDateUtc`, `auditDeletedBy`,
`auditDeletedDateUtc` and `DbApplication` all accept an explicit value and default only when the caller passes NULL or
an empty string. That means the audit trail is **not tamper-proof against anyone holding INSERT on the view**, and it is
the right call anyway: a migration has to carry the original values across. Overwriting them strips the data of its
history, ruins reporting built on it, and in a regulated context is itself the violation.

**On UPDATE**, only `auditModifiedBy` is caller-overridable. `auditModifiedDateUtc`, `DbApplication`, `HostName`,
`AppSessionId` and `SqlSpid` are recomputed every time. `auditCreatedBy` and `auditCreatedDateUtc` are never rewritten.
The triggers use `UPDATE(auditModifiedBy)` to tell "the caller named this column" from "this is the existing value".

**`HostName` is never caller-overridable**, on INSERT or UPDATE. It is the one identity column a caller cannot supply.

**DELETE is a soft delete.** `IsDeleted = 1`, the `auditDeleted*` columns are stamped, and the row stays. On the event
log a soft-deleted row is a finding, not a normal state — `logs.uspDdlAuditVerify` reports it.

**An `UPDATE` that sets `IsDeleted = 1` stamps `auditDeleted*` too.** There are two routes to a soft delete — the
`DELETE` statement and an ORM writing the flag directly — and neither may leave the question of *who* unanswered. It
used to: only the `DELETE` trigger stamped those columns, so the row the verifier flags as a tamper indicator could
arrive with no record of who created it.

**The `*By` columns are `NVARCHAR (255)`, everywhere, and that is not negotiable downward.** The resolution order
below casts `SESSION_CONTEXT (N'AppUser')` to `NVARCHAR (255)`, which cannot be written into a 128-wide column at all.
`checkDbChangeLogging.sql` reports anything narrower as out of date.

Resolution order for a `*By` column, in all three triggers:

```sql
COALESCE (NULLIF (i.auditCreatedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
```

`ORIGINAL_LOGIN()` last and deliberately: it is unaffected by `EXECUTE AS`, so it names the actual person even under the
loginless `ddl_audit_user` the DDL trigger runs as.

## Things that will bite

- **`SCOPE_IDENTITY()` returns NULL to the caller** after an insert through an INSTEAD OF trigger, because the insert
  happened in the trigger's scope. Create `#ReturnedIdentity (InsertedId bigint)` before the insert and the trigger
  will `OUTPUT` the keys into it. This is also why `record_db_changes` writes the base tables directly instead of going
  through the views.
- **ORMs need to know the table has triggers.** Each trigger does `SET NOCOUNT ON`, returns early on an empty
  `inserted`/`deleted`, then `SET NOCOUNT OFF` before the primary DML, so the affected-row count EF Core reads to
  decide whether its write landed is the real one (otherwise: `DbUpdateConcurrencyException`).
- **The primary key is immutable through the view.** An `UPDATE` that changes `ChangeId`, or `SchemaName`/`ObjectName`
  on the state table, would silently do nothing — the trigger joins `deleted` to `inserted` on that key and matches
  nothing — so the triggers `THROW 50010` instead. A `THROW` rather than a `RAISERROR`, because `RAISERROR` followed by
  `RETURN` reports the rejection and then lets the caller's batch run on to the next statement, which is the same
  silence one statement later.
- **Do not `DENY ... ON SCHEMA::logsData TO public`.** Every user is a member of `public` and membership cannot be
  revoked, so that DENY reaches `ddl_audit_user` too; and because the DDL trigger fails closed, a permission
  guess that goes wrong stops every DDL statement in the database. `logdBChanges.sql` section 11 `REVOKE`s instead,
  which also clears the DENY on a database that already has it.
- **`sp_rename` is not tracked.** A renamed object leaves its state row under the old name and gets a fresh row under
  the new one, with no prior definition. Drop-and-create instead, or accept the gap.
- **An encrypted module has no captured definition.** `OBJECT_DEFINITION` returns NULL for `WITH ENCRYPTION`, so
  `CommandText` is all there is.
- **Retired, and still present on a migrated database:** the `PrevRowHash`/`RowHash` SHA-256 chain, `logs.z_ddl_row_hash`
  and `logs.z_ddl_change_verify`. System versioning replaced them, and the chain's cost was real — computing it held
  `UPDLOCK, HOLDLOCK` on the tail of the event log, which serialised every DDL statement in the database. The two
  columns are made NULLable and stop being written; they are not dropped, because nothing here drops a column. The views
  do not project them.

## What none of this can detect

Anyone with `sysadmin` or `db_owner` can switch versioning off, edit both tables, and switch it back on with
`DATA_CONSISTENCY_CHECK = OFF`; or restore an older backup. The only durable defence is a copy outside the instance,
held by someone other than the people being audited: read `logsData.DdlChange` from a job on another instance on a
`ChangeId` watermark and keep the highest `ChangeId` seen. `ChangeId` is an IDENTITY, so a gap on the next read is
evidence in itself. `logs.uspDdlAuditVerify` prints the watermark for exactly this.

## Adding another table to the pattern

`templates/table-temporal.sql` is the template; use it rather than adapting this list by hand. It is **opt-in** —
`RowHistory` in `SKILL.md` defaults to off, so a table gets this shape only when the request asks for it. Section 3 of
that template converts a table that already exists and already has rows, which is why off is a safe default.

What the template does, and what to check if you are reviewing one someone else wrote:

1. Base table in the `*Data` schema, with the full audit block, the session columns (`AppSessionId`, `SqlSpid`), the
   hidden `PERIOD FOR SYSTEM_TIME`, and `SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.<name>)`.
2. `DF_<schema>_<tableName>_<fieldName>` on every default. Default constraint names are unique per database, so they
   carry the real schema and table name and can never be copied from another table.
3. A view in the consumer-facing schema with the base table's public name, an explicit column list, and
   `WHERE IsDeleted = 0`. Do not project the period columns; `HIDDEN` already keeps them out of `SELECT *`.
4. `trg_ioi_ins_<name>`, `trg_iov_updt_<name>`, `trg_iod_del_<name>` on the view — copy the bodies from
   `logdBChanges.sql` sections 8 and 9 rather than paraphrasing them.
5. Ownership on all three schemas to `dbo`, grants on the view only.
6. `MS_Description` on the table, every column, the view **and each of the three triggers**, through
   `util.uspSetObjectDescription`. The helper resolves a `TRIGGER` against its parent and takes the parent's own type
   from `sys.objects`, so a trigger on a view is addressed correctly — pass the trigger's schema, which is the view's.

## Adding a column to one of the change-logging tables

The column list is written out in six places and nothing checks that they agree. A column added to
`logsData.DdlChange` and named in only five of them is silently dropped on the way through the view, which is a data
loss defect that no error reports. Work down the list:

1. The `ALTER TABLE ... ADD` block in `logdBChanges.sql` section 4 (or section 5 for `DdlObjectState`) — additive
   and separately guarded on `COL_LENGTH`, never an edit to the original `CREATE TABLE`.
2. The view's explicit `SELECT` list in section 8 (or 9).
3. The INSERT trigger. For `DdlChange` **there are two near-identical INSERT branches** — one with
   `OUTPUT ... INTO #ReturnedIdentity`, one without — and both need the column. They are duplicated because an `OUTPUT`
   clause cannot be made conditional inside one statement; keep them diffable so that a missed edit shows up as a diff.
4. The UPDATE trigger's `SET` list — unless the column is meant to be immutable, which is a decision to state in the
   trigger's header rather than leave implied by an omission.
5. `record_db_changes` in section 13, which writes the base table directly. A column the DDL trigger does not write is a
   column that is NULL on every real audit row.
6. Section 14's `@Descriptions` table. Rule 4 is "the table and every column", and a column added later is the one most
   likely to be missed; `templates/extended-properties.sql` ends with a report that finds them.

If the column has a legacy twin, write both from **one** hoisted value — see "the legacy twins" in section 8's headers.
Sections 4c and 5c back-fill on the twins being equal, so two separate `SYSUTCDATETIME ()` calls make the installer
re-update the same row on every run and push a spurious version into the history table each time.
