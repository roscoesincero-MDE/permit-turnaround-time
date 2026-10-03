
/***********************************************************************************************************************
Script:         logdBChanges.sql
Purpose:        Per-database DDL auditing.  Records who changed which object and what statement they ran, and keeps a
                copy of the object definition as it stood immediately before the change so the previous version can be
                recovered.
Target:         SQL Server 2022.  That is the project floor and it is stated once, in SKILL.md rule 6.  Nothing in
                THIS file needs anything newer than 2017 (STRING_AGG, CREATE OR ALTER, system-versioned temporal
                tables), but templates/procedure.sql uses LEAST(), which is 2022+, so the floor is real and not
                nominal.  Do not re-declare a lower one here.
Run as:         db_owner (or equivalent) in the target database.  Section 1 additionally needs ALTER ANY LOGIN in
                master; if the executing principal does not have it, that section reports and continues.
Run with:       sqlcmd, or SSMS with Query > SQLCMD Mode on.  The file uses :on error exit and $(DbName).
                Run without sqlcmd mode it fails on the first line, which is the intended outcome: the alternative
                failure -- installing into the wrong database and reporting success -- is silent.
Idempotent:     Yes.  Re-running never drops the audit tables, never discards audit history, and a clean second run
                changes nothing.  Every CREATE is guarded; every column, period and index is added additively and is
                guarded on ITS OWN name, so a run that fails part way through is repaired by running it again rather
                than by hand.
                One thing does change on every run, deliberately: record_db_changes is DISABLED in section 3 and
                ENABLED again in section 15, so the script does not audit its own install.  It is never dropped.  A
                run that fails in between leaves it disabled, and a disabled trigger is what both
                checkDbChangeLogging.sql and logs.uspDdlAuditVerify report as a problem -- a dropped one would be
                indistinguishable from "never installed".
To retarget:    Pass it per run:  sqlcmd -d <database> -v DbName=<database>.  There is no in-file default and adding
                one back would break this, for the reason set out above section 0.  Everything after section 2 is
                database-agnostic, so the same file can be run against each database that needs its own audit tables.

Shape
-----
Three schemas, one job each.  This is what makes INSTEAD OF semantics possible on a temporal table, which cannot carry
an INSTEAD OF trigger itself:

  logsData     the base tables.  System-versioned.  No direct application access.
  history      the history tables.  Written only by the engine.
  logs         the views the world reads and writes, their INSTEAD OF triggers, and the helper modules.

Objects created
---------------
  logsData.DdlChange       Append-only event log, system-versioned.  One row per DDL event, with PriorDefinition and
                             NewDefinition.
  logsData.DdlObjectState  Current definition of each schema-scoped object, system-versioned.  Source of the "before"
                             image; every version it has ever held is in history.DdlObjectState.
  history.DdlChange        History table.  Should be EMPTY: the event log is append-only, so any row here is evidence
                             that an event row was edited or deleted.
  history.DdlObjectState   History table.  One row per superseded object definition.
  logs.DdlChange           Updatable view over the base table, filtered IsDeleted = 0, with INSTEAD OF triggers.
  logs.DdlObjectState      Updatable view over the base table, filtered IsDeleted = 0, with INSTEAD OF triggers.
  logs.udfTableShape       Scalar function.  Renders a table's columns and indexes as diffable text.
  logs.uspDdlAuditVerify   Procedure.  Reports the integrity posture of the audit subsystem.
  record_db_changes        Database-level DDL trigger.
  logsAuditReader        Database role.  SELECT on the views, the base tables and the history tables.
  applicationRole, readOnlyRole  Database roles.  See section 11.

Renamed, 2026-09-17
-------------------
Everything above used to be named z_ddl_change, z_ddl_object_state, z_table_shape and z_ddl_audit_verify, with the six
INSTEAD OF triggers and every DF_/PK_ constraint carrying the old table name.  Sections 4a and 5a migrate a deployed
database onto the new names -- system versioning off, sp_rename, constraints and indexes renamed from the catalog, the
old views dropped, versioning back on in 4e/5e -- and 12c retires the state rows the old names left behind.  Read 4a
before touching any of it; the sequence has one failure mode that would silently orphan the history, and 4a-3 exists to
stop it.

If you have consumers on the old names, they will get "invalid object name" rather than stale rows.  That is the point.

Optional dependency
-------------------
  util.uspSetObjectDescription   When it exists, section 14 applies MS_Description to both tables, every one of their
                                 columns, both views and both modules.  When it does not, section 14 prints a note and
                                 is skipped: this file is also run against databases that have no util helpers, and the
                                 audit subsystem has to deploy there too.  Deploy the helper and re-run to fill them in.

Retired by the move to temporal tables
--------------------------------------
  logs.z_ddl_row_hash            DROPPED.  The SHA-256 hash chain existed to make an edited or removed event row
  logs.z_ddl_change_verify       DROPPED.  detectable.  System versioning now does that: an UPDATE or DELETE against
  DdlChange.PrevRowHash       no longer written.  logsData.DdlChange copies the prior row into
  DdlChange.RowHash           no longer written.  history.DdlChange, so the history table of an append-only log
                                 is a tamper report by definition.  logs.uspDdlAuditVerify reads it.

                                 The chain also cost more than it looked: computing it required reading the tail of the
                                 event log under UPDLOCK, HOLDLOCK, which serialised every DDL statement in the
                                 database.  The trigger now takes UPDLOCK, HOLDLOCK on one state row instead, so
                                 concurrent DDL against different objects no longer blocks.

                                 What is lost with it: the chain could be anchored off-instance (copy the highest
                                 ChangeId and its RowHash elsewhere) and would then detect edits made while system
                                 versioning was paused.  Temporal history cannot see those.  The mitigation is
                                 unchanged and is still the only durable one -- copy rows to an instance held by
                                 someone other than the people being audited.  See the trigger header.

                                 The two hash columns are NOT dropped where they already exist: this database performs
                                 no destructive DDL.  They are made NULLable, stop being written, and keep whatever
                                 they already hold.  Rows written before this script ran can still be verified by hand
                                 against a saved copy of the old function.  logs.DdlChange does NOT project them,
                                 though, so a query that still reads RowHash or PrevRowHash has to go to
                                 logsData.DdlChange directly, which needs logsAuditReader.  NOT readOnlyRole:
                                 scripts/permissions.sql denies that role SELECT on every data schema.

Column overlap, stated rather than hidden
-----------------------------------------
The standard audit block was added to tables that already had columns meaning the same thing.  No COLUMN was renamed or
dropped -- renaming one breaks a consumer silently and dropping one destroys data, and neither is worth the tidiness --
so three pairs overlap on DdlChange.  (The tables and modules themselves were renamed, in 2026-09-17; see section 4a.
An object rename is a different proposition: it fails loudly, it is reversible, and every reader of these two is in
this file.)

  RecordedUtc   / auditCreatedDateUtc     both = when the audit row was written
  OriginalLogin / auditCreatedBy          both = ORIGINAL_LOGIN() of the session that ran the DDL
  ProgramName   / DbApplication           both = APP_NAME()

and one on DdlObjectState:

  UpdatedUtc    / auditModifiedDateUtc    both = when the state row last changed

The audit* column is canonical in new code; the legacy name is kept for existing consumers and is written with the
same value.  Do not "fix" this by dropping a column.
***********************************************************************************************************************/

-- :on error exit stops the run on the first error instead of carrying on into the next batch.  It is not a nicety
-- here: there is no enclosing transaction -- every GO commits its own batch -- so without it a failure in the middle
-- of the file lets every later section run against a half-applied install.
:on error exit

-- THE TARGET DATABASE IS SUPPLIED ON THE COMMAND LINE AND HAS NO DEFAULT:
--
--     sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i logdBChanges.sql
--
-- There is deliberately no `:setvar DbName` line here, and adding one back would break the documented invocation
-- above.  Measured on sqlcmd 17: WHEN A FILE SETS A VARIABLE WITH :setvar, THAT VALUE WINS OVER -v ON THE COMMAND
-- LINE.  It is not a fallback for when -v is absent -- it overrides -v outright.  So while this file carried
-- a `:setvar DbName` default, every documented run of it was silently targeting THAT hard-coded name no matter what -v
-- said, and the only thing standing between that and installing the whole subsystem into the wrong database was the
-- assertion in section 0.  Which held, and is why this was found rather than deployed.
--
-- Omitting -v is therefore the safe failure, not the dangerous one: sqlcmd reports
--   'DbName' scripting variable not defined.
-- and the `:on error exit` above stops the run before the first batch, so nothing is changed.  If you want the target
-- hard-wired into the file rather than passed each time, edit the two `$(DbName)` references directly -- section 0's
-- assertion and section 2's USE -- and accept that the file is then single-database.
--
-- Section 2 does USE [$(DbName)]; section 0 checks that the connection agrees before anything is changed.

-- XACT_ABORT so a partial failure leaves no half-applied DDL.  QUOTED_IDENTIFIER because sqlcmd defaults it OFF where
-- every other client defaults it ON, it is baked into every module at CREATE time, and a module carrying it OFF cannot
-- run DML against a table with a filtered index (error 1934).  ANSI_NULLS is required by the XML methods in the DDL
-- trigger.  Any sqlcmd line running this file needs -I.
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


-- *** 0. Assert the target ***
-- Every documented invocation of this file passes the database on the command line AND expects the file to name the
-- same one.  When those two disagree the old behaviour was silent: the USE won, the subsystem was installed into
-- whichever database the file named, and section 15's report -- run against that same wrong database -- said it
-- worked.  So check it here, before section 1's USE [master], while DB_NAME() is still whatever -d selected.
--
-- Severity 16 rather than the 20 that would kill the connection outright: severity 20 needs sysadmin or ALTER TRACE,
-- and this file is documented to run as db_owner.  The :on error exit above is what turns the error into a stopped
-- run rather than a skipped batch.
IF DB_NAME () <> N'$(DbName)'
BEGIN
    DECLARE @Mismatch nvarchar(2000) =
        N'Target mismatch. Connected to [' + DB_NAME () + N'] but this file is configured for [$(DbName)]. '
      + N'Either connect with  -d $(DbName)  or override the file with  -v DbName=' + DB_NAME ()
      + N'. Nothing has been changed.';

    THROW 50000, @Mismatch, 1;
END
GO


-- *** 1. Server level: remove the old audit login ***
-- The previous version of this script created [DdlAuditLogin] with a password written in clear text in the
-- script itself, and granted it INSERT and SELECT on the audit table.  Anyone able to read the script could therefore
-- connect and both read and forge audit rows.  The trigger no longer uses a login at all (see section 3), so the login
-- is removed.

USE [master];
GO

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'DdlAuditLogin')
    BEGIN
        DROP LOGIN [DdlAuditLogin];
        PRINT N'Dropped login [DdlAuditLogin].';
    END
END TRY
BEGIN CATCH
    PRINT N'Could not drop [DdlAuditLogin]: ' + ERROR_MESSAGE()
        + N'  Drop it manually; it is no longer used by the audit trigger.';
END CATCH
GO


-- *** 2. Schemas ***

USE [$(DbName)];     -- supplied by  sqlcmd -v DbName=<database>.  Section 0 has already checked it against DB_NAME ().
GO

-- Created only when missing.  These are never dropped: DROP SCHEMA fails once the schema holds objects, and dropping
-- an empty schema silently discards every permission that had been granted on it.
-- CREATE SCHEMA must be the only statement in its batch, hence the EXEC.
--
-- Only the schemas this file actually puts something in.  It used to create [Auth] as well, which nothing in this file
-- references -- no object, no grant, no permission -- and which SKILL.md spells `auth`, lower case.  Two problems, and
-- the reason it is gone rather than corrected in place.  A schema created here is a schema this file can never tidy up,
-- by the rule stated immediately above; and on a case-sensitive collation `Auth` and `auth` are two different schemas,
-- so an installer with no stake in either one got to decide which spelling the database ends up with.  Whichever script
-- owns authn/authz objects creates the schema it needs.
IF SCHEMA_ID(N'history')  IS NULL EXEC (N'CREATE SCHEMA [history]');
GO
-- util is created even though this file only CALLS util.uspSetObjectDescription and never defines it: section 14 skips
-- the descriptions when the helper is absent, and the schema has to exist for the deploy of templates/
-- extended-properties.sql that README.md then prescribes.
IF SCHEMA_ID(N'util')     IS NULL EXEC (N'CREATE SCHEMA [util]');
GO
IF SCHEMA_ID(N'logs')     IS NULL EXEC (N'CREATE SCHEMA [logs]');
GO
IF SCHEMA_ID(N'logsData') IS NULL EXEC (N'CREATE SCHEMA [logsData]');
GO

-- Ownership has to match across the three schemas or nothing else in this file works.  The views in logs are the only
-- write path to the base tables in logsData, and that works by ownership chaining: same owner on both sides means the
-- caller's permissions are checked on the view and NOT on the base table -- for the view's own SELECT and for the
-- INSTEAD OF triggers' DML alike.  A different owner on either schema breaks the chain, and every application write
-- then fails with a permission error on a table the application is deliberately denied.
-- Guarded so a clean re-run prints nothing.
IF EXISTS (SELECT 1
             FROM sys.schemas             AS s
             JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
            WHERE s.name = N'logs' AND p.name <> N'dbo')
BEGIN
    ALTER AUTHORIZATION ON SCHEMA::logs TO dbo;
    PRINT N'Schema logs transferred to dbo.';
END
GO

IF EXISTS (SELECT 1
             FROM sys.schemas             AS s
             JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
            WHERE s.name = N'logsData' AND p.name <> N'dbo')
BEGIN
    ALTER AUTHORIZATION ON SCHEMA::logsData TO dbo;
    PRINT N'Schema logsData transferred to dbo.';
END
GO

IF EXISTS (SELECT 1
             FROM sys.schemas             AS s
             JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
            WHERE s.name = N'history' AND p.name <> N'dbo')
BEGIN
    ALTER AUTHORIZATION ON SCHEMA::history TO dbo;
    PRINT N'Schema history transferred to dbo.';
END
GO


-- *** 3. Audit principal and roles ***

-- Turn the DDL trigger off for the duration of this run, so the script does not audit its own install.  Section 15
-- turns it back on.
--
-- It is deliberately NOT dropped.  The previous version of this file opened with DROP TRIGGER and did not recreate
-- the trigger until section 13, some 1,600 lines later, with every table, view, trigger, permission and the baseline
-- snapshot in between.  Any failure in that window left the database with no DDL auditing at all and said nothing
-- about it: the operator saw the error from whatever statement broke, not "and change logging is now off".  Disabling
-- has none of that: a disabled trigger is reported as a problem by checkDbChangeLogging.sql and by
-- logs.uspDdlAuditVerify, both of which read is_disabled, whereas a dropped one on a half-failed run looks exactly
-- like "never installed".
--
-- Nothing here needs the drop either.  It existed only to let the execution-context user be dropped -- a principal
-- named in a module's EXECUTE AS clause cannot be dropped while that module exists -- and the user is no longer
-- dropped.  Section 13 is CREATE OR ALTER, which does not require the trigger to be absent.
IF EXISTS (SELECT 1 FROM sys.triggers
            WHERE parent_class = 0 AND name = N'record_db_changes' AND is_disabled = 0)
BEGIN
    DISABLE TRIGGER record_db_changes ON DATABASE;
    PRINT N'Disabled record_db_changes for the duration of this run; section 15 enables it again.';
END
GO

-- The audit user, WITHOUT LOGIN.  EXECUTE AS works on a loginless user, so the trigger can still write to the audit
-- tables on behalf of callers who have no rights on them, but there is no credential to steal and no way to
-- authenticate as this principal.
--
-- Created only when missing.  The previous version dropped and recreated it on every run, which is what forced the
-- DROP TRIGGER above, and which also failed outright on any database where the principal happened to own a schema or
-- an object -- after the trigger had already gone.
IF DATABASE_PRINCIPAL_ID (N'ddl_audit_user') IS NULL
BEGIN
    CREATE USER [ddl_audit_user] WITHOUT LOGIN;
    PRINT N'Created [ddl_audit_user] (loginless).';
END
GO

-- An existing principal is left as it is rather than replaced.  Report it when it is not loginless, because replacing
-- it means dropping the trigger first, and that is a decision for a person rather than for a deployment script.
-- authentication_type 0 is NONE, which is what WITHOUT LOGIN produces.
IF EXISTS (SELECT 1 FROM sys.database_principals
            WHERE name = N'ddl_audit_user' AND type IN ('S','U','G') AND authentication_type <> 0)
    PRINT N'[ddl_audit_user] exists and is NOT loginless; it has been left alone. To replace it: drop '
        + N'record_db_changes, drop the user, re-run this file -- in that order, and not during business hours.';
GO

-- Read access to the audit tables is held by a role, not by the audit user, so that readers can be managed without
-- touching the trigger's execution context.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'logsAuditReader' AND type = 'R')
    CREATE ROLE [logsAuditReader];
GO

-- Ordinary application / end-user access: CRUD through the views in logs, nothing on logsData or history.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'applicationRole' AND type = 'R')
    CREATE ROLE [applicationRole];
GO

-- Read-only access to the base tables and history, for compliance or reporting queries (FOR SYSTEM_TIME lookups) that
-- need to see soft-deleted rows or historical versions the views' IsDeleted filter hides.  Skip this role -- and the
-- matching block in section 9 -- if nobody needs that today.
-- (The previous version of this block tested for a role named plc_read_role and created one named readOnlyRole, so
--  it created the role again on every run and failed on the second.  Both names now agree.)
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'readOnlyRole' AND type = 'R')
    CREATE ROLE [readOnlyRole];
GO


-- *** 4. logsData.DdlChange ***
-- The evidence, and append-only by intent.  Nothing in this script ever deletes from it or recreates it.
--
-- 4a. Legacy names.  Every block in 4a is a no-op on a fresh database and on one already migrated; each is guarded on
--     its own condition rather than on one test for the whole of 4a, for the reason spelled out in 4c -- this file has
--     no enclosing transaction, every GO commits its own batch, and a failure part-way through has to leave a state
--     the next run can finish from.
--
--     Until 2026-09-17 these tables were called z_ddl_change and z_ddl_object_state: snake_case, with a 'z_' prefix
--     that sorted them to the bottom of Object Explorer, from when this subsystem was a standalone script rather than
--     part of a template.  That is not a style question any more.  The convention gate -- .claude/hooks/validate-sql.py,
--     which cites this skill as its authority -- enforces PascalCase table names, the vw/usp/udf/tvf prefixes and
--     DF_<schema>_<table>_<field> constraint naming, and under the old names this file, the reference implementation
--     the gate points at, failed its own gate.  A rule the reference cannot pass is a rule that gets switched off.
--
--     Renaming is safe here in a way it would not be for an application table.  Nothing outside this file writes to
--     these two, the only documented read paths are the two views in logs and logs.uspDdlAuditVerify -- all recreated
--     below -- and the DDL trigger that writes them is recreated in section 13.  The names that leak outside the
--     subsystem are the views', and section 4a-4 makes the old ones stop working rather than quietly return stale
--     rows: a caller still on logs.z_ddl_change gets "invalid object name", not silence.
--
--     4a-1. A table still sitting in logs, from before the logsData/history split, so the view created in section 6
--           can take its name and no consumer has to change.  Type 'U' matches a user table only, so this is skipped
--           once the name in logs is the view.  ALTER SCHEMA TRANSFER keeps the data and the indexes; it DISCARDS
--           permissions on the object, which section 9 re-grants.  It has to happen before system versioning is
--           switched on -- a temporal table cannot be transferred.

IF OBJECT_ID(N'logs.z_ddl_change', N'U') IS NOT NULL
BEGIN
    ALTER SCHEMA logsData TRANSFER logs.z_ddl_change;
    PRINT N'Transferred logs.z_ddl_change to logsData.';
END
GO

-- 4a-2. The rename.  System versioning comes off first: SQL Server refuses sp_rename on a system-versioned table and
--       on its history table.  It is not switched back on here -- section 4e already does that, and its guard is
--       temporal_type <> 2, which is precisely the state this block leaves behind.  One place names the history
--       table, so the two cannot disagree.

IF OBJECT_ID (N'logsData.z_ddl_change', N'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.tables
                WHERE object_id = OBJECT_ID (N'logsData.z_ddl_change') AND temporal_type = 2)
BEGIN
    ALTER TABLE logsData.z_ddl_change SET (SYSTEM_VERSIONING = OFF);
    PRINT N'System versioning suspended on logsData.z_ddl_change for the rename.';
END
GO

IF OBJECT_ID (N'logsData.z_ddl_change', N'U') IS NOT NULL
   AND OBJECT_ID (N'logsData.DdlChange', N'U') IS NULL
BEGIN
    EXEC sys.sp_rename N'logsData.z_ddl_change', N'DdlChange';
    PRINT N'Renamed logsData.z_ddl_change to logsData.DdlChange.';
END
GO

