-- SET XACT_ABORT ON sits ABOVE the header block deliberately. The GO on the next line ends the batch, and
-- sys.sql_modules stores only the batch that contains CREATE -- so a header placed AFTER this GO is invisible
-- to anyone reading the trigger out of the database through sp_helptext, OBJECT_DEFINITION, or SSMS
-- "Script as CREATE", which is where a maintainer actually reads it. The header has to be the LAST thing
-- before CREATE with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER. sqlcmd defaults it OFF where every other client defaults it ON, the setting is
-- BAKED IN at CREATE time, and a module carrying it OFF cannot run DML against a table with a filtered index
-- (error 1934). This trigger's whole body is an UPDATE against dbo.stdPermitTT, which has one --
-- UX_dbo_stdPermitTT_Natural, filtered WHERE IsDeleted = 0 -- so a deploy without this setting produces a
-- trigger that compiles and then fails on every update of the table it is meant to protect.
SET QUOTED_IDENTIFIER ON;
GO

-- The table has to exist before CREATE OR ALTER TRIGGER can name it, and in this project it is NOT created by
-- deploying a script: 020 deploys a PROCEDURE that creates the table on its first EXECUTE. So a fresh database
-- reaches this script with no table, and the native failure is "Invalid object name 'dbo.stdPermitTT'", which
-- does not tell the operator what to do about it. This does.
IF OBJECT_ID (N'dbo.stdPermitTT', N'U') IS NULL
BEGIN
    ;THROW 50000, N'dbo.stdPermitTT does not exist yet. Run sql/020_dbo.uspBuildStdPermitTT.sql and then EXEC dbo.uspBuildStdPermitTT, which creates the table, before running this script.', 1;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.trg_au_updt_stdPermitTT
Author:       rsincero
CreateDate:   2026-09-22
========================================================================================================================
Description:

Owns the modification and soft-delete audit columns on dbo.stdPermitTT. Recomputes auditModifiedDateUtc / tmsp_last_updt
and the two "who" columns on every update, and stamps auditDeletedBy / auditDeletedDateUtc when IsDeleted transitions
0 -> 1. This is the plain-table equivalent of what the INSTEAD OF triggers do for a table with a view wrapper.

========================================================================================================================
Requirements and Key Dependencies:

dbo.stdPermitTT and its PRIMARY KEY PK_dbo_stdPermitTT (id). The table is created by dbo.uspBuildStdPermitTT at run
time, so that procedure must have been executed at least once -- asserted above.

util.uspSetObjectDescription, for the extended property at the foot of this script. @ObjectType = N'TRIGGER' requires the
2026-09-22 version of sql/010_util.uspSetObjectDescription.sql; the original rejected TRIGGER outright.

No grant of its own. A trigger runs in the caller's security context against a table the caller already holds UPDATE on,
so whatever grants dbo.stdPermitTT cover this too.

========================================================================================================================
Notes:

WHY THIS EXISTS. All eleven audit columns on dbo.stdPermitTT carry DEFAULT constraints, and a DEFAULT fires on INSERT
ONLY. Until this trigger existed, every UPDATE against the table left the audit trail to the caller's good manners, and
all three of these succeeded against a login holding nothing but UPDATE:

    update dbo.stdPermitTT set turnaround_time = 99 where id = 1;
        -- auditModifiedBy, auditModifiedDateUtc, user_last_updt and tmsp_last_updt LEFT STALE at their insert-time
        -- values. The trail does not go quiet; it asserts nobody has touched the row since it was created.

    update dbo.stdPermitTT set auditModifiedDateUtc = '1999-01-01' where id = 1;
        -- accepted verbatim. A back-dated audit trail, written by hand.

    update dbo.stdPermitTT set IsDeleted = 1 where id = 1;
        -- the row is soft-deleted and auditDeletedBy / auditDeletedDateUtc keep their INSERT-time defaults, so the row
        -- claims whoever created it deleted it at the moment they created it.

dbo.uspBuildStdPermitTT maintained all four pairs by hand on both of its UPDATE branches, which is why the table's data
is correct today. That is exactly the weakness: the guarantee held only for that one writer, and soft delete on a plain
table arrives as a bare UPDATE of the flag -- there is no view here, and DELETE is deliberately not granted -- so any
other caller could do all three of the above.

