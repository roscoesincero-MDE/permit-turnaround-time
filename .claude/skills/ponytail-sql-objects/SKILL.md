---
name: ponytail-sql-objects
description: Create or modify SQL Server tables, views, stored procedures, functions and triggers to this project's mandatory conventions — schema placement, PascalCase with vw/usp/udf/tvf prefixes, the standard audit and soft-delete column block with DF_schema_table_field constraint names, MS_Description on every table and column, the standard object header block, and the SQL Server 2022 floor. Also installs and checks the per-database DDL change-logging subsystem. Use for any CREATE or ALTER of a database object, for DDL scripts, migrations and EF Core entity configurations, when setting up a new database, or when asked whether a database records its own schema changes.
---

# SQL Server object conventions — the project

Read the one file you need; do not read all of them.

| File | Use |
|---|---|
| `templates/table.sql` | New table (includes audit block + extended properties) — **the default** |
| `templates/table-temporal.sql` | New table **with row history**: system-versioned base table + view wrapper + INSTEAD OF triggers. Opt-in, see *Configuration* |
| `templates/object-header.sql` | Header block for views, procedures, functions, triggers |
| `templates/view.sql` | New view |
| `templates/procedure.sql` | New stored procedure **that writes** — full rule 8 instrumentation |
| `templates/procedure-readonly.sql` | New stored procedure **that only reads** — error-only instrumentation (rule 8) |
| `templates/extended-properties.sql` | Adding/updating `MS_Description`; also defines `util.uspSetObjectDescription` |
| `references/instrumentation.md` | The long form of rule 8 — read before writing a procedure |
| `references/change-logging.md` | How DDL change logging works, deploying it, and the audit contract on its views |
| `references/external-dependencies.md` | Objects these templates call that this skill does not create, and the project identifiers baked into it |
| `scripts/checkDbChangeLogging.sql` | Read-only report: does this database record its own DDL, and is that current |
| `scripts/logdBChanges.sql` | Installs or updates change logging. Additive, re-runnable, drops nothing |
| `scripts/logExecutionLogging.sql` | Installs `logs.ExecutionLog` and the four logging procedures rule 8 calls. **Run this before deploying any instrumented procedure** |
| `scripts/permissions.sql` | The schema-level role permissions, in one place. **Run it, or a plain table you deploy is readable by `db_owner` and nobody else** |

**Scope.** This file is the authority. Every rule below is stated here in full and holds on this
file's own account — there is no external requirements document to consult, and nothing here is a
summary of one. The SQL in `templates/` and `scripts/` is self-contained and runs against any SQL
Server 2022 database. What it does *not* create for you is inventoried in
`references/external-dependencies.md`: a handful of roles and one utility schema the templates
reference by name, and a short list of project-specific identifiers to rename when you take this
into a different estate.

## Configuration

| Switch | Default | Off means | On means |
|---|---|---|---|
| `RowHistory` | **off** | `templates/table.sql`. One table, 7 audit columns, current values only. Past values are gone once overwritten. | `templates/table-temporal.sql`. Base table in `<schema>Data`, system-versioned into `history`, extended audit block, and a view wrapper in the consumer schema carrying the table's name and three INSTEAD OF triggers. |

**To change the project default, edit the Default cell above.** That table is the only place the value is written down;
everything else in this file defers to it.

**To turn it on for one table without changing the default, say so in the request** — "`Permit` needs row history",
"make it temporal", "auditors will ask what changed and when". A table whose past values are *evidence* wants it on;
one where they are noise — a cache, a staging table, a nightly-reloaded queue — wants it off.

It is a low-stakes default, for two reasons. **Off is not a one-way door**: section 3 of
`templates/table-temporal.sql` converts a populated table additively, with the view taking the name the table had, so
no consumer query changes. And **the change-logging tables are on regardless** — `RowHistory` governs *your* tables;
rule 10 is not subject to this switch.

## Non-negotiables

