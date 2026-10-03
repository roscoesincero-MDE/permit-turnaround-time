
/***********************************************************************************************************************
Script:         checkDbChangeLogging.sql
Purpose:        Read-only pre-flight report on the DDL change-logging subsystem in the current database, and on the two
                application table shapes whose audit trail depends on an object the engine will not supply by itself.
                Answers one question -- is it here, is it complete, and is it current -- and prescribes the fix for
                anything it is not.  Changes nothing.

                The table-shape checks are here rather than in a file of their own so that there is a single health
                check to run, and because README.md's troubleshooting table already tells the reader this script names
                a missing or disabled audit trigger.
Target:         SQL Server 2022 -- the project floor, stated once in SKILL.md rule 6.  Nothing in this file needs
                anything newer than 2017, but do not re-declare a lower floor here: templates/procedure.sql uses
                LEAST(), which is 2022+, so a procedure built to this skill's conventions will not compile below it.
Run as:         Any principal with VIEW DEFINITION or membership of logsAuditReader.  A principal that cannot see
                catalog metadata reads a healthy database as an empty one, so do not run this as an application login.
Companion:      scripts/logdBChanges.sql applies everything this script reports as missing or out of date, and is safe
                to run against a database that is already correct.

Why this is all catalog queries
-------------------------------
Every check reads sys.* only.  Nothing here names a column of logsData.DdlChange in a FROM clause, deliberately: a
column reference is bound when the batch is compiled, not when the IF around it is evaluated, so one static SELECT
against a table that does not exist yet -- or that exists without the audit block -- would fail the whole report on
exactly the database that needs it most.

What a clean report does not prove
----------------------------------
That the audit trail is intact.  This script checks that the machinery is in place; logs.uspDdlAuditVerify checks
whether it has been tampered with (empty history on the append-only log, no soft-deleted event rows, versioning still
on).  Run both: this one before deploying, that one after, and from a monitoring job thereafter.

========================================================================================================================
Example Usage and Performance:

sqlcmd -S <server> -d <database> -I -C -i checkDbChangeLogging.sql

This file reads whichever database -d selected; it has no USE and no :setvar of its own, so there is nothing here to
get out of step with the command line.  Its companion does: logdBChanges.sql names its target in a :setvar and
asserts it before changing anything, so run that one as

    sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i logdBChanges.sql

Catalog reads only.  Milliseconds, no locks worth naming, safe on a production instance during business hours.

========================================================================================================================
Modification History:

Date:       2026-09-12
Author:     rsincero
Ticket:     N/A
Description:
Created, alongside the temporal conversion of the logging tables.

Date:       2026-09-13
Author:     rsincero
Ticket:     N/A
Description:
Code-review fixes.  Status now always agrees with Severity, and the summary counts the same buckets it prints.  Added
the INSTEAD OF trigger enablement check -- existence was being checked, enablement was not, on either side.  The
audit*By width check now tests against the standard 255 rather than 128.

Date:       2026-09-13
Author:     rsincero
Ticket:     N/A
Description:
Added the application table shape checks, which widens this file's scope past the change-logging subsystem: a plain
table carrying the audit block with no AFTER UPDATE trigger, one whose trigger is DISABLED, one whose trigger is named
off-convention, and a system-versioned base table sitting outside a *Data schema where it can never be given a view
wrapper.  README.md documented the first two as findings of this script before they were implemented.

-------------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

DECLARE @Findings TABLE
(
    -- Severity is the sort key AND the bucket the summary counts, so Status is written as a pure function of it:
    --   1  MISSING or DISABLED -- broken now
    --   2  STALE               -- present but out of date
    --   3  INFO or OPTIONAL    -- worth reading, not a fault
    --   4  OK
    -- They disagreed before: a missing applicationRole printed MISSING and was counted under "out of date", so the summary
    -- line and the lines above it could not be reconciled by anyone who tried.
    Severity  tinyint      not null,
    Status    varchar(10)  not null,
    Item      nvarchar(128) not null,
    Detail    nvarchar(1000) not null
);

/* ------------------------------------------------------------------------------------------------------------------
   Schemas
   ------------------------------------------------------------------------------------------------------------------ */
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'MISSING', N'schema ' + x.SchemaName,
       N'Schema does not exist. ' + x.Purpose + N' Run logdBChanges.sql section 2.'
  FROM (VALUES (N'logsData', N'Holds the system-versioned base tables.')
             , (N'history',  N'Holds the history tables the engine writes.')
             , (N'logs',     N'Holds the views, their INSTEAD OF triggers and the helper modules.')
       ) AS x (SchemaName, Purpose)
 WHERE SCHEMA_ID (x.SchemaName) IS NULL;

