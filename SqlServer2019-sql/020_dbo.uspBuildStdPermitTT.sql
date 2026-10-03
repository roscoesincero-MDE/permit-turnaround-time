-- SET XACT_ABORT ON sits ABOVE the header block deliberately. The GO on the next line ends the batch, and
-- sys.sql_modules stores only the batch that contains CREATE -- so a header placed AFTER this GO is invisible
-- to anyone reading the procedure out of the database through sp_helptext, OBJECT_DEFINITION, or SSMS
-- "Script as CREATE", which is where a maintainer actually reads it. The header has to be the LAST thing
-- before CREATE with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER. sqlcmd defaults it OFF where every other client defaults it ON, the setting is
-- BAKED IN at CREATE time, and a module carrying it OFF cannot run DML against a table with a filtered index
-- (error 1934). dbo.stdPermitTT has one, so this procedure would fail at run time -- inside a MERGE whose text
-- reads perfectly correctly -- if it were ever deployed by a hand-typed sqlcmd line without -I.
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================================================================
-- ADDITIVE COLUMN MIGRATION. This runs BEFORE the procedure is created, and it has to, for a reason that is not
-- obvious: deferred name resolution covers a missing TABLE but not a missing COLUMN of a table that already exists.
-- On a database where dbo.stdPermitTT is already deployed with the original 22 columns, a CREATE OR ALTER PROCEDURE
-- whose MERGE names taskIDs would fail to compile outright with "Invalid column name" -- the ALTER cannot live inside
-- the procedure body alongside the MERGE that uses the new columns, and putting the MERGE in dynamic SQL to get
-- around that would throw away compile-time checking for no gain. So: guarded ALTERs here, in their own batch, and
-- the same six columns are also listed in the CREATE TABLE inside the procedure for the fresh-database path. Both
-- paths converge on the same 28-column table.
--
-- The guards make this a no-op on a fresh database (no table yet -- the procedure creates it complete) and a no-op on
-- the second run of an upgraded one. Nothing is dropped and no existing column is altered.
--
-- One cosmetic consequence, stated so it is not mistaken for a defect: on an upgraded database the six columns land
-- at the physical end of the table, after the audit block, whereas a fresh database gets them in the declared order
-- below. Column ORDER is not part of the contract -- every consumer names its columns -- and correcting it would mean
-- rebuilding a populated table, which is not worth it.
-- =====================================================================================================================
IF OBJECT_ID (N'dbo.stdPermitTT', N'U') IS NOT NULL
BEGIN
    -- Comma-delimited list of ETS reference task IDs. See the header for why this is a delimited list.
    IF COL_LENGTH (N'dbo.stdPermitTT', N'taskIDs') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD taskIDs VARCHAR (100) NULL;

    -- The five descriptive fields carried over from dbo.MTB_MDE_ACTIVITY. Widths match that table exactly, except
    -- stt_sortorder, which follows the earlier attempt's INT rather than the source's NUMERIC (2, 0).
    IF COL_LENGTH (N'dbo.stdPermitTT', N'permit_category') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD permit_category VARCHAR (30) NULL;

    IF COL_LENGTH (N'dbo.stdPermitTT', N'permit_class') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD permit_class VARCHAR (50) NULL;

    IF COL_LENGTH (N'dbo.stdPermitTT', N'permit_type') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD permit_type VARCHAR (100) NULL;

    IF COL_LENGTH (N'dbo.stdPermitTT', N'stt_permit_type') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD stt_permit_type VARCHAR (100) NULL;

    IF COL_LENGTH (N'dbo.stdPermitTT', N'stt_sortorder') IS NULL
        ALTER TABLE dbo.stdPermitTT ADD stt_sortorder INT NULL;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.uspBuildStdPermitTT
Author:       rsincero
CreateDate:   2026-09-10
========================================================================================================================
Description:

Creates dbo.stdPermitTT if it does not exist, then loads it from the two standard-turnaround-time (STT) lookup tables
that the permit turnaround times (PTT) report reads today:

    dbo.MTB_MDE_STT       -- every program except Wetlands and Waterways
    dbo.MTB_MDE_WWP_STT   -- the "short-cut" table built for Wetlands and Waterways only (program_code = '33')

The point of the combined table is to retire that short-cut. MTB_MDE_WWP_STT exists because Wetlands was given its own
lookup with its own shape instead of being fitted into MTB_MDE_STT: it has no program_code column (every row is
program 33) and no activity_category_code column, it carries project_type and alt_turnaround_time which MTB_MDE_STT does
not, and five of its seven rows carry no activity_type_code at all. dbo.stdPermitTT is one table, one shape, one grain,
for both.

Scope is applications only -- activity_category_code = 'APP'. That column exists in neither source table; it comes from
the DSKMTB_ACTIVITY_TYPE lookup (see Requirements) and is fixed to 'APP' by a CHECK constraint.

Every turnaround time in this table is in DAYS. The sources state some standards in months; they are converted on the way
in and turnaround_time_unit is 'Days' on every row, enforced by a CHECK constraint. See the units note below.

========================================================================================================================
Requirements and Key Dependencies:

dbo.stdPermitTT               -- created by this procedure on first run
dbo.MTB_MDE_STT               -- source, 313 rows as at 2026-09-10
dbo.MTB_MDE_WWP_STT           -- source, 7 rows as at 2026-09-10
dbo.DSKMTB_ACTIVITY_TYPE      -- supplies activity_category_code, and expands the Wetlands rows
dbo.MTB_MDE_ACTIVITY          -- supplies permit_category, permit_class, permit_type, stt_permit_type, stt_sortorder

util.uspSetObjectDescription  -- install 010_util.uspSetObjectDescription.sql FIRST

dbo.trg_au_updt_stdPermitTT   -- NOT a dependency of this procedure: it sits ON the table this procedure creates, so it
                              -- is deployed by 030_dbo.trg_au_updt_stdPermitTT.sql AFTER this procedure has been run
                              -- once. Listed here because it fires on the MERGE's UPDATE branches and co-owns the audit
                              -- columns -- see the note below before editing those assignments or the OUTPUT clause.

logs.ExecutionLog             -- the completion UPDATE below writes it directly
logs.uspStartExecutionLogging -- opens the row; called at the top of the TRY and again in the CATCH
logs.uspRecordExecutionError  -- records the failure; called from the CATCH
                              -- all three: install 015_logs.ExecutionLogging.sql BEFORE this script

THE LOGGING OBJECTS MUST EXIST BEFORE THE FIRST CALL, NOT BEFORE THE DEPLOY. Deferred name resolution means this
procedure CREATEs cleanly against a database that has none of them -- the failure then arrives at the EXEC in the TRY
block on the first call, before any work is done, as error 2812 "Could not find stored procedure". That is a safe
failure but a confusing one, so run 015 first. Its own closing report says whether it is complete; do not take the
absence of errors from this script as evidence that logging is installed.

dbo.DSKMTB_ACTIVITY_TYPE IS A SYNONYM, AND THAT IS WHY THIS PROCEDURE NAMES NO OTHER DATABASE. The activity type lookup
physically lives in the ETS database, not in MDE_ETSReport, and this database already carries a local synonym for it
(sys.synonyms, alongside several hundred others of the same kind). Going through the synonym rather than writing a
three-part name means the procedure text has no cross-database reference in it, so it does not have to be rewritten if
the two databases are ever split across servers -- only the synonym would. Do not "simplify" it back to a three-part
name.

========================================================================================================================
Notes:

THE GRAIN, AND WHY THE WETLANDS ROWS ARE EXPANDED. dbo.MTB_MDE_STT is keyed at activity-type level:
(program_code, activity_class_code, activity_type_code, effective_start_date) is unique across all 313 rows.
dbo.MTB_MDE_WWP_STT is not -- five of its seven rows have activity_type_code NULL and are keyed by project_type
('Major' / 'Minor') instead, which is a class-level standard, not a type-level one.

To reach one grain, each class-level Wetlands row is expanded across every APP activity type in its class from
dbo.DSKMTB_ACTIVITY_TYPE: the 7 source rows become 66, and activity_type_code is NOT NULL on every row of the combined
table. 313 + 66 = 379 rows, and (program_code, activity_class_code, activity_type_code, project_type,
effective_start_date) is unique across all 379 -- verified against live data before this procedure was written.

CONSEQUENCE FOR CONSUMERS -- READ THIS BEFORE REPOINTING ANYTHING AT dbo.stdPermitTT. util.ufn_lookup_wwp_stt_time
matches the Wetlands table with a disjunction:

        and (project_type = @v_project_type or activity_type_code = @v_activity_type_code)
        and activity_class_code = @v_activity_class_code

That OR is correct only while the two predicates are mutually exclusive, which they are in MTB_MDE_WWP_STT because a row
has one or the other and never both. Expansion populates BOTH on every row, so the OR would match the 'Major' row when
asked about a 'Minor' project and return 365 days instead of 240. A consumer of dbo.stdPermitTT must match with AND:

        and activity_class_code  = @v_activity_class_code
        and activity_type_code   = @v_activity_type_code
        and (project_type = @v_project_type or project_type is null)