All ten are requirements of this project, and a script that misses any of them is incomplete. They are not preferences
and not defaults to be weighed against convenience; where one of them is expensive, the rule says so and says why the
cost is accepted.

1. **Every table gets the full audit block** (7 columns) — see `templates/table.sql`. When `RowHistory` is on for the
   table it carries the extended block as well — `DbApplication`, `HostName`, `AppSessionId`, `SqlSpid`, and a hidden
   `PERIOD FOR SYSTEM_TIME` — plus a view wrapper, because a temporal table cannot carry an INSTEAD OF trigger. Use
   `templates/table-temporal.sql` and read `references/change-logging.md` first. `RowHistory` is **off by default**;
   never turn it on for a table on your own initiative, and never leave a table half-converted (a period without a
   view, or a view without all three triggers) — both shapes are complete or neither is applied.

   **Datetime columns are `DATETIME2 (3)`. Write the precision; never leave it bare.** Bare `DATETIME2` means
   `DATETIME2 (7)`, 8 bytes and 100-nanosecond resolution that nothing in this database uses or can rely on. Three is
   the project width: milliseconds, 7 bytes, and the resolution every timestamp here is actually compared at. It is
   also the width the period columns of a temporal table use, which is what makes this worth a rule rather than a
   preference — `RowHistory` is *not a one-way door*, so a table created today with bare `DATETIME2` audit columns and
   converted next quarter ends up with `datetime2(7)` audit columns beside `datetime2(3)` period columns, comparing
   unequal for sub-millisecond reasons in exactly the join that is supposed to line a row up with its own history. The
   `Src*` provenance columns mirroring an external system take 3 as well; that system's precision is its business, and
   the copy is ours. This applies to `datetime2` variables in triggers and procedures too, for the same reason.
2. **Constraint names are `DF_<schema>_<tableName>_<fieldName>`.** Interpolate the real schema
   and table name. Copying a constraint name from another table will fail at deploy: default
   constraint names must be unique per database.
3. **Soft delete only.** No `DELETE` statements, no `ON DELETE CASCADE`. `IsDeleted = 1` means
   deleted. Every read filters `IsDeleted = 0`.
4. **`MS_Description` on the table and on every column.** No exceptions. Set it through
   `util.uspSetObjectDescription`, never `sp_addextendedproperty` directly.
5. **Every view/procedure/function/trigger opens with the header block.**
6. **SQL Server 2022 is the floor and the ceiling, and this rule is the only place either is written down.** Every
   script and template defers to it; do not re-declare a different one in a file header, which is how the scripts came
   to advertise "2017 or later" while the procedure template used `LEAST ()` — a 2022 function. That is what makes the
   floor real rather than nominal: a procedure built to these conventions will not compile on 2017 or 2019.

   **The ceiling is the half that gets forgotten. Write nothing that needs SQL Server 2025.** A 2025-only construct
   deploys cleanly on the developer's newer instance and fails at `CREATE` time on every 2022 server in the estate, so
   the cost lands on whoever deploys rather than whoever wrote it. Specifically, and none of these are hypothetical
   temptations — each one is the obvious modern answer to something this project does:

   | Do not use | Use instead |
   |---|---|
   | the native `json` **type** | `NVARCHAR (MAX)` with `CHECK (<col> IS NULL OR ISJSON (<col>) = 1)` |
   | `JSON_ARRAYAGG`, `JSON_OBJECTAGG` | `STRING_AGG`, or `FOR JSON PATH` |
   | `REGEXP_LIKE`, `REGEXP_REPLACE`, `REGEXP_SUBSTR`, `REGEXP_INSTR`, `REGEXP_COUNT`, `REGEXP_MATCHES` | `LIKE` with `[]` classes, `PATINDEX`, `TRANSLATE`, `REPLACE` |
   | `vector` type, `VECTOR_DISTANCE`, `AI_GENERATE_EMBEDDINGS`, `CREATE EXTERNAL MODEL` | out of scope; raise it as a design question, do not smuggle it in as a column |
   | `BASE64_ENCODE`, `BASE64_DECODE` | `CONVERT` with style 1 via `xml`, or handle it in the application |
   | `PRODUCT ()` | `EXP (SUM (LOG (…)))`, with the zero and negative cases handled |
   | `UUID`/v7 identifier functions | `NEWSEQUENTIALID ()` in a default, or `BIGINT IDENTITY` |
   | optimized locking, and anything else set with `ALTER DATABASE SET` that 2022 does not recognise | leave it out; a database-level switch that silently no-ops is worse than one that errors |

   **2022's own additions are fair game and are used deliberately** — `LEAST` / `GREATEST` (the completion `UPDATE` in
   `templates/procedure.sql` depends on `LEAST`), `DATE_BUCKET`, `GENERATE_SERIES`, `STRING_SPLIT` with `enable_ordinal`,
   `TRIM` with `LEADING` / `TRAILING`, `IS [NOT] DISTINCT FROM`, the `WINDOW` clause, and `JSON_PATH_EXISTS`. Reaching
   for a pre-2022 workaround where one of those fits is the mirror-image mistake, and it is the reason the floor is
   stated as a floor rather than as "old enough to be safe".

   If you are unsure which side of the line a construct falls on, say so in the handoff rather than guessing. "This
   needs checking against 2022" costs a minute; a failed deployment does not.
