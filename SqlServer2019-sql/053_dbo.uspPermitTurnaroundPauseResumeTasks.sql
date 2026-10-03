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
                  FROM (VALUES (N'dbo.vwClockPauseResumeTask', N'V')
                             , (N'dbo.stdPermitTT',            N'U')
                             , (N'dbo.MTB_PROGRAM',            N'SN')) AS n (RequiredName, RequiredType)
                 WHERE OBJECT_ID (n.RequiredName, n.RequiredType) IS NULL
                 ORDER BY n.RequiredName
                   FOR XML PATH (N''), TYPE).value (N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

IF @Missing IS NOT NULL
BEGIN
    DECLARE @MissingMessage NVARCHAR (2048) =
            CONCAT (N'dbo.uspPermitTurnaroundPauseResumeTasks reads objects that do not exist yet: ', @Missing
                  , N'. Deploy sql/045 (the view) and run EXEC dbo.uspBuildStdPermitTT (the table) first.');
    ;THROW 50000, @MissingMessage, 1;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspPermitTurnaroundPauseResumeTasks
Author:       rsincero
CreateDate:   2026-10-02
========================================================================================================================
Description:

The pause / resume tasks configured TODAY for the ETS turnaround clock, for the activity types this report measures.
One row per pause / resume pair per activity type, with

    program_code, program_desc, permit_category, permit_class, permit_type, stt_permit_type
    activity_category_code, activity_class_code, activity_type_code, activity_type_label
    pause_reference_task_id,  pause_task_desc        the task that pauses the clock
    resume_reference_task_id, resume_task_desc       the task that restarts it
    stop_reference_task_id,   stop_task_desc         the task that stops it when the permit is issued
    in_use                                           'No' if ETS flags either task or the activity type inactive
    last_updated_by, last_updated_date               the last change to the pair in ETS

Task names are MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC, through dbo.vwClockPauseResumeTask.

THE ACTIVITY TYPES are those with a New, Renew or Renewal standard in dbo.stdPermitTT that is in force today -- the
same classes dbo.vwPermitTurnaroundPerformance matches on, so the same activity types the other tabs report on. Pairs
configured for any other activity type are not listed. The optional @ProgramCode, @PermitCategory, @PermitClass,
@PermitType and @SttPermitType filters are exact matches on the standard; NULL means all.

Takes no period: it reports configuration as it stands when the report runs, not activity in a period.

Reads only, apart from one logs.ExecutionLog row per call recording its start and end time.

========================================================================================================================
Requirements and Key Dependencies:

dbo.vwClockPauseResumeTask (sql/045), and through it the EPAL_ISSI synonyms dbo.MTB_DEFINED_TASK_EXTEND_LIST,
dbo.MTB_DEFINED_TASK_LIST and dbo.DSKMTB_ACTIVITY_TYPE. dbo.stdPermitTT, created by EXEC dbo.uspBuildStdPermitTT.
dbo.MTB_PROGRAM, a synonym onto EPAL_ISSI, for program_desc. All asserted above.

logs.ExecutionLog, logs.uspStartExecutionLogging and logs.uspRecordExecutionError (sql/015), for the Rule 8
instrumentation block. INSTALL 015 BEFORE THIS SCRIPT.

========================================================================================================================
Notes:

ONE ROW PER STANDARD'S ACTIVITY TYPE, NOT PER STANDARD. dbo.stdPermitTT can hold two standards for one activity type
(eight Wetlands types carry a Major and a Minor standard). They are collapsed first, on the four activity codes and
the permit names, so a pair is listed once per activity type. On 2026-10-02 the names were the same on every standard
of an activity type (207 types, 207 distinct type-and-name combinations).

permit_type IS THE STANDARD'S OWN NAME. The Wetlands Tidal relabelling in dbo.vwPermitTurnaroundPerformance ('240-Day'
measured against 325 reads '325-Day') depends on which standard each APPLICATION was measured against, so it cannot
apply to a list of activity types. A @PermitType of '325-Day' or '150-Day' therefore returns nothing here.

COMPATIBILITY: runs on SQL Server 2019 and later. The ElapsedMilliseconds clamp is a CASE rather than LEAST ().

in_use TREATS INACTIVE_FLAG = 'Y' AS INACTIVE and anything else, NULL included, as in use. ETS's convention, not
measured here: the author's login cannot read EPAL_ISSI.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspPermitTurnaroundPauseResumeTasks;                                     -- every measured activity type
exec dbo.uspPermitTurnaroundPauseResumeTasks @ProgramCode = '27', @PermitCategory = 'Scrap Tire';

