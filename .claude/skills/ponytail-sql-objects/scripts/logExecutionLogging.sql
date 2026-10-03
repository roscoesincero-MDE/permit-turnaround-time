
/***********************************************************************************************************************
Script:         logExecutionLogging.sql
Purpose:        Per-database procedure execution logging -- the table and the four procedures that rule 8's
                instrumentation block calls.  Records when each instrumented procedure ran, for how long, whether it
                succeeded, and what error it hit if it did not.
Target:         SQL Server 2022.  That is the project floor and it is stated once, in SKILL.md rule 6.  Nothing in THIS
                file needs anything newer than 2016 (CREATE OR ALTER, DATEDIFF_BIG), but the completion UPDATE in
                templates/procedure.sql uses LEAST(), which is 2022+, so the floor is real.  Do not re-declare a lower
                one here.
Run as:         db_owner (or equivalent) in the target database.
Run with:       sqlcmd -I -C, or SSMS with Query > SQLCMD Mode on.  The file uses :on error exit and $(DbName).
                Run without sqlcmd mode it fails on the first line, which is the intended outcome: the alternative
                failure -- installing into the wrong database and reporting success -- is silent.
Idempotent:     Yes.  Every CREATE is guarded, every column and index is added additively and guarded on ITS OWN name,
                and a clean second run changes nothing and reports nothing but the closing report.  Nothing here drops
                a table, a column or an index.  A run that failed part way through is repaired by running it again.
To retarget:    Pass it per run:  sqlcmd -d <database> -v DbName=<database>.  There is no in-file default, and the
                comment above section 0 explains why putting one back would break this.

Why this file exists, and why it is not optional
------------------------------------------------
SKILL.md rule 8 requires every procedure that writes to open a logs.ExecutionLog row before its transaction and close it
after the commit, and every procedure that reads to record its failures.  templates/procedure.sql and
templates/procedure-readonly.sql are written against the contract below.  Until this file has run, both templates
reference objects that do not exist, and every instrumented procedure fails on its first call.

Objects created
---------------
  logs.ExecutionLog                     One row per instrumented procedure call.  Standard 7-column audit block, soft
                                        delete, no hard delete.
  logs.uspStartExecutionLoggingInsert   Opens the row and returns its key.  THROWS on failure -- see section 5.
  logs.uspStartExecutionLogging         Wrapper over the above.  This is what a procedure calls.
  logs.uspRecordExecutionErrorUpdate    Records the error onto the open row, or opens an orphan row if there is none.
                                        SWALLOWS everything -- see section 7.
  logs.uspRecordExecutionError          Wrapper over the above.  This is what a CATCH block calls.

Those four ARE the four logging procedures rule 8 exempts from instrumentation, and instrumenting any of them would be
circular: the procedure that records a failure cannot itself open a row to record its own.  Two wrappers and two inner
procedures, which is why the count is four rather than two.  The fifth exempt procedure is
util.uspSetObjectDescription, which is defined in templates/extended-properties.sql, not here.

Why the wrapper / inner split is kept
-------------------------------------
Each wrapper does nothing but forward its arguments.  That looks like dead weight and is not: the wrapper is the seam
that lets the inner procedure be pointed at a CENTRAL logging database without editing a single caller.  Change the
wrapper's one EXEC to a four-part name and every instrumented procedure in the database starts logging somewhere else.
Section 6 and section 8 carry the commented four-part form.  Delete the wrappers and that becomes a change to every
procedure in the database instead.

The contract, which the templates depend on
-------------------------------------------
  EXEC logs.uspStartExecutionLogging @ProcedureName, @KeyParameters, @StartDateUtc, @ReCreatedAfterRollback,
                                     @ExecutionLogId OUTPUT
  EXEC logs.uspRecordExecutionError  @ProcedureName, @KeyParameters, @ExecutionLogId, @ErrorMessage, @ErrorProcedure,
                                     @ErrorNumber, @ErrorLine, @DynamicSql, @ContextMessage

Do not rename a parameter, narrow a type or reorder the list without changing both templates in the same commit.  Every
instrumented procedure in the database calls these by NAME, so a rename is a break, not a refactor.

The completion UPDATE is the CALLER's, deliberately
---------------------------------------------------
There is no uspFinishExecutionLogging.  templates/procedure.sql closes its own row with an inline UPDATE against
logs.ExecutionLog after the COMMIT, and that is the design: the successful path costs one round trip instead of two, and
the caller is the only thing that knows its own @Comments and its own @StartTimeUtc.  It also means

  ELAPSED TIME IS COMPUTED BY THE CALLER AND NOTHING ON THIS TABLE RECOMPUTES IT.

An earlier version of this subsystem carried an AFTER UPDATE trigger on the log table that recalculated elapsed time
with DATEDIFF (SECOND, ...).  It is deliberately absent.  Two reasons: it was a second source of truth that silently
overwrote the millisecond value templates/procedure.sql had just written with a second-resolution one, and it rewrote
every updated row on every update of a table that is one of the highest-write objects in the database.  The clamp in the
template (LEAST against 2147483647) is there because DATEDIFF_BIG returns bigint and this column is int -- a call left
running for 25 days would otherwise overflow the assignment rather than record a large number.

Permissions: ownership chaining, not a grant on the table
---------------------------------------------------------
The calling procedure -- in dbo, or config, or wherever -- runs that completion UPDATE against a table in logs.  It does
NOT need UPDATE on logs.ExecutionLog for that, provided the schema holding the caller and the schema holding this table
have the SAME OWNER, which section 1 sets to dbo.  Ownership chaining then skips the permission check on the table.  Get
that wrong and the symptom is a permission error inside the instrumentation block of a procedure whose own logic is
fine.  Section 10 grants EXECUTE on the four procedures and SELECT on the table, and nothing else.

RowHistory is OFF for this table, deliberately
----------------------------------------------
SKILL.md's RowHistory switch defaults off and this table is a case where off is the right answer rather than the default
answer.  A log row is written once and updated once, by one writer, seconds apart; system versioning would double the
write volume of the highest-write table in the database to preserve an intermediate state that is "the call had not
finished yet".  The table's own rows are the audit trail.  This is not the DDL change log, where the history table being
empty is itself the tamper evidence -- that one is rule 10 and is not subject to the switch.

Relationship to an existing logs.execution_log
----------------------------------------------
An earlier generation of this subsystem used snake_case names -- logs.execution_log, its id column, ErrorMsg,
ContextMsg, ElapsedTime in seconds.  Those names do not match SKILL.md's Naming rule, and the templates in this skill
call the PascalCase ones.  This file does NOT rename, migrate or drop that table: nothing here performs destructive DDL,
and a rename with live callers is a decision for whoever owns them.  Section 2 DETECTS it and the closing report names
it, with the migration written out.  Until that migration is done a database can carry both; only this one is written.
***********************************************************************************************************************/

-- :on error exit stops the run on the first error instead of carrying on into the next batch.  There is no enclosing
-- transaction -- every GO commits its own batch -- so without it a failure in the middle of the file lets every later
-- section run against a half-applied install.
:on error exit

-- THE TARGET DATABASE IS SUPPLIED ON THE COMMAND LINE AND HAS NO DEFAULT:
--
--     sqlcmd -S <server> -d <database> -v DbName=<database> -I -C -i logExecutionLogging.sql
--
-- There is deliberately no `:setvar DbName` line here.  Measured on sqlcmd 17: WHEN A FILE SETS A VARIABLE WITH
-- :setvar, THAT VALUE WINS OVER -v ON THE COMMAND LINE -- it overrides -v rather than acting as a fallback for its
-- absence.  A file carrying `:setvar DbName "SomeDatabase"` therefore ignores every -v it is given, and the only thing
-- standing between that and installing into the wrong database is section 0's assertion.
--
-- Omitting -v is the safe failure: sqlcmd reports  'DbName' scripting variable not defined.  and the `:on error exit`
-- above stops the run before the first batch, so nothing is changed.  To hard-wire the target instead, edit the two
-- `$(DbName)` references directly -- section 0's assertion and section 1's USE.

-- XACT_ABORT so a partial failure leaves no half-applied DDL.  QUOTED_IDENTIFIER because sqlcmd defaults it OFF where
-- every other client defaults it ON, it is baked into every module at CREATE time, and a module carrying it OFF cannot
-- run DML against a table with a filtered index (error 1934).  Any sqlcmd line running this file needs -I.
--
-- These are the BATCH settings, which is what validate-sql.py checks for and what every CREATE below is compiled with.
-- Sections 5 to 8 each set XACT_ABORT OFF inside the procedure BODY, for a reason stated there.  A SET inside a module
-- reverts when the module returns, so that does not leak back out here.
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