7. **Every script is safe to run twice.** A developer runs them by hand. See *Re-runnable
   scripts* below.
8. **Every procedure that WRITES is fully instrumented; a procedure that only reads gets
   error-only instrumentation unless the plan names it.**

   *Full* is `TRY`/`CATCH`, a `logs.ExecutionLog` row opened before the transaction and closed
   after the commit, the row re-created in the `CATCH` if a rollback destroyed it, and a **bare
   `;THROW;`** so the caller receives the original error number rather than `50000`.
   *Error-only* keeps the header block, `SET NOCOUNT ON`, `SET XACT_ABORT ON` and a `CATCH` that
   records with `@ExecutionLogId = NULL`; it drops the **successful-path** round trip only. A
   procedure that both reads and writes, writes — so it is fully instrumented.

   A procedure that only reads has its own file — copy `templates/procedure-readonly.sql`, not the
   full one with pieces removed. Otherwise copy the block from `templates/procedure.sql` verbatim;
   only the parameter list, `@KeyParameters`, the work between the two `=====` banners, and
   `@Comments` change.

   **`logs.ExecutionLog` and the four procedures come from `scripts/logExecutionLogging.sql`.** Run it against the
   database before deploying anything instrumented; until it has run, both templates reference objects that do not
   exist and every instrumented procedure fails on its first call.

   **Exactly five procedures are exempt**, and the exemption is structural rather than granted — the procedure that
   records a failure cannot open a row to record its own:

   | Exempt | Why there are four rather than two |
   |---|---|
   | `logs.uspStartExecutionLogging` | the wrapper a procedure calls |
   | `logs.uspStartExecutionLoggingInsert` | the inner procedure that does the `INSERT` |
   | `logs.uspRecordExecutionError` | the wrapper a `CATCH` block calls |
   | `logs.uspRecordExecutionErrorUpdate` | the inner procedure that does the `MERGE` |
   | `util.uspSetObjectDescription` | rule 4's helper; instrumenting it would log a row per column description |

   The wrapper/inner split is the seam that lets logging be redirected to a central logging database without editing a
   single caller — which is why the count is four. **Nothing outside that chain is exempt, whatever it is called.** A
   procedure in `logs` that is not one of the four is instrumented like any other.

   A module that **raises** an error of its own — an argument check, an immutable-key rejection in
   an `INSTEAD OF` trigger — uses `THROW` with a number a caller can branch on, never
   `RAISERROR (…, 16, 1)` followed by `RETURN`. `RETURN` ends the module and nothing else: the
   statement is silently not applied and the caller's batch continues believing it was.

   **Read `references/instrumentation.md` before writing or reviewing one.** It holds the
   reasoning behind every clause above, the exact `CATCH` shape, the flush pattern for logging
   other than `logs.ExecutionLog`, the `@ProcName` `COALESCE` rule that stops a procedure logging
   anonymously, and the error numbers this skill has claimed. That material used to sit here,
   which made the always-loaded file 300 lines long while its first line told you to read only the
   one file you need.
