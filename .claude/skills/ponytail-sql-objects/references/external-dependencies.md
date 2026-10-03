# What this skill does not ship

`SKILL.md` is self-contained: every rule in it holds on its own account, and there is no external requirements document
to go and read. This file covers the other kind of dependency — the things the *SQL* refers to by name and does not
create, and the project-specific identifiers baked into it.

Read this before installing the skill into a different repository or a different estate.

**The short version.** `templates/` and `scripts/` run against any SQL Server 2022 database. What they assume already
exists is a handful of database roles, one utility schema, and — for `scripts/logdBChanges.sql` — one loginless
principal it creates itself. Everything else in this file is either optional enforcement or a name to change.

---

## Database objects the templates reference and do not create

Each of these is referenced from a `GRANT` or an `EXECUTE AS` guarded on the principal existing, so a database that does
not have it gets a skipped grant and a printed note rather than a failed script. **That guard has a cost worth knowing:
a typo in a role name is a silent no-op** — the object deploys and nobody can execute it, with no error saying why. Check
the names against the permission script's own report rather than against your memory.

| Name | Kind | Referenced by | If it does not exist |
|---|---|---|---|
| `applicationRole` | database role | `GRANT EXECUTE` in the procedure templates and `scripts/logExecutionLogging.sql`; CRUD grants on the `logs` views | Grants are skipped. The applications cannot call the procedures. Create the role, or change the name. |
| `readOnlyRole` | database role | `SELECT` grants on `logs.ExecutionLog` and the change-logging views; the closing `GRANT EXECUTE` in `templates/procedure-readonly.sql` | The monitoring app cannot read the logs, and cannot call a read-only procedure. |
| `logsAuditReader` | database role | `SELECT` on `logsData` in `scripts/logdBChanges.sql` | Auditors have no read path to the DDL trail. |
| `ddl_audit_user` | loginless database user | the `EXECUTE AS` clause on the `record_db_changes` DDL trigger | `scripts/logdBChanges.sql` creates it. Rename it only before the first run — see the identifier list. |
| `util` schema and `util.uspSetObjectDescription` | schema + procedure | rule 4, from every template and both installers | Descriptions are **skipped with a printed note**, not failed. Deploy `templates/extended-properties.sql`, which creates both, then re-run. |
| `logs.ExecutionLog` and the four logging procedures | table + procedures | rule 8, from both procedure templates | Every instrumented procedure fails on its **first call**, not at deploy time. Run `scripts/logExecutionLogging.sql` first. This one ships with the skill; it is listed here because the templates depend on it and it is a separate run. |

---

## Identifiers the skill picks for you

None of these is load-bearing on the conventions, and none is a name borrowed from any other system. They are the
skill's own identifiers: some you will keep, one or two you may want to change. **Decide about each one before you
deploy.**

