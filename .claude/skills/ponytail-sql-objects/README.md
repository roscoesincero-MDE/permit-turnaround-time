# How to use this skill

This skill makes Claude write SQL Server objects the way this project requires — the audit columns, the soft delete, the
naming, the header blocks, the descriptions — without you having to restate the rules each time. It also installs and
checks the change logging that records who altered which database object.

You do not run this skill. You just ask for what you want, and it applies.

---

## 1. Install it (once)

The folder must be named after the skill, and it goes in one of two places.

**For this project only:**

```
<your project>\.claude\skills\ponytail-sql-objects\
```

**For every project on this machine:**

```
C:\Users\<you>\.claude\skills\ponytail-sql-objects\
```

Copy this whole folder there and rename the copy to `ponytail-sql-objects` — `SKILL.md`, `templates\`, `scripts\` and
`references\` must all sit inside it. Then restart Claude Code. Type `/skills` to confirm `ponytail-sql-objects` is listed.

That is the entire installation. Nothing to configure, no dependencies.

---

## 2. Use it (just ask)

Ask in plain language. The skill loads by itself when the request touches SQL objects.

| Say something like | You get |
|---|---|
| "Add a `Permit` table to `dbo`" | A guarded `CREATE TABLE` with all 7 audit columns, `DF_dbo_Permit_*` constraint names, a filtered unique index, an `AFTER UPDATE` trigger that maintains the audit columns, and a description on the table and every column |
| "Add a `PermitStatus` column to `dbo.Permit`" | A separate guarded `ALTER TABLE ... ADD` block — it will not edit the original `CREATE TABLE` |
| "Write a view over `dbo.Permit`" | A `CREATE OR ALTER VIEW` with the header block and `WHERE IsDeleted = 0` |
| "Write a procedure that merges the permit batch" | A procedure with the header block, `TRY`/`CATCH`, the `logs.ExecutionLog` instrumentation, and a bare `;THROW;` |
| "Does this database record its schema changes?" | The read-only check script, and what to do about anything missing |
| "Set up change logging on `MyDatabase`" | The install script and the `sqlcmd` line to run it, with `-d` and `-v DbName=` both naming your database |
| "Set up the execution logging this expects" | `scripts\logExecutionLogging.sql`, and the `sqlcmd` line to run it |
| "`applicationRole` cannot see my new table" | `scripts\permissions.sql` — the schema-level grants, and why `DELETE` is not among them |
| "`Permit` needs row history — auditors will ask what changed" | The temporal version: a versioned base table, a view wrapper, and the three `INSTEAD OF` triggers |

You can also be explicit: "use the ponytail-sql-objects skill".

**Say which database you mean.** The skill cannot see your server. It writes scripts for you to run; it does not connect
to anything.

---

## 3. The one setting

Tables do **not** get history tracking unless you ask for it. That is the only switch, and it lives in the
Configuration table near the top of `SKILL.md`:

| | |
|---|---|
| **Default** | Off. A normal table. Current values only. |
| **Turn it on for one table** | Say so in the request — "needs row history", "make it temporal", "we need to see what this row used to say". |
| **Turn it on for everything** | Edit the `Default` cell in the Configuration table in `SKILL.md` to `on`. |

Turning it on later is fine. A table that already exists and already has rows can be converted with nothing dropped and
no data lost, and callers keep using the same name. So "off" is not a decision you have to get right up front.

Change logging for the *database* is always on — that is separate from this switch and is not optional.

---

## 4. The SQL scripts you run

These are the only files here you run yourself. On a database this skill has not touched before, run all four, in the
order below.

**Install execution logging** — the table and the four procedures every instrumented procedure calls:

```
sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i scripts\logExecutionLogging.sql
```

Do this **before** deploying any procedure written to these conventions. Every one of them opens a row in
`logs.ExecutionLog`, so until this has run they fail on their first call — not at deploy time, which is what makes it
worth doing first rather than when something breaks. It ends with a report; read it. Re-running it is safe and changes
nothing.

It needs the same `-d` / `-v DbName=` agreement as the change-logging script below, for the same reason, and it stops
if they disagree.

**Check what a database has** — read-only, safe any time, changes nothing:

```
sqlcmd -S <server> -d <database> -I -C -i scripts\checkDbChangeLogging.sql
```

It prints one line per object: `OK`, `STALE` or `MISSING`, and the fix for each.

**Install it, or bring it up to date** — name your database twice and run it:

```
sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i scripts\logdBChanges.sql
```

Then check the result:

```sql
EXEC logs.uspDdlAuditVerify;
```

**Name it twice, and the two have to match.** `-d` is the connection; `-v DbName=` is what the script installs into.
The script compares them before it changes anything and stops if they disagree. That is deliberate: it used to have
`USE [<one fixed database>];` written into it, so passing `-d YourDatabase` and forgetting to edit the file installed the whole
subsystem into that database — and then printed a clean report, because the report ran there too.

**There is no `:setvar DbName` default to edit, and that is deliberate.** An in-file `:setvar` *overrides* `-v` on the
command line rather than yielding to it — measured, not assumed — so a default left in the file would silently win over
the `-d`/`-v` pair you passed and reintroduce the exact failure the assertion exists to catch. `-v DbName=` is the only
way to name the target. Both installers carry a comment block where the `:setvar` used to be, explaining this.

**The `-I` is required.** `sqlcmd` is the one client that turns `QUOTED_IDENTIFIER` off by default, and without `-I`
things fail later in ways that look unrelated. Every `sqlcmd` line in this project carries `-I -C`.

**It needs sqlcmd mode.** The file uses `:setvar` and `:on error exit`. Run it with `sqlcmd`, or in SSMS with
*Query > SQLCMD Mode* switched on. Without that it fails on the first line — which is the intended outcome, because
the alternative failure is silent.

Running the install script twice is safe and expected. It never drops anything, never deletes a row, and a second run
on an already-correct database changes nothing. It switches the DDL trigger off at the start and back on at the end. If
a run fails in between, the trigger is left **disabled** — which the check script reports in bold. It is never dropped,
so "the install broke" never looks like "this was never installed".

**A first install does record some of itself, and that is worth knowing before you read the log.** The disable window
covers the object creation, not everything: `logdBChanges.sql` sets its own extended properties in section 14, after
the trigger is back on, so a fresh install lands roughly 65 `CREATE_EXTENDED_PROPERTY` rows describing the
change-logging subsystem itself. `logExecutionLogging.sql` does not disable the trigger at all, so every object it
installs — table, three indexes, five procedures, their descriptions and their grants — is recorded in full. Neither is
harmful; both mean the first hundred-odd rows of `logs.DdlChange` on a new database are the install talking about
itself, not changes anyone made. A second run of either script adds nothing, because nothing changes.

**Apply the permissions** — who may do what to each schema:

```
sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i scripts\permissions.sql
```

**Run this, or the tables you deploy will be readable by `db_owner` and by nobody else.** It grants `SELECT`, `INSERT`
and `UPDATE` on `SCHEMA::dbo` to `applicationRole` and `SELECT` to `readOnlyRole`, and denies `dboData`, `logsData` and
`history` to both. Because the grants are schema-scoped they cover tables you have not written yet, so you run this once
and not per table.

`DELETE` is deliberately not granted on `SCHEMA::dbo`: a plain table has no `INSTEAD OF DELETE` trigger, so a `DELETE`
there would physically remove the row. Soft-deleting a plain table's row is an `UPDATE`. A view that needs `DELETE` gets
it in its own script, where the trigger makes it a soft delete.

It does not create the roles — which principals exist is your decision — but it names any that are missing instead of
skipping quietly, and it ends by reading the permissions back out of the catalog so you can see what actually applied.
It never revokes anything. Re-run it after adding a schema it reports as `ABSENT`.

**It covers `dbo`, `logs`, `dboData`, `logsData` and `history`, and no others.** A schema you add yourself gets neither a
grant nor a deny, and the closing report lists what *was* applied rather than what was not — so the omission is invisible
at deploy time and surfaces later as a permission error inside a procedure that reads one of its objects. Measured on a
first install: after this script ran, a `config` schema and a `util` schema created by the same deployment held no
permission at all for either application role. If your deployment adds schemas, grant them explicitly in a script of your
own, and decide deliberately when the answer is "nothing" — including for the `util` schema this skill's own
`extended-properties.sql` creates.

You need `db_owner` on the target database. One optional section also needs `ALTER ANY LOGIN` on the server; without it
that section reports and carries on.

---

## 5. What this skill will never produce

Useful to know, because it is deliberate rather than an oversight:

- **No `DROP TABLE`, `DROP COLUMN` or `TRUNCATE`** — not even as a convenience to make a script re-runnable.
- **No hard `DELETE`.** Deleting means `IsDeleted = 1`; the row stays and every read filters it out.
- **No `DROP ... CREATE`** to make a script repeatable. Everything is guarded or `CREATE OR ALTER`. That includes the
  DDL trigger in the install script, which is disabled and re-enabled rather than dropped and recreated.
- **No SQL Server 2025-only features.** The floor is 2022, and it is a real floor — the procedure template uses
  `LEAST ()`, which does not exist before 2022.

If you actually want one of these, say so plainly — it will be written, with the consequence stated.

---

## 6. If something looks wrong

| Symptom | Cause |
|---|---|
| Claude ignores the conventions | The folder is not named `ponytail-sql-objects`, or it is not under a `.claude\skills\` path. Check `/skills`. |
| "Property already exists" on a second run | A description was set with `sp_addextendedproperty` directly. Use `util.uspSetObjectDescription`. |
| Error 1934 on a filtered index | `QUOTED_IDENTIFIER` was off. Add `-I` to the `sqlcmd` line and re-create the object. |
| A write through a view fails on the base table | The schemas stopped sharing an owner. Re-run section 2 of `logdBChanges.sql`. |
| Descriptions were skipped | `util.uspSetObjectDescription` is not in the database. Deploy `templates\extended-properties.sql`, then re-run. |
| "Target mismatch. Connected to \[X] but this file is configured for \[Y]" | `-d` and `-v DbName=` disagree. Nothing was changed. Make them match. |
| "Incorrect syntax near ':'" on the first line | Not running in sqlcmd mode. Use `sqlcmd`, or turn on *Query > SQLCMD Mode* in SSMS. |
| "Invalid object name 'logs.ExecutionLog'" on the first call of a new procedure | `scripts\logExecutionLogging.sql` has not been run against that database. Run it; nothing needs redeploying afterwards. |
| A procedure fails with a permission error *inside* its logging block, on logic that is fine | The `logs` schema is not owned by `dbo`, so ownership chaining does not reach the log table. `ALTER AUTHORIZATION ON SCHEMA::logs TO dbo;` — the install report checks this and names it. |
| An instrumented procedure runs but no row appears in `logs.ExecutionLog` | Its `CATCH` recorded nothing because the transaction was already doomed, or the procedure never called the start wrapper. Look for rows whose `ContextMessage` starts with the no-start-row note. |
| The check script says `record_db_changes` is DISABLED | An install run failed part way through and never reached the end. Fix whatever it reported, then run it again — it converges. |
| A write lands but the audit columns are not filled in | An audit trigger is disabled — one of the three `INSTEAD OF` triggers on a wrapped table, or the `trg_au_updt_` `AFTER UPDATE` trigger on a plain one. The check script names it and prints the `enable trigger` line. |
| An `UPDATE` on a plain table leaves `auditModifiedDateUtc` at its insert-time value | The table has no `trg_au_updt_<Table>` trigger. The audit column `DEFAULT`s fire on `INSERT` only, so without it every `UPDATE` leaves the trail stale and a soft delete records neither who nor when. Add section 4 of `templates\table.sql`. |
| A `DELETE` on a table you expected to soft-delete removed the row outright | The table is system-versioned but was left in `dbo` instead of a `<schema>Data` schema, so it has no view wrapper — and it cannot be given one under its own name, because a view and a table cannot share a name in one schema and a versioned table cannot carry an `INSTEAD OF` trigger. The check script reports the placement and prints the `alter schema … transfer` line. Re-run `scripts\permissions.sql` afterwards: a `TRANSFER` discards the object's permissions. |
| The audit trail is being maintained but the check script reports the trigger name as `STALE` | The `AFTER UPDATE` trigger works and is simply not named `trg_au_updt_<Table>`, so nothing that goes looking for it by convention — this table, `SKILL.md` rule 5, the next person — will find it. Not urgent and not a data problem. `sp_rename` it. |
| `auditModifiedBy` shows a value the application never sets | Working as intended, and the same on both table shapes. `auditModifiedBy` is the one audit column a caller may set explicitly; everything else is recomputed. If you need it non-forgeable, that is a change to both the plain trigger and the view's `INSTEAD OF UPDATE` trigger, not to one of them. |
| An application user can see the `dbo` **views** but not the `dbo` **tables** | `scripts\permissions.sql` has not been run. The views carry object-level grants from their own scripts; plain tables get theirs from the schema grant, so without it they are invisible — SQL Server hides the metadata of an object you hold no permission on, which is why the table is missing from Object Explorer rather than erroring. |
| An application user sees nothing at all, and the permissions look right | The role has no members. `permissions.sql` prints an `INFO` line when a role is empty. `ALTER ROLE applicationRole ADD MEMBER <user>;` |
| "The DELETE permission was denied on the object" for a plain `dbo` table | Working as intended. `DELETE` is never granted on `SCHEMA::dbo` because a plain table would be hard-deleted. Soft delete with `UPDATE … SET IsDeleted = 1`, or go through a view. |

---

## 7. What is in this folder

| Path | What it is |
|---|---|
| `SKILL.md` | The rules. Claude reads this; you only edit it to change the `RowHistory` default. |
| `templates\table.sql` | Normal table, plus the `AFTER UPDATE` trigger that maintains its audit columns |
| `templates\table-temporal.sql` | Table with row history (opt-in), plus the three `INSTEAD OF` triggers on its view |
| `templates\view.sql`, `object-header.sql` | View, and the mandatory header block |
| `templates\procedure.sql` | Procedure that **writes** — full execution logging |
| `templates\procedure-readonly.sql` | Procedure that **only reads** — logs failures, not successes |
| `templates\extended-properties.sql` | `MS_Description`, and the helper that sets it |
| `scripts\checkDbChangeLogging.sql` | Read-only report on a database |
| `scripts\logdBChanges.sql` | Installs / updates change logging |
| `scripts\logExecutionLogging.sql` | Installs `logs.ExecutionLog` and the four procedures the instrumented procedures call. Run it first |
| `scripts\permissions.sql` | The whole permission model: which role may do what to which schema. Run it, or your tables are invisible |
| `references\change-logging.md` | How change logging works, and why it is shaped that way. Read before changing it. |
| `references\instrumentation.md` | The long form of the procedure-logging rule |
| `references\external-dependencies.md` | The roles and schemas the SQL expects to exist, and the project names to change — read this before installing it into a different estate |

---

## Names you will see

Three names this skill picks for you. The first is fixed and not worth changing; the second is a
deliberate absence; the third is live, and worth checking before your first deploy.

- **`ddl_audit_user`** — the loginless principal the DDL trigger runs as. It is fixed, and both scripts refer to
  it by that exact name: the check script reports it MISSING by name, and the trigger's `EXECUTE AS` clause binds to
  it. Renaming it means editing both scripts *and* dropping the old principal by hand on every database that already
  has one, in that order. Not worth doing for tidiness.
- **The target database — there is no default, deliberately.** No script carries a `:setvar DbName` line and none
  should be given one: an in-file `:setvar` *overrides* `-v` on the command line rather than giving way to it, so a
  "harmless default" would silently decide the target on every documented run. Supply the database with
  `-v DbName=<database>` every time. Each installer asserts it against `DB_NAME ()` and stops rather than guess.
- **`applicationRole`** and **`readOnlyRole`** — the roles the two procedure templates grant `EXECUTE` to, in the block at the
  very bottom of each file. Unlike the two above these are not historical: they are the same two roles
  `scripts\permissions.sql` grants at schema level, so the templates and the permission model name one set of roles
  between them. Create them, or change the name in both places — `references\external-dependencies.md` says what each
  one costs.

Every grant in this skill is guarded on the role existing, so a name you have not created is a **silently skipped
grant** — the object deploys and nobody can execute it. Check the names before you wonder why.

**The worked examples belong to this skill.** `dbo.FacilitySource` (a table mirrored from an external registry) in
`table.sql`, `dbo.Permit` in `table-temporal.sql`, `dbo.uspSoftDeleteFacilitySource` and `dbo.vwFacilitySource` in the
procedure and view templates, `dbo.uspMergeFacilitySourceBatch` and `logs.uspGetExecutionLogPage` in
`references\instrumentation.md`. Every one of them is an illustration written for this skill and built on objects this
skill defines — none is borrowed from a real system, and there is no other repository where you would find them.

They are deliberate: a template with the concrete parts stripped out stops showing how the pattern is applied. Replace
the names when you copy one; do not empty out the templates.

---

## One caveat worth stating

The SQL in `scripts\` **has now been run** — installed from empty and then re-run on a throwaway database, on SQL Server
2025, in the documented order with `-I -C -b` and `-v DbName=`. All four installed clean, `checkDbChangeLogging.sql` read
clean on both passes, and the second pass changed nothing. No script needed to change. Three things that exercise found,
none of them a defect and all of them easier to read about here than to diagnose on the day:

- **`logs.uspDdlAuditVerify` raises a deferred-resolution warning on a first pass.** It references
  `logs.uspRecordExecutionError`, which `logExecutionLogging.sql` creates one script later. It resolves before anything
  calls it and the warning does not recur on a second run. Do not fix it by swapping the two installers: then
  `logExecutionLogging.sql`'s own DDL executes before the trigger that records DDL.
- **Re-runnability is a claim about state, not about the change log.** A converged second pass still appends roughly 45
  rows, because `CREATE OR ALTER` and each unconditional `GRANT`/`DENY` raise a DDL event whether or not anything
  differed. "Did the change log stay quiet?" is the wrong test for idempotency and will fail on a correct database.
- **`permissions.sql` covers only the five schemas it names** — see the paragraph in section 4. Anything else your
  deployment creates ends up with no permission at all, silently.

The process point from the review is still the right one and is what found all three: **a single throwaway database
exercised twice — installed from empty, then re-run — catches most of what a static read cannot.** Do that before
pointing this at anything populated, and read what `checkDbChangeLogging.sql` says before and after each run.
