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
ObjectName:   dbo.uspPermitTurnaroundPerformanceSummary
Author:       rsincero
CreateDate:   2026-09-30
========================================================================================================================
Description:

Summary companion to dbo.uspPermitTurnaroundPerformance. Returns one row per

    permit_category, permit_class, permit_type, stt_permit_type, std_turnaround_time

with the number of activities (total_qty) and the average derived_days_qty (avg_derived_days_qty), over the rows of
dbo.vwPermitTurnaroundPerformance where

    approval_issued       in [@StartDate, @EndDate]
AND application_received  IS NOT NULL
AND std_turnaround_time   IS NOT NULL

and optionally one @ProgramCode, @PermitCategory, @PermitClass, @PermitType and/or @SttPermitType (exact match; NULL
means all).

NOTE THE DIFFERENCE FROM THE DETAIL PROCEDURE: the detail procedure selects rows received OR issued/closed in the
period. This one selects only rows ISSUED in the period (closed-without-issue rows are excluded), whenever they were
received. Its counts will therefore not match a count of the detail procedure's rows for the same period.

stt_permit_type can be NULL; GROUP BY treats all NULLs as one group, so those rows form their own summary line.

The period is given exactly as in dbo.uspPermitTurnaroundPerformance:

    @FiscalType   -1  Date range              @DateStart / @DateEnd; @FiscalYear and @FiscalPeriod are ignored
                   0  Calendar year           January - December
                   1  State fiscal year       July - June;       FY 2026 = 2025-07-01 .. 2026-06-30
                   2  Federal fiscal year     October - September; FY 2026 = 2025-10-01 .. 2026-09-30

    @FiscalPeriod  1-4   Quarter of that fiscal year (state FY Q1 = July - September)
                   5     The whole fiscal year (the default)
                   6-17  One calendar month: 6 = January .. 17 = December, placed in the fiscal year that contains it
                         (state FY 2026 month 12 = July 2025; federal FY 2026 month 15 = October 2025)

Reads only, apart from one logs.ExecutionLog row per call recording its start and end time.

========================================================================================================================
Requirements and Key Dependencies:

dbo.vwPermitTurnaroundPerformance (sql/040), and through it dbo.stdPermitTT, dbo.MtbApprovalTaskList and the EPAL_ISSI
synonyms.

logs.ExecutionLog, logs.uspStartExecutionLogging and logs.uspRecordExecutionError (sql/015), for the Rule 8
instrumentation block. INSTALL 015 BEFORE THIS SCRIPT.

========================================================================================================================
Notes:

THE END DATE IS INCLUSIVE OF THE WHOLE DAY. approval_issued is datetime2 and carries a time of day, so the
comparison is half-open: `>= @StartDate AND < DATEADD (day, 1, @EndDate)`.

THE AVERAGE IS NOT INTEGER-TRUNCATED. derived_days_qty is cast to DECIMAL before AVG, and the result is rounded to
two places. AVG ignores NULL derived_days_qty; total_qty counts every row in the group. derived_days_qty_count is
returned alongside so a reader can see when the two differ.

No filter is applied to the day counts themselves: if the view can produce a negative derived_days_qty (as it can for
calendar_days_qty), such rows are included in the average.

DEFAULTS, as in the detail procedure: with no arguments the procedure reports the PREVIOUS CALENDAR QUARTER.

COMPATIBILITY: runs on SQL Server 2019 and later. DATETRUNC (2022+) is not used; the start of the current quarter is
computed as DATEADD (quarter, DATEDIFF (quarter, 0, @Today), 0). Everything else used here (CREATE OR ALTER, THROW,
IIF, EOMONTH, DATEFROMPARTS, CONCAT) is available from 2016 SP1.

Rows are ordered by the lowest stt_sortorder in each group, then by the grouping columns, so the summary follows the
same order as the detail report.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundPerformanceSummary;                                                  -- previous calendar quarter
exec dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = -1, @DateStart = '2025-01-01', @DateEnd = '2025-03-31';
exec dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = 1, @FiscalYear = 2026;              -- state FY 2026
exec dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = 2, @FiscalYear = 2026, @FiscalPeriod = 1;  -- federal FY26 Q1
exec dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = 1, @FiscalYear = 2026, @PermitCategory = 'Tidal';
exec dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '33';    -- Wetlands only