-- *** 0. Assert the target ***
-- Every documented invocation of this file passes the database on the command line AND expects the file to name the same
-- one.  When those two disagree the failure is otherwise silent: the subsystem installs into whichever database the file
-- named, and the closing report -- run against that same wrong database -- says it worked.
--
-- Severity 16 rather than the 20 that would kill the connection outright: severity 20 needs sysadmin or ALTER TRACE, and
-- this file is documented to run as db_owner.  The :on error exit above is what turns the error into a stopped run
-- rather than a skipped batch.
IF DB_NAME () <> N'$(DbName)'
BEGIN
    DECLARE @Mismatch nvarchar(2000) =
        N'Target mismatch. Connected to [' + DB_NAME () + N'] but this file is configured for [$(DbName)]. '
      + N'Either connect with  -d $(DbName)  or override the file with  -v DbName=' + DB_NAME ()
      + N'. Nothing has been changed.';

    THROW 50000, @Mismatch, 1;
END
GO


-- *** 1. Schema, and the owner that makes ownership chaining work ***

USE [$(DbName)];     -- supplied by  sqlcmd -v DbName=<database>.  Section 0 has already checked it against DB_NAME ().
GO

-- Created only when missing, and never dropped: DROP SCHEMA fails once the schema holds objects, and dropping an empty
-- schema silently discards every permission that had been granted on it.
-- CREATE SCHEMA must be the only statement in its batch, hence the EXEC.
IF SCHEMA_ID (N'logs') IS NULL EXEC (N'CREATE SCHEMA [logs]');
GO

-- The owner is load-bearing, not tidiness.  The completion UPDATE in templates/procedure.sql runs from a procedure in
-- the CALLER's schema against a table in this one; ownership chaining skips the permission check on the table only when
-- both schemas resolve to the same owner.  dbo is the value the rest of this project uses -- see
-- references/change-logging.md on logs / logsData / history -- so it is the value here.
--
-- Guarded on the owner NOT already being dbo, so a second run is a no-op rather than a re-issued ALTER.
IF EXISTS (SELECT 1
             FROM sys.schemas AS s
             JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
            WHERE s.name = N'logs' AND p.name <> N'dbo')
BEGIN
    ALTER AUTHORIZATION ON SCHEMA::logs TO dbo;
    PRINT N'Schema [logs] re-owned to dbo, for ownership chaining from the calling procedure''s schema.';
END
GO


-- *** 2. logs.ExecutionLog ***
-- Guarded, so a second run is a no-op.  Later changes belong in section 3, additively; do not edit this CREATE to add a
-- column to a table that already exists somewhere.

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NULL
BEGIN
    CREATE TABLE logs.ExecutionLog
    (
        ExecutionLogId          BIGINT          IDENTITY (1, 1) NOT NULL,

        -- ---------------------------------------------------------------------------------
        -- What ran, and with what
        -- ---------------------------------------------------------------------------------
        -- 300 to match @ProcName in templates/procedure.sql.  Two QUOTENAME(sysname) values plus a dot can in theory
        -- reach 517 characters; 300 covers every real name and is the width the templates declare.  It is NOT 261 --
        -- an earlier version used that, and passing a 300-wide value into a 261-wide PARAMETER truncates SILENTLY,
        -- because assignment truncation is not the error that INSERT truncation is.  Keep the three widths equal:
        -- this column, the parameter in sections 5 to 8, and @ProcName in the templates.
        ProcedureName           NVARCHAR (300)  NOT NULL,

        -- Identifiers and counts ONLY.  NEVER a credential, NEVER an API key or bearer token, NEVER a URL query
        -- string, NEVER a request header, and NEVER a payload parameter.  The same restriction applies to Comments,
        -- ContextMessage and DynamicSql below.  This table is read by a monitoring web app and retained; a secret
        -- written here has been published.  See the header of templates/procedure.sql, which states it at the point
        -- where the value is composed.
        KeyParameters           NVARCHAR (MAX)  NULL,

        -- ---------------------------------------------------------------------------------
        -- Timing and outcome
        -- ---------------------------------------------------------------------------------
        StartDateUtc            DATETIME2 (3)   NOT NULL,
        EndDateUtc              DATETIME2 (3)   NULL,

        -- Written by the CALLER's completion UPDATE, clamped there against int overflow.  Nothing on this table
        -- recomputes it -- see "The completion UPDATE is the CALLER's" in the file header.
        ElapsedMilliseconds     INT             NULL,

        -- Defaults to 0, so an interrupted call reads as unsuccessful rather than as unknown.  The completion UPDATE
        -- sets it to 1, and it is the last thing that happens on the successful path.  A row with EndDateUtc set and
        -- Successful = 0 is a recorded failure; a row with neither is a call that never came back at all.
        Successful              BIT             NOT NULL CONSTRAINT DF_logs_ExecutionLog_Successful              DEFAULT (0),
        Comments                NVARCHAR (MAX)  NULL,

        -- 1 when this row was re-created in the caller's CATCH because a ROLLBACK destroyed the original.  Set by
        -- @ReCreatedAfterRollback, never inferred: the rollback also destroys the evidence it happened, so without
        -- this column an error row and a re-created error row are indistinguishable.
        ReCreatedAfterRollback  BIT             NOT NULL CONSTRAINT DF_logs_ExecutionLog_ReCreatedAfterRollback  DEFAULT (0),

        -- ---------------------------------------------------------------------------------
        -- The failure, when there was one.  All NULL on a successful call.
        -- ---------------------------------------------------------------------------------
        ErrorMessage            NVARCHAR (MAX)  NULL,
        ErrorProcedure          NVARCHAR (300)  NULL,
        ErrorNumber             INT             NULL,
        ErrorLine               INT             NULL,

        -- The statement text when the failure was in dynamic SQL, and whatever the procedure chose to say about its own
        -- state.  Both are for debugging the procedure, and both are subject to the KeyParameters restriction above.
        DynamicSql              NVARCHAR (MAX)  NULL,
        ContextMessage          NVARCHAR (MAX)  NULL,

        -- ---------------------------------------------------------------------------------
        -- Standard audit block.  Soft delete only; there is no hard delete.
        -- Convention: DF_<schema>_<tableName>_<fieldName>, unique per database.
        --
        -- The audit*By columns are NVARCHAR (255) for the two reasons stated in templates/table.sql:
        -- DEFAULT (ORIGINAL_LOGIN ()) returns sysname (128), and a trigger resolving the value casts
        -- SESSION_CONTEXT (N'AppUser') to NVARCHAR (255), which cannot land in a 128-wide column.
        -- Datetime columns are DATETIME2 (3) -- SKILL.md rule 1.  Never bare.
        -- ---------------------------------------------------------------------------------
        IsDeleted               BIT             NOT NULL CONSTRAINT DF_logs_ExecutionLog_IsDeleted               DEFAULT (0),
        auditDeletedBy          NVARCHAR (255)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditDeletedBy          DEFAULT (ORIGINAL_LOGIN ()),
        auditDeletedDateUtc     DATETIME2 (3)   NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditDeletedDateUtc     DEFAULT (SYSUTCDATETIME ()),
        auditCreatedBy          NVARCHAR (255)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditCreatedBy          DEFAULT (ORIGINAL_LOGIN ()),
        auditCreatedDateUtc     DATETIME2 (3)   NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditCreatedDateUtc     DEFAULT (SYSUTCDATETIME ()),
        auditModifiedBy         NVARCHAR (255)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditModifiedBy         DEFAULT (ORIGINAL_LOGIN ()),
        auditModifiedDateUtc    DATETIME2 (3)   NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditModifiedDateUtc    DEFAULT (SYSUTCDATETIME ()),

        CONSTRAINT PK_logs_ExecutionLog PRIMARY KEY CLUSTERED (ExecutionLogId)
    );

    PRINT N'Created logs.ExecutionLog.';
END
GO

-- NO FILTERED UNIQUE INDEX ON THIS TABLE, AND THAT IS NOT AN OMISSION.  SKILL.md's soft-delete rule pairs every natural
-- key with a unique index filtered on IsDeleted = 0.  This table HAS no natural key: the same procedure running twice
-- with the same arguments in the same millisecond is two calls and must be two rows.  ExecutionLogId is the only key.
GO

