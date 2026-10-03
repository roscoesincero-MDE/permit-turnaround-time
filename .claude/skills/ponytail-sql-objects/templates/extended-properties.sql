/*
    Adding or updating MS_Description extended properties.

    ALWAYS through util.uspSetObjectDescription, defined below. A developer runs these scripts by
    hand, so every script must survive a second run — and extended properties are the single
    most common place that breaks:

        sp_addextendedproperty     FAILS if the property already exists
                                   ("Property cannot be added. Property already exists.")
        sp_updateextendedproperty  FAILS if it does not

    So neither one alone is re-runnable. The helper checks sys.extended_properties and picks the
    right one, which also means an improved wording replaces the old one instead of erroring.

    The raw form below is shown ONLY so it is recognizable in older scripts. Do not write it:

        EXEC sys.sp_addextendedproperty @name = N'MS_Description',
             @value = N'<description>',
             @level0type = N'SCHEMA', @level0name = N'<schema>',
             @level1type = N'TABLE',  @level1name = N'<TableName>',
             @level2type = N'COLUMN', @level2name = N'<ColumnName>';

    ORDER MATTERS IN THIS FILE, and it did not always. The CREATE of the helper comes FIRST, before
    anything that calls it, and the illustrative calls that used to sit above it are now inside a
    comment block. Both halves of that are the fix to one defect: this file is what README.md
    prescribes when descriptions were skipped, which is reported on precisely the databases that do
    not have util.uspSetObjectDescription yet — so a live EXEC of the helper ahead of its own CREATE
    failed on run 1 with "Could not find stored procedure", and under sqlcmd -b never reached the
    CREATE at all, meaning the documented remedy did not deploy the remedy. On run 2, with the
    helper finally in place, the same two calls failed again: their <placeholder> arguments resolve
    to no real object, so sp_addextendedproperty rejected them. A file that cannot run clean on
    either run has no business teaching re-runnability. Keep executable statements below the CREATE
    and keep examples in comments.
*/

-- Both settings, at the top of the script, before anything runs. XACT_ABORT so a partial failure leaves
-- no half-applied DDL. QUOTED_IDENTIFIER because sqlcmd defaults it OFF where every other client defaults
-- it ON, and a session carrying it OFF cannot run DML against a table with a filtered index (error 1934) --
-- which is every table here, via the soft-delete unique constraints. The helper below writes to
-- sys.extended_properties rather than to a user table, but this file also CREATEs it, and the setting is
-- BAKED IN at CREATE time.
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- The util schema, created when missing. This file's only CREATE lives in it, and this file is what README.md
-- prescribes when descriptions were skipped -- which is reported on precisely the databases that do not have the util
-- helpers yet, and which therefore need not have the schema either. Without this guard the documented remedy failed
-- on every database that actually needed it. CREATE SCHEMA must be alone in its batch, hence the EXEC.
IF SCHEMA_ID (N'util') IS NULL EXEC (N'CREATE SCHEMA [util]');
GO


