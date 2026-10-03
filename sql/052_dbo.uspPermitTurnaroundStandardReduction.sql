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
ObjectName:   dbo.uspPermitTurnaroundStandardReduction
Author:       rsincero
CreateDate:   2026-10-01
========================================================================================================================
Description:

What-if analysis for a proposed reduction of the standard turnaround times. For permits ISSUED in the period, answers:
if every standard had been @ReductionPercent lower (default 25), how many of these permits would have been late?
Returns one row per

    program_code, program_desc, permit_category, permit_type, std_turnaround_time

with the number issued, the number and share late against today's standard, the number and share late against the
proposed standard (std_turnaround_time * (100 - @ReductionPercent) / 100), the median and 90th percentile turnaround
time, and a readiness label that sorts each row into one of three groups:

    Ready now            p90_days    <= proposed standard   nine in ten already finish within it
    Improvement project  median_days <= proposed standard   typical permits make it; the slow tail does not
    Redesign needed      median_days >  proposed standard   most permits would be late

The population is that of dbo.uspPermitTurnaroundPerformanceSummary -- approval_issued in [@StartDate, @EndDate],
application_received IS NOT NULL, std_turnaround_time IS NOT NULL, and the same optional @ProgramCode,
@PermitCategory, @PermitClass, @PermitType and @SttPermitType filters (exact match; NULL means all) -- with one
addition: derived_days_qty >= 0, which drops rows with no figure and rows whose dates are the wrong way round.

The period is given exactly as in dbo.uspPermitTurnaroundPerformance:

    @FiscalType   -1  Date range              @DateStart / @DateEnd; @FiscalYear and @FiscalPeriod are ignored
                   0  Calendar year           January - December
                   1  State fiscal year       July - June;       FY 2026 = 2025-07-01 .. 2026-06-30
                   2  Federal fiscal year     October - September; FY 2026 = 2025-10-01 .. 2026-09-30

    @FiscalPeriod  1-4   Quarter of that fiscal year (state FY Q1 = July - September)
                   5     The whole fiscal year (the default)
                   6-17  One calendar month: 6 = January .. 17 = December, placed in the fiscal year that contains it

Reads only, apart from one logs.ExecutionLog row per call recording its start and end time.

========================================================================================================================
Requirements and Key Dependencies:

dbo.vwPermitTurnaroundPerformance (sql/040), and through it dbo.stdPermitTT, dbo.MtbApprovalTaskList and the EPAL_ISSI
synonyms.

logs.ExecutionLog, logs.uspStartExecutionLogging and logs.uspRecordExecutionError (sql/015), for the Rule 8
instrumentation block. INSTALL 015 BEFORE THIS SCRIPT.

========================================================================================================================
Notes:

NULL permit_type IS KEPT, AS ITS OWN ROW, labelled '(no permit type)'. The percentiles are window functions over the
same partition as the GROUP BY rather than a second grouped set joined back on permit_type: that join was the first
draft of this query, and it silently dropped every row with no permit_type, because NULL = NULL is not true. PARTITION
BY and GROUP BY both treat NULLs as one group, so no join is needed. A @PermitType filter cannot select those rows.

THE NEGATIVE FILTER IS DELIBERATE AND DIFFERS FROM THE SUMMARY PROCEDURE. A negative derived_days_qty is <= every
standard, so left in it would count as on time against both the current and the proposed standard and flatter the
result. issued_qty can therefore be lower than the Summary's total_qty for the same permits.

THE PROPOSED STANDARD IS NOT ROUNDED to whole days: 25% off 90 is 67.5, and a permit is late against it at 68 days.
It is held at NUMERIC (8, 3), the width of std_turnaround_time, and the late count compares against that held value.

derived_days_qty mixes two clocks -- EPAL_ISSI's working-time days_used_qty where it exists, calendar days otherwise
-- exactly as on the Summary and Detail tabs. A reduction target set from this result should say which clock it means.

Small groups give unstable percentiles. A row with a handful of permits can land in any readiness group by chance;
read issued_qty before the label.

THE END DATE IS INCLUSIVE OF THE WHOLE DAY. approval_issued is datetime2 and carries a time of day, so the
comparison is half-open: `>= @StartDate AND < DATEADD (day, 1, @EndDate)`.

DEFAULTS, as in the detail procedure: with no arguments the procedure reports the PREVIOUS CALENDAR QUARTER at a 25%
reduction.