Reads a few hundred standards and the pause / resume reference table. Not measured, for the reason in the Notes.

Instrumentation is the full Rule 8 block, as in dbo.uspPermitTurnaroundStandardReduction: one logs.ExecutionLog row
per call, closed with the end time, ElapsedMilliseconds, Successful = 1 and the number of rows returned. @ReportUser
is recorded as ReportUser= in KeyParameters. No ROLLBACK in the CATCH, for the reason given there. To see the runs:

    select top (10) ExecutionLogId, StartDateUtc, EndDateUtc, ElapsedMilliseconds, Successful, KeyParameters, Comments
         , ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspPermitTurnaroundPauseResumeTasks]' and IsDeleted = 0
     order by StartDateUtc desc;

========================================================================================================================
Modification History:

Date:		2026-10-02
Author:		rsincero
Ticket:		PTT
Description:
Original. Feeds the Pause-Resume Tasks tab of TurnaroundPerformance.rdl.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspPermitTurnaroundPauseResumeTasks
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
                                                    , N'[dbo].[uspPermitTurnaroundPauseResumeTasks]')
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

    DECLARE @Today DATE = CAST (SYSDATETIME () AS DATE);

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

        WITH measured AS
        (
            -- Activity types with a New / Renew / Renewal standard in force today, collapsed to one row per type.
            -- See the Notes on the eight Wetlands types that carry two standards.
            SELECT s.program_code
                 , s.activity_category_code
                 , s.activity_class_code
                 , s.activity_type_code
                 , s.permit_category
                 , s.permit_class
                 , s.permit_type
                 , s.stt_permit_type
                 , MIN (s.stt_sortorder) AS stt_sortorder
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
            , t.activity_type_label
            , t.pause_reference_task_id
            , t.pause_task_desc
            , t.resume_reference_task_id
            , t.resume_task_desc
            , t.stop_reference_task_id
            , t.stop_task_desc
            , CASE WHEN 'Y' IN (t.pause_task_inactive_flag, t.resume_task_inactive_flag, t.activity_type_inactive_flag)
                   THEN 'No' ELSE 'Yes'
              END                 AS in_use
            , t.last_updated_by
            , t.last_updated_date
            , SYSDATETIME ()      AS refresh_date
          FROM measured AS m
         INNER JOIN dbo.vwClockPauseResumeTask AS t
                 ON t.program_code           = m.program_code
                AND t.activity_category_code = m.activity_category_code
                AND t.activity_class_code    = m.activity_class_code
                AND t.activity_type_code     = m.activity_type_code
          LEFT JOIN dbo.MTB_PROGRAM AS pc
                 ON pc.program_code = m.program_code
         ORDER BY pc.program_desc
                , m.stt_sortorder
                , m.permit_category
                , m.permit_type
                , m.permit_class
                , m.activity_type_code
                , t.pause_task_desc
                , t.pause_reference_task_id
                , t.resume_reference_task_id;

        -- Immediately after the SELECT: any later statement resets @@ROWCOUNT.
        SET @RowCount = @@ROWCOUNT;

        -- =========================================================================================
        -- ===== End of the procedure's own work. ===================================================
        -- =========================================================================================

        SET @Comments = CONCAT (@RowCount, N' pause / resume rows returned.');

        -- Completion. auditModifiedDateUtc is set explicitly because its DEFAULT fires on INSERT only.
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
    , @ObjectName  = N'uspPermitTurnaroundPauseResumeTasks'
    , @Description = N'The pause / resume tasks configured today for the ETS turnaround clock, one row per pair per activity type, for activity types with a New, Renew or Renewal standard in dbo.stdPermitTT in force today. Task names from MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC through dbo.vwClockPauseResumeTask; in_use = No where ETS flags either task or the activity type inactive. Optional program_code / permit_category / permit_class / permit_type / stt_permit_type filters on the standard, NULL = all. No period. Reads only; logs the start and end time and @ReportUser of every call in logs.ExecutionLog.';
GO

-- db_executor is the role this project's scripts grant EXECUTE to; applicationRole / readOnlyRole do not exist here.
IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspPermitTurnaroundPauseResumeTasks TO db_executor;
END;
GO