Repointing util.ufn_lookup_wwp_stt_time and util.ufn_lookup_STT_days at this table is deliberately NOT part of this
procedure. Note also that those functions currently read the REF schema copies, not the dbo ones this procedure loads
from, and REF.mtb_mde_stt holds 261 rows against dbo.MTB_MDE_STT's 313 -- reconcile that before switching consumers over.

ALL UNITS ARE CONVERTED TO DAYS, AT A FLAT 30 DAYS PER MONTH. Management's requirement. This is NOT a small correction:
144 of the 313 dbo.MTB_MDE_STT rows state their standard in months, spread across programs 21, 27 and 32, from 4 months
up to 36. dbo.MTB_MDE_WWP_STT is entirely in days. So 144 of the 377 rows convert, and turnaround_time_unit is 'Days'
everywhere afterwards -- enforced by CK_dbo_stdPermitTT_turnaround_time_unit rather than left to convention, because a
report that compares a duration against a standard silently produces nonsense if one row is in a different unit.

The factor is a flat 30, as specified, not a calendar month. 6 months becomes 180 days, not 182 or 183, and it does not
matter which months the application actually spanned. That is a deliberate simplification in the requirement and it makes
the conversion reversible and reproducible; do not "improve" it into DATEADD arithmetic, which would make the standard
depend on the receipt date.

Only two unit spellings exist across both sources, 'Days' and 'Months'. Anything else -- a new spelling, a NULL, a
'Weeks' -- is REJECTED before the load starts, with a message naming the offending value, rather than being silently
multiplied by 1 and stored as though it were days. That check is the reason this procedure fails loudly on a unit it does
not understand instead of quietly corrupting 30-odd standards.

alt_turnaround_time IS CONVERTED ON THE SAME BASIS AS ITS ROW, AND THAT IS A JUDGEMENT CALL WORTH REVIEWING. The two
columns share one unit column, so the conversion is applied to both using the row's own unit. That is uniform and needs
no special case -- but it decides something the requirements do not state outright. The two program 21 class APC rows
that rule 2 gives alt_turnaround_time = 11 are 'Months' rows (15 months, now 450 days), so the 11 is read as 11 MONTHS
and stored as 330 DAYS. The alternative reading is that the 11 was already meant as days, which would leave it at 11.
330 is the coherent one: an alternate standard of 11 days against a 450-day standard would be a strange thing to write,
the value was specified while the row was in months, and treating it as days would mean carving an exception out of a
rule that says everything is in days. If 11 days really is what was meant, change the multiplier on that one CASE
expression in the load below to 1 and re-run -- it is a one-line change and the rebuild converges.

ACTIVITY TYPE 'XPR' IS EXCLUDED, AND ONLY FOR WETLANDS. Program 33 class ATW has an activity type XPR that must not
carry a standard. It is a creature of the expansion rather than of the source data: no row of dbo.MTB_MDE_WWP_STT names
XPR, but XPR is one of the APP types in class ATW, so expanding the two class-level ATW rows across the class produced an
XPR / Major row at 240 days and an XPR / Minor row at 150 days that nobody asked for. The filter sits in the Wetlands
branch only, so an XPR in some other program -- there is none today -- keeps its standard.

Two things corroborate the exclusion rather than merely permitting it. Those two XPR rows were the ONLY two rows of the
whole 379 that failed to find a match in dbo.MTB_MDE_ACTIVITY, so the requirement below that adds columns from that
table and the requirement that removes XPR agree with each other; and excluding them leaves 377 rows, which is exactly
the row count of the earlier attempt, OIMT.mtb_standard_turnaround_time.

Because the pair already exists in a deployed table, the exclusion reaches them as a SOFT DELETE -- IsDeleted = 1 -- not
as a removal. That is the intended path, and it means the first run after this change reports 2 soft-deleted while the
table still physically holds 379 rows, 377 of them active. Every read filters IsDeleted = 0 already.

taskIDs IS A DELIMITED LIST, NOT A NUMBER. Two of the requirements attach ETS reference task IDs to particular rows: a
single 48 for one Wetlands row, and BOTH 2017 and 2028 for the program 21 rows. One row therefore has to carry two IDs,
so the column cannot be an integer. It is VARCHAR (100) holding a comma-separated list with no spaces -- '48',
'2017,2028' -- which is the shape this database already uses for the same idea, in REFERENCE_TASK_IDS_W and
REFERENCE_TASK_ID_L on the V_All_* views. Split it with STRING_SPLIT when joining to a task table. NULL, not an empty
string, means no task IDs apply, which is the case for 374 of the 377 rows.

RULE 1, taskIDs = 48 FOR WETLANDS ROWS WHOSE TWO STANDARDS DIFFER. Applies where program_code = '33' and
turnaround_time <> alt_turnaround_time. Exactly one source row qualifies: class ATW, type T01, 240 days against an
alternate of 325. The other six Wetlands rows carry an alternate equal to the standard. Written as a CASE over the
source columns, so the test is "the two standards genuinely differ" and not "an alternate exists"; if a Wetlands row
ever arrives with alt_turnaround_time NULL the comparison is UNKNOWN and taskIDs stays NULL, which is the wanted
answer rather than an accident. No program 33 row has a NULL alternate today.

RULE 2, taskIDs = 2017 AND 2028 PLUS alt_turnaround_time = 11 FOR THE OPEN-ENDED PROGRAM 21 APC ROWS. Applies where
program_code = '21', activity_class_code = 'APC', activity_type_code is 'APC' or 'ASM', and effective_end_date IS NULL.
Two rows qualify -- APC/APC and APC/ASM, both starting 2021-07-01 at 15 days -- and their superseded 1970..2021-06-30
predecessors are correctly left alone by the effective_end_date IS NULL test. This is the first non-Wetlands use of
alt_turnaround_time: dbo.MTB_MDE_STT has no such column, so the 11 is injected here, not copied. The requirement wrote
these predicates with a "dcf." alias, which is an artefact of whatever query it was drafted against -- there is no dcf
schema or object in this database -- and the four column names match dbo.stdPermitTT, so they are applied to this table.
The predicate is written once, in a CROSS APPLY, because it drives two output columns and duplicating it invites the two
copies to drift apart.

RULE 3, THE FIVE DESCRIPTIVE FIELDS ARE MATERIALISED, NOT JOINED AT READ TIME. permit_category, permit_class,
permit_type, stt_permit_type and stt_sortorder are copied onto each row from dbo.MTB_MDE_ACTIVITY. They are stored
rather than left to the consumer to join because the earlier attempt did exactly that -- OIMT.mtb_standard_turnaround_time
carries these same five columns, under these same names -- and because the whole point of dbo.stdPermitTT is that the
report reads ONE lookup. The join is safe to denormalise over: its four columns
(PROGRAM_CODE, ACTIVITY_CATEGORY_CODE, ACTIVITY_CLASS_CODE, ACTIVITY_TYPE_CODE) are precisely the primary key of
dbo.MTB_MDE_ACTIVITY, so it cannot fan a row out into several.

It is a LEFT join on purpose. An inner join would silently drop any row whose activity type is missing from
dbo.MTB_MDE_ACTIVITY -- losing a real turnaround standard to fetch five descriptive strings, which is the wrong trade.
All 377 rows match today, so the LEFT join changes nothing now; it is there so that a newly added activity type still
gets its standard, with these five columns NULL, instead of vanishing from the report. The five columns are included in
the change-detection test below, so editing a permit_class in dbo.MTB_MDE_ACTIVITY and re-running propagates it.

INACTIVE ACTIVITY TYPES ARE INCLUDED IN THE EXPANSION. Twelve of the twenty APP types in class ATW carry
INACTIVE_FLAG = 'Y'. They are expanded anyway, because two of the Wetlands rows are themselves historical (they end
2010-09-30) and the report looks standards up by the date an application was received, not by what is current. Excluding
them would silently lose the standard for older applications. Filter on INACTIVE_FLAG here only if that is what is
actually wanted.

TURNAROUND TIMES OF ZERO ARE CARRIED THROUGH AS ZERO. 24 rows in dbo.MTB_MDE_STT have TURNAROUND_TIME = 0 -- 22 of them
program 27, class APJ, permit_class 'Modify'. This is a faithful copy, so they arrive as 0 rather than being dropped or
turned into NULL. The earlier attempt, OIMT.usp_update_mtb_mde_stt, excluded them with "turnaround_time != 0". If the
report must not treat 0 as "the standard is zero days", filter it in the consumer or say so and it can be filtered here.

THE CONFLICT RULE IS IMPLEMENTED BUT DOES NOT FIRE TODAY. The requirement is: for program_code <> '33'
dbo.MTB_MDE_STT wins, and for program_code = '33' dbo.MTB_MDE_WWP_STT wins. dbo.MTB_MDE_STT presently holds no
program 33 rows at all -- its programs are 21, 26, 27, 29, 31, 32 and 37 -- so the two sources do not currently overlap
and the union is clean. The "s.PROGRAM_CODE <> '33'" predicate below is the rule, kept so that a program 33 row added to
MTB_MDE_STT later loses to the Wetlands table as specified rather than colliding on the unique index.