-- Ownership.  The views can only write to the base tables while all three schemas share an owner: an unbroken
-- ownership chain is what lets the caller hold permissions on the view alone.
IF NOT EXISTS (SELECT 1 FROM @Findings WHERE Item LIKE N'schema %')
BEGIN
    IF (SELECT COUNT (DISTINCT s.principal_id)
          FROM sys.schemas AS s
         WHERE s.name IN (N'logs', N'logsData', N'history')) > 1
        INSERT @Findings (Severity, Status, Item, Detail)
        VALUES (1, 'MISSING', N'schema ownership',
                N'logs, logsData and history do not share an owner, so ownership chaining is broken and writes '
              + N'through the views will fail on the base tables. Run logdBChanges.sql section 2.');
    ELSE
        INSERT @Findings (Severity, Status, Item, Detail)
        VALUES (4, 'OK', N'schema ownership', N'logs, logsData and history share an owner.');
END

/* ------------------------------------------------------------------------------------------------------------------
   Base tables: location, then system versioning, then the audit block
   ------------------------------------------------------------------------------------------------------------------ */
-- Still in logs, from before the temporal conversion.  ALTER SCHEMA TRANSFER moves it with its data and indexes.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', N'logs.' + t.name,
       N'Base table is still in the logs schema, where the view of the same name now belongs. logdBChanges.sql '
     + N'sections 4a and 5a transfer it to logsData with its data and indexes intact. Note that a TRANSFER discards '
     + N'the object''s permissions, which section 11 re-applies.'
  FROM sys.tables  AS t
  JOIN sys.schemas AS s ON s.schema_id = t.schema_id
 WHERE s.name = N'logs'
   AND t.name IN (N'DdlChange', N'DdlObjectState');

-- Present, absent, and versioned.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT CASE WHEN t.object_id IS NULL THEN 1 WHEN t.temporal_type <> 2 THEN 2 ELSE 4 END,
       CASE WHEN t.object_id IS NULL THEN 'MISSING' WHEN t.temporal_type <> 2 THEN 'STALE' ELSE 'OK' END,
       N'logsData.' + x.TableName,
       CASE WHEN t.object_id IS NULL
                 THEN N'Table does not exist. Run logdBChanges.sql.'
            WHEN t.temporal_type <> 2
                 THEN N'Table exists but is not system-versioned (temporal_type = '
                    + CONVERT (nvarchar(10), t.temporal_type) + N'). Changes to it are not being recorded. '
                    + N'logdBChanges.sql adds the period columns and turns versioning on additively -- no data moves.'
            ELSE N'System-versioned into ' + QUOTENAME (OBJECT_SCHEMA_NAME (t.history_table_id)) + N'.'
               + QUOTENAME (OBJECT_NAME (t.history_table_id)) + N'.'
       END
  FROM (VALUES (N'DdlChange'), (N'DdlObjectState')) AS x (TableName)
  LEFT JOIN sys.tables AS t ON t.object_id = OBJECT_ID (N'logsData.' + x.TableName)
                           AND t.object_id IS NOT NULL;

