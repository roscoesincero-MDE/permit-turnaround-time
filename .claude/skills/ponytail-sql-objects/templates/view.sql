-- SET XACT_ABORT ON sits ABOVE the header block deliberately, and moving it below would introduce a real defect. The
-- GO on the next line ends the batch, and sys.sql_modules stores only the batch that contains CREATE -- so a header
-- placed AFTER that GO is invisible to anyone reading the view out of the database through sp_helptext,
-- OBJECT_DEFINITION or SSMS "Script as CREATE", which is where a maintainer actually reads it. The header has to be
-- the LAST thing before CREATE, with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER, which is not optional here. sqlcmd defaults it OFF where every other client defaults it ON,
-- the setting is BAKED IN at CREATE time, and a module carrying it OFF cannot run DML against a table with a filtered
-- index (error 1934). Every unique constraint in this database is one, via the soft-delete rule -- so that is every
-- table. validate-sql.py rejects a script that CREATEs an object without these two, which for a while included this
-- file: the template that teaches the rule was the one script that broke it.
SET QUOTED_IDENTIFIER ON;
GO

/***********************************************************************************************************************
ObjectName:   dbo.vwFacilitySource
Author:       <author>
CreateDate:   <yyyy-mm-dd>
========================================================================================================================
Description:

Active (non-soft-deleted) facility source records mirrored from the external source registry. Consumers should read this view rather
than dbo.FacilitySource directly so the IsDeleted filter is applied consistently.

========================================================================================================================
Requirements and Key Dependencies:

dbo.FacilitySource

========================================================================================================================
Notes:

Soft delete is enforced here. Any query against the base table risks including deleted rows.

========================================================================================================================
Example Usage and Performance:

select * from dbo.vwFacilitySource where ActivityLocation = 'MD' and CurrentRecord = 1

Supported by UX_dbo_FacilitySource_Natural (filtered on IsDeleted = 0).

========================================================================================================================
Modification History:

Date:		<yyyy-mm-dd>
Author:		<author>
Ticket:		<ticket>
Description:

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW dbo.vwFacilitySource
AS
SELECT
      fs.FacilitySourceId
    , fs.FacilityId
    , fs.ActivityLocation
    , fs.SourceType
    , fs.Sequence
    , fs.FacilityName
    , fs.CurrentRecord
    , fs.SrcCreatedBy
    , fs.SrcCreatedDateUtc
    , fs.SrcUpdatedBy
    , fs.SrcUpdatedDateUtc
    , fs.auditCreatedBy
    , fs.auditCreatedDateUtc
    , fs.auditModifiedBy
    , fs.auditModifiedDateUtc
FROM dbo.FacilitySource AS fs
WHERE fs.IsDeleted = 0;
GO

-- Through the helper, never sp_addextendedproperty directly: CREATE OR ALTER VIEW keeps the
-- object_id, so the extended property survives a re-run and a bare add would then fail with
-- "Property cannot be added. Property already exists."
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwFacilitySource'
    , @Description = N'Active facility source records from the external source registry, with the soft-delete filter applied. Preferred read path over the base table.';
GO
