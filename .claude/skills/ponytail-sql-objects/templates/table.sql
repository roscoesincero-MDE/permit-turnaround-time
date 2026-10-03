/*
    Table template.

    The worked example mirrors an external registry — schema dbo, table FacilitySource, the source
    system's column names. That is illustration, not scope: nothing here is specific to that
    example, and the same shape applies to any table in any database this skill is installed in.
    What IS mandatory is the audit block, the soft delete, the DF_ naming and the descriptions.

    Replace every <placeholder>, and replace the example names too. The DF_ constraint names MUST
    carry this table's real schema and table name: default constraint names are unique per
    database, so copying them from another table fails at deploy time.

    RE-RUNNABLE BY DESIGN. A developer runs these scripts by hand, so every script must
    be safe to run twice, or ten times. That shapes the whole file:

      - guard the CREATE TABLE with an OBJECT_ID check;
      - add later columns, constraints and indexes ADDITIVELY, each behind its own check;
      - set descriptions through util.uspSetObjectDescription, which adds or updates
        (sp_addextendedproperty FAILS on the second run — "Property already exists");
      - NEVER "DROP IF EXISTS ... CREATE". That is the usual way to make a script re-runnable
        and it is forbidden here: it is a hard delete of real data, and this database has no
        hard deletes anywhere.

    A correct second run changes nothing and reports nothing. If re-running a script would
    UPDATE data, it would also move auditModifiedDateUtc for no reason — converge, do not
    re-apply.

    Example below uses schema "dbo", table "FacilitySource".
*/

SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER, which is not optional here. sqlcmd defaults it OFF where every other client
-- defaults it ON, the setting is BAKED IN at CREATE time, and a module carrying it OFF cannot run DML
-- against a table with a filtered index (error 1934). Every unique constraint in this database is one,
-- via the soft-delete rule -- so that is every table. Set it here so a hand run without sqlcmd -I cannot
-- get it wrong; validate-sql.py rejects a script that CREATEs an object without it.
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------
-- 1. The table. Guarded, so a second run is a no-op.
-- -------------------------------------------------------------------------------------------
IF OBJECT_ID (N'dbo.FacilitySource', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FacilitySource
    (
        -- ---------------------------------------------------------------------------------
        -- Business key / natural key
        -- ---------------------------------------------------------------------------------
        FacilitySourceId      INT             IDENTITY (1, 1) NOT NULL,
        FacilityId            VARCHAR (12)    NOT NULL,
        ActivityLocation     CHAR (2)        NOT NULL,
        SourceType           VARCHAR (2)     NOT NULL,
        Sequence             INT             NOT NULL,

        -- ---------------------------------------------------------------------------------
        -- Payload columns
        -- ---------------------------------------------------------------------------------
        FacilityName          NVARCHAR (255)  NULL,
        CurrentRecord        BIT             NULL,

        -- The source system's own audit fields, prefixed Src so they are never confused with
        -- the local audit* columns below. These are the source's provenance, and mirrored data.
        SrcCreatedBy         NVARCHAR (100)  NULL,
        SrcCreatedDateUtc    DATETIME2 (3)   NULL,
        SrcUpdatedBy         NVARCHAR (100)  NULL,
        SrcUpdatedDateUtc    DATETIME2 (3)   NULL,

        -- Raw API payload. NVARCHAR(MAX) with an ISJSON check — the native json type is
        -- SQL Server 2025 only and this database targets 2022.
        RawJson              NVARCHAR (MAX)  NULL,

        -- ---------------------------------------------------------------------------------
        -- Standard audit columns for all tables. Soft delete only; there is no hard delete.
        -- Convention: DF_<schema>_<tableName>_<fieldName>
        --
        -- The three audit*By columns are NVARCHAR (255). Two separate things set that floor and
        -- they are different numbers, which is why "128 or wider" was the wrong way to state it:
        --   - DEFAULT (ORIGINAL_LOGIN ()) returns sysname, i.e. NVARCHAR (128), so anything
        --     under 128 makes the default itself raise a truncation error and fail the insert;
        --   - every INSTEAD OF trigger in this skill resolves the *By columns through
        --     CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), which cannot land in a
        --     128-wide column at all.
        -- 255 is the only width that satisfies both, so 255 is the rule everywhere — this file,
        -- table-temporal.sql, and the change-logging tables alike. Do not narrow it back.
        --
        -- The datetime columns are DATETIME2 (3) — milliseconds, written explicitly. Bare DATETIME2
        -- is DATETIME2 (7), which is a different type, a byte wider, and does not match the period
        -- columns a temporal conversion adds. See rule 1 in SKILL.md.
        -- ---------------------------------------------------------------------------------
        IsDeleted            BIT             NOT NULL CONSTRAINT DF_dbo_FacilitySource_IsDeleted            DEFAULT (0),
        auditDeletedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditDeletedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditDeletedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditDeletedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditCreatedBy       NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditCreatedBy       DEFAULT (ORIGINAL_LOGIN ()),
        auditCreatedDateUtc  DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditCreatedDateUtc  DEFAULT (SYSUTCDATETIME ()),
        auditModifiedBy      NVARCHAR (255)  NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditModifiedBy      DEFAULT (ORIGINAL_LOGIN ()),
        auditModifiedDateUtc DATETIME2 (3)   NOT NULL CONSTRAINT DF_dbo_FacilitySource_auditModifiedDateUtc DEFAULT (SYSUTCDATETIME ()),

        CONSTRAINT PK_dbo_FacilitySource         PRIMARY KEY CLUSTERED (FacilitySourceId),
        CONSTRAINT CK_dbo_FacilitySource_RawJson CHECK (RawJson IS NULL OR ISJSON (RawJson) = 1)
    );