-- The legacy snake_case table, detected and reported, never touched.  See "Relationship to an existing
-- logs.execution_log" in the file header for why this is a report rather than a migration.
IF OBJECT_ID (N'logs.execution_log', N'U') IS NOT NULL
BEGIN
    PRINT N'NOTE: logs.execution_log also exists. It is the previous generation of this table and nothing in this file';
    PRINT N'      reads, writes, renames or drops it. The templates in this skill write logs.ExecutionLog only.';
    PRINT N'      To carry its rows across, in a script of your own that you can review:';
    PRINT N'        insert logs.ExecutionLog (ProcedureName, KeyParameters, StartDateUtc, EndDateUtc,';
    PRINT N'                                  ElapsedMilliseconds, Successful, Comments, ErrorMessage,';
    PRINT N'                                  ErrorProcedure, ErrorNumber, ErrorLine, DynamicSql, ContextMessage,';
    PRINT N'                                  auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc)';
    PRINT N'        select ProcedureName, KeyParameters, StartDateUtc, EndDateUtc,';
    PRINT N'               ElapsedTime * 1000, Successful, Comments, ErrorMsg,';
    PRINT N'               ErrorProcedure, ErrorNumber, ErrorLine, DynamicSql, ContextMsg,';
    PRINT N'               CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc';
    PRINT N'          from logs.execution_log;';
    PRINT N'      ElapsedTime was SECONDS there and ElapsedMilliseconds is milliseconds here, hence the * 1000 --';
    PRINT N'      the values are second-resolution and stay that way. Leave the old table in place afterwards.';
END
GO


-- *** 3. Additive changes ***
-- Columns added after this table was first deployed somewhere.  Each guarded on ITS OWN name, so the file converges on
-- an empty database and on one that has an older ExecutionLog, and so a run that failed part way through is repaired by
-- running it again.  Never edit section 2 to add a column here.
--
-- On a brand-new database every block below is a no-op, because section 2 just created the table with all of them.
-- That is the point: the two paths arrive at the same shape.

-- COL_LENGTH returns NULL when the column does not exist.
IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'ReCreatedAfterRollback') IS NULL
BEGIN
    -- NOT NULL with a default is safe on a populated table: existing rows get 0, which is the true answer for every
    -- row written before the caller could report otherwise.
    ALTER TABLE logs.ExecutionLog
        ADD ReCreatedAfterRollback BIT NOT NULL
            CONSTRAINT DF_logs_ExecutionLog_ReCreatedAfterRollback DEFAULT (0);
    PRINT N'Added logs.ExecutionLog.ReCreatedAfterRollback.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'ElapsedMilliseconds') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog ADD ElapsedMilliseconds INT NULL;
    PRINT N'Added logs.ExecutionLog.ElapsedMilliseconds.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'DynamicSql') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog ADD DynamicSql NVARCHAR (MAX) NULL;
    PRINT N'Added logs.ExecutionLog.DynamicSql.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'ContextMessage') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog ADD ContextMessage NVARCHAR (MAX) NULL;
    PRINT N'Added logs.ExecutionLog.ContextMessage.';
END
GO

-- The audit block, one column per guarded block.  A table that predates SKILL.md rule 1 has none of these; one that was
-- created by section 2 has all of them.  Written out rather than looped because the DF_ name differs per column and the
-- guard has to be on that name.
IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'IsDeleted') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog
        ADD IsDeleted BIT NOT NULL CONSTRAINT DF_logs_ExecutionLog_IsDeleted DEFAULT (0);
    PRINT N'Added logs.ExecutionLog.IsDeleted.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'auditDeletedBy') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog
        ADD auditDeletedBy      NVARCHAR (255) NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditDeletedBy      DEFAULT (ORIGINAL_LOGIN ())
          , auditDeletedDateUtc DATETIME2 (3)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditDeletedDateUtc DEFAULT (SYSUTCDATETIME ());
    PRINT N'Added logs.ExecutionLog.auditDeletedBy and auditDeletedDateUtc.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'auditCreatedBy') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog
        ADD auditCreatedBy      NVARCHAR (255) NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditCreatedBy      DEFAULT (ORIGINAL_LOGIN ())
          , auditCreatedDateUtc DATETIME2 (3)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditCreatedDateUtc DEFAULT (SYSUTCDATETIME ());
    PRINT N'Added logs.ExecutionLog.auditCreatedBy and auditCreatedDateUtc.';
END
GO

IF OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', N'auditModifiedBy') IS NULL
BEGIN
    ALTER TABLE logs.ExecutionLog
        ADD auditModifiedBy      NVARCHAR (255) NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditModifiedBy      DEFAULT (ORIGINAL_LOGIN ())
          , auditModifiedDateUtc DATETIME2 (3)  NOT NULL CONSTRAINT DF_logs_ExecutionLog_auditModifiedDateUtc DEFAULT (SYSUTCDATETIME ());
    PRINT N'Added logs.ExecutionLog.auditModifiedBy and auditModifiedDateUtc.';
END
GO

-- Widen an audit*By column that a previous generation created at 100 or 128.  Guarded on the width in CHARACTERS, so
-- the block is a no-op once it is already 255 and so varchar and nvarchar compare alike.  ALTER COLUMN to a WIDER type
-- of the same family is a metadata-only change and does not rewrite the table.
DECLARE @NarrowBy sysname, @Widen nvarchar(400);

DECLARE NarrowByCols CURSOR LOCAL FAST_FORWARD FOR
    SELECT c.name
      FROM sys.columns AS c
     WHERE c.object_id = OBJECT_ID (N'logs.ExecutionLog')
       AND c.name IN (N'auditCreatedBy', N'auditModifiedBy', N'auditDeletedBy')
       AND c.max_length >= 0                                          -- exclude the (max) types, reported as -1
       AND c.max_length / CASE WHEN c.system_type_id IN (231, 239) THEN 2 ELSE 1 END < 255;

OPEN NarrowByCols;
FETCH NEXT FROM NarrowByCols INTO @NarrowBy;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- QUOTENAME on a name that came out of sys.columns: the value is trusted, the habit is not optional.
    SET @Widen = N'ALTER TABLE logs.ExecutionLog ALTER COLUMN ' + QUOTENAME (@NarrowBy) + N' nvarchar(255) NOT NULL;';
    EXEC (@Widen);
    PRINT N'Widened logs.ExecutionLog.' + @NarrowBy + N' to nvarchar(255).';

    FETCH NEXT FROM NarrowByCols INTO @NarrowBy;
END

CLOSE NarrowByCols;
DEALLOCATE NarrowByCols;
GO


-- *** 4. Indexes ***
-- Guarded rather than DROP_EXISTING, which requires the index to already exist.  Named IX_<schema>_<Table>_<columns>;
-- UX_ where it is unique, of which there are none here -- see the note under section 2.

