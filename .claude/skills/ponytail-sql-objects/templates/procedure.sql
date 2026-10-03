-- SET XACT_ABORT ON sits ABOVE the header block deliberately, and moving it below would introduce a
-- real defect. The GO on the next line ends the batch, and sys.sql_modules stores only the batch that
-- contains CREATE -- so a header placed AFTER this GO is invisible to anyone reading the procedure out
-- of the database through sp_helptext, OBJECT_DEFINITION, or SSMS "Script as CREATE", which is where a
-- maintainer actually reads it. The header has to be the LAST thing before CREATE with no batch
-- separator between them. `.claude/hooks/validate-sql.py` enforces that; it did not at first, which is
-- how all eleven procedures in this database came to be deployed with no stored header at all while
-- every view kept one.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER, which is not optional here. sqlcmd defaults it OFF where every other client
-- defaults it ON, the setting is BAKED IN at CREATE time, and a module carrying it OFF cannot run DML
-- against a table with a filtered index (error 1934). Every unique constraint in this database is one,
-- via the soft-delete rule -- so that is every table. Set it here so a hand run without sqlcmd -I cannot
-- get it wrong; validate-sql.py rejects a script that CREATEs an object without it.
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspSoftDeleteFacilitySource
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Soft-deletes a facility source record. This database performs no hard deletes: the row is retained with IsDeleted = 1
and the auditDeleted* columns populated.

========================================================================================================================
Requirements and Key Dependencies:

dbo.FacilitySource

logs.uspStartExecutionLogging and logs.uspRecordExecutionError, for the rule 8 instrumentation block, plus
logs.ExecutionLog itself, which the completion UPDATE below writes directly. All three are installed by
scripts/logExecutionLogging.sql -- run it against the database before deploying this procedure, because the failure
otherwise arrives on the first call and not at deploy time. Every procedure an application calls goes through them; the
only exceptions are the five named in SKILL.md rule 8, which are the logging chain itself.

========================================================================================================================
Notes:

Idempotent -- soft-deleting an already-deleted row is a no-op and does not overwrite the original auditDeleted* values.

INSTRUMENTATION. The DECLARE block, the BEGIN TRY, the transaction, the completion UPDATE and the whole CATCH block are
Rule 8 boilerplate. Copy them verbatim. Only four things change from one procedure to the next: the parameter list, the
@KeyParameters string, the work between the two ===== banners, and the @Comments string. Resist the urge to tidy the
boilerplate per procedure -- it is load-bearing in ways the sections below explain, and sixteen slightly different
versions of it is the outcome this template exists to prevent.

@ProcName FALLS BACK TO A LITERAL, AND THE LITERAL IS THE ONE THAT ACTUALLY GETS USED. OBJECT_NAME (@@PROCID) and
OBJECT_SCHEMA_NAME (@@PROCID) return NULL for a principal denied metadata visibility, and the permission model denies exactly that
to both application logins. Measured: a read-only application login holds EXECUTE = 1 on logs.uspGetExecutionLogPage and still gets NULL
from OBJECT_ID (N'logs.uspGetExecutionLogPage'), because a permission on an object is not permission to see its name. The
consequence is that the COALESCE is not a defensive nicety for ad-hoc batches -- it is the branch every application call
takes. So the fallback must be the procedure's OWN name as a literal, matching QUOTENAME output exactly, and never a
placeholder: with '(ad-hoc batch)' there, every row the loader and the monitor wrote had no procedure name in it, which
is the one column the monitoring web app exists to group by. The dynamic half is kept for the developer, where it still
resolves, because it catches a rename that the literal would not. Change both when renaming the procedure.

WHAT @KeyParameters MAY CONTAIN. Identifiers and counts. Never a credential, never an API key or bearer token, never a
URL query string, never a request header, and never a payload parameter -- for this project that means @Payload is
excluded by name, because logging it would copy thousands of regulated-entity records into logs.ExecutionLog, which has a
different read audience and a different retention policy from the tables the payload lands in. The same restriction
applies to @Comments, @ContextMessage and @DynamicSql. The original in-house template said it in one line and it is worth
repeating: do NOT include parameters such as passwords and Personally Identifiable Information.

