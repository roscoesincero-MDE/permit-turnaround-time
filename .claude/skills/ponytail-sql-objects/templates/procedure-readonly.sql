-- SET XACT_ABORT ON sits ABOVE the header block deliberately: the GO on the next line ends the batch,
-- sys.sql_modules stores only the batch containing CREATE, and a header after that GO is invisible to
-- sp_helptext, OBJECT_DEFINITION and SSMS "Script as CREATE". The header has to be the LAST thing before
-- CREATE with no batch separator between them. templates/procedure.sql gives the long version, including
-- how eleven procedures came to be deployed with no stored header at all.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER, which is not optional here: sqlcmd defaults it OFF where every other client
-- defaults it ON, the setting is BAKED IN at CREATE time, and a module carrying it OFF cannot run DML
-- against a table with a filtered index (error 1934). This procedure only reads, so 1934 is not its own
-- problem -- but the setting is a property of the module, so it is set here too rather than left to depend
-- on which client happened to deploy it. validate-sql.py rejects a script that CREATEs an object without it.
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspGetFacilitySourcePage
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

One page of active facility source records, for a grid. Reads only; writes nothing.

========================================================================================================================
Requirements and Key Dependencies:

dbo.vwFacilitySource -- read through the view, never the base table, so the IsDeleted = 0 filter is applied in one place.

logs.uspRecordExecutionError, for the error-only instrumentation block. NOT logs.uspStartExecutionLogging: see below.
It is installed by scripts/logExecutionLogging.sql, which must have been run against the database before this procedure
is deployed -- the failure otherwise arrives on the first CALL THAT RAISES, which is the worst possible time to
discover it.

========================================================================================================================
Notes:

THIS IS THE ERROR-ONLY TEMPLATE. Use it for a procedure that READS AND NOTHING ELSE. A procedure that reads and also
writes, writes -- copy templates/procedure.sql instead and instrument it fully. `references/instrumentation.md` is the
authority for both shapes and for the reasoning below; read it before changing this block.

What error-only means, precisely: the header block, SET NOCOUNT ON, SET XACT_ABORT ON, TRY/CATCH whose CATCH records,
and a bare ;THROW;. What it drops is the SUCCESSFUL path only -- no logs.uspStartExecutionLogging call, no completion
UPDATE, no resurrection block. And no transaction, because nothing writes.

WHY READS ARE OPT-IN. Decided at the design review on 2026-09-05. On a write, two extra round trips and one log row
are nothing next to the merge itself; on a read they are not. A monitoring page that refreshes is the highest-frequency
caller in the system, and instrumenting every read turns logs.ExecutionLog into a record of people looking at things --
which is also how it fills up. A probe defect wrote about 70,000 rows in one afternoon. logs.uspGetExecutionLogPage is
the one deliberately instrumented read, kept as the standing witness that rule 8 wrapping does not break a result set a
client has to materialize.

A READ STILL RECORDS ITS FAILURES. This is the part that gets dropped by accident. A review finding,
worth stating in full: a procedure whose body was a single SELECT called a scalar UDF inside that SELECT, the UDF
errored, and NOTHING was recorded anywhere -- because "it only reads" had been read as "it cannot fail in a way worth
recording". A read owns no INSERT, but everything it touches can fail: a UDF, a view over a view, a computed column, a
conversion, a deadlock, a permission it turns out not to hold. Hence the CATCH below, which is not optional.

DO NOT ADD HALF A START BLOCK. A start row that is never completed makes every call read as a failure in the monitoring
grid. Either instrument fully or instrument the CATCH only; there is no third shape.

@ExecutionLogId IS ALWAYS NULL, AND THAT IS THE POINT. No start row was opened, so there is nothing to update. NULL
sends logs.uspRecordExecutionErrorUpdate's MERGE down its NOT MATCHED branch, which inserts a row and notes that
execution logging never started for this call. On a fully instrumented procedure that state means a start row was LOST,
which is a defect in the logging chain; here it is correct. So the call passes a @ContextMessage saying so, or every
read failure in the database reads as a second, imaginary defect.

NO TRANSACTION, AND NO ROLLBACK IN THE CATCH. Nothing here writes, so there is nothing of this procedure's to roll back.
If a CALLER has a transaction open and the error dooms it (XACT_STATE () = -1), the INSERT in uspRecordExecutionError
cannot write and that procedure swallows it by design: the row is lost while the error still reaches the caller. Rolling
the caller's transaction back to make the write possible would be worse -- it is not this procedure's transaction to
end. EF Core calls these reads without an ambient transaction, so the common path records. That limit is stated rather
than glossed; do not "fix" it by adding a rollback here.

