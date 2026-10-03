/*
    Table template, WITH ROW HISTORY — system-versioned base table plus a view wrapper.

    OPT-IN. Do not use this template unless RowHistory is on for the table (see Configuration in
    SKILL.md). The default is OFF, and templates/table.sql is the normal template. This one costs
    a second schema, a history table that grows without bound, a view, three INSTEAD OF triggers
    and a permissions block per table — worth it for a table whose past values are evidence,
    not worth it for one where they are noise.

    Off is not a one-way door. Everything below can be applied to a table that already exists and
    already has rows, additively and without dropping anything: transfer the table into the base
    schema, ADD the missing columns, ADD the period, switch versioning on, then put the view in
    the name the table used to have so no consumer query changes. Section 3 does exactly that, and
    scripts/logdBChanges.sql is the worked example of it on two populated tables. So a table that
    turns out to need history later is a migration, not a rebuild — which is the reason the default
    can safely be off.

    THE SHAPE, and why it is two schemas and a view.

    A temporal table cannot carry an INSTEAD OF trigger. Soft delete and caller-overridable audit
    columns both need INSTEAD OF semantics. So:

      dboData.Permit      the base table. System-versioned. No application access.
      history.Permit      the history table. Written only by the engine.
      dbo.Permit          the view: SELECT with IsDeleted = 0, plus the three INSTEAD OF triggers.
                          It takes the name the table would otherwise have had, so callers see a
                          table-shaped thing called dbo.Permit and nothing downstream changes.

    Naming: base schema is the consumer schema plus "Data" (dbo -> dboData, plc -> plcData,
    logs -> logsData), history is always "history". Rename if the project has a better convention,
    but keep the rule: the base table never shares a schema with its view.

    ALL THREE SCHEMAS MUST SHARE AN OWNER (dbo). An unbroken ownership chain means a caller's
    permissions are checked on the view only — that is what lets applicationRole write through the view
    while being denied the base table. Break it and every write through the view fails.

    Replace every occurrence of Permit / dbo / dboData. The DF_ constraint names MUST carry the
    base table's real schema and name: default constraint names are unique per database, so
    copying them from another table fails at deploy.

    Re-runnable by design, on the same terms as templates/table.sql: guarded CREATEs, additive
    ALTERs, CREATE OR ALTER on the view and triggers, descriptions through
    util.uspSetObjectDescription. Never DROP IF EXISTS ... CREATE.

    Full reference for the audit contract and the traps: references/change-logging.md.
*/

SET XACT_ABORT ON;
-- QUOTED_IDENTIFIER is not optional. sqlcmd defaults it OFF where every other client defaults it ON,
-- the setting is BAKED IN at CREATE time, and a module carrying it OFF cannot run DML against a table
-- with a filtered index (error 1934) -- which is every table here, via the soft-delete rule.
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------
-- 1. Schemas, and one owner across all three.
-- -------------------------------------------------------------------------------------------
IF SCHEMA_ID (N'dboData') IS NULL EXEC (N'CREATE SCHEMA dboData');   -- alone in its batch, hence EXEC
GO
IF SCHEMA_ID (N'history') IS NULL EXEC (N'CREATE SCHEMA history');
GO

-- Guarded so a clean second run reports nothing.
IF EXISTS (SELECT 1
             FROM sys.schemas            AS s
             JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
            WHERE s.name IN (N'dbo', N'dboData', N'history')
              AND p.name <> N'dbo')
BEGIN
    ALTER AUTHORIZATION ON SCHEMA::dboData TO dbo;
    ALTER AUTHORIZATION ON SCHEMA::history TO dbo;
    PRINT N'Schema ownership aligned to dbo.';
END;
GO

