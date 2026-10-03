/***********************************************************************************************************************
ObjectName:   logs.vwGetObjectChangeHistory
Author:       rsincero
CreateDate:   2025-12-01
========================================================================================================================
Description:

This view queries the audit table and returns the change history of triggers, procedures, functions, and views.

========================================================================================================================
Requirements and Key Dependencies:

========================================================================================================================
Notes:

========================================================================================================================
Example Usage and Performance:

select * from logs.vwGetObjectChangeHistory

========================================================================================================================

Modification History:

Date:		2025-12-04
Author:		rsincero
Ticket:		RITM000001
Description:
Added triggers to the list as it was originally missing.

-----------------------------------------------------------------------------------------------------------------------
Modification History:

Date:		2025-12-09
Author:		msingh
Ticket:		RITM000008
Description:
Added functions

-----------------------------------------------------------------------------------------------------------------------
Modification History:

Date:		2025-12-11
Author:		smackay
Ticket:		RITM000033
Description:
Added views

-----------------------------------------------------------------------------------------------------------------------


***********************************************************************************************************************/

/*
    Usage notes for this template:

    - Required on every view, stored procedure, function, and trigger.
    - ObjectName is the fully-qualified name including schema and the type prefix
      (vw / usp / udf / tvf).
    - CreateDate is the date the object was first created; it never changes.
    - Description explains what the object does and why it exists, not how it is implemented.
    - Requirements and Key Dependencies: tables, other objects, or permissions the object needs.
    - Example Usage and Performance: a runnable example, plus any performance caveats
      (expected row counts, index dependencies, known slow paths).
    - Modification History: APPEND a row for every change. Never edit or remove prior rows —
      the history is the audit trail. Keep the column alignment.
*/