ONE ROLLBACK, NOT TWO. SET XACT_ABORT ON dooms the transaction on almost any error, so by the time the CATCH block runs
XACT_STATE () is -1 far more often than 1. Both values need the same unqualified ROLLBACK TRANSACTION, so the block tests
XACT_STATE () <> 0 once rather than branching on -1 and 1 separately. A doomed transaction also means SAVE TRANSACTION is
useless here and there is no such thing as partial success inside one of these procedures: either the whole body commits
or none of it does.

WHY THE LOG ROW IS RE-CREATED, AND WHEN IT ACTUALLY IS. The re-creation call exists because a rollback can destroy the row
logs.uspStartExecutionLogging wrote, and without it the only executions never recorded would be the ones that failed.
Note carefully WHEN that happens: the start call is before BEGIN TRANSACTION, so a procedure invoked with no ambient
transaction writes its row in autocommit and the rollback cannot reach it. The row is only lost when the procedure was
called inside a transaction that was ALREADY open -- from another procedure, or from a SqlConnection.BeginTransaction on
the .NET side -- because ROLLBACK TRANSACTION unwinds the outermost transaction, not the inner one. A probe measured
both paths: the flat failure kept its row and completed it, the nested failure lost its row and re-created it. The
re-creation passes the ORIGINAL @StartTimeUtc, so the duration is still the time the call ran, and passes
@ReCreatedAfterRollback = 1, which is how the fact is recorded. Do not try to infer it from
auditCreatedDateUtc > StartDateUtc -- that was the original design and the probe showed it to be clock-tick noise that
fires on successful rows.

NO NOLOCK ON THE EXISTENCE CHECK. The original in-house template read logs.ExecutionLog WITH (NOLOCK) there. It is removed on purpose:
a dirty read is free to return the very row the rollback is discarding, which would make the check conclude the row
survived and skip the re-creation -- the exact failure the check exists to prevent. There is also nothing to avoid, since
the rollback has already released its locks. The check matches on ExecutionLogId alone, with no IsDeleted = 0 filter,
because an in-flight row cannot have been soft-deleted and a filtered miss would insert a duplicate.

THE COMPLETION UPDATE IS AFTER THE COMMIT, AND THAT HAS A CONSEQUENCE. If the COMMIT succeeds and then the completion
UPDATE fails, control reaches the CATCH block with XACT_STATE () = 0, the error is recorded against the existing row, and
the call is reported as failed with a bare THROW even though its work is committed. The caller may then retry. This is
survivable only because every write procedure in this database is idempotent -- the loads are MERGE-based and the soft
delete below is a no-op on an already-deleted row. If you write a procedure whose second run is not harmless, it is wrong
for reasons that go beyond logging.

THROW IS BARE AND PRECEDED BY A SEMICOLON. Bare THROW re-raises the original error with its original number, which is
what lets the .NET client branch on it: 1205 is a deadlock and the call should be retried, 2627 and 547 are constraint
violations and it should not. RAISERROR would replace the number with 50000 and destroy that. The leading semicolon is
required because a bare THROW as the first statement after BEGIN is a syntax error.

ERROR_* ARE CAPTURED FIRST. They are only valid in the CATCH scope and any statement can reset them, so the SELECT that
captures them is the first statement in the block, before the rollback.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspSoftDeleteFacilitySource @FacilityId = 'MD0000123456', @SourceType = 'N', @Sequence = 1

Seeks on UX_dbo_FacilitySource_Natural. Instrumentation adds one singleton insert on every call and one singleton update
on the successful path.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------
					