THIS TABLE CARRIES TWO AUDIT CONVENTIONS AND THE TRIGGER MAINTAINS BOTH. The seven audit and IsDeleted columns are the
project convention; user_created / tmsp_created / user_last_updt / tmsp_last_updt are the ETS house convention this
database's other tooling reads. Both pairs record the same fact and both are stale-on-UPDATE for the same reason, so
maintaining only the project pair would have left half the trail broken and the two halves disagreeing about when the
row last changed. Each column keeps its OWN expression rather than being unified: user_last_updt gets
LEFT (SUSER_SNAME (), 20) and tmsp_last_updt gets local time, matching their DEFAULTs and matching what
dbo.uspBuildStdPermitTT writes, while the audit* pair gets ORIGINAL_LOGIN () and UTC. The trigger's job is to make an
UPDATE behave the way an INSERT already does, not to redesign the relationship between the two conventions.

    One consequence, recorded because it is pre-existing and not introduced here: SUSER_SNAME () and ORIGINAL_LOGIN ()
    differ under impersonation, so user_last_updt and auditModifiedBy can name different logins even though the column
    description for user_last_updt says they hold "the same login". dbo.uspBuildStdPermitTT already has this, via
    @ActorShort and @Actor. Unifying them is a data-semantics decision for the table's owner, not something to change
    inside a trigger.

BOTH "WHO" COLUMNS ARE CALLER-OVERRIDABLE, the two "when" columns are not. Overridability on auditModifiedBy comes
straight from templates/table.sql, which keeps it so the plain shape is not STRICTER than the wrapped shape and does not
break the migration path that carries original audit values across. Extending the same treatment to user_last_updt is a
deliberate addition: the two columns record one fact, so a migration that preserves auditModifiedBy and silently loses
user_last_updt would leave the row self-contradictory. UPDATE (<col>) is what distinguishes "the caller named this
column" from "the caller's UPDATE happened to carry the value already in the row"; without it every update looks
deliberate.

WHY THE 0 -> 1 TEST IS EXPLICIT. There is no filter in front of a plain table, so an already-deleted row can be updated
again. Testing only the after-image would re-stamp auditDeletedBy and auditDeletedDateUtc on every later touch of a row
deleted months ago, quietly moving the delete forward in time. Hence d.IsDeleted = 0 AND i.IsDeleted = 1.

AN UNDELETE LEAVES auditDeleted* ALONE, on purpose. Both columns are NOT NULL with defaults, so there is no empty state
to restore them to, and their descriptions already say they are meaningful only when IsDeleted = 1. Clearing them on a
1 -> 0 transition would destroy the record of a delete that really happened.

AFTER, NOT INSTEAD OF. A plain table can carry an INSTEAD OF trigger and it would save a write, but an INSTEAD OF UPDATE
trigger has to name every payload column -- so adding a column to dbo.stdPermitTT would mean editing this trigger too,
and forgetting would silently make that column not updatable. This table has already grown twice, from 22 columns to 28.
AFTER costs one extra UPDATE and cannot be made stale by a schema change.

RECURSION. This trigger updates the table it is defined on. RECURSIVE_TRIGGERS is OFF in this database, so it does not
re-fire -- but that is a DATABASE option someone else can turn on, and the failure if they do is an infinite loop rather
than a wrong value. The TRIGGER_NESTLEVEL guard makes the trigger correct on its own terms instead of correct because of
a setting it does not control.

JOINING ON THE PRIMARY KEY is sound because id is an IDENTITY column and SQL Server rejects an UPDATE against one
outright, so deleted and inserted cannot disagree about it. A table whose key is not IDENTITY would need
IF UPDATE (<KeyColumn>) ;THROW 50010 ... above this.

DATETIME2 WITHOUT PRECISION IS DELIBERATE HERE, and it is the one place this file departs from rule 1. The four datetime
columns this trigger writes are all DATETIME2 (7) on the deployed table, and dbo.uspBuildStdPermitTT declares its own
@NowUtc / @NowLocal bare for the same stated reason: a DATETIME2 (3) variable would round on the way in, so the trigger
would write millisecond-precision values into columns whose DEFAULT writes full precision, and rows would carry
different resolutions depending on which writer touched them last. The correct fix is the columns, not the variables --
see the handoff note below.

INTERACTION WITH dbo.uspBuildStdPermitTT, verified rather than assumed. Its MERGE uses OUTPUT ... INTO @Changes, so the
error-334 restriction on a bare OUTPUT against a table with an enabled trigger does not apply; its counts come from
@Changes and never from @@ROWCOUNT, so the trigger's inner UPDATE cannot corrupt them; and its MATCHED branch still
fires only when a value actually differs, so this trigger only ever runs for rows that genuinely changed and
tmsp_last_updt still does not drift on a no-op rebuild. The one visible change is that the audit timestamps on updated
rows now come from the trigger's own SYSUTCDATETIME () rather than the procedure's run-wide @NowUtc -- still one value
per statement, so rows stay consistent with each other.

========================================================================================================================
Example Usage and Performance:

update dbo.stdPermitTT set turnaround_time = 99 where id = 1;   -- audit columns follow automatically
update dbo.stdPermitTT set IsDeleted = 1 where id = 1;          -- auditDeleted* stamped, this touch only