-- History retention.  A finite period silently deletes the oldest evidence, which is the evidence that matters.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', N'logsData.' + t.name + N' retention',
       N'History retention is finite (' + CONVERT (nvarchar(10), t.history_retention_period) + N' '
     + t.history_retention_period_unit_desc + N'). Set it to INFINITE: '
     + N'alter table logsData.' + t.name + N' set (system_versioning = on (history_table = history.' + t.name
     + N', history_retention_period = infinite));'
  FROM sys.tables  AS t
  JOIN sys.schemas AS s ON s.schema_id = t.schema_id
 WHERE s.name = N'logsData'
   AND t.temporal_type = 2
   AND ISNULL (t.history_retention_period, -1) <> -1;

-- The audit block, the session columns and the period columns, per table.  Reported as one row per table listing what
-- is absent, because a table missing the block is missing all of it and one finding per column would bury the report.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'MISSING', N'logsData.' + x.TableName + N' audit block',
       N'Missing column(s): ' + STRING_AGG (c.ColumnName, N', ') WITHIN GROUP (ORDER BY c.Ordinal)
     + N'. logdBChanges.sql adds them with a guarded ALTER TABLE ADD and back-fills the values once.'
  FROM (VALUES (N'DdlChange'), (N'DdlObjectState')) AS x (TableName)
 CROSS JOIN (VALUES (1, N'IsDeleted'), (2, N'auditDeletedBy'), (3, N'auditDeletedDateUtc')
                  , (4, N'auditCreatedBy'), (5, N'auditCreatedDateUtc')
                  , (6, N'auditModifiedBy'), (7, N'auditModifiedDateUtc')
                  , (8, N'DbApplication'), (9, N'HostName')
                  , (10, N'AppSessionId'), (11, N'SqlSpid')
                  , (12, N'SysStartTime'), (13, N'SysEndTime')
            ) AS c (Ordinal, ColumnName)
 WHERE OBJECT_ID (N'logsData.' + x.TableName) IS NOT NULL
   AND NOT EXISTS (SELECT 1
                     FROM sys.columns AS col
                    WHERE col.object_id = OBJECT_ID (N'logsData.' + x.TableName)
                      AND col.name      = c.ColumnName)
 GROUP BY x.TableName;

-- The standard width is nvarchar(255), and it is 255 rather than "128 or wider" because two separate things set the
-- floor and they are different numbers.  DEFAULT (ORIGINAL_LOGIN ()) returns sysname, so anything under 128 makes the
-- default itself raise a truncation error on a long domain login -- and the INSTEAD OF triggers resolve the *By
-- columns through CAST (SESSION_CONTEXT (N'AppUser') AS nvarchar(255)), which cannot land in a 128-wide column at
-- all.  255 is the only width that satisfies both, so 128 is reported as out of date rather than as acceptable.
-- The type is read with TYPE_NAME rather than assumed, and the declared width is computed from it: max_length is BYTES,
-- so it is halved for the Unicode types and taken as-is for the rest.  Dividing unconditionally by two is what made an
-- earlier version of this check report a varchar(255) column as "nvarchar(127)" -- a diagnosis that reads as nonsense
-- beside a remediation that was correct.  A non-Unicode column is still a finding here, and the reason it is one is the
-- CAST to nvarchar(255) in the triggers, not the width alone.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', N'logsData.' + OBJECT_NAME (col.object_id) + N'.' + col.name,
       N'Column is ' + TYPE_NAME (col.system_type_id) + N'(' + CONVERT (nvarchar(10), w.CharLen) + N')'
     + CASE WHEN col.system_type_id NOT IN (231, 239) THEN N', not Unicode, and' ELSE N',' END
     + N' narrower than the standard nvarchar(255). '
     + N'The INSTEAD OF triggers cast SESSION_CONTEXT (''AppUser'') to nvarchar(255) before writing it here. '
     + N'Widen it: alter table logsData.'
     + OBJECT_NAME (col.object_id) + N' alter column ' + col.name + N' nvarchar(255) not null;'
  FROM sys.columns AS col
 CROSS APPLY (VALUES (col.max_length / CASE WHEN col.system_type_id IN (231, 239) THEN 2 ELSE 1 END)) AS w (CharLen)
 WHERE col.object_id IN (OBJECT_ID (N'logsData.DdlChange'), OBJECT_ID (N'logsData.DdlObjectState'))
   AND col.name IN (N'auditCreatedBy', N'auditModifiedBy', N'auditDeletedBy', N'DbApplication', N'HostName')
   AND col.max_length >= 0                                    -- exclude the (max) types, reported as -1
   AND w.CharLen < 255;                                       -- in CHARACTERS, so varchar and nvarchar compare alike

