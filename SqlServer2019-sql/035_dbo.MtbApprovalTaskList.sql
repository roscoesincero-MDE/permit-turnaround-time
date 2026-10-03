-- SET XACT_ABORT ON and QUOTED_IDENTIFIER ON sit above everything, and above the trigger's header block,
-- for the reasons spelled out in 040: sys.sql_modules stores only the batch containing CREATE, so a header
-- placed after a GO is invisible to sp_helptext. QUOTED_IDENTIFIER is baked in at CREATE time and this file
-- creates a trigger that runs DML against a table carrying a filtered index -- which is error 1934 territory
-- if it is ever OFF. sqlcmd defaults it OFF where every other client defaults it ON; set it explicitly so a
-- hand run without  sqlcmd -I  cannot get it wrong.
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------------------------
-- 1. The table. Guarded, so a second run is a no-op.
--
--    WHY THERE IS A SURROGATE KEY ON A 463-ROW LOOKUP WHOSE NATURAL KEY IS ALREADY A BIGINT. REFERENCE_TASK_ID is
--    the primary key of REF.mtb_approval_task_list and the obvious choice here too. It is not the choice made, for
--    two reasons that both follow from the soft-delete rule:
--
--      - a PK directly on ReferenceTaskId means a soft-deleted row BLOCKS re-creation of the same task id. The
--        right move then is to undelete rather than insert, which the MERGE in section 5 does -- but the
--        constraint would make the wrong move fail at 2am instead of converging. The filtered unique index in
--        section 3 enforces the same uniqueness over LIVE rows only, which is what the rule actually wants.
--      - the audit trigger in section 4 joins inserted to deleted on the primary key. On an IDENTITY column SQL
--        Server rejects an UPDATE outright, so that join cannot be wrong. On a natural key it can: deleted holds
--        the old value and inserted the new one, so a statement that changed the key would join rows to the wrong
--        partners. The trigger still guards ReferenceTaskId explicitly, because the natural key should not move
--        either -- but the guard is a business rule, not the thing holding the audit trail together.
-- -------------------------------------------------------------------------------------------------------------------
IF OBJECT_ID (N'dbo.MtbApprovalTaskList', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MtbApprovalTaskList
    (
        -- ---------------------------------------------------------------------------------------------------------
        -- Surrogate key, then the natural key. See the section comment above.
        -- ---------------------------------------------------------------------------------------------------------
        MtbApprovalTaskListId BIGINT          IDENTITY (1, 1) NOT NULL,
        ReferenceTaskId       BIGINT          NOT NULL,

        -- ---------------------------------------------------------------------------------------------------------
        -- Payload. TaskDesc is varchar(100) in the source and 97 characters is the longest value present, so the
        -- width is carried across rather than widened -- a copy that accepts values the source cannot hold would
        -- diverge silently on the first reload.
        -- ---------------------------------------------------------------------------------------------------------
        TaskDesc              VARCHAR (100)   NOT NULL,

        -- The seven flags. ALL SEVEN ARE  int  IN THE SOURCE AND BIT HERE. Measured before converting: every one
        -- holds only 0 and 1 across all 463 rows, so nothing is lost, and BIT makes the two-valued intent part of
        -- the type instead of a convention a future writer can break with a 2. This is the one place this table
        -- deliberately does NOT mirror the source's declared types.
        IsActive              BIT             NOT NULL,
        StartsClock           BIT             NOT NULL,
        StopsClock            BIT             NOT NULL,
        IsIssueTask           BIT             NOT NULL,
        IsCloseTask           BIT             NOT NULL,
        PausesClock           BIT             NOT NULL,
        ResumesClock          BIT             NOT NULL,

        -- Prose, not JSON, so no ISJSON check. nvarchar(max) in the source and populated on 30 of 463 rows, the
        -- longest 646 characters. Kept as MAX rather than narrowed to a measured width: it is free-text
        -- documentation and the next edit is as likely to be longer as shorter.
        BusinessRule          NVARCHAR (MAX)  NULL,

        -- ---------------------------------------------------------------------------------------------------------
        -- The SOURCE system's own audit fields, prefixed Src so they are never confused with the local audit*
        -- columns below. REF.mtb_approval_task_list carries the ETS-style pair (user_created / tmsp_created /
        -- user_last_updt / tmsp_last_updt) rather than this project's; those are the source's provenance and this
        -- is mirrored data, so they come across under their own prefix and the local block is maintained here.
        --
        -- DATETIME2 (3), where the source columns are datetime2(7). Rule 1: the source system's precision is its
        -- business and the copy is ours. It does mean a sub-millisecond source timestamp is truncated in the copy,
        -- which is acceptable for a provenance field on a 463-row lookup that is reloaded wholesale -- do not
        -- reconcile these to the millisecond against REF.
        -- ---------------------------------------------------------------------------------------------------------
        SrcUserCreated        VARCHAR (20)    NULL,
        SrcTmspCreated        DATETIME2 (3)   NULL,
        SrcUserLastUpdt       VARCHAR (20)    NULL,
        SrcTmspLastUpdt       DATETIME2 (3)   NULL,

        -- ---------------------------------------------------------------------------------------------------------
        -- Standard audit columns, rule 1. Soft delete only; there is no hard delete.
        -- Convention: DF_<schema>_<tableName>_<fieldName>, unique per database.
        -- ---------------------------------------------------------------------------------------------------------
        IsDeleted            BIT             NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_IsDeleted            DEFAULT (0),
        auditDeletedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditDeletedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditDeletedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditDeletedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditCreatedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditCreatedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditCreatedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditCreatedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditModifiedBy      NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditModifiedBy      DEFAULT (ORIGINAL_LOGIN ()),
        auditModifiedDateUtc DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_MtbApprovalTaskList_auditModifiedDateUtc DEFAULT (SYSUTCDATETIME ()),

        CONSTRAINT PK_dbo_MtbApprovalTaskList PRIMARY KEY CLUSTERED (MtbApprovalTaskListId)
    );
END;
GO

-- -------------------------------------------------------------------------------------------------------------------
-- 2. Later changes go here, ADDITIVELY and separately guarded -- never by editing section 1, which is skipped on a
--    database where the table already exists. Nothing yet.
-- -------------------------------------------------------------------------------------------------------------------

-- -------------------------------------------------------------------------------------------------------------------
-- 3. Indexes.
-- -------------------------------------------------------------------------------------------------------------------

-- The natural key, filtered so a soft-deleted row does not block re-creation of the same task id. This is the
-- constraint that makes ReferenceTaskId safe to join on: unique across live rows, which is all any reader sees.
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'UX_dbo_MtbApprovalTaskList_ReferenceTaskId'
                  AND object_id = OBJECT_ID (N'dbo.MtbApprovalTaskList'))
