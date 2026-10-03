-- SET XACT_ABORT ON sits ABOVE the header block deliberately. The GO on the next line ends the batch, and
-- sys.sql_modules stores only the batch that contains CREATE -- so a header placed AFTER this GO is invisible
-- to anyone reading the procedure out of the database through sp_helptext, OBJECT_DEFINITION, or SSMS
-- "Script as CREATE", which is where a maintainer actually reads it. The header has to be the LAST thing
-- before CREATE with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER. sqlcmd defaults it OFF where every other client defaults it ON, the setting is
-- BAKED IN at CREATE time, and a module carrying it OFF cannot run DML against a table with a filtered index
-- (error 1934) -- which is dbo.stdPermitTT, via the soft-delete unique index. Set it here so a hand run
-- without sqlcmd -I cannot get it wrong.
SET QUOTED_IDENTIFIER ON;
GO

-- The util schema, created when missing. This script's only CREATE lives in it, and this script is the prescribed
-- remedy on a database that has no util helpers -- which is precisely a database that need not have the schema either.
-- MDE_ETSReport and EPAL_ISSI both happen to have it today, so this guard is a no-op on both; it is here because the
-- header used to ASSERT the schema already existed, which made the script silently non-portable to the one kind of
-- database it exists to fix. CREATE SCHEMA must be alone in its batch, hence the EXEC.
IF SCHEMA_ID (N'util') IS NULL EXEC (N'CREATE SCHEMA [util]');
GO