/* ------------------------------------------------------------------------------------------------------------------
   Views, INSTEAD OF triggers and modules
   ------------------------------------------------------------------------------------------------------------------ */
INSERT @Findings (Severity, Status, Item, Detail)
SELECT CASE WHEN OBJECT_ID (x.QualifiedName, x.TypeCode) IS NULL THEN 1 ELSE 4 END,
       CASE WHEN OBJECT_ID (x.QualifiedName, x.TypeCode) IS NULL THEN 'MISSING' ELSE 'OK' END,
       x.QualifiedName,
       CASE WHEN OBJECT_ID (x.QualifiedName, x.TypeCode) IS NULL
                 THEN N'Does not exist. ' + x.Purpose + N' Run logdBChanges.sql.'
            ELSE x.Purpose
       END
  FROM (VALUES
      (N'logs.DdlChange',                    'V',  N'The read and write path for the event log; applies the IsDeleted = 0 filter and carries the INSTEAD OF triggers a temporal table cannot.')
    , (N'logs.DdlObjectState',              'V',  N'The read and write path for per-object definition state.')
    , (N'logs.trg_ioi_ins_DdlChange',        'TR', N'Resolves the audit columns on insert, keeping any value the caller supplied.')
    , (N'logs.trg_iov_updt_DdlChange',       'TR', N'Owns the audit columns on update; only auditModifiedBy is caller-overridable.')
    , (N'logs.trg_iod_del_DdlChange',        'TR', N'Turns DELETE into a soft delete. Without it a DELETE against the view fails.')
    , (N'logs.trg_ioi_ins_DdlObjectState',  'TR', N'As above, for object state.')
    , (N'logs.trg_iov_updt_DdlObjectState', 'TR', N'As above, for object state.')
    , (N'logs.trg_iod_del_DdlObjectState',  'TR', N'As above, for object state.')
    , (N'logs.udfTableShape',                   'FN', N'Renders a table''s structure as diffable text, so a table can be compared across events the way a module''s definition can.')
    , (N'logs.uspDdlAuditVerify',              'P',  N'Reports whether the audit trail has been tampered with. Run it after deploying and from a monitoring job.')
       ) AS x (QualifiedName, TypeCode, Purpose);

-- A view that exists but predates a column added to the base table returns a stale column list until it is recompiled.
-- CREATE OR ALTER in logdBChanges.sql handles it; this catches the case where only the table was patched by hand.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', N'logs.' + x.TableName + N' column list',
       N'The view does not project ' + CONVERT (nvarchar(10), COUNT (*)) + N' column(s) that exist on '
     + N'logsData.' + x.TableName + N', including ' + MIN (bc.name) + N'. Re-run logdBChanges.sql to recreate the view.'
  FROM (VALUES (N'DdlChange'), (N'DdlObjectState')) AS x (TableName)
  JOIN sys.columns AS bc ON bc.object_id = OBJECT_ID (N'logsData.' + x.TableName)
 WHERE OBJECT_ID (N'logs.' + x.TableName, 'V') IS NOT NULL
   AND bc.is_hidden = 0                                       -- period columns are HIDDEN and not projected, by design
   AND bc.name NOT IN (N'RowHash', N'PrevRowHash')            -- retired; the views do not project them, by design
   AND NOT EXISTS (SELECT 1
                     FROM sys.columns AS vc
                    WHERE vc.object_id = OBJECT_ID (N'logs.' + x.TableName)
                      AND vc.name      = bc.name)
 GROUP BY x.TableName;