9. **`@KeyParameters`, `@Comments`, `@ContextMessage` and `@DynamicSql` carry identifiers and counts
   only.** Never a credential, an API key or bearer token, a URL query string, a request header, or
   `@Payload`. The monitoring web app reads `logs`, so anything written there is readable by
   whoever can open that page.
10. **Every database records its own DDL.** Before writing objects into a database, check that change logging is
    installed and current, and install it if it is not — see *Database change logging* below. A database whose schema
    can change without a record of who changed it is not a database this project ships.

## Schema placement

`dbo` user data · `auth` authn/authz · `logs` logging · `config` app configuration ·
`util` utility objects. Lower case, as written here.

Change logging adds two more, and they are not general-purpose: `logsData` holds the system-versioned base tables and
`history` holds their history tables. Nothing else goes in either one.

`RowHistory` on adds one more per consumer schema: **`<schema>Data`** holds the system-versioned base table while the
view keeps the table's name in the consumer schema — `dboData.Permit` under `dbo.Permit`. Its history table goes in
`history` alongside the change-logging ones. So a temporal table in `dbo` touches three schemas: `dbo`, `dboData`,
`history`. **All three must share one owner** (`dbo`), because the view is the only write path to the base table and
that works by ownership chaining; a different owner on any of them and every application write fails with a permission
error on a table the application is deliberately denied.

## Permissions

Granted at the **schema**, in `scripts/permissions.sql`, and nowhere else. Run it once per database, after the two
installers and before or after your own objects — a schema-scoped grant covers objects created later, which is the
entire reason it is schema-scoped.

| Schema | `applicationRole` | `readOnlyRole` |
|---|---|---|
| `dbo` | `SELECT`, `INSERT`, `UPDATE` | `SELECT` |
| `logs` | `SELECT`, `INSERT`, `UPDATE`, `DELETE` | `SELECT`; writes denied |
| `dboData`, `logsData`, `history` | **all denied** | **all denied** |

**`DELETE` is never granted on `SCHEMA::dbo`.** On the temporal shape a `DELETE` is safe to grant because it lands on a
view whose `INSTEAD OF DELETE` trigger converts it to `IsDeleted = 1`. A plain table has no such trigger, so `DELETE`
against it physically removes the row — soft-deleting a plain table's row is an `UPDATE`, which the `UPDATE` grant
already covers. A view that needs `DELETE` gets it as an object-level grant in its own script.

There is also **no `DENY DELETE ON SCHEMA::dbo`**, deliberately: withholding a permission and denying it are different,
and a schema-scoped `DENY` would sit above the object-scoped `GRANT DELETE` every temporal view carries. `DENY`
generally wins over `GRANT` regardless of scope, so that would break every soft delete in the database. Not granting is
sufficient — with no grant at any scope, permission is already refused.

**`EXECUTE` stays per procedure**, in that procedure's own script, to the roles that call it. A schema-wide `EXECUTE`
would hand every role every procedure written afterwards, including ones written for a different caller entirely.

**Why reads are granted at the schema and not per table.** They used to be per table, and `templates/table.sql` shipped
with no grant block at all, so a plain table deployed from it was readable by `db_owner` and by nobody else. Nothing
failed: a missing grant raises no error at deploy time, and SQL Server hides the metadata of an object a principal holds
no permission on, so the table did not even appear in Object Explorer. Silent, per table, and permanent. **If a `dbo`
table must not be readable by every application user, the grant is not the thing to change** — put it in a data schema,
which `permissions.sql` denies, and expose a view.