/***********************************************************************************************************************
ObjectName:   util.uspSetObjectDescription
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Adds or updates an MS_Description extended property on a table, view, procedure, function, trigger, or column.
Idempotent, so deployment scripts can be re-run safely. Use this in preference to calling sp_addextendedproperty
directly.

========================================================================================================================
Requirements and Key Dependencies:

sys.extended_properties, sys.sp_addextendedproperty, sys.sp_updateextendedproperty

========================================================================================================================
Notes:

@ObjectType must be one of TABLE, VIEW, PROCEDURE, FUNCTION, TRIGGER. Pass @ColumnName only for a column-level
description.

TRIGGER is addressed differently from the rest and the procedure handles that internally. A DML trigger is a LEVEL 2
object under the table or view it sits on -- SCHEMA / TABLE / TRIGGER, or SCHEMA / VIEW / TRIGGER -- where a view or a
procedure is a level 1 object. So the parent's name is required, and so is the parent's own level-1 TYPE: the level1type
has to match what the parent actually is or sp_addextendedproperty rejects the call. Both are derived from the catalog
rather than asked for, so callers pass a trigger exactly the way they pass anything else. That type used to be
hard-coded to TABLE, which was wrong for every INSTEAD OF trigger in this project -- all of them sit on VIEWS, because a
system-versioned table cannot carry one. A database-scoped DDL trigger has no parent at all, is not addressable this
way, and is rejected with a message that says so.

========================================================================================================================
Example Usage and Performance:

exec util.uspSetObjectDescription
      @SchemaName  = 'dbo'
    , @ObjectType  = 'TABLE'
    , @ObjectName  = 'FacilitySource'
    , @ColumnName  = 'FacilityId'
    , @Description = 'Source-assigned facility identifier, e.g. ''MD0000123456''.'

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE util.uspSetObjectDescription
      @SchemaName  SYSNAME
    , @ObjectType  SYSNAME          -- TABLE | VIEW | PROCEDURE | FUNCTION | TRIGGER
    , @ObjectName  SYSNAME
    , @Description NVARCHAR (3750)
    , @ColumnName  SYSNAME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ObjectType NOT IN (N'TABLE', N'VIEW', N'PROCEDURE', N'FUNCTION', N'TRIGGER')
    BEGIN
        -- ;THROW, with the leading semicolon, for the reason templates/procedure.sql gives: a bare THROW as the first
        -- statement after BEGIN is a syntax error. This file wrote it without, which left the skill contradicting
        -- itself in a place a reader copies from.
        ;THROW 50000, N'@ObjectType must be TABLE, VIEW, PROCEDURE, FUNCTION or TRIGGER.', 1;
    END;

    -- A DML trigger is addressed as SCHEMA / <parent> / TRIGGER, so it needs both its parent's name and the parent's
    -- own level-1 type. Derived here rather than taken as parameters that every other caller would have to pass as
    -- NULL. The BEGIN/END blocks around the THROWs below are not decoration: `IF <cond> ;THROW ...` parses the leading
    -- semicolon as an empty statement, which takes the THROW out of the IF and fires it unconditionally.
    DECLARE @ParentName SYSNAME
          , @ParentType SYSNAME;

    IF @ObjectType = N'TRIGGER'
    BEGIN
        SELECT @ParentName = p.name
             , @ParentType = CASE p.type WHEN 'U' THEN N'TABLE'
                                         WHEN 'V' THEN N'VIEW'
                             END
          FROM sys.objects AS o
          JOIN sys.schemas AS s ON s.schema_id  = o.schema_id
          JOIN sys.objects AS p ON p.object_id  = o.parent_object_id
         WHERE o.type   = 'TR'
           AND o.name   = @ObjectName
           AND s.name   = @SchemaName;

        -- A database-scoped DDL trigger has parent_object_id = 0, so the join above finds nothing and it lands here.
        IF @ParentName IS NULL
        BEGIN
            ;THROW 50000, N'No DML trigger of that name in that schema. A database-scoped DDL trigger has no parent table and cannot carry an extended property addressed this way.', 1;
        END;

        IF @ParentType IS NULL
        BEGIN
            ;THROW 50000, N'The trigger''s parent is neither a table nor a view, so the trigger cannot be addressed as a level-2 object.', 1;
        END;

        IF @ColumnName IS NOT NULL
        BEGIN
            ;THROW 50000, N'@ColumnName does not apply to a TRIGGER.', 1;
        END;
    END;

    -- The existence check below needs no special case for a trigger: sys.objects holds triggers under their parent's
    -- schema, an object-level property carries minor_id = 0 whatever kind of object it hangs off, and ep.class = 1
    -- covers both. Only the sp_add / sp_update calls differ.
    DECLARE @exists BIT =
    (
        SELECT CASE WHEN EXISTS
        (
            SELECT 1
              FROM sys.extended_properties AS ep
              JOIN sys.objects              AS o  ON o.object_id  = ep.major_id
              JOIN sys.schemas              AS s  ON s.schema_id  = o.schema_id
              LEFT JOIN sys.columns         AS c  ON c.object_id  = o.object_id
                                                 AND c.column_id  = ep.minor_id
             WHERE ep.class      = 1          -- object or column
               AND ep.name       = N'MS_Description'
               AND s.name        = @SchemaName
               AND o.name        = @ObjectName
               AND (
                        (@ColumnName IS NULL     AND ep.minor_id = 0)
                     OR (@ColumnName IS NOT NULL AND c.name      = @ColumnName)
                   )
        ) THEN 1 ELSE 0 END
    );

    IF @exists = 1
    BEGIN
        IF @ObjectType = N'TRIGGER'
            EXEC sys.sp_updateextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ParentType, @level1name = @ParentName
                , @level2type = N'TRIGGER',  @level2name = @ObjectName;
        ELSE IF @ColumnName IS NULL
            EXEC sys.sp_updateextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ObjectType, @level1name = @ObjectName;
        ELSE
            EXEC sys.sp_updateextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ObjectType, @level1name = @ObjectName
                , @level2type = N'COLUMN',   @level2name = @ColumnName;
    END;
    ELSE
    BEGIN
        IF @ObjectType = N'TRIGGER'
            EXEC sys.sp_addextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ParentType, @level1name = @ParentName
                , @level2type = N'TRIGGER',  @level2name = @ObjectName;
        ELSE IF @ColumnName IS NULL
            EXEC sys.sp_addextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ObjectType, @level1name = @ObjectName;
        ELSE
            EXEC sys.sp_addextendedproperty
                  @name = N'MS_Description', @value = @Description
                , @level0type = N'SCHEMA',   @level0name = @SchemaName
                , @level1type = @ObjectType, @level1name = @ObjectName
                , @level2type = N'COLUMN',   @level2name = @ColumnName;
    END;

    RETURN 0;
END;
GO


/*
    The helper describes itself, and this call is LIVE -- unlike the examples below it.

    Rules 4 and 5 exempt nothing, and this procedure is the one object in the database with no excuse:
    it is the mechanism by which every other description is set. The audit report at the bottom of this
    file reports on sys.objects, so before this block existed the file's own closing report named
    util.uspSetObjectDescription as a finding on every run -- a report that indicts its own script.

    Placement is the whole trick. The ORDER MATTERS note at the top of this file explains why the
    examples further down are inert: a script cannot call the helper before the helper is created. That
    constraint is satisfied here and only here -- the CREATE is complete and the GO above has ended its
    batch, so the procedure exists and can be called. Anywhere earlier in the file it could not be.
*/
EXEC util.uspSetObjectDescription
      @SchemaName  = N'util'
    , @ObjectType  = N'PROCEDURE'
    , @ObjectName  = N'uspSetObjectDescription'
    , @Description = N'Adds or updates the MS_Description extended property on a table, view, procedure, function, trigger or column. The single entry point for rules 4 and 5: scripts call this rather than sys.sp_addextendedproperty, because add fails on an object that already carries the property and every script in this skill has to survive a re-run. Resolves a trigger''s parent object itself, since a DML trigger takes its schema from its parent rather than carrying its own. Deliberately not instrumented under rule 8 -- it is called from inside deployment scripts, including the one that installs execution logging.';