-- Enablement, which existence does not imply.  A disabled INSTEAD OF trigger is invisible from the caller's side:
-- the view accepts the statement and the write lands on the base table.  What stops is the audit contract -- the
-- audit columns are no longer resolved on the way through, and a DELETE stops being a soft delete.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'DISABLED', N'logs.' + tr.name,
       N'The INSTEAD OF trigger exists but is DISABLED, so writes through the view bypass the audit contract: the '
     + N'audit columns stop being resolved and a DELETE stops soft-deleting. '
     + N'enable trigger logs.' + tr.name + N' on logs.' + OBJECT_NAME (tr.parent_id) + N';'
  FROM sys.triggers AS tr
 WHERE tr.parent_class = 1                    -- 1 = trigger on an object; 0 would be the database-scoped DDL trigger
   AND tr.parent_id IN (OBJECT_ID (N'logs.DdlChange'), OBJECT_ID (N'logs.DdlObjectState'))
   AND tr.is_disabled = 1;

/* ------------------------------------------------------------------------------------------------------------------
   The DDL trigger, the principal it runs as, and the roles
   ------------------------------------------------------------------------------------------------------------------ */
INSERT @Findings (Severity, Status, Item, Detail)
SELECT CASE WHEN tr.name IS NULL OR tr.is_disabled = 1 THEN 1 ELSE 4 END,
       CASE WHEN tr.name IS NULL THEN 'MISSING' WHEN tr.is_disabled = 1 THEN 'DISABLED' ELSE 'OK' END,
       N'record_db_changes',
       CASE WHEN tr.name IS NULL    THEN N'The database-level DDL trigger does not exist, so no DDL is being recorded '
                                       + N'at all. Run logdBChanges.sql.'
            WHEN tr.is_disabled = 1 THEN N'The trigger exists but is DISABLED. It records nothing and raises no error. '
                                       + N'enable trigger record_db_changes on database;'
            ELSE N'Exists and is enabled.'
       END
  FROM (SELECT 1 AS One) AS x
  LEFT JOIN sys.triggers AS tr ON tr.parent_class = 0 AND tr.name = N'record_db_changes';

-- Two of these four are required and two are not, and that distinction is now carried by Status as well as by
-- Severity: an absent optional role reads OPTIONAL and is not counted as a fault, rather than reading MISSING while
-- being counted as "out of date".
INSERT @Findings (Severity, Status, Item, Detail)
SELECT CASE WHEN DATABASE_PRINCIPAL_ID (x.PrincipalName) IS NOT NULL THEN 4
            WHEN x.Required = 1                                      THEN 1
            ELSE 3
       END,
       CASE WHEN DATABASE_PRINCIPAL_ID (x.PrincipalName) IS NOT NULL THEN 'OK'
            WHEN x.Required = 1                                      THEN 'MISSING'
            ELSE 'OPTIONAL'
       END,
       x.PrincipalName,
       CASE WHEN DATABASE_PRINCIPAL_ID (x.PrincipalName) IS NULL
                 THEN N'Does not exist. ' + x.Purpose
            ELSE x.Purpose
       END
  FROM (VALUES
      (N'ddl_audit_user', 1, N'The loginless user record_db_changes runs as. Without it the trigger cannot be created. Run logdBChanges.sql section 3.')
    , (N'logsAuditReader',     1, N'Role: SELECT across the subsystem, including soft-deleted and historical rows. Run logdBChanges.sql section 3.')
    , (N'applicationRole',              0, N'Role: CRUD on the views only. logdBChanges.sql sections 3 and 11 create it and grant to it; until an application writes through the views, nothing depends on it.')
    , (N'readOnlyRole',         0, N'Role: SELECT on the view schemas only -- dbo and logs. Denied on dboData, logsData and history like every other non-audit principal, because the views are what apply the IsDeleted filter. Optional by design -- skip it if nobody needs it.')
       ) AS x (PrincipalName, Required, Purpose);

/* ------------------------------------------------------------------------------------------------------------------
   Application table shapes: the plain table's audit trigger, and where a versioned table is allowed to live
   ------------------------------------------------------------------------------------------------------------------ */