-- The monitoring grid's query: recent calls, newest first, optionally narrowed to one procedure.  StartDateUtc leads
-- because that is what the grid orders by and what a retention job deletes on.
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'IX_logs_ExecutionLog_StartDateUtc'
                  AND object_id = OBJECT_ID (N'logs.ExecutionLog'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_logs_ExecutionLog_StartDateUtc
        ON logs.ExecutionLog (StartDateUtc DESC)
        INCLUDE (ProcedureName, Successful, ElapsedMilliseconds)
        WHERE IsDeleted = 0;
    PRINT N'Created IX_logs_ExecutionLog_StartDateUtc.';
END
GO

-- "How is this one procedure behaving over time" -- the other half of the grid, and what a slow-query investigation
-- starts from.
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'IX_logs_ExecutionLog_ProcedureName_StartDateUtc'
                  AND object_id = OBJECT_ID (N'logs.ExecutionLog'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_logs_ExecutionLog_ProcedureName_StartDateUtc
        ON logs.ExecutionLog (ProcedureName, StartDateUtc DESC)
        INCLUDE (Successful, ElapsedMilliseconds)
        WHERE IsDeleted = 0;
    PRINT N'Created IX_logs_ExecutionLog_ProcedureName_StartDateUtc.';
END
GO

-- Failures only, and there are few of them relative to the table -- which is exactly what a filtered index is for.
-- This is the index the "what is broken right now" page runs on.
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'IX_logs_ExecutionLog_Failures'
                  AND object_id = OBJECT_ID (N'logs.ExecutionLog'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_logs_ExecutionLog_Failures
        ON logs.ExecutionLog (StartDateUtc DESC)
        INCLUDE (ProcedureName, ErrorNumber, ErrorProcedure, ErrorLine)
        WHERE Successful = 0 AND IsDeleted = 0;
    PRINT N'Created IX_logs_ExecutionLog_Failures.';
END
GO


-- *** 5. logs.uspStartExecutionLoggingInsert ***

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   logs.uspStartExecutionLoggingInsert
Author:       rsincero
CreateDate:   2026-09-13
========================================================================================================================
Description:

Opens a logs.ExecutionLog row for a call that is starting and returns its key, so the caller can close the row when the
call finishes.  Called only by its wrapper, logs.uspStartExecutionLogging.

========================================================================================================================
Requirements and Key Dependencies:

logs.ExecutionLog.

========================================================================================================================
Notes:

EXEMPT FROM RULE 8, AND THE EXEMPTION IS STRUCTURAL.  This procedure cannot open a logs.ExecutionLog row to record its
own execution, because opening that row is what it does.  One of the four logging procedures SKILL.md rule 8 names.  Do
not add an instrumentation block here; see references/instrumentation.md.

THIS ONE THROWS.  Its sibling logs.uspRecordExecutionError swallows everything, and the asymmetry is deliberate.  A
failure to OPEN the row happens before the caller has done any work, so the caller should hear about it -- an
instrumented procedure whose logging is broken is a defect worth surfacing, not one to run silently.  A failure to
RECORD AN ERROR happens inside the caller's CATCH, where throwing would replace the error being reported with a logging
error and lose the real one.  templates/procedure.sql relies on both halves: its normal call is unguarded, and its
resurrection call in the CATCH is wrapped in a nested BEGIN TRY specifically because this procedure throws.

XACT_ABORT IS SET OFF IN THIS BODY, DELIBERATELY.  With it ON, any error in the INSERT below dooms the surrounding
transaction (XACT_STATE () = -1), which would turn "logging could not start" into "the caller's transaction is
uncommittable" -- the logging tail wagging the dog.  OFF leaves the caller's transaction committable for the large class
of errors that would otherwise doom it, and the THROW still reaches the caller either way.  A SET inside a module
reverts when the module returns, so this does not change the caller's own setting.  The batch above still carries
XACT_ABORT ON, which is what the CREATE is compiled with and what validate-sql.py checks.

@StartDateUtc IS THE CALLER'S CLOCK, NOT THIS PROCEDURE'S.  It defaults to SYSUTCDATETIME () for an ad-hoc call, but
templates/procedure.sql always passes the value it captured before its own work started -- otherwise the recorded
duration would exclude however long the EXEC took to get here, and the resurrection path in the CATCH would record the
time of the ROLLBACK instead of the time the call began.

@ReCreatedAfterRollback IS PASSED, NEVER INFERRED.  The rollback that destroys the original row destroys the evidence
that there was one, so nothing here can work it out after the fact.

SCOPE_IDENTITY () IS CORRECT HERE AND WOULD NOT BE ONE LEVEL UP.  It is scoped to this procedure, which is where the
INSERT happens; the caller reads the value through the OUTPUT parameter instead.  @@IDENTITY would be wrong -- it
crosses scopes and would return an identity from a trigger on some other table.

========================================================================================================================
Example Usage and Performance:

declare @ExecutionLogId bigint;
exec logs.uspStartExecutionLoggingInsert
      @ProcedureName          = N'[dbo].[uspSoftDeleteFacilitySource]'
    , @KeyParameters          = N'FacilityId=MD0000123456'
    , @StartDateUtc           = NULL
    , @ReCreatedAfterRollback = 0
    , @ExecutionLogId         = @ExecutionLogId OUTPUT;

One single-row INSERT.  This is on the hot path of every instrumented write in the database, so keep it that way: no
SELECT, no validation that costs a read, nothing that takes a lock it does not need.

========================================================================================================================
Modification History:

Date:		2026-09-13
Author:		rsincero
Ticket:		N/A
Description:
Brought into line with the skill: PascalCase name, nvarchar(300) @ProcedureName, @ExecutionLogId in place of
@ExecutionID, @ReCreatedAfterRollback added, the audit block written explicitly, and the missing leading semicolon on
THROW fixed -- without it, `THROW` as the first statement after BEGIN is a syntax error.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE logs.uspStartExecutionLoggingInsert
      @ProcedureName          NVARCHAR (300)
    , @KeyParameters          NVARCHAR (MAX) = NULL
    , @StartDateUtc           DATETIME2 (3)  = NULL
    , @ReCreatedAfterRollback BIT            = 0
    , @ExecutionLogId         BIGINT         OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- OFF on purpose. See "XACT_ABORT IS SET OFF IN THIS BODY" in the header above.
    SET XACT_ABORT OFF;

    -- One value per fact, so StartDateUtc and the two audit timestamps cannot disagree by a millisecond and a
    -- reader cannot mistake three near-identical times for three separate events.
    DECLARE @Now   DATETIME2 (3)  = SYSUTCDATETIME ()
          , @Actor NVARCHAR (255) = ORIGINAL_LOGIN ();

    SET @StartDateUtc = ISNULL (@StartDateUtc, @Now);

    -- Successful defaults to 0 and is left there: a call is unsuccessful until its completion UPDATE says otherwise.
    -- The audit columns are named explicitly rather than left to their DEFAULTs, so that all three timestamps come
    -- from @Now and a later change to the defaults cannot silently split them.
    INSERT INTO logs.ExecutionLog
    (
        ProcedureName, KeyParameters, StartDateUtc, ReCreatedAfterRollback,
        auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc
    )
    VALUES
    (
        @ProcedureName, @KeyParameters, @StartDateUtc, ISNULL (@ReCreatedAfterRollback, 0),
        @Actor, @Now, @Actor, @Now
    );

    SET @ExecutionLogId = SCOPE_IDENTITY ();

    -- Defensive, and it has to be: the caller's completion UPDATE is guarded on this being non-NULL, so a silent NULL
    -- here produces a row that is opened and never closed -- which the monitoring grid renders as a call that never
    -- returned.  Better to fail the start than to log a lie.
    --
    -- BEGIN/END around the THROW is load-bearing, not style.  `IF <cond> ;THROW ...` parses the leading semicolon as an
    -- empty statement, which ENDS the IF -- and the THROW then fires unconditionally, on every call.
    IF @ExecutionLogId IS NULL
    BEGIN
        ;THROW 50000, N'logs.uspStartExecutionLoggingInsert: SCOPE_IDENTITY () was NULL after inserting into logs.ExecutionLog. No execution log row was opened.', 1;
    END

    RETURN 0;
END
GO


-- *** 6. logs.uspStartExecutionLogging -- the wrapper ***

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   logs.uspStartExecutionLogging
Author:       rsincero
CreateDate:   2026-09-13
========================================================================================================================
Description:

Opens a logs.ExecutionLog row and returns its key.  THIS is the procedure an instrumented procedure calls;
templates/procedure.sql names it at the top of its TRY block and again in its CATCH.

========================================================================================================================
Requirements and Key Dependencies:

logs.uspStartExecutionLoggingInsert, which does the work.

========================================================================================================================
Notes:

EXEMPT FROM RULE 8.  One of the four logging procedures.  See section 5's header.

WHY THIS WRAPPER EXISTS, GIVEN THAT IT ONLY FORWARDS.  It is the seam for centralised logging.  Point the one EXEC below
at a four-part name and every instrumented procedure in this database logs to another server without a single caller
changing:

    EXEC [LoggingServer].[LoggingDatabase].logs.uspStartExecutionLoggingInsert ...

Prefer a static four-part name over a linked-server variable: the name is resolved at compile time, and a variable would
force dynamic SQL onto the hot path of every instrumented write.  Note what changes if you do point it elsewhere --
ExecutionLogId then comes from a different database, so the caller's completion UPDATE against local logs.ExecutionLog
has to move too.  Both templates would need the same edit.  That is a decision, not a switch.

IT FORWARDS EVERY PARAMETER, BY NAME.  Positional EXEC in a wrapper is how a parameter added to the inner procedure ends
up silently unset, or worse, bound to the wrong argument.  Named forwarding fails loudly instead.

========================================================================================================================
Example Usage and Performance:

declare @ExecutionLogId bigint;
exec logs.uspStartExecutionLogging
      @ProcedureName          = N'[dbo].[uspSoftDeleteFacilitySource]'
    , @KeyParameters          = N'FacilityId=MD0000123456, SourceType=N, Sequence=1'
    , @StartDateUtc           = NULL
    , @ReCreatedAfterRollback = 0
    , @ExecutionLogId         = @ExecutionLogId OUTPUT;

One EXEC plus one INSERT.  The wrapper itself costs a procedure call and nothing else.

========================================================================================================================
Modification History:

Date:		2026-09-13
Author:		rsincero
Ticket:		N/A
Description:
Brought into line with the skill, and the parameter list matched to templates/procedure.sql.  Arguments are now
forwarded by name.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE logs.uspStartExecutionLogging
      @ProcedureName          NVARCHAR (300)
    , @KeyParameters          NVARCHAR (MAX) = NULL
    , @StartDateUtc           DATETIME2 (3)  = NULL
    , @ReCreatedAfterRollback BIT            = 0
    , @ExecutionLogId         BIGINT         OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- OFF for the same reason as section 5: a logging failure must not doom the caller's transaction.
    SET XACT_ABORT OFF;

    -- BEST PRACTICE FOR CENTRALISED LOGGING: replace this with the static four-part name. See the header.
    -- EXEC [LoggingServer].[LoggingDatabase].logs.uspStartExecutionLoggingInsert
    EXEC logs.uspStartExecutionLoggingInsert
          @ProcedureName          = @ProcedureName
        , @KeyParameters          = @KeyParameters
        , @StartDateUtc           = @StartDateUtc
        , @ReCreatedAfterRollback = @ReCreatedAfterRollback
        , @ExecutionLogId         = @ExecutionLogId OUTPUT;

    RETURN 0;
END
GO


-- *** 7. logs.uspRecordExecutionErrorUpdate ***

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   logs.uspRecordExecutionErrorUpdate
Author:       rsincero
CreateDate:   2026-09-13
========================================================================================================================
Description:

Records a failure onto the logs.ExecutionLog row the call opened.  If there is no such row -- because logging never
started, or because a ROLLBACK destroyed it, or because the caller is an error-only instrumented read that never opens
one -- it inserts a row instead and says so.  Called only by its wrapper, logs.uspRecordExecutionError.

========================================================================================================================
Requirements and Key Dependencies:

logs.ExecutionLog.

========================================================================================================================
Notes:

EXEMPT FROM RULE 8.  One of the four logging procedures.  Instrumenting the procedure that records failures with a
mechanism that records failures is circular.

THIS ONE SWALLOWS EVERYTHING, AND THE EMPTY CATCH IS THE POINT.  It runs inside the caller's CATCH block, where an error
escaping from here would replace the error being reported.  Losing a log row is bad; losing the actual error and
reporting a logging error in its place is worse, because the caller's client then branches on the wrong error number.
So the CATCH is empty on purpose.  Do not "improve" it by adding a THROW, and do not add a RAISERROR -- see
references/instrumentation.md.  This is the opposite of section 5, which throws, for the reason given there.

XACT_ABORT IS SET OFF IN THIS BODY, AND HERE IT IS LOAD-BEARING RATHER THAN MERELY PRUDENT.  With it ON, a failure in
the MERGE below would doom the caller's transaction, so a procedure whose error was recoverable would find its
transaction uncommittable BECAUSE the logging worked badly.  OFF plus the empty CATCH is what makes "swallow" true.  A
SET inside a module reverts when the module returns.

WHAT IT CANNOT DO.  If the caller's transaction is ALREADY doomed when this runs -- XACT_STATE () = -1, which
XACT_ABORT ON in the caller makes the common case -- no write of any kind can succeed until it is rolled back, so the
MERGE fails and is swallowed and the row is lost.  templates/procedure.sql avoids that by rolling back BEFORE it calls
here.  templates/procedure-readonly.sql cannot, because the transaction is not its own to end, and states the limit
rather than hiding it.  Do not add a ROLLBACK here to work around it: ending a transaction this procedure did not begin
is a far worse failure than a missing log row.

MERGE, NOT "UPDATE THEN INSERT IF ZERO ROWS".  One statement, one seek on the clustered PK, and no window in which two
concurrent calls both see zero rows and both insert.  @ExecutionLogId IS NULL simply never matches, which sends it down
the NOT MATCHED branch -- so the NULL case needs no special handling.

THE ORPHAN ROW IS NOT ALWAYS A DEFECT.  Reaching the NOT MATCHED branch means one of three things, and only one is
wrong: (a) the caller is an error-only instrumented READ, which never opens a start row -- correct and expected, and its
@ContextMessage says so; (b) a rollback destroyed the row and the re-creation in the caller's CATCH also failed -- a
real but understood failure; (c) the caller never called logs.uspStartExecutionLogging at all -- a procedure that does
not follow templates/procedure.sql.  The prefix below is worded for all three: it states the FACT (no start row) rather
than the accusation, and the @ContextMessage the caller passed is what distinguishes them.  An earlier version asserted
(c) unconditionally, which made every error-only read look like a defect in the monitoring grid.

========================================================================================================================
Example Usage and Performance:

exec logs.uspRecordExecutionErrorUpdate
      @ProcedureName   = N'[dbo].[uspSoftDeleteFacilitySource]'
    , @KeyParameters   = N'FacilityId=MD0000123456'
    , @ExecutionLogId  = 22
    , @ErrorMessage    = N'Violation of UNIQUE KEY constraint ... (error 2627, line 68)'
    , @ErrorProcedure  = N'uspSoftDeleteFacilitySource'
    , @ErrorNumber     = 2627
    , @ErrorLine       = 68
    , @DynamicSql      = NULL
    , @ContextMessage  = NULL;

One MERGE, seeking the clustered PK.  Runs only on the failure path, so it is not on any hot path -- which is why it can
afford the MERGE and the extra columns that section 5 cannot.

========================================================================================================================
Modification History:

Date:		2026-09-13
Author:		rsincero
Ticket:		N/A
Description:
Brought into line with the skill.  @ErrorMsg/@ContextMsg renamed to @ErrorMessage/@ContextMessage to match
templates/procedure.sql; the audit columns are now written on both branches, which the previous version left to the
INSERT default and therefore never updated; ElapsedMilliseconds and EndDateUtc are computed from one hoisted value;
@ProcedureName is used for ProcedureName on the NOT MATCHED branch instead of being discarded in favour of
@ErrorProcedure; and the orphan-row message no longer asserts that the caller ignored the template.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE logs.uspRecordExecutionErrorUpdate
      @ProcedureName   NVARCHAR (300)
    , @KeyParameters   NVARCHAR (MAX) = NULL
    , @ExecutionLogId  BIGINT         = NULL
    , @ErrorMessage    NVARCHAR (MAX) = NULL
    , @ErrorProcedure  NVARCHAR (300) = NULL
    , @ErrorNumber     INT            = NULL
    , @ErrorLine       INT            = NULL
    , @DynamicSql      NVARCHAR (MAX) = NULL
    , @ContextMessage  NVARCHAR (MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- OFF on purpose, and here it is what makes the empty CATCH below actually swallow.
    -- See "XACT_ABORT IS SET OFF IN THIS BODY" in the header.
    SET XACT_ABORT OFF;

    BEGIN TRY

        -- One value per fact.  EndDateUtc, ElapsedMilliseconds and auditModifiedDateUtc all derive from @Now, so the
        -- recorded end time and the recorded duration cannot contradict each other.
        DECLARE @Now   DATETIME2 (3)  = SYSUTCDATETIME ()
              , @Actor NVARCHAR (255) = ORIGINAL_LOGIN ();

        -- Stated as a fact, not as an accusation -- see "THE ORPHAN ROW IS NOT ALWAYS A DEFECT" in the header.
        DECLARE @NoStartRowPrefix NVARCHAR (200) =
            N'[no execution log row was open for this call] ';

        MERGE INTO logs.ExecutionLog AS T
        USING (SELECT @ExecutionLogId AS ExecutionLogId) AS S
           ON T.ExecutionLogId = S.ExecutionLogId

        WHEN MATCHED THEN
            UPDATE SET
                  T.EndDateUtc            = @Now
                  -- Clamped exactly as templates/procedure.sql clamps it: DATEDIFF_BIG returns bigint and this column
                  -- is int, so a call left running for 25 days would overflow the assignment rather than record a
                  -- large number.
                , T.ElapsedMilliseconds   = CAST (LEAST (DATEDIFF_BIG (MILLISECOND, T.StartDateUtc, @Now)
                                                       , CAST (2147483647 AS BIGINT)) AS INT)
                , T.Successful            = 0
                , T.ErrorMessage          = @ErrorMessage
                , T.ErrorProcedure        = @ErrorProcedure
                , T.ErrorNumber           = @ErrorNumber
                , T.ErrorLine             = @ErrorLine
                , T.DynamicSql            = @DynamicSql
                , T.ContextMessage        = @ContextMessage
                  -- Written explicitly because the DEFAULT fires on INSERT only.  SKILL.md rule 1: an UPDATE that does
                  -- not set auditModified* leaves the row claiming it was last touched when it was created.
                , T.auditModifiedBy       = @Actor
                , T.auditModifiedDateUtc  = @Now

        WHEN NOT MATCHED BY TARGET THEN
            INSERT (ProcedureName, KeyParameters, StartDateUtc, EndDateUtc, ElapsedMilliseconds,
                    Successful, ErrorMessage, ErrorProcedure, ErrorNumber, ErrorLine,
                    DynamicSql, ContextMessage,
                    auditCreatedBy, auditCreatedDateUtc, auditModifiedBy, auditModifiedDateUtc)
            VALUES (
                  -- The caller's own name first.  An earlier version used COALESCE (@ErrorProcedure, ...) here, which
                  -- files the row under whichever nested procedure happened to raise -- so the monitoring grid, which
                  -- groups by ProcedureName, attributed the failure to the wrong procedure.  @ErrorProcedure is still
                  -- recorded, in its own column, where it belongs.
                    COALESCE (@ProcedureName, @ErrorProcedure, N'[unknown].[unknown]')
                  , @KeyParameters
                  -- No start row means no start time.  @Now is the only honest value available, and ElapsedMilliseconds
                  -- is therefore 0 rather than a duration invented from it.
                  , @Now
                  , @Now
                  , 0
                  , 0
                  , @NoStartRowPrefix + ISNULL (@ErrorMessage, N'')
                  , @ErrorProcedure
                  , @ErrorNumber
                  , @ErrorLine
                  , @DynamicSql
                  -- CONCAT_WS drops NULLs, so a caller that passed no @ContextMessage gets just the ExecutionLogId
                  -- note, and one that did -- every error-only read does -- keeps its own text first.
                  , CONCAT_WS (N'; '
                             , @ContextMessage
                             , N'ExecutionLogId passed by the caller: '
                               + ISNULL (CONVERT (NVARCHAR (20), @ExecutionLogId), N'NULL'))
                  , @Actor
                  , @Now
                  , @Actor
                  , @Now
            );
        -- MERGE requires its terminating semicolon; without it the next statement is parsed as part of the MERGE.

    END TRY
    BEGIN CATCH
        -- DELIBERATELY EMPTY, and it has to stay that way.  See "THIS ONE SWALLOWS EVERYTHING" in the header.  The
        -- caller is inside its own CATCH and the error it is reporting matters more than this one.  An empty CATCH
        -- block is valid T-SQL; do not add a THROW, a RAISERROR or a PRINT to make it look less bare.
        --
        -- To find out whether this is silently failing, look for procedures that raised and left no row here, or
        -- compare a count of rows with Successful = 0 against your application's own error count.  That is the price
        -- of the guarantee, and it is the right way round.
    END CATCH

    RETURN 0;
END
GO


-- *** 8. logs.uspRecordExecutionError -- the wrapper ***

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   logs.uspRecordExecutionError
Author:       rsincero
CreateDate:   2026-09-13
========================================================================================================================
Description:

Records a failure against the logs.ExecutionLog row the call opened, or opens an orphan row if there was none.  THIS is
the procedure a CATCH block calls; both templates/procedure.sql and templates/procedure-readonly.sql name it.

========================================================================================================================
Requirements and Key Dependencies:

logs.uspRecordExecutionErrorUpdate, which does the work.

========================================================================================================================
Notes:

EXEMPT FROM RULE 8.  One of the four logging procedures.

WHY THIS WRAPPER EXISTS.  The same seam as section 6: point the one EXEC below at a four-part name and every CATCH block
in the database records to a central logging database.  See section 6's header for what else has to move if you do.

IT FORWARDS EVERY PARAMETER, BY NAME -- INCLUDING @DynamicSql AND @ContextMessage.  Those two are called out because an
earlier version accepted them and then did not pass them on: the wrapper's own signature declared them, callers dutifully
supplied them, and the inner procedure was called positionally without them, so both columns were NULL on every row in
the database.  That is the exact failure mode named in section 6 -- positional forwarding in a wrapper -- and it cost the
two columns most useful for debugging a dynamic-SQL failure.  Named forwarding is not a style preference here.

IT DOES NOT SWALLOW, AND IT DOES NOT NEED TO.  The inner procedure swallows everything, so nothing can escape this one
except a failure to resolve the inner procedure itself -- which is a deployment problem, not a runtime one, and should
be loud.

========================================================================================================================
Example Usage and Performance:

exec logs.uspRecordExecutionError
      @ProcedureName   = N'[dbo].[uspSoftDeleteFacilitySource]'
    , @KeyParameters   = N'FacilityId=MD0000123456'
    , @ExecutionLogId  = 22
    , @ErrorMessage    = N'Violation of UNIQUE KEY constraint ... (error 2627, line 68)'
    , @ErrorProcedure  = N'uspSoftDeleteFacilitySource'
    , @ErrorNumber     = 2627
    , @ErrorLine       = 68;

One EXEC plus one MERGE.  Failure path only.

========================================================================================================================
Modification History:

Date:		2026-09-13
Author:		rsincero
Ticket:		N/A
Description:
Brought into line with the skill, and the parameter list matched to templates/procedure.sql.  @DynamicSql and
@ContextMessage are now actually forwarded; previously they were accepted and dropped.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE logs.uspRecordExecutionError
      @ProcedureName   NVARCHAR (300)
    , @KeyParameters   NVARCHAR (MAX) = NULL
    , @ExecutionLogId  BIGINT         = NULL
    , @ErrorMessage    NVARCHAR (MAX) = NULL
    , @ErrorProcedure  NVARCHAR (300) = NULL
    , @ErrorNumber     INT            = NULL
    , @ErrorLine       INT            = NULL
    , @DynamicSql      NVARCHAR (MAX) = NULL
    , @ContextMessage  NVARCHAR (MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- OFF for the same reason as section 7: this runs inside the caller's CATCH.
    SET XACT_ABORT OFF;

    -- BEST PRACTICE FOR CENTRALISED LOGGING: replace this with the static four-part name. See the header.
    -- EXEC [LoggingServer].[LoggingDatabase].logs.uspRecordExecutionErrorUpdate
    EXEC logs.uspRecordExecutionErrorUpdate
          @ProcedureName   = @ProcedureName
        , @KeyParameters   = @KeyParameters
        , @ExecutionLogId  = @ExecutionLogId
        , @ErrorMessage    = @ErrorMessage
        , @ErrorProcedure  = @ErrorProcedure
        , @ErrorNumber     = @ErrorNumber
        , @ErrorLine       = @ErrorLine
        , @DynamicSql      = @DynamicSql
        , @ContextMessage  = @ContextMessage;

    RETURN 0;
END
GO


/***********************************************************************************************************************
   *** 9. Extended properties ***

MS_Description on logs.ExecutionLog, on every one of its columns, and on all four procedures -- SKILL.md rule 4.

Always through util.uspSetObjectDescription, which adds or updates: sp_addextendedproperty fails on the second run
("Property already exists") and sp_updateextendedproperty fails on the first, so neither is re-runnable on its own.

Driven from a table of values rather than one EXEC per column, for the same reason as section 14 of logdBChanges.sql:
twenty-odd descriptions as separate six-line EXEC blocks would be a hundred and fifty lines of near-identical text.
The helper is still the only thing that touches sys.extended_properties.

Skipped in full when util.uspSetObjectDescription is not in the database.  This file is run against databases that do
not have the util helpers, and execution logging must still deploy there -- rule 8 does not wait for rule 4.  Deploy
templates/extended-properties.sql and re-run this file to fill them in.
***********************************************************************************************************************/

IF OBJECT_ID (N'util.uspSetObjectDescription', N'P') IS NULL
    PRINT N'util.uspSetObjectDescription not found; MS_Description descriptions skipped. Deploy templates/extended-properties.sql and re-run this file.';
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

    -- The table and its columns -------------------------------------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logs', N'TABLE', N'ExecutionLog', NULL, N'One row per call of an instrumented stored procedure: when it started, how long it took, whether it succeeded, and the error if it did not. Written by logs.uspStartExecutionLogging at the start of a call and closed by the calling procedure''s own completion UPDATE after its COMMIT. This is the table the monitoring web app reads. Not system-versioned: a log row is written once and updated once, and the rows are themselves the audit trail.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ExecutionLogId', N'Surrogate key, and the value logs.uspStartExecutionLogging returns to the caller so it can close its own row. IDENTITY, so it never goes backwards.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ProcedureName', N'Fully-qualified name of the procedure that ran, as QUOTENAME output, e.g. [dbo].[uspSoftDeleteFacilitySource]. The column the monitoring app groups by, which is why templates/procedure.sql falls back to a hard-coded literal rather than allowing NULL when OBJECT_NAME(@@PROCID) is unavailable. nvarchar(300) to match that template.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'KeyParameters', N'The arguments the call was made with, as a short readable string. IDENTIFIERS AND COUNTS ONLY -- never a credential, never an API key or bearer token, never a URL query string, never a request header, and never a payload parameter. This table is retained and is read through a web app, so a secret written here has been published.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'StartDateUtc', N'UTC time the call began, captured by the CALLER before its own work started rather than by the logging procedure. Not the time this row was inserted -- see auditCreatedDateUtc for that; the two differ by however long the EXEC took.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'EndDateUtc', N'UTC time the call finished, successfully or not. NULL means the call never came back: the process was killed, the connection dropped, or the server restarted mid-call. Combined with Successful = 0 that is the signature of an abandoned call rather than a recorded failure.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ElapsedMilliseconds', N'Duration of the call in milliseconds, computed and written by the CALLER, clamped to int range against a call left running for more than 25 days. Nothing on this table recomputes it -- there is deliberately no trigger. NULL for a call that never finished.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'Successful', N'1 only after the call committed and its completion UPDATE ran. Defaults to 0, so an interrupted call reads as unsuccessful rather than as unknown. Never set to 1 by the error path.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'Comments', N'Whatever the procedure chose to record about what it did, typically a row count. Subject to the same restriction as KeyParameters: no credentials, no payload.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ReCreatedAfterRollback', N'1 when this row was re-created in the caller''s CATCH because a ROLLBACK destroyed the original. Passed in by the caller, never inferred: the rollback destroys the evidence that there was a first row, so nothing can work it out afterwards. Without this column a failure and a failure-after-rollback are indistinguishable.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ErrorMessage', N'ERROR_MESSAGE() with the error number and line appended by the caller. Prefixed with a note when no start row was open for the call -- which is expected for an error-only instrumented read and a defect for a write.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ErrorProcedure', N'ERROR_PROCEDURE() -- the procedure the error was RAISED in, which for a nested call is not the procedure named in ProcedureName. Compare the two to see how deep the failure was.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ErrorNumber', N'ERROR_NUMBER(). The original number, because the templates re-raise with a bare THROW rather than RAISERROR -- so 1205 (deadlock) stays distinguishable from 2627 (unique violation) and from 50000 (argument validation).')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ErrorLine', N'ERROR_LINE() within ErrorProcedure. Line numbers are relative to the module definition, so they move when the module is edited; read them against the version of the definition that was deployed at StartDateUtc, which logsData.DdlObjectState can supply if DDL change logging is installed.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'DynamicSql', N'The statement text when the failure was inside dynamic SQL, assigned by the procedure before it executed the batch. NULL otherwise. Subject to the KeyParameters restriction -- a dynamic statement with a literal secret in it must not be recorded here.')
    , (N'logs', N'TABLE', N'ExecutionLog', N'ContextMessage', N'Whatever the procedure chose to say about its own state to make the failure debuggable. An error-only instrumented read sets it to explain why its ExecutionLogId is NULL by design. Also carries the ExecutionLogId the caller passed when no row matched it. Subject to the KeyParameters restriction.');

    -- The audit block.  Wording is identical on every table in this project; only the table name changes.
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description)
    SELECT N'logs', N'TABLE', N'ExecutionLog', c.ColumnName, c.Description
      FROM (VALUES
              (N'IsDeleted', N'Soft-delete flag. 1 = deleted, 0 = active. This database performs no hard deletes; all reads must filter IsDeleted = 0, and every index on this table is filtered on it. A soft-deleted execution log row is unusual enough to be worth asking about.')
            , (N'auditDeletedBy', N'Login that soft-deleted the row. Populated by default only; meaningful when IsDeleted = 1.')
            , (N'auditDeletedDateUtc', N'UTC timestamp of the soft delete. Meaningful when IsDeleted = 1; must be set explicitly by the deleting statement.')
            , (N'auditCreatedBy', N'Login that inserted the row -- which for this table is the login that ran the instrumented procedure, since logging runs in the caller''s security context and not under EXECUTE AS.')
            , (N'auditCreatedDateUtc', N'UTC timestamp of row insert. Distinct from StartDateUtc, which is the caller''s own clock reading from before it called into logging.')
            , (N'auditModifiedBy', N'Login that last modified the row -- normally the same login again, from the completion UPDATE or the error MERGE.')
            , (N'auditModifiedDateUtc', N'UTC timestamp of last modification, i.e. when the row was closed. The DEFAULT fires on INSERT only, so both the completion UPDATE and the error MERGE set this column explicitly.')
         ) AS c (ColumnName, Description);

    -- The four procedures -------------------------------------------------------------------------------------------
    INSERT @Descriptions (SchemaName, ObjectType, ObjectName, ColumnName, Description) VALUES
      (N'logs', N'PROCEDURE', N'uspStartExecutionLogging', NULL, N'Opens a logs.ExecutionLog row for a call that is starting and returns its key through @ExecutionLogId OUTPUT. Called at the top of every fully instrumented procedure''s TRY block, and again in its CATCH if a rollback destroyed the row. A thin wrapper over logs.uspStartExecutionLoggingInsert, kept as the seam that lets logging be redirected to a central database without editing any caller. THROWS on failure, unlike the error-recording pair. Exempt from rule 8: it cannot instrument itself.')
    , (N'logs', N'PROCEDURE', N'uspStartExecutionLoggingInsert', NULL, N'Does the INSERT for logs.uspStartExecutionLogging and returns SCOPE_IDENTITY(). Not called directly -- call the wrapper. Throws 50000 if no key came back, because a start row that is never closed renders in the monitoring grid as a call that never returned. Exempt from rule 8.')
    , (N'logs', N'PROCEDURE', N'uspRecordExecutionError', NULL, N'Records a failure onto the logs.ExecutionLog row the call opened, or inserts an orphan row if there was none. Called from the CATCH block of every instrumented procedure, write or read. A thin wrapper over logs.uspRecordExecutionErrorUpdate; it forwards every parameter by name, including @DynamicSql and @ContextMessage. Exempt from rule 8.')
    , (N'logs', N'PROCEDURE', N'uspRecordExecutionErrorUpdate', NULL, N'Does the MERGE for logs.uspRecordExecutionError: updates the open row when @ExecutionLogId matches one, inserts a row noting that none was open when it does not. Swallows every error it hits, deliberately and with an empty CATCH, because it runs inside the caller''s CATCH and must not replace the error being reported. Not called directly -- call the wrapper. Exempt from rule 8.');

    -- Apply -----------------------------------------------------------------------------------------------------------
    DECLARE @RowNo int = 1,
            @MaxRowNo int,
            @Sch sysname, @OTy sysname, @Obj sysname, @Col sysname, @Dsc nvarchar(3750);

    SELECT @MaxRowNo = MAX (RowNo) FROM @Descriptions;

    WHILE @RowNo <= @MaxRowNo
    BEGIN
        SELECT @Sch = SchemaName, @OTy = ObjectType, @Obj = ObjectName, @Col = ColumnName, @Dsc = Description
          FROM @Descriptions
         WHERE RowNo = @RowNo;

        -- Skip a column this database does not have.  Section 3 adds the ones it can, but a database carrying an older
        -- table that section 3 has not been run against yet should get the descriptions it CAN take rather than fail.
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

    PRINT N'MS_Description applied to logs.ExecutionLog, every one of its columns, and the four logging procedures.';
END
GO


-- *** 10. Grants, and the closing report ***

-- Each procedure carries its own object-level GRANT EXECUTE, to only the roles that call it.  That is what makes the
-- permission report at the end of the permission script an authoritative answer to what the applications can do -- a
-- schema-wide GRANT EXECUTE ON SCHEMA::logs would silently include every procedure added to the schema later.
--
-- Guarded on the role existing, which is what keeps this file re-runnable across databases that do not all have the
-- same roles.  Note the cost of that guard: a TYPO in a role name is a silent no-op, producing procedures nobody can
-- execute and no error to say why.  Check the names against the permission script's own report.
--
-- applicationRole is the writers: every procedure instrumented under rule 8 calls both wrappers.  It gets EXECUTE on the two
-- WRAPPERS ONLY.  The inner procedures are deliberately not granted -- a caller that reaches past the wrapper defeats
-- the redirection seam described in sections 6 and 8, and ownership chaining means the wrapper can still call them.
IF DATABASE_PRINCIPAL_ID (N'applicationRole') IS NOT NULL
BEGIN
    GRANT EXECUTE ON logs.uspStartExecutionLogging TO applicationRole;
    GRANT EXECUTE ON logs.uspRecordExecutionError  TO applicationRole;
    PRINT N'Granted EXECUTE on the two logging wrappers to applicationRole.';
END
GO

-- No GRANT of INSERT or UPDATE on logs.ExecutionLog to anybody.  The INSERTs happen inside the procedures above, and
-- the completion UPDATE in templates/procedure.sql reaches the table through OWNERSHIP CHAINING from the calling
-- procedure's schema -- which is what section 1's ALTER AUTHORIZATION exists to guarantee.  If you find yourself
-- wanting to grant UPDATE here, the owner is wrong; fix that instead.
GO

-- Readers: the monitoring web app and anyone diagnosing a failure.  SELECT only.
IF DATABASE_PRINCIPAL_ID (N'readOnlyRole') IS NOT NULL
BEGIN
    GRANT SELECT ON logs.ExecutionLog TO readOnlyRole;
    PRINT N'Granted SELECT on logs.ExecutionLog to readOnlyRole.';
END
GO

-- Prints where the subsystem stands, so a deployment does not have to be trusted on the strength of having run.
-- Read-only: it reports, it does not repair.
PRINT N'';
PRINT N'=== Execution logging: install report ===';
GO

DECLARE @Report TABLE (Severity int, Status varchar(10), Item nvarchar(300), Detail nvarchar(1000));

-- The table, and the columns the templates actually require.  A column missing here is not cosmetic: the completion
-- UPDATE in templates/procedure.sql names ElapsedMilliseconds and Successful by name and fails without them.
INSERT @Report (Severity, Status, Item, Detail)
SELECT CASE WHEN OBJECT_ID (N'logs.ExecutionLog', N'U') IS NULL THEN 1 ELSE 4 END
     , CASE WHEN OBJECT_ID (N'logs.ExecutionLog', N'U') IS NULL THEN 'MISSING' ELSE 'OK' END
     , N'logs.ExecutionLog'
     , CASE WHEN OBJECT_ID (N'logs.ExecutionLog', N'U') IS NULL
            THEN N'The table does not exist. Nothing instrumented under rule 8 can run. Re-run section 2.'
            ELSE N'Present.' END;

INSERT @Report (Severity, Status, Item, Detail)
SELECT 1, 'MISSING', N'logs.ExecutionLog.' + c.ColumnName
     , N'Required by the instrumentation templates. Re-run section 3.'
  FROM (VALUES (N'ExecutionLogId'), (N'ProcedureName'), (N'KeyParameters'), (N'StartDateUtc'), (N'EndDateUtc')
             , (N'ElapsedMilliseconds'), (N'Successful'), (N'Comments'), (N'ReCreatedAfterRollback')
             , (N'ErrorMessage'), (N'ErrorProcedure'), (N'ErrorNumber'), (N'ErrorLine')
             , (N'DynamicSql'), (N'ContextMessage')
             , (N'IsDeleted'), (N'auditDeletedBy'), (N'auditDeletedDateUtc')
             , (N'auditCreatedBy'), (N'auditCreatedDateUtc'), (N'auditModifiedBy'), (N'auditModifiedDateUtc')
       ) AS c (ColumnName)
 WHERE OBJECT_ID (N'logs.ExecutionLog', N'U') IS NOT NULL
   AND COL_LENGTH (N'logs.ExecutionLog', c.ColumnName) IS NULL;

-- The four procedures.
INSERT @Report (Severity, Status, Item, Detail)
SELECT CASE WHEN OBJECT_ID (p.QualifiedName, N'P') IS NULL THEN 1 ELSE 4 END
     , CASE WHEN OBJECT_ID (p.QualifiedName, N'P') IS NULL THEN 'MISSING' ELSE 'OK' END
     , p.QualifiedName
     , CASE WHEN OBJECT_ID (p.QualifiedName, N'P') IS NULL
            THEN N'Not present. Every instrumented procedure that calls it fails on its first call.'
            ELSE N'Present.' END
  FROM (VALUES (N'logs.uspStartExecutionLogging'), (N'logs.uspStartExecutionLoggingInsert')
             , (N'logs.uspRecordExecutionError'),  (N'logs.uspRecordExecutionErrorUpdate')
       ) AS p (QualifiedName);

-- Ownership chaining, which the completion UPDATE depends on and which nothing else in this file can detect a break in.
INSERT @Report (Severity, Status, Item, Detail)
SELECT CASE WHEN p.name = N'dbo' THEN 4 ELSE 2 END
     , CASE WHEN p.name = N'dbo' THEN 'OK' ELSE 'PROBLEM' END
     , N'Owner of schema [logs]'
     , CASE WHEN p.name = N'dbo'
            THEN N'dbo. Ownership chaining from a calling procedure''s schema will work.'
            ELSE N'Owned by [' + p.name + N'], not dbo. The completion UPDATE in templates/procedure.sql will fail with '
               + N'a permission error inside the instrumentation block of procedures whose own logic is fine. '
               + N'Fix: ALTER AUTHORIZATION ON SCHEMA::logs TO dbo;' END
  FROM sys.schemas AS s
  JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
 WHERE s.name = N'logs';

-- Rule 4, reported rather than assumed: a missing description is a finding, not a silent skip.
INSERT @Report (Severity, Status, Item, Detail)
SELECT 3, 'STALE', N'MS_Description on logs.ExecutionLog'
     , CONVERT (nvarchar(10), COUNT (*)) + N' column(s) have no MS_Description. '
     + CASE WHEN OBJECT_ID (N'util.uspSetObjectDescription', N'P') IS NULL
            THEN N'util.uspSetObjectDescription is not in this database, so section 9 was skipped. Deploy '
               + N'templates/extended-properties.sql and re-run this file.'
            ELSE N'Section 9 ran, so these are columns it does not know about -- add them to its @Descriptions table.' END
  FROM sys.columns AS c
 WHERE c.object_id = OBJECT_ID (N'logs.ExecutionLog')
   AND NOT EXISTS (SELECT 1
                     FROM sys.extended_properties AS ep
                    WHERE ep.major_id = c.object_id
                      AND ep.minor_id = c.column_id
                      AND ep.class    = 1
                      AND ep.name     = N'MS_Description')
HAVING COUNT (*) > 0;

-- The legacy table, carried into the report so it is not only a PRINT that scrolled past.
INSERT @Report (Severity, Status, Item, Detail)
SELECT 3, 'INFO', N'logs.execution_log'
     , N'The previous generation of this table is still present and is not written by anything in this skill. '
     + N'Nothing here renames or drops it. See section 2 for the copy-across statement.'
 WHERE OBJECT_ID (N'logs.execution_log', N'U') IS NOT NULL;

-- The trigger the earlier design put on the log table.  Present means something is recomputing ElapsedMilliseconds
-- behind the template's back, at second resolution.
INSERT @Report (Severity, Status, Item, Detail)
-- OBJECT_SCHEMA_NAME, not SCHEMA_NAME (t.schema_id): sys.triggers has NO schema_id column. A DML trigger takes its
-- schema from its parent rather than carrying its own, which is also why util.uspSetObjectDescription has to resolve
-- the parent to address one.
SELECT 2, 'PROBLEM', N'Trigger ' + QUOTENAME (OBJECT_SCHEMA_NAME (t.object_id)) + N'.' + QUOTENAME (t.name)
     , N'A trigger exists on logs.ExecutionLog. This design has none: elapsed time is computed once by the caller. '
     + N'A trigger here overwrites that value and rewrites every updated row on the highest-write table in the '
     + N'database. Review it before keeping it.'
  FROM sys.triggers AS t
 WHERE t.parent_id = OBJECT_ID (N'logs.ExecutionLog');

IF EXISTS (SELECT 1 FROM @Report WHERE Severity <= 2)
    PRINT N'Execution logging: PROBLEMS found. Read the report below before treating this install as done.';
ELSE
    PRINT N'Execution logging: no problems found.';

SELECT Severity, Status, Item, Detail
  FROM @Report
 ORDER BY Severity, Item;
GO