END;
GO

-- -------------------------------------------------------------------------------------------
-- 2. Later changes are ADDITIVE and separately guarded. Do not edit section 1 to add a
--    column to a table that already exists somewhere — append a guarded block here instead,
--    so the script converges on both an empty database and a populated one.
--
--    The three blocks below work on RegionCode, which section 1 deliberately does NOT define.
--    That is the whole point of the illustration: on an empty database section 1 creates the
--    table without the column and section 2 adds it, on a populated one section 1 is skipped
--    and section 2 still adds it, and both arrive at the same shape. An earlier version of this
--    template illustrated the idiom with FacilityName, DF_dbo_FacilitySource_IsDeleted and
--    CK_dbo_FacilitySource_RawJson — all three of which section 1 already creates, so the blocks
--    were permanent no-ops that read as live code in a file people copy verbatim.
-- -------------------------------------------------------------------------------------------

-- New column. COL_LENGTH returns NULL when the column does not exist.
IF COL_LENGTH (N'dbo.FacilitySource', N'RegionCode') IS NULL
BEGIN
    ALTER TABLE dbo.FacilitySource ADD RegionCode CHAR (2) NULL;
END;
GO

-- New default constraint on a column that already exists. Named
-- DF_<schema>_<tableName>_<fieldName>, unique per database.
-- Note what this does and does not do: a default applies to rows inserted from now on. It does
-- not back-fill the rows already there — those keep the NULL they were created with. If they
-- need a value, that is a separate, separately guarded, converging UPDATE.
IF NOT EXISTS (SELECT 1
                 FROM sys.default_constraints
                WHERE name = N'DF_dbo_FacilitySource_RegionCode')
BEGIN
    ALTER TABLE dbo.FacilitySource
        ADD CONSTRAINT DF_dbo_FacilitySource_RegionCode DEFAULT ('03') FOR RegionCode;
END;
GO

-- New check constraint. ADD CONSTRAINT validates the rows already in the table unless
-- WITH NOCHECK is specified, so a constraint the existing data violates fails here rather than
-- silently admitting bad rows — which is what you want, and why NOCHECK is not used.
IF NOT EXISTS (SELECT 1
                 FROM sys.check_constraints
                WHERE name = N'CK_dbo_FacilitySource_RegionCode')