Rows are ordered by late_rate_at_proposed, highest first, so the permit types the target would hit hardest lead.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundStandardReduction;                                                     -- previous calendar quarter, 25%
exec dbo.uspPermitTurnaroundStandardReduction @FiscalType = 1, @FiscalYear = 2026;                 -- state FY 2026, 25%
exec dbo.uspPermitTurnaroundStandardReduction @FiscalType = 1, @FiscalYear = 2026, @ReductionPercent = 10;
exec dbo.uspPermitTurnaroundStandardReduction @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '33';   -- Wetlands only

The view is evaluated in full and then filtered, windowed and aggregated; the view's dates are computed, not stored.
The two PERCENTILE_CONT windows add a sort of the filtered rows. Cost is that of one read of the view plus that sort.

Instrumentation is the full Rule 8 block, as in dbo.uspPermitTurnaroundPerformanceSummary: one logs.ExecutionLog row
per call, opened before any work with the start time and @KeyParameters, and closed after the SELECT with the end
time, ElapsedMilliseconds, Successful = 1 and the number of rows returned, the reduction and the resolved period in
Comments. A failed call keeps Successful = 0 and gets the error and the phase it reached in ContextMessage. The user
running the report is passed in @ReportUser and recorded as ReportUser= in KeyParameters; auditCreatedBy holds only
the SQL login, which for SSRS is the data source's stored credential. No ROLLBACK in the CATCH: the procedure opens no
transaction, so one open there is the caller's, and inside INSERT ... EXEC a ROLLBACK raises 8004 and loses the error
record. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundStandardReduction]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Original. Supports the executive goal of reducing standard turnaround times by 25%: per program, permit type and
standard, the share of permits issued in the period that would have been late against a standard @ReductionPercent
lower, with median, 90th percentile and a readiness label. Built from dbo.uspPermitTurnaroundPerformanceSummary, whose
period handling, filters, @ReportUser and instrumentation it shares unchanged.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Added permit_category to the grouping, the percentile partitions, the result (after program_desc) and the sort, so the
Standard Reduction tab can show it. A permit type that appears under two categories is now two rows. NULL
permit_category is kept as its own group by both GROUP BY and PARTITION BY, as permit_type is.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundStandardReduction
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
    , @ReductionPercent DECIMAL (5, 2) = 25
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
                                                    , N'[dbo].[uspPermitTurnaroundStandardReduction]')
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
                               , N', ReductionPercent=', @ReductionPercent
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

        IF @ReductionPercent IS NULL OR @ReductionPercent <= 0 OR @ReductionPercent >= 100
        BEGIN
            ;THROW 50000, N'@ReductionPercent must be greater than 0 and less than 100.', 1;
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
            SET @StartDate = COALESCE (@DateStart, DATEADD (quarter, -1, DATETRUNC (quarter, @Today)));
            SET @EndDate   = COALESCE (@DateEnd,   DATEADD (day,     -1, DATETRUNC (quarter, @Today)));
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

        WITH issued AS
        (
            SELECT v.program_code
                 , v.program_desc
                 , v.permit_category
                 , v.permit_type
                 , v.std_turnaround_time
                   -- Held at the width of std_turnaround_time, not rounded to whole days.
                 , CAST (v.std_turnaround_time * (100 - @ReductionPercent) / 100 AS NUMERIC (8, 3))
                                                                                   AS proposed_std_turnaround_time
                 , v.derived_days_qty
                   -- Window functions over the GROUP BY's own partition, so nothing is joined back. A join on
                   -- permit_type drops every row whose permit_type is NULL, because NULL = NULL is not true.
                 , PERCENTILE_CONT (0.5) WITHIN GROUP (ORDER BY v.derived_days_qty)
                       OVER (PARTITION BY v.program_code, v.program_desc, v.permit_category, v.permit_type
                                        , v.std_turnaround_time)
                                                                                   AS median_days
                 , PERCENTILE_CONT (0.9) WITHIN GROUP (ORDER BY v.derived_days_qty)
                       OVER (PARTITION BY v.program_code, v.program_desc, v.permit_category, v.permit_type
                                        , v.std_turnaround_time)
                                                                                   AS p90_days
              FROM dbo.vwPermitTurnaroundPerformance AS v
             WHERE v.std_turnaround_time  IS NOT NULL
               AND v.application_received IS NOT NULL
               -- Half-open on the day after @EndDate, so times of day on the last day are included.
               AND v.approval_issued >= @StartDate
               AND v.approval_issued <  DATEADD (day, 1, @EndDate)
               -- Drops NULL figures and reversed dates. A negative is <= every standard and would count as on time.
               AND v.derived_days_qty >= 0
               -- NULL = all. Exact match otherwise.
               AND (@PermitCategory IS NULL OR v.permit_category = @PermitCategory)
               AND (@PermitClass    IS NULL OR v.permit_class    = @PermitClass)
               AND (@PermitType     IS NULL OR v.permit_type     = @PermitType)
               AND (@SttPermitType  IS NULL OR v.stt_permit_type = @SttPermitType)
               AND (@ProgramCode    IS NULL OR v.program_code    = @ProgramCode)
        )
        , grouped AS
        (
            SELECT i.program_code
                 , i.program_desc
                 , i.permit_category
                 , i.permit_type
                 , i.std_turnaround_time
                 , i.proposed_std_turnaround_time
                 , COUNT (*)                                                               AS issued_qty
                 , SUM (IIF (i.derived_days_qty > i.std_turnaround_time,          1, 0))   AS late_qty_now
                 , SUM (IIF (i.derived_days_qty > i.proposed_std_turnaround_time, 1, 0))   AS late_qty_at_proposed
                   -- One value per partition, so MAX only carries it through the GROUP BY.
                 , MAX (i.median_days)                                                     AS median_days
                 , MAX (i.p90_days)                                                        AS p90_days
              FROM issued AS i
             GROUP BY i.program_code
                    , i.program_desc
                    , i.permit_category
                    , i.permit_type
                    , i.std_turnaround_time
                    , i.proposed_std_turnaround_time
        )
        SELECT
              g.program_code
            , g.program_desc
            , g.permit_category
            , COALESCE (g.permit_type, '(no permit type)')                         AS permit_type
            , g.std_turnaround_time
            , g.proposed_std_turnaround_time
            , g.issued_qty
            , g.late_qty_now
            , g.late_qty_at_proposed
            , CAST (1.0 * g.late_qty_now         / g.issued_qty AS DECIMAL (5, 4)) AS late_rate_now
            , CAST (1.0 * g.late_qty_at_proposed / g.issued_qty AS DECIMAL (5, 4)) AS late_rate_at_proposed
            , CAST (g.median_days AS DECIMAL (12, 1))                              AS median_days
            , CAST (g.p90_days    AS DECIMAL (12, 1))                              AS p90_days
            , CASE WHEN g.p90_days    <= g.proposed_std_turnaround_time THEN N'Ready now'
                   WHEN g.median_days <= g.proposed_std_turnaround_time THEN N'Improvement project'
                   ELSE N'Redesign needed'
              END                                                                  AS readiness
            , @ReductionPercent                                                    AS reduction_percent
            , @StartDate                                                           AS period_start_date
            , @EndDate                                                             AS period_end_date
            , SYSDATETIME ()                                                       AS refresh_date
          FROM grouped AS g
         ORDER BY late_rate_at_proposed DESC
                , g.issued_qty DESC
                , g.program_desc
                , g.program_code
                , g.permit_category
                , permit_type
                , g.std_turnaround_time;

        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' rows returned at a ', @ReductionPercent, N'% reduction for '
                              , CONVERT (NCHAR (10), @StartDate, 23), N' to '
                              , CONVERT (NCHAR (10), @EndDate, 23), N'.');

        -- Completion. After the SELECT, so the recorded duration covers the read of the view.
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
    , @ObjectName  = N'uspPermitTurnaroundStandardReduction'
    , @Description = N'What-if for a proposed cut to the standard turnaround times: per program, permit category, permit type and standard, the permits issued (approval_issued) between the start and end date, the number and share late against the current standard and against one @ReductionPercent lower (default 25), the median and 90th percentile turnaround time, and a readiness label (Ready now / Improvement project / Redesign needed). Rows with a standard, an application_received date and derived_days_qty >= 0; NULL permit_type kept as ''(no permit type)''; optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters, NULL = all. Period by date range, calendar year, state fiscal year or federal fiscal year, by quarter, year or month. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundStandardReduction TO db_executor;
END;
GO