GO


/*
    ------------------------------------------------------------------------------------------------
    HOW TO CALL IT. These are examples, deliberately NOT executable -- see the ORDER MATTERS note at
    the top of this file. Copy the shape into your own script, with real names.
    ------------------------------------------------------------------------------------------------

    Table description:

        EXEC util.uspSetObjectDescription
              @SchemaName  = N'<schema>'
            , @ObjectType  = N'TABLE'
            , @ObjectName  = N'<TableName>'
            , @Description = N'<what this table holds and what one row represents>';
        GO

    Column description — the same call, plus @ColumnName:

        EXEC util.uspSetObjectDescription
              @SchemaName  = N'<schema>'
            , @ObjectType  = N'TABLE'
            , @ObjectName  = N'<TableName>'
            , @ColumnName  = N'<ColumnName>'
            , @Description = N'<what this column means, its units/format, and its valid values>';
        GO

    Views, procedures, functions, triggers: pass VIEW | PROCEDURE | FUNCTION | TRIGGER as
    @ObjectType and omit @ColumnName. A view's columns can carry descriptions too, with
    @ObjectType = N'VIEW'. For TRIGGER, @ObjectName is the trigger and @SchemaName is its schema;
    the parent object and its type are looked up.
*/


/*
    Audit report — everything still missing a description. Run before declaring a script complete.

    Two halves, because rule 4 has two halves: an object-level property on the object itself
    (minor_id = 0) and one per column. The report used to run only the second half, and only over
    sys.tables, so it stayed quiet about a table with no description of its own and about every
    view, procedure, function and trigger in the database — while rule 4 requires the table-level
    property and rule 5 covers the modules. A report that passes a script rule 4 would fail is
    worse than no report.

    ep.class = 1 is load-bearing, not tidiness. major_id and minor_id are reused by every property
    class: an index-scoped property is class 7 with minor_id = index_id, and a constraint- or
    parameter-scoped one uses the same pair again. Without the filter, any of those whose minor_id
    happened to equal a column_id on the same object satisfied the join and the report went quiet
    about a column that in fact has no description at all — the one failure mode an audit report
    must not have.

    NOT EXISTS rather than a LEFT JOIN with `WHERE ep.value IS NULL`, because the filter has to
    apply to the search for a matching property, not to the rows that come back from it.
*/
SELECT N'OBJECT'               AS MissingLevel
     , s.name                  AS SchemaName
     , o.name                  AS ObjectName
     , CAST (NULL AS SYSNAME)  AS ColumnName
     , o.type_desc             AS ObjectType
     , 0                       AS ColumnOrder   -- sorts the object's own row above its columns
  FROM sys.objects  AS o
  JOIN sys.schemas  AS s ON s.schema_id = o.schema_id
 WHERE o.is_ms_shipped = 0
   AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'TR')
   -- A database-scoped DDL trigger cannot carry an addressable extended property, so it is not a finding.
   AND (o.type <> 'TR' OR o.parent_object_id <> 0)
   AND NOT EXISTS (SELECT 1
                     FROM sys.extended_properties AS ep
                    WHERE ep.major_id = o.object_id
                      AND ep.minor_id = 0
                      AND ep.class    = 1
                      AND ep.name     = N'MS_Description')

UNION ALL

SELECT N'COLUMN'
     , s.name
     , o.name
     , c.name
     , o.type_desc
     , c.column_id
  FROM sys.objects  AS o
  JOIN sys.schemas  AS s ON s.schema_id = o.schema_id
  JOIN sys.columns  AS c ON c.object_id = o.object_id
 WHERE o.is_ms_shipped = 0
   AND o.type IN ('U', 'V')
   AND NOT EXISTS (SELECT 1
                     FROM sys.extended_properties AS ep
                    WHERE ep.major_id = o.object_id
                      AND ep.minor_id = c.column_id
                      AND ep.class    = 1
                      AND ep.name     = N'MS_Description')

 ORDER BY SchemaName, ObjectName, ColumnOrder;   -- the object's own row first, then its columns in ordinal order