-- -------------------------------------------------------------------------------------------
-- 2. The base table. Guarded, so a second run is a no-op.
-- -------------------------------------------------------------------------------------------
IF OBJECT_ID (N'dboData.Permit', N'U') IS NULL
BEGIN
    CREATE TABLE dboData.Permit
    (
        -- ---------------------------------------------------------------------------------
        -- Key and payload
        -- ---------------------------------------------------------------------------------
        PermitId             INT             IDENTITY (1, 1) NOT NULL,
        PermitType           VARCHAR (20)    NOT NULL,
        PermitSubtype        VARCHAR (20)    NULL,
        PermitName           NVARCHAR (255)  NULL,

        -- ---------------------------------------------------------------------------------
        -- Standard audit block, extended form. Soft delete only; there is no hard delete.
        -- Convention: DF_<schema>_<tableName>_<fieldName>, carrying the BASE table's schema.
        -- The audit*By columns are NVARCHAR (255): DEFAULT (ORIGINAL_LOGIN ()) returns sysname
        -- (NVARCHAR(128)), so anything narrower makes the default itself raise a truncation
        -- error, and 255 leaves room for a caller-supplied value from a migration.
        --
        -- The defaults matter less here than on a plain table: the INSTEAD OF triggers set every
        -- one of these explicitly. They stay because a write that bypasses the view -- a
        -- migration, a repair script -- still has to land audited.
        -- ---------------------------------------------------------------------------------
        IsDeleted            BIT             NOT NULL CONSTRAINT DF_dboData_Permit_IsDeleted            DEFAULT (0),
        auditDeletedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dboData_Permit_auditDeletedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditDeletedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dboData_Permit_auditDeletedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditCreatedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dboData_Permit_auditCreatedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditCreatedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dboData_Permit_auditCreatedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditModifiedBy      NVARCHAR (255)  NOT NULL CONSTRAINT DF_dboData_Permit_auditModifiedBy      DEFAULT (ORIGINAL_LOGIN ()),
        auditModifiedDateUtc DATETIME2 (3)   NOT NULL CONSTRAINT DF_dboData_Permit_auditModifiedDateUtc DEFAULT (SYSUTCDATETIME ()),
        -- Every session-function default on a NOT NULL column is wrapped in ISNULL. APP_NAME() and
        -- HOST_NAME() both return NULL for some connections, and a NULL arriving at a NOT NULL
        -- column fails the insert on a column the caller never named. DbApplication was the one
        -- that was not wrapped, in this file and in the change-logging tables both.
        DbApplication        NVARCHAR (255)  NOT NULL CONSTRAINT DF_dboData_Permit_DbApplication        DEFAULT (ISNULL (APP_NAME (), N'')),
        HostName             NVARCHAR (255)  NOT NULL CONSTRAINT DF_dboData_Permit_HostName             DEFAULT (ISNULL (HOST_NAME (), N'')),

        -- Session auditing. For a deep-dive investigation, query the history table for every
        -- session that touched the row; for everything else the latest values are enough.
        AppSessionId         NVARCHAR (128)  NULL,
        SqlSpid              SMALLINT        NOT NULL CONSTRAINT DF_dboData_Permit_SqlSpid              DEFAULT (@@SPID),

        -- System time is always UTC. HIDDEN keeps these out of SELECT *, so a consumer written
        -- against a non-temporal version of this table is unaffected; name them explicitly, or
        -- query history.Permit, to see them.
        SysStartTime         DATETIME2 (3)   GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
        SysEndTime           DATETIME2 (3)   GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime),

        CONSTRAINT PK_dboData_Permit PRIMARY KEY CLUSTERED (PermitId)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.Permit, DATA_CONSISTENCY_CHECK = ON));

    PRINT N'Created dboData.Permit (system-versioned, history.Permit).';
END;
GO

-- -------------------------------------------------------------------------------------------
-- 3. Converting a table that ALREADY EXISTS and already has rows.
--
--    Delete this section for a genuinely new table. Keep it when turning RowHistory on for a
--    table that was created without it: each block is separately guarded, so on a fresh database
--    every one is a no-op, and on a populated one nothing is dropped and no row is rewritten.
--    Do not fold these back into section 2 -- a populated database never runs section 2.
-- -------------------------------------------------------------------------------------------

-- 3a. Move it out of the consumer schema, so the view can take the name. TRANSFER keeps the data
--     and the indexes; it DISCARDS the object's permissions, which section 7 re-applies. It is
--     also impossible once the table is temporal, so it has to happen first.
IF OBJECT_ID (N'dbo.Permit', N'U') IS NOT NULL
BEGIN
    ALTER SCHEMA dboData TRANSFER dbo.Permit;
    PRINT N'Transferred dbo.Permit to dboData.';