## Database change logging

The subsystem that records who changed which object, what they ran, and what the definition was immediately before.
Purpose-built for the question *"does this database have the logging tables and the objects that support them, and are
they current?"*

```
exec logs.uspDdlAuditVerify;                                 -- is the trail intact (run after deploying, and from a job)
sqlcmd -S <server> -d <db> -I -C -i scripts/checkDbChangeLogging.sql               -- is the machinery there (read-only)
sqlcmd -S <server> -d <db> -v DbName=<db> -I -C -i scripts/logdBChanges.sql        -- put it there, or bring it current
```

`logdBChanges.sql` takes its target from `-v DbName=` and **asserts it before changing anything**, so
`-v DbName=<db>` and `-d <db>` have to agree. They will stop the run if they do not, which is the
point: the old file hard-coded `USE [<one fixed database>]`, so passing `-d` while forgetting to edit the
file installed the subsystem into that database and then reported success from inside it. **Neither
installer carries a `:setvar DbName` default, and neither should be given one** — an in-file
`:setvar` overrides `-v` rather than deferring to it, so a default would beat the target the caller
named and quietly restore the failure the assertion is there to catch. The file needs sqlcmd mode —
sqlcmd itself, or SSMS with *Query > SQLCMD Mode* on.

**The workflow, in order:** check with `checkDbChangeLogging.sql` (read-only, catalog queries only, safe on a database
that has none of this); install or update with `logdBChanges.sql` (additive — an existing base table is transferred to
`logsData`, missing columns added one guard at a time, values back-filled once, versioning switched on, nothing
dropped); then verify with `uspDdlAuditVerify`, which answers a different question — not *is it installed* but *has it
been tampered with*.

**Read `references/change-logging.md` before changing any of it.** The parts that look simplifiable are load-bearing,
and that file says which and why.

## Naming

PascalCase throughout. Tables unprefixed; `vw` views, `usp` procedures, `udf` scalar functions,
`tvf` table-valued functions. Example: `dbo.FacilitySource`, `dbo.vwFacilitySource`,
`dbo.uspLoadFacilitySource`.

**Triggers** — `trg_` plus the firing shape plus the object's name, and they are the one deliberate
break from PascalCase, because the shape is what you need to read at a glance in a catalog listing:

| Trigger | Name |
|---|---|
| `INSTEAD OF INSERT` | `trg_ioi_ins_<ObjectName>` |
| `INSTEAD OF UPDATE` | `trg_iov_updt_<ObjectName>` |
| `INSTEAD OF DELETE` | `trg_iod_del_<ObjectName>` |
| `AFTER UPDATE` | `trg_au_updt_<ObjectName>` |

A DML trigger lives in the schema of the object it sits on. The three `INSTEAD OF` triggers sit on the
**view**, so a row-history table has all three in the view's schema: `dbo.trg_ioi_ins_Permit`,
`dbo.trg_iov_updt_Permit`, `dbo.trg_iod_del_Permit`. The `AFTER UPDATE` trigger sits on a **plain
table** and takes that table's schema: `dbo.trg_au_updt_FacilitySource`. Rule 5's header block applies
to a trigger exactly as it does to a procedure.

**Every table carries exactly one of the two arrangements.** A plain table gets the one `AFTER UPDATE`
trigger from `templates/table.sql` section 4; a wrapped table gets the three `INSTEAD OF` triggers from
`templates/table-temporal.sql`, on the view. A table with neither has an audit trail that holds only
while every caller maintains it by hand — the audit column `DEFAULT`s fire on `INSERT` only, so an
`UPDATE` leaves `auditModifiedBy` and `auditModifiedDateUtc` stale, and a soft delete records neither
who nor when. That is not a theoretical risk: it was measured against a real login holding exactly the
permissions `scripts/permissions.sql` grants, and all three failures reproduced.

