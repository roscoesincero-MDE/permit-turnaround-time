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
ObjectName:   dbo.uspPermitTurnaroundPerformance
Author:       rsincero
CreateDate:   2026-09-24
========================================================================================================================
Description:

Permit turnaround performance for a reporting period. Returns the rows of dbo.vwPermitTurnaroundPerformance whose
application was received in the period, OR whose issued-or-closed date falls in it:

    application_received                     in [@StartDate, @EndDate]
 OR COALESCE (approval_issued, closedDate)   in [@StartDate, @EndDate]

restricted to activities that matched a standard (std_turnaround_time IS NOT NULL), and optionally to one
@ProgramCode, @PermitCategory, @PermitClass, @PermitType and/or @SttPermitType. Each of those five is an exact match;
NULL means all.

The period is given either as an explicit date range or as a year type plus a year and a period code, in the same
scheme as MDEServ.proc_wetland_detailed_listing_STT_by_fiscal_year_rs, which this replaces for the PTT view:

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

THE END DATE IS INCLUSIVE OF THE WHOLE DAY. The view's dates are datetime2 and carry a time of day on 79,592 received
and 63,825 issued rows (measured 2026-09-24), so `BETWEEN @StartDate AND @EndDate` with a DATE end would silently drop
everything after midnight on the last day of the period. The comparison is therefore half-open:
`>= @StartDate AND < DATEADD (day, 1, @EndDate)`, which is what "between the start and end date" means to a reader.

DIFFERENCES FROM THE MDEServ ORIGINAL, all deliberate:
  - @FiscalPeriod NULL means the whole year. The original left the dates NULL and returned nothing.
  - A date range (@FiscalType = -1) no longer requires @FiscalYear > 1 to return rows.
  - Bad arguments raise 50000 instead of returning an empty result that looks like "no activity".
  - Activities with no matching standard (std_turnaround_time NULL) are excluded, as the original's
    `stt is not null` did. Added 2026-09-24; the first version returned them.
  - The view's other caveats still reach the caller: calendar_days_qty can be negative (every compliance predicate
    needs calendar_days_qty >= 0) and grows daily on unissued rows, which is why refresh_date is returned.

DEFAULTS, as in the original: with no arguments the procedure reports the PREVIOUS CALENDAR QUARTER as a date range.
Either end of a date range may be omitted independently and takes that default.

period_start_date / period_end_date are returned on every row so a report built on a year type can print the range it
actually covers without re-deriving it.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundPerformance;                                                     -- previous calendar quarter
exec dbo.uspPermitTurnaroundPerformance @FiscalType = -1, @DateStart = '2025-01-01', @DateEnd = '2025-03-31';
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 0, @FiscalYear = 2025;                 -- calendar 2025
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 1, @FiscalYear = 2026;                 -- state FY 2026
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 2, @FiscalYear = 2026, @FiscalPeriod = 1;  -- federal FY26 Q1
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 1, @FiscalYear = 2026, @FiscalPeriod = 12; -- July 2025
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 1, @FiscalYear = 2026, @PermitCategory = 'Tidal';
exec dbo.uspPermitTurnaroundPerformance @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '33';    -- Wetlands only

The view is evaluated in full and then filtered: the OR across two derived dates is not sargable, and the view's
dates are computed, not stored. Cost is that of one read of the view.

Instrumentation is the full Rule 8 block, as in dbo.uspBuildStdPermitTT: one logs.ExecutionLog row per call,
opened before any work with the start time and @KeyParameters, and closed after the SELECT with the end time,
ElapsedMilliseconds, Successful = 1 and the number of rows returned and the resolved period in Comments. A
failed call keeps Successful = 0 and gets the error and the phase it reached in ContextMessage. One singleton
INSERT and one singleton UPDATE per call, which is not measurable against a read of the view. The user running the
report is passed in @ReportUser and recorded as ReportUser= in KeyParameters; auditCreatedBy holds only the SQL
login, which for SSRS is the data source's stored credential. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundPerformance]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-09-24
Author:		rsincero
Ticket:		PTT
Description:
Original. Port of MDEServ.proc_wetland_detailed_listing_STT_by_fiscal_year_rs onto dbo.vwPermitTurnaroundPerformance.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-24
Author:		rsincero
Ticket:		PTT
Description:
Excludes rows with no standard (std_turnaround_time IS NULL). Added four optional exact-match filters, NULL = all:
@PermitCategory, @PermitClass, @PermitType, @SttPermitType, typed to the view's columns. All new parameters come
after the existing five, so positional callers of the first version are unaffected.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-24
Author:		rsincero
Ticket:		PTT
Description:
Returns the view's new derived_days_qty, after calendar_days_qty. permit_type now carries the view's Wetlands Tidal
relabelling, so @PermitType = '325-Day' selects those rows.

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
ROLLBACK raises 8004 and loses the error record. Comments carries the rows returned and the resolved period; ContextMessage
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
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundPerformance
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
                                                    , N'[dbo].[uspPermitTurnaroundPerformance]')
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

        IF @FiscalType = -1
        BEGIN
            -- Default: the previous calendar quarter, each end independently, as in the original.
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
            , v.approval_issued
            , v.closedDate
            , v.closedType
            , v.days_used_qty
            , v.calendar_days_qty
            , v.derived_days_qty
            , v.turnaround_time
            , v.alt_turnaround_time
            , v.std_turnaround_time
            , @StartDate      AS period_start_date
            , @EndDate        AS period_end_date
            , SYSDATETIME ()  AS refresh_date
          FROM dbo.vwPermitTurnaroundPerformance AS v
         -- Half-open on the day after @EndDate, so times of day on the last day are included.
         WHERE v.std_turnaround_time IS NOT NULL
           AND (   (    v.application_received >= @StartDate
                    AND v.application_received <  DATEADD (day, 1, @EndDate))
                OR (    COALESCE (v.approval_issued, v.closedDate) >= @StartDate
                    AND COALESCE (v.approval_issued, v.closedDate) <  DATEADD (day, 1, @EndDate)))
           -- NULL = all. Exact match otherwise.
           AND (@PermitCategory IS NULL OR v.permit_category = @PermitCategory)
           AND (@PermitClass    IS NULL OR v.permit_class    = @PermitClass)
           AND (@PermitType     IS NULL OR v.permit_type     = @PermitType)
           AND (@SttPermitType  IS NULL OR v.stt_permit_type = @SttPermitType)
           AND (@ProgramCode    IS NULL OR v.program_code    = @ProgramCode)
         ORDER BY v.program_desc
				, v.stt_sortorder
                , v.permit_category
                , v.stt_permit_type
                , v.ACTIVITY_ID
                -- ACTIVITY_ID is not unique; INT_DOC_ID is the key and makes the order deterministic.
                , v.INT_DOC_ID;


        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' rows returned for '
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
    , @ObjectName  = N'uspPermitTurnaroundPerformance'
    , @Description = N'Permit turnaround performance for a period: rows of dbo.vwPermitTurnaroundPerformance received, or issued/closed, between the start and end date. Only rows with a standard; optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters, NULL = all. Period by date range, calendar year, state fiscal year or federal fiscal year, by quarter, year or month. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundPerformance TO db_executor;
END;
GO