@ProcName FALLS BACK TO A LITERAL, AND THE LITERAL IS THE ONE THAT ACTUALLY GETS USED. OBJECT_NAME (@@PROCID) and
OBJECT_SCHEMA_NAME (@@PROCID) return NULL for a principal denied metadata visibility, and the permission model denies exactly that
to both application logins -- so the COALESCE is not a guard for ad-hoc batches, it is the branch every application call
takes. The fallback must be this procedure's OWN name as a literal, matching QUOTENAME output exactly, and never a
placeholder and never the name copied out of this template: ProcedureName is the column the monitoring web app groups
by. The dynamic half stays because it still resolves for the developer and it catches a rename. Change both when
renaming the procedure.

WHAT @KeyParameters MAY CONTAIN. Identifiers and counts. Never a credential, never an API key or bearer token, never a
URL query string, never a request header, and never a payload parameter. The same restriction applies to @ContextMessage
and @DynamicSql. A read's parameters are often exactly the user's search terms, so this needs more attention here than
in a write procedure, not less: paging and sort arguments are safe, a free-text search box is not.

ARGUMENT VALIDATION THROWS 50000, INSIDE THE TRY. Inside, so the CATCH records the rejection under this procedure's name
-- a client sending an unsupported @SortBy is something worth seeing in the log, not something to swallow. 50000 is the
argument-validation number in this database; 50010 is an immutable-key rejection through a view.

@SortBy IS WHITELISTED, NOT INTERPOLATED. There is no dynamic SQL here at all: one CASE per sortable column in the
ORDER BY. A single CASE would force every branch's type to converge, so each column gets its own. If a read ever does
need dynamic SQL, it passes identifiers through QUOTENAME and assigns the statement to @DynamicSql so a failure is
recorded with the text that failed.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspGetFacilitySourcePage @FacilityId = 'MD0000123456', @PageNumber = 1, @PageSize = 50, @SortBy = 'Sequence'