RE-RUNNABLE, AND IT CONVERGES RATHER THAN RE-APPLYING. Safe to run any number of times. The table is created behind an
OBJECT_ID guard and never dropped; the load is a MERGE, and its MATCHED branch fires only when a value actually differs
(the EXCEPT test below is null-safe, which "<>" is not). A second run against unchanged sources therefore reports 0/0/0
and does not move tmsp_last_updt or auditModifiedDateUtc.

SOFT DELETE ONLY. A row that disappears from a source is marked IsDeleted = 1, never removed. Reads must filter
IsDeleted = 0. The unique index is filtered the same way, so a key can be re-inserted after its earlier row was
soft-deleted, and the re-soft-delete branch is guarded by "AND t.IsDeleted = 0" so it cannot overwrite the original
auditDeleted* values on a later run.

AN AFTER UPDATE TRIGGER NOW CO-OWNS THE AUDIT COLUMNS, SINCE 2026-09-22. dbo.trg_au_updt_stdPermitTT, deployed by
sql/030, maintains auditModifiedBy, auditModifiedDateUtc, user_last_updt, tmsp_last_updt and the auditDeleted* pair on
every UPDATE of this table -- including the two UPDATE branches of the MERGE below. The explicit assignments in those
branches are deliberately KEPT rather than deleted: they are what makes the procedure readable about its own intent, the
trigger's 0 -> 1 guard and this procedure's "AND t.IsDeleted = 0" guard agree, and the values the two write are the same
ones. Two consequences worth knowing:

    The audit timestamps on UPDATED rows are the trigger's SYSUTCDATETIME () / SYSDATETIME (), not this procedure's
    run-wide @NowUtc / @NowLocal. Still one value per statement, so rows stay consistent with each other; INSERTED rows
    keep @NowLocal, because an AFTER UPDATE trigger does not see them.

    Do NOT change the MERGE's "OUTPUT $action, inserted.IsDeleted INTO @Changes" to a bare OUTPUT. A table with an
    enabled trigger rejects an OUTPUT clause that has no INTO (error 334), so that edit would stop this procedure
    compiling. The INTO form is also why the counts survived the trigger: they come from @Changes and never from
    @@ROWCOUNT, which the trigger's own inner UPDATE would otherwise be free to overwrite.

id IS A NEW IDENTITY AND CARRIES NOTHING OVER. Neither source table has an id column at all, so there is nothing to
preserve; the identity values here are unrelated to OIMT.mtb_standard_turnaround_time's.

INSTRUMENTATION IS THE FULL RULE 8 BLOCK, COPIED FROM templates/procedure.sql. This procedure writes, so it gets the
whole thing: a logs.ExecutionLog row opened before the transaction, closed by its own UPDATE after the commit, re-created
in the CATCH if a rollback destroyed it, the failure recorded through logs.uspRecordExecutionError, and a bare THROW.
The DECLARE block, the BEGIN TRY, the completion UPDATE and the whole CATCH are boilerplate -- do not tidy them per
procedure. Only @KeyParameters, @Comments, @ContextMessage and the work between the two ===== banners belong to this
procedure.

  Until 2026-09-22 there was no log row at all, because logs.ExecutionLog did not exist in MDE_ETSReport -- the logs
  schema here held only z_db_changes -- and building it had been declined. Script 015 now installs it and the four
  procedures, so the reason is gone. THE OLD NOTE POINTED AT OIMT.uspExecutionLog as the house equivalent; this
  procedure deliberately does NOT write there. Two logging tables written by different procedures in one database is
  worse than either alone, and templates/procedure.sql -- which the CATCH below is copied from verbatim -- is written
  against logs.ExecutionLog. OIMT.uspExecutionLog is left for OIMT.usp_update_mtb_mde_stt, which is the earlier attempt
  this work replaces.

@KeyParameters SAYS "(none)" BECAUSE THIS PROCEDURE TAKES NO PARAMETERS, and that is worth a line rather than a NULL.
NULL in that column is ambiguous between "no arguments" and "the procedure did not bother", and the monitoring grid
shows an empty cell either way. It is NOT a place to record the source row counts: rule 9 allows counts, but getting
them would mean reading the four source tables before the work starts, and the counts that matter are the three the
load actually applied -- which go in @Comments, computed from the MERGE's own OUTPUT clause.

@ContextMessage IS SET AT EACH PHASE BOUNDARY, so a failure says how far the build got. The procedure does five
distinguishable things -- create the table, index it, describe it, validate the units, load -- and the ERROR_LINE alone
does not separate them for a reader who does not have this file open. It carries phase names and counts only.

THE UNITS CHECK IS INSIDE THE INSTRUMENTED REGION, WHICH IS THE POINT. It THROWs 50001 before BEGIN TRANSACTION, so it
is now recorded as a failed call with its own message rather than only reaching whoever was watching the output. That
was the most likely real failure of this procedure and the one that previously left no trace.

THROW IS BARE AND PRECEDED BY A SEMICOLON. Bare THROW re-raises the original error with its original number. RAISERROR
would replace it with 50000 and a caller could no longer tell a deadlock (1205, retry) from a constraint violation
(2627, 547, do not). The leading semicolon is required because a bare THROW as the first statement after BEGIN is a
syntax error.

ERROR_* ARE CAPTURED FIRST. They are valid only in the CATCH scope and any statement can reset them, so the SELECT that
captures them is the first statement in the block, before the rollback.

DDL RUNS BEFORE THE TRANSACTION, NOT INSIDE IT. The create-table, index and description work is outside BEGIN
TRANSACTION so that the load is the only thing a rollback can undo. The MERGE that follows references a table created
earlier in the same execution, which is resolved at run time rather than at CREATE PROCEDURE time -- that is why this
procedure compiles cleanly against a database where dbo.stdPermitTT does not yet exist.

========================================================================================================================
Example Usage and Performance:

exec dbo.uspBuildStdPermitTT

First run creates the table, the index and 29 extended properties, then inserts 377 rows. Later runs re-apply the
descriptions, scan the sources and the two lookups, and touch only rows whose values changed. All four inputs are
small -- 313, 7, 382 and a few thousand rows -- so the whole build is well under a second and the plan shape does not
matter. Reports what it did with PRINT rather than a result set, so INSERT ... EXEC callers are not broken.

Instrumentation adds one singleton INSERT into logs.ExecutionLog on every call and one singleton UPDATE of it on the
successful path. Against a build that touches four source tables that is not measurable, which is the trade rule 8 makes
on a writer. To see what a run recorded:

    select top (10) ExecutionLogId, StartDateUtc, ElapsedMilliseconds, Successful, Comments, ContextMessage
      from logs.ExecutionLog
     where ProcedureName = N'[dbo].[uspBuildStdPermitTT]' and IsDeleted = 0
     order by StartDateUtc desc;

Do not treat ExecutionLogId as gapless: a failure inside a CALLER's transaction loses its row to the rollback and the
re-created one takes the next identity value, so the consumed number is gone. ReCreatedAfterRollback = 1 marks that row.

On the FIRST run after the four additional requirements were added, against a database already holding the original
379 rows, the expected report was "0 inserted, 377 updated, 2 soft-deleted": every surviving row gained the five
descriptive columns, and the two XPR rows left the source.

On the FIRST run after the units conversion, the expected report is "0 inserted, 144 updated, 0 soft-deleted" -- the 144
'Months' rows, and no others. Runs after that report 0/0/0 again.

========================================================================================================================
Modification History:

Date:		2026-09-10
Author:		rsincero
Ticket:		PTT
Description:
Original. Combines dbo.MTB_MDE_STT and dbo.MTB_MDE_WWP_STT into dbo.stdPermitTT, replacing the Wetlands short-cut.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-11
Author:		rsincero
Ticket:		PTT
Description:
Four additional requirements. Six new columns, added both to the CREATE TABLE and as guarded ALTERs ahead of this batch:
taskIDs, permit_category, permit_class, permit_type, stt_permit_type, stt_sortorder.
  1. Excluded activity_type_code 'XPR' from the Wetlands expansion. 379 active rows become 377; the two existing XPR
     rows are soft-deleted rather than removed.
  2. taskIDs = '48' where program_code = '33' and turnaround_time <> alt_turnaround_time. One row.
  3. taskIDs = '2017,2028' and alt_turnaround_time = 11 where program_code = '21', activity_class_code = 'APC',
     activity_type_code in ('APC', 'ASM') and effective_end_date IS NULL. Two rows.
  4. Carried permit_category, permit_class, permit_type, stt_permit_type and stt_sortorder over from
     dbo.MTB_MDE_ACTIVITY, LEFT joined on program / category / class / type.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-11
Author:		rsincero
Ticket:		PTT
Description:
Additional requirements 2. Every turnaround time is now stored in DAYS: a 'Months' row has both turnaround_time and
alt_turnaround_time multiplied by 30 and its unit rewritten to 'Days'. 144 of the 377 rows are affected. Added
CK_dbo_stdPermitTT_turnaround_time_unit to enforce it, and a pre-load check that rejects any unit spelling other than
'Days' or 'Months' with a message naming the value. Note the interaction with rule 2 of the previous round: the two
program 21 APC rows are Months rows, so their injected alt_turnaround_time of 11 is stored as 330 days -- see the units
note above, which explains the reading and how to change it.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
Rule 8 instrumentation, replacing the "TRY/CATCH and a bare THROW with no log row" decision recorded above. The reason
for that decision was that MDE_ETSReport had no logs.ExecutionLog; sql/015_logs.ExecutionLogging.sql now installs it and
the four logging procedures, so it does. RUN 015 BEFORE THIS SCRIPT.