END;
GO

-- 3b. The extended audit columns. NOT NULL with a default is fine on a populated table -- the
--     default back-fills.
--
--     EACH COLUMN IS GUARDED ON ITS OWN NAME. The tempting shortcut is one guard for the whole
--     block, on the reasoning that a table either has the extended block or it does not. That
--     holds only if the ALTER is atomic with everything after it, and it is not: every GO commits
--     its own batch. A failure anywhere downstream -- a lock timeout, a permission, the period
--     add in 3c -- then leaves a table that HAS DbApplication and is missing the rest, and every
--     later run skips the block because DbApplication is present. The table can no longer be
--     brought forward by the script whose entire job is to bring it forward. Per-column guards
--     are what make "additive" actually converge, and they cost four lines.
IF COL_LENGTH (N'dboData.Permit', N'DbApplication') IS NULL
    ALTER TABLE dboData.Permit ADD DbApplication NVARCHAR (255) NOT NULL
        CONSTRAINT DF_dboData_Permit_DbApplication DEFAULT (ISNULL (APP_NAME (), N''));

IF COL_LENGTH (N'dboData.Permit', N'HostName') IS NULL
    ALTER TABLE dboData.Permit ADD HostName NVARCHAR (255) NOT NULL
        CONSTRAINT DF_dboData_Permit_HostName DEFAULT (ISNULL (HOST_NAME (), N''));

IF COL_LENGTH (N'dboData.Permit', N'AppSessionId') IS NULL
    ALTER TABLE dboData.Permit ADD AppSessionId NVARCHAR (128) NULL;

IF COL_LENGTH (N'dboData.Permit', N'SqlSpid') IS NULL
    ALTER TABLE dboData.Permit ADD SqlSpid SMALLINT NOT NULL
        CONSTRAINT DF_dboData_Permit_SqlSpid DEFAULT (@@SPID);
GO

-- 3c. The period columns. Both need a default because they are NOT NULL on existing rows: start at
--     the floor, end at the maximum the type holds, which is what "current row" means to the engine.
IF NOT EXISTS (SELECT 1 FROM sys.periods WHERE object_id = OBJECT_ID (N'dboData.Permit'))
BEGIN
    ALTER TABLE dboData.Permit ADD
        SysStartTime DATETIME2 (3) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
            CONSTRAINT DF_dboData_Permit_SysStartTime DEFAULT ('1900-01-01 00:00:00.000'),
        SysEndTime   DATETIME2 (3) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL
            CONSTRAINT DF_dboData_Permit_SysEndTime   DEFAULT ('9999-12-31 23:59:59.999'),
        PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime);
    PRINT N'Added the system-time period to dboData.Permit.';
END;
GO

-- 3d. Switch versioning on. temporal_type: 0 = not temporal, 2 = system-versioned.
IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID (N'dboData.Permit') AND temporal_type <> 2)
BEGIN
    ALTER TABLE dboData.Permit
        SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = history.Permit, DATA_CONSISTENCY_CHECK = ON));
    PRINT N'System versioning enabled on dboData.Permit.';
END;
GO

-- -------------------------------------------------------------------------------------------
-- 4. Indexes. On the BASE table -- an index on a view is a different object with different rules.
--    Natural keys stay filtered on IsDeleted = 0: a soft-deleted row still occupies its key.
-- -------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'UX_dboData_Permit_Natural'
                  AND object_id = OBJECT_ID (N'dboData.Permit'))
BEGIN
    CREATE UNIQUE INDEX UX_dboData_Permit_Natural
        ON dboData.Permit (PermitType, PermitSubtype)
        WHERE IsDeleted = 0;
END;
GO