-- This section is not about the change-logging subsystem.  It reads the application's own tables, and it is here rather
-- than in a file of its own for two reasons: there should be one health check to run, and README.md already tells the
-- reader that for a disabled audit trigger "the check script names it and prints the enable trigger line".  That was
-- documented before it was true.
--
-- What it does NOT check, deliberately: whether a table in a *Data schema has its view in dbo, and whether that view
-- carries all three INSTEAD OF triggers.  Both are worth having and neither is inferable from the catalog without
-- guessing at the naming relationship between a base table and its wrapper, which is a different kind of check from
-- the two below -- those follow from the engine's own rules rather than from a convention.

DECLARE @PlainTables TABLE (object_id int primary key, SchemaName sysname, TableName sysname);

INSERT @PlainTables (object_id, SchemaName, TableName)
SELECT t.object_id, s.name, t.name
  FROM sys.tables  AS t
  JOIN sys.schemas AS s ON s.schema_id = t.schema_id
 WHERE t.is_ms_shipped = 0
   AND t.temporal_type = 0            -- 0 = not versioned, 1 = a history table, 2 = a versioned base table
   AND s.name NOT LIKE N'%Data'
   AND s.name NOT IN (N'logs', N'history', N'util')
   -- The marker for a table this skill manages.  A table without the audit block is neither shape and is none of this
   -- section's business, which is also what keeps staging and scaffolding tables out of the report.
   AND EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = t.object_id AND c.name = N'IsDeleted')
   AND EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = t.object_id AND c.name = N'auditModifiedBy');

-- Absent.  On a plain table there is no view and no INSTEAD OF trigger to fall back on, so this trigger is the only
-- thing maintaining the trail: the audit column DEFAULTs fire on INSERT only.  Without it every UPDATE leaves
-- auditModifiedBy and auditModifiedDateUtc at their insert-time values, and a soft delete -- which on this shape can
-- only arrive as a bare UPDATE of IsDeleted, because DELETE is not granted on the schema -- records neither who nor when.
--
-- Tested for ANY enabled AFTER UPDATE trigger rather than for the conventional name, so a table whose trigger was named
-- something else is not reported as having none.  The naming is checked separately below, as a convention rather than a
-- fault, because the two need different remedies.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'MISSING', p.SchemaName + N'.' + p.TableName + N' audit trigger',
       N'Plain table carrying the audit block, with no AFTER UPDATE trigger. The audit column DEFAULTs fire on INSERT '
     + N'only, so every UPDATE leaves the trail stale and a soft delete records neither who nor when. Add section 4 of '
     + N'templates\table.sql, which creates ' + p.SchemaName + N'.trg_au_updt_' + p.TableName + N'.'
  FROM @PlainTables AS p
 WHERE NOT EXISTS (SELECT 1
                     FROM sys.triggers       AS tr
                     JOIN sys.trigger_events AS te ON te.object_id = tr.object_id
                    WHERE tr.parent_id = p.object_id
                      AND tr.is_instead_of_trigger = 0
                      AND te.type_desc = N'UPDATE');

-- Present and disabled, which is the worse of the two states: the table looks correct, the UPDATE succeeds, and the
-- audit columns quietly stop moving.  Same reasoning as the INSTEAD OF enablement check above, and the same remedy shape.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'DISABLED', p.SchemaName + N'.' + tr.name,
       N'The AFTER UPDATE audit trigger on ' + p.SchemaName + N'.' + p.TableName + N' exists but is DISABLED, so '
     + N'updates succeed while the audit columns stop being maintained. Nothing raises an error and nothing else on a '
     + N'plain table maintains them. enable trigger ' + p.SchemaName + N'.' + tr.name
     + N' on ' + p.SchemaName + N'.' + p.TableName + N';'
  FROM @PlainTables       AS p
  JOIN sys.triggers       AS tr ON tr.parent_id = p.object_id AND tr.is_instead_of_trigger = 0
  JOIN sys.trigger_events AS te ON te.object_id = tr.object_id AND te.type_desc = N'UPDATE'
 WHERE tr.is_disabled = 1;