What changed, all of it boilerplate from templates/procedure.sql except where noted:
  1. @ProcName, @StartTimeUtc, @EndTimeUtc, @ExecutionId, @KeyParameters, @Comments, @ContextMessage and @DynamicSql
     added to the DECLARE block. The four ERROR_* variables were already there and are reused.
  2. logs.uspStartExecutionLogging called as the first statement in the TRY, before any DDL.
  3. A completion UPDATE against logs.ExecutionLog after the COMMIT and after section 6, so the recorded duration and
     @Comments cover the whole build rather than the load alone.
  4. The CATCH now re-creates the row if a rollback destroyed it, then calls logs.uspRecordExecutionError, then throws
     bare as before. The rollback and the ERROR_* capture are unchanged.
  5. @Comments carries the three MERGE counts -- the same string the PRINT reports, which is now built once and used
     twice rather than formatted inline.
  6. @ContextMessage is set at each of the six phase boundaries. This is the one addition that is NOT in the template:
     the template's single unit of work needs no phase marker and this procedure's six do, because ERROR_LINE alone does
     not tell a reader which of create-table / index / descriptions / validate-units / load / units-constraint was
     running.

Behaviour on the successful path is otherwise unchanged -- same DDL, same MERGE, same counts, same PRINT, still
re-runnable and still converging to 0/0/0. The PRINTs are kept alongside the log row rather than replaced by it.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
DOCUMENTATION ONLY -- no executable change to this procedure. dbo.trg_au_updt_stdPermitTT was added to the table by
sql/030_dbo.trg_au_updt_stdPermitTT.sql, so this file now records that a trigger co-owns the audit columns the MERGE
assigns by hand, and warns against two edits that would break: deleting those assignments (they document intent and
agree with the trigger) and changing "OUTPUT ... INTO @Changes" to a bare OUTPUT, which error 334 forbids on a table
with an enabled trigger. Verified after deploying the trigger: a run with nothing changed still reports 0/0/0, and a run
against one deliberately perturbed row still reports exactly 1 updated, so the trigger's inner UPDATE does not corrupt
the OUTPUT-derived counts.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-24
Author:		rsincero
Ticket:		PTT
Description:
SQL Server 2019 compatibility. The completion UPDATE clamped ElapsedMilliseconds with LEAST (), which does not exist
before SQL Server 2022, so the procedure failed to compile on 2019. Replaced with an equivalent CASE expression, the same
form sql/015_logs.ExecutionLogging.sql now uses. No other change; nothing else in this procedure needs anything newer
than 2017 (STRING_AGG).

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER PROCEDURE dbo.uspBuildStdPermitTT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Actor        NVARCHAR (128) = ORIGINAL_LOGIN ()
          , @ActorShort   VARCHAR  (20)  = LEFT (SUSER_SNAME (), 20)
          , @NowUtc       DATETIME2      = SYSUTCDATETIME ()
          , @NowLocal     DATETIME2      = SYSDATETIME ()
          , @Inserted     INT            = 0
          , @Updated      INT            = 0
          , @SoftDeleted  INT            = 0
          , @UnsupportedList NVARCHAR (500) = NULL
          , @ErrorMsg     NVARCHAR (MAX) = NULL
          , @ErrorProc    NVARCHAR (300) = NULL
          , @ErrorNumber  INT            = NULL
          , @ErrorLine    INT            = NULL;

    -- =============================================================================================
    -- Rule 8 instrumentation. Boilerplate: copied verbatim from templates/procedure.sql. The four
    -- ERROR_* variables it also declares are above, where they already were.
    -- =============================================================================================
    -- The literal is not a fallback for odd cases; it is what the application logins actually log,
    -- because metadata visibility is denied to them. Keep it in step with the CREATE OR ALTER
    -- PROCEDURE name above.
    DECLARE @ProcName       NVARCHAR (300) = COALESCE (QUOTENAME (OBJECT_SCHEMA_NAME (@@PROCID))
                                                     + N'.' + QUOTENAME (OBJECT_NAME (@@PROCID))
                                                    , N'[dbo].[uspBuildStdPermitTT]')
          -- DATETIME2 (3), precision written out, because both are compared and subtracted against
          -- logs.ExecutionLog.StartDateUtc, which is DATETIME2 (3). A bare DATETIME2 is DATETIME2 (7)
          -- -- a different type -- so @StartTimeUtc would be rounded on the way into the start
          -- procedure and the ElapsedMilliseconds arithmetic would then run against a value the log
          -- does not hold. Note that @NowUtc and @NowLocal above are bare, and are left that way on
          -- purpose: they feed this table's own audit and tmsp columns and never logs.ExecutionLog,
          -- so widening them here would be a change to dbo.stdPermitTT's data, not to logging.
          , @StartTimeUtc   DATETIME2 (3)  = SYSUTCDATETIME ()
          , @EndTimeUtc     DATETIME2 (3)  = NULL
          , @ExecutionId    BIGINT         = NULL
          , @KeyParameters  NVARCHAR (MAX) = NULL
          , @Comments       NVARCHAR (MAX) = NULL
          , @ContextMessage NVARCHAR (MAX) = NULL
          , @DynamicSql     NVARCHAR (MAX) = NULL;

    -- Identifiers and counts ONLY -- rule 9. This procedure has no parameters; see the header for
    -- why that is stated rather than left NULL, and why the row counts are not put here.
    SET @KeyParameters = N'(none)';

    -- $action alone cannot tell a value change from a soft delete -- both are 'UPDATE' -- so the new
    -- IsDeleted value is captured alongside it.
    DECLARE @Changes TABLE (action_taken NVARCHAR (10) NOT NULL, is_deleted BIT NOT NULL);

    BEGIN TRY

        EXEC logs.uspStartExecutionLogging
              @ProcedureName          = @ProcName
            , @KeyParameters          = @KeyParameters
            , @StartDateUtc           = @StartTimeUtc
            , @ReCreatedAfterRollback = 0
            , @ExecutionLogId         = @ExecutionId OUTPUT;

        SET @ContextMessage = N'phase=create-table';

        -- =========================================================================================
        -- 1. The table. Guarded, so a second run is a no-op. Never dropped: this is a hard delete of
        --    real data and the conventions forbid it outright.
        --    Column order follows the requested field list; the audit block is appended after it.
        --    Constraint names are DF_<schema>_<tableName>_<fieldName>, which must be unique per
        --    database -- hence stdPermitTT in every one of them.
        -- =========================================================================================
        IF OBJECT_ID (N'dbo.stdPermitTT', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.stdPermitTT
            (
                -- -------------------------------------------------------------------------------
                -- Surrogate key. New identity values; neither source table has an id column.
                -- -------------------------------------------------------------------------------
                id                     BIGINT          IDENTITY (1, 1) NOT NULL,

                -- -------------------------------------------------------------------------------
                -- Natural key. project_type is part of it and is NULL for every non-Wetlands row.
                -- -------------------------------------------------------------------------------
                program_code           CHAR (2)        NOT NULL,
                activity_category_code CHAR (3)        NOT NULL,
                activity_class_code    CHAR (3)        NOT NULL,
                activity_type_code     CHAR (3)        NOT NULL,
                project_type           VARCHAR (50)    NULL,

                -- -------------------------------------------------------------------------------
                -- The standard itself. NUMERIC (8, 3) follows the earlier attempt,
                -- OIMT.mtb_standard_turnaround_time; both sources are NUMERIC (5, 0), so widening
                -- is lossless.
                -- -------------------------------------------------------------------------------
                turnaround_time        NUMERIC (8, 3)  NOT NULL,
                turnaround_time_unit   VARCHAR (25)    NOT NULL,
                effective_start_date   DATETIME2       NOT NULL,
                effective_end_date     DATETIME2       NULL,

                -- Wetlands only: the alternate standard that applies when a hearing was held.
                -- MTB_MDE_WWP_STT also has ALT1_TURNAROUND_TIME, which is dropped -- it is equal to
                -- ALT_TURNAROUND_TIME in all seven source rows, so nothing is lost.
                alt_turnaround_time    NUMERIC (8, 3)  NULL,

                -- -------------------------------------------------------------------------------
                -- Comma-separated list of ETS reference task IDs, e.g. '48' or '2017,2028'. A
                -- delimited string rather than an integer because one row has to carry two IDs.
                -- NULL, not '', means none apply -- which is 374 of the 377 rows.
                -- Kept in step with the guarded ALTER above; see the note there on why both exist.
                -- -------------------------------------------------------------------------------
                taskIDs                VARCHAR (100)   NULL,

                -- -------------------------------------------------------------------------------
                -- Descriptive fields carried over from dbo.MTB_MDE_ACTIVITY, whose primary key is
                -- exactly the four columns they are matched on, so the copy cannot fan a row out.
                -- Widths match that table; stt_sortorder follows the earlier attempt's INT rather
                -- than the source's NUMERIC (2, 0).
                -- -------------------------------------------------------------------------------
                permit_category        VARCHAR (30)    NULL,
                permit_class           VARCHAR (50)    NULL,
                permit_type            VARCHAR (100)   NULL,
                stt_permit_type        VARCHAR (100)   NULL,
                stt_sortorder          INT             NULL,

                -- -------------------------------------------------------------------------------
                -- ETS-style audit columns, as used by DSKMTB_ACTIVITY_TYPE and
                -- OIMT.mtb_standard_turnaround_time. VARCHAR (20) matches that house convention,
                -- which is why the login is truncated into it rather than stored whole; the
                -- untruncated login is in the audit*By columns below.
                -- -------------------------------------------------------------------------------
                user_last_updt         VARCHAR (20)    NOT NULL CONSTRAINT DF_dbo_stdPermitTT_user_last_updt         DEFAULT (LEFT (SUSER_SNAME (), 20)),
                tmsp_last_updt         DATETIME2       NOT NULL CONSTRAINT DF_dbo_stdPermitTT_tmsp_last_updt         DEFAULT (SYSDATETIME ()),
                user_created           VARCHAR (20)    NOT NULL CONSTRAINT DF_dbo_stdPermitTT_user_created           DEFAULT (LEFT (SUSER_SNAME (), 20)),
                tmsp_created           DATETIME2       NOT NULL CONSTRAINT DF_dbo_stdPermitTT_tmsp_created           DEFAULT (SYSDATETIME ()),

                -- -------------------------------------------------------------------------------
                -- Standard audit columns. Soft delete only; there is no hard delete.
                -- The three audit*By columns are NVARCHAR (128) -- the width of sysname, which is
                -- what DEFAULT (ORIGINAL_LOGIN ()) returns. Anything narrower makes the default
                -- itself raise a truncation error and fail the insert.
                -- -------------------------------------------------------------------------------
                IsDeleted              BIT             NOT NULL CONSTRAINT DF_dbo_stdPermitTT_IsDeleted              DEFAULT (0),
                auditDeletedBy         NVARCHAR (128)  NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditDeletedBy         DEFAULT (ORIGINAL_LOGIN ()),
                auditDeletedDateUtc    DATETIME2       NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditDeletedDateUtc    DEFAULT (SYSUTCDATETIME ()),
                auditCreatedBy         NVARCHAR (128)  NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditCreatedBy         DEFAULT (ORIGINAL_LOGIN ()),
                auditCreatedDateUtc    DATETIME2       NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditCreatedDateUtc    DEFAULT (SYSUTCDATETIME ()),
                auditModifiedBy        NVARCHAR (128)  NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditModifiedBy        DEFAULT (ORIGINAL_LOGIN ()),
                auditModifiedDateUtc   DATETIME2       NOT NULL CONSTRAINT DF_dbo_stdPermitTT_auditModifiedDateUtc   DEFAULT (SYSUTCDATETIME ()),

                CONSTRAINT PK_dbo_stdPermitTT PRIMARY KEY CLUSTERED (id),

                -- The table is applications only. Stated in the requirement, so enforced rather
                -- than left as a convention.
                CONSTRAINT CK_dbo_stdPermitTT_activity_category_code CHECK (activity_category_code = 'APP'),

                CONSTRAINT CK_dbo_stdPermitTT_effective_dates CHECK (effective_end_date IS NULL
                                                                     OR effective_end_date >= effective_start_date),

                -- Management requires every standard in days. Enforced, not assumed: a single row
                -- left in months makes every comparison against it wrong by a factor of 30, and
                -- nothing about the number itself would look out of place. On an already-deployed
                -- database this same constraint is added after the load instead -- see below.
                CONSTRAINT CK_dbo_stdPermitTT_turnaround_time_unit CHECK (turnaround_time_unit = 'Days')
            );
        END;

        SET @ContextMessage = N'phase=index';

        -- =========================================================================================
        -- 2. Natural-key index, filtered on IsDeleted = 0 so a soft-deleted row does not block
        --    re-insertion of the same key. project_type is nullable and a unique index treats NULLs
        --    as equal, which is what is wanted here: one NULL-project_type row per
        --    (program, class, type, start date).
        -- =========================================================================================
        IF NOT EXISTS (SELECT 1
                         FROM sys.indexes
                        WHERE name      = N'UX_dbo_stdPermitTT_Natural'
                          AND object_id = OBJECT_ID (N'dbo.stdPermitTT'))
        BEGIN
            CREATE UNIQUE INDEX UX_dbo_stdPermitTT_Natural
                ON dbo.stdPermitTT (program_code, activity_class_code, activity_type_code
                                  , project_type, effective_start_date)
                WHERE IsDeleted = 0;
        END;

        SET @ContextMessage = N'phase=descriptions';

        -- =========================================================================================
        -- 3. MS_Description on the table and on every column. Re-applied on every run rather than
        --    only at create time, so an improved wording actually reaches the database; the helper
        --    adds or updates, so this is idempotent.
        -- =========================================================================================
        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @Description = N'Standard turnaround time (STT) for permits and licenses, for the permit turnaround times (PTT) report. Combines dbo.MTB_MDE_STT with the Wetlands and Waterways short-cut table dbo.MTB_MDE_WWP_STT so that program 33 is no longer a special case. Applications only (activity_category_code = ''APP''). One row per program / activity class / activity type / project type / effective start date. Also carries five descriptive fields copied from dbo.MTB_MDE_ACTIVITY and a taskIDs list, so the report reads one lookup. Activity type ''XPR'' is excluded for program 33. Rebuilt by dbo.uspBuildStdPermitTT; do not edit by hand. Soft delete only -- reads must filter IsDeleted = 0.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'id', @Description = N'Surrogate key. No business meaning and no relationship to any source table: neither dbo.MTB_MDE_STT nor dbo.MTB_MDE_WWP_STT has an id column, and these values are unrelated to OIMT.mtb_standard_turnaround_time.id. The natural key is (program_code, activity_class_code, activity_type_code, project_type, effective_start_date).';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'program_code', @Description = N'Two-character ETS program code owning the standard, e.g. ''21'' Air, ''27'' Solid Waste, ''33'' Wetlands and Waterways. Taken from dbo.MTB_MDE_STT.PROGRAM_CODE, or set to ''33'' for every row sourced from dbo.MTB_MDE_WWP_STT, which has no program_code column because all of its rows are Wetlands.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'activity_category_code', @Description = N'Activity category. Always ''APP'' (application) -- the PTT report covers permits and licenses only, and a CHECK constraint enforces it. Neither source table carries this column; it comes from dbo.DSKMTB_ACTIVITY_TYPE.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'activity_class_code', @Description = N'Three-character ETS activity class code, e.g. ''ANT'' nontidal wetlands, ''ATW'' tidal wetlands. Together with activity_type_code it identifies the kind of application the standard applies to.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'activity_type_code', @Description = N'Three-character ETS activity type code, e.g. ''NTN'' New Nontidal Permit, ''T01'' 240 Day - Tidal. NOT NULL on every row. Five of the seven dbo.MTB_MDE_WWP_STT rows carry no activity type -- their standard is set at class level -- so each is expanded across every APP activity type in its class from dbo.DSKMTB_ACTIVITY_TYPE to reach this grain.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'project_type', @Description = N'Wetlands only: the project size that selects between competing standards, ''Major'' or ''Minor''. Sourced from a document attribute (PROJ_MAJOR / PROJ_MINOR) rather than from the activity type, which is why it is a separate key column. NULL on every non-Wetlands row and on the Wetlands rows whose standard is keyed by activity type instead. A lookup should read: activity_type_code = @type AND (project_type = @projectType OR project_type IS NULL).';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'turnaround_time', @Description = N'The standard itself: how long processing this kind of application is allowed to take, always in DAYS. Compared against the actual time used to decide whether the program met the standard. Where the source states a standard in months it is multiplied by a flat 30 on the way in, so 6 months is stored as 180 -- 144 of the 377 rows are converted this way. 0 means no standard is defined rather than "zero days" -- 24 rows arrive that way from dbo.MTB_MDE_STT, mostly program 27 class APJ Modify -- and consumers must not treat 0 as a deadline.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'turnaround_time_unit', @Description = N'Unit that turnaround_time and alt_turnaround_time are expressed in. Always ''Days'', enforced by CK_dbo_stdPermitTT_turnaround_time_unit: management requires every standard in days, so the 144 source rows stated in months are converted at a flat 30 days per month during the load. The column is retained rather than dropped because it is one of the requested fields and because a consumer should not have to assume the unit. The sources still hold both ''Days'' and ''Months''; any other spelling stops the load with an error naming it.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'effective_start_date', @Description = N'First date this standard applies. Part of the natural key: a standard that changes over time is a new row, not an edit. Selection is by the date the application was RECEIVED, not the current date, which is why superseded rows are retained.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'effective_end_date', @Description = N'Last date this standard applies. NULL means still in force -- a lookup uses "received BETWEEN effective_start_date AND ISNULL (effective_end_date, current date)". A CHECK constraint requires it to be on or after effective_start_date.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'alt_turnaround_time', @Description = N'Alternate standard that replaces turnaround_time when a hearing was held, in DAYS: for tidal wetlands (class ATW) a 240-day standard becomes 325 days if a hearing date is present and the application was received after 2012-01-01. NULL where no alternate applies, which is most rows. Two exceptions to "Wetlands only": the program 21 class APC rows still in force, where 11 is injected by requirement and -- because those rows are stated in months -- converted to 330 days on the same basis as the row it belongs to. dbo.MTB_MDE_STT has no equivalent column of its own.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'taskIDs', @Description = N'Comma-separated list of ETS reference task IDs that this standard is measured against, with no spaces -- ''48'', ''2017,2028''. A delimited string rather than an integer because one row carries two IDs; split it with STRING_SPLIT when joining to a task list. NULL (not an empty string) means no task IDs apply, which is true of 374 of the 377 rows. Set to ''48'' for the Wetlands row whose alternate standard differs from its standard, and to ''2017,2028'' for the two open-ended program 21 class APC rows.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'permit_category', @Description = N'Reporting category of the permit, e.g. ''Permits To Construct'', ''Tidal''. Copied from dbo.MTB_MDE_ACTIVITY.PERMIT_CATEGORY, matched on program / activity category / activity class / activity type -- exactly that table''s primary key, so the copy cannot duplicate a row. NULL if the activity type is not in dbo.MTB_MDE_ACTIVITY; the join is a LEFT join so a missing descriptor never costs the row its turnaround standard.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'permit_class', @Description = N'Class of permit action, e.g. ''New'', ''Renew'', ''Modify''. Copied from dbo.MTB_MDE_ACTIVITY.PERMIT_CLASS. Note that the 24 rows with turnaround_time = 0 are mostly permit_class ''Modify''.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'permit_type', @Description = N'Descriptive permit type, e.g. ''APA'', ''Synthetic Minor-APA'', ''240-Day''. Copied from dbo.MTB_MDE_ACTIVITY.PERMIT_TYPE. This is the detailed label; stt_permit_type is the coarser one the PTT report groups by.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'stt_permit_type', @Description = N'Permit type as the standard-turnaround-time report groups it, which is coarser than permit_type -- both program 21 APC/APC (''APA'') and APC/ASM (''Synthetic Minor-APA'') roll up to ''APA''. Copied from dbo.MTB_MDE_ACTIVITY.STT_PERMIT_TYPE. NULL where that table leaves it unset, which includes the Wetlands rows.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'stt_sortorder', @Description = N'Display order for the PTT report, 0 to 31 today. Copied from dbo.MTB_MDE_ACTIVITY.STT_SORTORDER and widened from NUMERIC (2, 0) to INT to match the earlier attempt, OIMT.mtb_standard_turnaround_time. Not unique and not a key -- several activity types share a position -- so a report ordering by it needs a tie-breaker.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'user_last_updt', @Description = N'ETS-style audit: login that last changed this row, truncated to 20 characters to match the house convention used by DSKMTB_ACTIVITY_TYPE and OIMT.mtb_standard_turnaround_time. Set by dbo.uspBuildStdPermitTT, so it identifies whoever ran the rebuild, not an end user. auditModifiedBy holds the same login untruncated.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'tmsp_last_updt', @Description = N'ETS-style audit: server local time this row last changed. Moves only when a value actually changed, not on every rebuild. auditModifiedDateUtc is the same event in UTC.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'user_created', @Description = N'ETS-style audit: login that inserted this row, truncated to 20 characters. Set by dbo.uspBuildStdPermitTT, so it identifies whoever ran the rebuild that first saw this key.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'tmsp_created', @Description = N'ETS-style audit: server local time this row was inserted. auditCreatedDateUtc is the same event in UTC.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'IsDeleted', @Description = N'Soft-delete flag. 1 = deleted, 0 = active. Set to 1 when a key stops appearing in the source tables; rows are never removed. All reads must filter IsDeleted = 0, and the natural-key unique index is filtered the same way.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditDeletedBy', @Description = N'Login that soft-deleted the row. Meaningful only when IsDeleted = 1; carries the DEFAULT until then.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditDeletedDateUtc', @Description = N'UTC timestamp of the soft delete. Meaningful only when IsDeleted = 1. Preserved once set: the soft-delete branch of the rebuild is guarded by IsDeleted = 0, so a later run cannot overwrite it.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditCreatedBy', @Description = N'Untruncated login that inserted the row, from ORIGINAL_LOGIN (). user_created holds the same value truncated to the 20-character ETS convention.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditCreatedDateUtc', @Description = N'UTC timestamp of row insert.';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditModifiedBy', @Description = N'Untruncated login that last modified the row, from ORIGINAL_LOGIN ().';

        EXEC util.uspSetObjectDescription @SchemaName = N'dbo', @ObjectType = N'TABLE', @ObjectName = N'stdPermitTT'
           , @ColumnName = N'auditModifiedDateUtc', @Description = N'UTC timestamp of last modification. The DEFAULT fires on INSERT only, so the rebuild sets this column explicitly on both its UPDATE branches.';

        SET @ContextMessage = N'phase=validate-units';

        -- =========================================================================================
        -- 4. Unit sanity check, BEFORE the transaction opens and before anything is written.
        --    The conversion below understands 'Days' and 'Months' and nothing else. If a third
        --    spelling ever appears, the CASE would fall through to a multiplier of 1 and quietly
        --    store, say, "3" for three weeks as though it were three days -- a number that looks
        --    entirely reasonable and is wrong by a factor of seven. So the load refuses to start,
        --    and says which value it did not recognise. NULL is caught too; ISNULL cannot be used
        --    for the test itself because a NULL fails NOT IN silently.
        -- =========================================================================================
        DECLARE @UnsupportedUnits INT = 0;

        SELECT @UnsupportedUnits = COUNT (*)
             , @UnsupportedList  = STRING_AGG (ISNULL (u.unit, N'(null)'), N', ')
          FROM (
                SELECT DISTINCT CONVERT (NVARCHAR (25), TURNAROUND_TIME_UNIT) AS unit FROM dbo.MTB_MDE_STT
                UNION
                SELECT DISTINCT CONVERT (NVARCHAR (25), TURNAROUND_TIME_UNIT) FROM dbo.MTB_MDE_WWP_STT
               ) AS u
         WHERE u.unit IS NULL
            OR u.unit NOT IN (N'Days', N'Months');

        IF @UnsupportedUnits > 0
        BEGIN
            SET @ErrorMsg = CONCAT (N'dbo.uspBuildStdPermitTT: cannot convert to days -- '
                                  , @UnsupportedUnits
                                  , N' unrecognised turnaround_time_unit value(s) in the source tables: '
                                  , @UnsupportedList
                                  , N'. Only ''Days'' and ''Months'' are understood. Add the conversion '
                                  , N'factor to the load before re-running; nothing has been written.');
            THROW 50001, @ErrorMsg, 1;
        END;

        SET @ContextMessage = N'phase=load';

        -- =========================================================================================
        -- 5. The load. Only this is transactional -- the DDL above is not, so a failure here cannot
        --    leave a half-created table behind.
        -- =========================================================================================
        BEGIN TRANSACTION;

        WITH src AS
        (
            -- Every program except Wetlands. The join to the activity type lookup supplies
            -- activity_category_code, which dbo.MTB_MDE_STT does not carry; it is 1:1 and does not
            -- fan out, because (PROGRAM_CODE, ACTIVITY_CLASS_CODE, ACTIVITY_TYPE_CODE) is unique in
            -- DSKMTB_ACTIVITY_TYPE. All 313 rows presently match and all are 'APP', so the filter
            -- removes nothing today -- it is scope, not a no-op to be deleted.
            SELECT  s.PROGRAM_CODE                              AS program_code
                  , a.ACTIVITY_CATEGORY_CODE                    AS activity_category_code
                  , s.ACTIVITY_CLASS_CODE                       AS activity_class_code
                  , s.ACTIVITY_TYPE_CODE                        AS activity_type_code
                  , CONVERT (VARCHAR (50),   NULL)              AS project_type
                    -- Everything is stored in days. 144 of these rows say 'Months'; o.unit_factor is
                    -- 30 for those and 1 for the rest.
                  , CONVERT (NUMERIC (8, 3), s.TURNAROUND_TIME * o.unit_factor) AS turnaround_time
                  , CONVERT (VARCHAR (25), 'Days')              AS turnaround_time_unit
                  , s.EFFECTIVE_START_DATE                      AS effective_start_date
                  , s.EFFECTIVE_END_DATE                        AS effective_end_date
                    -- The only non-Wetlands use of alt_turnaround_time. dbo.MTB_MDE_STT has no such
                    -- column, so the 11 is injected by rule 2 rather than copied; every other row
                    -- from this branch stays NULL.
                    -- The 11 is multiplied by o.unit_factor like everything else, so on these
                    -- 'Months' rows it means 11 months and is stored as 330 days. That reading is
                    -- explained in the units note in the header -- change the factor here to 1 if
                    -- the 11 was meant as days.
                  , CASE WHEN o.is_apc_override = 1
                         THEN CONVERT (NUMERIC (8, 3), 11 * o.unit_factor)
                         ELSE CONVERT (NUMERIC (8, 3), NULL)
                    END                                         AS alt_turnaround_time
                  , CASE WHEN o.is_apc_override = 1
                         THEN CONVERT (VARCHAR (100), '2017,2028')
                         ELSE CONVERT (VARCHAR (100), NULL)
                    END                                         AS taskIDs
                  , b.PERMIT_CATEGORY                           AS permit_category
                  , b.PERMIT_CLASS                              AS permit_class
                  , b.PERMIT_TYPE                               AS permit_type
                  , b.STT_PERMIT_TYPE                           AS stt_permit_type
                  , CONVERT (INT, b.STT_SORTORDER)              AS stt_sortorder
              FROM dbo.MTB_MDE_STT          AS s
              JOIN dbo.DSKMTB_ACTIVITY_TYPE AS a
                ON  a.PROGRAM_CODE          = s.PROGRAM_CODE
                AND a.ACTIVITY_CLASS_CODE   = s.ACTIVITY_CLASS_CODE
                AND a.ACTIVITY_TYPE_CODE    = s.ACTIVITY_TYPE_CODE

              -- Rule 3. LEFT, not INNER: a type missing from dbo.MTB_MDE_ACTIVITY must still keep
              -- its turnaround standard and simply carry NULL descriptors. All 313 match today.
              LEFT JOIN dbo.MTB_MDE_ACTIVITY AS b
                ON  b.PROGRAM_CODE           = s.PROGRAM_CODE
                AND b.ACTIVITY_CATEGORY_CODE = a.ACTIVITY_CATEGORY_CODE
                AND b.ACTIVITY_CLASS_CODE    = s.ACTIVITY_CLASS_CODE
                AND b.ACTIVITY_TYPE_CODE     = s.ACTIVITY_TYPE_CODE

              -- Rule 2, written ONCE. It drives two output columns, and two copies of a four-part
              -- predicate is two things to keep in step. effective_end_date IS NULL is what
              -- confines it to the standard currently in force and leaves the superseded
              -- 1970..2021-06-30 rows untouched.
              -- Both derived values live here so each is written once. unit_factor is the months-to-
              -- days conversion; an unrecognised unit cannot reach this point, because the check
              -- above stops the load first.
              CROSS APPLY (SELECT CONVERT (BIT, CASE WHEN s.PROGRAM_CODE       = '21'
                                                      AND s.ACTIVITY_CLASS_CODE = 'APC'
                                                      AND s.ACTIVITY_TYPE_CODE IN ('APC', 'ASM')
                                                      AND s.EFFECTIVE_END_DATE IS NULL
                                                     THEN 1 ELSE 0 END) AS is_apc_override
                                , CASE WHEN s.TURNAROUND_TIME_UNIT = 'Months' THEN 30 ELSE 1 END
                                      AS unit_factor) AS o

             WHERE a.ACTIVITY_CATEGORY_CODE = 'APP'
               -- The conflict rule: for program 33 the Wetlands table wins, so program 33 is
               -- excluded here. No such row exists today; see the header.
               AND s.PROGRAM_CODE          <> '33'

            UNION ALL

            -- Wetlands (program 33) from the short-cut table. The same join does real work here: it
            -- expands a class-level row -- one with no ACTIVITY_TYPE_CODE, keyed by PROJECT_TYPE --
            -- across every APP activity type in its class, and passes a row that already names its
            -- type straight through. 7 source rows become 66.
            SELECT  '33'
                  , a.ACTIVITY_CATEGORY_CODE
                  , w.ACTIVITY_CLASS_CODE
                  , a.ACTIVITY_TYPE_CODE
                  , w.PROJECT_TYPE
                    -- Same conversion as the branch above. Every Wetlands row is in days today, so
                    -- unit_factor is 1 throughout and this is currently a no-op -- it is here so a
                    -- month-based Wetlands standard cannot slip through unconverted later.
                  , CONVERT (NUMERIC (8, 3), w.TURNAROUND_TIME * o.unit_factor)
                  , CONVERT (VARCHAR (25), 'Days')
                  , w.EFFECTIVE_START_DATE
                  , w.EFFECTIVE_END_DATE
                  , CONVERT (NUMERIC (8, 3), w.ALT_TURNAROUND_TIME * o.unit_factor)
                    -- Rule 1. Deliberately a test that the two standards DIFFER, not that an
                    -- alternate exists: if ALT_TURNAROUND_TIME were ever NULL the comparison is
                    -- UNKNOWN and taskIDs stays NULL, which is the right answer. One row qualifies
                    -- today -- class ATW, type T01, 240 against 325. Tested on the RAW values, which
                    -- is equivalent to testing the converted ones: both sides of the comparison scale
                    -- by the same unit_factor, so the conversion cannot change the answer.
                  , CASE WHEN w.TURNAROUND_TIME <> w.ALT_TURNAROUND_TIME
                         THEN CONVERT (VARCHAR (100), '48')
                         ELSE CONVERT (VARCHAR (100), NULL)
                    END
                  , b.PERMIT_CATEGORY
                  , b.PERMIT_CLASS
                  , b.PERMIT_TYPE
                  , b.STT_PERMIT_TYPE
                  , CONVERT (INT, b.STT_SORTORDER)
              FROM dbo.MTB_MDE_WWP_STT      AS w
              JOIN dbo.DSKMTB_ACTIVITY_TYPE AS a
                ON  a.PROGRAM_CODE           = '33'
                AND a.ACTIVITY_CATEGORY_CODE = 'APP'
                AND a.ACTIVITY_CLASS_CODE    = w.ACTIVITY_CLASS_CODE
                AND (w.ACTIVITY_TYPE_CODE IS NULL
                     OR w.ACTIVITY_TYPE_CODE = a.ACTIVITY_TYPE_CODE)

              -- Rule 3, as in the branch above.
              LEFT JOIN dbo.MTB_MDE_ACTIVITY AS b
                ON  b.PROGRAM_CODE           = '33'
                AND b.ACTIVITY_CATEGORY_CODE = 'APP'
                AND b.ACTIVITY_CLASS_CODE    = w.ACTIVITY_CLASS_CODE
                AND b.ACTIVITY_TYPE_CODE     = a.ACTIVITY_TYPE_CODE

              CROSS APPLY (SELECT CASE WHEN w.TURNAROUND_TIME_UNIT = 'Months' THEN 30 ELSE 1 END
                                      AS unit_factor) AS o

               -- The XPR exclusion. It belongs to the EXPANSION, not to the source: no
               -- MTB_MDE_WWP_STT row names XPR, but XPR is an APP type in class ATW, so expanding
               -- the class-level ATW rows invented an XPR / Major and an XPR / Minor standard.
               -- Confined to this branch, so an XPR in another program would keep its standard.
             WHERE a.ACTIVITY_TYPE_CODE <> 'XPR'
        )
        MERGE dbo.stdPermitTT AS t
        USING src AS s
           ON  t.program_code         = s.program_code
           AND t.activity_class_code  = s.activity_class_code
           AND t.activity_type_code   = s.activity_type_code
           AND t.effective_start_date = s.effective_start_date
           -- project_type is nullable, so "=" alone would never match two NULLs.
           AND (t.project_type = s.project_type
                OR (t.project_type IS NULL AND s.project_type IS NULL))
           -- Soft-deleted rows are excluded from matching, which is what lets a resurrected key
           -- insert a fresh row instead of colliding on the filtered unique index.
           AND t.IsDeleted            = 0

        WHEN NOT MATCHED BY TARGET THEN
            INSERT (program_code, activity_category_code, activity_class_code, activity_type_code
                  , project_type, turnaround_time, turnaround_time_unit
                  , effective_start_date, effective_end_date, alt_turnaround_time
                  , taskIDs, permit_category, permit_class, permit_type, stt_permit_type, stt_sortorder
                  , user_last_updt, tmsp_last_updt, user_created, tmsp_created)
            VALUES (s.program_code, s.activity_category_code, s.activity_class_code, s.activity_type_code
                  , s.project_type, s.turnaround_time, s.turnaround_time_unit
                  , s.effective_start_date, s.effective_end_date, s.alt_turnaround_time
                  , s.taskIDs, s.permit_category, s.permit_class, s.permit_type, s.stt_permit_type, s.stt_sortorder
                  , @ActorShort, @NowLocal, @ActorShort, @NowLocal)

        -- Converge, do not re-apply. EXCEPT compares NULL to NULL as equal, which "<>" does not, so
        -- an unchanged row with a NULL effective_end_date or alt_turnaround_time is left alone
        -- instead of being rewritten -- and tmsp_last_updt does not drift on every rebuild.
        -- activity_category_code is absent because the CHECK constraint fixes it at 'APP'.
        -- The five descriptive columns are compared too, so editing a permit_class or a sort order in
        -- dbo.MTB_MDE_ACTIVITY and re-running propagates the change instead of leaving a stale copy.
        WHEN MATCHED AND EXISTS (SELECT t.turnaround_time, t.turnaround_time_unit
                                      , t.effective_end_date, t.alt_turnaround_time, t.taskIDs
                                      , t.permit_category, t.permit_class, t.permit_type
                                      , t.stt_permit_type, t.stt_sortorder
                                 EXCEPT
                                 SELECT s.turnaround_time, s.turnaround_time_unit
                                      , s.effective_end_date, s.alt_turnaround_time, s.taskIDs
                                      , s.permit_category, s.permit_class, s.permit_type
                                      , s.stt_permit_type, s.stt_sortorder)
            THEN UPDATE
                SET t.turnaround_time      = s.turnaround_time
                  , t.turnaround_time_unit = s.turnaround_time_unit
                  , t.effective_end_date   = s.effective_end_date
                  , t.alt_turnaround_time  = s.alt_turnaround_time
                  , t.taskIDs              = s.taskIDs
                  , t.permit_category      = s.permit_category
                  , t.permit_class         = s.permit_class
                  , t.permit_type          = s.permit_type
                  , t.stt_permit_type      = s.stt_permit_type
                  , t.stt_sortorder        = s.stt_sortorder
                  , t.user_last_updt       = @ActorShort
                  , t.tmsp_last_updt       = @NowLocal
                  , t.auditModifiedBy      = @Actor
                  , t.auditModifiedDateUtc = @NowUtc

        -- Soft delete, never a hard one. Guarded on IsDeleted = 0 so a row already soft-deleted on
        -- an earlier run keeps its original auditDeleted* values.
        WHEN NOT MATCHED BY SOURCE AND t.IsDeleted = 0 THEN
            UPDATE
                SET t.IsDeleted            = 1
                  , t.auditDeletedBy       = @Actor
                  , t.auditDeletedDateUtc  = @NowUtc
                  , t.auditModifiedBy      = @Actor
                  , t.auditModifiedDateUtc = @NowUtc
                  , t.user_last_updt       = @ActorShort
                  , t.tmsp_last_updt       = @NowLocal

        OUTPUT $action, inserted.IsDeleted INTO @Changes (action_taken, is_deleted);

        IF @@TRANCOUNT > 0
        BEGIN
            COMMIT TRANSACTION;
        END;

        -- SUM (... ELSE 0), not COUNT (CASE ... THEN 1 END): COUNT over an expression that is NULL
        -- for the non-matching rows raises "Null value is eliminated by an aggregate" on every run,
        -- which is a warning a developer then has to investigate to discover it means nothing.
        SELECT @Inserted    = SUM (CASE WHEN action_taken = N'INSERT'                    THEN 1 ELSE 0 END)
             , @Updated     = SUM (CASE WHEN action_taken = N'UPDATE' AND is_deleted = 0 THEN 1 ELSE 0 END)
             , @SoftDeleted = SUM (CASE WHEN action_taken = N'UPDATE' AND is_deleted = 1 THEN 1 ELSE 0 END)
          FROM @Changes;

        -- SUM returns NULL over an empty table variable; a converged rebuild reports zeros.
        SELECT @Inserted    = ISNULL (@Inserted,    0)
             , @Updated     = ISNULL (@Updated,     0)
             , @SoftDeleted = ISNULL (@SoftDeleted, 0);

        SET @ContextMessage = CONCAT (N'phase=units-constraint, inserted=', @Inserted
                                    , N', updated=', @Updated, N', soft-deleted=', @SoftDeleted);

        -- =========================================================================================
        -- 6. The units CHECK constraint, added AFTER the load and not with the rest of the DDL.
        --    That placement is forced: on a database that predates the units requirement the table
        --    still holds 144 'Months' rows when this procedure starts, and ALTER TABLE ADD CHECK
        --    validates existing data, so adding it earlier would fail on the very run that fixes
        --    those rows. By this point the load has converted them and the constraint applies
        --    cleanly. A fresh database already has it from the CREATE TABLE above, so the guard
        --    makes this a no-op there and on every later run.
        --    Outside the transaction deliberately -- it is DDL, and the load is already committed.
        -- =========================================================================================
        IF NOT EXISTS (SELECT 1
                         FROM sys.check_constraints
                        WHERE name = N'CK_dbo_stdPermitTT_turnaround_time_unit')
        BEGIN
            ALTER TABLE dbo.stdPermitTT
                ADD CONSTRAINT CK_dbo_stdPermitTT_turnaround_time_unit
                    CHECK (turnaround_time_unit = 'Days');
        END;

        -- The three counts are the whole story of the run, so they are what @Comments carries.
        SET @Comments = CONCAT (@Inserted,    N' inserted, '
                              , @Updated,     N' updated, '
                              , @SoftDeleted, N' soft-deleted.');

        -- PRINT rather than a result set, so INSERT ... EXEC callers are not broken. Kept alongside
        -- the log row, not replaced by it: the developer running this by hand reads the output, and
        -- a caller that cannot see logs.ExecutionLog still gets the report.
        PRINT CONCAT (N'dbo.stdPermitTT: ', @Comments);

        -- Completion. Deliberately after the COMMIT, and after section 6, so @Comments and the
        -- elapsed time cover the whole build rather than the load alone. If the COMMIT succeeds and
        -- then this UPDATE fails, control reaches the CATCH with XACT_STATE () = 0 and the call is
        -- reported as failed with its work committed -- survivable only because this procedure is
        -- idempotent, which it is: the load is a MERGE and every DDL step is guarded.
        -- auditModifiedDateUtc is set explicitly because its DEFAULT fires on INSERT only.
        SET @EndTimeUtc = SYSUTCDATETIME ();

        IF @ExecutionId IS NOT NULL
        BEGIN
            UPDATE logs.ExecutionLog
               SET EndDateUtc           = @EndTimeUtc
                   -- Clamped to int range with a CASE rather than LEAST (), which is SQL Server 2022+;
                   -- this procedure targets 2019. Same form as logs.uspRecordExecutionErrorUpdate.
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
        -- capture them before doing anything else -- including before the rollback.
        SELECT @ErrorNumber = ERROR_NUMBER ()
             , @ErrorProc   = ERROR_PROCEDURE ()
             , @ErrorLine   = ERROR_LINE ()
             , @ErrorMsg    = ERROR_MESSAGE ()
                            + N' (error ' + CAST (ERROR_NUMBER () AS NVARCHAR (11))
                            + N', line '  + CAST (ERROR_LINE ()   AS NVARCHAR (11)) + N')';

        -- One test, not two: XACT_ABORT ON makes XACT_STATE () = -1 the common case, and -1 and 1
        -- both need the same unqualified rollback. This procedure opened the transaction, so it is
        -- this procedure's to end.
        IF XACT_STATE () <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        -- The rollback above may have destroyed the row logs.uspStartExecutionLogging wrote. Put it
        -- back, with the ORIGINAL @StartTimeUtc, or the only unrecorded executions would be the
        -- failures. WHEN that actually happens is narrower than it looks: the start call is before
        -- BEGIN TRANSACTION, so a call made with no ambient transaction wrote its row in autocommit
        -- and the rollback cannot reach it. The row is lost only when this procedure was called
        -- INSIDE an already-open transaction -- from another procedure, or from a .NET
        -- BeginTransaction -- because ROLLBACK unwinds the outermost transaction, not the inner one.
        -- The nested TRY is required because the start procedure does not swallow; an error escaping
        -- here would replace the error being reported. Nothing to do in its CATCH -- @ExecutionId is
        -- left NULL and logs.uspRecordExecutionError then writes an orphan row that explains itself.
        BEGIN TRY
            IF @ExecutionId IS NULL
               OR NOT EXISTS (SELECT 1
                                FROM logs.ExecutionLog
                               WHERE ExecutionLogId = @ExecutionId)
            BEGIN
                EXEC logs.uspStartExecutionLogging
                      @ProcedureName          = @ProcName
                    , @KeyParameters          = @KeyParameters
                    , @StartDateUtc           = @StartTimeUtc
                    , @ReCreatedAfterRollback = 1
                    , @ExecutionLogId         = @ExecutionId OUTPUT;
            END;
        END TRY
        BEGIN CATCH
            SET @ExecutionId = NULL;
        END CATCH;

        -- Swallows everything by design, so this call cannot mask the error below it. @ContextMessage
        -- carries the phase the build reached; @DynamicSql stays NULL because this procedure runs no
        -- dynamic SQL.
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

        -- Kept as well as the log row, for the developer running this by hand: a PRINT is visible
        -- immediately where a row in logs.ExecutionLog has to be gone and looked for.
        PRINT CONCAT (N'dbo.uspBuildStdPermitTT failed in ', ISNULL (@ErrorProc, N'(none)')
                    , N' during ', ISNULL (@ContextMessage, N'(unknown phase)')
                    , N': ', @ErrorMsg);

        -- Bare, so the ORIGINAL error number reaches the caller. The leading semicolon is required:
        -- a bare THROW immediately after BEGIN is a syntax error.
        ;THROW;

    END CATCH;

    RETURN 0;
END;
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'PROCEDURE'
    , @ObjectName  = N'uspBuildStdPermitTT'
    , @Description = N'Creates dbo.stdPermitTT if absent, then loads it from dbo.MTB_MDE_STT and the Wetlands short-cut table dbo.MTB_MDE_WWP_STT, expanding the latter''s class-level rows to activity-type grain, excluding activity type ''XPR'', applying the taskIDs and alt_turnaround_time rules, and copying five descriptive fields from dbo.MTB_MDE_ACTIVITY. Applications only. Re-runnable; soft-deletes keys that leave the sources.';
GO

IF DATABASE_PRINCIPAL_ID (N'db_executor') IS NOT NULL
BEGIN
    GRANT EXECUTE ON dbo.uspBuildStdPermitTT TO db_executor;
END;
GO