**The one exemption, and the test for it.** A table whose *only* writer is a procedure that maintains
the audit columns explicitly does not need a trigger. `logs.ExecutionLog` is the sole example the skill
ships: the four logging procedures are its only writers and each sets `auditModifiedBy` and
`auditModifiedDateUtc` in its own `UPDATE`. The test is "only writer", not "usual writer" — a table any
caller can `UPDATE` directly does not qualify, and a plain table in `dbo` never qualifies, because
`scripts/permissions.sql` grants `UPDATE` on the whole schema. Do not extend this to a business table.

**What neither arrangement locks down, deliberately.** `auditModifiedBy` stays caller-overridable and
`auditCreatedBy` / `auditCreatedDateUtc` are untouched on `INSERT`. Both are the same on both shapes,
on purpose: the wrapped shape's `INSTEAD OF INSERT` trigger keeps caller-supplied audit values so a
migration can carry the originals across, and making the plain shape stricter would buy nothing but an
inconsistency. If you need `auditModifiedBy` non-forgeable, that is a change to **both** arrangements.

**Objects of the change-logging subsystem take the same names as everything else**, as of
2026-09-17: `logsData.DdlChange`, `logsData.DdlObjectState`, their history tables, the two wrapper
views in `logs`, `logs.udfTableShape` and `logs.uspDdlAuditVerify`.

They used to be `z_ddl_change`, `z_ddl_object_state`, `z_table_shape` and `z_ddl_audit_verify` —
lower_snake_case behind a `z_` prefix that sorted the machinery to the bottom of every object list —
and this document used to record that as an earned exemption. It was not one. The gate
(`.claude/hooks/validate-sql.py`) cites this file as its authority and enforces the rules above, so
under the old names `scripts/logdBChanges.sql`, the reference implementation the gate points at,
failed the gate it is the reference for. That is a worse problem than an untidy object list: a rule
whose own example cannot pass is a rule the next person switches off. The argument that renaming the
subsystem would be "the largest untracked change in the history it keeps" was also backwards — the
rename is recorded in `12c`, which is more than an ordinary `sp_rename` gets.

`record_db_changes`, the database-level DDL trigger, keeps its name: it is not schema-scoped, no
naming rule here covers it, and every diagnostic and runbook in the estate names it.

**Three exemptions remain, and they are in the gate rather than in prose** — a documented exemption
nobody can enforce is just a comment:

- `dboData`, `logsData` and `history` are valid schemas. They are structural to row history, not
  drift: see *Two arrangements* above.
- The row-history wrapper view does **not** take the `vw` prefix. It carries its base table's name
  on purpose — that is the whole point of the arrangement, and `vwDdlChange` over
  `logsData.DdlChange` would put the prefix on the object the application is supposed to think of as
  the table.
- The `@@PROCID` rule looks for `OBJECT_NAME (@@PROCID)`, not for `@@PROCID`.
  `TRIGGER_NESTLEVEL (@@PROCID, 'AFTER', 'DML')` does not need the `COALESCE` fallback and used to be
  flagged for not having one — it would have fired on every `AFTER UPDATE` audit trigger built
  from `templates/table.sql` section 4, which is one per plain table in the database.

**Indexes and constraints** carry their prefix, their schema and their table, for the same reason rule 2 gives for
`DF_`: these names are unique per database, so none of them can be copied from another table.

| | Name | Example |
|---|---|---|
| Primary key | `PK_<schema>_<Table>` | `PK_logs_ExecutionLog` |
| Unique index (every one filtered on `IsDeleted = 0`) | `UX_<schema>_<Table>_<Purpose>` | `UX_dbo_FacilitySource_Natural` |
| Non-unique index | `IX_<schema>_<Table>_<LeadingColumns>` | `IX_logs_ExecutionLog_ProcedureName_StartDateUtc` |
| Default constraint | `DF_<schema>_<Table>_<Column>` | `DF_logs_ExecutionLog_IsDeleted` |
| Check constraint | `CK_<schema>_<Table>_<Rule>` | `CK_dbo_Permit_StatusKnown` |
| Foreign key | `FK_<schema>_<Table>_<RefSchema>_<RefTable>` | `FK_dbo_Permit_dbo_Facility` |

