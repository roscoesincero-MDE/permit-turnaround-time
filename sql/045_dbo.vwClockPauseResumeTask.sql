-- SET XACT_ABORT ON sits ABOVE the header block deliberately. The GO on the next line ends the batch, and
-- sys.sql_modules stores only the batch that contains CREATE -- so a header placed AFTER this GO is invisible
-- to anyone reading the view out of the database. The header has to be the LAST thing before CREATE.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER: sqlcmd defaults it OFF where every other client defaults it ON, and the setting is
-- BAKED IN at CREATE time. Set here for consistency with every other module in the project.
SET QUOTED_IDENTIFIER ON;
GO

-- The three EPAL_ISSI tables are reached through local synonyms, which is the ONLY permitted access path -- no
-- three-part names, and no CREATE SYNONYM in this repository either (validate-sql.py rejects one that points outside
-- the database). dbo.MTB_DEFINED_TASK_EXTEND_LIST is the one this project added on 2026-10-02; see the README for the
-- statement that creates it. Names every missing one at once, rather than letting CREATE VIEW fail on the first.
DECLARE @MissingSynonyms NVARCHAR (MAX) =
        STUFF ((SELECT N', ' + n.RequiredName
                  FROM (VALUES (N'dbo.MTB_DEFINED_TASK_EXTEND_LIST')
                             , (N'dbo.MTB_DEFINED_TASK_LIST')
                             , (N'dbo.DSKMTB_ACTIVITY_TYPE')) AS n (RequiredName)
                 WHERE OBJECT_ID (n.RequiredName, N'SN') IS NULL
                 ORDER BY n.RequiredName
                   FOR XML PATH (N''), TYPE).value (N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

IF @MissingSynonyms IS NOT NULL
BEGIN
    DECLARE @SynonymMessage NVARCHAR (2048) =
            CONCAT (N'This view reads EPAL_ISSI through local synonyms and these are missing: ', @MissingSynonyms
                  , N'. Create them in this database before deploying (see the README) -- do NOT "fix" this by putting a three-part EPAL_ISSI name in the view, which the project conventions forbid.');
    ;THROW 50000, @SynonymMessage, 1;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.vwClockPauseResumeTask
Author:       rsincero
CreateDate:   2026-10-02
========================================================================================================================
Description:

One row per row of EPAL_ISSI.dbo.MTB_DEFINED_TASK_EXTEND_LIST: the pause / resume task pairs configured for the ETS
turnaround clock, per activity type, with the human-friendly name of each task.

ETS keeps one turnaround clock per activity and stores the days used in ACTIVITY_TASK_LIST.DAYS_USED_QTY, which is
days_used_qty in dbo.vwPermitTurnaroundPerformance. Completing a PAUSE task stops the clock, completing its RESUME task
restarts it, and a pause of one day or more is left out of the days used (see ETS_Clock.txt). This view is the list of
which tasks do that, for which activity type:

    pause_reference_task_id    PRED_REFERENCE_TASK_ID   the task that pauses the clock
    resume_reference_task_id   EXT_REFERENCE_TASK_ID    the task that restarts it
    stop_reference_task_id     PRIM_REFERENCE_TASK_ID   the task that stops it for good: approval issued, 1000000002

Each task id is named from MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC, the description ETS shows once a task is
completed ("Received requested info" rather than "Receive requested info"), and carries that table's INACTIVE_FLAG.

========================================================================================================================
Requirements and Key Dependencies:

Three SYNONYMS onto EPAL_ISSI, asserted above and the only permitted access path:
    dbo.MTB_DEFINED_TASK_EXTEND_LIST   the pause / resume pairs. ADDED FOR THIS VIEW, 2026-10-02; created outside
                                       this repository like the others (see the README).
    dbo.MTB_DEFINED_TASK_LIST          the task descriptions and INACTIVE_FLAG
    dbo.DSKMTB_ACTIVITY_TYPE           the activity type's label and INACTIVE_FLAG

No grant of its own. Reads flow through the schema-level grant on SCHEMA::dbo. Reading the view needs read access to
EPAL_ISSI, exactly as dbo.vwPermitTurnaroundPerformance does; without it the query fails with error 916.

========================================================================================================================
Notes:

NOTHING IS FILTERED. MTB_DEFINED_TASK_EXTEND_LIST still holds the history of how the clock was configured -- the
first pair, 200000 / 200001, went in for one hazardous waste activity on 2008-03-24 and has since been renamed
"Extension Granted" / "Extension Ended" (see util.func_get_total_days_delay_rs). Rows are kept and their state is
shown instead: the two task INACTIVE_FLAG columns and activity_type_inactive_flag. Filter on them for "in use today".

ALL THREE LOOKUPS ARE LEFT JOINS, so a pair whose task or activity type is missing from its lookup table still comes
through, with a NULL description, rather than disappearing from the list of configured pauses. The lookups are by
their natural keys -- REFERENCE_TASK_ID, and the four activity codes -- which are taken to be unique in EPAL_ISSI.
That could NOT be measured when this view was written (the author's login has no EPAL_ISSI access); if either is not
unique this view fans out, and the second query below shows it.

last_updated_by / last_updated_date are USER_LAST_UPDT / TMSP_LAST_UPDT: the last change to the row, not necessarily
when the pair was added.

THE PAIR CAN INCLUDE THE STOP TASK. For Wetlands, 3037 "Send Report and Recommendation to the Board of Public Works"
pauses the clock and 1000000002 "Approval Issued" is its resume task -- consistent with the Wetlands exception in
dbo.vwPermitTurnaroundPerformance, which ends the measured time at 3037.

========================================================================================================================
Example Usage and Performance:

-- every pause / resume pair configured for Scrap Tire
select activity_type_code, activity_type_label, pause_task_desc, resume_task_desc, last_updated_date
  from dbo.vwClockPauseResumeTask
 where program_code = '27' and activity_type_label like 'Scrap Tire%'
 order by activity_type_code, pause_task_desc;

-- fan-out check: must return no rows (see the Notes)
select program_code, activity_category_code, activity_class_code, activity_type_code
     , pause_reference_task_id, resume_reference_task_id, count (*) as Copies
  from dbo.vwClockPauseResumeTask
 group by program_code, activity_category_code, activity_class_code, activity_type_code
        , pause_reference_task_id, resume_reference_task_id
having count (*) > 1;

A small reference table and three key lookups. Not measured, for the reason in the Notes.

========================================================================================================================
Modification History:

Date:		2026-10-02
Author:		rsincero
Ticket:		PTT
Description:
Original. Feeds the Pause-Resume Tasks and No Pause-Resume tabs of TurnaroundPerformance.rdl, through
dbo.uspPermitTurnaroundPauseResumeTasks and dbo.uspPermitTurnaroundNoPauseResume.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW dbo.vwClockPauseResumeTask
AS
SELECT x.PROGRAM_CODE            AS program_code
     , x.ACTIVITY_CATEGORY_CODE  AS activity_category_code
     , x.ACTIVITY_CLASS_CODE     AS activity_class_code
     , x.ACTIVITY_TYPE_CODE      AS activity_type_code
     , aty.ACTIVITY_TYPE_LABEL   AS activity_type_label
     , aty.INACTIVE_FLAG         AS activity_type_inactive_flag
     , x.PRED_REFERENCE_TASK_ID  AS pause_reference_task_id
     , pau.COMPLETED_TASK_DESC   AS pause_task_desc
     , pau.INACTIVE_FLAG         AS pause_task_inactive_flag
     , x.EXT_REFERENCE_TASK_ID   AS resume_reference_task_id
     , res.COMPLETED_TASK_DESC   AS resume_task_desc
     , res.INACTIVE_FLAG         AS resume_task_inactive_flag
     , x.PRIM_REFERENCE_TASK_ID  AS stop_reference_task_id
     , stp.COMPLETED_TASK_DESC   AS stop_task_desc
     , x.USER_LAST_UPDT          AS last_updated_by
     , x.TMSP_LAST_UPDT          AS last_updated_date
  FROM dbo.MTB_DEFINED_TASK_EXTEND_LIST AS x

       -- LEFT throughout: a configured pair stays visible even when a lookup row is missing. See the Notes.
  LEFT JOIN dbo.DSKMTB_ACTIVITY_TYPE AS aty
         ON aty.PROGRAM_CODE           = x.PROGRAM_CODE
        AND aty.ACTIVITY_CATEGORY_CODE = x.ACTIVITY_CATEGORY_CODE
        AND aty.ACTIVITY_CLASS_CODE    = x.ACTIVITY_CLASS_CODE
        AND aty.ACTIVITY_TYPE_CODE     = x.ACTIVITY_TYPE_CODE
  LEFT JOIN dbo.MTB_DEFINED_TASK_LIST AS pau
         ON pau.REFERENCE_TASK_ID = x.PRED_REFERENCE_TASK_ID
  LEFT JOIN dbo.MTB_DEFINED_TASK_LIST AS res
         ON res.REFERENCE_TASK_ID = x.EXT_REFERENCE_TASK_ID
  LEFT JOIN dbo.MTB_DEFINED_TASK_LIST AS stp
         ON stp.REFERENCE_TASK_ID = x.PRIM_REFERENCE_TASK_ID;
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwClockPauseResumeTask'
    , @Description = N'One row per EPAL_ISSI MTB_DEFINED_TASK_EXTEND_LIST row: the pause / resume task pairs configured for the ETS turnaround clock, per activity type, each task named from MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC. Unfiltered -- historical pairs are kept, with the task and activity type INACTIVE_FLAGs shown so a reader can filter to what is in use. Read through the synonyms dbo.MTB_DEFINED_TASK_EXTEND_LIST, dbo.MTB_DEFINED_TASK_LIST and dbo.DSKMTB_ACTIVITY_TYPE.';
GO

EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'program_code'
    , @Description = N'Two-character ETS program code of the activity type the pair is configured for. From MTB_DEFINED_TASK_EXTEND_LIST.PROGRAM_CODE.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'activity_category_code'
    , @Description = N'Activity category code of the activity type the pair is configured for, e.g. APP. From MTB_DEFINED_TASK_EXTEND_LIST. Not filtered: pairs for every category come through.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'activity_class_code'
    , @Description = N'Activity class code of the activity type the pair is configured for. From MTB_DEFINED_TASK_EXTEND_LIST.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'activity_type_code'
    , @Description = N'Activity type code of the activity type the pair is configured for. With the three columns before it, the key dbo.stdPermitTT and dbo.vwPermitTurnaroundPerformance match on.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'activity_type_label'
    , @Description = N'The activity type''s name in ETS, DSKMTB_ACTIVITY_TYPE.ACTIVITY_TYPE_LABEL. NULL if the activity type is missing from that table.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'activity_type_inactive_flag'
    , @Description = N'DSKMTB_ACTIVITY_TYPE.INACTIVE_FLAG for the activity type, passed through. NULL if the activity type is missing from that table.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'pause_reference_task_id'
    , @Description = N'Reference task id of the task that PAUSES the clock: MTB_DEFINED_TASK_EXTEND_LIST.PRED_REFERENCE_TASK_ID.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'pause_task_desc'
    , @Description = N'Name of the pause task: MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC, the description ETS shows for the completed task. NULL if the task id is missing from that table.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'pause_task_inactive_flag'
    , @Description = N'MTB_DEFINED_TASK_LIST.INACTIVE_FLAG for the pause task, passed through.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'resume_reference_task_id'
    , @Description = N'Reference task id of the task that RESUMES the clock: MTB_DEFINED_TASK_EXTEND_LIST.EXT_REFERENCE_TASK_ID.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'resume_task_desc'
    , @Description = N'Name of the resume task: MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC. NULL if the task id is missing from that table.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'resume_task_inactive_flag'
    , @Description = N'MTB_DEFINED_TASK_LIST.INACTIVE_FLAG for the resume task, passed through.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'stop_reference_task_id'
    , @Description = N'Reference task id of the task that stops the clock for good when the permit is issued: MTB_DEFINED_TASK_EXTEND_LIST.PRIM_REFERENCE_TASK_ID, normally 1000000002.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'stop_task_desc'
    , @Description = N'Name of the stop task: MTB_DEFINED_TASK_LIST.COMPLETED_TASK_DESC. NULL if the task id is missing from that table.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'last_updated_by'
    , @Description = N'Who last changed the pair''s row: MTB_DEFINED_TASK_EXTEND_LIST.USER_LAST_UPDT. Not necessarily who added it.';
GO
EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'VIEW', @ObjectName = N'vwClockPauseResumeTask'
    , @ColumnName = N'last_updated_date'
    , @Description = N'When the pair''s row was last changed: MTB_DEFINED_TASK_EXTEND_LIST.TMSP_LAST_UPDT. Not necessarily when it was added.';
GO