-- -------------------------------------------------------------------------------------------
-- 5. The view. Explicit column list, never SELECT * -- a column added to the base table must be
--    added here deliberately, and the period columns are not projected at all (HIDDEN already
--    keeps them out of SELECT *, but say it in the list so nobody has to check).
--
--    Not SCHEMABINDING: it would block the additive ALTER TABLE in section 3 on the next change.
-- -------------------------------------------------------------------------------------------
/***********************************************************************************************************************
ObjectName:   dbo.Permit
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Active permit records. The read and write path for this table: the INSTEAD OF triggers on this view own the audit
columns and turn DELETE into a soft delete. The base table dboData.Permit is system-versioned, and a temporal table
cannot carry an INSTEAD OF trigger, which is why this view exists and why it holds the name callers use.

========================================================================================================================
Requirements and Key Dependencies:

dboData.Permit. Ownership chaining from dbo through dboData -- both schemas owned by dbo.

========================================================================================================================
Notes:

Soft delete is enforced here. A query against dboData.Permit directly sees deleted rows.

For history: select * from dboData.Permit for system_time as of '<utc datetime>' where PermitId = <id>;
or read history.Permit. Both need SELECT on dboData/history, which applicationRole does not have.

========================================================================================================================
Example Usage and Performance:

select * from dbo.Permit where PermitType = 'STD';

Supported by UX_dboData_Permit_Natural (filtered on IsDeleted = 0).

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW dbo.Permit
AS
SELECT
      p.PermitId
    , p.PermitType
    , p.PermitSubtype
    , p.PermitName
    , p.IsDeleted
    , p.auditDeletedBy
    , p.auditDeletedDateUtc
    , p.auditCreatedBy
    , p.auditCreatedDateUtc
    , p.auditModifiedBy
    , p.auditModifiedDateUtc
    , p.DbApplication
    , p.HostName
    , p.AppSessionId
    , p.SqlSpid
FROM dboData.Permit AS p
WHERE p.IsDeleted = 0;
GO

/*
    6. The INSTEAD OF triggers, and the audit contract they implement.

    ON INSERT, the caller may supply auditCreatedBy, auditCreatedDateUtc, auditModifiedBy,
    auditModifiedDateUtc, auditDeletedBy, auditDeletedDateUtc and DbApplication; each defaults only
    when NULL or empty. That means the audit trail is NOT tamper-proof against anyone holding INSERT
    on this view, and it is still the right call: a migration has to carry the original values
    across. Overwriting them strips the data of its history, ruins reporting built on it, and in a
    regulated context is itself the violation.

    ON UPDATE, only auditModifiedBy is caller-overridable. Everything else is recomputed, and
    auditCreatedBy / auditCreatedDateUtc are never rewritten. UPDATE(col) is what distinguishes
    "the caller named this column" from "this is the existing value arriving through the view".

    HostName is never caller-overridable, on INSERT or UPDATE. It is the one identity column a
    caller cannot supply.

    ON DELETE, the row is soft-deleted. Nothing is removed.

    Copy these bodies; do not paraphrase them. Each one: SET NOCOUNT ON, return early on an empty
    inserted/deleted, then SET NOCOUNT OFF before the primary DML so the affected-row count an ORM
    reads to decide whether its write landed is the real one (otherwise EF Core raises
    DbUpdateConcurrencyException). EF Core also has to be told the table has triggers.
*/