**The name has to describe the definition.** An `IX_` naming a column it is not keyed on is worse than a vague name,
because the next person trusts it and adds a duplicate index rather than the one that was missing. Where an index is
filtered for a purpose, say the purpose — `IX_logs_ExecutionLog_Failures` is filtered `WHERE Successful = 0`.

## Soft delete and unique keys

A soft-deleted row still occupies its key. Use filtered unique indexes:

```sql
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'UX_dbo_FacilitySource_Natural'
                  AND object_id = OBJECT_ID (N'dbo.FacilitySource'))
BEGIN
    CREATE UNIQUE INDEX UX_dbo_FacilitySource_Natural
        ON dbo.FacilitySource (FacilityId, SourceType, Sequence)
        WHERE IsDeleted = 0;
END;
```

## Re-runnable scripts

The developer runs the DDL by hand, so a second run must change nothing and report nothing. The
usual shortcut — `DROP IF EXISTS` then `CREATE` — is **forbidden**: it is a hard delete of real
data, and this database has none.

| Object | Re-runnable form |
|---|---|
| Table | `IF OBJECT_ID (N'<schema>.<Table>', N'U') IS NULL BEGIN CREATE TABLE ... END` |
| Column | `IF COL_LENGTH (N'<schema>.<Table>', N'<Col>') IS NULL ALTER TABLE ... ADD ...` |
| Default constraint | `IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'DF_...')` |
| Check constraint | `IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_...')` |
| Foreign key | `IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_...')` |
| Index | `IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'...' AND object_id = OBJECT_ID (N'...'))` |
| Schema | `IF SCHEMA_ID (N'<schema>') IS NULL EXEC (N'CREATE SCHEMA <schema>')` — must be alone in its batch, hence the `EXEC` |
| View / procedure / function / trigger | `CREATE OR ALTER` — preserves `object_id`, so grants and extended properties survive |
| Extended property | `util.uspSetObjectDescription` — adds or updates |
| Seed / reference data | `MERGE`, or an insert guarded by `NOT EXISTS`. Never a bare `INSERT` |

Two things that are easy to miss:

- **Additive, not edited in place.** To add a column to a table that already exists somewhere,
  append a guarded `ALTER TABLE ... ADD` block; do not go back and edit the original
  `CREATE TABLE`, or the script stops converging on a populated database.
- **Converge, do not re-apply.** A re-run that `UPDATE`s rows also moves `auditModifiedDateUtc`,
  which makes the audit trail lie about when the data last changed.

Open every script with **`SET XACT_ABORT ON;`** so a partial failure does not leave half-applied DDL,
and **`SET QUOTED_IDENTIFIER ON;`** immediately after it. The second one is not decoration: `sqlcmd`
defaults `QUOTED_IDENTIFIER` **OFF** where every other client defaults it ON, the setting is **baked in
at `CREATE` time** (`sys.sql_modules.uses_quoted_identifier`), and a module or session carrying it OFF
**cannot run DML against a table with a filtered index — error 1934**. Every unique constraint here is a
filtered index, via the soft-delete rule, so that is every table. The module case does not fail at deploy
time: the script succeeds and the error surfaces later inside a procedure whose text is correct. The hook
rejects any script that `CREATE`s an object without it, and any `sqlcmd` line — including one written out
for the developer to run — needs `-I`.

## Checklist before handing off a script

- [ ] Correct schema for the object's purpose
- [ ] PascalCase, correct type prefix
- [ ] All 7 audit columns present (tables)
- [ ] **`RowHistory` respected** — off unless the request asked for it or the Configuration default says otherwise. If
      on: base table in `<schema>Data` system-versioned into `history`, the extended audit block, the view wrapper
      holding the table's name, all three INSTEAD OF triggers, grants on the view, and all three schemas owned by `dbo`