/***********************************************************************************************************************
ObjectName:   util.uspSetObjectDescription
Author:       rsincero
CreateDate:   2026-09-10
========================================================================================================================
Description:

Adds or updates an MS_Description extended property on a table, view, procedure, function, trigger, or column.
Idempotent, so deployment scripts can be re-run safely. Use this in preference to calling sp_addextendedproperty
directly.

This is a PREREQUISITE for 015_logs.ExecutionLogging.sql and 020_dbo.uspBuildStdPermitTT.sql. The ponytail-sql-objects
conventions require MS_Description on every table and every column and require it to be set through this helper, but
MDE_ETSReport did not have the helper -- the util schema here holds only the func_ and ufn_ reporting functions. This
script installs it. Nothing else in the database depends on it yet, so installing it is additive.

========================================================================================================================
Requirements and Key Dependencies:

sys.extended_properties, sys.objects, sys.schemas, sys.columns, sys.sp_addextendedproperty,
sys.sp_updateextendedproperty

The util schema, created above when missing. Nothing else -- this script is deliberately the FIRST thing that runs, so
it cannot depend on logs.ExecutionLog (installed by 015) or on anything in dbo.

========================================================================================================================
Notes:

@ObjectType must be one of TABLE, VIEW, PROCEDURE, FUNCTION, TRIGGER. Pass @ColumnName only for a column-level
description.

TRIGGER IS ADDRESSED DIFFERENTLY, AND THE PROCEDURE HANDLES THAT INTERNALLY. A DML trigger is a LEVEL 2 object under the
table or view it sits on -- SCHEMA / TABLE / TRIGGER, or SCHEMA / VIEW / TRIGGER -- where a view or a procedure is a
level 1 object. So the parent's name is required, and so is the parent's own level-1 TYPE: the level1type has to match
what the parent actually is or sp_addextendedproperty rejects the call. Both are derived from the catalog rather than
asked for, so callers pass a trigger exactly the way they pass anything else. Do NOT hard-code the parent type to TABLE:
every INSTEAD OF trigger in these conventions sits on a VIEW, because a system-versioned table cannot carry one. A
database-scoped DDL trigger has no parent, is not addressable this way, and is rejected with a message that says so.

    This mattered here and was missing. MDE_ETSReport already carries the record_db_changes DDL trigger, and
    templates/table.sql section 4 puts an AFTER UPDATE trigger on every plain table, so the first caller to pass
    @ObjectType = N'TRIGGER' met a THROW 50000 telling it TRIGGER was not a legal value.

WHY NOT sp_addextendedproperty DIRECTLY. Neither raw procedure is re-runnable on its own:

    sp_addextendedproperty     fails if the property already exists ("Property cannot be added. Property already
                               exists.")
    sp_updateextendedproperty  fails if it does not

A developer runs these scripts by hand, so a second run must be a no-op. This helper checks
sys.extended_properties and picks the right one, which also means an improved wording actually replaces the old one
instead of erroring.

NO INSTRUMENTATION HERE, DELIBERATELY. This procedure is one of the named exemptions from the "every procedure records
its own errors" rule: it runs during deployment, before any logging target is guaranteed to exist, and it is called
dozens of times per script. It writes only to sys.extended_properties.

========================================================================================================================
Example Usage and Performance:

exec util.uspSetObjectDescription
      @SchemaName  = 'dbo'
    , @ObjectType  = 'TABLE'
    , @ObjectName  = 'stdPermitTT'
    , @ColumnName  = 'program_code'
    , @Description = 'Two-character ETS program code, e.g. ''33'' for Wetlands and Waterways.'

Singleton metadata reads and one singleton catalog write. Negligible.

========================================================================================================================
Modification History:

Date:		2026-09-10
Author:		rsincero
Ticket:		PTT
Description:
Original. Installed to support dbo.stdPermitTT.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
Brought into line with templates/extended-properties.sql, which had moved on since 2026-09-10. Four corrections, in
descending order of how much they mattered:

1. TRIGGER is now a legal @ObjectType. The parent object's name AND the parent's own level-1 type are derived from the
   catalog, and the add/update paths grew a third branch for the level-2 TRIGGER call. Previously TRIGGER was rejected
   outright with THROW 50000, so there was no way to describe a trigger through the one helper rule 4 permits -- while
   templates/table.sql section 4 puts an AFTER UPDATE trigger on every plain table and the closing report below counts
   triggers as findings. The parent type is derived rather than hard-coded to TABLE because every INSTEAD OF trigger in
   these conventions sits on a VIEW.

2. The util schema is created when missing. The header previously ASSERTED the schema already existed, which is true of
   MDE_ETSReport and EPAL_ISSI but makes the script non-portable to the one kind of database it exists to fix.

3. Added the closing audit report -- both halves, object level and column level, with ep.class = 1 -- scoped to the
   objects this project deploys. The scope is the single departure from the template and the note above the report says
   why: unscoped it returns 33,222 findings in this legacy database.

4. THROW is written ;THROW, matching every other THROW in this project. With arguments it compiles either way, so this
   changes no behaviour; it is consistency in a line people copy, where the bare form IS a syntax error.

Also: the self-describing EXEC now states the trigger handling and the rule 8 exemption, and the header cites
ponytail-sql-objects rather than the superseded sql-objects skill. No change to the procedure's signature or to the
behaviour of any existing caller -- 015_logs.ExecutionLogging.sql and 020_dbo.uspBuildStdPermitTT.sql pass TABLE,
PROCEDURE and column-level calls only, all of which take the same branches they did before.

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
        -- statement after BEGIN is a syntax error. With arguments it happens to compile either way, which is exactly
        -- why the form is written consistently -- this is a line people copy.
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
        -- MDE_ETSReport has one of these already, the legacy record_db_changes trigger.
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
    The helper describes itself, and this call is LIVE.

    Rules 4 and 5 exempt nothing, and this procedure is the one object in the database with no excuse: it is the
    mechanism by which every other description is set. The audit report at the bottom of this script reports on
    sys.objects, so without this block the script's own closing report would name util.uspSetObjectDescription as a
    finding on every run -- a report that indicts its own script.

    Placement is the whole trick. The CREATE is complete and the GO above has ended its batch, so the procedure exists
    and can be called. Anywhere earlier in the file it could not be.
*/
EXEC util.uspSetObjectDescription
      @SchemaName  = N'util'
    , @ObjectType  = N'PROCEDURE'
    , @ObjectName  = N'uspSetObjectDescription'
    , @Description = N'Adds or updates the MS_Description extended property on a table, view, procedure, function, trigger or column. The single entry point for rules 4 and 5: scripts call this rather than sys.sp_addextendedproperty, because add fails on an object that already carries the property and every script in this project has to survive a re-run. Resolves a trigger''s parent object and the parent''s own level-1 type itself, since a DML trigger is addressed as a level-2 object under the table or view it sits on. Deliberately not instrumented under rule 8 -- it is called from inside deployment scripts, including 015_logs.ExecutionLogging.sql, which installs the very logging it would otherwise write to.';