| Identifier | Where | What to do |
|---|---|---|
| `ddl_audit_user` | `scripts/logdBChanges.sql` (creation, the trigger's `EXECUTE AS`, and the `GRANT EXECUTE ON logs.udfTableShape`), `scripts/checkDbChangeLogging.sql` (reported MISSING by name), `references/change-logging.md`, `README.md` | Usually nothing. If your estate names such principals differently, rename it once, everywhere, **before the first run** — afterwards it means editing both scripts *and* dropping the old principal by hand on every database that has one, in that order. |
| `DdlAuditLogin` | `scripts/logdBChanges.sql` §1 | Same reasoning. §1 is also the one section needing `ALTER ANY LOGIN`; it reports and continues without it. |
| `dbo.FacilitySource`, `dbo.vwFacilitySource`, `dbo.uspSoftDeleteFacilitySource`, `dbo.Permit` | `templates/table.sql`, `templates/table-temporal.sql`, `templates/view.sql`, both procedure templates | **Deliberate worked examples**, and the only complete ones the skill has. `FacilitySource` stands in for a table mirrored from an external registry — a natural key it does not own, plus `Src*` provenance columns; `Permit` is a plain domain table. Replace the names when you copy a template; do not strip them out of the templates themselves, because a template with no concrete example stops showing how the pattern is applied. |

---

## Optional enforcement

Neither of these ships here. Without them the checks are conventions a reviewer applies by eye — which is the normal
case for this skill installed anywhere else, and is why the two rules they enforce are also written out in `SKILL.md`.

### `.claude/hooks/validate-sql.py`

Rejects a script that `CREATE`s an object without `SET XACT_ABORT ON` and `SET QUOTED_IDENTIFIER ON`, and rejects a
procedure whose header block sits after a `GO` (where `sys.sql_modules` will not store it).

The prologue check is the one worth applying by hand: `sqlcmd` is the one client that defaults `QUOTED_IDENTIFIER` OFF,
the setting is baked in at `CREATE` time, and a module carrying it OFF cannot run DML against a table with a filtered
index — error 1934, surfacing later, inside a procedure whose text is correct.

### A permission-posture check in your build

Asserts the error-only-read contract from the far side: a `logs.ExecutionLog` row appearing under an error-only
procedure's name on a **successful** call fails the check.

Without it, a start block half-added to a read-only procedure goes unnoticed until the monitoring grid starts showing
every call as a failure.

---

## Reference implementations named in comments

The templates and `references/instrumentation.md` name these as worked examples. Every one of them is an illustration
belonging to this skill, built on objects this skill defines — `dbo.FacilitySource` from `templates/table.sql` and
`logs.ExecutionLog` from `scripts/logExecutionLogging.sql`. None is a dependency, and there is no file to go and find:
the shape each one demonstrates is written out in full where it is mentioned.

| Named | Demonstrates | Written out in |
|---|---|---|
| `templates/procedure-readonly.sql` itself | An error-only read: `TRY`/`CATCH`, recording `CATCH`, no start row, no transaction | `templates/procedure-readonly.sql`, in full |
| `dbo.uspMergeFacilitySourceBatch` | The flush pattern — table variable populated before `BEGIN TRANSACTION`, failure rows flushed from the `CATCH` | `references/instrumentation.md`, all four steps |
| `logs.uspGetExecutionLogPage` | A read that is deliberately given *full* instrumentation | `references/instrumentation.md`. Note that this is an example of rule 8 **applied**, not an exemption from it — it is not one of the four logging procedures. |

---

## Deployment plumbing

### A permission script that denies metadata visibility

**This is not `scripts/permissions.sql`.** The one that ships here does the schema-level grants and nothing else. Some
deployments add a further script that also `DENY`s metadata visibility to the application logins. This skill does not
ship one — whether yours does is a decision for your estate — and two things in `SKILL.md` depend on it, both of which
survive its absence with a note:

- It `DENY`s metadata visibility to both application logins, which is why `OBJECT_NAME (@@PROCID)` returns `NULL` on
  every application call and why the `@ProcName` `COALESCE` fallback is the branch that actually runs. **In a project
  without it, `OBJECT_NAME (@@PROCID)` will usually resolve, so the fallback becomes the guard it looks like rather than
  the main path.** Keep it correct anyway — a procedure that logs anonymously is a procedure nobody can find in the
  monitoring grid.
- Its closing report is the authoritative statement of who can execute what, which is only true while every procedure
  script carries its own object-level `GRANT EXECUTE`. A schema-wide `GRANT EXECUTE ON SCHEMA::logs` silently includes
  every procedure added later and breaks that invariant. Both installers grant per object for this reason.

### A deployment script

Runs the scripts in order with the right `sqlcmd` switches. Without one, run them by hand and pass `-I -C` every time.
The order that matters:

1. `templates/extended-properties.sql` — creates `util.uspSetObjectDescription`, which everything else wants.
2. `scripts/logdBChanges.sql` — DDL change logging, so the rest of the deployment is recorded.
3. `scripts/logExecutionLogging.sql` — `logs.ExecutionLog` and the four logging procedures.
4. `scripts/permissions.sql` — the schema-level role permissions. Safe to run before your objects exist: a
   schema-scoped grant covers objects created afterwards, which is the reason it is schema-scoped.
5. Your own objects.

All three installers require `-v DbName=<database>` on every run — none carries an in-file default, and each asserts it
against `DB_NAME ()` and stops rather than guess.

`scripts/permissions.sql` is the one place the permission model is stated in full. Re-run it after adding a schema it
reports as `ABSENT` — `dboData` and `history` do not exist until the first table built from
`templates/table-temporal.sql`, so their `DENY` cannot be applied before then. It never revokes anything, so a
permission granted by hand survives it.