-- Named off-convention.  Not a fault -- the trail is being maintained -- but SKILL.md rule 5 fixes the name as
-- trg_au_updt_<TableName> in the table's own schema, and README's troubleshooting table tells a reader to look for
-- exactly that.  A trigger under another name works and is harder to find.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', p.SchemaName + N'.' + p.TableName + N' trigger name',
       N'The AFTER UPDATE audit trigger is named ' + tr.name + N', not trg_au_updt_' + p.TableName
     + N'. It works; it is simply not where anyone following SKILL.md rule 5 or README''s troubleshooting table will '
     + N'look for it. Rename it: exec sys.sp_rename N''' + p.SchemaName + N'.' + tr.name + N''', N''trg_au_updt_'
     + p.TableName + N''';'
  FROM @PlainTables       AS p
  JOIN sys.triggers       AS tr ON tr.parent_id = p.object_id AND tr.is_instead_of_trigger = 0
  JOIN sys.trigger_events AS te ON te.object_id = tr.object_id AND te.type_desc = N'UPDATE'
 WHERE tr.name <> N'trg_au_updt_' + p.TableName;

-- A system-versioned base table outside a *Data schema.  This is a placement fault with a hard cause rather than a
-- stylistic one: a system-versioned table CANNOT carry an INSTEAD OF trigger, so its soft delete has to run through a
-- view -- and a view cannot share a name with the table inside one schema.  Left in dbo, the table has no wrapper and
-- no way to get one under its own name, so DELETE against it is a HARD delete for anyone holding the permission.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 1, 'MISSING', s.name + N'.' + t.name + N' placement',
       N'System-versioned base table in a schema that is not a *Data schema, so it has no view wrapper and cannot be '
     + N'given one under its own name -- a view and a table cannot share a name in one schema, and a versioned table '
     + N'cannot carry an INSTEAD OF trigger. A DELETE against it is therefore a hard delete. Move it and wrap it: '
     + N'alter schema ' + s.name + N'Data transfer ' + s.name + N'.' + t.name + N'; then build the view and its three '
     + N'INSTEAD OF triggers from templates\table-temporal.sql. A TRANSFER discards the object''s permissions, so '
     + N're-run scripts/permissions.sql afterwards.'
  FROM sys.tables  AS t
  JOIN sys.schemas AS s ON s.schema_id = t.schema_id
 WHERE t.is_ms_shipped = 0
   AND t.temporal_type = 2
   AND s.name NOT LIKE N'%Data'
   AND s.name NOT IN (N'logs', N'history', N'util')
   -- Gated on the same audit-block marker as the checks above, so this section reports on one population throughout:
   -- tables this skill manages.  Without the gate it would fire on any system-versioned table in the database -- an
   -- ORM's, a vendor's, someone's own -- and print a remedy telling the reader to move it and wrap it, which for a
   -- table that was never meant to have a soft-delete view is confident, specific, wrong advice. Missing it on an
   -- unmarked table is the better failure: a versioned table without the audit block is not this shape either way.
   AND EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = t.object_id AND c.name = N'IsDeleted')
   AND EXISTS (SELECT 1 FROM sys.columns AS c WHERE c.object_id = t.object_id AND c.name = N'auditModifiedBy');

-- One OK line rather than one per table, so a database with forty application tables does not bury the rest of the
-- report -- and so that a clean run still says the check ran.  Suppressed entirely when there is nothing of this shape,
-- because "0 plain tables are correct" reads like a fault and is not one.
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 4, 'OK', N'plain table audit triggers',
       N'All ' + CONVERT (nvarchar(10), COUNT (*)) + N' plain table(s) carrying the audit block have an enabled '
     + N'AFTER UPDATE trigger: ' + STRING_AGG (CONVERT (nvarchar(MAX), p.SchemaName + N'.' + p.TableName), N', ')
                                   WITHIN GROUP (ORDER BY p.SchemaName, p.TableName) + N'.'
  FROM @PlainTables AS p
 WHERE EXISTS (SELECT 1
                 FROM sys.triggers       AS tr
                 JOIN sys.trigger_events AS te ON te.object_id = tr.object_id
                WHERE tr.parent_id = p.object_id
                  AND tr.is_instead_of_trigger = 0
                  AND te.type_desc = N'UPDATE'
                  AND tr.is_disabled = 0)