Seeks on UX_dbo_FacilitySource_Natural when @FacilityId is supplied; scans the filtered index otherwise. Adds no log row
on the successful path -- one row on failure only. OFFSET/FETCH re-reads the rows it skips, so deep paging costs more
than shallow paging; a keyset (seek) page is the fix if that ever matters.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspGetFacilitySourcePage
      @FacilityId  VARCHAR (12) = NULL
    , @PageNumber INT          = 1
    , @PageSize   INT          = 50
    , @SortBy     NVARCHAR (30) = N'FacilityId'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- =============================================================================================
    -- Rule 8 error-only instrumentation. Boilerplate: copy verbatim.
    -- Shorter than the full block by exactly what a read does not need. Do not reintroduce
    -- @ExecutionId, @StartTimeUtc, @EndTimeUtc or @Comments -- they belong to the successful path,
    -- and a start row without a completion makes every call look like a failure.
    -- =============================================================================================
    -- The literal is what the application logins actually log, because metadata visibility is denied
    -- to them. Keep it in step with the CREATE OR ALTER PROCEDURE name above.
    DECLARE @ProcName       NVARCHAR (300) = COALESCE (QUOTENAME (OBJECT_SCHEMA_NAME (@@PROCID))
                                                     + N'.' + QUOTENAME (OBJECT_NAME (@@PROCID))
                                                    , N'[dbo].[uspGetFacilitySourcePage]')
          , @KeyParameters  NVARCHAR (MAX) = NULL
          , @ContextMessage NVARCHAR (MAX) = NULL
          , @DynamicSql     NVARCHAR (MAX) = NULL
          , @ErrorMsg       NVARCHAR (MAX) = NULL
          , @ErrorProc      NVARCHAR (300) = NULL
          , @ErrorNumber    INT            = NULL
          , @ErrorLine      INT            = NULL;

    -- Identifiers and counts ONLY. See "WHAT @KeyParameters MAY CONTAIN" in the header.
    SET @KeyParameters = CONCAT (N'FacilityId=',    @FacilityId
                               , N', PageNumber=', @PageNumber
                               , N', PageSize=',   @PageSize
                               , N', SortBy=',     @SortBy);

    -- Says why the row this procedure logs has no ExecutionLogId, so the orphan is not read as a
    -- second defect. Copy this line as it stands; only the procedure name changes.
    SET @ContextMessage = N'Error-only instrumented read: no start row is opened, so @ExecutionLogId is NULL by design.';

    BEGIN TRY

        -- Validation inside the TRY, so a bad argument is recorded rather than swallowed.
        IF @PageNumber < 1
        BEGIN
            ;THROW 50000, N'@PageNumber must be 1 or greater.', 1;
        END;

        IF @PageSize NOT BETWEEN 1 AND 500
        BEGIN
            ;THROW 50000, N'@PageSize must be between 1 and 500.', 1;
        END;

        -- Whitelist. An unsupported value is rejected, never interpolated.
        IF @SortBy NOT IN (N'FacilityId', N'FacilityName', N'Sequence', N'auditModifiedDateUtc')
        BEGIN
            ;THROW 50000, N'@SortBy must be one of FacilityId, FacilityName, Sequence, auditModifiedDateUtc.', 1;
        END;

        -- =========================================================================================
        -- ===== The procedure's own work starts here. Everything above and below is boilerplate. ==
        -- =========================================================================================

        -- Through the view, so the soft-delete filter is applied in one place.
        SELECT
              fs.FacilitySourceId
            , fs.FacilityId
            , fs.ActivityLocation
            , fs.SourceType
            , fs.Sequence
            , fs.FacilityName
            , fs.CurrentRecord
            , fs.auditModifiedBy
            , fs.auditModifiedDateUtc
          FROM dbo.vwFacilitySource AS fs
         WHERE (@FacilityId IS NULL OR fs.FacilityId = @FacilityId)
         -- One CASE per sortable column. A single CASE with branches of different types would force
         -- them to converge -- an int and a datetime2 under one CASE is a conversion error at
         -- runtime, or a silent implicit conversion that discards the index.
         ORDER BY CASE WHEN @SortBy = N'FacilityId'            THEN fs.FacilityId            END
                , CASE WHEN @SortBy = N'FacilityName'          THEN fs.FacilityName          END
                , CASE WHEN @SortBy = N'Sequence'             THEN fs.Sequence             END
                , CASE WHEN @SortBy = N'auditModifiedDateUtc' THEN fs.auditModifiedDateUtc END
                -- Deterministic tiebreak. Without it two calls for the same page can return
                -- different rows, and a grid silently drops or duplicates records across pages.
                , fs.FacilitySourceId
        OFFSET (@PageNumber - 1) * @PageSize ROWS
         FETCH NEXT @PageSize ROWS ONLY;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        -- Nothing here. No completion UPDATE: there is no row to complete, by design.

    END TRY
    BEGIN CATCH

        -- The ERROR_* functions are valid only in this scope and any statement can reset them, so
        -- capture them before doing anything else.
        SELECT @ErrorNumber = ERROR_NUMBER ()
             , @ErrorProc   = ERROR_PROCEDURE ()
             , @ErrorLine   = ERROR_LINE ()
             , @ErrorMsg    = ERROR_MESSAGE ()
                            + N' (error '  + CAST (ERROR_NUMBER () AS NVARCHAR (11))
                            + N', line '   + CAST (ERROR_LINE ()   AS NVARCHAR (11)) + N')';

        -- No rollback. Nothing here writes, and the caller's transaction is not this procedure's to
        -- end -- see "NO TRANSACTION, AND NO ROLLBACK IN THE CATCH" in the header.

        -- Swallows everything by design, so this call cannot mask the error below it.
        -- @ExecutionLogId is NULL because no start row was opened; @ContextMessage says so, so the
        -- orphan row is not read as a lost start row.
        EXEC logs.uspRecordExecutionError
              @ProcedureName   = @ProcName
            , @KeyParameters   = @KeyParameters
            , @ExecutionLogId  = NULL
            , @ErrorMessage    = @ErrorMsg
            , @ErrorProcedure  = @ErrorProc
            , @ErrorNumber     = @ErrorNumber
            , @ErrorLine       = @ErrorLine
            , @DynamicSql      = @DynamicSql
            , @ContextMessage  = @ContextMessage;

        -- Bare, so the ORIGINAL error number reaches the caller. RAISERROR would make it 50000 and
        -- the client could no longer tell a deadlock from a validation rejection. The leading
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
    , @ObjectName  = N'uspGetFacilitySourcePage'
    , @Description = N'One page of active facility source records for a grid. Reads only; error-only instrumented, so it writes to logs.ExecutionLog on failure and not on success.';
GO

-- Each procedure script carries its own grant, which is what makes the report at the end of script
-- 050 the authoritative answer to what the applications can do. Grant only the roles that call it --
-- for a monitoring read that is the monitor's role, not the loader's.
--
-- Put a REAL role name here. The guard makes a missing principal a silent no-op, which is what keeps
-- the script re-runnable across databases, and is also how a typo'd role name produces a procedure
-- nobody can execute and no error to say why. Check it against the report at the end of scripts/permissions.sql.
IF DATABASE_PRINCIPAL_ID (N'readOnlyRole') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspGetFacilitySourcePage TO readOnlyRole;
END;
GO
