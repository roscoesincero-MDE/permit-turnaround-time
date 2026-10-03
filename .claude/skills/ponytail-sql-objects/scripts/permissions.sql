/***********************************************************************************************************************
ObjectName:   scripts/permissions.sql
Author:       ponytail-sql-objects
CreateDate:   2026-09-13
========================================================================================================================
Description:

The database-wide role permissions: what applicationRole and readOnlyRole may do to each schema.  One file, so the whole
permission model can be read in one place instead of being reassembled from the installers and every table script.

Run it AFTER logdBChanges.sql and logExecutionLogging.sql, and BEFORE your own objects.  Order matters only because a
grant on SCHEMA::logs is pointless before the logs schema exists; nothing here fails on an object that is not there yet,
because a schema-scoped grant applies to objects created later, which is the whole reason it is schema-scoped.

========================================================================================================================
Requirements and Key Dependencies:

The roles applicationRole and readOnlyRole.  This file does NOT create them: which principals exist, and who is a member of
what, is a deployment decision and not a convention.  Every block below is guarded on the role existing -- but unlike the
guarded grants elsewhere in this skill, a missing role here is REPORTED rather than silently skipped, because a silently
skipped grant is how a deployed object ends up readable by nobody with no error to say why.

The schemas logs, logsData and history are created by logdBChanges.sql.  dboData and history are created by the first
table built from templates/table-temporal.sql.  A grant or deny against a schema that does not exist yet is skipped here
and reported; re-run this file after the schema appears.

========================================================================================================================
Notes:

WHY SCHEMA-SCOPED AND NOT PER TABLE.  A schema-scoped grant covers every object in the schema, including the ones not
written yet.  The alternative -- a grant block in every table script -- was the original design, and templates/table.sql
shipped without one, so a plain dbo table deployed from the skill's own template was readable by db_owner and by nobody
else.  Nothing failed: a missing grant raises no error at deploy time, it just makes the table invisible, and the object
does not even appear in Object Explorer because SQL Server hides metadata for objects a principal holds no permission
on.  That failure is silent, per table, and forever, which is why reads are now granted once at the schema.

DELETE IS NOT GRANTED ON SCHEMA::dbo, AND THAT IS THE POINT.  This database performs no hard deletes.  On the temporal
shape a DELETE is safe to grant because it lands on a view whose INSTEAD OF DELETE trigger turns it into IsDeleted = 1;
the row is never removed.  A PLAIN table has no such trigger, so DELETE against it is a genuine, unrecoverable hard
delete.  Soft-deleting a plain table's row is an UPDATE setting IsDeleted = 1, which the UPDATE grant below already
covers.  A view that needs DELETE gets it as an object-level grant in its own script -- see section 7 of
templates/table-temporal.sql.

AND THERE IS NO DENY DELETE ON SCHEMA::dbo, DELIBERATELY.  Withholding a permission and denying it are not the same
thing.  A schema-scoped DENY would sit above the object-scoped GRANT DELETE that every temporal view carries, and
whether a schema DENY beats an object GRANT is not a thing to bet a write path on -- DENY generally wins, which would
break every soft delete in the database.  Not granting DELETE is sufficient: with no grant at any scope, permission is
already refused.

EXECUTE IS NOT GRANTED HERE.  Every procedure carries its own GRANT EXECUTE in its own script, to the roles that
actually call it.  That stays per-procedure on purpose: a schema-wide EXECUTE would hand every role every procedure
written afterwards, including ones written for a different caller entirely.  The two logging procedures applicationRole must
reach are granted by logExecutionLogging.sql.

WHAT GRANTING SELECT ON SCHEMA::dbo ACTUALLY MEANS.  Every table and view in dbo, now and in future, becomes readable by
applicationRole and readOnlyRole.  If a dbo table is going to hold something not every application user may read, dbo is the
wrong schema for it -- put it in a data schema and expose a view, which is the pattern this skill is built around.  Do
not solve it with a column-level DENY on a dbo table; that is the one case where the precedence rules genuinely surprise
people, since a column-level GRANT overrides an object-level DENY.

THE DATA SCHEMAS ARE DENIED, NOT MERELY UNGRANTED.  dboData, logsData and history hold the base tables and the temporal
history behind the views.  Nothing outside a trigger or an ownership-chained procedure should touch them, and a DENY
says so where an absent grant only fails to say otherwise.  templates/table-temporal.sql issues the dboData deny as
well, so a table deployed before this file was ever run is still protected; re-issuing an identical DENY is a no-op.

RE-RUNNABLE.  GRANT and DENY are declarative -- applying one that is already in place changes nothing and raises
nothing.  There is no state to converge here, so no guards beyond the existence checks.  Nothing in this file revokes
anything: a REVOKE would silently strip a permission granted deliberately by hand, and this file cannot tell the two
apart.  Section 4 reports what is actually in place, which is the check that replaces guessing.

========================================================================================================================
Example Usage and Performance:

sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i scripts/permissions.sql

Catalog writes only.  Runs in well under a second on any database.

========================================================================================================================
Modification History:

Date:        2026-09-13
Author:      ponytail-sql-objects
Ticket:      n/a
Description: Initial version.  Extracted the schema-level role permissions out of the installers and added the missing
             grants on SCHEMA::dbo -- without them, a plain table from templates/table.sql was invisible to applicationRole
             while the views were not, because only the temporal template carried a permissions section.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/

-- :on error exit stops the run on the first error instead of carrying on into the next batch.  There is no enclosing
-- transaction -- every GO commits its own batch -- so without it a failure in the middle of the file lets every later
-- section run against a half-applied permission model, which is worse than none.
:on error exit

-- THE TARGET DATABASE IS SUPPLIED ON THE COMMAND LINE AND HAS NO DEFAULT:
--
--     sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i scripts/permissions.sql
--
-- There is deliberately no `:setvar DbName` line here.  Measured on sqlcmd 17: WHEN A FILE SETS A VARIABLE WITH
-- :setvar, THAT VALUE WINS OVER -v ON THE COMMAND LINE -- it overrides -v rather than acting as a fallback for its
-- absence.  Granting into the wrong database is the exact failure section 0 exists to stop.
--
-- Omitting -v is the safe failure: sqlcmd reports  'DbName' scripting variable not defined.  and the `:on error exit`
-- above stops the run before the first batch, so nothing is changed.

-- XACT_ABORT so a partial failure leaves nothing half-applied.  QUOTED_IDENTIFIER because sqlcmd defaults it OFF where
-- every other client defaults it ON; no module is created here, but the setting is cheap and every sqlcmd line in this
-- skill carries -I so that it is never the variable.
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


-- *** 0. Assert the target ***
-- Every documented invocation passes the database on the command line AND expects the file to name the same one.  When
-- they disagree the failure is otherwise silent: the permissions land on whichever database the file named, and the
-- closing report -- run against that same wrong database -- says it worked.
--
-- Severity 16 rather than 20: severity 20 needs sysadmin or ALTER TRACE, and this file is documented to run as db_owner.
-- The :on error exit above is what turns the error into a stopped run rather than a skipped batch.
IF DB_NAME () <> N'$(DbName)'
BEGIN
    DECLARE @Mismatch nvarchar(2000) =
        N'Target mismatch. Connected to [' + DB_NAME () + N'] but this file is configured for [$(DbName)]. '
      + N'Either connect with  -d $(DbName)  or override the file with  -v DbName=' + DB_NAME ()
      + N'. Nothing has been changed.';

    THROW 50000, @Mismatch, 1;
END
GO


USE [$(DbName)];     -- supplied by  sqlcmd -v DbName=<database>.  Section 0 has already checked it against DB_NAME ().
GO


-- *** 1. The roles this file expects ***
-- Reported rather than silently skipped.  Everywhere else in this skill a guarded grant that finds no role is a quiet
-- no-op, which keeps a table script re-runnable across databases with different principals.  Here that behaviour would
-- hide the whole point of the file, so a missing role is announced and named.
PRINT '--- roles ---';
GO

DECLARE @Roles TABLE (RoleName sysname PRIMARY KEY);
INSERT @Roles (RoleName) VALUES (N'applicationRole'), (N'readOnlyRole');

SELECT RoleName    = r.RoleName
     , Status      = CASE WHEN DATABASE_PRINCIPAL_ID (r.RoleName) IS NULL
                          THEN 'MISSING - every grant below for this role is SKIPPED'
                          ELSE 'present' END
     , MemberCount = ISNULL ((SELECT COUNT (*)
                                FROM sys.database_role_members AS m
                               WHERE m.role_principal_id = DATABASE_PRINCIPAL_ID (r.RoleName)), 0)
  FROM @Roles AS r
 ORDER BY r.RoleName;
GO

-- A role with no members is not an error -- the grants are still correct and take effect the moment someone is added --
-- but it is the single most common reason for "the permissions are right and it still cannot read anything".
IF EXISTS (SELECT 1
             FROM sys.database_principals AS p
            WHERE p.name IN (N'applicationRole', N'readOnlyRole')
              AND NOT EXISTS (SELECT 1
                                FROM sys.database_role_members AS m
                               WHERE m.role_principal_id = p.principal_id))
BEGIN
    PRINT 'INFO: at least one role has no members. The grants are still applied; add users with ALTER ROLE ... ADD MEMBER.';
END;
GO


-- *** 2. dbo -- the read and write surface ***
-- SELECT, INSERT and UPDATE, at the schema, so that every dbo table and view is reachable without a per-object grant --
-- including the ones not written yet.  NOT DELETE: see "DELETE IS NOT GRANTED ON SCHEMA::dbo" in the header.
PRINT '--- dbo ---';
GO

IF DATABASE_PRINCIPAL_ID (N'applicationRole') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE ON SCHEMA::dbo TO applicationRole;
    PRINT 'GRANT SELECT, INSERT, UPDATE ON SCHEMA::dbo TO applicationRole.';
    PRINT '  DELETE deliberately withheld: a plain dbo table has no INSTEAD OF trigger, so DELETE would be a HARD delete.';
    PRINT '  A view that needs DELETE carries its own object-level grant, from templates/table-temporal.sql section 7.';
END
ELSE
BEGIN
    PRINT 'SKIPPED: applicationRole does not exist. No grant on SCHEMA::dbo was made.';
END;
GO

IF DATABASE_PRINCIPAL_ID (N'readOnlyRole') IS NOT NULL
BEGIN
    GRANT SELECT ON SCHEMA::dbo TO readOnlyRole;
    PRINT 'GRANT SELECT ON SCHEMA::dbo TO readOnlyRole.';
END
ELSE
BEGIN
    PRINT 'SKIPPED: readOnlyRole does not exist. No grant on SCHEMA::dbo was made.';
END;
GO


-- *** 3. The data schemas -- denied ***
-- dboData, logsData and history hold the base tables and the temporal history sitting behind the views.  A trigger or an
-- ownership-chained procedure reaches them; nothing else should.  DENY rather than an absent grant, so that a later
-- blanket grant somewhere else cannot quietly open them.
--
-- Guarded on the schema existing rather than assumed: dboData appears with the first temporal table, which on a fresh
-- database may not exist yet.  Re-run this file after it does.
PRINT '--- data schemas ---';
GO

DECLARE @DataSchemas TABLE (SchemaName sysname PRIMARY KEY);
INSERT @DataSchemas (SchemaName) VALUES (N'dboData'), (N'logsData'), (N'history');

DECLARE @SchemaName sysname
      , @RoleName   sysname
      , @Sql        nvarchar(400);

DECLARE SchemaRole CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.SchemaName, r.RoleName
      FROM @DataSchemas AS d
     CROSS JOIN (VALUES (N'applicationRole'), (N'readOnlyRole')) AS r (RoleName)
     WHERE SCHEMA_ID (d.SchemaName) IS NOT NULL
       AND DATABASE_PRINCIPAL_ID (r.RoleName) IS NOT NULL
     ORDER BY d.SchemaName, r.RoleName;

OPEN SchemaRole;
FETCH NEXT FROM SchemaRole INTO @SchemaName, @RoleName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- QUOTENAME on both, because a schema and a role are both identifiers arriving from a variable.  There is no user
    -- input anywhere near this -- the names are literals in the two table variables above -- but a dynamic statement
    -- built from an identifier gets QUOTENAME regardless, so that the habit does not depend on remembering which
    -- statements were safe.
    --
    -- readOnlyRole keeps SELECT nowhere here: a reader has no business in the base tables either, since the view is
    -- what applies the soft-delete filter, and reading round it returns deleted rows.
    SET @Sql = N'DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::' + QUOTENAME (@SchemaName)
             + N' TO ' + QUOTENAME (@RoleName) + N';';

    EXEC sys.sp_executesql @Sql;
    PRINT '  ' + @Sql;

    FETCH NEXT FROM SchemaRole INTO @SchemaName, @RoleName;
END;

CLOSE SchemaRole;
DEALLOCATE SchemaRole;
GO

-- Named, so that "the deny is missing" and "the schema does not exist yet" are told apart.
SELECT SchemaName = s.SchemaName
     , Status     = 'ABSENT - no deny applied. Re-run this file once the schema exists.'
  FROM (VALUES (N'dboData'), (N'logsData'), (N'history')) AS s (SchemaName)
 WHERE SCHEMA_ID (s.SchemaName) IS NULL;
GO


-- *** 4. logs -- the log surface ***
-- Also granted by logdBChanges.sql, and repeated here so that this file is a complete statement of the model rather than
-- most of it.  Re-applying an identical grant changes nothing.
PRINT '--- logs ---';
GO

IF SCHEMA_ID (N'logs') IS NOT NULL AND DATABASE_PRINCIPAL_ID (N'applicationRole') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logs TO applicationRole;
    PRINT 'GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logs TO applicationRole.';
    PRINT '  DELETE is safe here: logs.DdlChange is a VIEW whose INSTEAD OF DELETE trigger soft-deletes.';
END;
GO

IF SCHEMA_ID (N'logs') IS NOT NULL AND DATABASE_PRINCIPAL_ID (N'readOnlyRole') IS NOT NULL
BEGIN
    GRANT SELECT ON SCHEMA::logs TO readOnlyRole;
    DENY INSERT, UPDATE, DELETE ON SCHEMA::logs TO readOnlyRole;
    PRINT 'GRANT SELECT / DENY writes ON SCHEMA::logs TO readOnlyRole.';
END;
GO


-- *** 5. Closing report -- what is actually in place ***
-- Effective schema-level state per role, read back out of the catalog rather than restated from the code above.  A
-- report that repeats the script's intentions cannot catch a grant that failed to apply.
PRINT '--- effective schema permissions ---';
GO

SELECT RoleName   = CAST (dp.name AS nvarchar(60))
     , SchemaName = CAST (SCHEMA_NAME (p.major_id) AS nvarchar(30))
     , Permission = CAST (p.permission_name AS nvarchar(30))
     , State      = CAST (p.state_desc AS nvarchar(20))
  FROM sys.database_permissions AS p
  JOIN sys.database_principals  AS dp ON dp.principal_id = p.grantee_principal_id
 WHERE p.class = 3      -- SCHEMA
   AND dp.name IN (N'applicationRole', N'readOnlyRole')
 ORDER BY dp.name, SCHEMA_NAME (p.major_id), p.permission_name;
GO

-- The object-level grants that supplement the schema ones -- principally GRANT DELETE on each temporal view, which is
-- the permission the schema-level model deliberately does not provide.
PRINT '--- object-level grants that supplement the above ---';
GO

SELECT RoleName   = CAST (dp.name AS nvarchar(60))
     , ObjectName = CAST (SCHEMA_NAME (o.schema_id) + N'.' + o.name AS nvarchar(200))
     , ObjectType = CAST (o.type_desc AS nvarchar(30))
     , Permission = CAST (p.permission_name AS nvarchar(30))
     , State      = CAST (p.state_desc AS nvarchar(20))
  FROM sys.database_permissions AS p
  JOIN sys.database_principals  AS dp ON dp.principal_id = p.grantee_principal_id
  JOIN sys.objects              AS o  ON o.object_id     = p.major_id
 WHERE p.class = 1      -- OBJECT_OR_COLUMN
   AND dp.name IN (N'applicationRole', N'readOnlyRole')
 ORDER BY dp.name, SCHEMA_NAME (o.schema_id), o.name, p.permission_name;
GO

PRINT 'Permissions applied. Verify for a specific user with:';
PRINT '    EXECUTE AS USER = ''<user>'';';
PRINT '    SELECT HAS_PERMS_BY_NAME (''dbo.<Table>'', ''OBJECT'', ''SELECT'');';
PRINT '    REVERT;';
GO