BEGIN
    CREATE UNIQUE INDEX UX_dbo_MtbApprovalTaskList_ReferenceTaskId
        ON dbo.MtbApprovalTaskList (ReferenceTaskId)
        WHERE IsDeleted = 0;
END;
GO

-- The access path dbo.vwPermitTurnaroundPerformance actually uses: "give me every close task". 10 of the 463 rows
-- qualify, so this is a 10-row seek instead of a 463-row scan once per activity -- and the view probes it 191,603
-- times. INCLUDE (TaskDesc) makes it covering, since closedType reads that column and nothing else.
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'IX_dbo_MtbApprovalTaskList_IsCloseTask'
                  AND object_id = OBJECT_ID (N'dbo.MtbApprovalTaskList'))
BEGIN
    CREATE INDEX IX_dbo_MtbApprovalTaskList_IsCloseTask
        ON dbo.MtbApprovalTaskList (IsCloseTask, ReferenceTaskId)
        INCLUDE (TaskDesc)
        WHERE IsDeleted = 0;
END;
GO

-- -------------------------------------------------------------------------------------------------------------------
-- 4. The audit trigger. Not optional -- the seven audit columns carry DEFAULTs, and a DEFAULT fires on INSERT only,
--    so without this every UPDATE leaves auditModifiedBy / auditModifiedDateUtc asserting that nobody has touched
--    the row since it was created, and a soft delete leaves auditDeletedBy claiming the creator deleted it at the
--    moment of creation. See templates/table.sql section 4 for the measured demonstration.
-- -------------------------------------------------------------------------------------------------------------------
/***********************************************************************************************************************
ObjectName:   dbo.trg_au_updt_MtbApprovalTaskList
Author:       rsincero
CreateDate:   2026-09-23
========================================================================================================================
Description:

Owns the modification and soft-delete audit columns on dbo.MtbApprovalTaskList. Recomputes auditModifiedDateUtc on
every update, stamps auditDeletedBy / auditDeletedDateUtc when IsDeleted transitions 0 -> 1, and rejects any attempt to
move ReferenceTaskId. The plain-table equivalent of the INSTEAD OF triggers a wrapped table carries.

========================================================================================================================
Requirements and Key Dependencies:

dbo.MtbApprovalTaskList and its PRIMARY KEY. No grant of its own: a trigger runs in the caller's security context
against a table the caller already holds UPDATE on.

========================================================================================================================
Notes:

THE 0 -> 1 TEST IS EXPLICIT, not just  i.IsDeleted = 1.  There is no view in front of this table, so an
already-deleted row can be updated again; testing only the after-image would re-stamp auditDeletedBy and
auditDeletedDateUtc on every later touch of a row deleted months ago, quietly moving the delete forward in time.

REFERENCETASKID IS IMMUTABLE and the trigger throws 50010 rather than silently correcting. It is the natural key, the
column dbo.vwPermitTurnaroundPerformance joins on, and the MERGE key in section 5 -- moving it would silently re-point
every reader at a different task. THROW rather than RAISERROR + RETURN: RETURN ends the trigger and nothing else, so
the UPDATE would be applied and the caller's batch would continue believing it had been validated.

AN UNDELETE LEAVES auditDeleted* ALONE, on purpose. Both columns are NOT NULL with defaults, so there is no empty
state to restore them to, and clearing them on a 1 -> 0 transition would destroy the record of a delete that really
happened.

UPDATE (auditModifiedBy) distinguishes "the caller named this column" from "the caller's UPDATE happened to carry the
value already in the row". Without it every update looks deliberate.

RECURSION. This trigger updates the table it is defined on. RECURSIVE_TRIGGERS is OFF by default, but that is a
database option someone else can turn on, and the failure if they do is an infinite loop rather than a wrong value.
The TRIGGER_NESTLEVEL guard makes the trigger correct on its own terms instead of correct because of a setting it does
not control.

========================================================================================================================
Example Usage and Performance:

update dbo.MtbApprovalTaskList set TaskDesc = 'Close Case' where ReferenceTaskId = 3020;  -- audit follows automatically
update dbo.MtbApprovalTaskList set IsDeleted = 1 where ReferenceTaskId = 3020;            -- the soft delete path

Set-based; one extra UPDATE per statement regardless of row count, touching four columns. On a 463-row reference table
reloaded by MERGE, that cost is not measurable.

========================================================================================================================
Modification History:

Date:		2026-09-23
Author:		rsincero
Ticket:		PTT
Description:
Original, with the table.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_au_updt_MtbApprovalTaskList
ON dbo.MtbApprovalTaskList
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- An UPDATE that matched nothing still fires the trigger, with inserted and deleted both empty.
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- See RECURSION in the notes.
    IF TRIGGER_NESTLEVEL (@@PROCID, 'AFTER', 'DML') > 1 RETURN;

    -- The natural key does not move. Checked before anything is stamped, so a rejected statement leaves no trace.
    IF UPDATE (ReferenceTaskId)
       AND EXISTS (SELECT 1
                     FROM inserted AS i
                          JOIN deleted AS d ON d.MtbApprovalTaskListId = i.MtbApprovalTaskListId
                    WHERE i.ReferenceTaskId <> d.ReferenceTaskId)
    BEGIN
        ;THROW 50010, N'ReferenceTaskId is immutable on dbo.MtbApprovalTaskList: it is the natural key, the column dbo.vwPermitTurnaroundPerformance joins on, and the MERGE key used to reload the table. Soft-delete the row and insert the correct task id instead.', 1;
    END;

    -- One value per fact, hoisted: a soft delete arriving here must stamp auditDeletedDateUtc and
    -- auditModifiedDateUtc with the SAME instant, not two SYSUTCDATETIME () calls a millisecond boundary can split.
    DECLARE @Now   DATETIME2 (3)  = SYSUTCDATETIME (),
            @Actor NVARCHAR (255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ());

    UPDATE t
       SET -- Recomputed every time, whatever the caller passed. This is the column the DEFAULT cannot maintain, and
           -- overwriting rather than defaulting is also what stops a hand-written back-date from surviving.
           t.auditModifiedDateUtc = @Now,

           -- Caller-overridable, and the only one that is -- matching the view wrapper on a temporal table.
           t.auditModifiedBy = CASE WHEN UPDATE (auditModifiedBy)
                                    THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                    ELSE @Actor
                               END,

           -- The soft delete arriving as a bare UPDATE of the flag, which on a plain table is the only way it can
           -- arrive: there is no view here, and DELETE is not granted on SCHEMA::dbo precisely because it would be
           -- a hard delete. So this is the main soft-delete path for this shape, not an edge case.
           t.auditDeletedBy      = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @Actor ELSE t.auditDeletedBy      END,
           t.auditDeletedDateUtc = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @Now   ELSE t.auditDeletedDateUtc END
      FROM dbo.MtbApprovalTaskList AS t
      JOIN inserted                AS i ON i.MtbApprovalTaskListId = t.MtbApprovalTaskListId
      JOIN deleted                 AS d ON d.MtbApprovalTaskListId = t.MtbApprovalTaskListId;
END;
GO

-- -------------------------------------------------------------------------------------------------------------------
-- 5. The load, from REF.mtb_approval_task_list.
--
--    WHY THIS SCRIPT CARRIES DATA AT ALL. dbo.vwPermitTurnaroundPerformance reads this table to decide which
--    reference task ids close an activity. An empty table is not a degraded view, it is a view whose closedDate and
--    closedType are NULL on all 191,603 rows -- so the table and its contents are one deliverable.
--
--    CONVERGING, NOT RE-APPLYING. The WHEN MATCHED branch compares every column with NOT EXISTS (SELECT <target
--    columns> INTERSECT SELECT <source columns>) and updates only rows that actually differ. INTERSECT treats two
--    NULLs as equal, exactly as IS NOT DISTINCT FROM does, so the nullable columns need no ISNULL scaffolding and no
--    sentinel values. It is used instead of IS NOT DISTINCT FROM because that is SQL Server 2022+ and this script
--    targets 2019. A correct second run therefore reports 0 inserted / 0 updated / 0 deleted and does NOT move
--    auditModifiedDateUtc -- which a blanket UPDATE would, rewriting the audit trail of the whole table every time
--    somebody re-ran the deploy.
--
--    ROWS THAT VANISH FROM REF ARE SOFT-DELETED, NOT REMOVED, and a row that comes back is UNDELETED rather than
--    re-inserted -- which is the whole reason section 1 has a surrogate key and section 3 a filtered index. A
--    hard DELETE here would also be forbidden outright by the soft-delete rule.
--
--    REF REMAINS THE SOURCE OF RECORD UNTIL SOMEBODY REPOINTS ITS WRITERS. This is a seeded copy, reloaded by
--    re-running this script; it is not yet a master. Editing dbo.MtbApprovalTaskList by hand and then re-running
--    this script will have the edit overwritten from REF. That is deliberate for a copy and wrong for a master, so
--    if this table becomes the master, delete this section rather than leaving it to fight the writers.
-- -------------------------------------------------------------------------------------------------------------------
IF OBJECT_ID (N'REF.mtb_approval_task_list', N'U') IS NULL
BEGIN
    ;THROW 50000, N'REF.mtb_approval_task_list does not exist in this database, so dbo.MtbApprovalTaskList cannot be seeded from it. The table above was created empty -- dbo.vwPermitTurnaroundPerformance will return NULL closedDate / closedType on every row until it is populated.', 1;
END;
GO

DECLARE @Changes TABLE (Action NVARCHAR (10) NOT NULL, IsDeleted BIT NOT NULL);

MERGE dbo.MtbApprovalTaskList AS tgt
USING (SELECT r.reference_task_id
            , r.task_desc
              -- int -> bit. Every source value is 0 or 1, verified before this column list was written; a value of
              -- 2 would fail the conversion here rather than being silently read as true, which is the behaviour
              -- wanted for a flag.
            , CAST (r.IsActive     AS BIT) AS IsActive
            , CAST (r.StartsClock  AS BIT) AS StartsClock
            , CAST (r.StopsClock   AS BIT) AS StopsClock
            , CAST (r.IsIssueTask  AS BIT) AS IsIssueTask
            , CAST (r.IsCloseTask  AS BIT) AS IsCloseTask
            , CAST (r.PausesClock  AS BIT) AS PausesClock
            , CAST (r.ResumesClock AS BIT) AS ResumesClock
            , r.business_rule
            , r.user_created
            , CAST (r.tmsp_created   AS DATETIME2 (3)) AS tmsp_created
            , r.user_last_updt
            , CAST (r.tmsp_last_updt AS DATETIME2 (3)) AS tmsp_last_updt
         -- An unadorned SELECT against a system-versioned table returns current rows only, which is what a copy of
         -- the present state wants. FOR SYSTEM_TIME here would change the grain and duplicate every task id.
         FROM REF.mtb_approval_task_list AS r) AS src
   ON src.reference_task_id = tgt.ReferenceTaskId

       -- Changed if any column differs, NULL-safely. The two SELECT lists must stay in the same order and the same
       -- length -- INTERSECT pairs them by POSITION, not by name, so a column added to one list and not the other
       -- fails to compile, and two columns swapped in one list compare the wrong values without any error.
 WHEN MATCHED AND (NOT EXISTS (SELECT tgt.TaskDesc, tgt.IsActive, tgt.StartsClock, tgt.StopsClock
                                    , tgt.IsIssueTask, tgt.IsCloseTask, tgt.PausesClock, tgt.ResumesClock
                                    , tgt.BusinessRule
                                    , tgt.SrcUserCreated, tgt.SrcTmspCreated, tgt.SrcUserLastUpdt, tgt.SrcTmspLastUpdt
                               INTERSECT
                               SELECT src.task_desc, src.IsActive, src.StartsClock, src.StopsClock
                                    , src.IsIssueTask, src.IsCloseTask, src.PausesClock, src.ResumesClock
                                    , src.business_rule
                                    , src.user_created, src.tmsp_created, src.user_last_updt, src.tmsp_last_updt)
                       -- A row present in REF is live here, so re-appearing after a soft delete counts as a change
                       -- and takes the undelete below.
                   OR tgt.IsDeleted = 1)
      THEN UPDATE
              SET tgt.TaskDesc        = src.task_desc
                , tgt.IsActive        = src.IsActive
                , tgt.StartsClock     = src.StartsClock
                , tgt.StopsClock      = src.StopsClock
                , tgt.IsIssueTask     = src.IsIssueTask
                , tgt.IsCloseTask     = src.IsCloseTask
                , tgt.PausesClock     = src.PausesClock
                , tgt.ResumesClock    = src.ResumesClock
                , tgt.BusinessRule    = src.business_rule
                , tgt.SrcUserCreated  = src.user_created
                , tgt.SrcTmspCreated  = src.tmsp_created
                , tgt.SrcUserLastUpdt = src.user_last_updt
                , tgt.SrcTmspLastUpdt = src.tmsp_last_updt
                , tgt.IsDeleted       = 0

 WHEN NOT MATCHED BY TARGET
      THEN INSERT (ReferenceTaskId, TaskDesc, IsActive, StartsClock, StopsClock, IsIssueTask, IsCloseTask
                 , PausesClock, ResumesClock, BusinessRule, SrcUserCreated, SrcTmspCreated, SrcUserLastUpdt
                 , SrcTmspLastUpdt)
           VALUES (src.reference_task_id, src.task_desc, src.IsActive, src.StartsClock, src.StopsClock
                 , src.IsIssueTask, src.IsCloseTask, src.PausesClock, src.ResumesClock, src.business_rule
                 , src.user_created, src.tmsp_created, src.user_last_updt, src.tmsp_last_updt)

       -- Gone from REF. Soft delete, and only where it is not already soft-deleted, so the second run of a script
       -- that retired a task does not re-stamp auditDeletedDateUtc and move the delete forward in time.
 WHEN NOT MATCHED BY SOURCE AND tgt.IsDeleted = 0
      THEN UPDATE SET tgt.IsDeleted = 1

       -- OUTPUT ... INTO, never a bare OUTPUT: error 334 rejects a bare OUTPUT outright on a table with an enabled
       -- trigger, and dbo.trg_au_updt_MtbApprovalTaskList is one. It is also why the counts below are safe -- they
       -- come from @Changes and never from @@ROWCOUNT, which the trigger's inner UPDATE is free to overwrite.
       -- Same constraint as the MERGE in 020; see the stdPermitTT notes.
OUTPUT $action, inserted.IsDeleted INTO @Changes (Action, IsDeleted);

-- A correct second run prints three zeroes. COUNT and not SUM: on a no-op run @Changes is EMPTY, and SUM over no
-- rows is NULL, so the SUM form reported "NULL NULL NULL" for the one outcome this line exists to confirm.
SELECT 'Inserted'    = COUNT (CASE WHEN Action = N'INSERT' THEN 1 END)
     , 'Updated'     = COUNT (CASE WHEN Action = N'UPDATE' AND IsDeleted = 0 THEN 1 END)
     , 'SoftDeleted' = COUNT (CASE WHEN Action = N'UPDATE' AND IsDeleted = 1 THEN 1 END)
  FROM @Changes;
GO


-- -------------------------------------------------------------------------------------------------------------------
-- 6. Extended properties, rule 4: the table, every column, and the trigger. Through
--    util.uspSetObjectDescription, which adds or updates -- sp_addextendedproperty succeeds once and then fails
--    every subsequent run with "Property already exists".
-- -------------------------------------------------------------------------------------------------------------------

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @Description = N'Reference list of EPAL_ISSI approval task ids and what each one means for an activity''s clock -- one row per REFERENCE_TASK_ID appearing in ACTIVITY_TASK_LIST. The project-convention version of REF.mtb_approval_task_list (463 rows), seeded from it by section 5 of sql/035 and reloaded by re-running that script, so REF REMAINS THE SOURCE OF RECORD until its writers are repointed: a hand edit here is overwritten on the next run. Differs from REF in four ways, all deliberate: a surrogate key plus a filtered unique index on ReferenceTaskId rather than a primary key on it, so a soft-deleted task does not block re-creation; the seven int flags narrowed to BIT, every source value having been verified as 0 or 1; the source''s ETS audit pair carried under a Src prefix with this project''s audit block maintained alongside it; and no copy of the source''s own mtb_approval_task_list_seq surrogate, which has no meaning outside REF. Read by dbo.vwPermitTurnaroundPerformance, which uses IsCloseTask = 1 to decide that an activity has stopped and TaskDesc to say how. All reads must filter IsDeleted = 0.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'MtbApprovalTaskListId'
    , @Description = N'Surrogate key. No business meaning and no counterpart in REF.mtb_approval_task_list -- the natural key is ReferenceTaskId. It exists so the soft-delete rule works (a retired task id can be re-created without a primary-key collision, enforced instead by the filtered index UX_dbo_MtbApprovalTaskList_ReferenceTaskId) and so the audit trigger can join inserted to deleted on a column SQL Server refuses to let an UPDATE move.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'ReferenceTaskId'
    , @Description = N'The EPAL_ISSI reference task id, matching ACTIVITY_TASK_LIST.REFERENCE_TASK_ID and the primary key of REF.mtb_approval_task_list. The natural key of this table and the column every reader joins on: unique across live rows by UX_dbo_MtbApprovalTaskList_ReferenceTaskId, and IMMUTABLE -- dbo.trg_au_updt_MtbApprovalTaskList throws 50010 on any attempt to change it, because moving it would silently re-point every reader at a different task. The values are not dense or contiguous: they run from small three- and four-digit ids (3020, 3037, 3056) to the 1000000000 block that carries the two key tasks every activity has.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'TaskDesc'
    , @Description = N'Human-readable name of the task, e.g. ''Application Received'', ''Approval Issued'', ''Close Case'', ''Send Report and Recommendation to the Board of Public Works''. This is the column dbo.vwPermitTurnaroundPerformance projects as closedType, so it is reporting-facing text and not an internal label -- an edit here changes what a report says. NOT NULL and never blank. 458 distinct values across 463 rows, so it is NOT unique: five descriptions are shared by more than one task id (''Application Withdrawn'' is one), which is why closedType must never be used as a substitute for the task id itself. varchar(100), the source width, with the longest value present at 97 characters.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'IsActive'
    , @Description = N'1 = the task is in current use. CONSTANT 1 ON ALL 463 ROWS as seeded on 2026-09-23, so it currently partitions nothing and no reader should assume it filters anything -- but it is carried rather than dropped because it is the source''s own retirement flag and the next REF edit could set one to 0. A reader that wants only live tasks should filter it anyway, for that reason. Note this is about the TASK DEFINITION being current; whether a given activity performed the task is ACTIVITY_TASK_LIST''s business, and whether this ROW is live is IsDeleted''s. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'StartsClock'
    , @Description = N'1 = completing this task STARTS the turnaround clock. Reference task 1000000000 (''Application Received'') is the one that matters for the permit turnaround measure, and dbo.vwPermitTurnaroundPerformance currently hard-codes that id rather than reading this flag -- so changing this column does not change that view. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'StopsClock'
    , @Description = N'1 = completing this task STOPS the turnaround clock. Broader than IsCloseTask: a task can stop the clock by issuing the approval (1000000002, 3037) as well as by closing the case unissued. dbo.vwPermitTurnaroundPerformance does not read this flag -- it hard-codes 1000000000 / 1000000002 for the clock and uses IsCloseTask for the closure columns -- so this is documentation of intent rather than a switch that view obeys. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'IsIssueTask'
    , @Description = N'1 = completing this task ISSUES the approval, i.e. the activity ended in a decision rather than in a closure. DISJOINT FROM IsCloseTask across all 463 rows as seeded: no task is both, which is what makes "issued" and "closed without issue" meaningful as separate states. Reference task 1000000002 (''Approval Issued'') and 3037 (''Send Report and Recommendation to the Board of Public Works'', the Wetlands substitute) both carry it. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'IsCloseTask'
    , @Description = N'1 = completing this task STOPS THE ACTIVITY, whether or not an approval was ever issued. THIS IS THE COLUMN dbo.vwPermitTurnaroundPerformance READS, and the only one of the seven flags any object in this project currently obeys: that view takes the earliest completed close task as closedDate and this row''s TaskDesc as closedType. 10 of the 463 rows carry it as seeded on 2026-09-23 -- 3020 Close Case, 3056 Administratively closed, 1000000010 Application Withdrawn, 1000000011 Approval Denied, 1000000023 Approval Not Required, 1000000025 Application Voided, 1000000026 Application Withdrawn by the Department, 1000000027 Application Returned, 1000000033 Registration only / Permit not required, 1000000034 Approval no longer needed. SETTING THIS ON AN ELEVENTH TASK CHANGES THAT VIEW''S OUTPUT IMMEDIATELY, with no code change and no redeploy, so treat it as a published interface. Disjoint from IsIssueTask. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'PausesClock'
    , @Description = N'1 = completing this task PAUSES the turnaround clock, typically because the department is waiting on the applicant. This is the mechanism behind the difference between ACTIVITY_TASK_LIST.DAYS_USED_QTY, a working-time clock that can be paused, and dbo.vwPermitTurnaroundPerformance.calendar_days_qty, a wall-clock measure that never stops -- which is why those two columns do not reconcile row by row. Nothing in this project reads this flag yet. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'ResumesClock'
    , @Description = N'1 = completing this task RESUMES a clock paused by a PausesClock task. The counterpart of PausesClock; see that column. Nothing in this project reads this flag yet. Narrowed from int to BIT on copy.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'BusinessRule'
    , @Description = N'Free-text note on how the task is meant to be used, carried across from REF.mtb_approval_task_list.business_rule. Populated on 30 of the 463 rows as seeded, the longest 646 characters. Prose for a human, not a parseable expression -- nothing reads it programmatically and nothing should.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'SrcUserCreated'
    , @Description = N'The SOURCE system''s record of who created the row, from REF.mtb_approval_task_list.user_created. Provenance of the mirrored data, not of this row -- auditCreatedBy is who wrote it here. Prefixed Src so the two can never be confused.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'SrcTmspCreated'
    , @Description = N'The SOURCE system''s creation timestamp, from REF.mtb_approval_task_list.tmsp_created. Narrowed to datetime2(3) from the source''s datetime2(7) per rule 1, so it is TRUNCATED and must not be reconciled to the millisecond against REF. Provenance of the mirrored data; auditCreatedDateUtc is when this row was written here.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'SrcUserLastUpdt'
    , @Description = N'The SOURCE system''s record of who last updated the row, from REF.mtb_approval_task_list.user_last_updt. Provenance of the mirrored data; auditModifiedBy is who last touched it here.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'SrcTmspLastUpdt'
    , @Description = N'The SOURCE system''s last-update timestamp, from REF.mtb_approval_task_list.tmsp_last_updt. Narrowed to datetime2(3) from datetime2(7) per rule 1, so TRUNCATED -- do not reconcile to the millisecond against REF. This is the column to watch to know whether REF has moved since this copy was loaded; auditModifiedDateUtc answers the different question of when the copy last changed.';
GO

/*
    Audit column descriptions. Identical on every table in this project; only @ObjectName changes.
*/

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'IsDeleted'
    , @Description = N'Soft-delete flag. 1 = deleted, 0 = active. This database performs no hard deletes; all reads must filter IsDeleted = 0. Set by the MERGE in sql/035 section 5 when a task id disappears from REF.mtb_approval_task_list, and cleared again if it comes back -- so a retired task keeps its row, and its history, rather than vanishing from the reference list.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditDeletedBy'
    , @Description = N'Login that soft-deleted the row. Stamped by trg_au_updt_MtbApprovalTaskList when IsDeleted transitions 0 -> 1. Meaningful only when IsDeleted = 1; on a live row it holds whatever the insert defaulted, and an undelete deliberately leaves the old value in place.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditDeletedDateUtc'
    , @Description = N'UTC timestamp of the soft delete. Stamped by trg_au_updt_MtbApprovalTaskList on an IsDeleted 0 -> 1 transition, with the same instant as auditModifiedDateUtc. Meaningful only when IsDeleted = 1.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditCreatedBy'
    , @Description = N'Login that inserted the row here. For rows seeded by sql/035 this is whoever ran that script, not whoever created the task in the source system -- SrcUserCreated is that.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditCreatedDateUtc'
    , @Description = N'UTC timestamp of row insert into this table, which for seeded rows is when sql/035 first ran and not when the task was defined in the source. SrcTmspCreated is the latter.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditModifiedBy'
    , @Description = N'Login that last modified the row. Maintained by trg_au_updt_MtbApprovalTaskList, but caller-overridable: a statement that names this column explicitly keeps the value it supplied. That matches the view wrapper on a temporal table, where it is also the only audit column a caller may set on UPDATE.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'MtbApprovalTaskList'
    , @ColumnName  = N'auditModifiedDateUtc'
    , @Description = N'UTC timestamp of last modification. The DEFAULT fires on INSERT only, so trg_au_updt_MtbApprovalTaskList recomputes this column on every UPDATE. A value supplied by the caller is overwritten, deliberately -- this is the one audit column that cannot be back-dated by hand. Note that re-running sql/035 does NOT move it on an unchanged row: the MERGE compares every column and updates only rows that actually differ.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_au_updt_MtbApprovalTaskList'
    , @Description = N'Owns the modification and soft-delete audit columns on dbo.MtbApprovalTaskList. Recomputes auditModifiedDateUtc on every update, stamps auditDeletedBy / auditDeletedDateUtc on an IsDeleted 0 -> 1 transition, and throws 50010 on any attempt to move ReferenceTaskId, the natural key every reader joins on. The plain-table equivalent of the INSTEAD OF triggers on a wrapped table; without it a DEFAULT fires on INSERT only and every UPDATE leaves the audit trail to the caller.';
GO


-- -------------------------------------------------------------------------------------------------------------------
-- 7. Permissions. DELIBERATELY NO GRANT BLOCK, for the reason templates/table.sql gives: reads are granted once per
--    database at the schema by scripts/permissions.sql, and a schema-scoped grant covers objects created after it
--    was issued, including this one. DELETE is never granted on a plain table at any scope -- there is no INSTEAD OF
--    trigger here to turn it into a soft delete, so it would physically remove the row; soft deleting is an UPDATE
--    setting IsDeleted = 1, which the schema grant already allows.
--
--    NOTE FOR THIS DATABASE SPECIFICALLY: neither applicationRole nor readOnlyRole exists in MDE_ETSReport as of
--    2026-09-23, so scripts/permissions.sql has never been run here and there is no schema grant for this table to
--    inherit. That is a pre-existing, project-wide condition rather than anything about this table -- every object
--    in sql/ is in the same position -- and it means this table is currently readable by db_owner and nobody else.
--    Do not paper over it with a per-table grant to a role that does not exist; run the installer.
-- -------------------------------------------------------------------------------------------------------------------