/***********************************************************************************************************************
ObjectName:   dbo.trg_ioi_ins_Permit
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Writes an insert against dbo.Permit through to dboData.Permit, resolving the audit columns and keeping any audit value
the caller supplied.

========================================================================================================================
Requirements and Key Dependencies:

dboData.Permit. Optional #ReturnedIdentity (InsertedId int) in the caller's session.

========================================================================================================================
Notes:

SCOPE_IDENTITY() in the CALLER's scope returns NULL after an insert through an INSTEAD OF trigger, because the insert
happened in the trigger's scope. Create #ReturnedIdentity (InsertedId int) before the insert to get the keys back --
all of them, not just the last.

Each resolved value is computed once in the CROSS APPLY, so a column and any legacy twin of it cannot disagree, and
SYSUTCDATETIME() is not evaluated twice in one row.

========================================================================================================================
Example Usage and Performance:

insert dbo.Permit (PermitType, auditCreatedBy, auditCreatedDateUtc)
values ('STD', N'DOMAIN\olduser', '2019-04-01T08:00:00');    -- migration: original values kept

Set-based; one INSERT per statement regardless of row count.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_ioi_ins_Permit
ON dbo.Permit
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    SET NOCOUNT OFF;

    IF OBJECT_ID (N'tempdb..#ReturnedIdentity') IS NOT NULL
    BEGIN
        INSERT INTO dboData.Permit
            (PermitType, PermitSubtype, PermitName,
             IsDeleted, auditDeletedBy, auditDeletedDateUtc, auditCreatedBy, auditCreatedDateUtc,
             auditModifiedBy, auditModifiedDateUtc, DbApplication, HostName, AppSessionId, SqlSpid)
        OUTPUT inserted.PermitId INTO #ReturnedIdentity (InsertedId)      -- captures ALL rows
        SELECT i.PermitType, i.PermitSubtype, i.PermitName,
               ISNULL (i.IsDeleted, 0), r.DeletedBy, r.DeletedDateUtc, r.CreatedBy, r.CreatedDateUtc,
               r.ModifiedBy, r.ModifiedDateUtc, r.DbApplication,
               ISNULL (HOST_NAME (), N''),                                -- never caller-overridable
               CAST (SESSION_CONTEXT (N'AppSessionId') AS NVARCHAR (128)),
               @@SPID
          FROM inserted AS i
         CROSS APPLY (VALUES (
               COALESCE (NULLIF (i.auditCreatedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditCreatedDateUtc, SYSUTCDATETIME ())
             , COALESCE (NULLIF (i.auditModifiedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditModifiedDateUtc, SYSUTCDATETIME ())
             , COALESCE (NULLIF (i.auditDeletedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditDeletedDateUtc, SYSUTCDATETIME ())
             , ISNULL (NULLIF (i.DbApplication,     N''), ISNULL (APP_NAME (), N''))
         )) AS r (CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc, DeletedBy, DeletedDateUtc, DbApplication);
    END;
    ELSE
    BEGIN
        INSERT INTO dboData.Permit
            (PermitType, PermitSubtype, PermitName,
             IsDeleted, auditDeletedBy, auditDeletedDateUtc, auditCreatedBy, auditCreatedDateUtc,
             auditModifiedBy, auditModifiedDateUtc, DbApplication, HostName, AppSessionId, SqlSpid)
        SELECT i.PermitType, i.PermitSubtype, i.PermitName,
               ISNULL (i.IsDeleted, 0), r.DeletedBy, r.DeletedDateUtc, r.CreatedBy, r.CreatedDateUtc,
               r.ModifiedBy, r.ModifiedDateUtc, r.DbApplication,
               ISNULL (HOST_NAME (), N''),
               CAST (SESSION_CONTEXT (N'AppSessionId') AS NVARCHAR (128)),
               @@SPID
          FROM inserted AS i
         CROSS APPLY (VALUES (
               COALESCE (NULLIF (i.auditCreatedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditCreatedDateUtc, SYSUTCDATETIME ())
             , COALESCE (NULLIF (i.auditModifiedBy, N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditModifiedDateUtc, SYSUTCDATETIME ())
             , COALESCE (NULLIF (i.auditDeletedBy,  N''), NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ())
             , ISNULL (i.auditDeletedDateUtc, SYSUTCDATETIME ())
             , ISNULL (NULLIF (i.DbApplication,     N''), ISNULL (APP_NAME (), N''))
         )) AS r (CreatedBy, CreatedDateUtc, ModifiedBy, ModifiedDateUtc, DeletedBy, DeletedDateUtc, DbApplication);
    END;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.trg_iov_updt_Permit
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Writes an update against dbo.Permit through to dboData.Permit. The audit columns are owned here: only auditModifiedBy
accepts a caller value, and auditCreatedBy / auditCreatedDateUtc are never rewritten.

========================================================================================================================
Requirements and Key Dependencies:

dboData.Permit.

========================================================================================================================
Notes:

UPDATE(auditModifiedBy) is the whole mechanism for "the caller named this column": every row arriving through the view
carries a value for it either way, so without UPDATE() an unchanged existing value is indistinguishable from a
deliberate one.

PermitId cannot be changed through this view. An INSTEAD OF UPDATE trigger joins deleted to inserted on the key, so a
statement that changed it would match nothing and SILENTLY do nothing -- hence the explicit rejection. It is a THROW
carrying error 50010, not a RAISERROR: RAISERROR reports the rejection and then lets the batch continue to the next
statement, which is the same silence one statement later.

========================================================================================================================
Example Usage and Performance:

update dbo.Permit set PermitName = N'Standard' where PermitId = 1;

Set-based; one UPDATE per statement regardless of row count.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_iov_updt_Permit
ON dbo.Permit
INSTEAD OF UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF UPDATE (PermitId)
    BEGIN
        -- THROW, not RAISERROR + RETURN. RETURN ends the trigger and nothing else: the statement is
        -- silently not applied and the caller's batch runs on to the next statement believing it was.
        -- THROW terminates the batch. 50010 is this skill's "immutable key rejected" number, chosen so a
        -- client can branch on it the way it branches on 1205 or 2627 -- which is the same reason rule 8
        -- requires a bare ;THROW; in a CATCH rather than a RAISERROR that flattens everything to 50000.
        ;THROW 50010, N'PermitId is immutable through dbo.Permit. Soft-delete the row and insert a new one.', 1;
    END;

    SET NOCOUNT OFF;

    -- One value per fact, hoisted, then used everywhere below. Two reasons. It is one statement, so
    -- a soft delete arriving here stamps auditDeletedDateUtc and auditModifiedDateUtc with the SAME
    -- instant instead of two SYSUTCDATETIME() calls that can straddle a millisecond. And if this
    -- table ever gains a legacy twin column -- the pattern scripts\logdBChanges.sql carries for
    -- RecordedUtc/auditCreatedDateUtc and UpdatedUtc/auditModifiedDateUtc -- a twin written from a
    -- second call is a pair that can disagree, and a re-runnable back-fill guarded on the pair
    -- being equal then re-fires on every deployment.
    DECLARE @Now     DATETIME2 (3)  = SYSUTCDATETIME (),
            @Actor   NVARCHAR (255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ()),
            @AppName NVARCHAR (255) = ISNULL (APP_NAME (), N'');

    UPDATE t
       SET t.PermitType    = i.PermitType,
           t.PermitSubtype = i.PermitSubtype,
           t.PermitName    = i.PermitName,
           t.IsDeleted     = i.IsDeleted,

           -- An UPDATE that sets IsDeleted = 1 is a soft delete arriving by the OTHER route, and it
           -- must answer "who" exactly as the DELETE trigger does. There are two routes -- the
           -- DELETE statement and an ORM or a hand-written UPDATE writing the flag directly -- and
           -- for a long time only the first one stamped these columns. That is worse than an
           -- omission: auditDeletedBy and auditDeletedDateUtc keep their INSERT-time defaults, so
           -- the row does not go quiet about who deleted it, it asserts that whoever created the
           -- row deleted it, at the moment they created it.
           --
           -- The view filters IsDeleted = 0, so every row reaching this trigger was live and
           -- setting the flag to 1 here is always a genuine 0 -> 1 transition. No before-image test
           -- is needed, and the ELSE branches preserve the existing values for every other UPDATE.
           t.auditDeletedBy      = CASE WHEN i.IsDeleted = 1 THEN @Actor ELSE t.auditDeletedBy      END,
           t.auditDeletedDateUtc = CASE WHEN i.IsDeleted = 1 THEN @Now   ELSE t.auditDeletedDateUtc END,

           -- Caller-overridable on UPDATE, and the only one that is.
           t.auditModifiedBy = CASE WHEN UPDATE (auditModifiedBy)
                                    THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                    ELSE @Actor
                               END,

           -- Recomputed every time, whatever the caller passed. The DEFAULT on the column fires on
           -- INSERT only, so an UPDATE that does not set these leaves them stale.
           t.auditModifiedDateUtc = @Now,
           t.DbApplication        = @AppName,
           t.HostName             = ISNULL (HOST_NAME (), N''),
           t.AppSessionId         = CAST (SESSION_CONTEXT (N'AppSessionId') AS NVARCHAR (128)),
           t.SqlSpid              = @@SPID
      FROM dboData.Permit AS t
      JOIN deleted        AS d ON t.PermitId = d.PermitId
      JOIN inserted       AS i ON i.PermitId = d.PermitId;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.trg_iod_del_Permit
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Turns a DELETE against dbo.Permit into a logical soft delete on dboData.Permit. Nothing is removed.

========================================================================================================================
Requirements and Key Dependencies:

dboData.Permit.

========================================================================================================================
Notes:

Without this trigger a DELETE against the view fails outright, which is the safe failure but not a usable one -- an ORM
issuing a delete would break. WHERE t.IsDeleted = 0 makes a repeated delete converge instead of moving the audit
timestamps every time.

========================================================================================================================
Example Usage and Performance:

delete from dbo.Permit where PermitId = 1;   -- sets IsDeleted = 1; the row stays

Set-based; one UPDATE per statement regardless of row count.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_iod_del_Permit
ON dbo.Permit
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    SET NOCOUNT OFF;

    -- Hoisted for the same reason as in the UPDATE trigger: one delete is one event, so the deleted
    -- and modified stamps are the same instant rather than two SYSUTCDATETIME() calls a millisecond
    -- boundary can separate.
    DECLARE @Now   DATETIME2 (3)  = SYSUTCDATETIME (),
            @Actor NVARCHAR (255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ());

    UPDATE t
       SET t.IsDeleted           = 1,
           t.auditDeletedBy      = @Actor,
           t.auditDeletedDateUtc = @Now,
           t.auditModifiedBy     = @Actor,
           t.auditModifiedDateUtc = @Now,
           t.DbApplication       = ISNULL (APP_NAME (), N''),
           t.HostName            = ISNULL (HOST_NAME (), N''),
           t.AppSessionId        = CAST (SESSION_CONTEXT (N'AppSessionId') AS NVARCHAR (128)),
           t.SqlSpid             = @@SPID
      FROM dboData.Permit AS t
      JOIN deleted        AS d ON t.PermitId = d.PermitId
     WHERE t.IsDeleted = 0;
END;
GO

-- -------------------------------------------------------------------------------------------
-- 7. Permissions. On the VIEW, not the base table -- ownership chaining does the rest.
--    Section 3a's TRANSFER discards the object's permissions, so this has to run every time.
--    GRANT and DENY are both idempotent, so it is unguarded and silent on a re-run.
-- -------------------------------------------------------------------------------------------
IF DATABASE_PRINCIPAL_ID (N'applicationRole') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Permit TO applicationRole;
    -- The DENY is not what makes the view work; it is what stops a direct SELECT against the base
    -- table, which would bypass the IsDeleted filter.
    DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dboData TO applicationRole;
    DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::history TO applicationRole;
END;
GO

-- NOTHING HERE FOR readOnlyRole, AND THAT IS A CORRECTION RATHER THAN AN OMISSION.
--
-- This block used to read:
--
--     GRANT SELECT ON SCHEMA::dboData TO readOnlyRole;
--     GRANT SELECT ON SCHEMA::history TO readOnlyRole;
--
-- described as "read-only access to the base and history tables, for reporting or compliance queries
-- that need soft-deleted rows or FOR SYSTEM_TIME versions". It never worked. scripts/permissions.sql
-- issues DENY SELECT, INSERT, UPDATE, DELETE on dboData, logsData and history to BOTH roles, and its
-- own comment gives the reason: a reader has no business in the base tables either, because the view
-- is what applies the soft-delete filter and reading round it returns deleted rows.
--
-- Two files in one skill stated opposite intentions, and DENY wins over GRANT regardless of scope or
-- order -- so the reader's access was gone whichever ran last. Measured, not deduced: after both files
-- ran, sys.database_permissions held exactly one SELECT row for readOnlyRole on dboData and its
-- state_desc was DENY. The GRANT had not been overridden at query time, it had been overwritten in the
-- catalog, so nothing anywhere reported a conflict. permissions.sql is also the file documented to be
-- re-run whenever a schema it listed as ABSENT appears -- which is precisely after a temporal table is
-- deployed -- so it was always going to have the last word.
--
-- The single place that decides who may read a data schema is scripts/permissions.sql. If a compliance
-- reader genuinely needs the base or history tables, change it THERE, once, rather than per table here.
-- The narrower answer, and usually the right one, is a view in dbo that exposes exactly the historical
-- slice they need: it goes through ownership chaining, so it needs no grant on dboData at all.
--
-- applicationRole's DENY above is not redundant with permissions.sql for the same reason in reverse: it is the
-- same intent stated twice, and a DENY applied twice is still a DENY. This block was the only place
-- where the two files CONFLICTED.
GO

-- Do NOT add DENY ... ON SCHEMA::dboData TO public as "inheritance cleanup". Every user is a member
-- of public and membership cannot be revoked, so that DENY also reaches the principals that have to
-- write -- and whether a schema-scoped DENY beats an object-scoped GRANT is not something to bet a
-- write path on. public holds nothing on a new schema anyway. To clear one already applied:
--     REVOKE SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dboData FROM public;   -- REVOKE clears a DENY too

-- -------------------------------------------------------------------------------------------
-- 8. Extended properties. Required on the base table, on EVERY column of it, on the view, AND on
--    all three triggers -- rule 5 covers modules, and a trigger is a module. The triggers are the
--    easiest ones to forget, because nothing in the deployment fails without them: they are simply
--    absent from every data dictionary the descriptions feed, which is exactly the outcome rule 5
--    exists to prevent. Run the audit report at the bottom of templates/extended-properties.sql
--    before calling a script done; it reports triggers, so it catches this.
--    Always through util.uspSetObjectDescription -- it adds or updates, so the script re-runs
--    cleanly. Descriptions go on the BASE table: that is where the columns live.
--    The audit block wording is identical on every table; copy it from
--    scripts/logdBChanges.sql section 14, which words all thirteen columns once.
-- -------------------------------------------------------------------------------------------
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dboData'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'Permit'
    , @Description = N'Permit records, one row per permit. System-versioned into history.Permit, so every version this row has held is recoverable with FOR SYSTEM_TIME. Read and write through dbo.Permit.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dboData'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'Permit'
    , @ColumnName  = N'PermitId'
    , @Description = N'Surrogate key. Immutable through dbo.Permit.';
GO

-- ... continue for every column, including the audit block and the two period columns ...

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'Permit'
    , @Description = N'Active permit records, over dboData.Permit with the soft-delete filter applied. The read and write path: its INSTEAD OF triggers own the audit columns and turn DELETE into a soft delete.';
GO

-- The history table, which SQL Server created implicitly in section 2 and which therefore has no
-- CREATE of its own anywhere in this file to hang a description off. It is an ordinary table and
-- takes the property normally; describe it here, or the audit report at the bottom of
-- templates/extended-properties.sql names it on every run. Its columns mirror the base table's and
-- do not need describing again.
EXEC util.uspSetObjectDescription
      @SchemaName  = N'history'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'Permit'
    , @Description = N'System-versioned history for dboData.Permit, written by SQL Server and never by an application. One row per superseded version, bounded by SysStartTime and SysEndTime. Query it through FOR SYSTEM_TIME on dboData.Permit rather than directly. While versioning is on, SQL Server itself refuses INSERT, UPDATE and DELETE here.';
GO

-- The three triggers. @SchemaName is the TRIGGER's schema, which is the VIEW's schema -- a DML
-- trigger takes its schema from its parent rather than carrying one of its own, which is also why
-- util.uspSetObjectDescription has to resolve the parent to address the property at all. Do not
-- write dboData here: these triggers sit on dbo.Permit, not on the base table.
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_ioi_ins_Permit'
    , @Description = N'Turns an INSERT against dbo.Permit into an insert on dboData.Permit, resolving the audit columns from the session where the caller left them NULL or empty. Returns the new keys through #ReturnedIdentity when the caller has created it, because SCOPE_IDENTITY() is NULL after an insert through an INSTEAD OF trigger.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_iov_updt_Permit'
    , @Description = N'Applies an UPDATE against dbo.Permit to dboData.Permit, stamping auditModifiedBy and auditModifiedDateUtc from the session and refusing them from the caller. Rejects a change to the surrogate key or the natural key with error 50010: an identity is not editable through the view.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_iod_del_Permit'
    , @Description = N'Turns a DELETE against dbo.Permit into a soft delete: IsDeleted goes to 1, auditDeletedBy and auditDeletedDateUtc are stamped from the session, and the row leaves the view. No row is ever removed from dboData.Permit, and the version that was current before the delete stays readable in history.Permit.';
GO