The view is evaluated in full and then filtered and aggregated; the view's dates are computed, not stored. Cost is
that of one read of the view.

Instrumentation is the full Rule 8 block, as in dbo.uspBuildStdPermitTT: one logs.ExecutionLog row per call,
opened before any work with the start time and @KeyParameters, and closed after the SELECT with the end time,
ElapsedMilliseconds, Successful = 1 and the number of summary rows returned and the resolved period in Comments. A
failed call keeps Successful = 0 and gets the error and the phase it reached in ContextMessage. One singleton
INSERT and one singleton UPDATE per call, which is not measurable against a read of the view. The user running the
report is passed in @ReportUser and recorded as ReportUser= in KeyParameters; auditCreatedBy holds only the SQL
login, which for SSRS is the data source's stored credential. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundPerformanceSummary]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-09-30
Author:		rsincero
Ticket:		PTT
Description:
Original. Summary of dbo.uspPermitTurnaroundPerformance: count and average derived_days_qty by permit_category,
permit_class, permit_type, stt_permit_type and std_turnaround_time, for rows issued in the period that have an
application_received date.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-30
Author:		rsincero
Ticket:		PTT
Description:
SQL Server 2019 compatible: replaced DATETRUNC (quarter, ...) with DATEADD / DATEDIFF from day 0. No change in results.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Added optional @ProgramCode CHAR (2), an exact match on program_code; NULL = all. Last in the parameter list, so
positional callers are unaffected.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Full Rule 8 instrumentation, replacing error-only: every call now records its start and end time in logs.ExecutionLog,
as dbo.uspBuildStdPermitTT does. The same boilerplate as that procedure -- @StartTimeUtc, @EndTimeUtc, @ExecutionId and
@Comments declared; logs.uspStartExecutionLogging as the first statement in the TRY, before validation, so a rejected
argument is a failed run rather than a missing one; a completion UPDATE after the SELECT; and a CATCH that
passes @ExecutionId to logs.uspRecordExecutionError so the failure closes the same row. UNLIKE THAT PROCEDURE,
NO ROLLBACK: it opens no transaction, so one open in the CATCH is the caller's, and inside INSERT ... EXEC a
ROLLBACK raises 8004 and loses the error record. Comments carries the summary rows returned and the resolved period; ContextMessage
carries the phase reached (validate / resolve-period / select). The result set is unchanged.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Added optional @ReportUser NVARCHAR (256), the user running the report, recorded as ReportUser= in KeyParameters of
the logs.ExecutionLog row. TurnaroundPerformance.rdl passes =User!UserID. Needed because auditCreatedBy records
ORIGINAL_LOGIN (), which for the report is the data source's stored credential, not the person running it. Not used
to filter; the result set is unchanged. Last in the parameter list, so positional callers are unaffected.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundPerformanceSummary
      @FiscalType     INT           = -1
    , @FiscalYear     INT           = NULL
    , @FiscalPeriod   INT           = 5
    , @DateStart      DATE          = NULL
    , @DateEnd        DATE          = NULL
    , @PermitCategory VARCHAR (30)  = NULL
    , @PermitClass    VARCHAR (50)  = NULL
    , @PermitType     VARCHAR (100) = NULL
    , @SttPermitType  VARCHAR (100) = NULL
    , @ProgramCode    CHAR (2)      = NULL
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
                                                    , N'[dbo].[uspPermitTurnaroundPerformanceSummary]')
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

    DECLARE @StartDate       DATE = NULL
          , @EndDate         DATE = NULL
          , @FyStartMonth    INT  = NULL
          , @FyStartDate     DATE = NULL
          , @CalendarMonth   INT  = NULL
          , @CurrentQuarterStart DATE = NULL
          , @Today           DATE = CAST (SYSDATETIME () AS DATE);

    -- Identifiers and counts ONLY.
    SET @KeyParameters = CONCAT (N'FiscalType=',     @FiscalType
                               , N', FiscalYear=',   @FiscalYear
                               , N', FiscalPeriod=', @FiscalPeriod
                               , N', DateStart=',    CONVERT (NCHAR (10), @DateStart, 23)
                               , N', DateEnd=',      CONVERT (NCHAR (10), @DateEnd, 23)
                               , N', PermitCategory=', @PermitCategory
                               , N', PermitClass=',    @PermitClass
                               , N', PermitType=',     @PermitType
                               , N', SttPermitType=',  @SttPermitType
                               , N', ProgramCode=',    @ProgramCode
                               -- Who ran it: the SSRS User!UserID. auditCreatedBy is only the data source login.
                               , N', ReportUser=',     @ReportUser);

    BEGIN TRY

        -- First, before validation, so a rejected argument is recorded as a failed run with its
        -- start time rather than as an orphan error row.
        EXEC logs.uspStartExecutionLogging
              @ProcedureName          = @ProcName
            , @KeyParameters          = @KeyParameters
            , @StartDateUtc           = @StartTimeUtc
            , @ReCreatedAfterRollback = 0
            , @ExecutionLogId         = @ExecutionId OUTPUT;

        SET @ContextMessage = N'phase=validate';

        -- Validation inside the TRY, so a bad argument is recorded rather than swallowed.
        IF @FiscalType IS NULL OR @FiscalType NOT IN (-1, 0, 1, 2)
        BEGIN
            ;THROW 50000, N'@FiscalType must be -1 (date range), 0 (calendar), 1 (state fiscal) or 2 (federal fiscal).', 1;
        END;

        IF @FiscalType <> -1
        BEGIN
            IF @FiscalYear IS NULL OR @FiscalYear NOT BETWEEN 1901 AND 9998
            BEGIN
                ;THROW 50000, N'@FiscalYear is required for a calendar, state or federal year and must be between 1901 and 9998.', 1;
            END;

            IF @FiscalPeriod IS NOT NULL AND @FiscalPeriod NOT BETWEEN 1 AND 17
            BEGIN
                ;THROW 50000, N'@FiscalPeriod must be 1-4 (quarter), 5 (whole year) or 6-17 (January-December).', 1;
            END;
        END;

        -- =========================================================================================
        -- ===== The procedure's own work starts here. Everything above and below is boilerplate. ==
        -- =========================================================================================

        SET @ContextMessage = N'phase=resolve-period';

        -- Period resolution: identical to dbo.uspPermitTurnaroundPerformance. Keep the two in step.
        IF @FiscalType = -1
        BEGIN
            -- Default: the previous calendar quarter, each end independently.
            -- First day of the current quarter without DATETRUNC, which needs SQL Server 2022: whole quarters
            -- since day 0 (1900-01-01), added back to day 0. Works on 2019.
            SET @CurrentQuarterStart = CAST (DATEADD (quarter, DATEDIFF (quarter, 0, @Today), 0) AS DATE);

            SET @StartDate = COALESCE (@DateStart, DATEADD (quarter, -1, @CurrentQuarterStart));
            SET @EndDate   = COALESCE (@DateEnd,   DATEADD (day,     -1, @CurrentQuarterStart));
        END
        ELSE
        BEGIN
            SET @FiscalPeriod = COALESCE (@FiscalPeriod, 5);

            -- The month a fiscal year starts in. A fiscal year that does not start in January begins in the
            -- previous calendar year: state FY 2026 starts 2025-07-01, federal FY 2026 starts 2025-10-01.
            SET @FyStartMonth = CASE @FiscalType WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 10 END;
            SET @FyStartDate  = DATEFROMPARTS (@FiscalYear - IIF (@FyStartMonth > 1, 1, 0), @FyStartMonth, 1);

            IF @FiscalPeriod BETWEEN 1 AND 4          -- quarter of the fiscal year
            BEGIN
                SET @StartDate = DATEADD (quarter, @FiscalPeriod - 1, @FyStartDate);
                SET @EndDate   = EOMONTH (@StartDate, 2);
            END
            ELSE IF @FiscalPeriod = 5                 -- whole fiscal year
            BEGIN
                SET @StartDate = @FyStartDate;
                SET @EndDate   = EOMONTH (@StartDate, 11);
            END
            ELSE                                      -- 6-17: one calendar month, in the fiscal year holding it
            BEGIN
                SET @CalendarMonth = @FiscalPeriod - 5;
                SET @StartDate     = DATEFROMPARTS (@FiscalYear - IIF (@FyStartMonth > 1 AND @CalendarMonth >= @FyStartMonth, 1, 0)
                                                  , @CalendarMonth, 1);
                SET @EndDate       = EOMONTH (@StartDate);
            END;
        END;

        IF @StartDate > @EndDate
        BEGIN
            ;THROW 50000, N'The start date must be on or before the end date.', 1;
        END;

        SET @ContextMessage = CONCAT (N'phase=select, period=', CONVERT (NCHAR (10), @StartDate, 23)
                                    , N'..', CONVERT (NCHAR (10), @EndDate, 23));

        SELECT
              v.program_code	
            , v.program_desc			  
            , v.permit_category
            , v.permit_class
            , v.permit_type
            , v.stt_permit_type
            , v.std_turnaround_time
            , COUNT (*)                                                        AS total_qty
            , COUNT (v.derived_days_qty)                                       AS derived_days_qty_count
            -- Cast before AVG so an integer column is not truncated; rounded to two places.
            , CAST (AVG (CAST (v.derived_days_qty AS DECIMAL (19, 4))) AS DECIMAL (12, 2))
                                                                               AS avg_derived_days_qty
            , @StartDate                                                       AS period_start_date
            , @EndDate                                                         AS period_end_date
            , SYSDATETIME ()                                                   AS refresh_date
          FROM dbo.vwPermitTurnaroundPerformance AS v
         WHERE v.std_turnaround_time  IS NOT NULL
           AND v.application_received IS NOT NULL
           -- Half-open on the day after @EndDate, so times of day on the last day are included.
           AND v.approval_issued >= @StartDate
           AND v.approval_issued <  DATEADD (day, 1, @EndDate)
           -- NULL = all. Exact match otherwise.
           AND (@PermitCategory IS NULL OR v.permit_category = @PermitCategory)
           AND (@PermitClass    IS NULL OR v.permit_class    = @PermitClass)
           AND (@PermitType     IS NULL OR v.permit_type     = @PermitType)
           AND (@SttPermitType  IS NULL OR v.stt_permit_type = @SttPermitType)
           AND (@ProgramCode    IS NULL OR v.program_code    = @ProgramCode)
         GROUP BY v.program_code
				, v.program_desc		 
				, v.permit_category
                , v.permit_class
                , v.permit_type
                , v.stt_permit_type
                , v.std_turnaround_time
         ORDER BY v.program_desc
				, v.program_code		 		 
                , v.permit_category
                , v.stt_permit_type
				, MIN (v.stt_sortorder)				
                , v.permit_type
                , v.std_turnaround_time
                , v.permit_class				
				;

        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' summary rows returned for '
                              , CONVERT (NCHAR (10), @StartDate, 23), N' to '
                              , CONVERT (NCHAR (10), @EndDate, 23), N'.');

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

        -- No rollback, unlike dbo.uspBuildStdPermitTT: this procedure opens no transaction, so any open
        -- one is the CALLER's and not this procedure's to end -- and inside INSERT ... EXEC a ROLLBACK
        -- would itself raise 8004 and abort this CATCH before the error is recorded. For the same
        -- reason there is no re-create step: nothing here can destroy the row the start call wrote.
        -- If the caller's transaction is doomed the call below cannot write, and swallows that.

        -- Swallows everything by design, so this call cannot mask the error below it. Closes the
        -- row opened above with the end time and the error; @ContextMessage says which phase failed.
        -- @ExecutionId is NULL only if the start call itself failed, and then this writes an orphan
        -- row that explains itself.
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
    , @ObjectName  = N'uspPermitTurnaroundPerformanceSummary'
    , @Description = N'Permit turnaround summary for a period: count and average derived_days_qty from dbo.vwPermitTurnaroundPerformance, grouped by permit_category, permit_class, permit_type, stt_permit_type and std_turnaround_time. Only rows issued (approval_issued) between the start and end date, with an application_received date, and with a standard; optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters, NULL = all. Period by date range, calendar year, state fiscal year or federal fiscal year, by quarter, year or month. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundPerformanceSummary TO db_executor;
END;
GO