BEGIN
    ALTER TABLE dbo.FacilitySource
        ADD CONSTRAINT CK_dbo_FacilitySource_RegionCode
            CHECK (RegionCode IS NULL OR RegionCode LIKE '[0-1][0-9]');
END;
GO

-- -------------------------------------------------------------------------------------------
-- 3. Indexes. Natural key filtered so a soft-deleted row does not block re-creation of the
--    same key. Guarded rather than DROP_EXISTING, which requires the index to already exist.
-- -------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE name      = N'UX_dbo_FacilitySource_Natural'
                  AND object_id = OBJECT_ID (N'dbo.FacilitySource'))
BEGIN
    CREATE UNIQUE INDEX UX_dbo_FacilitySource_Natural
        ON dbo.FacilitySource (FacilityId, SourceType, Sequence)
        WHERE IsDeleted = 0;
END;
GO

-- -------------------------------------------------------------------------------------------
-- 4. The audit trigger. NOT OPTIONAL, and the reason it exists is worth reading before you
--    decide your table does not need one.
--
--    A plain table has no view in front of it, so nothing sits between the caller and the
--    columns. The seven audit columns carry DEFAULT constraints, and a DEFAULT fires on INSERT
--    ONLY -- so before this trigger existed, every UPDATE against a table built from this
--    template left the audit trail to the caller's good manners. Measured against a real login
--    holding exactly the permissions scripts/permissions.sql grants, all three of these
--    succeeded:
--
--      update dbo.FacilitySource set FacilityName = N'x' where ...;
--          -- auditModifiedBy and auditModifiedDateUtc LEFT STALE at their insert-time values.
--          -- The trail does not go quiet; it asserts nobody has touched the row since it was
--          -- created.
--
--      update dbo.FacilitySource set auditModifiedDateUtc = '1999-01-01' where ...;
--          -- accepted verbatim. A back-dated audit trail, written by hand.
--
--      update dbo.FacilitySource set IsDeleted = 1 where ...;
--          -- the row is soft-deleted and auditDeletedBy / auditDeletedDateUtc keep their
--          -- INSERT-time defaults, so the row claims whoever created it deleted it, at the
--          -- moment they created it. Same failure the temporal UPDATE trigger's own comment
--          -- calls out -- and on a plain table there was nothing to catch it.
--
--    The wrapped (temporal) shape had all three closed by its INSTEAD OF triggers. This trigger
--    is what makes the guarantee the same on both shapes, which is the point: which shape a
--    table happens to be should not change whether its audit trail can be trusted.
--
--    WHAT THIS DELIBERATELY DOES **NOT** CLOSE. auditModifiedBy remains caller-overridable, and
--    auditCreatedBy / auditCreatedDateUtc are untouched on INSERT. Both match the view exactly
--    rather than improving on it: templates/table-temporal.sql's INSTEAD OF UPDATE trigger
--    documents auditModifiedBy as "Caller-overridable on UPDATE, and the only one that is", and
--    its INSTEAD OF INSERT trigger keeps caller-supplied audit values on purpose so a migration
--    can carry the original values across. Locking either one down here would make the plain
--    shape STRICTER than the wrapped shape and break that migration path. Parity is the goal,
--    not maximum strictness.
--
--    AFTER, NOT INSTEAD OF. A plain table can carry an INSTEAD OF trigger -- only the
--    system-versioned base table in the wrapped shape cannot -- and it would save a write. It
--    is still the wrong choice: an INSTEAD OF UPDATE trigger has to name every payload column,
--    so section 2 adding a column means editing this trigger too, and forgetting silently makes
--    that column not updatable. AFTER costs one extra UPDATE touching four columns and cannot
--    be made stale by a schema change.
-- -------------------------------------------------------------------------------------------
/***********************************************************************************************************************
ObjectName:   dbo.trg_au_updt_FacilitySource
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Owns the modification and soft-delete audit columns on dbo.FacilitySource. Recomputes auditModifiedDateUtc on every
update, and stamps auditDeletedBy / auditDeletedDateUtc when IsDeleted transitions 0 -> 1. This is the plain-table
equivalent of what the INSTEAD OF triggers do for a table with a view wrapper.

========================================================================================================================
Requirements and Key Dependencies:

dbo.FacilitySource, and its PRIMARY KEY. No grant of its own: a trigger runs in the caller's security context against a
table the caller already holds UPDATE on, so scripts/permissions.sql covers it.

========================================================================================================================
Notes:

WHY THE 0 -> 1 TEST IS EXPLICIT HERE AND NOT IN THE VIEW'S TRIGGER. The temporal view filters IsDeleted = 0, so every
row reaching its INSTEAD OF UPDATE trigger was live and  i.IsDeleted = 1  is by itself proof of a genuine transition.
There is no filter in front of a plain table: an already-deleted row can be updated again, and testing only the
after-image would re-stamp auditDeletedBy and auditDeletedDateUtc on every later touch of a row deleted months ago,
quietly moving the delete forward in time. Hence  d.IsDeleted = 0 AND i.IsDeleted = 1.

AN UNDELETE LEAVES auditDeleted* ALONE, on purpose. Both columns are NOT NULL with defaults, so there is no empty state
to restore them to, and the column descriptions in section 5 already say they are meaningful only when IsDeleted = 1.
Clearing them on a 1 -> 0 transition would destroy the record of a delete that really happened; leaving them makes a
restored row's history readable.

UPDATE (auditModifiedBy) is what distinguishes "the caller named this column" from "the caller's UPDATE happened to
carry the value already in the row". Without it the two are indistinguishable and every update would look deliberate.

RECURSION. This trigger updates the table it is defined on. RECURSIVE_TRIGGERS is OFF by default, so it does not
re-fire -- but that is a DATABASE option someone else can turn on, and the failure if they do is an infinite loop
rather than a wrong value. The TRIGGER_NESTLEVEL guard makes the trigger correct on its own terms instead of correct
because of a setting it does not control.

JOINING ON THE PRIMARY KEY is sound here because FacilitySourceId is an IDENTITY column and SQL Server rejects an UPDATE
against one outright. A TABLE WHOSE KEY IS NOT IDENTITY NEEDS A GUARD: deleted holds the old key and inserted the new
one, so a statement that changed the key would join wrong. Add  IF UPDATE (<KeyColumn>) ;THROW 50010, N'...', 1;  above,
exactly as templates/table-temporal.sql's INSTEAD OF UPDATE trigger does.

SET NOCOUNT ON STAYS ON for the whole trigger, unlike the INSTEAD OF triggers which switch it OFF before their write.
There the inner statement IS the caller's work and its row count is the one the caller should see. Here the caller's own
UPDATE has already reported, so letting this one report too would show every update twice.

========================================================================================================================
Example Usage and Performance:

update dbo.FacilitySource set FacilityName = N'Acme' where FacilitySourceId = 1;   -- audit columns follow automatically

Set-based; one extra UPDATE per statement regardless of row count, touching four columns. That doubling is the price of
the guarantee -- a plain UPDATE against this table is now two writes. It is the reason the trigger returns early on an
UPDATE that matched no rows, which fires the trigger with an empty inserted table.

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER TRIGGER dbo.trg_au_updt_FacilitySource
ON dbo.FacilitySource
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- An UPDATE that matched nothing still fires the trigger, with inserted and deleted both empty.
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    -- See RECURSION in the notes. Guarding on this trigger's own depth rather than on the database
    -- option, so the trigger cannot be made to loop by a setting changed elsewhere.
    IF TRIGGER_NESTLEVEL (@@PROCID, 'AFTER', 'DML') > 1 RETURN;

    -- One value per fact, hoisted, for the same reason as in the temporal triggers: a soft delete
    -- arriving here must stamp auditDeletedDateUtc and auditModifiedDateUtc with the SAME instant,
    -- not two SYSUTCDATETIME () calls that a millisecond boundary can separate.
    DECLARE @Now   DATETIME2 (3)  = SYSUTCDATETIME (),
            @Actor NVARCHAR (255) = COALESCE (NULLIF (CAST (SESSION_CONTEXT (N'AppUser') AS NVARCHAR (255)), N''), ORIGINAL_LOGIN ());

    UPDATE t
       SET -- Recomputed every time, whatever the caller passed. This is the column the DEFAULT
           -- cannot maintain, and overwriting rather than defaulting is also what stops a
           -- hand-written back-date from surviving.
           t.auditModifiedDateUtc = @Now,

           -- Caller-overridable, and the only one that is -- matching the view. See the section 4
           -- comment above on why this is not locked down.
           t.auditModifiedBy = CASE WHEN UPDATE (auditModifiedBy)
                                    THEN COALESCE (NULLIF (i.auditModifiedBy, N''), @Actor)
                                    ELSE @Actor
                               END,

           -- The soft delete arriving as a bare UPDATE of the flag, which on a plain table is the
           -- ONLY way it can arrive: there is no view here, and DELETE is not granted on
           -- SCHEMA::dbo precisely because it would be a hard delete. So this branch is not an
           -- edge case, it is the main soft-delete path for this shape.
           t.auditDeletedBy      = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @Actor ELSE t.auditDeletedBy      END,
           t.auditDeletedDateUtc = CASE WHEN d.IsDeleted = 0 AND i.IsDeleted = 1 THEN @Now   ELSE t.auditDeletedDateUtc END
      FROM dbo.FacilitySource AS t
      JOIN inserted          AS i ON i.FacilitySourceId = t.FacilitySourceId
      JOIN deleted           AS d ON d.FacilitySourceId = t.FacilitySourceId;
END;
GO


/*
    5. Extended properties. Required on the table and on EVERY column.

    Always through util.uspSetObjectDescription — it adds or updates, so the script re-runs
    cleanly and an improved wording actually replaces the old one. A bare
    sp_addextendedproperty succeeds once and then fails every subsequent run.

    Write what the column means, not a restatement of its name. Where no authoritative
    description exists yet, say 'TODO: awaiting the source data dictionary' rather than inventing one.
*/

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @Description = N'Facility source records mirrored from the external source registry. One row per (FacilityId, SourceType, Sequence) version of a facility''s submitted source record.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'FacilitySourceId'
    , @Description = N'Surrogate key. No business meaning; the source system''s natural key is (FacilityId, SourceType, Sequence).';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'FacilityId'
    , @Description = N'Source-assigned facility identifier, e.g. ''MD0000123456''. Unique per facility within an activity location.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'ActivityLocation'
    , @Description = N'Two-character state or region code identifying where the facility activity took place. Scope is ''MD''; this column is not constrained to it, but out-of-state values are unexpected here. Contact and mailing addresses may legitimately be out of state — those live on the contact tables, not this column.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'SourceType'
    , @Description = N'Source record type, e.g. ''N'' (notification), ''I''. TODO: awaiting the source data dictionary for the full code list.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'Sequence'
    , @Description = N'Sequence number distinguishing multiple source records of the same type for one facility. Ordering is assigned by the source system.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'RegionCode'
    , @Description = N'Region the facility falls under, as two digits, e.g. ''03'' for the mid-Atlantic region that covers MD. Added after the table was first deployed — see section 2 — and NULL on rows that predate it; the default applies to new rows only.';