GO

IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON util.uspSetObjectDescription TO db_executor;
END;
GO


/*
    Audit report -- everything in THIS PROJECT'S schemas still missing a description. Run before declaring a script
    complete.

    Two halves, because rule 4 has two halves: an object-level property on the object itself (minor_id = 0) and one per
    column. Both halves are needed -- a report over columns alone stays quiet about a table with no description of its
    own, and about every view, procedure, function and trigger in the database, while rule 4 requires the table-level
    property and rule 5 covers the modules.

    ep.class = 1 is load-bearing, not tidiness. major_id and minor_id are reused by every property class: an
    index-scoped property is class 7 with minor_id = index_id, and a constraint- or parameter-scoped one uses the same
    pair again. Without the filter, any of those whose minor_id happened to equal a column_id on the same object
    satisfies the join and the report goes quiet about a column that in fact has no description at all -- the one
    failure mode an audit report must not have.

    NOT EXISTS rather than a LEFT JOIN with `WHERE ep.value IS NULL`, because the filter has to apply to the search for
    a matching property, not to the rows that come back from it.

    THE SCOPE FILTER IS THE ONE DEPARTURE FROM templates/extended-properties.sql, AND IT IS DELIBERATE. The template's
    report is database-wide, which is right for a database built to these conventions from empty. MDE_ETSReport is not
    that: it is a legacy reporting database of 19 user schemas, and the unscoped report returns 33,222 findings here --
    9,483 from WMA columns alone, 3,255 from dbo, 142 from util's pre-existing func_ and ufn_ reporting functions. A
    deploy check that returns 33,222 rows is not read, so it does not check anything.

    So the scope is the objects THIS PROJECT deploys, named rather than taken by schema -- because by schema there is no
    good answer: dbo and util are both mostly legacy, and scoping to util + logs would have silently stopped checking
    dbo.stdPermitTT, which is the whole deliverable. Named, the report answers the one question worth asking at deploy
    time: did MY scripts satisfy rule 4.

    logs is taken whole rather than object by object, and the 21 findings it returns are real ones -- the legacy
    logs.z_db_changes table and its 20 columns, the OLD generation of DDL change logging, which predates these
    conventions and which rule 10 wants replaced by scripts/logdBChanges.sql. Leaving it visible is the point.

    To get the template's full database-wide backlog instead, comment out the two scope predicates below. The finding
    logic either way is character-for-character the template's.
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
   -- A database-scoped DDL trigger cannot carry an addressable extended property, so it is not a finding. MDE_ETSReport
   -- has one: the legacy record_db_changes trigger.
   AND (o.type <> 'TR' OR o.parent_object_id <> 0)
   -- Project scope; see the note above. Comment this block out for the template's database-wide report.
   AND (   s.name = N'logs'
        OR (s.name = N'util' AND o.name = N'uspSetObjectDescription')
        OR (s.name = N'dbo'  AND o.name IN (N'stdPermitTT', N'trg_au_updt_stdPermitTT')))
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
   -- Project scope; see the note above. Comment this block out for the template's database-wide report.
   AND (   s.name = N'logs'
        OR (s.name = N'dbo' AND o.name = N'stdPermitTT'))
   AND NOT EXISTS (SELECT 1
                     FROM sys.extended_properties AS ep
                    WHERE ep.major_id = o.object_id
                      AND ep.minor_id = c.column_id
                      AND ep.class    = 1
                      AND ep.name     = N'MS_Description')

 ORDER BY SchemaName, ObjectName, ColumnOrder;   -- the object's own row first, then its columns in ordinal order
GO