IF OBJECT_ID (N'history.z_ddl_change', N'U') IS NOT NULL
   AND OBJECT_ID (N'history.DdlChange', N'U') IS NULL
BEGIN
    EXEC sys.sp_rename N'history.z_ddl_change', N'DdlChange';
    PRINT N'Renamed history.z_ddl_change to history.DdlChange.';
END
GO

-- 4a-3. The one outcome of 4a-2 that must not pass quietly.  If the base table was renamed and the history table was
--       not, section 4e switches versioning on against HISTORY_TABLE = history.DdlChange, finds no such table,
--       CREATES an empty one, orphans every historical row and reports success.  Losing the history of an audit trail
--       without being told is worse than a failed install, so the run stops here instead.  Versioning is off at this
--       point; a re-run picks up from 4a-2 once the history table has been renamed by hand.

IF OBJECT_ID (N'logsData.DdlChange', N'U') IS NOT NULL
   AND OBJECT_ID (N'history.z_ddl_change', N'U') IS NOT NULL
BEGIN
    DECLARE @OrphanedHistory nvarchar(2000) =
        N'logsData.DdlChange exists but history.z_ddl_change was not renamed. Rename it -- '
      + N'EXEC sys.sp_rename N''history.z_ddl_change'', N''DdlChange''; -- and run this file again. '
      + N'Section 4e must not be allowed to create a new history table: it would orphan the existing history. '
      + N'System versioning is currently OFF on logsData.DdlChange.';

    THROW 50000, @OrphanedHistory, 1;
END
GO

-- 4a-4. Names that sp_rename on the table does not touch: its constraints, its indexes, and the view over it.
--
--       The constraints are not cosmetic.  Section 4c's DbApplication repair names DF_logsData_DdlChange_DbApplication
--       explicitly, so left alone it would silently never apply; and the gate's constraint rule would be wrong about
--       the deployed database while passing on this file.  They are derived from the catalog and renamed by substring
--       rather than listed: the list then cannot fall out of step with section 4b, and a constraint somebody added by
--       hand is carried along with the rest.
--
--       The indexes matter for a sharper reason.  Section 4f guards each CREATE INDEX on the NEW name, so under the
--       old names it would not find them and would build a second copy of all three beside the originals -- doubling
--       the write cost of every DDL event, silently.  These are renamed one at a time because the old names were
--       idx_<table>_<purpose> and the convention is IX_<schema>_<Table>_<LeadingColumns>, which no substring
--       substitution produces.
--
--       The view is dropped rather than altered: CREATE OR ALTER in section 6 creates logs.DdlChange and cannot
--       remove logs.z_ddl_change, which from here on selects from a table that no longer exists.  DROP VIEW takes its
--       three INSTEAD OF triggers with it.  Nothing is dropped that holds a row.

