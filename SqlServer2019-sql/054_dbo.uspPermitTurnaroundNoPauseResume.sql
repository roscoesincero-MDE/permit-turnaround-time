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

-- CREATE PROCEDURE does not resolve the objects it reads (deferred name resolution), so a missing one would deploy
-- cleanly and fail on the report's first run. Checked here instead, all at once.
DECLARE @Missing NVARCHAR (MAX) =
        STUFF ((SELECT N', ' + n.RequiredName
                  FROM (VALUES (N'dbo.vwClockPauseResumeTask',        N'V')
                             , (N'dbo.vwPermitTurnaroundPerformance', N'V')
                             , (N'dbo.stdPermitTT',                   N'U')
                             , (N'dbo.MTB_PROGRAM',                   N'SN')
                             , (N'dbo.DSKMTB_ACTIVITY_TYPE',          N'SN')
                             , (N'dbo.MTB_DEFINED_TASK_LISTS_XREF',   N'SN')) AS n (RequiredName, RequiredType)
                 WHERE OBJECT_ID (n.RequiredName, n.RequiredType) IS NULL
                 ORDER BY n.RequiredName
                   FOR XML PATH (N''), TYPE).value (N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

IF @Missing IS NOT NULL
BEGIN
    DECLARE @MissingMessage NVARCHAR (2048) =
            CONCAT (N'dbo.uspPermitTurnaroundNoPauseResume reads objects that do not exist yet: ', @Missing
                  , N'. Deploy sql/040 and sql/045, run EXEC dbo.uspBuildStdPermitTT, and create any missing EPAL_ISSI synonym (see the README) first.');
    ;THROW 50000, @MissingMessage, 1;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspPermitTurnaroundNoPauseResume
Author:       rsincero
CreateDate:   2026-10-02
========================================================================================================================
Description:

The activity types this report measures that have NO pause / resume task pair configured for the ETS turnaround
clock -- so the days used ETS records for them can never leave out time an application spent on hold. One row per
activity type, with

    program_code, program_desc, permit_category, permit_class, permit_type, stt_permit_type
    activity_category_code, activity_class_code, activity_type_code, activity_type_label
    std_turnaround_time, std_turnaround_time_max   the standard in force today; two values only where an activity type
                                                   carries two (Wetlands Major / Minor), otherwise equal
    active_in_ets                                  'No' where DSKMTB_ACTIVITY_TYPE.INACTIVE_FLAG = 'Y'
    ets_clock_set_up                               'Yes' where ETS is set up to run the turnaround clock at all
    issued_qty                                     permits issued in the period, counted as on the Summary tab
    issued_with_ets_clock_qty                      of those, how many have an ETS days-used figure
    last_received_date                             the most recent application received, at any time

THE ACTIVITY TYPES are those with a New, Renew or Renewal standard in dbo.stdPermitTT that is in force today -- the same
classes dbo.vwPermitTurnaroundPerformance matches on. "No pause / resume" means no row in dbo.vwClockPauseResumeTask
(MTB_DEFINED_TASK_EXTEND_LIST) with both a pause and a resume task for the activity type. The optional @ProgramCode,
@PermitCategory, @PermitClass, @PermitType and @SttPermitType filters are exact matches on the standard; NULL means all.

The period is given exactly as in dbo.uspPermitTurnaroundPerformance and is used ONLY for issued_qty and
issued_with_ets_clock_qty. Which activity types are listed does not depend on it:

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

dbo.vwClockPauseResumeTask (sql/045) and dbo.vwPermitTurnaroundPerformance (sql/040), and through them the EPAL_ISSI
synonyms. dbo.stdPermitTT, created by EXEC dbo.uspBuildStdPermitTT. Three more EPAL_ISSI synonyms read directly:
dbo.MTB_PROGRAM (program_desc), dbo.DSKMTB_ACTIVITY_TYPE (label and INACTIVE_FLAG) and dbo.MTB_DEFINED_TASK_LISTS_XREF
(ets_clock_set_up). All asserted above.

logs.ExecutionLog, logs.uspStartExecutionLogging and logs.uspRecordExecutionError (sql/015), for the Rule 8
instrumentation block. INSTALL 015 BEFORE THIS SCRIPT.

========================================================================================================================
Notes:

ets_clock_set_up USES THE RULE IN REF.v_activities_with_clock_enabled: the activity type has a task in
MTB_DEFINED_TASK_LISTS_XREF flagged INIT_TASK_FLAG = 'Y', which starts the clock, and a task with a
PRIMARY_TASK_TIME_TO_COMPLETE, which stops it. 'No' means ETS records no days used for the type at all and every
report falls back to calendar days (see ETS_Clock.txt); 'Yes' with no pause / resume pair means the clock runs but
cannot be paused. issued_with_ets_clock_qty shows what actually happened in the period.

A TYPE WITH ONLY HISTORICAL PAIRS IS NOT LISTED. A pair whose tasks ETS now flags inactive still counts as configured
here; the Pause-Resume Tasks tab shows such pairs with in_use = No.

ONE ROW PER ACTIVITY TYPE, NOT PER STANDARD, as in dbo.uspPermitTurnaroundPauseResumeTasks: eight Wetlands types carry
a Major and a Minor standard, shown as std_turnaround_time and std_turnaround_time_max. permit_type is the standard's
own name, so the Wetlands Tidal '325-Day' / '150-Day' relabelling of the other tabs does not apply here.

issued_qty COUNTS AS THE SUMMARY TAB DOES -- approval_issued in the period, with a standard and an
application_received date -- so for one activity type the two agree. last_received_date ignores dates after today,
because the source carries some far-future COMPLETED_DATE values (see dbo.vwPermitTurnaroundPerformance).

THE END DATE IS INCLUSIVE OF THE WHOLE DAY. approval_issued carries a time of day, so the comparison is half-open.

COMPATIBILITY: runs on SQL Server 2019 and later. DATETRUNC (2022+) is not used; the start of the current quarter is
computed as DATEADD (quarter, DATEDIFF (quarter, 0, @Today), 0), and the ElapsedMilliseconds clamp is a CASE rather
than LEAST ().

DEFAULTS, as in the detail procedure: with no arguments the counts are for the PREVIOUS CALENDAR QUARTER.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundNoPauseResume;                                                   -- previous calendar quarter
exec dbo.uspPermitTurnaroundNoPauseResume @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '27';

One read of dbo.vwPermitTurnaroundPerformance, aggregated by activity type, plus the small reference tables. Cost is
that of the read of the view, as for the other report procedures.

Instrumentation is the full Rule 8 block, as in dbo.uspPermitTurnaroundStandardReduction. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundNoPauseResume]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-10-02
Author:		rsincero
Ticket:		PTT
Description:
Original. Feeds the No Pause-Resume tab of TurnaroundPerformance.rdl. Period handling, filters, @ReportUser and
instrumentation as in dbo.uspPermitTurnaroundStandardReduction.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundNoPauseResume
      @FiscalType     INT            = -1
    , @FiscalYear     INT            = NULL
    , @FiscalPeriod   INT            = 5
    , @DateStart      DATE           = NULL
    , @DateEnd        DATE           = NULL
    , @PermitCategory VARCHAR (30)   = NULL
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
                                                    , N'[dbo].[uspPermitTurnaroundNoPauseResume]')
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

        WITH measured AS
        (
            -- Activity types with a New / Renew / Renewal standard in force today, one row per type. The same set as
            -- dbo.uspPermitTurnaroundPauseResumeTasks; keep the two in step.
            SELECT s.program_code
                 , s.activity_category_code
                 , s.activity_class_code
                 , s.activity_type_code
                 , s.permit_category
                 , s.permit_class
                 , s.permit_type
                 , s.stt_permit_type
                 , MIN (s.stt_sortorder)   AS stt_sortorder
                 , MIN (s.turnaround_time) AS std_turnaround_time
                 , MAX (s.turnaround_time) AS std_turnaround_time_max
              FROM dbo.stdPermitTT AS s
             WHERE s.IsDeleted = 0
               AND s.permit_class IN ('New', 'Renew', 'Renewal')
               AND s.effective_start_date <  DATEADD (day, 1, @Today)
               AND (s.effective_end_date IS NULL OR s.effective_end_date >= @Today)
               -- NULL = all. Exact match otherwise.
               AND (@PermitCategory IS NULL OR s.permit_category = @PermitCategory)
               AND (@PermitClass    IS NULL OR s.permit_class    = @PermitClass)
               AND (@PermitType     IS NULL OR s.permit_type     = @PermitType)
               AND (@SttPermitType  IS NULL OR s.stt_permit_type = @SttPermitType)
               AND (@ProgramCode    IS NULL OR s.program_code    = @ProgramCode)
             GROUP BY s.program_code
                    , s.activity_category_code
                    , s.activity_class_code
                    , s.activity_type_code
                    , s.permit_category
                    , s.permit_class
                    , s.permit_type
                    , s.stt_permit_type
        )
        , activity AS
        (
            -- One pass over the view for both the period counts and the all-time last received date. The
            -- population is the Summary tab's: a standard and an application_received date.
            SELECT v.program_code
                 , v.activity_category_code
                 , v.activity_class_code
                 , v.activity_type_code
                 , SUM (IIF (v.approval_issued >= @StartDate
                         AND v.approval_issued <  DATEADD (day, 1, @EndDate), 1, 0))           AS issued_qty
                 , SUM (IIF (v.approval_issued >= @StartDate
                         AND v.approval_issued <  DATEADD (day, 1, @EndDate)
                         AND v.days_used_qty IS NOT NULL, 1, 0))                               AS issued_with_ets_clock_qty
                   -- Far-future source dates are ignored rather than reported as the latest receipt.
                 , MAX (IIF (v.application_received < DATEADD (day, 1, @Today), v.application_received, NULL))
                                                                                               AS last_received_date
              FROM dbo.vwPermitTurnaroundPerformance AS v
             WHERE v.std_turnaround_time  IS NOT NULL
               AND v.application_received IS NOT NULL
               AND (@ProgramCode IS NULL OR v.program_code = @ProgramCode)
             GROUP BY v.program_code
                    , v.activity_category_code
                    , v.activity_class_code
                    , v.activity_type_code
        )
        SELECT
              m.program_code
            , pc.program_desc
            , m.permit_category
            , m.permit_class
            , m.permit_type
            , m.stt_permit_type
            , m.activity_category_code
            , m.activity_class_code
            , m.activity_type_code
            , aty.ACTIVITY_TYPE_LABEL                                     AS activity_type_label
            , m.std_turnaround_time
            , m.std_turnaround_time_max
            , IIF (aty.INACTIVE_FLAG = 'Y', 'No', 'Yes')                  AS active_in_ets
              -- The rule in REF.v_activities_with_clock_enabled: a task that starts the clock and one that stops it.
            , CASE WHEN EXISTS (SELECT 1
                                  FROM dbo.MTB_DEFINED_TASK_LISTS_XREF AS x
                                 WHERE x.PROGRAM_CODE           = m.program_code
                                   AND x.ACTIVITY_CATEGORY_CODE = m.activity_category_code
                                   AND x.ACTIVITY_CLASS_CODE    = m.activity_class_code
                                   AND x.ACTIVITY_TYPE_CODE     = m.activity_type_code
                                   AND x.INIT_TASK_FLAG         = 'Y')
                    AND EXISTS (SELECT 1
                                  FROM dbo.MTB_DEFINED_TASK_LISTS_XREF AS x
                                 WHERE x.PROGRAM_CODE           = m.program_code
                                   AND x.ACTIVITY_CATEGORY_CODE = m.activity_category_code
                                   AND x.ACTIVITY_CLASS_CODE    = m.activity_class_code
                                   AND x.ACTIVITY_TYPE_CODE     = m.activity_type_code
                                   AND x.PRIMARY_TASK_TIME_TO_COMPLETE IS NOT NULL)
                   THEN 'Yes' ELSE 'No'
              END                                                         AS ets_clock_set_up
            , COALESCE (a.issued_qty, 0)                                  AS issued_qty
            , COALESCE (a.issued_with_ets_clock_qty, 0)                   AS issued_with_ets_clock_qty
            , a.last_received_date
            , @StartDate                                                  AS period_start_date
            , @EndDate                                                    AS period_end_date
            , SYSDATETIME ()                                              AS refresh_date
          FROM measured AS m
          LEFT JOIN dbo.MTB_PROGRAM AS pc
                 ON pc.program_code = m.program_code
          LEFT JOIN dbo.DSKMTB_ACTIVITY_TYPE AS aty
                 ON aty.PROGRAM_CODE           = m.program_code
                AND aty.ACTIVITY_CATEGORY_CODE = m.activity_category_code
                AND aty.ACTIVITY_CLASS_CODE    = m.activity_class_code
                AND aty.ACTIVITY_TYPE_CODE     = m.activity_type_code
          LEFT JOIN activity AS a
                 ON a.program_code           = m.program_code
                AND a.activity_category_code = m.activity_category_code
                AND a.activity_class_code    = m.activity_class_code
                AND a.activity_type_code     = m.activity_type_code
         -- The point of the result: no configured pair with both a pause and a resume task.
         WHERE NOT EXISTS (SELECT 1
                             FROM dbo.vwClockPauseResumeTask AS t
                            WHERE t.program_code           = m.program_code
                              AND t.activity_category_code = m.activity_category_code
                              AND t.activity_class_code    = m.activity_class_code
                              AND t.activity_type_code     = m.activity_type_code
                              AND t.pause_reference_task_id  IS NOT NULL
                              AND t.resume_reference_task_id IS NOT NULL)
         ORDER BY pc.program_desc
                , m.stt_sortorder
                , m.permit_category
                , m.permit_type
                , m.permit_class
                , m.activity_type_code;

        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' activity types with no pause / resume pair; counts for '
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

        -- No rollback: this procedure opens no transaction, so any open one is the CALLER's and not this
        -- procedure's to end -- and inside INSERT ... EXEC a ROLLBACK would itself raise 8004 and abort this
        -- CATCH before the error is recorded. For the same reason there is no re-create step.

        -- Swallows everything by design, so this call cannot mask the error below it. Closes the row opened
        -- above with the end time and the error; @ContextMessage says which phase failed. @ExecutionId is NULL
        -- only if the start call itself failed.
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
    , @ObjectName  = N'uspPermitTurnaroundNoPauseResume'
    , @Description = N'Activity types with a New, Renew or Renewal standard in dbo.stdPermitTT in force today that have no pause / resume task pair for the ETS turnaround clock (no row in dbo.vwClockPauseResumeTask with both tasks). One row per activity type with program, permit names, activity type label, the standard, whether the type is active in ETS and set up to run the clock at all, the permits issued in the period and how many of them carry an ETS days-used figure, and the last application received. Optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters, NULL = all. Period, used for the counts only, by date range, calendar year, state fiscal year or federal fiscal year, by quarter, year or month. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundNoPauseResume TO db_executor;
END;
GO