GO

-- ... continue for FacilityName, CurrentRecord, Src* columns, RawJson ...
--
-- A column added in section 2 needs a description exactly as much as one created in section 1:
-- rule 4 is "the table and every column", and a column that arrived later is the one most likely
-- to be missed. templates/extended-properties.sql ends with a report that finds them.

/*
    Audit column descriptions. These are identical on every table; copy this block verbatim
    and change only @ObjectName.
*/

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'IsDeleted'
    , @Description = N'Soft-delete flag. 1 = deleted, 0 = active. This database performs no hard deletes; all reads must filter IsDeleted = 0.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditDeletedBy'
    , @Description = N'Login that soft-deleted the row. Stamped by trg_au_updt_FacilitySource when IsDeleted transitions 0 -> 1. Meaningful only when IsDeleted = 1; on a live row it holds whatever the insert defaulted, and an undelete deliberately leaves the old value in place.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditDeletedDateUtc'
    , @Description = N'UTC timestamp of the soft delete. Stamped by trg_au_updt_FacilitySource on an IsDeleted 0 -> 1 transition, with the same instant as auditModifiedDateUtc. Meaningful only when IsDeleted = 1.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditCreatedBy'
    , @Description = N'Login that inserted the row. Under the application logins this identifies which application wrote it, not an end user.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditCreatedDateUtc'
    , @Description = N'UTC timestamp of row insert.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditModifiedBy'
    , @Description = N'Login that last modified the row. Maintained by trg_au_updt_FacilitySource, but caller-overridable: a statement that names this column explicitly keeps the value it supplied. That matches the view wrapper on a temporal table, where it is also the only audit column a caller may set on UPDATE.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TABLE'
    , @ObjectName  = N'FacilitySource'
    , @ColumnName  = N'auditModifiedDateUtc'
    , @Description = N'UTC timestamp of last modification. The DEFAULT fires on INSERT only, so trg_au_updt_FacilitySource recomputes this column on every UPDATE. A value supplied by the caller is overwritten, deliberately -- this is the one audit column that cannot be back-dated by hand.';