HAVING COUNT (*) > 0
   AND COUNT (*) = (SELECT COUNT (*) FROM @PlainTables);

/* ------------------------------------------------------------------------------------------------------------------
   Retired objects still present, and the optional helper
   ------------------------------------------------------------------------------------------------------------------ */
INSERT @Findings (Severity, Status, Item, Detail)
SELECT 2, 'STALE', x.QualifiedName,
       N'Retired by the temporal conversion and still present. ' + x.Detail + N' logdBChanges.sql section 6 drops it.'
  FROM (VALUES
      (N'logs.z_ddl_change_verify', 'P',  N'The hash-chain verifier, superseded by logs.uspDdlAuditVerify.')
    , (N'logs.z_ddl_row_hash',      'FN', N'The hash function the chain was built on. System versioning now provides the tamper evidence it existed for.')
       ) AS x (QualifiedName, TypeCode, Detail)
 WHERE OBJECT_ID (x.QualifiedName, x.TypeCode) IS NOT NULL;

INSERT @Findings (Severity, Status, Item, Detail)
SELECT 3, 'INFO', N'util.uspSetObjectDescription',
       CASE WHEN OBJECT_ID (N'util.uspSetObjectDescription', N'P') IS NULL
                 THEN N'Not present, so logdBChanges.sql section 14 will skip the MS_Description descriptions and say '
                    + N'so. The audit subsystem deploys and works without it. Deploy templates/extended-properties.sql '
                    + N'and re-run to fill the descriptions in.'
            ELSE N'Present, so the descriptions on both tables, every column, both views and both modules will be '
               + N'applied or updated.'
       END;

/* ------------------------------------------------------------------------------------------------------------------
   Report
   ------------------------------------------------------------------------------------------------------------------ */
SELECT   Status, Item, Detail
  FROM   @Findings
 ORDER BY Severity ASC, Item ASC;

-- Counted off Severity, which Status is written from, so the two numbers below are exactly the lines printed above
-- with Status MISSING or DISABLED, and the lines with Status STALE.  OPTIONAL and INFO are neither.
DECLARE @Broken int = (SELECT COUNT (*) FROM @Findings WHERE Severity = 1),
        @Stale  int = (SELECT COUNT (*) FROM @Findings WHERE Severity = 2);

PRINT N'';
IF @Broken = 0 AND @Stale = 0
BEGIN
    PRINT N'Change logging is present and current, and the application table shapes checked here are sound.';
    PRINT N'Run: exec logs.uspDdlAuditVerify;  to check the trail itself.';
END
ELSE
BEGIN
    PRINT N'Findings: ' + CONVERT (nvarchar(10), @Broken) + N' missing or disabled, '
        + CONVERT (nvarchar(10), @Stale) + N' out of date or off-convention.';
    -- Two remedies, because this report now covers two things and only one of them has an installer. Naming
    -- logdBChanges.sql alone would send a reader to a script that cannot create an application table's audit trigger
    -- and would then report success while the finding stood.
    PRINT N'Fix, for anything in the logs / logsData / history schemas: run scripts/logdBChanges.sql against this';
    PRINT N'database (sqlcmd -I -C), then re-run this report. It is additive and re-runnable: nothing is dropped, no';
    PRINT N'data is discarded, and a clean second run changes nothing.';
    PRINT N'Fix, for a finding naming an application table: apply the Detail line above by hand. No installer owns your';
    PRINT N'tables, so logdBChanges.sql will not clear those and re-running it is not the remedy.';
END
GO