Set-based; one extra UPDATE per statement regardless of row count, touching six columns. That doubling is the price of
the guarantee -- a plain UPDATE against this table is now two writes. It is the reason the trigger returns early on an
UPDATE that matched no rows, which fires the trigger with an empty inserted table.

========================================================================================================================
Modification History:

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
Original. dbo.stdPermitTT was deployed on 2026-09-10 with no trigger at all, which left it the one shape the
conventions do not allow: a plain table whose audit trail holds only while every caller maintains it by hand. Adapted
from templates/table.sql section 4, extended to maintain the ETS user_last_updt / tmsp_last_updt pair alongside the
project's audit* columns.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_au_updt_stdPermitTT
ON dbo.stdPermitTT
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- NOCOUNT stays ON for the whole trigger, unlike the INSTEAD OF triggers in the temporal template which switch it
    -- OFF before their write. There the inner statement IS the caller's work and its row count is the one the caller
    -- should see. Here the caller's own UPDATE has already reported, so letting this one report too would show every
    -- update twice.

    -- An UPDATE that matched nothing still fires the trigger, with inserted and deleted both empty.
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- See RECURSION in the notes. Guarding on this trigger's own depth rather than on the database option, so the
    -- trigger cannot be made to loop by a setting changed elsewhere.
    IF TRIGGER_NESTLEVEL (@@PROCID, 'AFTER', 'DML') > 1 RETURN;

    -- One value per fact, hoisted, so a soft delete arriving here stamps auditDeletedDateUtc and auditModifiedDateUtc
    -- with the SAME instant rather than two SYSUTCDATETIME () calls a millisecond boundary can separate. @NowUtc and
    -- @NowLocal are bare DATETIME2 on purpose -- see the note in the header.
    DECLARE @NowUtc     DATETIME2      = SYSUTCDATETIME ()
          , @NowLocal   DATETIME2      = SYSDATETIME ()
          , @Actor      NVARCHAR (128) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (128)), N'')
                                                 , ORIGINAL_LOGIN ())
          , @ActorShort VARCHAR  (20)  = LEFT (SUSER_SNAME (), 20);

    UPDATE t
       SET -- Recomputed every time, whatever the caller passed. These are the columns the DEFAULTs cannot maintain, and
           -- overwriting rather than defaulting is also what stops a hand-written back-date from surviving.
           t.auditModifiedDateUtc = @NowUtc
         , t.tmsp_last_updt       = @NowLocal

           -- Caller-overridable, and the only two that are. See the header note.
         , t.auditModifiedBy      = CASE WHEN UPDATE (auditModifiedBy)
                                         THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                         ELSE @Actor
                                    END
         , t.user_last_updt       = CASE WHEN UPDATE (user_last_updt)
                                         THEN COALESCE (NULLIF (i.user_last_updt, ''), @ActorShort)
                                         ELSE @ActorShort
                                    END

           -- The soft delete arriving as a bare UPDATE of the flag, which on a plain table is the ONLY way it can
           -- arrive: there is no view here, and DELETE is not granted precisely because it would be a hard delete. So
           -- this branch is not an edge case, it is the main soft-delete path for this shape.
         , t.auditDeletedBy       = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @Actor  ELSE t.auditDeletedBy      END
         , t.auditDeletedDateUtc  = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @NowUtc ELSE t.auditDeletedDateUtc END
      FROM dbo.stdPermitTT AS t
      JOIN inserted        AS i ON i.id = t.id
      JOIN deleted         AS d ON d.id = t.id;
END;
GO


-- Rules 4 and 5 cover a trigger exactly as they cover a procedure. This call is what the 2026-09-22 correction to
-- sql/010_util.uspSetObjectDescription.sql made possible: before it, @ObjectType = N'TRIGGER' was rejected with
-- THROW 50000, so there was no permitted way to describe a trigger at all.
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_au_updt_stdPermitTT'
    , @Description = N'Owns the modification and soft-delete audit columns on dbo.stdPermitTT. Recomputes auditModifiedDateUtc, tmsp_last_updt, auditModifiedBy and user_last_updt on every UPDATE, and stamps auditDeletedBy / auditDeletedDateUtc on an IsDeleted 0 -> 1 transition only. Exists because a DEFAULT fires on INSERT only, so without it every UPDATE left the audit trail to the caller''s good manners -- including a bare soft delete, which on a plain table is the only form a soft delete can take. Maintains both audit conventions the table carries: the project''s audit* columns in UTC from ORIGINAL_LOGIN (), and the ETS user_last_updt / tmsp_last_updt pair in local time from SUSER_SNAME (), each keeping the expression its own DEFAULT uses.';
GO