GO


-- Rule 5 covers the trigger too. It is an object in this schema and it is the one object here whose
-- absence changes what the data means rather than only what a script does, so a data dictionary that
-- omits it is missing the reason the audit columns can be trusted.
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'TRIGGER'
    , @ObjectName  = N'trg_au_updt_FacilitySource'
    , @Description = N'Owns the modification and soft-delete audit columns on dbo.FacilitySource. Recomputes auditModifiedDateUtc on every update and stamps auditDeletedBy / auditDeletedDateUtc on an IsDeleted 0 -> 1 transition. The plain-table equivalent of the INSTEAD OF triggers on a wrapped table; without it, a DEFAULT fires on INSERT only and every UPDATE leaves the audit trail to the caller.';
GO


-- -------------------------------------------------------------------------------------------
-- 6. Permissions. THERE IS DELIBERATELY NO GRANT BLOCK IN THIS FILE.
--
-- A plain table needs no grant of its own: scripts/permissions.sql grants SELECT, INSERT and
-- UPDATE on SCHEMA::dbo to applicationRole and SELECT to readOnlyRole, once per database, and a
-- schema-scoped grant covers objects created after it was issued -- including this one.
--
-- This used to be a per-table grant block, and this template shipped without one, which meant a
-- table deployed from it was readable by db_owner and by nobody else. Nothing failed: a missing
-- grant raises no error at deploy time, the table is simply invisible -- SQL Server hides even the
-- metadata of an object a principal holds no permission on, so it does not appear in Object
-- Explorer either. Silent, per table, and permanent. Reads are granted at the schema now so that
-- forgetting is not possible.
--
-- WHAT IS STILL PER OBJECT, AND WHY:
--   DELETE  -- never granted on a plain table at any scope. There is no INSTEAD OF trigger here to
--              turn it into a soft delete, so a DELETE would physically remove the row. Soft
--              deleting is an UPDATE setting IsDeleted = 1, which the schema grant already allows.
--              Only a view gets GRANT DELETE, in its own script.
--   EXECUTE -- granted per procedure, in that procedure's own script, to the roles that call it.
--
-- If this table must NOT be readable by every application user, the grant is not the thing to
-- change: put the table in a data schema, which scripts/permissions.sql denies, and expose a view.
-- -------------------------------------------------------------------------------------------
