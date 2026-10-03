-- SET XACT_ABORT ON sits ABOVE the header block deliberately: the GO on the next line ends the batch,
-- sys.sql_modules stores only the batch containing CREATE, and a header after that GO is invisible to
-- sp_helptext, OBJECT_DEFINITION and SSMS "Script as CREATE". The header has to be the LAST thing before
-- CREATE with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER: sqlcmd defaults it OFF where every other client defaults it ON, and the setting is
-- BAKED IN at CREATE time. This procedure writes only its own logs.ExecutionLog row, but the setting is a
-- property of the module, so it is set here rather than left to depend on which client happened to deploy it.
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspPermitTurnaroundPending
Author:       rsincero
CreateDate:   2026-10-02
========================================================================================================================
Description:

Every permit application that is still PENDING -- neither issued nor closed -- whenever it was received, with how much
of its standard turnaround time it has used. One row per activity, the same columns as
dbo.uspPermitTurnaroundPerformance except approval_issued, closedDate and closedType (all NULL by definition here) and
the two period dates, plus

    days_left       std_turnaround_time - derived_days_qty. Negative once the application is past its standard.
    std_used_pct    derived_days_qty / std_turnaround_time, as a fraction: 0.75 = three quarters of the standard used,
                    1.10 = 10% past it. The column to prioritise by, because it compares a 30-day permit and a
                    1,080-day permit on the same scale.

Rows come back most urgent first: highest std_used_pct, then fewest days_left.

Pending means approval_issued IS NULL AND closedDate IS NULL in dbo.vwPermitTurnaroundPerformance, which is that view's
"genuinely open" population (see its header: approval_issued IS NULL alone also returns applications that were
withdrawn, denied or voided). Like the Detail tab, only applications that matched a published standard are listed.

TAKES NO PERIOD. This is the answer to INC0963902: the Detail tab lists applications received, issued or closed in the
reporting period, so it is not the list of everything pending, and its count will not match a pending total taken at
another time or over another range. The optional @ProgramCode, @PermitCategory, @PermitClass, @PermitType and
@SttPermitType filters are exact matches, as on the Detail tab; NULL means all.

Reads only, apart from one logs.ExecutionLog row per call recording its start and end time.

========================================================================================================================
Requirements and Key Dependencies:

dbo.vwPermitTurnaroundPerformance (sql/040), and through it dbo.stdPermitTT, dbo.MtbApprovalTaskList (which decides
closedDate), dbo.AiExclusionList and the EPAL_ISSI synonyms.

logs.ExecutionLog, logs.uspStartExecutionLogging and logs.uspRecordExecutionError (sql/015), for the Rule 8
instrumentation block. INSTALL 015 BEFORE THIS SCRIPT.

========================================================================================================================
Notes:

THE MEASURE IS derived_days_qty, as on the Detail tab: the ETS clock where ETS records days used, calendar days to today
otherwise. So for a permit type that uses the ETS clock, time on hold does not count against the standard and
days_left stops falling while the clock is paused; for one that does not, every calendar day counts. Both kinds are
mixed in one list; days_used_qty IS NULL tells them apart.

THE LIST IS NOT REPRODUCIBLE FROM DAY TO DAY, by design: calendar days run to today, so the same application shows one
day fewer left tomorrow. refresh_date says when the list was taken.

COMPATIBILITY: runs on SQL Server 2019 and later. The ElapsedMilliseconds clamp is a CASE rather than LEAST ().

NO ROW IS DROPPED FOR BAD DATES. An application_received after today gives a negative derived_days_qty and sorts to the
end; the source holds a few far-future received dates (see dbo.vwPermitTurnaroundPerformance), and they stay visible
here as data to correct rather than being hidden. std_used_pct is NULL only if a standard is 0, which no New, Renew or
Renewal standard was on 2026-10-02.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundPending;                                                   -- every pending application
exec dbo.uspPermitTurnaroundPending @ProgramCode = '27', @PermitCategory = 'Scrap Tire';