IF OBJECT_ID (N'logsData.DdlChange', N'U') IS NOT NULL
BEGIN
    DECLARE @ConstraintRenames nvarchar(max);

    SELECT  @ConstraintRenames = STRING_AGG (CONVERT (nvarchar(max),
                    N'EXEC sys.sp_rename N''' + QUOTENAME (s.name) + N'.' + QUOTENAME (o.name)
                  + N''', N''' + REPLACE (o.name, N'z_ddl_change', N'DdlChange') + N''', ''OBJECT'';'),
                NCHAR (13) + NCHAR (10))
    FROM        sys.objects  AS o
    INNER JOIN  sys.schemas  AS s  ON s.schema_id = o.schema_id
    WHERE       o.parent_object_id = OBJECT_ID (N'logsData.DdlChange')
      AND       o.name LIKE N'%z[_]ddl[_]change%';

    IF @ConstraintRenames IS NOT NULL
    BEGIN
        EXEC sys.sp_executesql @ConstraintRenames;
        PRINT N'Renamed the constraints of logsData.DdlChange off the old table name.';
    END
END
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'idx_z_ddl_change_object')
    EXEC sys.sp_rename N'logsData.DdlChange.idx_z_ddl_change_object',
                       N'IX_logsData_DdlChange_Schema_Object', 'INDEX';

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'idx_z_ddl_change_original_login')
    EXEC sys.sp_rename N'logsData.DdlChange.idx_z_ddl_change_original_login',
                       N'IX_logsData_DdlChange_OriginalLogin', 'INDEX';

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'idx_z_ddl_change_event_time')
    EXEC sys.sp_rename N'logsData.DdlChange.idx_z_ddl_change_event_time',
                       N'IX_logsData_DdlChange_EventTimeServer', 'INDEX';
GO

IF OBJECT_ID (N'logs.z_ddl_change', N'V') IS NOT NULL
BEGIN
    DROP VIEW logs.z_ddl_change;
    PRINT N'Dropped the superseded view logs.z_ddl_change and its three INSTEAD OF triggers.';
END
GO

-- 4b. Create it when it is not there at all.  Column set matches what section 4c converges an older table onto, so a
--     fresh database and a migrated one end up the same shape, minus the two retired hash columns that a migrated
--     table keeps and this one never gets.

IF OBJECT_ID(N'logsData.DdlChange', N'U') IS NULL
BEGIN
    CREATE TABLE logsData.DdlChange
    (
    ChangeId                bigint          identity (1,1)  not null,

    /* event facts, taken from EVENTDATA() */
    EventTimeServer         datetime2(3)                    null,       -- server local time, as reported by the event
    EventType               nvarchar(128)                   null,
    ObjectType              nvarchar(128)                   null,
    SchemaName              sysname                         null,
    ObjectName              sysname                         null,
    CommandText             nvarchar(max)                   null,       -- the statement that fired the trigger
    Spid                    int                             null,       -- from the event payload, not @@SPID
    EventLoginName          sysname                         null,       -- server-level identity, from the event
    EventDatabaseUser       sysname                         null,       -- database-level identity, from the event
    EventXml                xml                             null,       -- full payload, in case a field is needed later

    /* object definitions */
    DefinitionKind          varchar(20)     not null        constraint DF_logsData_DdlChange_DefinitionKind default ('NONE'),
    PriorDefinition         nvarchar(max)                   null,       -- as it stood immediately before this event
    NewDefinition           nvarchar(max)                   null,       -- as it stood immediately after this event
    DefinitionChanged       bit                             null,

    /* session facts, captured independently of the event payload.  Legacy names; see the header note on overlap. */
    RecordedUtc             datetime2(3)    not null        constraint DF_logsData_DdlChange_RecordedUtc   default (sysutcdatetime ()),
    OriginalLogin           sysname         not null        constraint DF_logsData_DdlChange_OriginalLogin default (original_login ()),
    SessionLogin            sysname         not null        constraint DF_logsData_DdlChange_SessionLogin  default (isnull (suser_sname (), N'')),
    ProgramName             nvarchar(128)   not null        constraint DF_logsData_DdlChange_ProgramName   default (isnull (app_name (), N'')),

    /* Standard audit block.  Soft delete only; there is no hard delete anywhere in this database.
       Convention: DF_<schema>_<tableName>_<fieldName>.  Default constraint names are unique per database, so these
       carry this table's real schema and name and cannot be copied to another table.
       The audit*By columns are nvarchar(255) -- comfortably wider than the sysname (nvarchar(128)) that
       ORIGINAL_LOGIN() returns.  Anything narrower makes the default itself raise a truncation error, and 255 is
       also what the INSTEAD OF triggers cast SESSION_CONTEXT('AppUser') to.
       Every session-function default on a NOT NULL column is wrapped in ISNULL.  Not defensive habit: APP_NAME()
       and HOST_NAME() are nullable, and a NULL arriving at a NOT NULL column inside record_db_changes fails the
       audit write, which -- fail-closed -- fails the DDL statement that triggered it. */
    IsDeleted               bit             not null        constraint DF_logsData_DdlChange_IsDeleted             default (0),
    auditDeletedBy          nvarchar(255)   not null        constraint DF_logsData_DdlChange_auditDeletedBy        default (original_login ()),
    auditDeletedDateUtc     datetime2(3)    not null        constraint DF_logsData_DdlChange_auditDeletedDateUtc   default (sysutcdatetime ()),
    auditCreatedBy          nvarchar(255)   not null        constraint DF_logsData_DdlChange_auditCreatedBy        default (original_login ()),
    auditCreatedDateUtc     datetime2(3)    not null        constraint DF_logsData_DdlChange_auditCreatedDateUtc   default (sysutcdatetime ()),
    auditModifiedBy         nvarchar(255)   not null        constraint DF_logsData_DdlChange_auditModifiedBy       default (original_login ()),
    auditModifiedDateUtc    datetime2(3)    not null        constraint DF_logsData_DdlChange_auditModifiedDateUtc  default (sysutcdatetime ()),
    DbApplication           nvarchar(255)   not null        constraint DF_logsData_DdlChange_DbApplication         default (isnull (app_name (), N'')),
    HostName                nvarchar(255)   not null        constraint DF_logsData_DdlChange_HostName              default (isnull (host_name (), N'')),

    /* Session auditing.  For a deep-dive investigation, query the history table for every session that touched the
       row; for everything else the latest session values are enough. */
    AppSessionId            nvarchar(128)                   null,
    SqlSpid                 smallint        not null        constraint DF_logsData_DdlChange_SqlSpid default (@@SPID),

    /* System time is always UTC.  HIDDEN keeps these out of SELECT *, so a consumer written against the old table is
       unaffected; name them explicitly, or query history.DdlChange, to see them. */
    SysStartTime            datetime2(3)    generated always as row start hidden not null,
    SysEndTime              datetime2(3)    generated always as row end   hidden not null,
    period for system_time (SysStartTime, SysEndTime),

    constraint PK_logsData_DdlChange primary key clustered (ChangeId asc)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.DdlChange, DATA_CONSISTENCY_CHECK = ON));

    PRINT N'Created logsData.DdlChange (system-versioned, history.DdlChange).';
END
GO

-- 4c. Additive column work for a table that already existed.  On a fresh database every block here is a no-op --
--     section 4b already created the column -- so do not fold these back into 4b: a populated database never runs it.
--
--     EVERY COLUMN IS GUARDED ON ITS OWN NAME.  The earlier version guarded ten ADDs on a single test for IsDeleted,
--     reasoning that a table either has the standard block or it does not.  That holds only if the ALTER is atomic
--     with everything downstream of it, and it is not: this file has no enclosing transaction, so every GO commits
--     its own batch.  A failure anywhere after the ALTER -- a lock timeout, a permission, a later statement -- then
--     left a table that HAD IsDeleted and was missing the rest, and every subsequent run skipped the whole block
--     because IsDeleted was present.  The table could never be brought forward by the tool whose entire purpose is
--     to bring it forward, and the repair was by hand.  Per-column guards are what make "additive" actually converge.
--
--     HostName is in this list.  It was not, and it is the one column logs.DdlChange projects that 4c never added,
--     so a database whose event table predated it got as far as CREATE OR ALTER VIEW and failed with
--     "Invalid column name 'HostName'" -- with the DDL trigger already gone under the old section 3.  The widening
--     block further down handles the other case, where the column exists but is narrower than the standard.

IF COL_LENGTH (N'logsData.DdlChange', N'IsDeleted') IS NULL
    ALTER TABLE logsData.DdlChange ADD IsDeleted bit not null
        constraint DF_logsData_DdlChange_IsDeleted default (0);

IF COL_LENGTH (N'logsData.DdlChange', N'auditDeletedBy') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditDeletedBy nvarchar(255) not null
        constraint DF_logsData_DdlChange_auditDeletedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlChange', N'auditDeletedDateUtc') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditDeletedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlChange_auditDeletedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlChange', N'auditCreatedBy') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditCreatedBy nvarchar(255) not null
        constraint DF_logsData_DdlChange_auditCreatedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlChange', N'auditCreatedDateUtc') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditCreatedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlChange_auditCreatedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlChange', N'auditModifiedBy') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditModifiedBy nvarchar(255) not null
        constraint DF_logsData_DdlChange_auditModifiedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlChange', N'auditModifiedDateUtc') IS NULL
    ALTER TABLE logsData.DdlChange ADD auditModifiedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlChange_auditModifiedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlChange', N'DbApplication') IS NULL
    ALTER TABLE logsData.DdlChange ADD DbApplication nvarchar(255) not null
        constraint DF_logsData_DdlChange_DbApplication default (isnull (app_name (), N''));

IF COL_LENGTH (N'logsData.DdlChange', N'HostName') IS NULL
    ALTER TABLE logsData.DdlChange ADD HostName nvarchar(255) not null
        constraint DF_logsData_DdlChange_HostName default (isnull (host_name (), N''));

IF COL_LENGTH (N'logsData.DdlChange', N'AppSessionId') IS NULL
    ALTER TABLE logsData.DdlChange ADD AppSessionId nvarchar(128) null;

IF COL_LENGTH (N'logsData.DdlChange', N'SqlSpid') IS NULL
    ALTER TABLE logsData.DdlChange ADD SqlSpid smallint not null
        constraint DF_logsData_DdlChange_SqlSpid default (@@SPID);
GO

-- The DbApplication default on a database that already has the unwrapped form.  APP_NAME() is the only one of the
-- three session-function defaults on a NOT NULL column that was not wrapped in ISNULL; if it ever returns NULL the
-- insert violates the constraint, record_db_changes catches it, and because it fails closed EVERY DDL statement in
-- the database fails until someone works out why.  Every INSTEAD OF trigger in this file already writes
-- ISNULL (APP_NAME (), N'') to the same column, so the bare default was an oversight rather than a decision.
-- Replacing a default constraint is metadata only: no row is read, rewritten or lost.
IF EXISTS (SELECT 1 FROM sys.default_constraints
            WHERE name = N'DF_logsData_DdlChange_DbApplication'
              AND definition NOT LIKE N'%isnull%')
BEGIN
    ALTER TABLE logsData.DdlChange DROP CONSTRAINT DF_logsData_DdlChange_DbApplication;
    ALTER TABLE logsData.DdlChange ADD CONSTRAINT DF_logsData_DdlChange_DbApplication
        DEFAULT (isnull (app_name (), N'')) FOR DbApplication;
    PRINT N'Wrapped DF_logsData_DdlChange_DbApplication in ISNULL.';
END
GO

-- Existing rows: the audit block defaults fire for them, so auditCreatedDateUtc says "when this script ran" rather
-- than when the row was written.  RecordedUtc holds the truth, so copy it across once.  Guarded on a value that only
-- the ALTER above can have produced, so this converges instead of re-applying.
IF EXISTS (SELECT 1 FROM logsData.DdlChange WHERE auditCreatedDateUtc <> RecordedUtc)
BEGIN
    UPDATE logsData.DdlChange
       SET auditCreatedBy       = OriginalLogin,
           auditCreatedDateUtc  = RecordedUtc,
           auditModifiedBy      = OriginalLogin,
           auditModifiedDateUtc = RecordedUtc,
           auditDeletedBy       = OriginalLogin,
           auditDeletedDateUtc  = RecordedUtc,
           DbApplication        = ProgramName
     WHERE auditCreatedDateUtc <> RecordedUtc;

    PRINT N'Back-filled the audit block on ' + CONVERT (nvarchar(20), @@ROWCOUNT) + N' pre-existing DdlChange rows.';
END
GO

-- HostName predates the standard block at nvarchar(128).  Widening is metadata-only and loses nothing.
-- max_length is in bytes, so nvarchar(255) is 510.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'HostName' AND max_length < 510)
    ALTER TABLE logsData.DdlChange ALTER COLUMN HostName nvarchar(255) NOT NULL;
GO

-- The retired hash columns.  NOT dropped -- no destructive DDL here -- but no writer names them any more, so neither
-- can stay NOT NULL or every insert fails.  Made NULLable before system versioning goes on.
--
-- BOTH columns, not just RowHash.  The argument is identical for PrevRowHash: section 13's trigger does not name it,
-- neither does the INSTEAD OF INSERT trigger in section 8, and a NOT NULL column with no default that nobody writes
-- fails every INSERT into the event log.  With @FailClosed = 1 in the trigger that does not merely stop auditing, it
-- blocks ALL DDL in the database until someone finds it.  Only RowHash was repaired here, on the assumption that
-- PrevRowHash was already NULLable because the first row of a chain has no predecessor -- true of the original design,
-- but not something this script can verify, since these columns exist only on databases that were migrated and it
-- never creates them.  The guard costs nothing where the column is absent or already NULLable.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'RowHash' AND is_nullable = 0)
BEGIN
    ALTER TABLE logsData.DdlChange ALTER COLUMN RowHash binary(32) NULL;
    PRINT N'logsData.DdlChange.RowHash is now NULLable; the hash chain is retired. Existing values are untouched.';
END
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'PrevRowHash' AND is_nullable = 0)
BEGIN
    ALTER TABLE logsData.DdlChange ALTER COLUMN PrevRowHash binary(32) NULL;
    PRINT N'logsData.DdlChange.PrevRowHash is now NULLable; the hash chain is retired. Existing values are untouched.';
END
GO

-- 4d. Period columns.  They have to be added together with the PERIOD in one statement, and on a populated table both
--     need a default: SysStartTime any past instant, SysEndTime the maximum for the type, which is what
--     DATA_CONSISTENCY_CHECK then verifies.  For datetime2(3) that maximum is 9999-12-31 23:59:59.999.

IF NOT EXISTS (SELECT 1 FROM sys.periods WHERE object_id = OBJECT_ID (N'logsData.DdlChange'))
BEGIN
    ALTER TABLE logsData.DdlChange ADD
        SysStartTime datetime2(3) generated always as row start hidden not null
            constraint DF_logsData_DdlChange_SysStartTime default ('1900-01-01 00:00:00.000'),
        SysEndTime   datetime2(3) generated always as row end   hidden not null
            constraint DF_logsData_DdlChange_SysEndTime   default ('9999-12-31 23:59:59.999'),
        period for system_time (SysStartTime, SysEndTime);

    PRINT N'Added the SYSTEM_TIME period to logsData.DdlChange.';
END
GO

-- 4e. System versioning.  temporal_type 2 is a system-versioned table.  Retention is left at the default INFINITE:
--     this is an audit trail, and a retention period would silently delete the oldest evidence first.
IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND temporal_type <> 2)
BEGIN
    ALTER TABLE logsData.DdlChange
        SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.DdlChange, DATA_CONSISTENCY_CHECK = ON));

    PRINT N'System versioning enabled on logsData.DdlChange -> history.DdlChange.';
END
GO

-- 4f. Indexes.  Guarded by object_id and by name, so an index that already exists is left alone.  The three that a
--     migrated database carries under the old idx_z_ddl_change_* names were renamed to these names in 4a-4, which is
--     what stops this block from building a second copy of each beside them.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'IX_logsData_DdlChange_Schema_Object')
    CREATE NONCLUSTERED INDEX IX_logsData_DdlChange_Schema_Object
        ON logsData.DdlChange (SchemaName asc, ObjectName asc, ChangeId desc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'IX_logsData_DdlChange_OriginalLogin')
    CREATE NONCLUSTERED INDEX IX_logsData_DdlChange_OriginalLogin
        ON logsData.DdlChange (OriginalLogin asc, ChangeId desc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID (N'logsData.DdlChange') AND name = N'IX_logsData_DdlChange_EventTimeServer')
    CREATE NONCLUSTERED INDEX IX_logsData_DdlChange_EventTimeServer
        ON logsData.DdlChange (EventTimeServer asc);
GO


-- *** 5. logsData.DdlObjectState ***
-- Current definition of each schema-scoped object.  The trigger reads the row to obtain the "before" image, then
-- overwrites it with the "after" image.  Now that it is system-versioned, every version it has ever held is in
-- history.DdlObjectState and can be read with FOR SYSTEM_TIME -- so this table is no longer merely working
-- storage, it is a second, independent record of every definition.
--
-- 5a. Legacy names.  Same five steps as 4a, same reasoning, same guards, for the table that was z_ddl_object_state.
--     Read 4a for why any of this is here; only the differences are commented below.

IF OBJECT_ID(N'logs.z_ddl_object_state', N'U') IS NOT NULL
BEGIN
    ALTER SCHEMA logsData TRANSFER logs.z_ddl_object_state;
    PRINT N'Transferred logs.z_ddl_object_state to logsData.';
END
GO

IF OBJECT_ID (N'logsData.z_ddl_object_state', N'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.tables
                WHERE object_id = OBJECT_ID (N'logsData.z_ddl_object_state') AND temporal_type = 2)
BEGIN
    ALTER TABLE logsData.z_ddl_object_state SET (SYSTEM_VERSIONING = OFF);
    PRINT N'System versioning suspended on logsData.z_ddl_object_state for the rename.';
END
GO

IF OBJECT_ID (N'logsData.z_ddl_object_state', N'U') IS NOT NULL
   AND OBJECT_ID (N'logsData.DdlObjectState', N'U') IS NULL
BEGIN
    EXEC sys.sp_rename N'logsData.z_ddl_object_state', N'DdlObjectState';
    PRINT N'Renamed logsData.z_ddl_object_state to logsData.DdlObjectState.';
END
GO

IF OBJECT_ID (N'history.z_ddl_object_state', N'U') IS NOT NULL
   AND OBJECT_ID (N'history.DdlObjectState', N'U') IS NULL
BEGIN
    EXEC sys.sp_rename N'history.z_ddl_object_state', N'DdlObjectState';
    PRINT N'Renamed history.z_ddl_object_state to history.DdlObjectState.';
END
GO

-- Section 5e is the re-enable, and it would create an empty history table over the top of the real one.  See 4a-3.
IF OBJECT_ID (N'logsData.DdlObjectState', N'U') IS NOT NULL
   AND OBJECT_ID (N'history.z_ddl_object_state', N'U') IS NOT NULL
BEGIN
    DECLARE @OrphanedStateHistory nvarchar(2000) =
        N'logsData.DdlObjectState exists but history.z_ddl_object_state was not renamed. Rename it -- '
      + N'EXEC sys.sp_rename N''history.z_ddl_object_state'', N''DdlObjectState''; -- and run this file again. '
      + N'Section 5e must not be allowed to create a new history table: it would orphan the existing history. '
      + N'System versioning is currently OFF on logsData.DdlObjectState.';

    THROW 50000, @OrphanedStateHistory, 1;
END
GO

-- No index block to match 4a-4: this table's only index is its primary key, which the constraint rename below covers.
IF OBJECT_ID (N'logsData.DdlObjectState', N'U') IS NOT NULL
BEGIN
    DECLARE @StateConstraintRenames nvarchar(max);

    SELECT  @StateConstraintRenames = STRING_AGG (CONVERT (nvarchar(max),
                    N'EXEC sys.sp_rename N''' + QUOTENAME (s.name) + N'.' + QUOTENAME (o.name)
                  + N''', N''' + REPLACE (o.name, N'z_ddl_object_state', N'DdlObjectState') + N''', ''OBJECT'';'),
                NCHAR (13) + NCHAR (10))
    FROM        sys.objects  AS o
    INNER JOIN  sys.schemas  AS s  ON s.schema_id = o.schema_id
    WHERE       o.parent_object_id = OBJECT_ID (N'logsData.DdlObjectState')
      AND       o.name LIKE N'%z[_]ddl[_]object[_]state%';

    IF @StateConstraintRenames IS NOT NULL
    BEGIN
        EXEC sys.sp_executesql @StateConstraintRenames;
        PRINT N'Renamed the constraints of logsData.DdlObjectState off the old table name.';
    END
END
GO

IF OBJECT_ID (N'logs.z_ddl_object_state', N'V') IS NOT NULL
BEGIN
    DROP VIEW logs.z_ddl_object_state;
    PRINT N'Dropped the superseded view logs.z_ddl_object_state and its three INSTEAD OF triggers.';
END
GO

-- 5b. Create it when missing.

IF OBJECT_ID(N'logsData.DdlObjectState', N'U') IS NULL
BEGIN
    CREATE TABLE logsData.DdlObjectState
    (
    SchemaName              sysname         not null,
    ObjectName              sysname         not null,
    ObjectType              nvarchar(128)                   null,
    DefinitionKind          varchar(20)     not null        constraint DF_logsData_DdlObjectState_DefinitionKind default ('NONE'),
    Definition              nvarchar(max)                   null,
    IsDropped               bit             not null        constraint DF_logsData_DdlObjectState_IsDropped      default (0),
    LastChangeId            bigint                          null,
    UpdatedUtc              datetime2(3)    not null        constraint DF_logsData_DdlObjectState_UpdatedUtc     default (sysutcdatetime ()),

    /* Standard audit block.  Convention: DF_<schema>_<tableName>_<fieldName>. */
    IsDeleted               bit             not null        constraint DF_logsData_DdlObjectState_IsDeleted            default (0),
    auditDeletedBy          nvarchar(255)   not null        constraint DF_logsData_DdlObjectState_auditDeletedBy       default (original_login ()),
    auditDeletedDateUtc     datetime2(3)    not null        constraint DF_logsData_DdlObjectState_auditDeletedDateUtc  default (sysutcdatetime ()),
    auditCreatedBy          nvarchar(255)   not null        constraint DF_logsData_DdlObjectState_auditCreatedBy       default (original_login ()),
    auditCreatedDateUtc     datetime2(3)    not null        constraint DF_logsData_DdlObjectState_auditCreatedDateUtc  default (sysutcdatetime ()),
    auditModifiedBy         nvarchar(255)   not null        constraint DF_logsData_DdlObjectState_auditModifiedBy      default (original_login ()),
    auditModifiedDateUtc    datetime2(3)    not null        constraint DF_logsData_DdlObjectState_auditModifiedDateUtc default (sysutcdatetime ()),
    DbApplication           nvarchar(255)   not null        constraint DF_logsData_DdlObjectState_DbApplication        default (isnull (app_name (), N'')),
    HostName                nvarchar(255)   not null        constraint DF_logsData_DdlObjectState_HostName             default (isnull (host_name (), N'')),

    AppSessionId            nvarchar(128)                   null,
    SqlSpid                 smallint        not null        constraint DF_logsData_DdlObjectState_SqlSpid default (@@SPID),

    /* System time is always UTC. */
    SysStartTime            datetime2(3)    generated always as row start hidden not null,
    SysEndTime              datetime2(3)    generated always as row end   hidden not null,
    period for system_time (SysStartTime, SysEndTime),

    constraint PK_logsData_DdlObjectState primary key clustered (SchemaName asc, ObjectName asc)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.DdlObjectState, DATA_CONSISTENCY_CHECK = ON));

    PRINT N'Created logsData.DdlObjectState (system-versioned, history.DdlObjectState).';
END
GO

-- 5c. Additive column work for a table that already existed.  Per-column guards, for the reason given in 4c.

IF COL_LENGTH (N'logsData.DdlObjectState', N'IsDeleted') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD IsDeleted bit not null
        constraint DF_logsData_DdlObjectState_IsDeleted default (0);

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditDeletedBy') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditDeletedBy nvarchar(255) not null
        constraint DF_logsData_DdlObjectState_auditDeletedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditDeletedDateUtc') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditDeletedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlObjectState_auditDeletedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditCreatedBy') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditCreatedBy nvarchar(255) not null
        constraint DF_logsData_DdlObjectState_auditCreatedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditCreatedDateUtc') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditCreatedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlObjectState_auditCreatedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditModifiedBy') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditModifiedBy nvarchar(255) not null
        constraint DF_logsData_DdlObjectState_auditModifiedBy default (original_login ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'auditModifiedDateUtc') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD auditModifiedDateUtc datetime2(3) not null
        constraint DF_logsData_DdlObjectState_auditModifiedDateUtc default (sysutcdatetime ());

IF COL_LENGTH (N'logsData.DdlObjectState', N'DbApplication') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD DbApplication nvarchar(255) not null
        constraint DF_logsData_DdlObjectState_DbApplication default (isnull (app_name (), N''));

IF COL_LENGTH (N'logsData.DdlObjectState', N'HostName') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD HostName nvarchar(255) not null
        constraint DF_logsData_DdlObjectState_HostName default (isnull (host_name (), N''));

IF COL_LENGTH (N'logsData.DdlObjectState', N'AppSessionId') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD AppSessionId nvarchar(128) null;

IF COL_LENGTH (N'logsData.DdlObjectState', N'SqlSpid') IS NULL
    ALTER TABLE logsData.DdlObjectState ADD SqlSpid smallint not null
        constraint DF_logsData_DdlObjectState_SqlSpid default (@@SPID);
GO

-- Same DbApplication default repair as on DdlChange; see the comment there.
IF EXISTS (SELECT 1 FROM sys.default_constraints
            WHERE name = N'DF_logsData_DdlObjectState_DbApplication'
              AND definition NOT LIKE N'%isnull%')
BEGIN
    ALTER TABLE logsData.DdlObjectState DROP CONSTRAINT DF_logsData_DdlObjectState_DbApplication;
    ALTER TABLE logsData.DdlObjectState ADD CONSTRAINT DF_logsData_DdlObjectState_DbApplication
        DEFAULT (isnull (app_name (), N'')) FOR DbApplication;
    PRINT N'Wrapped DF_logsData_DdlObjectState_DbApplication in ISNULL.';
END
GO

-- Same back-fill as on DdlChange: UpdatedUtc knows when the row last changed, the freshly-defaulted audit block
-- does not.
IF EXISTS (SELECT 1 FROM logsData.DdlObjectState WHERE auditModifiedDateUtc <> UpdatedUtc)
BEGIN
    UPDATE logsData.DdlObjectState
       SET auditCreatedDateUtc  = UpdatedUtc,
           auditModifiedDateUtc = UpdatedUtc,
           auditDeletedDateUtc  = UpdatedUtc
     WHERE auditModifiedDateUtc <> UpdatedUtc;

    PRINT N'Back-filled the audit block on ' + CONVERT (nvarchar(20), @@ROWCOUNT) + N' pre-existing DdlObjectState rows.';
END
GO

-- 5d. Period columns.

IF NOT EXISTS (SELECT 1 FROM sys.periods WHERE object_id = OBJECT_ID (N'logsData.DdlObjectState'))
BEGIN
    ALTER TABLE logsData.DdlObjectState ADD
        SysStartTime datetime2(3) generated always as row start hidden not null
            constraint DF_logsData_DdlObjectState_SysStartTime default ('1900-01-01 00:00:00.000'),
        SysEndTime   datetime2(3) generated always as row end   hidden not null
            constraint DF_logsData_DdlObjectState_SysEndTime   default ('9999-12-31 23:59:59.999'),
        period for system_time (SysStartTime, SysEndTime);

    PRINT N'Added the SYSTEM_TIME period to logsData.DdlObjectState.';
END
GO

-- 5e. System versioning.

IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID (N'logsData.DdlObjectState') AND temporal_type <> 2)
BEGIN
    ALTER TABLE logsData.DdlObjectState
        SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.DdlObjectState, DATA_CONSISTENCY_CHECK = ON));

    PRINT N'System versioning enabled on logsData.DdlObjectState -> history.DdlObjectState.';
END
GO


-- *** 6. Retire the hash chain ***
-- Modules only, so DROP here destroys no data.  Order matters: z_ddl_change_verify references z_ddl_row_hash, and
-- z_ddl_row_hash is WITH SCHEMABINDING, so the procedure goes first.
-- Keep a copy of the old function text (it is in logsData.DdlChange.PriorDefinition, recorded by the trigger the
-- last time it changed) if you ever need to re-verify rows written before this script ran.

IF OBJECT_ID (N'logs.z_ddl_change_verify', N'P') IS NOT NULL
BEGIN
    DROP PROCEDURE logs.z_ddl_change_verify;
    PRINT N'Dropped logs.z_ddl_change_verify; superseded by logs.uspDdlAuditVerify.';
END
GO

IF OBJECT_ID (N'logs.z_ddl_row_hash', N'FN') IS NOT NULL
BEGIN
    DROP FUNCTION logs.z_ddl_row_hash;
    PRINT N'Dropped logs.z_ddl_row_hash; the hash chain is superseded by system versioning.';
END
GO

-- The other half of the 2026-09-17 rename described in 4a: the function and the procedure kept their bodies and
-- changed only their names, so CREATE OR ALTER in sections 7 and 10 creates the new ones and leaves these behind.
-- The procedure goes first for the same reason as above -- it calls the function.  Both are modules; no data is here.
IF OBJECT_ID (N'logs.z_ddl_audit_verify', N'P') IS NOT NULL
BEGIN
    DROP PROCEDURE logs.z_ddl_audit_verify;
    PRINT N'Dropped logs.z_ddl_audit_verify; renamed to logs.uspDdlAuditVerify.';
END
GO

IF OBJECT_ID (N'logs.z_table_shape', N'FN') IS NOT NULL
BEGIN
    DROP FUNCTION logs.z_table_shape;
    PRINT N'Dropped logs.z_table_shape; renamed to logs.udfTableShape.';
END
GO


-- *** 7. Helper function ***

/***********************************************************************************************************************
ObjectName:   logs.udfTableShape
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Renders a table's columns and index definitions as newline-delimited text, so that successive versions can be compared
with a plain string comparison.  Returns NULL when the object does not exist or is not a table.  Covers columns, column
defaults and indexes only; it is not a complete scripting of the table.

========================================================================================================================
Requirements and Key Dependencies:

sys.columns, sys.types, sys.default_constraints, sys.indexes, sys.index_columns.  Callers need VIEW DEFINITION for the
catalog to be populated for objects they do not own.

========================================================================================================================
Notes:

Two constraints shape the code below.  STRING_AGG rejects an argument containing an aggregate or a subquery, so each
line is built in a derived table and the aggregate then operates on a plain column.  And the sysname columns of the
system catalog carry the instance metadata collation, which need not match this database's collation, so every
catalog-sourced string is forced to DATABASE_DEFAULT before it meets a literal.

The period columns of a temporal table appear here like any other column, so switching a table to system versioning
shows up as a definition change -- which is correct: it is one.

========================================================================================================================
Example Usage and Performance:

select logs.udfTableShape (object_id (N'logsData.DdlChange'));

Catalog reads only.  Called once per DDL event by record_db_changes.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Header block added.  Body unchanged by the temporal conversion.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER FUNCTION logs.udfTableShape (@ObjectId int)
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @Crlf       nchar(2) = NCHAR(13) + NCHAR(10);
    DECLARE @Columns    nvarchar(max);
    DECLARE @Indexes    nvarchar(max);

    IF @ObjectId IS NULL OR NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id = @ObjectId)
        RETURN NULL;

    SELECT @Columns = STRING_AGG (CONVERT (nvarchar(max), ColumnLines.Line), @Crlf)
                            WITHIN GROUP (ORDER BY ColumnLines.column_id)
    FROM
    (
        SELECT      c.column_id,
                    N'COLUMN|' + CONVERT (nvarchar(10), c.column_id)
                  + N'|' + c.name COLLATE DATABASE_DEFAULT
                  + N'|' + t.name COLLATE DATABASE_DEFAULT
                  + N'|len=' + CONVERT (nvarchar(10), c.max_length)
                  + N'|prec=' + CONVERT (nvarchar(10), c.precision)
                  + N'|scale=' + CONVERT (nvarchar(10), c.scale)
                  + N'|null=' + CONVERT (nchar(1), c.is_nullable)
                  + N'|identity=' + CONVERT (nchar(1), c.is_identity)
                  + N'|computed=' + CONVERT (nchar(1), c.is_computed)
                  + N'|collation=' + ISNULL (c.collation_name COLLATE DATABASE_DEFAULT, N'')
                  + N'|default=' + ISNULL (dc.definition COLLATE DATABASE_DEFAULT, N'') AS Line
        FROM        sys.columns c
        INNER JOIN  sys.types   t   ON  t.user_type_id = c.user_type_id
        LEFT JOIN   sys.default_constraints dc
                                    ON  dc.parent_object_id = c.object_id
                                    AND dc.parent_column_id = c.column_id
        WHERE       c.object_id = @ObjectId
    ) AS ColumnLines;

    SELECT @Indexes = STRING_AGG (CONVERT (nvarchar(max), IndexLines.Line), @Crlf)
                            WITHIN GROUP (ORDER BY IndexLines.IndexName)
    FROM
    (
        SELECT      i.name COLLATE DATABASE_DEFAULT AS IndexName,
                    N'INDEX|' + i.name COLLATE DATABASE_DEFAULT
                  + N'|type=' + i.type_desc COLLATE DATABASE_DEFAULT
                  + N'|unique=' + CONVERT (nchar(1), i.is_unique)
                  + N'|pk=' + CONVERT (nchar(1), i.is_primary_key)
                  + N'|keys=' + ISNULL (KeyColumns.Cols, N'')
                  + N'|included=' + ISNULL (IncludedColumns.Cols, N'')
                  + N'|filter=' + ISNULL (i.filter_definition COLLATE DATABASE_DEFAULT, N'') AS Line
        FROM        sys.indexes i
        OUTER APPLY
        (
            SELECT      STRING_AGG (CONVERT (nvarchar(max), kc.name COLLATE DATABASE_DEFAULT
                                  + CASE WHEN ic.is_descending_key = 1 THEN N' desc' ELSE N' asc' END), N',')
                                WITHIN GROUP (ORDER BY ic.key_ordinal) AS Cols
            FROM        sys.index_columns ic
            INNER JOIN  sys.columns kc  ON  kc.object_id = ic.object_id
                                        AND kc.column_id = ic.column_id
            WHERE       ic.object_id = i.object_id
              AND       ic.index_id  = i.index_id
              AND       ic.is_included_column = 0
        ) AS KeyColumns
        OUTER APPLY
        (
            SELECT      STRING_AGG (CONVERT (nvarchar(max), nc.name COLLATE DATABASE_DEFAULT), N',')
                                WITHIN GROUP (ORDER BY nc.name) AS Cols
            FROM        sys.index_columns ic
            INNER JOIN  sys.columns nc  ON  nc.object_id = ic.object_id
                                        AND nc.column_id = ic.column_id
            WHERE       ic.object_id = i.object_id
              AND       ic.index_id  = i.index_id
              AND       ic.is_included_column = 1
        ) AS IncludedColumns
        WHERE       i.object_id = @ObjectId
          AND       i.name IS NOT NULL
    ) AS IndexLines;

    RETURN ISNULL (@Columns, N'') + CASE WHEN @Indexes IS NULL THEN N'' ELSE @Crlf + @Indexes END;
END
GO


/***********************************************************************************************************************
   *** 8. The view wrapper over logsData.DdlChange, and its INSTEAD OF triggers ***

A system-versioned table cannot carry an INSTEAD OF trigger -- only AFTER triggers -- so the view is the only place the
soft-delete and audit-column semantics can live.  It also takes the name the base table used to have, so every existing
query against logs.DdlChange keeps working.

What the triggers guarantee
---------------------------
INSERT   auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc, auditDeletedBy,
         auditDeletedDateUtc and DbApplication are CALLER-OVERRIDABLE.  An explicit value is kept; the default is
         applied only when the value is NULL or empty.  This is deliberate and it is what makes a migration honest:
         overwriting the original audit trail while loading history strips the data of its context, breaks reporting
         built on it, and in a regulated system is a finding.  The cost is stated plainly -- the audit trail is NOT
         tamper-proof against a principal holding INSERT on this view.  HostName, AppSessionId and SqlSpid are NOT
         overridable; they always describe the session that ran the statement.

         SessionLogin is overridable too, and behaves slightly differently from the audit columns: only a NULL is
         replaced (with SUSER_SNAME ()), so an explicit empty string is kept as an empty string.  That is on purpose --
         empty is the value record_db_changes itself writes, because SUSER_SNAME () under EXECUTE AS reports the
         trigger's own principal rather than anyone real.  A backfill can therefore say "not known" and mean it.

UPDATE   No audit column is caller-overridable EXCEPT auditModifiedBy.  Everything else is recomputed from the session.
         auditCreatedBy and auditCreatedDateUtc are not in the SET list at all, so an UPDATE cannot rewrite who
         created a row.  SessionLogin is in the SET list and follows the INSERT rule -- an explicit value wins, NULL
         falls back to SUSER_SNAME () -- so it is not an audit column in the protected sense.

DELETE   Soft delete only.  IsDeleted goes to 1 and the row leaves the view; the row itself, and every version of it,
         stays in logsData/history for good.

ChangeId is IDENTITY and immutable: the INSERT trigger ignores any value supplied for it, and the UPDATE trigger
rejects a statement that tries to change it rather than silently doing nothing.
***********************************************************************************************************************/

/***********************************************************************************************************************
ObjectName:   logs.DdlChange
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Active rows of the DDL event log.  One row per database-level DDL event, with the statement that was run, who ran it,
and the object definition immediately before and after.  This is the read and write path for everything except the
record_db_changes trigger itself; it applies the IsDeleted = 0 filter and carries the INSTEAD OF triggers that own the
audit columns.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlChange (system-versioned).  Schemas logs and logsData must share an owner or the INSTEAD OF triggers
cannot write to the base table -- see section 2.

========================================================================================================================
Notes:

Not SCHEMABINDING, deliberately: binding would block the additive ALTER TABLE blocks in section 4 on the next release.

The period columns are HIDDEN on the base table and are not projected here.  To see versions, read
logsData.DdlChange FOR SYSTEM_TIME (needs logsAuditReader; readOnlyRole is denied on logsData).

Omit a column from an INSERT to have the trigger default it.  Passing an explicit NULL to a NOT NULL column is
rejected by the view's own metadata before the trigger runs -- that is the view reporting the base table's
nullability, not the trigger refusing the value.

========================================================================================================================
Example Usage and Performance:

-- every change to one procedure, newest first, with the version that was in place beforehand
select      ChangeId, EventTimeServer, EventType, OriginalLogin, HostName, DbApplication, CommandText, PriorDefinition
from        logs.DdlChange
where       SchemaName = 'util'
  and       ObjectName = 'uspSetObjectDescription'
order by    ChangeId desc;

-- recover the definition that was in place before a specific change
select PriorDefinition from logs.DdlChange where ChangeId = 1234;

-- capture identities from a multi-row insert through the view
create table #ReturnedIdentity (InsertedId bigint not null);
insert logs.DdlChange (EventType, SchemaName, ObjectName, CommandText) values (N'BACKFILL', N'dbo', N'X', N'...');
select * from #ReturnedIdentity;

Supported by IX_logsData_DdlChange_Schema_Object, IX_logsData_DdlChange_OriginalLogin and IX_logsData_DdlChange_EventTimeServer on the base
table.  The IsDeleted = 0 filter is not indexed: soft-deleted event rows are expected to be nonexistent, and
logs.uspDdlAuditVerify reports any that appear.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created, as part of moving the base tables to logsData and making them system-versioned.  Takes the name the base
table held before that change.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW logs.DdlChange
AS
SELECT
      dc.ChangeId
    , dc.EventTimeServer
    , dc.EventType
    , dc.ObjectType
    , dc.SchemaName
    , dc.ObjectName
    , dc.CommandText
    , dc.Spid
    , dc.EventLoginName
    , dc.EventDatabaseUser
    , dc.EventXml
    , dc.DefinitionKind
    , dc.PriorDefinition
    , dc.NewDefinition
    , dc.DefinitionChanged
    , dc.RecordedUtc
    , dc.OriginalLogin
    , dc.SessionLogin
    , dc.ProgramName
    , dc.IsDeleted
    , dc.auditDeletedBy
    , dc.auditDeletedDateUtc
    , dc.auditCreatedBy
    , dc.auditCreatedDateUtc
    , dc.auditModifiedBy
    , dc.auditModifiedDateUtc
    , dc.DbApplication
    , dc.HostName
    , dc.AppSessionId
    , dc.SqlSpid
FROM logsData.DdlChange AS dc
WHERE dc.IsDeleted = 0;
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_ioi_ins_DdlChange
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Writes an insert against logs.DdlChange through to logsData.DdlChange, resolving the audit columns.  Audit values
supplied by the caller are kept -- see the block comment above the view for why, and for what that costs.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlChange.  Optional #ReturnedIdentity (InsertedId bigint) in the caller's session.

========================================================================================================================
Notes:

The legacy columns OriginalLogin, RecordedUtc and ProgramName are written from the same resolved values as
auditCreatedBy, auditCreatedDateUtc and DbApplication, computed once in the CROSS APPLY so the two cannot drift apart.
They are narrower (sysname / nvarchar(128)) than the audit columns (nvarchar(255)), hence the LEFT -- a caller passing
a 200-character auditCreatedBy would otherwise fail the insert on a column it never named.

Precisely, then: RecordedUtc and auditCreatedDateUtc are always EQUAL, and the sections 4c/5c back-fills rely on that.
OriginalLogin and ProgramName are the same value TRUNCATED TO 128, so they are equal for every value short enough to
fit and a prefix of the audit column otherwise.  Do not write a check that compares the pair for equality; compare
against LEFT (auditCreatedBy, 128) if you need one.  The guarantee is one source, not one width.

TWO NEAR-IDENTICAL INSERT BRANCHES FOLLOW.  The only difference is the OUTPUT ... INTO #ReturnedIdentity clause, which
cannot be made conditional inside one statement.  A column added to logsData.DdlChange must be added to BOTH -- and
to the UPDATE trigger's SET list, the view's SELECT list, section 14's @Descriptions, and record_db_changes in section
13.  references/change-logging.md carries that checklist; keep the two branches diffable rather than reformatting one.

ChangeId is IDENTITY, so any value supplied for it is ignored.  SCOPE_IDENTITY() in the CALLER's scope returns NULL
after an insert through an INSTEAD OF trigger, because the insert happened in the trigger's scope -- create
#ReturnedIdentity (InsertedId bigint) before the insert to get the keys back.  This is also why record_db_changes
writes to the base table directly rather than through this view.

========================================================================================================================
Example Usage and Performance:

insert logs.DdlChange (EventType, SchemaName, ObjectName, CommandText, auditCreatedBy, auditCreatedDateUtc)
values (N'BACKFILL', N'dbo', N'Widget', N'create table dbo.Widget ...', N'DOMAIN\\olduser', '2019-04-01T08:00:00');

Set-based; one INSERT per statement regardless of row count.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_ioi_ins_DdlChange
ON logs.DdlChange
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Short-circuit execution if zero rows are inserted
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- Re-enable the count on the primary DML.  An ORM (mainly EF Core, DbUpdateConcurrencyException) reads the
    -- affected-row count to decide whether its write landed, and it has to be told the table has triggers.
    SET NOCOUNT OFF;

    -- BRANCH 1 OF 2 -- identical to the ELSE branch below except for the OUTPUT ... INTO clause.  Any change here
    -- must be made there as well; see "TWO NEAR-IDENTICAL INSERT BRANCHES FOLLOW" in the header.
    IF OBJECT_ID (N'tempdb..#ReturnedIdentity') IS NOT NULL
    BEGIN
        INSERT INTO logsData.DdlChange
        (
            EventTimeServer, EventType, ObjectType, SchemaName, ObjectName, CommandText, Spid,
            EventLoginName, EventDatabaseUser, EventXml,
            DefinitionKind, PriorDefinition, NewDefinition, DefinitionChanged,
            RecordedUtc, OriginalLogin, SessionLogin, ProgramName,
            IsDeleted, auditDeletedBy, auditDeletedDateUtc, auditCreatedBy, auditCreatedDateUtc,
            auditModifiedBy, auditModifiedDateUtc, DbApplication, HostName, AppSessionId, SqlSpid
        )
        OUTPUT inserted.ChangeId INTO #ReturnedIdentity (InsertedId)     -- captures ALL rows
        SELECT
            i.EventTimeServer, i.EventType, i.ObjectType, i.SchemaName, i.ObjectName, i.CommandText, i.Spid,
            i.EventLoginName, i.EventDatabaseUser, i.EventXml,
            ISNULL (i.DefinitionKind, 'NONE'), i.PriorDefinition, i.NewDefinition, i.DefinitionChanged,
            r.CreatedDateUtc, LEFT (r.CreatedBy, 128), ISNULL (i.SessionLogin, ISNULL (SUSER_SNAME (), N'')),
            LEFT (r.DbApplication, 128),
            ISNULL (i.IsDeleted, 0), r.DeletedBy, r.DeletedDateUtc, r.CreatedBy, r.CreatedDateUtc,
            r.ModifiedBy, r.ModifiedDateUtc, r.DbApplication,
            ISNULL (HOST_NAME (), N''),                                  -- never caller-overridable
            CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
            @@SPID
        FROM inserted AS i
        CROSS APPLY (VALUES (
              COALESCE (NULLIF (i.auditCreatedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditCreatedDateUtc, SYSUTCDATETIME ())
            , COALESCE (NULLIF (i.auditModifiedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditModifiedDateUtc, SYSUTCDATETIME ())
            , COALESCE (NULLIF (i.auditDeletedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditDeletedDateUtc, SYSUTCDATETIME ())
            , ISNULL (NULLIF (i.DbApplication,     N''), ISNULL (APP_NAME (), N''))
        )) AS r (CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc, DeletedBy, DeletedDateUtc, DbApplication);
    END
    ELSE
    -- BRANCH 2 OF 2 -- the same INSERT without OUTPUT ... INTO, for a caller that did not create #ReturnedIdentity.
    -- Keep it character-for-character identical to branch 1 apart from that clause, so a diff of the two is empty.
    BEGIN
        INSERT INTO logsData.DdlChange
        (
            EventTimeServer, EventType, ObjectType, SchemaName, ObjectName, CommandText, Spid,
            EventLoginName, EventDatabaseUser, EventXml,
            DefinitionKind, PriorDefinition, NewDefinition, DefinitionChanged,
            RecordedUtc, OriginalLogin, SessionLogin, ProgramName,
            IsDeleted, auditDeletedBy, auditDeletedDateUtc, auditCreatedBy, auditCreatedDateUtc,
            auditModifiedBy, auditModifiedDateUtc, DbApplication, HostName, AppSessionId, SqlSpid
        )
        SELECT
            i.EventTimeServer, i.EventType, i.ObjectType, i.SchemaName, i.ObjectName, i.CommandText, i.Spid,
            i.EventLoginName, i.EventDatabaseUser, i.EventXml,
            ISNULL (i.DefinitionKind, 'NONE'), i.PriorDefinition, i.NewDefinition, i.DefinitionChanged,
            r.CreatedDateUtc, LEFT (r.CreatedBy, 128), ISNULL (i.SessionLogin, ISNULL (SUSER_SNAME (), N'')),
            LEFT (r.DbApplication, 128),
            ISNULL (i.IsDeleted, 0), r.DeletedBy, r.DeletedDateUtc, r.CreatedBy, r.CreatedDateUtc,
            r.ModifiedBy, r.ModifiedDateUtc, r.DbApplication,
            ISNULL (HOST_NAME (), N''),
            CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
            @@SPID
        FROM inserted AS i
        CROSS APPLY (VALUES (
              COALESCE (NULLIF (i.auditCreatedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditCreatedDateUtc, SYSUTCDATETIME ())
            , COALESCE (NULLIF (i.auditModifiedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditModifiedDateUtc, SYSUTCDATETIME ())
            , COALESCE (NULLIF (i.auditDeletedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
            , ISNULL (i.auditDeletedDateUtc, SYSUTCDATETIME ())
            , ISNULL (NULLIF (i.DbApplication,     N''), ISNULL (APP_NAME (), N''))
        )) AS r (CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc, DeletedBy, DeletedDateUtc, DbApplication);
    END
END
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_iov_updt_DdlChange
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Applies an update against logs.DdlChange to logsData.DdlChange.  Every audit column is recomputed from the
session; the one exception is auditModifiedBy, which the caller may set.  auditCreatedBy and auditCreatedDateUtc are
not in the SET list, so no update can rewrite who created a row.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlChange.

========================================================================================================================
Notes:

Correlating inserted to deleted needs a stable key, so ChangeId is treated as immutable and a statement that changes
it is rejected outright rather than silently doing nothing.  The rejection is a THROW carrying error 50010, so it ends
the caller's batch and can be branched on; RAISERROR would report 50000 and let the batch continue.

Setting IsDeleted = 1 through this trigger stamps auditDeletedBy and auditDeletedDateUtc, exactly as the DELETE
trigger does.  There are two routes to a soft delete and neither may leave the question of who unanswered.

UPDATE (auditModifiedBy) is what makes "overridable on UPDATE" implementable at all: on an UPDATE, inserted holds the
current value of every column the statement did not touch, so the value alone cannot distinguish "the caller set this"
from "this is what was already there".  UPDATE () reports whether the column appeared in the SET list.  The caveat --
an ORM that writes its full column list on every save names auditModifiedBy every time, so whatever it holds wins.
That is the same trade as on INSERT: honest migrations, not a tamper-proof trail.

========================================================================================================================
Example Usage and Performance:

update logs.DdlChange set DefinitionChanged = 1 where ChangeId = 1234;
update logs.DdlChange set DefinitionChanged = 1, auditModifiedBy = N'DOMAIN\\reviewer' where ChangeId = 1234;

Set-based; one UPDATE per statement.  Each row updated writes one row to history.DdlChange -- which for an
append-only event log is itself the tamper report.  See logs.uspDdlAuditVerify.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_iov_updt_DdlChange
ON logs.DdlChange
INSTEAD OF UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF EXISTS (SELECT 1
                 FROM deleted AS d
                WHERE NOT EXISTS (SELECT 1 FROM inserted AS i WHERE i.ChangeId = d.ChangeId))
    BEGIN
        -- THROW rather than RAISERROR + RETURN.  RAISERROR reported the rejection and then let the batch carry on to
        -- the next statement, so a multi-statement batch continued past a key change it believed had been applied.
        -- THROW terminates the batch.  50010 is this subsystem's "immutable key rejected" number, so a client can
        -- branch on it the way it branches on 1205 or 2627 -- which is the whole reason rule 8 bans RAISERROR here.
        ;THROW 50010, N'logs.DdlChange.ChangeId is immutable. Update the other columns, or insert a new event row.', 1;
    END

    -- Re-enable the count on the primary DML; see the insert trigger.
    SET NOCOUNT OFF;

    -- One value per fact, used everywhere below.  A legacy column and its audit* twin are written from the SAME
    -- variable, so they cannot drift apart -- the invariant stated in the insert trigger and in record_db_changes,
    -- and the one that section 4c's back-fill guard depends on.  Where the legacy column is narrower it is the audit
    -- value truncated to 128 (ProgramName below), so "same source" is the guarantee and "byte-for-byte equal" is not:
    -- a comparison written against these columns has to allow for the LEFT.
    DECLARE @Now      datetime2(3)  = SYSUTCDATETIME (),
            @AppName  nvarchar(255) = ISNULL (APP_NAME (), N''),
            @Actor    nvarchar(255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''),
                                                ORIGINAL_LOGIN ());

    UPDATE t
       SET t.EventTimeServer     = i.EventTimeServer,
           t.EventType           = i.EventType,
           t.ObjectType          = i.ObjectType,
           t.SchemaName          = i.SchemaName,
           t.ObjectName          = i.ObjectName,
           t.CommandText         = i.CommandText,
           t.Spid                = i.Spid,
           t.EventLoginName      = i.EventLoginName,
           t.EventDatabaseUser   = i.EventDatabaseUser,
           t.EventXml            = i.EventXml,
           t.DefinitionKind      = ISNULL (i.DefinitionKind, 'NONE'),
           t.PriorDefinition     = i.PriorDefinition,
           t.NewDefinition       = i.NewDefinition,
           t.DefinitionChanged   = i.DefinitionChanged,
           t.SessionLogin        = ISNULL (i.SessionLogin, ISNULL (SUSER_SNAME (), N'')),
           t.IsDeleted           = ISNULL (i.IsDeleted, 0),

           -- An UPDATE that sets IsDeleted = 1 is a soft delete arriving by the other route, and it used to leave no
           -- record of who performed it: only the DELETE trigger stamped auditDeleted*.  On the event log that row is
           -- precisely what logs.uspDdlAuditVerify reports as a tamper indicator, so "who" is the question being
           -- asked of it.  The view filters IsDeleted = 0, so every row that reaches this trigger was live and
           -- setting it to 1 here is always a 0 -> 1 transition; no before-image test is needed.
           t.auditDeletedBy      = CASE WHEN ISNULL (i.IsDeleted, 0) = 1 THEN @Actor ELSE t.auditDeletedBy      END,
           t.auditDeletedDateUtc = CASE WHEN ISNULL (i.IsDeleted, 0) = 1 THEN @Now   ELSE t.auditDeletedDateUtc END,

           -- auditModifiedBy is the one caller-overridable audit column on UPDATE.  Everything below it is taken from
           -- the session, whatever the statement passed.
           t.auditModifiedBy     = CASE WHEN UPDATE (auditModifiedBy)
                                        THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                        ELSE @Actor
                                   END,
           t.auditModifiedDateUtc = @Now,
           t.DbApplication        = @AppName,
           t.HostName             = ISNULL (HOST_NAME (), N''),
           t.AppSessionId         = CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
           t.SqlSpid              = @@SPID,
           t.ProgramName          = LEFT (@AppName, 128)    -- legacy mirror of DbApplication, from the same variable
      FROM logsData.DdlChange AS t
     INNER JOIN deleted  AS d ON t.ChangeId = d.ChangeId
     INNER JOIN inserted AS i ON i.ChangeId = d.ChangeId;
END
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_iod_del_DdlChange
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Turns a DELETE against logs.DdlChange into a soft delete on logsData.DdlChange.  No row is ever physically
removed, from either the current table or its history.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlChange.

========================================================================================================================
Notes:

This exists for completeness of the view's DML surface, not because anything should use it.  DdlChange is the
evidence: a soft-deleted event row is reported as a tamper indicator by logs.uspDdlAuditVerify, and the version that
was current before the delete is in history.DdlChange either way.  Consider a DENY DELETE on this view for
applicationRole if nothing legitimately needs it.

========================================================================================================================
Example Usage and Performance:

delete from logs.DdlChange where ChangeId = 1234;    -- sets IsDeleted = 1; nothing is removed

Set-based; one UPDATE per statement.  Already-deleted rows are excluded by the view's filter, so re-running is a no-op.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_iod_del_DdlChange
ON logs.DdlChange
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    -- Re-enable the count on the primary DML; see the insert trigger.
    SET NOCOUNT OFF;

    -- One value per fact; the deleted and modified stamps describe the same act and are written from one variable.
    DECLARE @Now    datetime2(3)  = SYSUTCDATETIME (),
            @Actor  nvarchar(255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''),
                                              ORIGINAL_LOGIN ());

    -- Logical soft delete rather than a physical row purge
    UPDATE t
       SET t.IsDeleted            = 1,
           t.auditDeletedBy       = @Actor,
           t.auditDeletedDateUtc  = @Now,
           t.auditModifiedBy      = @Actor,
           t.auditModifiedDateUtc = @Now,
           t.DbApplication        = ISNULL (APP_NAME (), N''),
           t.HostName             = ISNULL (HOST_NAME (), N''),
           t.AppSessionId         = CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
           t.SqlSpid              = @@SPID
      FROM logsData.DdlChange AS t
     INNER JOIN deleted AS d ON t.ChangeId = d.ChangeId
     WHERE t.IsDeleted = 0;
END
GO


/***********************************************************************************************************************
   *** 9. The view wrapper over logsData.DdlObjectState, and its INSTEAD OF triggers ***

Same contract as section 8: caller-overridable audit columns on INSERT, only auditModifiedBy on UPDATE, soft delete
only.  The key here is the natural key (SchemaName, ObjectName), which the UPDATE trigger treats as immutable -- an
object that was renamed gets a new state row on its next DDL event, which is what the trigger notes in section 12
already say about sp_rename.
***********************************************************************************************************************/

/***********************************************************************************************************************
ObjectName:   logs.DdlObjectState
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Current definition of each schema-scoped object, soft-delete filtered.  Read this to answer "what does this object look
like now, according to the audit subsystem"; read logsData.DdlObjectState FOR SYSTEM_TIME to answer "what did it
look like on this date".

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlObjectState (system-versioned).  Shares an owner with logsData -- see section 2.

========================================================================================================================
Notes:

record_db_changes writes the base table directly, not this view: it needs the state row under UPDLOCK, HOLDLOCK in the
same statement that reads it, and it runs as a loginless user whose grants are explicit.

========================================================================================================================
Example Usage and Performance:

-- what the audit subsystem currently holds for one object
select SchemaName, ObjectName, DefinitionKind, IsDropped, LastChangeId, Definition
from   logs.DdlObjectState
where  SchemaName = 'util' and ObjectName = 'uspSetObjectDescription';

-- what it looked like a month ago (base table; needs logsAuditReader -- readOnlyRole is denied here)
select Definition
from   logsData.DdlObjectState for system_time as of '2026-08-12T00:00:00'
where  SchemaName = 'util' and ObjectName = 'uspSetObjectDescription';

Seeks on the clustered PK (SchemaName, ObjectName).

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created, as part of moving the base tables to logsData and making them system-versioned.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW logs.DdlObjectState
AS
SELECT
      os.SchemaName
    , os.ObjectName
    , os.ObjectType
    , os.DefinitionKind
    , os.Definition
    , os.IsDropped
    , os.LastChangeId
    , os.UpdatedUtc
    , os.IsDeleted
    , os.auditDeletedBy
    , os.auditDeletedDateUtc
    , os.auditCreatedBy
    , os.auditCreatedDateUtc
    , os.auditModifiedBy
    , os.auditModifiedDateUtc
    , os.DbApplication
    , os.HostName
    , os.AppSessionId
    , os.SqlSpid
FROM logsData.DdlObjectState AS os
WHERE os.IsDeleted = 0;
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_ioi_ins_DdlObjectState
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Writes an insert against logs.DdlObjectState through to the base table, resolving the audit columns.  Audit values
supplied by the caller are kept, so a backfill can carry the dates and logins it came with.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlObjectState.

========================================================================================================================
Notes:

No IDENTITY on this table, so there is no #ReturnedIdentity branch: the key is supplied by the caller.  That is the one
structural difference from logs.trg_ioi_ins_DdlChange, which needs two branches for it; everything else about the
two triggers is the same shape, so read that one's header for the reasoning behind the CROSS APPLY.

UpdatedUtc is the legacy name for auditModifiedDateUtc and is written from the same resolved value, and both are
datetime2 (3), so unlike OriginalLogin/auditCreatedBy on DdlChange there is no truncation and the two are always
exactly equal.

A column added to logsData.DdlObjectState must be added here, to the UPDATE trigger's SET list, to the
logs.DdlObjectState view, and to section 14's @Descriptions.  references/change-logging.md carries the checklist.

========================================================================================================================
Example Usage and Performance:

insert logs.DdlObjectState (SchemaName, ObjectName, ObjectType, DefinitionKind, Definition)
values (N'dbo', N'Widget', N'USER_TABLE', 'TABLE_SHAPE', N'COLUMN|1|WidgetId|int|...');

Set-based; one INSERT per statement.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_ioi_ins_DdlObjectState
ON logs.DdlObjectState
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- Re-enable the count on the primary DML; see logs.trg_ioi_ins_DdlChange.
    SET NOCOUNT OFF;

    INSERT INTO logsData.DdlObjectState
    (
        SchemaName, ObjectName, ObjectType, DefinitionKind, Definition, IsDropped, LastChangeId, UpdatedUtc,
        IsDeleted, auditDeletedBy, auditDeletedDateUtc, auditCreatedBy, auditCreatedDateUtc,
        auditModifiedBy, auditModifiedDateUtc, DbApplication, HostName, AppSessionId, SqlSpid
    )
    SELECT
        i.SchemaName, i.ObjectName, i.ObjectType, ISNULL (i.DefinitionKind, 'NONE'), i.Definition,
        ISNULL (i.IsDropped, 0), i.LastChangeId, r.ModifiedDateUtc,
        ISNULL (i.IsDeleted, 0), r.DeletedBy, r.DeletedDateUtc, r.CreatedBy, r.CreatedDateUtc,
        r.ModifiedBy, r.ModifiedDateUtc, r.DbApplication,
        ISNULL (HOST_NAME (), N''),                                      -- never caller-overridable
        CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
        @@SPID
    FROM inserted AS i
    CROSS APPLY (VALUES (
          COALESCE (NULLIF (i.auditCreatedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
        , ISNULL (i.auditCreatedDateUtc, SYSUTCDATETIME ())
        , COALESCE (NULLIF (i.auditModifiedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
        , ISNULL (i.auditModifiedDateUtc, SYSUTCDATETIME ())
        , COALESCE (NULLIF (i.auditDeletedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''), ORIGINAL_LOGIN ())
        , ISNULL (i.auditDeletedDateUtc, SYSUTCDATETIME ())
        , ISNULL (NULLIF (i.DbApplication,     N''), ISNULL (APP_NAME (), N''))
    )) AS r (CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc, DeletedBy, DeletedDateUtc, DbApplication);
END
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_iov_updt_DdlObjectState
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Applies an update against logs.DdlObjectState to the base table.  Audit columns are recomputed from the session
except auditModifiedBy, which the caller may set; auditCreatedBy and auditCreatedDateUtc are not in the SET list.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlObjectState.

========================================================================================================================
Notes:

(SchemaName, ObjectName) is the key that correlates inserted to deleted, so it is immutable here and a statement that
changes it is rejected -- with a THROW carrying error 50010, which ends the caller's batch rather than letting it
continue past a change it believes was applied.  To move a state row to a new name, insert the new one; the old row
stays as the record of what that name used to hold.

Setting IsDeleted = 1 through this trigger stamps auditDeletedBy and auditDeletedDateUtc, as the DELETE trigger does.

Each update writes one row to history.DdlObjectState -- that history is what PriorDefinition on the event log is
reconciled against.

========================================================================================================================
Example Usage and Performance:

update logs.DdlObjectState set IsDropped = 1 where SchemaName = 'dbo' and ObjectName = 'Widget';

Set-based; seeks on the clustered PK.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_iov_updt_DdlObjectState
ON logs.DdlObjectState
INSTEAD OF UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF EXISTS (SELECT 1
                 FROM deleted AS d
                WHERE NOT EXISTS (SELECT 1
                                    FROM inserted AS i
                                   WHERE i.SchemaName = d.SchemaName
                                     AND i.ObjectName = d.ObjectName))
    BEGIN
        -- THROW rather than RAISERROR + RETURN; see logs.trg_iov_updt_DdlChange for why, and for what 50010 means.
        ;THROW 50010, N'logs.DdlObjectState.(SchemaName, ObjectName) is immutable. Insert a row under the new name instead.', 1;
    END

    -- Re-enable the count on the primary DML; see logs.trg_ioi_ins_DdlChange.
    SET NOCOUNT OFF;

    -- One value per fact.  UpdatedUtc is the legacy twin of auditModifiedDateUtc and the two were being written from
    -- two separate SYSUTCDATETIME () calls.  Section 5c's back-fill is guarded on those two being equal, so a row
    -- where they ever diverged would be re-updated by every subsequent run of the installer, pushing a spurious
    -- version into history.DdlObjectState each time.
    DECLARE @Now    datetime2(3)  = SYSUTCDATETIME (),
            @Actor  nvarchar(255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''),
                                              ORIGINAL_LOGIN ());

    UPDATE t
       SET t.ObjectType           = i.ObjectType,
           t.DefinitionKind       = ISNULL (i.DefinitionKind, 'NONE'),
           t.Definition           = i.Definition,
           t.IsDropped            = ISNULL (i.IsDropped, 0),
           t.LastChangeId         = i.LastChangeId,
           t.IsDeleted            = ISNULL (i.IsDeleted, 0),

           -- A soft delete performed by UPDATE stamps the delete columns too; see logs.trg_iov_updt_DdlChange.
           t.auditDeletedBy       = CASE WHEN ISNULL (i.IsDeleted, 0) = 1 THEN @Actor ELSE t.auditDeletedBy      END,
           t.auditDeletedDateUtc  = CASE WHEN ISNULL (i.IsDeleted, 0) = 1 THEN @Now   ELSE t.auditDeletedDateUtc END,

           t.auditModifiedBy      = CASE WHEN UPDATE (auditModifiedBy)
                                         THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                         ELSE @Actor
                                    END,
           t.auditModifiedDateUtc = @Now,
           t.UpdatedUtc           = @Now,                                -- legacy mirror, from the same variable
           t.DbApplication        = ISNULL (APP_NAME (), N''),
           t.HostName             = ISNULL (HOST_NAME (), N''),
           t.AppSessionId         = CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
           t.SqlSpid              = @@SPID
      FROM logsData.DdlObjectState AS t
     INNER JOIN deleted  AS d ON t.SchemaName = d.SchemaName AND t.ObjectName = d.ObjectName
     INNER JOIN inserted AS i ON i.SchemaName = d.SchemaName AND i.ObjectName = d.ObjectName;
END
GO


/***********************************************************************************************************************
ObjectName:   logs.trg_iod_del_DdlObjectState
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Turns a DELETE against logs.DdlObjectState into a soft delete on the base table.  Nothing is physically removed.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlObjectState.

========================================================================================================================
Notes:

A soft-deleted state row hides the object's last known definition from the view, and record_db_changes will then find
no prior image for that object on its next event -- so the next change records PriorDefinition as NULL.  Prefer
IsDropped = 1, which is what the trigger sets when an object is dropped and which keeps the definition readable.

========================================================================================================================
Example Usage and Performance:

delete from logs.DdlObjectState where SchemaName = 'dbo' and ObjectName = 'Widget';

Set-based; seeks on the clustered PK.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER logs.trg_iod_del_DdlObjectState
ON logs.DdlObjectState
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    -- Re-enable the count on the primary DML; see logs.trg_ioi_ins_DdlChange.
    SET NOCOUNT OFF;

    -- One value per fact.  UpdatedUtc and auditModifiedDateUtc are the same fact under two names and must not be
    -- written from two separate SYSUTCDATETIME () calls; see logs.trg_iov_updt_DdlObjectState.
    DECLARE @Now    datetime2(3)  = SYSUTCDATETIME (),
            @Actor  nvarchar(255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), N''),
                                              ORIGINAL_LOGIN ());

    UPDATE t
       SET t.IsDeleted            = 1,
           t.auditDeletedBy       = @Actor,
           t.auditDeletedDateUtc  = @Now,
           t.auditModifiedBy      = @Actor,
           t.auditModifiedDateUtc = @Now,
           t.UpdatedUtc           = @Now,
           t.DbApplication        = ISNULL (APP_NAME (), N''),
           t.HostName             = ISNULL (HOST_NAME (), N''),
           t.AppSessionId         = CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
           t.SqlSpid              = @@SPID
      FROM logsData.DdlObjectState AS t
     INNER JOIN deleted AS d ON t.SchemaName = d.SchemaName AND t.ObjectName = d.ObjectName
     WHERE t.IsDeleted = 0;
END
GO


-- *** 10. Verification procedure ***

/***********************************************************************************************************************
ObjectName:   logs.uspDdlAuditVerify
Author:       rsincero
CreateDate:   2026-09-12
========================================================================================================================
Description:

Reports the integrity posture of the DDL audit subsystem.  Replaces logs.z_ddl_change_verify, which recomputed a
SHA-256 hash chain; system versioning now provides the same evidence more cheaply.  One row per check, worst first.

  PROBLEM  something is wrong now and the audit trail is not trustworthy until it is fixed.
  INFO     a fact worth reading, not a fault.
  OK       the check passed.

The checks:

  SYSTEM_VERSIONING       Every table in logsData must be system-versioned.  If versioning is off, changes are no
                          longer being recorded and rows can be edited without trace -- this is the one check that
                          matters most, because pausing versioning is how a determined insider would work.
  EVENT_LOG_HISTORY       history.DdlChange must be EMPTY.  The event log is append-only, so a row in its history
                          table means an event row was updated or deleted.  The old version is in that history row.
  EVENT_LOG_SOFT_DELETED  No event row should carry IsDeleted = 1.  A soft-deleted event row is hidden from
                          logs.DdlChange but still present in the base table.
  DDL_TRIGGER             record_db_changes must exist and be enabled.  A disabled trigger records nothing and raises
                          no error.
  INSTEAD_OF_TRIGGERS     All six INSTEAD OF triggers on the two views must exist and be enabled.  A disabled one is
                          a silent hole: the write still lands on the base table, but the audit columns stop being
                          resolved and a DELETE stops soft-deleting.
  SCHEMA_OWNERSHIP        logs, logsData and history must share an owner, or the views cannot write to the base tables.
  HISTORY_RETENTION       Retention must be INFINITE.  A finite retention period silently deletes the oldest evidence.
  LEGACY_HASH_CHAIN       Informational: whether the retired hash columns are still on the table, which is to say
                          whether this database was migrated or created fresh.

========================================================================================================================
Requirements and Key Dependencies:

logsData.DdlChange, logsData.DdlObjectState, history.DdlChange, sys.tables, sys.periods, sys.triggers,
sys.schemas.  The caller needs SELECT on logsData and history (logsAuditReader -- readOnlyRole is DENIED both by
scripts/permissions.sql), or the counts come
back as permission errors rather than zeros.

========================================================================================================================
Notes:

What this cannot detect, unchanged from the hash-chain version and worth repeating: anyone with sysadmin or db_owner can
switch system versioning off, edit both tables, and switch it back on with DATA_CONSISTENCY_CHECK = OFF; or restore the
database from an earlier backup.  The SYSTEM_VERSIONING check catches the state they leave behind only if they forget
to switch it back on.  The only durable defence is a copy outside this instance, held by someone other than the people
being audited: read logsData.DdlChange from a job on another instance on a ChangeId watermark, and keep the highest
ChangeId you have seen.  A gap in ChangeId on the next read is then evidence in its own right, since the column is an
IDENTITY that never goes backwards.

TRY/CATCH with a bare THROW so the caller receives the original error number.  No logs.ExecutionLog row: this file is
self-contained by design -- it is run against databases that have no ExecutionLog subsystem -- and adding that call
would make the audit bootstrap depend on the application's logging.

========================================================================================================================
Example Usage and Performance:

exec logs.uspDdlAuditVerify;                    -- every check
exec logs.uspDdlAuditVerify @ProblemsOnly = 1;  -- only what is wrong

Catalog reads plus one COUNT over history.DdlChange and two over the current tables.  Cheap enough to run from a
monitoring job.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created, superseding logs.z_ddl_change_verify.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE logs.uspDdlAuditVerify
    @ProblemsOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY

        DECLARE @Findings TABLE
        (
            Severity    tinyint         not null,       -- 1 PROBLEM, 2 INFO, 3 OK.  Sort key only.
            Status      varchar(10)     not null,
            CheckName   varchar(30)     not null,
            Detail      nvarchar(1000)  not null
        );

        DECLARE @Count bigint;

        /* SYSTEM_VERSIONING ------------------------------------------------------------------------------------- */
        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT 1, 'PROBLEM', 'SYSTEM_VERSIONING',
               N'logsData.' + t.name + N' is not system-versioned (temporal_type = '
             + CONVERT (nvarchar(10), t.temporal_type) + N'). Changes to it are not being recorded.'
          FROM sys.tables  AS t
          JOIN sys.schemas AS s ON s.schema_id = t.schema_id
         WHERE s.name = N'logsData'
           AND t.temporal_type <> 2;

        IF NOT EXISTS (SELECT 1 FROM @Findings WHERE CheckName = 'SYSTEM_VERSIONING')
            INSERT @Findings (Severity, Status, CheckName, Detail)
            SELECT 3, 'OK', 'SYSTEM_VERSIONING',
                   N'All ' + CONVERT (nvarchar(10), COUNT (*)) + N' table(s) in logsData are system-versioned.'
              FROM sys.tables  AS t
              JOIN sys.schemas AS s ON s.schema_id = t.schema_id
             WHERE s.name = N'logsData';

        /* EVENT_LOG_HISTORY ------------------------------------------------------------------------------------- */
        SELECT @Count = COUNT (*) FROM history.DdlChange;

        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT CASE WHEN @Count = 0 THEN 3 ELSE 1 END,
               CASE WHEN @Count = 0 THEN 'OK' ELSE 'PROBLEM' END,
               'EVENT_LOG_HISTORY',
               CASE WHEN @Count = 0
                    THEN N'history.DdlChange is empty, as an append-only log should be.'
                    ELSE N'history.DdlChange holds ' + CONVERT (nvarchar(20), @Count)
                       + N' row(s): that many event rows have been updated or deleted. Read them for the prior '
                       + N'values: select * from history.DdlChange order by SysEndTime desc;'
               END;

        /* EVENT_LOG_SOFT_DELETED -------------------------------------------------------------------------------- */
        SELECT @Count = COUNT (*) FROM logsData.DdlChange WHERE IsDeleted = 1;

        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT CASE WHEN @Count = 0 THEN 3 ELSE 1 END,
               CASE WHEN @Count = 0 THEN 'OK' ELSE 'PROBLEM' END,
               'EVENT_LOG_SOFT_DELETED',
               CASE WHEN @Count = 0
                    THEN N'No event row is soft-deleted.'
                    ELSE N'' + CONVERT (nvarchar(20), @Count) + N' event row(s) carry IsDeleted = 1 and are hidden '
                       + N'from logs.DdlChange. They are still in logsData.DdlChange; auditDeletedBy says who.'
               END;

        /* DDL_TRIGGER ------------------------------------------------------------------------------------------- */
        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT CASE WHEN tr.name IS NULL OR tr.is_disabled = 1 THEN 1 ELSE 3 END,
               CASE WHEN tr.name IS NULL OR tr.is_disabled = 1 THEN 'PROBLEM' ELSE 'OK' END,
               'DDL_TRIGGER',
               CASE WHEN tr.name IS NULL     THEN N'record_db_changes does not exist. No DDL is being recorded.'
                    WHEN tr.is_disabled = 1  THEN N'record_db_changes exists but is DISABLED. It records nothing and '
                                                + N'raises no error. Re-enable it: enable trigger record_db_changes on database;'
                    ELSE N'record_db_changes exists and is enabled.'
               END
          FROM (SELECT 1 AS One) AS x
          LEFT JOIN sys.triggers AS tr
                 ON tr.parent_class = 0                  -- 0 = database-scoped DDL trigger
                AND tr.name         = N'record_db_changes';

        /* INSTEAD_OF_TRIGGERS ----------------------------------------------------------------------------------- */
        -- Existence is not enough, which is why this check reads is_disabled and the object-existence report in
        -- checkDbChangeLogging.sql is not a substitute.  A disabled INSTEAD OF trigger changes nothing a caller can
        -- see: the view still accepts the statement, the write still lands.  What stops is the audit contract -- the
        -- audit columns are no longer resolved, and a DELETE stops being a soft delete.
        DECLARE @IoTotal    int,
                @IoDisabled int,
                @IoNames    nvarchar(1000);

        SELECT @IoTotal    = COUNT (*),
               @IoDisabled = SUM (CASE WHEN tr.is_disabled = 1 THEN 1 ELSE 0 END)
          FROM sys.triggers AS tr
         WHERE tr.parent_class = 1                   -- 1 = trigger on an object, as opposed to 0 = database-scoped
           AND tr.parent_id IN (OBJECT_ID (N'logs.DdlChange'), OBJECT_ID (N'logs.DdlObjectState'));

        SELECT @IoNames = STRING_AGG (CONVERT (nvarchar(max), N'logs.' + tr.name), N', ')
                                WITHIN GROUP (ORDER BY tr.name)
          FROM sys.triggers AS tr
         WHERE tr.parent_class = 1
           AND tr.parent_id IN (OBJECT_ID (N'logs.DdlChange'), OBJECT_ID (N'logs.DdlObjectState'))
           AND tr.is_disabled = 1;

        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT CASE WHEN @IoDisabled > 0 OR @IoTotal < 6 THEN 1 ELSE 3 END,
               CASE WHEN @IoDisabled > 0 OR @IoTotal < 6 THEN 'PROBLEM' ELSE 'OK' END,
               'INSTEAD_OF_TRIGGERS',
               CASE WHEN @IoDisabled > 0
                         THEN CONVERT (nvarchar(10), @IoDisabled) + N' INSTEAD OF trigger(s) are DISABLED: '
                            + ISNULL (@IoNames, N'?')
                            + N'. Writes through the view stop resolving the audit columns and a DELETE stops '
                            + N'soft-deleting. Re-enable each: enable trigger <name> on <view>;'
                    WHEN @IoTotal < 6
                         THEN N'Only ' + CONVERT (nvarchar(10), @IoTotal) + N' of the 6 INSTEAD OF triggers exist. '
                            + N'Re-run logdBChanges.sql, which recreates them with CREATE OR ALTER.'
                    ELSE N'All 6 INSTEAD OF triggers exist and are enabled.'
               END;

        /* SCHEMA_OWNERSHIP -------------------------------------------------------------------------------------- */
        SELECT @Count = COUNT (DISTINCT s.principal_id)
          FROM sys.schemas AS s
         WHERE s.name IN (N'logs', N'logsData', N'history');

        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT CASE WHEN @Count = 1 THEN 3 ELSE 1 END,
               CASE WHEN @Count = 1 THEN 'OK' ELSE 'PROBLEM' END,
               'SCHEMA_OWNERSHIP',
               CASE WHEN @Count = 1
                    THEN N'logs, logsData and history share an owner, so ownership chaining through the views holds.'
                    ELSE N'logs, logsData and history have ' + CONVERT (nvarchar(10), @Count) + N' different owners. '
                       + N'Ownership chaining is broken, so writes through the views will fail on the base tables. '
                       + N'Re-run section 2 of logdBChanges.sql.'
               END;

        /* HISTORY_RETENTION ------------------------------------------------------------------------------------- */
        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT 1, 'PROBLEM', 'HISTORY_RETENTION',
               N'logsData.' + t.name + N' has a finite history retention of '
             + CONVERT (nvarchar(10), t.history_retention_period) + N' ' + t.history_retention_period_unit_desc
             + N'. The oldest evidence will be deleted. Set it to INFINITE.'
          FROM sys.tables  AS t
          JOIN sys.schemas AS s ON s.schema_id = t.schema_id
         WHERE s.name = N'logsData'
           AND t.temporal_type = 2
           AND ISNULL (t.history_retention_period, -1) <> -1;             -- -1 = INFINITE

        IF NOT EXISTS (SELECT 1 FROM @Findings WHERE CheckName = 'HISTORY_RETENTION')
            INSERT @Findings (Severity, Status, CheckName, Detail)
            VALUES (3, 'OK', 'HISTORY_RETENTION', N'History retention is INFINITE on every versioned table in logsData.');

        /* LEGACY_HASH_CHAIN ------------------------------------------------------------------------------------- */
        -- Reported from sys.columns rather than by counting rows WHERE RowHash IS NOT NULL.  Two reasons, both hard
        -- constraints rather than preferences.  A column reference is bound when the procedure's statements are
        -- compiled, not when the IF around them is evaluated, so a static SELECT on RowHash raises "Invalid column
        -- name" on a fresh database that never had the column -- guard or no guard.  And doing it in dynamic SQL to
        -- dodge that would break ownership chaining, so a caller holding only EXECUTE on this procedure would then
        -- need SELECT on logsData as well.  The count is one query away for anyone who wants it.
        IF EXISTS (SELECT 1
                     FROM sys.columns
                    WHERE object_id = OBJECT_ID (N'logsData.DdlChange')
                      AND name      = N'RowHash')
            INSERT @Findings (Severity, Status, CheckName, Detail)
            VALUES (2, 'INFO', 'LEGACY_HASH_CHAIN',
                    N'The retired hash columns are still present on logsData.DdlChange, so this database was '
                  + N'migrated rather than created fresh. Rows written before the temporal conversion still carry a '
                  + N'RowHash and can be re-verified by hand against a saved copy of logs.z_ddl_row_hash; rows written '
                  + N'after it have none, by design. To count them: SELECT COUNT (*) FROM logsData.DdlChange '
                  + N'WHERE RowHash IS NOT NULL;');

        /* Watermark, for the off-instance copy described in the notes ------------------------------------------- */
        INSERT @Findings (Severity, Status, CheckName, Detail)
        SELECT 2, 'INFO', 'WATERMARK',
               N'logsData.DdlChange holds ' + CONVERT (nvarchar(20), COUNT (*)) + N' row(s); highest ChangeId '
             + ISNULL (CONVERT (nvarchar(20), MAX (ChangeId)), N'(none)') + N'. Record this off-instance: a later read '
             + N'that skips a ChangeId is evidence in itself.'
          FROM logsData.DdlChange;

        /* ------------------------------------------------------------------------------------------------------- */
        SELECT   Status, CheckName, Detail
          FROM   @Findings
         WHERE   @ProblemsOnly = 0
            OR   Severity = 1
         ORDER BY Severity ASC, CheckName ASC;

    END TRY
    BEGIN CATCH

        -- This procedure only reads, so it skips the start row and the completion UPDATE -- but not the CATCH.
        -- "It only reads" is not the same as "it cannot fail in a way worth recording": every check above calls
        -- something (logs.udfTableShape, OBJECT_DEFINITION, a catalog view, a CONVERT of a definition into
        -- nvarchar(1000)) and any of those can raise.  When the verification of the audit trail is the thing that
        -- fails, that is precisely the event nobody can afford to lose.
        --
        -- @ExecutionLogId is NULL because there is no start row to update.  The MERGE inside
        -- logs.uspRecordExecutionErrorUpdate inserts an orphan row for that case on purpose.
        DECLARE @ProcName      nvarchar(300) = COALESCE (QUOTENAME (OBJECT_SCHEMA_NAME (@@PROCID)) + N'.'
                                                       + QUOTENAME (OBJECT_NAME (@@PROCID)), N'[logs].[uspDdlAuditVerify]'),
                @KeyParameters nvarchar(max) = N'@ProblemsOnly = ' + ISNULL (CONVERT (nvarchar(1), @ProblemsOnly), N'NULL'),
                @ErrorNumber   int           = ERROR_NUMBER (),
                @ErrorProc     nvarchar(300) = ERROR_PROCEDURE (),
                @ErrorLine     int           = ERROR_LINE (),
                @ErrorMsg      nvarchar(max) = ERROR_MESSAGE ()
                                             + N' (error '  + CAST (ERROR_NUMBER () AS nvarchar(11))
                                             + N', line '   + CAST (ERROR_LINE ()   AS nvarchar(11)) + N')';

        -- No ROLLBACK: this procedure opens no transaction, and XACT_STATE () <> 0 is also true when the CALLER owns
        -- one, so a rollback here would discard work this procedure never did.
        --
        -- Guarded on the procedure existing.  logs.uspRecordExecutionError is created by scripts/logExecutionLogging.sql,
        -- which is the other half of this skill and is normally already installed -- section 9 above depends on it
        -- being in the logs schema.  But this file is documented as installable on its own, and an unguarded EXEC
        -- would then replace the error being reported with "could not find stored procedure", which is the one
        -- outcome this whole rule exists to prevent.
        IF OBJECT_ID (N'logs.uspRecordExecutionError', N'P') IS NOT NULL
            EXEC logs.uspRecordExecutionError
                  @ProcedureName   = @ProcName
                , @KeyParameters   = @KeyParameters
                , @ExecutionLogId  = NULL
                , @ErrorMessage    = @ErrorMsg
                , @ErrorProcedure  = @ErrorProc
                , @ErrorNumber     = @ErrorNumber
                , @ErrorLine       = @ErrorLine;

        -- Bare THROW so the caller receives the original error number rather than 50000.
        ;THROW;
    END CATCH

    RETURN 0;
END
GO


/***********************************************************************************************************************
   *** 11. Permissions ***

Three layers, and the order they resolve in matters:

  applicationRole            CRUD on SCHEMA::logs -- the views and their INSTEAD OF triggers -- and nothing on logsData or
                      history.  No EXECUTE: modules are granted one at a time, from the script that creates them.
                      The writes still land, because logs, logsData and history share an owner: an unbroken
                      ownership chain means the caller's permissions are checked on the view only.  The DENY on
                      logsData is therefore not what makes the views work; it is what stops a direct
                      SELECT ... FROM logsData.DdlChange, which would bypass the IsDeleted filter.

  readOnlyRole       SELECT on SCHEMA::logs and nothing else.  Denied all four on logsData and history, matching
                      scripts/permissions.sql and SKILL.md.  It used to be granted SELECT on both, which contradicted
                      both of those files and won or lost on deployment order alone -- see the block in the script.

  logsAuditReader   The audit reader: SELECT everywhere in the subsystem, no writes.

  ddl_audit_user   Exactly what record_db_changes needs and nothing else.  No DELETE anywhere, no UPDATE on the
                      event log.

GRANT and DENY are both idempotent, so this section is unguarded and silent on a re-run.  It has to run every time
regardless: ALTER SCHEMA TRANSFER in sections 4a and 5a DISCARDS every permission on the object it moves.

Why there is no DENY ... TO public here
---------------------------------------
An earlier draft ended with DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logsData TO public as "inheritance cleanup".
Do not restore it.  Every database user is a member of public and membership cannot be revoked, so that DENY also
applies to ddl_audit_user -- and whether a schema-scoped DENY beats an object-scoped GRANT is not a question to
bet an audit trail on.  If it does, the trigger's INSERT fails, and since the trigger fails closed, every DDL statement
in the database fails with it.  public holds nothing on a new schema anyway, so the DENY bought nothing.  The REVOKE
below removes it if a database already has it -- REVOKE clears a DENY as well as a GRANT.
***********************************************************************************************************************/

REVOKE SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logsData FROM public;
REVOKE SELECT, INSERT, UPDATE, DELETE ON SCHEMA::history  FROM public;
GO

-- applicationRole
--
-- No EXECUTE on SCHEMA::logs.  An earlier version granted it, fifteen lines above the comment that explains why
-- logsAuditReader deliberately does not get one -- and that reasoning applies here more strongly rather than less.
-- logs also holds uspStartExecutionLogging, uspRecordExecutionError, uspRecordExecutionErrorUpdate, uspGetExecutionLogPage
-- and uspDdlAuditVerify; a schema-wide grant hands the application every one of them, and every module added to the
-- schema afterwards that nobody has reviewed yet.
--
-- It also broke a stated invariant: each procedure script carries its OWN GRANT EXECUTE, to only the roles that call
-- it, and that is what makes the permission report at the end of scripts/permissions.sql authoritative.  A schema-scoped grant
-- makes that report wrong by construction -- it reports what each script granted, and this granted everything.
--
-- The REVOKE is what makes the correction converge on a database that already carries the old grant.  It removes the
-- SCHEMA-scoped permission only; the object-level grants issued by the individual procedure scripts are a different
-- securable and are untouched.  If a call starts failing after this runs, the GRANT it needs belongs in that
-- procedure's own script, which is the point.
REVOKE EXECUTE                       ON SCHEMA::logs FROM applicationRole;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logs TO applicationRole;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logsData TO applicationRole;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::history  TO applicationRole;
GO

-- readOnlyRole
--
-- SELECT ON SCHEMA::logs ONLY.  The two lines that used to grant it SELECT on logsData and history are gone, and the
-- DENY below now covers SELECT as well, so this file states the same intent as scripts/permissions.sql instead of
-- contradicting it.
--
-- WHY THIS WAS WRONG, AND WHY NOTHING REPORTED IT.  scripts/permissions.sql puts dboData, logsData and history in one
-- deny list and denies readOnlyRole all four permissions on each, for a reason it states: the view is what applies the
-- IsDeleted filter, so a reader admitted to the base table reads soft-deleted rows.  SKILL.md's permission table says
-- the same.  This file granted the opposite.  Because a GRANT and a DENY on the same securable are one catalog row and
-- the later statement overwrites the earlier, whichever file ran last simply won -- silently, with no conflict to
-- detect.  Running permissions.sql last left DENY; running this file last left GRANT; the database was correct or
-- incorrect depending on deployment order alone.
--
-- The REVOKE is what makes the correction converge on a database that already carries the old grant.  Removing the
-- GRANT lines is not enough on its own: a database where they already ran keeps the row until something clears it, and
-- a DENY issued over an existing GRANT is what this whole comment is about.  REVOKE first, then DENY, so the end state
-- does not depend on what was there before.
--
-- IF A COMPLIANCE READER GENUINELY NEEDS SOFT-DELETED ROWS OR FOR SYSTEM_TIME VERSIONS, the answer is a view in logs
-- that exposes the slice they need and nothing else.  It reaches the base table through ownership chaining and needs no
-- grant on logsData at all, which is why it is narrower than a schema-wide SELECT rather than merely more polite.
-- logsAuditReader below already holds exactly this access for the audit case; that role is created by this file and
-- permissions.sql never touches it, which is why it survives and readOnlyRole's grant did not.
REVOKE SELECT ON SCHEMA::logsData FROM readOnlyRole;
REVOKE SELECT ON SCHEMA::history  FROM readOnlyRole;
GRANT SELECT ON SCHEMA::logs      TO readOnlyRole;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logsData TO readOnlyRole;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::history  TO readOnlyRole;
GO

-- logsAuditReader
GRANT SELECT ON SCHEMA::logs     TO logsAuditReader;
GRANT SELECT ON SCHEMA::logsData TO logsAuditReader;
GRANT SELECT ON SCHEMA::history  TO logsAuditReader;
-- EXECUTE on the verifier specifically, not on SCHEMA::logs: the audit reader has to be able to check the subsystem's
-- posture, and that is the only module it needs.
GRANT EXECUTE ON logs.uspDdlAuditVerify TO logsAuditReader;
GO

-- INSERT, UPDATE and DELETE against history.* are already blocked by SQL Server itself while system versioning is on,
-- whatever the permissions say.  The DENY above matters only if versioning is ever paused for maintenance -- which is
-- exactly when it matters most.

-- The audit user.  It writes the base tables directly rather than through the views: it needs the state row under
-- UPDLOCK, HOLDLOCK, and SCOPE_IDENTITY() does not survive an INSTEAD OF trigger.  VIEW DEFINITION is not optional --
-- without it OBJECT_DEFINITION returns NULL and definitions are silently not captured.
GRANT VIEW DEFINITION TO [ddl_audit_user];
GRANT INSERT, SELECT         ON logsData.DdlChange       TO [ddl_audit_user];
GRANT INSERT, SELECT, UPDATE ON logsData.DdlObjectState TO [ddl_audit_user];
GRANT EXECUTE                ON logs.udfTableShape          TO [ddl_audit_user];
GO


-- *** 12. Baseline snapshot ***
-- Seeds the "before" image for objects that already exist, so that the first change recorded after deployment still
-- has a previous version to compare against.
--
-- Written to the base table, not through logs.DdlObjectState, for two reasons: the NOT EXISTS check has to see
-- soft-deleted state rows, which the view hides and which would then collide with the primary key; and the values the
-- audit block wants here (ORIGINAL_LOGIN, SYSUTCDATETIME, APP_NAME, HOST_NAME) are the right ones for a seed row.
-- AppSessionId is the one column with no default, and is legitimately NULL here -- this runs from a deployment, not
-- from an application session.
--
-- The timestamps and the *By columns are still written EXPLICITLY, from one variable each, rather than left to those
-- defaults.  UpdatedUtc and auditModifiedDateUtc are legacy twins, and section 5c's one-shot back-fill is guarded on
-- exactly that pair being equal.  Each column DEFAULT is a separate SYSUTCDATETIME() expression, evaluated
-- independently, into datetime2(3): they normally land in the same millisecond and are not required to.  When they do
-- not, the NEXT run of this file sees auditModifiedDateUtc <> UpdatedUtc across the whole baseline, fires the
-- back-fill, prints that it repaired N rows, and pushes one spurious version per row into
-- history.DdlObjectState -- the precise failure 12b's comment describes, reached by the one path 12b does not
-- cover.  It converges on the run after that, so the cost is a false history version and a second run that is not
-- silent; both are avoidable for the price of naming the columns.  DbApplication and HostName keep their defaults:
-- APP_NAME() and HOST_NAME() have no twin and no guard depends on them.
--
-- 12a seeds gaps only, which is what keeps a re-run silent.  12b then converges the handful of objects THIS FILE
-- replaces, which gap-filling cannot reach -- see the comment there.

DECLARE @BaseUtc datetime2(3)  = SYSUTCDATETIME (),
        @BaseBy  nvarchar(255) = ORIGINAL_LOGIN ();

-- 12a. Fill the gaps.
--
--      The type filter is not cosmetic.  OBJECT_DEFINITION returns text for D (default) and C (check) constraints as
--      well as for modules, so without it every DF_ and CK_ in the database got a state row that no DDL event will
--      ever update: constraint DDL reports the TABLE as ObjectName, not the constraint.  Harmless, but it buried the
--      rows that matter under hundreds that never change.
INSERT logsData.DdlObjectState
    (SchemaName, ObjectName, ObjectType, DefinitionKind, Definition,
     UpdatedUtc, auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc,
     auditDeletedBy, auditDeletedDateUtc)
SELECT      s.name,
            o.name,
            o.type_desc,
            'MODULE',
            OBJECT_DEFINITION (o.object_id),
            @BaseUtc, @BaseBy, @BaseUtc, @BaseBy, @BaseUtc,
            -- Never read while IsDeleted = 0, but a seed row may as well be internally consistent rather than carry a
            -- third independent instant.
            @BaseBy, @BaseUtc
FROM        sys.objects  o
INNER JOIN  sys.schemas  s  ON s.schema_id = o.schema_id
WHERE       o.is_ms_shipped = 0
  AND       o.type IN ('P', 'V', 'FN', 'IF', 'TF', 'TR')
  AND       OBJECT_DEFINITION (o.object_id) IS NOT NULL
  AND       NOT EXISTS (SELECT 1 FROM logsData.DdlObjectState t
                        WHERE t.SchemaName = s.name AND t.ObjectName = o.name);

INSERT logsData.DdlObjectState
    (SchemaName, ObjectName, ObjectType, DefinitionKind, Definition,
     UpdatedUtc, auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc,
     auditDeletedBy, auditDeletedDateUtc)
SELECT      s.name,
            o.name,
            o.type_desc,
            'TABLE_SHAPE',
            logs.udfTableShape (o.object_id),
            @BaseUtc, @BaseBy, @BaseUtc, @BaseBy, @BaseUtc,
            @BaseBy, @BaseUtc
FROM        sys.tables   o
INNER JOIN  sys.schemas  s  ON s.schema_id = o.schema_id
WHERE       o.is_ms_shipped = 0
  AND       NOT EXISTS (SELECT 1 FROM logsData.DdlObjectState t
                        WHERE t.SchemaName = s.name AND t.ObjectName = o.name);

-- PRINT takes a scalar expression only, so the count is assigned first.  This was a compile-level error in an earlier
-- version, which aborted the whole batch and stopped both seed INSERTs from running.
DECLARE @BaselineRows int;
SELECT  @BaselineRows = COUNT (*) FROM logsData.DdlObjectState;
PRINT   N'Baseline snapshot rows in logsData.DdlObjectState: ' + CONVERT (nvarchar(20), @BaselineRows);
GO

-- 12b. Converge the objects this file itself creates or replaces.
--
--      Gap-filling is correct everywhere else and wrong here.  On a database that already had logs.z_ddl_change as a
--      TABLE, its state row already exists, holding the definition of that table -- and this run has just replaced
--      that name with a view.  NOT EXISTS skips the row, so the next DDL event against that name would report
--      PriorDefinition as the pre-migration table shape and DefinitionChanged = 1 for a change that happened weeks
--      earlier under a different shape.  The "before" image is the one thing this subsystem exists to guarantee, and
--      it was wrong for exactly the objects the installer touched.
--
--      The 2026-09-17 rename makes the same point under new names: logsData.DdlChange is a NEW name to this table, so
--      12a seeds a state row for it, and the row that stood under logsData.z_ddl_change is retired by 12c.  Renaming
--      is the one kind of change this subsystem cannot follow on its own -- see "What this trigger does not cover" in
--      section 13 -- which is why the file that does the renaming has to say so here.
--
--      Scoped to the objects this file owns rather than to everything: a blanket converge would also rewrite state
--      rows for objects that legitimately drifted while auditing was off, which is a repair somebody should make
--      deliberately and not as a side effect of installing.
--
--      Both timestamp columns come from one variable.  auditModifiedDateUtc and its legacy twin UpdatedUtc must not
--      disagree -- section 5c's back-fill is guarded on exactly that pair being equal, and a row where they differ
--      gets re-updated on every subsequent run, pushing a spurious version into history.DdlObjectState each time.
DECLARE @SeedUtc   datetime2(3) = SYSUTCDATETIME (),
        @SeedBy    nvarchar(255) = ORIGINAL_LOGIN (),
        @SeedApp   nvarchar(255) = ISNULL (APP_NAME (), N''),
        @SeedHost  nvarchar(255) = ISNULL (HOST_NAME (), N'');

;WITH Owned (SchemaName, ObjectName, ObjectType, DefinitionKind, Definition) AS
(
    SELECT      s.name,
                o.name,
                o.type_desc,
                CASE WHEN o.type = 'U' THEN 'TABLE_SHAPE' ELSE 'MODULE' END,
                CASE WHEN o.type = 'U' THEN logs.udfTableShape (o.object_id)
                     ELSE OBJECT_DEFINITION (o.object_id) END
    FROM        sys.objects  o
    INNER JOIN  sys.schemas  s  ON s.schema_id = o.schema_id
    WHERE       (s.name = N'logs'     AND o.name IN (N'DdlChange', N'DdlObjectState',
                                                     N'udfTableShape', N'uspDdlAuditVerify'))
       OR       (s.name = N'logsData' AND o.name IN (N'DdlChange', N'DdlObjectState'))
       OR       (s.name = N'history'  AND o.name IN (N'DdlChange', N'DdlObjectState'))
)
UPDATE      t
SET         t.ObjectType           = o.ObjectType,
            t.DefinitionKind       = o.DefinitionKind,
            t.Definition           = o.Definition,
            t.IsDropped            = 0,
            t.UpdatedUtc           = @SeedUtc,
            t.auditModifiedBy      = @SeedBy,
            t.auditModifiedDateUtc = @SeedUtc,
            t.DbApplication        = @SeedApp,
            t.HostName             = @SeedHost,
            t.SqlSpid              = @@SPID
FROM        logsData.DdlObjectState AS t
INNER JOIN  Owned AS o  ON  o.SchemaName = t.SchemaName
                        AND o.ObjectName = t.ObjectName
WHERE       ISNULL (t.Definition, N'') <> ISNULL (o.Definition, N'')
   OR       t.DefinitionKind <> o.DefinitionKind
   OR       t.IsDropped      <> 0;

IF @@ROWCOUNT > 0
    PRINT N'Refreshed the state rows for the objects this script replaced.';
GO

-- 12c. Names that no longer exist: the two objects section 6 retired, and everything the 2026-09-17 rename in 4a and
--      5a left behind.  The DDL trigger is disabled while this file runs, so neither the DROPs nor the sp_renames are
--      recorded anywhere -- which would otherwise leave their state rows claiming the objects still exist, with a
--      definition that can no longer be produced.  Definition is deliberately kept: a definition that could not be
--      read never overwrites one that was, and the last known text is how a dropped object is recovered.
--
--      Both lists are filtered by the OBJECT_ID test at the bottom, so a name that is somehow still present is left
--      alone.  That is what makes it safe to list the old trigger names without checking whether the view they hung
--      off was actually dropped: the six of them go with their view, and if one did not, it is not flagged.
DECLARE @RetiredUtc  datetime2(3)  = SYSUTCDATETIME (),
        @RetiredBy   nvarchar(255) = ORIGINAL_LOGIN ();

;WITH Retired (SchemaName, ObjectName) AS
(
    SELECT SchemaName, ObjectName
    FROM   (VALUES
                -- section 6: the hash chain
                (N'logs',     N'z_ddl_change_verify')
              , (N'logs',     N'z_ddl_row_hash')
                -- 4a / 5a: the base tables and their history
              , (N'logsData', N'z_ddl_change')
              , (N'logsData', N'z_ddl_object_state')
              , (N'history',  N'z_ddl_change')
              , (N'history',  N'z_ddl_object_state')
                -- 4a / 5a: the wrapper views, the helper function and the verification procedure
              , (N'logs',     N'z_ddl_change')
              , (N'logs',     N'z_ddl_object_state')
              , (N'logs',     N'z_table_shape')
              , (N'logs',     N'z_ddl_audit_verify')
                -- and the six INSTEAD OF triggers that were dropped with the two views.  A DML trigger takes the
                -- schema of the object it is defined on, so all six sit under logs.
              , (N'logs',     N'trg_ioi_ins_z_ddl_change')
              , (N'logs',     N'trg_iov_updt_z_ddl_change')
              , (N'logs',     N'trg_iod_del_z_ddl_change')
              , (N'logs',     N'trg_ioi_ins_z_ddl_object_state')
              , (N'logs',     N'trg_iov_updt_z_ddl_object_state')
              , (N'logs',     N'trg_iod_del_z_ddl_object_state')
           ) AS v (SchemaName, ObjectName)
)
UPDATE      t
SET         IsDropped            = 1,
            UpdatedUtc           = @RetiredUtc,
            auditModifiedBy      = @RetiredBy,
            auditModifiedDateUtc = @RetiredUtc
FROM        logsData.DdlObjectState AS t
INNER JOIN  Retired AS r  ON  r.SchemaName = t.SchemaName
                          AND r.ObjectName = t.ObjectName
WHERE       t.IsDropped = 0
  AND       OBJECT_ID (QUOTENAME (t.SchemaName) + N'.' + QUOTENAME (t.ObjectName)) IS NULL;

IF @@ROWCOUNT > 0
    PRINT N'Flagged the retired and renamed-away objects as dropped in logsData.DdlObjectState.';
GO


-- *** 13. The trigger ***
-- These SET options are captured when the trigger is created and are required by the XML methods in the body.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   record_db_changes
Author:       rsincero
CreateDate:   2023-03-03
========================================================================================================================
Description:

Writes one row to logsData.DdlChange for every database-level DDL event.  Each row holds the statement that was run,
the identity of the person who ran it, the object definition as it stood immediately before the event, and the definition
as it stood immediately after.  The previous version of any object can therefore be recovered from PriorDefinition
without relying on a backup.

It also rolls logsData.DdlObjectState forward.  That table is system-versioned, so every definition it has ever held
is in history.DdlObjectState and can be read with FOR SYSTEM_TIME -- a second, independent copy of the same
evidence, arrived at by a different route.

========================================================================================================================
Requirements and Key Dependencies:

  logsData.DdlChange, logsData.DdlObjectState, logs.udfTableShape
  ddl_audit_user, holding the grants issued in section 11.  VIEW DEFINITION matters in particular: without it
  OBJECT_DEFINITION returns NULL and definitions are silently not captured.

Writes to the base tables, not to the views in logs.  Three reasons, all of them load-bearing: SCOPE_IDENTITY() returns
NULL in the caller's scope after an insert through an INSTEAD OF trigger, and @ChangeId is needed for
DdlObjectState.LastChangeId; the state row must be read under UPDLOCK, HOLDLOCK, which is a base-table concern; and
the audit columns on this path are deliberately NOT caller-overridable -- the view's INSERT contract allows an explicit
auditCreatedBy, which is right for a migration and wrong for the trigger that records who ran the DDL.

========================================================================================================================
Notes:

@FailClosed controls what happens when the audit write fails.  It is set to 1 below.

  1  The DDL statement is rolled back.  No object changes without a matching audit row.  The cost is that a problem
     with the audit tables blocks all DDL in this database until it is fixed; the error text returned to the caller
     names the cause.
  0  The DDL statement is allowed to proceed and the failure is reported to the SQL Server error log on a best-effort
     basis.  This keeps deployments working at the price of unrecorded changes, which is the gap an audit trail is
     supposed to close.  Only set this to 0 with a monitor watching for the error-log entry.

Locking.  Earlier versions read the tail of the event log under UPDLOCK, HOLDLOCK to build a hash chain, which
serialised every DDL statement in the database.  The chain is gone -- system versioning records edits and deletions
instead -- so the only lock left is UPDLOCK, HOLDLOCK on the one state row for the object being changed.  Two developers
altering two different procedures no longer block each other.  The lock is still required: it is what stops two
concurrent events for the SAME object from both missing the row and both trying to insert it.

What this trigger does not cover:

  - Server-level events.  CREATE LOGIN, server role membership, linked servers and ALTER DATABASE are outside
    DDL_DATABASE_LEVEL_EVENTS.  They need a separate ON ALL SERVER trigger or SQL Server Audit.
  - Other databases.  This trigger is scoped to the database it is created in.
  - Encrypted modules.  OBJECT_DEFINITION returns NULL for WITH ENCRYPTION, so only CommandText is captured.
  - Renames.  sp_rename leaves the state row under the old name; the new name gets a fresh state row on its next event.
  - Anyone with sysadmin or db_owner, who can disable or drop this trigger, switch system versioning off and edit both
    tables, replace a base table with an object that discards inserts, or restore the database from an earlier backup.
    Temporal history makes an ordinary UPDATE or DELETE self-reporting -- for an append-only log, any row in
    history.DdlChange is a tamper report -- and logs.uspDdlAuditVerify reads exactly that.  It does not prevent any
    of it.  The only durable defence is a copy outside this instance, held by someone other than the people being
    audited: read logsData.DdlChange from a job on another instance on a ChangeId watermark and keep the highest
    ChangeId seen, so a later gap is itself evidence.

  Statistics maintenance raises CREATE_STATISTICS and UPDATE_STATISTICS events, which are captured like anything else.
  If that volume becomes a problem, filter on EventType when querying rather than narrowing the event group, so the
  events are still on record.

========================================================================================================================
ExampleUsage and Performance:

-- every change to one procedure, newest first, with the version that was in place beforehand
select      ChangeId, EventTimeServer, EventType, OriginalLogin, HostName, DbApplication, CommandText, PriorDefinition
from        logs.DdlChange
where       SchemaName = 'util'
  and       ObjectName = 'uspSetObjectDescription'
order by    ChangeId desc;

-- recover the definition that was in place before a specific change
select      PriorDefinition
from        logs.DdlChange
where       ChangeId = 1234;

-- the same answer from the other side, out of temporal history
select      Definition, SysStartTime, SysEndTime
from        logsData.DdlObjectState for system_time all
where       SchemaName = 'util' and ObjectName = 'uspSetObjectDescription'
order by    SysStartTime desc;

-- changes that actually altered a definition, by login, over the last 30 days
select      OriginalLogin, SchemaName, ObjectName, EventTimeServer, EventType
from        logs.DdlChange
where       DefinitionChanged = 1
  and       DefinitionKind = 'MODULE'
  and       EventTimeServer >= dateadd (day, -30, sysdatetime ())
order by    EventTimeServer desc;

-- every login that has ever changed objects in a schema, with a count
select      OriginalLogin, count (*) as Changes, max (EventTimeServer) as MostRecent
from        logs.DdlChange
where       SchemaName = 'util'
  and       DefinitionChanged = 1
group by    OriginalLogin
order by    Changes desc;

-- confirm the log has not been edited or thinned out, and that versioning is still on
exec        logs.uspDdlAuditVerify;

Performance: one row per DDL event, written inside the DDL statement's own transaction, plus one row per event to
history.DdlObjectState.  Locking is per-object rather than per-database; see the note above.

========================================================================================================================
Modification History:
Date        Author          Ticket          Description
----------  --------------- -----------     ----------------------------------------------------------------------------
2023-03-03  rsincero        N/A             Initial creation
2025-11-10  rsincero        N/A             Added header, added ddl_audit_user usage.  Added ObjectType,
                                            ObjectName, SchemaName columns.  Added try/catch block.
2025-11-20  rsincero        N/A             Added AuditSavePoint, XACT_ABORT OFF, and tested logging to SQL Server Logs.
2026-09-12  rsincero        N/A             Rewrite.  Captures the definition before and after each change and keeps a
                                            per-object state row to source it from.  Execution context changed to a
                                            loginless user.  Identity now recorded from ORIGINAL_LOGIN rather than
                                            CURRENT_USER.  Audit failure now fails closed by default.  Added hash
                                            chaining and logs.z_ddl_change_verify.  Fixed the RAISERROR call, the NULL
                                            defaults on NOT NULL columns, and the name truncation on principal columns.
2026-09-12  rsincero        N/A             Temporal conversion.  Base tables moved to logsData and system-versioned
                                            into history; writes retargeted from logs.* to logsData.*.  Hash chaining
                                            removed -- superseded by temporal history -- along with the tail lock it
                                            required, so DDL is no longer serialised database-wide.  Now populates the
                                            standard audit block and the session columns (AppSessionId, SqlSpid).
2026-09-13  rsincero        N/A             Code review.  The trigger is now DISABLED for the duration of an install
                                            rather than dropped at the top and recreated 1,600 lines later, and the
                                            execution-context user is created only when missing rather than dropped
                                            and recreated.  The fail-closed ROLLBACK is guarded on XACT_STATE(), as
                                            the fail-open one already was.  Elsewhere in the file: HostName added to
                                            the 4c migration list, every audit column guarded on its own name,
                                            DbApplication's default wrapped in ISNULL, applicationRole's schema-wide EXECUTE
                                            revoked, the baseline snapshot made to converge for the objects this file
                                            replaces, and the immutable-key rejections changed from RAISERROR+RETURN
                                            to THROW 50010.
***********************************************************************************************************************/
CREATE OR ALTER TRIGGER record_db_changes
ON DATABASE
WITH EXECUTE AS 'ddl_audit_user'
FOR DDL_DATABASE_LEVEL_EVENTS
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;     -- lets the CATCH block below decide what happens, rather than aborting on the first error

    -- 1 = an audit failure rolls back the DDL.  0 = the DDL proceeds and the failure goes to the error log.
    DECLARE @FailClosed bit = 1;

    DECLARE @Event xml = EVENTDATA ();

    IF @Event IS NULL
        RETURN;

    DECLARE @EventType          nvarchar(128),
            @ObjectTypeEvent    nvarchar(128),
            @SchemaName         sysname,
            @ObjectName         sysname,
            @CommandText        nvarchar(max),
            @EventTimeServer    datetime2(3),
            @Spid               int,
            @EventLoginName     sysname,
            @EventDatabaseUser  sysname,
            @ObjectId           int,
            @NewDefinition      nvarchar(max),
            @PriorDefinition    nvarchar(max),
            @DefinitionKind     varchar(20) = 'NONE',
            @PriorKind          varchar(20),
            @ChangeId           bigint,
            @RecordedUtc        datetime2(3)  = SYSUTCDATETIME (),
            @OriginalLogin      sysname       = ISNULL (ORIGINAL_LOGIN (), N''),
            @AppSessionId       nvarchar(128) = CAST (SESSION_CONTEXT (N'AppSessionId') AS nvarchar(128)),
            @ErrMsg             nvarchar(2044);

    -- Only needed by the fail-open path.  SAVE TRANSACTION is not valid inside a distributed transaction, so it is
    -- issued only when it will actually be used.
    IF @FailClosed = 0
        SAVE TRANSACTION AuditSavePoint;

    BEGIN TRY

        SET @EventType          = @Event.value ('(/EVENT_INSTANCE/EventType)[1]',                 'NVARCHAR(128)');
        SET @ObjectTypeEvent    = @Event.value ('(/EVENT_INSTANCE/ObjectType)[1]',                'NVARCHAR(128)');
        SET @SchemaName         = @Event.value ('(/EVENT_INSTANCE/SchemaName)[1]',                'SYSNAME');
        SET @ObjectName         = @Event.value ('(/EVENT_INSTANCE/ObjectName)[1]',                'SYSNAME');
        SET @CommandText        = @Event.value ('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]',   'NVARCHAR(MAX)');
        SET @EventTimeServer    = @Event.value ('(/EVENT_INSTANCE/PostTime)[1]',                  'DATETIME2(3)');
        SET @Spid               = @Event.value ('(/EVENT_INSTANCE/SPID)[1]',                      'INT');
        SET @EventLoginName     = @Event.value ('(/EVENT_INSTANCE/LoginName)[1]',                 'SYSNAME');
        SET @EventDatabaseUser  = @Event.value ('(/EVENT_INSTANCE/UserName)[1]',                  'SYSNAME');

        -- Definition as it stands now, after the event.  NULL for a DROP, since the object is already gone, and NULL
        -- for events that are not about a single schema-scoped object.
        IF @SchemaName IS NOT NULL AND @ObjectName IS NOT NULL
        BEGIN
            SET @ObjectId = OBJECT_ID (QUOTENAME (@SchemaName) + N'.' + QUOTENAME (@ObjectName));

            IF @ObjectId IS NOT NULL
            BEGIN
                SET @NewDefinition = OBJECT_DEFINITION (@ObjectId);

                IF @NewDefinition IS NOT NULL
                    SET @DefinitionKind = 'MODULE';
                ELSE IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = @ObjectId)
                BEGIN
                    SET @NewDefinition  = logs.udfTableShape (@ObjectId);
                    SET @DefinitionKind = 'TABLE_SHAPE';
                END
            END

            -- Definition as it stood before the event.  This is the whole point of logsData.DdlObjectState: for a
            -- DROP or an ALTER, the previous text is no longer available anywhere else.  UPDLOCK, HOLDLOCK is scoped to
            -- this one object's row -- enough to stop two concurrent events for the same object from both deciding the
            -- row is missing, and no wider than that.
            SELECT      @PriorDefinition = s.Definition,
                        @PriorKind       = s.DefinitionKind
            FROM        logsData.DdlObjectState s WITH (UPDLOCK, HOLDLOCK)
            WHERE       s.SchemaName = @SchemaName
              AND       s.ObjectName = @ObjectName;

            IF @DefinitionKind = 'NONE' AND @PriorKind IS NOT NULL
                SET @DefinitionKind = @PriorKind;
        END

        INSERT INTO logsData.DdlChange
        (
            EventTimeServer, EventType, ObjectType, SchemaName, ObjectName, CommandText, Spid,
            EventLoginName, EventDatabaseUser, EventXml,
            DefinitionKind, PriorDefinition, NewDefinition, DefinitionChanged,
            RecordedUtc, OriginalLogin, SessionLogin,
            auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc,
            AppSessionId
            /* ProgramName, DbApplication, HostName, IsDeleted, auditDeleted*, SqlSpid take their column defaults.
               Those are APP_NAME(), HOST_NAME(), @@SPID and constants -- connection-level or literal, none of them
               affected by EXECUTE AS -- and ORIGINAL_LOGIN() likewise reports the person who ran the DDL rather than
               this trigger's execution context.

               SessionLogin is the exception, which is why it is written explicitly below instead of being left in this
               list.  Its default is ISNULL (SUSER_SNAME (), N''), and SUSER_SNAME() is exactly what
               WITH EXECUTE AS 'ddl_audit_user' replaces: on this path it reports the audit user, or an empty
               string because that user is loginless.  Either way it is a fact about the trigger, not about the caller,
               and leaving it to the default put a value in an audit column that a reader would take for evidence of
               impersonation by the person being audited. */
        )
        VALUES
        (
            @EventTimeServer, @EventType, @ObjectTypeEvent, @SchemaName, @ObjectName, @CommandText, @Spid,
            @EventLoginName, @EventDatabaseUser, @Event,
            @DefinitionKind, @PriorDefinition, @NewDefinition,
            CASE WHEN ISNULL (@PriorDefinition, N'') <> ISNULL (@NewDefinition, N'') THEN 1 ELSE 0 END,
            @RecordedUtc, @OriginalLogin,
            -- Empty, deliberately, and not SUSER_SNAME().  The effective login cannot be captured here: EVENTDATA()
            -- does not carry it, and by the time this body runs the context has already been switched, so there is no
            -- earlier point in the trigger to read it from.  An empty string says "not captured on this path", which is
            -- true; the audit user's name would say "the caller was impersonating", which is not.  EventLoginName holds
            -- the payload's own view of who connected, and OriginalLogin holds the one to trust.
            N'',
            -- The audit pair and its legacy twin are written from the same two variables, and here they are exactly
            -- equal rather than merely same-sourced: @OriginalLogin is declared sysname, so the value that reaches
            -- nvarchar(255) auditCreatedBy is already the one OriginalLogin holds and there is nothing left to
            -- truncate.  ORIGINAL_LOGIN () returns sysname, so no name is lost.  Section 4c's back-fill guard tests
            -- this pair for equality; it holds on this path unconditionally.
            @OriginalLogin, @RecordedUtc, @OriginalLogin, @RecordedUtc,
            @AppSessionId
        );

        SET @ChangeId = SCOPE_IDENTITY ();

        -- Roll the state row forward so the next event has a correct "before" image.  A definition that could not be
        -- read is never allowed to overwrite one that was: on a DROP, or when OBJECT_DEFINITION came back empty, the
        -- last known text is kept and the row is flagged instead.
        --
        -- Every UPDATE here writes the superseded row to history.DdlObjectState.  The audit columns have to be set
        -- explicitly: a column DEFAULT fires on INSERT only.
        IF @SchemaName IS NOT NULL AND @ObjectName IS NOT NULL
        BEGIN
            UPDATE      logsData.DdlObjectState
            SET         ObjectType           = ISNULL (@ObjectTypeEvent, ObjectType),
                        DefinitionKind       = CASE WHEN @NewDefinition IS NOT NULL THEN @DefinitionKind ELSE DefinitionKind END,
                        Definition           = CASE WHEN @NewDefinition IS NOT NULL THEN @NewDefinition ELSE Definition END,
                        IsDropped            = CASE WHEN @ObjectId IS NULL THEN 1 ELSE 0 END,
                        LastChangeId         = @ChangeId,
                        UpdatedUtc           = @RecordedUtc,
                        auditModifiedBy      = @OriginalLogin,
                        auditModifiedDateUtc = @RecordedUtc,
                        DbApplication        = ISNULL (APP_NAME (), N''),
                        HostName             = ISNULL (HOST_NAME (), N''),
                        AppSessionId         = @AppSessionId,
                        SqlSpid              = @@SPID
            WHERE       SchemaName = @SchemaName
              AND       ObjectName = @ObjectName;

            IF @@ROWCOUNT = 0
                INSERT logsData.DdlObjectState
                    (SchemaName, ObjectName, ObjectType, DefinitionKind, Definition, IsDropped, LastChangeId,
                     UpdatedUtc, auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc,
                     AppSessionId)
                VALUES
                    (@SchemaName, @ObjectName, @ObjectTypeEvent, @DefinitionKind, @NewDefinition,
                     CASE WHEN @ObjectId IS NULL THEN 1 ELSE 0 END, @ChangeId,
                     @RecordedUtc, @OriginalLogin, @RecordedUtc, @OriginalLogin, @RecordedUtc,
                     @AppSessionId);
        END

    END TRY
    BEGIN CATCH

        SET @ErrMsg = N'DDL audit failed. Event: ' + ISNULL (@EventType, N'(unknown)')
                    + N'. Object: ' + ISNULL (QUOTENAME (@SchemaName), N'(no schema)')
                    + N'.' + ISNULL (QUOTENAME (@ObjectName), N'(no object)')
                    + N'. Login: ' + @OriginalLogin
                    + N'. Error ' + ISNULL (CONVERT (nvarchar(20), ERROR_NUMBER ()), N'?')
                    + N' at line ' + ISNULL (CONVERT (nvarchar(20), ERROR_LINE ()), N'?')
                    + N': ' + ISNULL (ERROR_MESSAGE (), N'(no message)');

        IF @FailClosed = 1
        BEGIN
            -- The message is raised first so the caller is told why, then the transaction is rolled back, which undoes
            -- the DDL.  The caller also receives error 3609 because the transaction ended inside a trigger.
            RAISERROR (N'%s', 16, 1, @ErrMsg);

            -- Guarded, as the fail-open branch below already is.  ROLLBACK TRANSACTION with no active transaction
            -- raises 3903 from inside the CATCH, and that error -- not the one just composed -- is what the caller
            -- would see, so the single description of what actually failed is the thing that gets lost.
            IF XACT_STATE () <> 0
                ROLLBACK TRANSACTION;
        END
        ELSE
        BEGIN
            IF XACT_STATE () = 1
                ROLLBACK TRANSACTION AuditSavePoint;    -- discard the failed audit write, keep the DDL

            -- Best effort only.  WITH LOG needs ALTER TRACE or sysadmin in the execution context, which a loginless
            -- user does not have, so this is expected to fall through to PRINT on most instances.  Severity 10 is used
            -- deliberately: a higher severity inside TRY would transfer control to the CATCH and tell us nothing about
            -- whether the write succeeded.
            BEGIN TRY
                RAISERROR (N'%s', 10, 1, @ErrMsg) WITH LOG;
            END TRY
            BEGIN CATCH
                PRINT @ErrMsg;
            END CATCH

            -- If XACT_STATE() is -1 the transaction is already doomed and the DDL will roll back regardless.
        END

    END CATCH
END
GO

PRINT N'record_db_changes created. Audit failure behaviour: fail closed (see @FailClosed in the trigger body).';
GO


/***********************************************************************************************************************
   *** 14. Extended properties ***

MS_Description on both tables, on every one of their columns, on the two views, on the six INSTEAD OF triggers and on
the two modules.  Always through util.uspSetObjectDescription, which adds or updates: sp_addextendedproperty fails on
the second run ("Property already exists") and sp_updateextendedproperty fails on the first, so neither is re-runnable
on its own.

The database-scoped record_db_changes is the one object here that gets none, and cannot: an extended property is
addressed through a schema and a parent object, and a DDL trigger on DATABASE has neither.  Its header block is where
its documentation lives.

Driven from a table of values rather than written out as one EXEC per column.  Sixty-odd descriptions as separate
six-line EXEC blocks would be four hundred lines of near-identical text in a file that already has a job to do, and the
audit block's wording is identical on both tables.  The helper is still the only thing that touches
sys.extended_properties.

Skipped in full when util.uspSetObjectDescription is not in the database: this file is run against databases that do not
have the util helpers, and the audit subsystem must still deploy there.  Descriptions for a column that does not exist
in this database -- the two retired hash columns, present only where they were migrated -- are skipped the same way.
***********************************************************************************************************************/

IF OBJECT_ID (N'util.uspSetObjectDescription', N'P') IS NULL
    PRINT N'util.uspSetObjectDescription not found; MS_Description descriptions skipped. Deploy the util helpers and re-run this file.';
GO

IF OBJECT_ID (N'util.uspSetObjectDescription', N'P') IS NOT NULL
BEGIN
    DECLARE @Descriptions TABLE
    (
        RowNo       int IDENTITY (1,1) PRIMARY KEY,
        SchemaName  sysname         not null,
        ObjectType  sysname         not null,
        ObjectName  sysname         not null,
        ColumnName  sysname             null,
        Description nvarchar(3750)  not null
    );

    -- The two tables ------------------------------------------------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logsData', N'TABLE', N'DdlChange', NULL, N'Append-only log of every database-level DDL event, one row per event, with the statement that was run and the object definition immediately before and after it. System-versioned into history.DdlChange, which should stay empty: a row there means an event row was updated or deleted. Read and write through logs.DdlChange.')
    , (N'logsData', N'TABLE', N'DdlChange', N'ChangeId', N'Surrogate key and the order events were recorded in. IDENTITY, so it never goes backwards -- a gap between two off-instance reads is evidence that rows were removed.')
    , (N'logsData', N'TABLE', N'DdlChange', N'EventTimeServer', N'PostTime from the event payload, in the server''s local time zone rather than UTC. Compare with RecordedUtc, which is UTC and is taken independently of the payload.')
    , (N'logsData', N'TABLE', N'DdlChange', N'EventType', N'DDL event type from the payload, e.g. ALTER_PROCEDURE, CREATE_TABLE, UPDATE_STATISTICS. Filter on this rather than narrowing the trigger''s event group, so the noisy events stay on record.')
    , (N'logsData', N'TABLE', N'DdlChange', N'ObjectType', N'Object type from the event payload, e.g. PROCEDURE, TABLE, VIEW. Payload-sourced, so it can be NULL for events that are not about a single schema-scoped object.')
    , (N'logsData', N'TABLE', N'DdlChange', N'SchemaName', N'Schema of the object the event was about. NULL for events with no single schema-scoped object.')
    , (N'logsData', N'TABLE', N'DdlChange', N'ObjectName', N'Name of the object the event was about. NULL for events with no single schema-scoped object. sp_rename is not tracked: the old name keeps its state row and the new name gets a fresh one.')
    , (N'logsData', N'TABLE', N'DdlChange', N'CommandText', N'The full statement that fired the trigger, verbatim. The only definition captured for an encrypted module, since OBJECT_DEFINITION returns NULL for WITH ENCRYPTION.')
    , (N'logsData', N'TABLE', N'DdlChange', N'Spid', N'Session id from the event payload. SqlSpid holds @@SPID as observed inside the trigger; the two are normally equal and a difference is worth investigating.')
    , (N'logsData', N'TABLE', N'DdlChange', N'EventLoginName', N'Server-level login from the event payload. Payload-sourced; OriginalLogin is the same fact captured independently and is the one to trust.')
    , (N'logsData', N'TABLE', N'DdlChange', N'EventDatabaseUser', N'Database-level user from the event payload.')
    , (N'logsData', N'TABLE', N'DdlChange', N'EventXml', N'The complete EVENTDATA() payload, kept so a field nobody has needed yet can still be recovered without re-running anything.')
    , (N'logsData', N'TABLE', N'DdlChange', N'DefinitionKind', N'What PriorDefinition and NewDefinition hold: MODULE (OBJECT_DEFINITION text), TABLE_SHAPE (logs.udfTableShape rendering), or NONE (no definition applies to this event).')
    , (N'logsData', N'TABLE', N'DdlChange', N'PriorDefinition', N'The object definition as it stood immediately BEFORE this event, taken from logsData.DdlObjectState. This is what lets a previous version be recovered without a backup. NULL when the object had no prior state row.')
    , (N'logsData', N'TABLE', N'DdlChange', N'NewDefinition', N'The object definition as it stood immediately AFTER this event. NULL for a DROP, since the object is already gone, and for an encrypted module.')
    , (N'logsData', N'TABLE', N'DdlChange', N'DefinitionChanged', N'1 when PriorDefinition and NewDefinition differ. Filter on this to separate real changes from re-deployments of identical text and from statistics events.')
    , (N'logsData', N'TABLE', N'DdlChange', N'RecordedUtc', N'UTC time the audit row was written, captured inside the trigger rather than from the payload. Legacy name for auditCreatedDateUtc; both columns are datetime2 (3), are written from the same value, and are always exactly equal.')
    , (N'logsData', N'TABLE', N'DdlChange', N'OriginalLogin', N'ORIGINAL_LOGIN() of the session that ran the DDL. Unaffected by EXECUTE AS, so it identifies the person even though the trigger runs as ddl_audit_user. Legacy name for auditCreatedBy; both are written from the same value, but this column is sysname (128) against the audit column''s nvarchar(255), so on a row inserted through logs.DdlChange with a longer name it holds the first 128 characters. Compare against LEFT (auditCreatedBy, 128), never against auditCreatedBy itself.')
    , (N'logsData', N'TABLE', N'DdlChange', N'SessionLogin', N'SUSER_SNAME() at the time of the write -- the effective login, which differs from OriginalLogin when the caller had switched context. EMPTY on every row written by record_db_changes: that trigger runs WITH EXECUTE AS a loginless user, so SUSER_SNAME() there describes the trigger and not the caller, and the column is written as an empty string rather than being allowed to look like evidence of impersonation. Meaningful only on rows inserted through logs.DdlChange, i.e. migrations and back-fills. Use OriginalLogin for who ran the DDL.')
    , (N'logsData', N'TABLE', N'DdlChange', N'ProgramName', N'APP_NAME() of the connection. Legacy name for DbApplication; both are written from the same value, but this column is nvarchar(128) against the audit column''s nvarchar(255), so a longer application name is truncated here. Compare against LEFT (DbApplication, 128). Kept for existing consumers, not for new code.')
    , (N'logsData', N'TABLE', N'DdlObjectState', NULL, N'Current definition of every schema-scoped object, as the audit subsystem last saw it. Source of the "before" image on the next DDL event. System-versioned into history.DdlObjectState, so every definition it has ever held is recoverable with FOR SYSTEM_TIME. Read and write through logs.DdlObjectState.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'SchemaName', N'Schema of the object. Part of the clustered primary key and immutable through the view.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'ObjectName', N'Name of the object. Part of the clustered primary key and immutable through the view. A renamed object leaves this row under the old name and gets a new row on its next DDL event.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'ObjectType', N'type_desc of the object, e.g. SQL_STORED_PROCEDURE, USER_TABLE. Kept from the last event that reported one.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'DefinitionKind', N'What Definition holds: MODULE (OBJECT_DEFINITION text), TABLE_SHAPE (logs.udfTableShape rendering), or NONE.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'Definition', N'The object''s current definition text. A definition that could not be read never overwrites one that was: on a DROP, or when OBJECT_DEFINITION comes back empty, the last known text is kept and IsDropped is set instead.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'IsDropped', N'1 when the object no longer exists. Definition still holds the last text it had, which is the point -- this is how a dropped object is recovered. Distinct from IsDeleted, which is about this audit row rather than the object it describes.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'LastChangeId', N'ChangeId of the most recent logsData.DdlChange row for this object. Not a foreign key: the event log is append-only and must never be constrained by working state.')
    , (N'logsData', N'TABLE', N'DdlObjectState', N'UpdatedUtc', N'UTC time this row last changed. Legacy name for auditModifiedDateUtc; both are written from the same value.');

    -- The audit block, worded once and applied to both tables ---------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description)
    SELECT N'logsData', N'TABLE', t.ObjectName, c.ColumnName, c.Description
      FROM (VALUES (N'DdlChange'), (N'DdlObjectState')) AS t (ObjectName)
     CROSS JOIN (VALUES
          (N'IsDeleted', N'Soft-delete flag. 1 = deleted, 0 = active. This database performs no hard deletes; the views in logs filter IsDeleted = 0. On DdlChange a value of 1 is a tamper indicator, reported by logs.uspDdlAuditVerify.')
        , (N'auditDeletedBy', N'Login that soft-deleted the row, from SESSION_CONTEXT(''AppUser'') where the application set it, otherwise ORIGINAL_LOGIN(). Meaningful when IsDeleted = 1. Caller-overridable on INSERT so a migration can carry the original value; not overridable on UPDATE or DELETE.')
        , (N'auditDeletedDateUtc', N'UTC time of the soft delete. Meaningful when IsDeleted = 1. Caller-overridable on INSERT only.')
        , (N'auditCreatedBy', N'Login that inserted the row, from SESSION_CONTEXT(''AppUser'') where the application set it, otherwise ORIGINAL_LOGIN(). Caller-overridable on INSERT, deliberately, so a migration keeps the original author; never written by an UPDATE.')
        , (N'auditCreatedDateUtc', N'UTC time the row was inserted. Caller-overridable on INSERT, deliberately, so a migration keeps the original timestamp; never written by an UPDATE.')
        , (N'auditModifiedBy', N'Login that last modified the row. Caller-overridable on INSERT, and the one audit column a caller may also set on UPDATE -- the trigger uses UPDATE(auditModifiedBy) to tell an explicit value from an unchanged one.')
        , (N'auditModifiedDateUtc', N'UTC time of the last modification. Caller-overridable on INSERT only; every UPDATE recomputes it from SYSUTCDATETIME(). The column DEFAULT fires on INSERT only, which is why the triggers set it explicitly.')
        , (N'DbApplication', N'APP_NAME() of the connection that wrote the row. Caller-overridable on INSERT only.')
        , (N'HostName', N'HOST_NAME() of the client that wrote the row. Never caller-overridable, on INSERT or UPDATE: it is the one identity column a caller cannot supply.')
        , (N'AppSessionId', N'Application session identifier, from SESSION_CONTEXT(''AppSessionId''). NULL when the writer set no session context -- a deployment or an ad-hoc SSMS batch. Never caller-overridable. Only the latest value is kept here; query the history table to follow every session that touched the row.')
        , (N'SqlSpid', N'@@SPID of the session that wrote the row. Never caller-overridable. On DdlChange compare with Spid, which is the same fact from the event payload.')
        , (N'SysStartTime', N'UTC time this version of the row became current. GENERATED ALWAYS and HIDDEN, so it is excluded from SELECT * and from the views -- name it explicitly, or read the history table.')
        , (N'SysEndTime', N'UTC time this version of the row stopped being current; 9999-12-31 23:59:59.999 for the current version. GENERATED ALWAYS and HIDDEN.')
     ) AS c (ColumnName, Description);

    -- The two retired hash columns, described only on a database that was migrated and still has them.  The loop below
    -- skips a row whose column does not exist, so no extra guard is needed here.
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logsData', N'TABLE', N'DdlChange', N'RowHash', N'RETIRED. SHA-256 over this row plus the previous row''s hash, from the tamper-evidence chain that system versioning replaced. NULL on every row written after the temporal conversion; earlier values are kept and are still verifiable by hand against a saved copy of logs.z_ddl_row_hash. Do not write it.')
    , (N'logsData', N'TABLE', N'DdlChange', N'PrevRowHash', N'RETIRED. The preceding row''s RowHash, which linked the chain so that removing a row broke it. NULL on every row written after the temporal conversion. Do not write it.');

    -- The views -----------------------------------------------------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logs', N'VIEW', N'DdlChange', NULL, N'Active rows of the DDL event log, over logsData.DdlChange with IsDeleted = 0 applied. The read and write path for everything except the record_db_changes trigger: the INSTEAD OF triggers on this view own the audit columns and turn DELETE into a soft delete. Takes the name the base table held before the temporal conversion, so existing queries did not change.')
    , (N'logs', N'VIEW', N'DdlObjectState', NULL, N'Active rows of the per-object definition state, over logsData.DdlObjectState with IsDeleted = 0 applied. Read this for what an object looks like now; read the base table FOR SYSTEM_TIME for what it looked like on a given date.');

    -- The six INSTEAD OF triggers -----------------------------------------------------------------------------------
    -- Rule 4 covers every object, and these six are where the audit semantics actually live -- an object whose
    -- behaviour a reader most needs described is a poor one to leave blank.  util.uspSetObjectDescription resolves a
    -- TRIGGER against its parent and reads the parent's own type from sys.objects, so a trigger on a VIEW is addressed
    -- correctly; SchemaName here is the trigger's schema, which for an INSTEAD OF trigger is the view's.
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logs', N'TRIGGER', N'trg_ioi_ins_DdlChange', NULL, N'Writes an INSERT against logs.DdlChange through to logsData.DdlChange. Resolves the audit columns, keeping any value the caller supplied so a history load stays honest, and stamps HostName, AppSessionId and SqlSpid from the session where a caller may not. Populates #ReturnedIdentity (InsertedId bigint) with every new ChangeId when the caller created that table, because SCOPE_IDENTITY() returns NULL through an INSTEAD OF trigger. Set-based; one INSERT per statement.')
    , (N'logs', N'TRIGGER', N'trg_iov_updt_DdlChange', NULL, N'Applies an UPDATE against logs.DdlChange to logsData.DdlChange. Recomputes every audit column from the session except auditModifiedBy, which the caller may set; auditCreatedBy and auditCreatedDateUtc are not in the SET list, so no update can rewrite who created a row. Setting IsDeleted = 1 here stamps auditDeleted* exactly as the DELETE trigger does. Rejects a change to ChangeId with THROW 50010, since the key is what correlates inserted to deleted. Every row it updates writes a row to history.DdlChange, which on an append-only log is itself the tamper report.')
    , (N'logs', N'TRIGGER', N'trg_iod_del_DdlChange', NULL, N'Turns a DELETE against logs.DdlChange into a soft delete: IsDeleted goes to 1, auditDeletedBy and auditDeletedDateUtc are stamped from the session, and the row leaves the view. No row is ever removed from logsData.DdlChange. On an append-only event log a soft-deleted row is a finding, and logs.uspDdlAuditVerify reports it.')
    , (N'logs', N'TRIGGER', N'trg_ioi_ins_DdlObjectState', NULL, N'Writes an INSERT against logs.DdlObjectState through to logsData.DdlObjectState, resolving the audit columns on the same rules as the DdlChange insert trigger. No #ReturnedIdentity branch: this table has no IDENTITY, the caller supplies the key. Set-based; one INSERT per statement.')
    , (N'logs', N'TRIGGER', N'trg_iov_updt_DdlObjectState', NULL, N'Applies an UPDATE against logs.DdlObjectState to logsData.DdlObjectState. Recomputes the audit columns from the session except auditModifiedBy; auditCreatedBy and auditCreatedDateUtc are not in the SET list. (SchemaName, ObjectName) is the key that correlates inserted to deleted, so it is immutable through the view -- a statement that changes it is rejected with THROW 50010, and a row is moved to a new name by inserting one, leaving the old row as the record of what that name used to hold.')
    , (N'logs', N'TRIGGER', N'trg_iod_del_DdlObjectState', NULL, N'Turns a DELETE against logs.DdlObjectState into a soft delete, stamping auditDeletedBy and auditDeletedDateUtc. The row leaves the view and stays in logsData with every version of it in history. A dropped object is recorded by setting IsDropped = 1, not by deleting its state row.');

    -- The two history tables ----------------------------------------------------------------------------------------
    -- SQL Server created these implicitly when section 2 switched versioning on, so neither has a CREATE anywhere in
    -- this file to hang a description off -- which is exactly how they came to be the only tables here without one.
    -- They are ordinary tables and take the property normally. Describe them, or the audit report at the bottom of
    -- templates/extended-properties.sql names them on every run against every database this is installed in. Their
    -- columns mirror the base tables' and are not described again.
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'history', N'TABLE', N'DdlChange', NULL, N'System-versioned history for logsData.DdlChange, written by SQL Server and never by an application. SHOULD BE EMPTY: the event log is append-only, so a row here means an event row was updated or deleted after the fact, and logs.uspDdlAuditVerify reports any row as a problem rather than as history. While versioning is on, SQL Server itself refuses INSERT, UPDATE and DELETE here.')
    , (N'history', N'TABLE', N'DdlObjectState', NULL, N'System-versioned history for logsData.DdlObjectState, written by SQL Server and never by an application. One row per superseded object definition, bounded by SysStartTime and SysEndTime -- this is what makes every definition an object has ever held recoverable with FOR SYSTEM_TIME, without a backup. Unlike history.DdlChange, rows here are expected and are the point. Query through FOR SYSTEM_TIME on logsData.DdlObjectState rather than directly.');

    -- The two modules -----------------------------------------------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logs', N'FUNCTION', N'udfTableShape', NULL, N'Renders a table''s structure -- columns, types, nullability, defaults, keys and indexes -- as deterministic text, so that a table can be diffed across DDL events the way a module''s definition can. Used by record_db_changes to fill PriorDefinition and NewDefinition when DefinitionKind is TABLE_SHAPE. Returns NULL for an object id that is not a table.')
    , (N'logs', N'PROCEDURE', N'uspDdlAuditVerify', NULL, N'Reports whether the DDL audit subsystem is intact: system versioning on both base tables, an empty history.DdlChange (any row there means an append-only event row was changed or removed), no soft-deleted event rows, the record_db_changes trigger present and enabled, all six INSTEAD OF triggers present and enabled, one owner across logs/logsData/history, and infinite history retention. Also prints the row-count and max-ChangeId watermark to compare against an off-instance copy. Replaces the retired hash-chain verifier logs.z_ddl_change_verify. Pass @ProblemsOnly = 1 to suppress the OK and INFO rows.');

    -- Apply ---------------------------------------------------------------------------------------------------------
    DECLARE @RowNo int = 1,
            @MaxRowNo int,
            @Sch sysname, @OTy sysname, @Obj sysname, @Col sysname, @Dsc nvarchar(3750);

    SELECT @MaxRowNo = MAX (RowNo) FROM @Descriptions;

    WHILE @RowNo <= @MaxRowNo
    BEGIN
        SELECT @Sch = SchemaName, @OTy = ObjectType, @Obj = ObjectName, @Col = ColumnName, @Dsc = Description
          FROM @Descriptions
         WHERE RowNo = @RowNo;

        -- Skip a column this database does not have: the retired hash columns exist only where they were migrated in.
        IF @Col IS NULL
            OR EXISTS (SELECT 1
                         FROM sys.columns
                        WHERE object_id = OBJECT_ID (QUOTENAME (@Sch) + N'.' + QUOTENAME (@Obj))
                          AND name      = @Col)
        BEGIN
            EXEC util.uspSetObjectDescription
                  @SchemaName  = @Sch
                , @ObjectType  = @OTy
                , @ObjectName  = @Obj
                , @ColumnName  = @Col
                , @Description = @Dsc;
        END

        SET @RowNo += 1;
    END

    PRINT N'MS_Description applied to logsData.DdlChange, logsData.DdlObjectState, the logs views, the six INSTEAD OF triggers and the two logs modules.';
END
GO

-- *** 15. Re-enable the DDL trigger, and report ***

-- Section 3 disabled it so this file would not audit its own install.  Enabling it is the last thing that happens,
-- which is also what makes "a clean second run changes nothing" true: were the trigger live through section 14, every
-- re-run would append an event row per extended-property write.
--
-- Unconditional and idempotent -- ENABLE TRIGGER on an already-enabled trigger is a no-op.  A run that failed before
-- reaching this point leaves the trigger disabled, and disabled is a PROBLEM in the report immediately below.
ENABLE TRIGGER record_db_changes ON DATABASE;
PRINT N'record_db_changes enabled.';
GO

-- Prints where the subsystem stands, so a deployment does not have to be trusted on the strength of having run.

EXEC logs.uspDdlAuditVerify;
GO