- [ ] The three `audit*By` columns are **`NVARCHAR (255)`** — not "128 or wider". Two separate
      things set the floor and they are different numbers: `DEFAULT (ORIGINAL_LOGIN ())` returns
      `sysname`, so under 128 the default itself raises a truncation error; and every `INSTEAD OF`
      trigger resolves these columns through `CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255))`,
      which cannot land in a 128-wide column at all. 255 satisfies both. Any `@ActorLogin`-style
      parameter carrying a login name is `NVARCHAR (255)` too, so a value that fits the column fits
      the parameter
- [ ] Every `DF_` constraint name carries this table's schema and name
- [ ] `MS_Description` on the table and on **every** column
- [ ] Header block present and filled in (views/procedures/functions/triggers)
- [ ] **Instrumented if it writes** — `TRY`/`CATCH`, `logs.ExecutionLog` opened and closed, the row
      re-created in the `CATCH`, and a **bare `;THROW;`** re-raising the original error number. Copied
      from `templates/procedure.sql`, not paraphrased
- [ ] **`TRY`/`CATCH` on a read-only procedure too**, with a `CATCH` that calls
      `logs.uspRecordExecutionError` with `@ExecutionLogId = NULL` and a `@ContextMessage` saying why
      that row is an orphan, before the bare `;THROW;`. Successful path only is skipped
- [ ] **Any logging other than `logs.ExecutionLog` is flushed from the `CATCH`** out of a table
      variable populated before `BEGIN TRANSACTION`, with no outcome on the failure rows
- [ ] **The `@ProcName` `COALESCE` fallback is *this* procedure's own bracket-quoted name**, not the
      template's and not a placeholder — it is the branch every application call takes
- [ ] **An error the procedure raises itself uses `THROW` with a branchable number**, never
      `RAISERROR` + `RETURN`, which lets the caller's batch continue past a statement that did nothing
- [ ] The four items above are summarised. `references/instrumentation.md` is the authority — read it
      before writing the procedure, not while reviewing it
- [ ] `@KeyParameters` / `@Comments` / `@ContextMessage` / `@DynamicSql` hold identifiers and counts
      only — no credential, no query string, no header, never `@Payload`
- [ ] The procedure script carries its **own `GRANT EXECUTE`**, guarded by
      `IF DATABASE_PRINCIPAL_ID (N'<Role>') IS NOT NULL`, to only the roles that call it — that is
      what makes the report at the end of `scripts/permissions.sql` authoritative
- [ ] Unique constraints filtered on `IsDeleted = 0`
- [ ] No hard `DELETE`, no `ON DELETE CASCADE`
- [ ] No SQL Server 2025-only features
- [ ] **Safe to run twice** — every `CREATE` guarded, `CREATE OR ALTER` on
      views/procedures/functions/triggers, descriptions via `util.uspSetObjectDescription`
- [ ] No `DROP TABLE` / `DROP COLUMN` / `TRUNCATE` anywhere, including as a re-run convenience
- [ ] **Change logging is installed in the target database** — `scripts/checkDbChangeLogging.sql` reads clean, or
      `scripts/logdBChanges.sql` has been run. New database, or a database this skill has not touched before: check it
      before writing objects into it, not after
- [ ] **`scripts/logExecutionLogging.sql` has been run** if the handoff includes an instrumented procedure. Its closing
      report reads clean, including the line on the owner of schema `logs` — ownership chaining is what lets the
      procedure's own completion `UPDATE` reach `logs.ExecutionLog` without a grant on the table
- [ ] `SET XACT_ABORT ON` **and `SET QUOTED_IDENTIFIER ON`** at the top; scripts clearly ordered for
      deployment. Any `sqlcmd` line that runs them passes `-I -C`, or use your deployment script