-- the same population straight from the view: how many pending, and how many past their standard, by program
select program_desc, count (*) as Pending
     , sum (case when derived_days_qty > std_turnaround_time then 1 else 0 end) as PastStandard
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is not null and approval_issued is null and closedDate is null
 group by program_desc order by Pending desc;

One read of dbo.vwPermitTurnaroundPerformance, as for the other report procedures. About 6,000 rows unfiltered on
2026-09-23, when the view's header measured 5,931 genuinely open applications with a standard.

Instrumentation is the full Rule 8 block, as in dbo.uspPermitTurnaroundStandardReduction. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundPending]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-10-02
Author:		rsincero
Ticket:		INC0963902
Description:
Original. Feeds the Pending tab of TurnaroundPerformance.rdl: every application neither issued nor closed, with
days_left and std_used_pct to prioritise by.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundPending
      @PermitCategory VARCHAR (30)   = NULL
    , @PermitClass    VARCHAR (50)   = NULL
    , @PermitType     VARCHAR (100)  = NULL
    , @SttPermitType  VARCHAR (100)  = NULL
    , @ProgramCode    CHAR (2)       = NULL
    , @ReportUser     NVARCHAR (256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- =============================================================================================
    -- Rule 8 instrumentation. Boilerplate: the same block as dbo.uspBuildStdPermitTT.
    -- =============================================================================================
    -- The literal is what the application logins actually log, because metadata visibility is denied
    -- to them. Keep it in step with the CREATE OR ALTER PROCEDURE name above.
    DECLARE @ProcName       NVARCHAR (300) = COALESCE (QUOTENAME (OBJECT_SCHEMA_NAME (@@PROCID))
                                                     + N'.' + QUOTENAME (OBJECT_NAME (@@PROCID))
                                                    , N'[dbo].[uspPermitTurnaroundPending]')
          -- DATETIME2 (3), precision written out, because both are compared and subtracted against
          -- logs.ExecutionLog.StartDateUtc, which is DATETIME2 (3).
          , @StartTimeUtc   DATETIME2 (3)  = SYSUTCDATETIME ()
          , @EndTimeUtc     DATETIME2 (3)  = NULL
          , @ExecutionId    BIGINT         = NULL
          , @RowCount       INT            = NULL
          , @KeyParameters  NVARCHAR (MAX) = NULL
          , @Comments       NVARCHAR (MAX) = NULL
          , @ContextMessage NVARCHAR (MAX) = NULL
          , @DynamicSql     NVARCHAR (MAX) = NULL
          , @ErrorMsg       NVARCHAR (MAX) = NULL
          , @ErrorProc      NVARCHAR (300) = NULL
          , @ErrorNumber    INT            = NULL
          , @ErrorLine      INT            = NULL;

    -- Identifiers and counts ONLY.
    SET @KeyParameters = CONCAT (N'PermitCategory=',   @PermitCategory
                               , N', PermitClass=',    @PermitClass
                               , N', PermitType=',     @PermitType
                               , N', SttPermitType=',  @SttPermitType
                               , N', ProgramCode=',    @ProgramCode
                               -- Who ran it: the SSRS User!UserID. auditCreatedBy is only the data source login.
                               , N', ReportUser=',     @ReportUser);

    BEGIN TRY

        EXEC logs.uspStartExecutionLogging
              @ProcedureName          = @ProcName
            , @KeyParameters          = @KeyParameters
            , @StartDateUtc           = @StartTimeUtc
            , @ReCreatedAfterRollback = 0
            , @ExecutionLogId         = @ExecutionId OUTPUT;

        -- =========================================================================================
        -- ===== The procedure's own work starts here. Everything above and below is boilerplate. ==
        -- =========================================================================================

        SET @ContextMessage = N'phase=select';

        SELECT
              v.INT_DOC_ID
            , v.ACTIVITY_ID
            , v.master_ai_id
            , v.permit_category
            , v.permit_class
            , v.permit_type
            , v.stt_permit_type
            , v.stt_sortorder
            , v.program_code
            , v.program_desc
            , v.activity_category_code
            , v.activity_class_code
            , v.activity_type_code
            , v.project_type
            , v.application_received
            , v.days_used_qty
            , v.calendar_days_qty
            , v.derived_days_qty
            , v.turnaround_time
            , v.alt_turnaround_time
            , v.std_turnaround_time
            , CAST (v.std_turnaround_time - v.derived_days_qty AS DECIMAL (12, 3))                   AS days_left
              -- NULLIF only guards a zero standard; none of the measured classes has one today.
            , CAST (1.0 * v.derived_days_qty / NULLIF (v.std_turnaround_time, 0) AS DECIMAL (12, 4)) AS std_used_pct
            , SYSDATETIME ()                                                                          AS refresh_date
          FROM dbo.vwPermitTurnaroundPerformance AS v
         WHERE v.std_turnaround_time IS NOT NULL
           -- Pending: not issued AND not closed. approval_issued IS NULL alone also returns withdrawn, denied and
           -- voided applications; see the header of dbo.vwPermitTurnaroundPerformance.
           AND v.approval_issued IS NULL
           AND v.closedDate      IS NULL
           -- NULL = all. Exact match otherwise.
           AND (@PermitCategory IS NULL OR v.permit_category = @PermitCategory)
           AND (@PermitClass    IS NULL OR v.permit_class    = @PermitClass)
           AND (@PermitType     IS NULL OR v.permit_type     = @PermitType)
           AND (@SttPermitType  IS NULL OR v.stt_permit_type = @SttPermitType)
           AND (@ProgramCode    IS NULL OR v.program_code    = @ProgramCode)
         -- Most urgent first. A NULL std_used_pct sorts last under DESC.
         ORDER BY std_used_pct DESC
                , days_left
                , v.application_received
                -- INT_DOC_ID is the key and makes the order deterministic.
                , v.INT_DOC_ID;

        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' pending applications returned.');

        -- Completion. After the SELECT, so the recorded duration covers the read of the view.
        -- auditModifiedDateUtc is set explicitly because its DEFAULT fires on INSERT only.
        SET @EndTimeUtc = SYSUTCDATETIME ();

        IF @ExecutionId IS NOT NULL
        BEGIN
            UPDATE logs.ExecutionLog
               SET EndDateUtc           = @EndTimeUtc
                   -- Clamped to int range with a CASE rather than LEAST (), which is SQL Server 2022+;
                   -- this procedure targets 2019. Same form as dbo.uspBuildStdPermitTT.
                 , ElapsedMilliseconds  = CAST (CASE WHEN DATEDIFF_BIG (MILLISECOND, @StartTimeUtc, @EndTimeUtc)
                                                          > CAST (2147483647 AS BIGINT)
                                                     THEN CAST (2147483647 AS BIGINT)
                                                     ELSE DATEDIFF_BIG (MILLISECOND, @StartTimeUtc, @EndTimeUtc)
                                                END AS INT)
                 , Successful           = 1
                 , Comments             = @Comments
                 , auditModifiedBy      = ORIGINAL_LOGIN ()
                 , auditModifiedDateUtc = @EndTimeUtc
             WHERE ExecutionLogId = @ExecutionId;
        END;

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

        -- No rollback: this procedure opens no transaction, so any open one is the CALLER's and not this
        -- procedure's to end -- and inside INSERT ... EXEC a ROLLBACK would itself raise 8004 and abort this
        -- CATCH before the error is recorded. For the same reason there is no re-create step.

        -- Swallows everything by design, so this call cannot mask the error below it. Closes the row opened
        -- above with the end time and the error; @ExecutionId is NULL only if the start call itself failed.
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

        -- Bare, so the ORIGINAL error number reaches the caller.
        ;THROW;

    END CATCH;

    RETURN 0;
END;
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'PROCEDURE'
    , @ObjectName  = N'uspPermitTurnaroundPending'
    , @Description = N'Every permit application that matched a published standard and is still pending -- approval_issued IS NULL and closedDate IS NULL in dbo.vwPermitTurnaroundPerformance -- whenever it was received. The Detail columns less approval_issued, plus days_left (standard less derived_days_qty, negative once overdue) and std_used_pct (derived_days_qty / standard), most urgent first. Optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters, NULL = all. No period. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundPending TO db_executor;
END;
GO