***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspSoftDeleteFacilitySource
      @FacilityId  VARCHAR (12)
    , @SourceType VARCHAR (2)
    , @Sequence   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- =============================================================================================
    -- Rule 8 instrumentation. Boilerplate: copy verbatim.
    -- =============================================================================================
    -- The literal is not a fallback for odd cases; it is what the application logins actually log,
    -- because metadata visibility is denied to them. See the header note. Keep it in step with the
    -- CREATE OR ALTER PROCEDURE name above.
    DECLARE @ProcName       NVARCHAR (300) = COALESCE (QUOTENAME (OBJECT_SCHEMA_NAME (@@PROCID))
                                                     + N'.' + QUOTENAME (OBJECT_NAME (@@PROCID))
                                                    , N'[dbo].[uspSoftDeleteFacilitySource]')
          -- DATETIME2 (3), with the precision written out. Rule 1 is about every datetime in the
          -- skill, not only columns: both values are compared and subtracted against
          -- logs.ExecutionLog.StartDateUtc, which is DATETIME2 (3). A bare DATETIME2 is DATETIME2 (7)
          -- -- a different type, so @StartTimeUtc would be rounded on the way into the start
          -- procedure and the ElapsedMilliseconds arithmetic would then run against a value the log
          -- does not hold.
          , @StartTimeUtc   DATETIME2 (3)  = SYSUTCDATETIME ()
          , @EndTimeUtc     DATETIME2 (3)  = NULL
          , @ExecutionId    BIGINT         = NULL
          , @KeyParameters  NVARCHAR (MAX) = NULL
          , @Comments       NVARCHAR (MAX) = NULL
          , @ContextMessage NVARCHAR (MAX) = NULL
          , @DynamicSql     NVARCHAR (MAX) = NULL
          , @ErrorMsg       NVARCHAR (MAX) = NULL
          , @ErrorProc      NVARCHAR (300) = NULL
          , @ErrorNumber    INT            = NULL
          , @ErrorLine      INT            = NULL;

    -- Identifiers and counts ONLY. See "WHAT @KeyParameters MAY CONTAIN" in the header.
    SET @KeyParameters = CONCAT (N'FacilityId=',    @FacilityId
                               , N', SourceType=', @SourceType
                               , N', Sequence=',   @Sequence);

    BEGIN TRY

        EXEC logs.uspStartExecutionLogging
              @ProcedureName          = @ProcName
            , @KeyParameters          = @KeyParameters
            , @StartDateUtc           = @StartTimeUtc
            , @ReCreatedAfterRollback = 0
            , @ExecutionLogId         = @ExecutionId OUTPUT;

        BEGIN TRANSACTION;

        -- =========================================================================================
        -- ===== The procedure's own work starts here. Everything above and below is boilerplate. ==
        -- =========================================================================================

        UPDATE dbo.FacilitySource
           SET IsDeleted            = 1
             , auditDeletedBy       = ORIGINAL_LOGIN ()
             , auditDeletedDateUtc  = SYSUTCDATETIME ()
             , auditModifiedBy      = ORIGINAL_LOGIN ()
             , auditModifiedDateUtc = SYSUTCDATETIME ()
         WHERE FacilityId  = @FacilityId
           AND SourceType = @SourceType
           AND Sequence   = @Sequence
           AND IsDeleted  = 0;   -- idempotent: preserves the original delete audit

        -- @@ROWCOUNT is reset by the next statement, so read it immediately.
        SET @Comments = CONCAT (@@ROWCOUNT, N' row(s) soft-deleted.');

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        IF @@TRANCOUNT > 0
        BEGIN
            COMMIT TRANSACTION;
        END;

        -- Completion. Deliberately after the COMMIT; see the header for what that costs.
        -- auditModifiedDateUtc is set explicitly because its DEFAULT fires on INSERT only.
        SET @EndTimeUtc = SYSUTCDATETIME ();

        IF @ExecutionId IS NOT NULL
        BEGIN
            UPDATE logs.ExecutionLog
               SET EndDateUtc           = @EndTimeUtc
                 , ElapsedMilliseconds  = CAST (LEAST (DATEDIFF_BIG (MILLISECOND, @StartTimeUtc, @EndTimeUtc)
                                                     , CAST (2147483647 AS BIGINT)) AS INT)
                 , Successful           = 1
                 , Comments             = @Comments
                 , auditModifiedBy      = ORIGINAL_LOGIN ()
                 , auditModifiedDateUtc = @EndTimeUtc
             WHERE ExecutionLogId = @ExecutionId;
        END;

    END TRY
    BEGIN CATCH

        -- The ERROR_* functions are valid only in this scope and any statement can reset them, so
        -- capture them before doing anything else -- including before the rollback.
        SELECT @ErrorNumber = ERROR_NUMBER ()
             , @ErrorProc   = ERROR_PROCEDURE ()
             , @ErrorLine   = ERROR_LINE ()
             , @ErrorMsg    = ERROR_MESSAGE ()
                            + N' (error '  + CAST (ERROR_NUMBER () AS NVARCHAR (11))
                            + N', line '   + CAST (ERROR_LINE ()   AS NVARCHAR (11)) + N')';

        -- One test, not two: XACT_ABORT ON makes XACT_STATE () = -1 the common case, and -1 and 1
        -- both need the same unqualified rollback.
        IF XACT_STATE () <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        -- The rollback destroyed the row logs.uspStartExecutionLogging wrote. Put it back, with the
        -- ORIGINAL @StartTimeUtc, or the only unrecorded executions in the database would be the
        -- failures. The nested TRY is required because the start procedure does not swallow: an
        -- error escaping here would replace the error being reported. Nothing to do in its CATCH --
        -- @ExecutionId is left NULL and logs.uspRecordExecutionError writes an orphan row that
        -- explains itself.
        BEGIN TRY
            IF @ExecutionId IS NULL
               OR NOT EXISTS (SELECT 1
                                FROM logs.ExecutionLog
                               WHERE ExecutionLogId = @ExecutionId)
            BEGIN
                EXEC logs.uspStartExecutionLogging
                      @ProcedureName          = @ProcName
                    , @KeyParameters          = @KeyParameters
                    , @StartDateUtc           = @StartTimeUtc
                    , @ReCreatedAfterRollback = 1
                    , @ExecutionLogId         = @ExecutionId OUTPUT;
            END;
        END TRY
        BEGIN CATCH
            SET @ExecutionId = NULL;
        END CATCH;

        -- Swallows everything by design, so this call cannot mask the error below it.
        EXEC logs.uspRecordExecutionError
              @ProcedureName   = @ProcName
            , @KeyParameters   = @KeyParameters
            , @ExecutionLogId  = @ExecutionId
            , @ErrorMessage    = @ErrorMsg
            , @ErrorProcedure  = @ErrorProc
            , @ErrorNumber     = @ErrorNumber
            , @ErrorLine       = @ErrorLine
            , @DynamicSql      = @DynamicSql
            , @ContextMessage  = @ContextMessage;

        -- Bare, so the ORIGINAL error number reaches the caller. RAISERROR would make it 50000 and
        -- the client could no longer tell a deadlock from a constraint violation. The leading
        -- semicolon is required: a bare THROW immediately after BEGIN is a syntax error.
        ;THROW;

    END CATCH;

    RETURN 0;
END;
GO

-- Through the helper, never sp_addextendedproperty directly: CREATE OR ALTER PROCEDURE keeps
-- the object_id, so the extended property survives a re-run and a bare add would then fail with
-- "Property cannot be added. Property already exists."
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'PROCEDURE'
    , @ObjectName  = N'uspSoftDeleteFacilitySource'
    , @Description = N'Soft-deletes one facility source record by natural key. No-op if already deleted.';
GO

-- Each procedure script carries its own grant, which is what makes the report at the end of script
-- 050 the authoritative answer to what the applications can do. Grant only the roles that call it.
IF DATABASE_PRINCIPAL_ID (N'applicationRole') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspSoftDeleteFacilitySource TO applicationRole;
END;
GO
