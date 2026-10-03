-- SET XACT_ABORT ON sits ABOVE the header block deliberately. The GO on the next line ends the batch, and
-- sys.sql_modules stores only the batch that contains CREATE -- so a header placed AFTER this GO is invisible
-- to anyone reading the view out of the database through sp_helptext, OBJECT_DEFINITION, or SSMS
-- "Script as CREATE", which is where a maintainer actually reads it. The header has to be the LAST thing
-- before CREATE with no batch separator between them.
SET XACT_ABORT ON;
-- And QUOTED_IDENTIFIER. sqlcmd defaults it OFF where every other client defaults it ON, and the setting is
-- BAKED IN at CREATE time. This view runs no DML, so error 1934 is not reachable through it -- but the setting
-- is also part of the SET options a plan is cached under, and validate-sql.py rejects a script that CREATEs an
-- object without both. Consistency across every module in the project is worth more than the one exemption.
SET QUOTED_IDENTIFIER ON;
GO

-- dbo.stdPermitTT is NOT created by deploying a script: sql/020 deploys a PROCEDURE that creates the table on
-- its first EXECUTE. So a fresh database reaches this script with no table, and the native failure is
-- "Invalid object name 'dbo.stdPermitTT'", which does not tell the operator what to do about it. This does.
IF OBJECT_ID (N'dbo.stdPermitTT', N'U') IS NULL
BEGIN
    ;THROW 50000, N'dbo.stdPermitTT does not exist yet. Run sql/020_dbo.uspBuildStdPermitTT.sql and then EXEC dbo.uspBuildStdPermitTT, which creates the table, before running this script.', 1;
END;
GO

-- dbo.MtbApprovalTaskList is the second local dependency, and unlike stdPermitTT it is created by deploying its
-- script rather than by executing a procedure. Named here for the same reason: CREATE VIEW would otherwise fail
-- with a bare "Invalid object name", which does not say which script to run. An EMPTY table is a different and
-- quieter failure that this cannot catch -- the view would deploy and return NULL closedDate / closedType on all
-- 191,603 rows -- so sql/035 asserts its own source and reports its load counts.
IF OBJECT_ID (N'dbo.MtbApprovalTaskList', N'U') IS NULL
BEGIN
    ;THROW 50000, N'dbo.MtbApprovalTaskList does not exist yet. Run sql/035_dbo.MtbApprovalTaskList.sql, which creates AND populates it, before running this script. The view reads it to decide which reference tasks close an activity.', 1;
END;
GO

-- dbo.AiExclusionList is the third local dependency and the only one this project does not create: it is
-- maintained outside this repository. Named here for the same reason as the two above. An EMPTY table is again
-- the quiet case -- the view deploys and simply excludes nothing.
IF OBJECT_ID (N'dbo.AiExclusionList', N'U') IS NULL
BEGIN
    ;THROW 50000, N'dbo.AiExclusionList does not exist in this database. The view reads it to exclude test and functional Agency Interests by Master_AI_Id; create it, even empty, before running this script.', 1;
END;
GO

-- The three EPAL_ISSI tables are reached through local synonyms, which is the ONLY permitted access path --
-- no three-part names. A synonym is a name with no validation behind it: it survives the drop or rename of
-- its target and the failure surfaces only when something queries through it. CREATE VIEW resolves it, so a
-- missing or broken synonym fails this deploy with "Invalid object name" naming the SYNONYM rather than the
-- table, which sends the reader looking in the wrong database. This names all three at once instead.
DECLARE @MissingSynonyms NVARCHAR (MAX) =
        STUFF ((SELECT N', ' + n.RequiredName
                  FROM (VALUES (N'dbo.DSK_CENTRAL_FILE')
                             , (N'dbo.ACTIVITY_TASK_LIST')
                             , (N'dbo.DSK_DOCUMENT_ATTRIBUTE')) AS n (RequiredName)
                 WHERE OBJECT_ID (n.RequiredName, N'SN') IS NULL
                 ORDER BY n.RequiredName
                   FOR XML PATH (N''), TYPE).value (N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

IF @MissingSynonyms IS NOT NULL
BEGIN
    DECLARE @SynonymMessage NVARCHAR (2048) =
            CONCAT (N'This view reads EPAL_ISSI through local synonyms and these are missing: ', @MissingSynonyms
                  , N'. Create them in this database before deploying -- do NOT "fix" this by putting a three-part EPAL_ISSI name in the view, which the project conventions forbid.');
    ;THROW 50000, @SynonymMessage, 1;
END;
GO

/***********************************************************************************************************************
ObjectName:   dbo.vwPermitTurnaroundPerformance
Author:       rsincero
CreateDate:   2026-09-22
========================================================================================================================
Description:

One row per EPAL_ISSI permit-family activity, carrying the turnaround time it actually consumed beside the published
standard that applies to it. Joins the activity to dbo.stdPermitTT on the standard in force when the application was
received, so that a permit received in 2015 is measured against the 2015 standard rather than today's.

Activity here means a row of dbo.DSK_CENTRAL_FILE under ACTIVITY_CATEGORY_CODE = 'APP' -- permits, licenses,
accreditations and their kin -- which has both key tasks: reference task 1000000000 (application received) with a
completed date, and reference task 1000000002 (the consumption clock).

Both ends of the clock are exposed as dates -- application_received and approval_issued -- alongside both published
values from the standard, turnaround_time and alt_turnaround_time, beside the std_turnaround_time the rule selected
from them. So every input to the comparison is visible on the row and none of it has to be inferred, with one
documented exception: on 2,055 Wetlands rows approval_issued is the completed date of reference task 3037 rather than
of 1000000002, and the raw 1000000002 date is not projected. See THE WETLANDS EXCEPTION in the Notes.

ISSUED AND CLOSED ARE TWO DIFFERENT QUESTIONS, and closedDate / closedType answer the second. An activity stops when
any task flagged IsCloseTask in dbo.MtbApprovalTaskList completes -- withdrawn, denied, voided, administratively
closed, approval not required -- and that can happen whether or not an approval was ever issued. So the two states
are independent, not a sequence: 160,105 activities are issued and not closed, 6,095 are closed and never issued,
9,345 are BOTH, and 16,058 are neither, which is the only genuinely in-flight population. A backlog query that tests
approval_issued IS NULL alone overstates the queue by 6,095 dead applications.

The four columns the match is made on -- program_code, activity_category_code, activity_class_code,
activity_type_code -- are carried from the ACTIVITY as well, which is what makes the coverage gap diagnosable rather
than merely countable: on a row that matched no standard they are the combination stdPermitTT is missing.
master_ai_id carries the Agency Interest, the regulated site, for grouping a performance question by site.

CONSUMED TIME COMES IN TWO COLUMNS AND THEY ARE DIFFERENT MEASURES. days_used_qty is EPAL_ISSI's own working-time
clock, passed through untouched and NULL on 63% of rows because that is how the source holds it. calendar_days_qty is
this view's own wall-clock arithmetic -- approval_issued, or today for an activity still running, minus
application_received -- computed on all 159,020 rows that have a standard. The second covers 2.9x the activities at the
cost of not being the measure the programs keep, and the two are NOT a check on each other. Pick one per report and say
which. Note that calendar_days_qty makes THE VIEW NON-DETERMINISTIC, since the 11,946 rows with no approval date grow
by a day every day, and that it goes NEGATIVE on 1,130 rows whose two dates are the wrong way round. All of this is in
the Notes and none of it is incidental.

    AND NOTE WHAT THE CLOSURE COLUMNS DO TO THAT NON-DETERMINISM: of those 11,946 rows only 5,931 are genuinely open.
    The other 6,015 are CLOSED but unissued, so their calendar_days_qty is still being measured to today and still
    growing, for an activity that stopped years ago. The column does not read closedDate, deliberately -- see the
    Notes -- so an aging report must filter on closedDate IS NULL itself.

========================================================================================================================
Requirements and Key Dependencies:

dbo.stdPermitTT -- the published standards. Created at run time by dbo.uspBuildStdPermitTT, asserted above.

dbo.MtbApprovalTaskList -- the reference list of approval tasks, created AND populated by sql/035, asserted above.
Read for one thing only: which reference task ids carry IsCloseTask = 1. THIS IS A DATA DEPENDENCY AND NOT ONLY A
SCHEMA ONE -- the set of closing tasks is read from the table at query time rather than hard-coded, so adding or
retiring one changes this view's closedDate and closedType with no redeploy. An EMPTY table deploys cleanly and
returns NULL on both columns for all 191,603 rows, which is the one failure mode the guard above cannot catch.

dbo.AiExclusionList -- Master_AI_Id values to leave out of reporting, maintained outside this project and asserted
above. Only rows with is_active = 1 exclude anything. ANOTHER DATA DEPENDENCY: adding, deleting or deactivating a row
changes this view's row count with no redeploy. 12 rows on 2026-10-01, all active -- test Agency Interests created for
TRIP and functional ones created by OIMT for data migration and for wastewater permits.

Three SYNONYMS onto EPAL_ISSI, asserted above and the only permitted access path -- dbo.DSK_CENTRAL_FILE (the
activity), dbo.ACTIVITY_TASK_LIST (its tasks), dbo.DSK_DOCUMENT_ATTRIBUTE (its attributes, including Major / Minor).
All three targets are system-versioned temporal tables, so an unadorned SELECT returns current rows only, which is what
this view wants. Adding FOR SYSTEM_TIME here would change the grain.

No grant of its own. Reads flow through the schema-level grant on SCHEMA::dbo.

========================================================================================================================
Notes:

THE MATCH RULE, IN THE ORDER IT IS APPLIED. A standard qualifies when program, activity category, activity class and
activity type all equal the activity's, the received date falls inside the standard's effective window, and the
standard's project_type either equals the activity's or is NULL. Where both a project-specific and a NULL-project_type
standard qualify, the specific one wins; where two vintages qualify, the later effective_start_date wins.

    THE project_type PREDICATE IS "AND", NOT "OR", AND THIS IS THE ONE PLACE A COPIED PATTERN WOULD BE WRONG.
    util.ufn_lookup_wwp_stt_time matches with (project_type = @pt OR activity_type_code = @atc). That OR was correct
    only while a stdPermitTT row carried one of the two and never both -- and the 2026-09-10 build EXPANDS the Wetlands
    class-level rows across dbo.DSKMTB_ACTIVITY_TYPE, so activity_type_code is now populated on every row. Under the
    legacy OR, asking about a Minor project returns the Major standard (365 days against 240). Do not repoint this view
    at that function, and do not "simplify" the predicate below to match it.

WHEN alt_turnaround_time IS USED. stdPermitTT.taskIDs is a comma-delimited list of reference task ids; when EVERY id in
that list has a task with a completed date on this activity, alt_turnaround_time replaces turnaround_time. ALL rather
than ANY is a decision recorded on 2026-09-22: the only multi-id value in the table is '2017,2028' on two program-21
rows, and it is read as one combined condition.

    THE TABLE IS COHERENT ON THIS, WHICH IS NOT OBVIOUS FROM THE COLUMN COUNTS. The 377 active standards fall into
    exactly three shapes: 311 have alt_turnaround_time NULL and no taskIDs; 63 have an alt_turnaround_time EQUAL to
    their own turnaround_time and no taskIDs; and 3 have an alt_turnaround_time that DIFFERS, each with a taskIDs value
    ('2017,2028' on two program-21 rows, '48' on one program-33 row). So alt_turnaround_time is different from
    turnaround_time only where there is a task list to select it with, and the 63 rows that carry an alternative
    without one are redundant rather than broken -- selecting their alternative would produce the same number.

    The consequence for a reader: 2,435 activities match a standard whose two values differ, and the alternative wins
    on 72 of them. The other 101,473 activities that match a standard carrying an alternative match one where the two
    values are identical, so which branch fired is unobservable from the output AND immaterial to it.

DUPLICATE KEY TASKS, and why each one is resolved differently. Neither key task is unique per activity -- up to five of
each have been seen. 744 activities carry more than one reference task 1000000002 and 197 of those disagree about
DAYS_USED_QTY. Without a deterministic pick the view would fan out and the row count would depend on the plan.

    application_received takes the MIN of COMPLETED_DATE. The earliest receipt is the one that starts the clock, and
    taking the latest would shorten every duplicated activity's measured window and could also move it into a
    different standard's effective period, changing the denominator rather than just the numerator.

    approval_issued takes the MAX of COMPLETED_DATE, the opposite end for the same reason: the last completion is the
    one that stops the clock, so MIN and MAX together give the widest window and cannot flatter the elapsed time.
    729 activities have duplicate 1000000002 tasks and 292 of those disagree about the date.

    days_used_qty takes the MAX, decided on 2026-09-22 over SUM. The duplicates read as re-created records of one task
    rather than as separate stretches of work, so MAX cannot overstate consumption where SUM would double-count it.

        days_used_qty AND approval_issued ARE INDEPENDENT AGGREGATES over the same set of tasks, so on those 292
        activities they can come from DIFFERENT task rows. That is deliberate: tying both to one row -- the row with
        the greatest days_used_qty, say -- would return a NULL approval_issued whenever that particular row happened
        to be the undated one, losing a date that demonstrably exists. Two independent maxima lose nothing, at the
        cost of the pair not being a verbatim copy of any single source row. It matters only if someone tries to
        reconcile a row here against one ACTIVITY_TASK_LIST row; reconcile against the task SET instead.

    project_type takes PROJ_MAJOR over PROJ_MINOR. 3 activities carry both attribute codes; Major is the stricter
    reading and the larger standard, so preferring it does not flatter the performance number.

THE WETLANDS EXCEPTION ON approval_issued. For program_code = '33' only, a completed reference task 3037 -- "Send
Report and Recommendation to the Board of Public Works" -- REPLACES the 1000000002 date entirely, including replacing
a NULL one. Added 2026-09-23 on instruction. Where a Wetlands activity has no completed 3037, the 1000000002 date is
used exactly as before, and the other 84,041 activities are untouched.

    THE SUBSTITUTION IS NOT VISIBLE ON THE ROW, which is the one thing to know before reconciling anything. The raw
    1000000002 date is not projected, so a substituted approval_issued is indistinguishable from an ordinary one
    without going back to ACTIVITY_TASK_LIST. 2,055 of the 107,562 Wetlands rows take it. Adding the raw date as its
    own column is a one-line change if the provenance is ever wanted on the row.

    WHAT IT MOVES, MEASURED, AND IT IS NOT NEUTRAL. Of the 2,055 substituted rows, 1,612 get an EARLIER approval date
    (the window shortens, so measured performance improves), 95 get a later one, 26 are unchanged, and 322 gain a date
    where there was none -- moving those out of the not-yet-issued population altogether. Net effect on the headline:
    Wetlands rows inside standard by the calendar measure go from 81,723 to 82,065 of 103,810, so THE EXCEPTION MAKES
    WETLANDS LOOK BETTER, by about a third of a percentage point. That is presumably the point -- the Board of Public
    Works recommendation is where the department's own control ends -- but a report comparing Wetlands to other
    programs is now comparing two different definitions of "issued", and should say so.

    MAX, not MIN, matching approval_issued's own aggregate: 17 activities carry more than one completed 3037 and the
    last completion is the one that stops the clock. Using MIN here would measure the Wetlands rows on a different
    principle from every other row in the view.

    THE PROGRAM GUARD CHANGES NO ROW TODAY and is kept anyway. All 2,080 completed 3037 tasks in this population
    belong to program 33, so restricting the rule to '33' is currently redundant. The rule as stated is about
    Wetlands rather than about task 3037, so if another program starts using that task this view must not silently
    start substituting for it -- the guard is what makes that true.

CLOSURE IS INDEPENDENT OF ISSUANCE, and closedDate / closedType exist because "has this stopped" and "was this
approved" are different questions that approval_issued alone cannot separate. An activity stops when any task with
IsCloseTask = 1 in dbo.MtbApprovalTaskList completes. 15,440 of the 191,603 activities have one.

    THE FOUR STATES, and only one of them is a backlog. Issued and not closed: 160,105. Issued AND closed: 9,345 --
    an approval was granted and the case later closed, which is ordinary and not a contradiction. Closed, never
    issued: 6,095 -- withdrawn, denied, voided, not required. Neither: 16,058, the genuinely open queue. THE TRAP IS
    THAT approval_issued IS NULL ALONE RETURNS 22,153 ROWS, overstating the live backlog by the 6,095 dead ones. Test
    closedDate IS NULL too.

    THE EARLIEST CLOSURE WINS, and the tie-break is load-bearing. 649 activities have more than one completed close
    task, and on 72 of them two or more share the SAME earliest date -- so the pick is ordered by COMPLETED_DATE then
    REFERENCE_TASK_ID. Without the second key, closedType would be chosen by whichever row the plan reached first and
    could change between two runs with no data change. closedDate is unaffected; closedType is the column that would
    wobble.

    closedType IS REPORTING-FACING TEXT FROM A MUTABLE TABLE, not a code. It is dbo.MtbApprovalTaskList.TaskDesc for
    the task that closed the activity, so editing that table's text changes what this view says. The ten values and
    their frequencies: Close Case 4,373; Approval Not Required 2,948; Administratively closed 2,333; Application
    Withdrawn 2,112; Application Voided 1,937; Application Withdrawn by the Department 697; Approval no longer needed
    684; Approval Denied 194; Application Returned 88; Registration only, Permit not required 74. GROUP BY it for a
    why-did-this-die report. Note that TaskDesc is NOT unique in that table (458 distinct descriptions over 463 rows),
    so closedType is not a substitute for the task id -- it happens to be unique across the ten closing tasks today,
    which is a property of the current data and not a guarantee.

    ADDING AN ELEVENTH CLOSE TASK CHANGES THIS VIEW WITH NO REDEPLOY. IsCloseTask is read from the table, unlike the
    1000000000 / 1000000002 / 3037 ids which are hard-coded here. That is deliberate -- the list of ways an
    application can die is reference data, not logic -- but it makes dbo.MtbApprovalTaskList a published interface of
    this view, and a one-row UPDATE there is a change to every report built on it.

    THE CLOSURE COLUMNS DO NOT FEED calendar_days_qty, and this is the sharpest edge in the current design. That
    column still measures to TODAY on any row with no approval_issued, including the 6,015 that are closed but
    unissued -- so a withdrawn 2019 application shows a calendar age that grows every night. Only 5,931 of the 11,946
    rows measured to today are genuinely open. Closing the clock on closedDate was NOT done because it was not asked
    for and because it would change calendar_days_qty on rows whose meaning nobody has agreed yet; until it is
    decided, an aging or backlog query must add  closedDate IS NULL  itself. Every backlog example below does.

    THREE SMALL DATA-QUALITY FINDINGS, none of them handled here and all of them visible now that the column exists:
    143 activities are closed BEFORE they were received, 1,447 are closed before they were issued, and 2,851 after.
    The first group is an ordering violation of the same family as the negative calendar_days_qty rows.

WHAT IS DELIBERATELY *NOT* FILTERED, both worth knowing before anyone adds a WHERE clause on top:

    EFFECTIVE_FLAG. 130,101 of the 191,603 activities are 'N' and 61,502 are 'Y'. INT_DOC_ID is the primary key of
    DSK_CENTRAL_FILE, so this is not a row-version flag with one live row per activity -- it is an attribute of the
    activity itself, and an expired or superseded permit still had a turnaround time when it was issued. Filtering it
    out would silently drop two thirds of the history from a report about how long things took.

    Activities that match no standard. 32,583 of 191,603 come through with std_turnaround_time NULL, because their
    program / class / type combination is not in stdPermitTT or the received date falls outside every effective window.
    Keeping them, decided on 2026-09-22, makes the coverage gap countable; filter with
    WHERE std_turnaround_time IS NOT NULL when only comparable rows are wanted.

TWO MEASURES OF CONSUMED TIME, IN TWO COLUMNS, AND THEY ARE NOT INTERCHANGEABLE. This is the single most important
thing to understand before using this view for a number, and the shape was settled on 2026-09-23 after a day spent
with the alternative.

    days_used_qty is EPAL_ISSI's own figure, passed through untouched: the MAX of DAYS_USED_QTY over the activity's
    reference task 1000000002 rows. It is a WORKING-TIME clock -- it can be stopped while the department waits on an
    information request -- and it is the measure the programs themselves keep. It is also NULL on 120,381 of the
    191,603 rows, 63%, and that is how the source holds the data, not something this view drops.

    calendar_days_qty is this view's own arithmetic: DATEDIFF (day, application_received,
    COALESCE (approval_issued, today)), on every row that has a standard. It is WALL-CLOCK elapsed time and it never
    stops. It is present on 159,020 rows.

    NEITHER IS A CHECK ON THE OTHER, and a row-level comparison will not reconcile. Where both exist and the activity
    has completed (49,258 rows) they agree exactly on 30,658 (62%), land within 7 days on 34,519 (70%) and within 30
    on 39,527 (80%). Where they differ, calendar_days_qty is LARGER on 18,254 and smaller on only 346 -- which is the
    right direction and is the evidence that it is a usable proxy: it makes performance look worse than the recorded
    figure does, never better, so it cannot be used to flatter a number. Across the whole view the residuals reach
    -664,712 to +730,498 days, and residuals of two thousand years are source data, not a clock.

    WHICH ONE TO REPORT is a decision for whoever owns the report, and the two give materially different answers:
    of the rows that have a standard, days_used_qty puts 43,943 of its 54,194 measurable rows inside standard (81.1%)
    while calendar_days_qty puts 119,321 of 157,890 (75.6%, negatives excluded). The second covers 2.9x the
    activities. Pick one, say which in the output, and do not average the two columns together.

WHY calendar_days_qty IS RESTRICTED TO ROWS WITH A STANDARD. 32,583 rows come through with std_turnaround_time NULL
and they get NULL here too, although both dates are present and the subtraction would succeed. The column exists to be
compared against a standard; an elapsed time with nothing to measure it against is a number someone would average by
mistake. Populating it everywhere is a one-line change -- drop the first branch of the cal apply -- if a bare elapsed
time is ever wanted on the coverage gap as well.

    THE VIEW IS NOT DETERMINISTIC, and this is the consequence most likely to bite. 11,946 of those 159,020 rows have
    no approval_issued, so calendar_days_qty is measured to SYSDATETIME () and grows by one every day. A row inside
    standard today can be outside it next month with nothing in either database having changed. For an aging or
    backlog question that is exactly right -- it is what "how long has this been sitting" means. For a published
    figure it is not: a monthly report must be MATERIALISED, selected into a table with its as-of date recorded, or it
    cannot be reproduced, and two people running it on different days will both be right and disagree. There is an
    example below. SYSDATETIME and not SYSUTCDATETIME, because this server runs UTC-4 and COMPLETED_DATE is local:
    UTC would add a spurious day every evening after 8pm local. days_used_qty is unaffected and stays reproducible,
    which is a further reason the two are kept apart rather than merged.

    calendar_days_qty GOES NEGATIVE ON 1,130 ROWS AND THIS IS DELIBERATE. Those are activities whose approval_issued
    precedes their application_received -- an ordering violation in EPAL_ISSI, since the two dates come from different
    tasks and neither is constrained against the other. The column reports what the two dates say: NULLing them would
    hide a source defect that this is the cheapest place in the estate to see, and clamping to 0 would assert the
    activity took no time, which is a claim about the data rather than an absence of one. THE COST LANDS ON THE
    CONSUMER AND IS EASY TO MISS -- a negative is <= every standard, so all 1,130 count as compliant in a naive
    calendar_days_qty <= std_turnaround_time, which is 1,130 of the 120,451 such rows. Every figure quoted in this
    header excludes them, and every example below does too. They are not randomly scattered: 515 are program 27 /
    APN / SA1 (worst -7,082 days), 104 are program 33 / ANT / LOM (worst -10,976) and 88 are program 33 / ANT / NTM,
    so this looks like a fixable upstream defect worth reporting rather than papering over. To NULL them here instead,
    add a  WHEN ... < 0 THEN NULL  branch to the cal apply.

    THE ORDERING VIOLATION IS BIGGER THAN THIS HEADER USED TO SAY. It claimed 1,240 rows with approval_issued earlier
    than application_received; that figure does not reproduce and is corrected here. Measured 2026-09-23: 3,259 rows
    are reversed on the raw timestamps and 3,082 by a whole day or more, which is the number that matters because
    DATEDIFF (day) counts date boundaries -- a same-day reversal of a few hours yields 0, not a negative. 1,130 of
    the 3,082 have a standard and so surface as a negative calendar_days_qty; the other 1,956 have none and are NULL
    here, which does not make them clean.

    THE EXTREMES ARE NOT CREDIBLE ON EITHER SIDE. days_used_qty holds 33,132 days against a program-33 standard and
    40,610 against program 44; calendar_days_qty runs to 37,195, with 5,963 over ten years and 2 over a century,
    which follow from far-future COMPLETED_DATE values in the source -- approval_issued reaches 3333-10-26 and
    application_received 2215-01-26. Nothing here caps either, because a cap would be an invented number. Bound the
    range, or exclude on application_received, before putting either column in an average. 11,776 rows also come
    through at calendar_days_qty = 0, which is a genuine same-day completion rather than a missing value.

days_used_qty IS VERY UNEVENLY POPULATED BY PROGRAM, which is the reason calendar_days_qty exists at all. Among
reference task 1000000002 rows at STATUS_CODE 100 (completed), 115,894 of 178,662 have no DAYS_USED_QTY. Program 32
populates it on 98% of tasks and program 44 on 99%, while program 21 manages 33 of 12,799 and program 37 one of 9,350.
So a department-wide aggregate over days_used_qty alone is really an aggregate over programs 32 and 44; count the NULLs
per program before reporting one, or use calendar_days_qty and say so.

THE TWO NULL POPULATIONS ON THE DATES ARE NOT THE SAME THING. application_received is NEVER NULL -- a completed
1000000000 task is a condition of the row existing, because without a received date there is no way to choose a
standard. approval_issued IS NULL on 22,153 of 191,603 rows, and that is the NOT-YET-ISSUED population rather than
the in-flight one: the 1000000002 task exists, which is why the row is here, but it has not completed -- and 6,095 of
those activities are CLOSED, so only 16,058 are still running. Treating them as zero elapsed days, or excluding them
silently, are both wrong for a backlog question; so is counting all 22,153 as the queue.

THE DATE COLUMNS PASS THROUGH AS datetime2(7), which is the second place this file departs from rule 1's DATETIME2 (3).
COMPLETED_DATE is datetime2(7) in EPAL_ISSI and stdPermitTT's own eight datetime2 columns are (7) as well, so casting
down to (3) here would truncate source values to make a view match a rule that the table it joins to does not match
either. A view is a projection; the precision decision belongs to whoever owns the columns. See follow-up (d) on
dbo.stdPermitTT.

THE IDENTIFIER COLUMNS EXIST BECAUSE THE MEASURE IS PER ACTIVITY. The descriptive and measure columns alone do not
identify a row -- many activities share all of them -- so without INT_DOC_ID an outlier could be seen but never
investigated, and duplicate rows could not be told from a fan-out bug. Added on 2026-09-22 for that reason.

    THREE OF THEM, AND ONLY ONE IS A KEY. INT_DOC_ID is the grain, one row per value, 191,603 of each.
    ACTIVITY_ID is business-facing and NOT unique. master_ai_id is not an identifier of the row at all -- it is the
    Agency Interest, the regulated SITE, and one site has many applications: 108,902 distinct values behind the
    191,603 rows, 77,878 of them with a single activity, 31,024 with more than one, and 482 on the busiest. GROUP BY
    it for a per-site question; joining on it fans out.

        master_ai_id IS PASSED THROUGH UNVALIDATED, which is the one caveat on it. It is NOT NULL in
        DSK_CENTRAL_FILE and never zero or negative here, but 150 of these activities carry an id with no row at all
        in EPAL_ISSI.dbo.AGENCY_INTEREST (12 distinct ids). This view does not read that table -- it is deliberately
        not a fourth synonym for a column nothing here needs to resolve -- so anyone joining master_ai_id to
        AGENCY_INTEREST for a site name must use an OUTER join or lose those rows. Note also that AGENCY_INTEREST
        holds 2,217,434 rows across 202,556 distinct MASTER_AI_ID, so it is not one row per site either and a naive
        equi-join fans out twice over.

THE FOUR MATCH-KEY COLUMNS ARE THE ACTIVITY'S, NOT THE STANDARD'S, and the distinction only shows on the rows that
matter. Where a standard matched, all four equal its own four columns by the join predicate, so reading them back
from s would give the same answer. Where none matched -- 32,583 rows -- every s column is NULL while these four are
populated, which turns "this activity has no standard" into "program 37 / class X / type Y has no standard", and that
is a row someone can add to stdPermitTT.

    activity_category_code IS CONSTANT 'APP'. It is filtered on in act, so all 191,603 rows carry the one value.
    It is here to complete the four-column key a reader reconciles against stdPermitTT, not to be grouped by; a
    GROUP BY on it returns one row and a COUNT (DISTINCT) on it returns 1.

    NEITHER activity_class_code NOR activity_type_code IS EVER NULL OR BLANK IN THIS POPULATION -- measured, 0 of
    191,603 on each, across 40 distinct class codes and 251 type codes -- although both are nullable in
    DSK_CENTRAL_FILE. So the coverage gap is NOT a missing-key problem that a NULL-tolerant join would close: those
    32,583 rows name a real, populated combination that stdPermitTT does not carry, or carries only outside their
    received date. All three activity code columns are char(3) in the source (program_code is char(2)) and pass
    through unchanged, so comparisons are trailing-blank-insensitive in the usual T-SQL way and a two-character
    class or type code needs no TRIM.

========================================================================================================================
Example Usage and Performance:

-- performance against standard on the RECORDED measure. days_used_qty is populated on only 54,194 of the 159,020 rows
-- that have a standard, so this is the narrower of the two questions -- see the calendar version below
select permit_type, count (*) as Activities
     , sum (case when days_used_qty <= std_turnaround_time then 1 else 0 end) as WithinStandard
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is not null and days_used_qty is not null
 group by permit_type order by Activities desc;

-- the same question on the calendar measure, which covers 2.9x the activities. NOTE THE  >= 0  -- without it the 1,130
-- rows whose dates are reversed all count as within standard, because a negative is <= every standard
select permit_type, count (*) as Activities
     , sum (case when calendar_days_qty <= std_turnaround_time then 1 else 0 end) as WithinStandard
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is not null and calendar_days_qty >= 0
 group by permit_type order by Activities desc;

-- the two measures side by side on the rows that carry both, which is how to decide which one a report should use.
-- They are not a check on each other: agreement is 62% exact, and where they differ the calendar measure is larger
select case when days_used_qty is null then 'calendar only' else 'both' end as Coverage
     , case when approval_issued is null then 'still running' else 'completed' end as Shape
     , count (*) as Activities
     , sum (case when days_used_qty      <= std_turnaround_time then 1 else 0 end) as WithinByRecorded
     , sum (case when calendar_days_qty  <= std_turnaround_time then 1 else 0 end) as WithinByCalendar
     , avg (case when days_used_qty is not null then calendar_days_qty - days_used_qty end) as MeanResidual
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is not null and calendar_days_qty >= 0
 group by case when days_used_qty is null then 'calendar only' else 'both' end
        , case when approval_issued is null then 'still running' else 'completed' end;

-- the coverage gap, by program
select program_code, count (*) as NoStandard
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is null group by program_code order by NoStandard desc;

-- the coverage gap by the FULL match key, which is the actionable form of the query above: each row is a
-- combination to add to dbo.stdPermitTT, or a received-date range its effective windows do not cover
select program_code, activity_category_code, activity_class_code, activity_type_code, project_type
     , count (*) as NoStandard
     , min (application_received) as EarliestReceived, max (application_received) as LatestReceived
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is null
 group by program_code, activity_category_code, activity_class_code, activity_type_code, project_type
 order by NoStandard desc;

-- per site rather than per application. master_ai_id is many-to-one, so this is a GROUP BY and not a join
select master_ai_id, count (*) as Activities
     , sum (case when days_used_qty > std_turnaround_time then 1 else 0 end) as OverStandard
  from dbo.vwPermitTurnaroundPerformance
 where std_turnaround_time is not null and days_used_qty is not null
 group by master_ai_id having count (*) >= 10 order by OverStandard desc;

-- which standard branch fired, with both measures of consumption beside the two published values. The predicate is
-- alt <> turnaround, NOT alt is not null: where the two published values are equal the branch is unobservable, and
-- testing std = alt there would label 101,473 rows 'alt' that may well have taken the ordinary branch.
select INT_DOC_ID, application_received, approval_issued
     , days_used_qty, calendar_days_qty, turnaround_time, alt_turnaround_time, std_turnaround_time
     , case when std_turnaround_time = alt_turnaround_time then 'alt' else 'standard' end as BranchFired
  from dbo.vwPermitTurnaroundPerformance
 where alt_turnaround_time <> turnaround_time;

-- STILL RUNNING: THE BACKLOG. Note BOTH null tests -- approval_issued is null alone returns 22,153 rows and overstates
-- the live queue by the 6,095 that are closed without ever being issued. calendar_days_qty is the AGE of each of these,
-- measured to today, so AlreadyOverStandard is a live figure and not a history -- the one question days_used_qty cannot
-- answer at all, since a working clock on an unfinished activity has no final value. Run it a month apart and it moves
select program_code, count (*) as InFlight
     , sum (case when calendar_days_qty > std_turnaround_time then 1 else 0 end) as AlreadyOverStandard
     , max (calendar_days_qty) as OldestDays
  from dbo.vwPermitTurnaroundPerformance
 where approval_issued is null and closedDate is null and std_turnaround_time is not null
 group by program_code order by InFlight desc;

-- how activities END, which is what the closure columns are for. The four states are independent, not a sequence:
-- 'issued and closed' is 9,345 ordinary rows and not a contradiction
select case when approval_issued is not null then 'issued' else 'not issued' end as Issuance
     , coalesce (closedType, '(not closed)') as Closure
     , count (*) as Activities
     , avg (case when calendar_days_qty >= 0 then calendar_days_qty end) as MeanCalendarDays
  from dbo.vwPermitTurnaroundPerformance
 group by case when approval_issued is not null then 'issued' else 'not issued' end
        , coalesce (closedType, '(not closed)')
 order by Activities desc;

-- the rows whose calendar age is still growing for an activity that has STOPPED. 6,015 of them: closed, never issued,
-- so calendar_days_qty measures to today forever. The view deliberately does not close the clock on closedDate --
-- see the Notes -- so this is the query that finds what that decision costs
select program_code, count (*) as ClosedButStillCounting
     , max (calendar_days_qty) as WorstDays
     , datediff (day, max (closedDate), cast (sysdatetime () as date)) as DaysSinceEarliestSuchClosure
  from dbo.vwPermitTurnaroundPerformance
 where approval_issued is null and closedDate is not null and calendar_days_qty is not null
 group by program_code order by ClosedButStillCounting desc;

-- the Wetlands substitution, made visible. approval_issued does not say whether it came from task 1000000002 or from
-- 3037, so this is how to see it -- and the only way, short of adding the raw date as a column
select v.INT_DOC_ID, v.application_received, v.approval_issued, v.calendar_days_qty, v.std_turnaround_time
     , raw1000000002.RawApprovalDate, bpw.BpwDate
  from dbo.vwPermitTurnaroundPerformance as v
       outer apply (select max (t.COMPLETED_DATE) as RawApprovalDate
                      from dbo.ACTIVITY_TASK_LIST as t
                     where t.INT_DOC_ID = v.INT_DOC_ID and t.REFERENCE_TASK_ID = 1000000002
                       and isnull (t.DELETED, 0) = 0) as raw1000000002
       outer apply (select max (t.COMPLETED_DATE) as BpwDate
                      from dbo.ACTIVITY_TASK_LIST as t
                     where t.INT_DOC_ID = v.INT_DOC_ID and t.REFERENCE_TASK_ID = 3037
                       and t.COMPLETED_DATE is not null and isnull (t.DELETED, 0) = 0) as bpw
 where v.program_code = '33' and bpw.BpwDate is not null;

-- the reversed-date rows, which are a data-quality report rather than a performance one. Worth sending upstream: they
-- are concentrated in a few program / type combinations, so they look like one fixable defect rather than noise
select program_code, activity_class_code, activity_type_code, count (*) as ReversedRows
     , min (calendar_days_qty) as WorstDays
  from dbo.vwPermitTurnaroundPerformance
 where calendar_days_qty < 0
 group by program_code, activity_class_code, activity_type_code order by ReversedRows desc;

-- materialising a reproducible snapshot, which is the supported way to publish a figure from this view. Without the
-- as-of column the numbers cannot be explained six months later
select cast (sysdatetime () as date) as AsOfDate, *
  into dbo.PermitTurnaroundSnapshot_20260923
  from dbo.vwPermitTurnaroundPerformance;

Roughly 191,600 rows. There is no cheap plan for this: it is a scan of the APP slice of DSK_CENTRAL_FILE with FIVE
correlated APPLYs per activity into ACTIVITY_TASK_LIST and DSK_DOCUMENT_ATTRIBUTE, plus the TOP (1) probe into
stdPermitTT, which is small enough to sit in memory. Filter on program_code or on the identifier columns rather than
selecting the whole view when an interactive answer is wanted; aggregate it into a table if it is going on a dashboard.
The STRING_SPLIT of taskIDs runs only for the three standards that carry one, so it costs nothing on the other 374.

The two APPLYs added on 2026-09-23 are the fourth and fifth ACTIVITY_TASK_LIST probes and both are seeks on
(INT_DOC_ID, REFERENCE_TASK_ID). The Wetlands one carries  cf.PROGRAM_CODE = '33'  INSIDE it rather than outside, so
it is skipped entirely on the 84,041 non-Wetlands activities instead of seeking and discarding. The closure one joins
dbo.MtbApprovalTaskList, which is 463 rows and covered for this access path by
IX_dbo_MtbApprovalTaskList_IsCloseTask (filtered on IsDeleted = 0, keyed on IsCloseTask, including TaskDesc) -- so the
close-task list resolves from 10 index rows rather than a 463-row scan repeated 191,603 times. Neither probe changes
the grain: one is an aggregate over a single task id, the other a TOP (1).

The APPLY that computes calendar_days_qty adds nothing measurable -- a single-row SELECT over values already in hand,
with no table access, so it is scalar arithmetic per row. But SYSDATETIME () makes the view NON-DETERMINISTIC, and that
does have costs beyond the arithmetic: this view cannot back an indexed view or a persisted computed column, and a plan
cached against it is still valid tomorrow while the result is not. Neither matters to a SELECT; both matter if anyone
tries to index their way out of the scan above. Filtering on calendar_days_qty cannot use an index either way, since
the value is computed per row after the join.

========================================================================================================================
Modification History:

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
Original. First consumer of dbo.stdPermitTT, which until now had no reader at all -- the 2026-09-10 build populated the
standards and nothing compared anything to them.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-22
Author:		rsincero
Ticket:		PTT
Description:
Added four columns, all of them values the first version computed or read and then discarded: application_received and
approval_issued (the completed dates of reference tasks 1000000000 and 1000000002), and turnaround_time /
alt_turnaround_time from the matched dbo.stdPermitTT row beside the std_turnaround_time selected from them. The received
date was already being computed to choose the standard and both turnaround values were already being read to resolve
the taskIDs rule, so this is projection only -- no change to the grain, the match rule, the filters or the row count,
confirmed at 191,603 rows across 191,603 distinct INT_DOC_ID before and after.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-23
Author:		rsincero
Ticket:		PTT
Description:
Added four more columns from DSK_CENTRAL_FILE: master_ai_id, and the activity's own activity_category_code,
activity_class_code and activity_type_code. Three of the four were ALREADY in the act CTE -- the view has always read
them, to match a standard on -- and were simply not projected, so only master_ai_id is a new read, and it comes from a
table already in the FROM clause. Projection only again: no new join, no new synonym, no change to the grain, the match
rule, the filters or the plan shape, confirmed at 191,603 rows across 191,603 distinct INT_DOC_ID before and after.

The point of the three code columns is the 32,583 rows that match no standard, where they are the only thing on the row
that says WHICH combination stdPermitTT is missing -- see the second coverage-gap query above, which is the actionable
form of the by-program one. master_ai_id is a grouping key and not an identifier; note the 150 rows whose id has no
AGENCY_INTEREST row. Both caveats are in the Notes.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-23
Author:		rsincero
Ticket:		PTT
Description:
THE CALENDAR MEASURE ARRIVED AS A SEPARATE COLUMN, AFTER A FALSE START. Earlier the same day it was built as a FILL:
days_used_qty itself took DATEDIFF (day, application_received, COALESCE (approval_issued, today)) wherever the source
left it NULL and the row had a standard, with a days_used_qty_is_derived BIT to tell the two apart. That was deployed,
measured, and then replaced on the user's instruction with the shape now in the file.

    WHAT CHANGED: days_used_qty goes back to being EPAL_ISSI's value and nothing else -- NULL on 120,381 rows, as the
    source holds it. The arithmetic moved to its own column, calendar_days_qty, and its population widened from "rows
    with a standard and no recorded value" (103,710) to ALL rows with a standard (159,020), so it is now computed
    alongside a recorded value rather than instead of one. days_used_qty_is_derived was dropped: with the two measures
    in two columns there is nothing for a flag to disambiguate. Still 20 columns; row count and grain unchanged at
    191,603 across 191,603 distinct INT_DOC_ID.

    WHY THE SECOND SHAPE IS BETTER, beyond being what was asked for. The fill made days_used_qty mean two things at
    once and silently changed a column consumers already read, so every existing query got a new answer without being
    touched; it also could not report the two measures side by side, which is the comparison that decides which one a
    report should use. Separate columns cost one column of width and no ambiguity. The one thing the fill did better:
    it left a single column to aggregate, where now a report has to choose -- which is the right problem to have.

    ONE DECISION REVERSED WITH IT. Under the fill, the 1,126 rows whose approval_issued precedes their
    application_received were left NULL, because a negative would have poisoned a column people aggregate. In its own
    plainly-named column the negative is now EMITTED, since calendar_days_qty is a measurement of two dates and
    hiding an EPAL_ISSI ordering violation is worse than showing it. The consumer's cost -- a negative reads as
    within standard -- is documented in the Notes, guarded in every example above, and reversible in one line.

Also corrected a figure this header carried from 2026-09-22: the ordering violation was recorded as 1,240 rows and does
not reproduce. Measured today it is 3,259 rows reversed on the raw timestamps and 3,082 reversed by a whole day or
more. The residual figures (62,772 / 44,017 / 18,755, -664,712 to +730,498) were re-measured and are correct as
written.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-23
Author:		rsincero
Ticket:		PTT
Description:
Two unrelated changes, and the first one is the only change this view has ever made to a column that already existed.

    1. THE WETLANDS EXCEPTION ON approval_issued. For program_code = '33', a completed reference task 3037 ("Send
    Report and Recommendation to the Board of Public Works") now replaces the 1000000002 date outright, including
    replacing a NULL one. 2,055 rows take it. THIS IS NOT PROJECTION -- it changes an existing column, so every query
    already built on approval_issued gets a new answer without being touched, and so does calendar_days_qty, which is
    derived from it. Measured: 1,612 rows get an earlier approval date, 95 a later one, 26 no change, and 322 gain a
    date where there was none. Downstream, approval_issued NULL goes 22,475 -> 22,153, the rows measured to today go
    12,232 -> 11,946, negatives go 1,126 -> 1,130, and within-standard by the calendar measure goes 118,979/157,894 to
    119,321/157,890. The direction is not neutral and the Notes say so: it makes Wetlands look slightly better.

    2. TWO NEW COLUMNS, closedDate and closedType, from the new dbo.MtbApprovalTaskList (sql/035) -- the earliest
    completed task carrying IsCloseTask = 1, and that task's TaskDesc. Pure projection: 191,603 rows across 191,603
    distinct INT_DOC_ID before and after, 20 columns to 22. These answer a question approval_issued could not: 6,095
    activities are CLOSED WITHOUT EVER BEING ISSUED, so the live backlog is 16,058 and not the 22,153 that
    approval_issued IS NULL returns. Every backlog example in this header now tests closedDate IS NULL as well.

    WHAT WAS DELIBERATELY NOT DONE. calendar_days_qty still measures to TODAY on a row with no approval_issued even
    when closedDate says the activity stopped years ago -- 6,015 rows. Closing the clock on closedDate was not asked
    for and would silently change an existing measure a second time in one release, so it is left to the consumer with
    an example query that quantifies the cost. This is the most likely next request on this view.

    ALSO NOT DONE: approval_issued does not expose which task it came from. The substitution is invisible on the row;
    an example query above reconstructs it, and adding the raw 1000000002 date as a column is a one-line change.

Also corrected two figures this header had carried: the fill-era example comment still claimed days_used_qty was
populated on 157,904 of 159,020 rows with a standard (it is 54,194 -- that figure belonged to the abandoned design),
and the 2026-09-23 modification note above said 1,116 reversed-date rows where the measurement was 1,126.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-09-24
Author:		rsincero
Ticket:		PTT
Description:
Two changes; the first alters an existing column, the second is a new one. Row count unchanged at 191,603.

    1. THE WETLANDS TIDAL EXCEPTION ON permit_type. For program_code = '33' and permit_category = 'Tidal', a
    permit_type of the form 'NNN-Day' becomes std_turnaround_time + '-Day'. 70 rows change: 66 '240-Day' measured
    against 325 become '325-Day', 1 '240-Day' and 3 '90-Day' measured against 150 become '150-Day'. The
    License-* / Permit-* Tidal types (about 34,000 rows) name a kind of approval, not a duration, and are left as they are --
    relabelling every Tidal row was offered and declined. std_turnaround_time is a whole number on every row, so the
    INT cast loses nothing. Like the approval_issued exception, the original label is not projected.

    2. NEW COLUMN derived_days_qty = COALESCE (days_used_qty, calendar_days_qty). From days_used_qty on 71,222 rows,
    from calendar_days_qty on 104,826, NULL on 15,555 (no recorded figure and no standard). It MIXES THE TWO CLOCKS by
    design; days_used_qty and calendar_days_qty are untouched, and it inherits calendar_days_qty's negatives and
    daily growth on the rows it takes from it.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Rows with an invalid date are excluded: application_received, approval_issued (as projected, after the Wetlands
substitution) and closedDate must each be NULL or on or after 1900-01-01. Two such rows were reported on 2026-10-01;
they broke the report's Excel export with "Not a legal OleAut date". THE ROW COUNT DROPS BY THOSE ROWS, so the
191,603 figures quoted throughout this header predate the change. The whole row is excluded rather than the one date,
because NULLing approval_issued or closedDate would make a finished activity read as unissued or open.

-----------------------------------------------------------------------------------------------------------------------

Date:		2026-10-01
Author:		rsincero
Ticket:		PTT
Description:
Activities whose MASTER_AI_ID is listed in dbo.AiExclusionList with is_active = 1 are excluded. That table holds 12 test
and functional Agency Interests (TRIP test sites, OIMT data-migration and wastewater placeholders) whose applications
are not real permit work. THE ROW COUNT DROPS AGAIN, by however many activities those 12 sites carry -- not measurable
from this login, which cannot read EPAL_ISSI. Tested in act, on DSK_CENTRAL_FILE directly, so excluded activities skip
the five task and attribute probes. A row deactivated (is_active = 0) stops excluding with no redeploy.

-----------------------------------------------------------------------------------------------------------------------

***********************************************************************************************************************/
CREATE OR ALTER VIEW dbo.vwPermitTurnaroundPerformance
AS
WITH act AS
(
    SELECT cf.INT_DOC_ID
         , cf.ACTIVITY_ID
         , cf.MASTER_AI_ID
         , cf.PROGRAM_CODE
         , cf.ACTIVITY_CATEGORY_CODE
         , cf.ACTIVITY_CLASS_CODE
         , cf.ACTIVITY_TYPE_CODE
         , rcv.ReceivedDate
         , pt.project_type
         , csm.days_used_qty

           -- THE WETLANDS EXCEPTION. For program 33 a completed reference task 3037 -- "Send Report and
           -- Recommendation to the Board of Public Works" -- REPLACES the 1000000002 date outright, including
           -- replacing a NULL one. COALESCE spells that correctly only because the bpw apply already restricts
           -- itself to program 33, so BpwDate is NULL by construction everywhere the exception does not apply.
           -- 2,055 rows take the substitution. See the header for what it moves and in which direction.
         , COALESCE (bpw.BpwDate, csm.ApprovalIssued) AS ApprovalIssued

      FROM dbo.DSK_CENTRAL_FILE AS cf

           -- Reference task 1000000000, "application received" / "date received". CROSS APPLY rather than a join so
           -- the duplicates collapse to one row here instead of fanning out and being de-duplicated later. It still
           -- returns a row when no task qualifies -- an aggregate over nothing is one NULL -- which is why the
           -- WHERE clause below has to test ReceivedDate explicitly rather than relying on CROSS APPLY to filter.
     CROSS APPLY (SELECT MIN (t.COMPLETED_DATE) AS ReceivedDate
                    FROM dbo.ACTIVITY_TASK_LIST AS t
                   WHERE t.INT_DOC_ID          = cf.INT_DOC_ID
                     AND t.REFERENCE_TASK_ID   = 1000000000
                     AND t.COMPLETED_DATE IS NOT NULL
                     AND ISNULL (t.DELETED, 0) = 0) AS rcv

           -- Reference task 1000000002, the consumption clock and the approval. TaskCount is what proves the task
           -- EXISTS, which is half of the validity test; days_used_qty is frequently NULL even where the task is
           -- present and completed, so a NULL measure must not be read as a missing task. ApprovalIssued is NULL
           -- on 22,475 of these activities for a different reason -- the task exists but is not finished. NOTE that
           -- is csm's OWN count, before the Wetlands substitution below takes 322 of them; the projected
           -- approval_issued is NULL on 22,153. See the
           -- header on both.
     CROSS APPLY (SELECT MAX (t.DAYS_USED_QTY)   AS days_used_qty
                       , MAX (t.COMPLETED_DATE)  AS ApprovalIssued
                       , COUNT (*)               AS TaskCount
                    FROM dbo.ACTIVITY_TASK_LIST AS t
                   WHERE t.INT_DOC_ID          = cf.INT_DOC_ID
                     AND t.REFERENCE_TASK_ID   = 1000000002
                     AND ISNULL (t.DELETED, 0) = 0) AS csm

           -- Reference task 3037, the Wetlands substitute for the approval date. THE PROGRAM TEST IS INSIDE THIS
           -- APPLY, not outside it in a CASE, for two reasons. It keeps the exception in one place instead of
           -- splitting the rule between a probe and a projection; and it lets the optimiser skip the seek entirely
           -- on the 84,041 non-Wetlands activities rather than seeking and discarding.
           --
           -- MAX, matching approval_issued's own aggregate rather than MIN: 17 activities carry more than one
           -- completed 3037 (up to three), and the last completion is the one that stops the clock -- the same
           -- reasoning that makes approval_issued a MAX. Choosing MIN here would make the Wetlands rows measured
           -- on a different principle from every other row in the view.
           --
           -- 3037 IS CURRENTLY A PROGRAM-33-ONLY TASK IN ANY CASE: measured 2026-09-23, all 2,080 completed 3037
           -- tasks in the APP population belong to program 33, so the guard changes no row today. It is kept
           -- because the rule as stated is about Wetlands, not about task 3037 -- if another program starts using
           -- the task, this view must not silently start substituting for it too.
     OUTER APPLY (SELECT MAX (t.COMPLETED_DATE) AS BpwDate
                    FROM dbo.ACTIVITY_TASK_LIST AS t
                   WHERE cf.PROGRAM_CODE       = '33'
                     AND t.INT_DOC_ID          = cf.INT_DOC_ID
                     AND t.REFERENCE_TASK_ID   = 3037
                     AND t.COMPLETED_DATE IS NOT NULL
                     AND ISNULL (t.DELETED, 0) = 0) AS bpw

           -- Major / Minor. OUTER, because 85,467 of these activities carry neither attribute and they belong in the
           -- output -- they simply match only a standard whose own project_type is NULL.
     OUTER APPLY (SELECT TOP (1) da.VALUE_TEXT AS project_type
                    FROM dbo.DSK_DOCUMENT_ATTRIBUTE AS da
                   WHERE da.INT_DOC_ID = cf.INT_DOC_ID
                     AND da.DOC_ATTRIBUTE_CODE IN ('PROJ_MAJOR', 'PROJ_MINOR')
                       -- An attribute row present but blank is no attribute at all, and it must not beat a populated
                       -- row of the other code.
                     AND NULLIF (LTRIM (RTRIM (da.VALUE_TEXT)), '') IS NOT NULL
                   ORDER BY CASE da.DOC_ATTRIBUTE_CODE WHEN 'PROJ_MAJOR' THEN 0 ELSE 1 END
                          , da.DOC_ATTRIBUTE_SEQ) AS pt

     WHERE cf.ACTIVITY_CATEGORY_CODE = 'APP'
       AND ISNULL (cf.DELETED, 0)    = 0
           -- The two key tasks. An APP row without both is not a valid activity for this purpose: with no received
           -- date there is no way to choose a standard, and with no 1000000002 task there is nothing to measure.
       AND rcv.ReceivedDate IS NOT NULL
       AND csm.TaskCount    > 0
           -- Test and functional Agency Interests are not real permit work. Only ACTIVE exclusion rows count, so an
           -- entry is retired by setting is_active = 0 rather than deleting it. Seeks the PK on Master_AI_Id.
       AND NOT EXISTS (SELECT 1
                         FROM dbo.AiExclusionList AS x
                        WHERE x.Master_AI_Id = cf.MASTER_AI_ID
                          AND x.is_active    = 1)
)
SELECT a.INT_DOC_ID
     , a.ACTIVITY_ID

       -- The Agency Interest -- the regulated site the application is about, not an attribute of the application.
       -- Many activities to one AI (108,902 AIs behind 191,603 activities, up to 482 on one), so this is the column
       -- to GROUP BY for a per-site question and never a key of this view.
     , a.MASTER_AI_ID   AS master_ai_id

       -- The five descriptive fields, materialised onto stdPermitTT by the 2026-09-10 build rather than joined at
       -- read time, so they arrive with the standard and cannot fan out.
     , s.permit_category
     , s.permit_class

       -- THE WETLANDS TIDAL EXCEPTION. For program 33 / Tidal, an 'NNN-Day' permit_type is relabelled with the
       -- standard actually applied, so 240-Day measured against 325 reads 325-Day. Only the N-Day labels: the
       -- License-GL / Permit-GP family names what kind of approval it is, not a duration, and keeps its name
       -- (decided 2026-09-24 over relabelling every Tidal row). 70 rows change; see the header.
     , CAST (CASE WHEN a.PROGRAM_CODE           = '33'
                   AND s.permit_category        = 'Tidal'
                   AND s.permit_type         LIKE '[0-9]%-Day'
                   AND std.std_turnaround_time IS NOT NULL
                  THEN CONCAT (CAST (std.std_turnaround_time AS INT), '-Day')
                  ELSE s.permit_type
             END AS VARCHAR (100)) AS permit_type
     , s.stt_permit_type
     , s.stt_sortorder

       -- The four match keys, all from the ACTIVITY and not from the matched standard, which is what makes them
       -- worth carrying: on the 32,583 rows that matched no standard these are populated where every s column is
       -- NULL, so the combination that is missing from stdPermitTT can be read straight off the row. Where a
       -- standard DID match they are equal to its own four columns by the join predicate below -- redundant there,
       -- and deliberately so.
       --
       -- activity_category_code is constant 'APP' on every row, because the WHERE clause in act filters on it.
       -- Carried anyway, for the same reason a stdPermitTT row carries it: the match key is four columns, and a
       -- reader reconciling this view against that table should see all four in one place. Do not read a
       -- distribution into it.
     , a.PROGRAM_CODE           AS program_code
     , a.ACTIVITY_CATEGORY_CODE AS activity_category_code
     , a.ACTIVITY_CLASS_CODE    AS activity_class_code
     , a.ACTIVITY_TYPE_CODE     AS activity_type_code
     , a.project_type

       -- The two ends of the clock. application_received is never NULL -- it is a condition of the row existing at
       -- all, and it is also the value that chose the standard. approval_issued is NULL on 22,153 rows, which is
       -- the not-yet-issued population: the task exists, hence the row, but it has not completed.
       --
       -- approval_issued IS NOT ALWAYS THE 1000000002 DATE. On 2,055 Wetlands rows it is the completed date of
       -- reference task 3037 instead, and the substitution is NOT VISIBLE on the row -- the raw 1000000002 date is
       -- not projected, so nothing here distinguishes a substituted date from an ordinary one. Reconcile against
       -- ACTIVITY_TASK_LIST via program_code = '33' and task 3037, or add the raw date as a column. See the header.
     , a.ReceivedDate   AS application_received
     , a.ApprovalIssued AS approval_issued

       -- CLOSURE, WHICH IS A DIFFERENT QUESTION FROM ISSUANCE and answers "is this activity still running" on the
       -- 22,153 rows where approval_issued is NULL. 6,104 of those are closed -- withdrawn, denied, voided, not
       -- required -- so only 16,371 are genuinely in flight. Populated INDEPENDENTLY of approval_issued and not
       -- mutually exclusive with it: 9,336 activities are both issued and closed. See the header before using
       -- either column as a state machine.
     , cls.closedDate
     , cls.closedType

       -- Straight from ACTIVITY_TASK_LIST, NULL on the 63% of activities the source leaves unpopulated. Nothing is
       -- filled in here: the calendar measure lives in its own column beside it, so the two measures never mix.
     , a.days_used_qty

       -- The calendar window, on every row that has a standard to compare it against. A SECOND, DIFFERENT MEASURE of
       -- the same thing -- not a fallback for the column above and not reconcilable with it row by row. See the
       -- header: it is present on 159,020 rows where days_used_qty manages 54,194, at the cost of being a calendar
       -- and not a working-time clock, of running to today on the 11,946 with no approval date, and of going NEGATIVE
       -- on the 1,130 whose two dates are the wrong way round.
     , cal.calendar_days_qty

       -- The recorded figure where EPAL_ISSI has one, the calendar figure where it does not. A BLEND OF THE TWO
       -- MEASURES ABOVE, asked for 2026-09-24 as its own column so that neither of them changes meaning. Which
       -- clock a row carries is read off days_used_qty IS NULL; say so in any report that aggregates it.
     , COALESCE (a.days_used_qty, cal.calendar_days_qty) AS derived_days_qty

       -- Both published values from the matched standard, beside the one the rule selected from them. Note that
       -- std_turnaround_time = alt_turnaround_time does NOT mean the alternative branch fired: 63 of the 66
       -- standards carrying an alternative set it EQUAL to their own turnaround_time, so the equality holds on
       -- 101,545 activities while the branch actually fires on 72. See the header.
     , s.turnaround_time
     , s.alt_turnaround_time
     , std.std_turnaround_time
	 , pc.program_desc 

  FROM act AS a
  
  inner join dbo.mtb_program pc on (pc.program_code = a.program_code)  


       -- OUTER, not CROSS: 32,583 activities match no standard and are kept with a NULL std_turnaround_time. See
       -- the header before changing this.
  OUTER APPLY (SELECT TOP (1) s.turnaround_time
                    , s.alt_turnaround_time
                    , s.taskIDs
                    , s.permit_category
                    , s.permit_class
                    , s.permit_type
                    , s.stt_permit_type
                    , s.stt_sortorder
                 FROM dbo.stdPermitTT AS s
                WHERE s.IsDeleted = 0
                  AND s.program_code           = a.PROGRAM_CODE
                  AND s.activity_category_code = a.ACTIVITY_CATEGORY_CODE
                  AND s.activity_class_code    = a.ACTIVITY_CLASS_CODE
                  AND s.activity_type_code     = a.ACTIVITY_TYPE_CODE
                       -- AND, never the legacy OR. See the header.
                  AND (s.project_type = a.project_type OR s.project_type IS NULL)
                       -- The received date picks the vintage. effective_end_date NULL means still in force.
                  AND a.ReceivedDate >= s.effective_start_date
                  AND (s.effective_end_date IS NULL OR a.ReceivedDate <= s.effective_end_date)
				  and (s.permit_class in ('New', 'Renew', 'Renewal') )
                ORDER BY CASE WHEN s.project_type IS NOT NULL THEN 0 ELSE 1 END  -- specific beats catch-all
                       , s.effective_start_date DESC) AS s                       -- later vintage beats earlier

       -- CROSS APPLY over a single-row SELECT: it always returns exactly one row, so it filters nothing, and it
       -- keeps the alt_turnaround_time test out of the SELECT list where its nesting would be unreadable. When no
       -- standard matched, every s column is NULL and this correctly yields NULL.
  CROSS APPLY (SELECT CASE
                           -- ALL of the listed reference task ids must have a completed date, not ANY. Decided
                           -- 2026-09-22; see the header. The double NOT EXISTS is how "no id is unsatisfied" is
                           -- spelled -- there is no ALL quantifier over a table source.
                           WHEN s.alt_turnaround_time IS NOT NULL
                            AND s.taskIDs IS NOT NULL
                            AND NOT EXISTS (SELECT 1
                                              FROM STRING_SPLIT (s.taskIDs, ',') AS ids
                                             WHERE NOT EXISTS (SELECT 1
                                                                 FROM dbo.ACTIVITY_TASK_LIST AS t
                                                                WHERE t.INT_DOC_ID = a.INT_DOC_ID
                                                                       -- TRY_CAST, not CAST: a malformed or blank
                                                                       -- segment yields NULL, which matches no task,
                                                                       -- so the alternative is simply not selected.
                                                                       -- CAST would fail the whole query instead.
                                                                  AND t.REFERENCE_TASK_ID   = TRY_CAST (LTRIM (RTRIM (ids.value)) AS BIGINT)
                                                                  AND t.COMPLETED_DATE IS NOT NULL
                                                                  AND ISNULL (t.DELETED, 0) = 0))
                           THEN s.alt_turnaround_time
                           ELSE s.turnaround_time
                      END AS std_turnaround_time) AS std

       -- The calendar window. CROSS APPLY over a single-row SELECT again, so it filters nothing; it is here rather
       -- than in the SELECT list because it has to reference std, and because the expression is long enough that
       -- repeating it would guarantee the two copies drifted apart.
  CROSS APPLY (SELECT CASE
                           -- Only where there is a standard to compare it against. The dates are present on the
                           -- other 32,583 rows and the subtraction would succeed, so this is a deliberate
                           -- restriction, not a limitation -- a bare elapsed time with nothing to measure it
                           -- against is a column people would average by mistake. Drop this branch to populate it
                           -- everywhere.
                           WHEN std.std_turnaround_time IS NULL THEN NULL
                           -- SYSDATETIME and not SYSUTCDATETIME: this server runs UTC-4 and COMPLETED_DATE is local,
                           -- so UTC would add a spurious day to every in-flight activity measured after 8pm local.
                           -- CAST to date states the "current date" the rule asks for -- DATEDIFF (day) counts date
                           -- boundaries, so it is the same number either way, but it would stop being the same
                           -- number the moment somebody changed the unit to hour.
                           --
                           -- NEGATIVE VALUES ARE EMITTED AS THEY FALL, on the 1,130 rows whose approval_issued
                           -- precedes their application_received. This column is a measurement of two dates and it
                           -- reports what they say; NULLing them would hide an EPAL_ISSI ordering violation that
                           -- this is the cheapest place to see, and clamping to 0 would assert the activity took no
                           -- time. The cost is real and belongs to the consumer: a negative is <= every standard,
                           -- so all 1,130 read as compliant unless excluded. Every comparison in the header does
                           -- exclude them. To NULL them here instead, add  WHEN ... < 0 THEN NULL  above.
                           ELSE DATEDIFF (day, a.ReceivedDate, COALESCE (a.ApprovalIssued, CAST (SYSDATETIME () AS date)))
                      END AS calendar_days_qty) AS cal

       -- CLOSURE. OUTER, because 176,163 activities have no completed close task and belong in the output; the
       -- columns are simply NULL for them. TOP (1) with the ORDER BY is what makes "the earliest closure" a single
       -- deterministic row rather than a fan-out -- 649 activities carry more than one completed close task.
       --
       -- THE TIE-BREAK ON ReferenceTaskId IS LOAD-BEARING, not decoration. 72 activities have two or more close
       -- tasks completed on the SAME date, so ORDER BY COMPLETED_DATE alone would leave closedType picked by
       -- whichever row the plan happened to reach first -- a value that could change between two runs of the same
       -- query with no data change. The lowest reference task id is arbitrary but STABLE, which is the property
       -- that matters. closedDate is unaffected either way; it is closedType that would wobble.
       --
       -- IsCloseTask IS READ FROM THE TABLE, NOT HARD-CODED, which is the difference between this and the
       -- 1000000000 / 1000000002 / 3037 ids above. Adding an eleventh close task to dbo.MtbApprovalTaskList
       -- changes this view's output with no redeploy -- deliberate, since the list of ways an application can die
       -- is reference data and not logic, but it does mean that table is a published interface. IsDeleted = 0
       -- because the soft-delete rule applies to reads of it like any other table here.
  OUTER APPLY (SELECT TOP (1) t.COMPLETED_DATE AS closedDate
                            , r.TaskDesc       AS closedType
                 FROM dbo.ACTIVITY_TASK_LIST AS t
                      JOIN dbo.MtbApprovalTaskList AS r
                        ON r.ReferenceTaskId = t.REFERENCE_TASK_ID
                       AND r.IsCloseTask     = 1
                       AND r.IsDeleted       = 0
                WHERE t.INT_DOC_ID          = a.INT_DOC_ID
                  AND t.COMPLETED_DATE IS NOT NULL
                  AND ISNULL (t.DELETED, 0) = 0
                ORDER BY t.COMPLETED_DATE          -- the EARLIEST closure, as asked
                       , t.REFERENCE_TASK_ID) AS cls   -- stable tie-break; see above

       -- INVALID DATES EXCLUDE THE ROW. Every date must be 1900-01-01 or later; anything earlier is a data-entry
       -- error in EPAL_ISSI (a year typed as 0019) and also breaks the SSRS Excel export, which cannot convert a
       -- date before year 100. The whole row goes rather than just the date: a NULLed approval_issued would make
       -- the activity look unissued and measure it to today, and a NULLed closedDate would make it look open.
       -- Tested here, after the Wetlands substitution, so approval_issued is checked as projected.
 WHERE a.ReceivedDate >= '19000101'
   AND (a.ApprovalIssued IS NULL OR a.ApprovalIssued >= '19000101')
   AND (cls.closedDate   IS NULL OR cls.closedDate   >= '19000101');
GO


-- Rule 4: the view and every one of its columns. Through the helper, never sp_addextendedproperty directly --
-- CREATE OR ALTER VIEW keeps the object_id, so a bare add would fail with "Property already exists" on the
-- second run of this script and a bare update would fail on the first.
EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @Description = N'One row per EPAL_ISSI permit-family activity (DSK_CENTRAL_FILE under ACTIVITY_CATEGORY_CODE = ''APP'' holding both key tasks 1000000000 and 1000000002), carrying the turnaround time consumed and both ends of the clock -- application_received and approval_issued -- beside the dbo.stdPermitTT standard in force on the date the application was received, with both published values (turnaround_time, alt_turnaround_time) shown next to the std_turnaround_time selected from them. Also carries the activity''s own four match keys (program_code, activity_category_code, activity_class_code, activity_type_code) and its master_ai_id. Reaches EPAL_ISSI through local synonyms only. Keeps activities that match no standard, with std_turnaround_time NULL, so the coverage gap stays countable -- and diagnosable, because the four match keys are populated on exactly those rows; does not filter on EFFECTIVE_FLAG, because an expired permit still had a turnaround time. Excludes any row whose application_received, approval_issued or closedDate falls before 1900-01-01, which is a data-entry error in the source, and any activity whose master_ai_id is listed as active in dbo.AiExclusionList (test and functional Agency Interests). CONSUMED TIME COMES IN TWO COLUMNS AND THEY ARE DIFFERENT MEASURES: days_used_qty is EPAL_ISSI''s own working-time clock, passed through untouched and NULL on 63% of rows because that is how the source holds it, while calendar_days_qty is this view''s wall-clock arithmetic (approval_issued, or today if still running, minus application_received) on all 159,020 rows that have a standard. The second covers 2.9x the activities but is not the measure the programs keep, and the two are not a check on each other -- pick one per report and say which. calendar_days_qty makes THE VIEW NON-DETERMINISTIC, since the 11,946 rows with no approval date grow by a day every day, so materialise with an as-of date before publishing a figure; it is also NEGATIVE on 1,130 rows whose two dates are reversed in the source, and a negative reads as within standard unless excluded. ISSUANCE AND CLOSURE ARE SEPARATE STATES: closedDate and closedType come from the earliest task flagged IsCloseTask in dbo.MtbApprovalTaskList and are populated independently of approval_issued, so 160,105 activities are issued and not closed, 9,345 are both, 6,095 are closed without ever being issued, and only 16,058 are genuinely in flight -- meaning approval_issued IS NULL alone overstates the live backlog by 6,095, and 6,015 rows have a calendar_days_qty still growing daily for an activity that has stopped. ONE COLUMN IS NOT WHAT ITS NAME SUGGESTS ON EVERY ROW: for program_code = ''33'' a completed reference task 3037 (the Board of Public Works recommendation) replaces the 1000000002 date on 2,055 rows, including where that date was NULL, and the substitution is not visible on the row. Note also that master_ai_id is a many-to-one grouping key rather than an identifier of the row.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'INT_DOC_ID'
    , @Description = N'The activity''s internal document id, primary key of DSK_CENTRAL_FILE and the grain of this view. Present because the nine descriptive and measure columns do not identify a row -- many activities share all nine -- so without it an outlier could be seen but never investigated.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'ACTIVITY_ID'
    , @Description = N'The activity''s business-facing identifier from DSK_CENTRAL_FILE, for tying a row back to an application in EPAL_ISSI without going through INT_DOC_ID. Nullable in the source, so INT_DOC_ID is the reliable key.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'master_ai_id'
    , @Description = N'The Agency Interest the application is about -- the regulated SITE -- from DSK_CENTRAL_FILE.MASTER_AI_ID. NOT an identifier of this row: one site has many applications, so 108,902 distinct values sit behind the 191,603 rows, 77,878 of them with a single activity, 31,024 with more than one and 482 on the busiest. GROUP BY it for a per-site question; an equi-join on it fans out. Never NULL, never zero or negative. Passed through unvalidated: 150 activities (12 distinct ids) carry a value with no row at all in EPAL_ISSI.dbo.AGENCY_INTEREST, which this view deliberately does not read, so join OUTER to get a site name or lose those rows -- and note AGENCY_INTEREST is itself 2,217,434 rows over 202,556 distinct ids, not one row per site. Values listed with is_active = 1 in dbo.AiExclusionList never appear: those activities are excluded from the view.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'permit_category'
    , @Description = N'Permit category of the matched standard, carried from dbo.stdPermitTT. NULL when the activity matched no standard.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'permit_class'
    , @Description = N'Permit class of the matched standard, carried from dbo.stdPermitTT. NULL when the activity matched no standard.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'permit_type'
    , @Description = N'Permit type of the matched standard, carried from dbo.stdPermitTT. NULL when the activity matched no standard. WETLANDS TIDAL EXCEPTION: for program_code = ''33'' and permit_category = ''Tidal'', an ''NNN-Day'' value is replaced by std_turnaround_time + ''-Day'' (e.g. 240-Day measured against 325 reads 325-Day), on 70 rows; the License-* / Permit-* Tidal types keep their names. The original label is not projected.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'stt_permit_type'
    , @Description = N'Standard-turnaround-time permit type label of the matched standard, the reporting-facing name, carried from dbo.stdPermitTT. NULL when the activity matched no standard.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'stt_sortorder'
    , @Description = N'Presentation sort order of the matched standard, carried from dbo.stdPermitTT, for ordering a report by the published sequence rather than alphabetically. NULL when the activity matched no standard, which sorts those rows first under a plain ORDER BY.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'program_code'
    , @Description = N'Two-character program code of the ACTIVITY, from DSK_CENTRAL_FILE -- not from the matched standard, so it is populated even on the rows that matched none, and is the column to group by when measuring the coverage gap. First of the four columns the standard is matched on; char(2) in the source, where the other three are char(3).';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'activity_category_code'
    , @Description = N'Activity category of the ACTIVITY, from DSK_CENTRAL_FILE. CONSTANT ''APP'' on every row -- the view filters on it, since permits, licences and accreditations are the whole subject -- so do not read a distribution into it: GROUP BY returns one row and COUNT (DISTINCT) returns 1. Carried because the match against dbo.stdPermitTT is on four columns and a reader reconciling the two should see all four in one place. Second of the four match keys.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'activity_class_code'
    , @Description = N'Activity class of the ACTIVITY, from DSK_CENTRAL_FILE, and the third of the four columns the standard is matched on. The ACTIVITY''s value, not the matched standard''s -- identical to it wherever a standard matched, by the join predicate, and populated on the roughly 32,600 rows where none did, which is the point: with program_code, activity_category_code and activity_type_code it names the exact combination missing from dbo.stdPermitTT. Nullable in DSK_CENTRAL_FILE but never NULL and never blank in this population (0 of 191,603, across 40 distinct values), so the coverage gap is a missing standard and not a missing key. char(3), so comparisons ignore trailing blanks.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'activity_type_code'
    , @Description = N'Activity type of the ACTIVITY, from DSK_CENTRAL_FILE, and the last of the four columns the standard is matched on. The ACTIVITY''s value, not the matched standard''s, for the same reason as activity_class_code. Nullable in DSK_CENTRAL_FILE but never NULL and never blank in this population (0 of 191,603, across 251 distinct values). char(3), so comparisons ignore trailing blanks. NOTE that on the stdPermitTT side this column is NOT NULL on every row only because the 2026-09-10 build expanded the Wetlands class-level standards across DSKMTB_ACTIVITY_TYPE -- which is why the project_type predicate in this view is AND and not the legacy OR. See the Notes.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'project_type'
    , @Description = N'Major or Minor, from the activity''s own DSK_DOCUMENT_ATTRIBUTE rows (DOC_ATTRIBUTE_CODE PROJ_MAJOR or PROJ_MINOR), preferring Major where an activity carries both. Deliberately the ACTIVITY''s value and not the matched standard''s, whose project_type is NULL wherever a standard applies to both. NULL for the roughly 85,500 activities carrying neither attribute; those match only a standard whose own project_type is NULL.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'application_received'
    , @Description = N'The date the application was received: the MIN of COMPLETED_DATE across the activity''s reference task 1000000000 rows, MIN because the earliest receipt is what starts the clock. NEVER NULL -- a completed 1000000000 task is a condition of the row existing, since without it no standard could be chosen. This is also the value that selected the standard, so it always falls inside the matched row''s effective window. Passed through as datetime2(7), the source precision.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'approval_issued'
    , @Description = N'The date the approval was issued: normally the MAX of COMPLETED_DATE across the activity''s reference task 1000000002 rows, MAX because the last completion is what stops the clock -- so with the MIN on application_received the pair gives the widest window and cannot flatter elapsed time. THE WETLANDS EXCEPTION: for program_code = ''33'', a completed reference task 3037 (''Send Report and Recommendation to the Board of Public Works'') REPLACES that date entirely, including replacing a NULL one, on 2,055 rows. The substitution is NOT VISIBLE HERE -- the raw 1000000002 date is not projected, so a substituted value is indistinguishable from an ordinary one without going back to ACTIVITY_TASK_LIST -- and it is not directionally neutral: 1,612 of those rows get an EARLIER date, which shortens the measured window and improves Wetlands'' apparent performance, against only 95 that move later and 26 unchanged, while 322 gain a date where there was none. A report comparing Wetlands against other programs is comparing two definitions of "issued" and should say so. NULL on 22,153 rows, which is the NOT-YET-ISSUED population and not the in-flight one and not a data gap: the task exists, which is why the row is here, but it has not completed -- and 6,095 of those activities are CLOSED (see closedDate), so the live backlog is 16,058. Independent of days_used_qty''s aggregate, so on the 292 activities whose duplicate tasks disagree about the date the two can come from different task rows. Passed through as datetime2(7), the source precision.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'closedDate'
    , @Description = N'The date the activity STOPPED, whatever the reason: the EARLIEST COMPLETED_DATE among the activity''s tasks whose REFERENCE_TASK_ID is flagged IsCloseTask = 1 in dbo.MtbApprovalTaskList -- withdrawn, denied, voided, administratively closed, approval not required. Earliest and not latest because the first closure is what ends the activity; a later one is a subsequent administrative act on something already stopped. INDEPENDENT OF approval_issued, not a successor to it: 9,345 activities are both issued and closed, so this being populated does not mean no approval was granted, and 6,095 are closed having never been issued. Populated on 15,440 of 191,603 rows; NULL means not closed, which with approval_issued NULL is the only genuinely in-flight state (16,058 rows). 649 activities carry more than one completed close task and 72 of those TIE on the earliest date, so the pick is broken by the lower REFERENCE_TASK_ID -- without that tie-break closedType would vary between runs on those 72 with no change in the data. Sourced from ACTIVITY_TASK_LIST with DELETED rows excluded, and passed through as datetime2(7). NOTE that calendar_days_qty does NOT read this column: on the 6,015 rows that are closed but unissued it is still measured to today and still growing, so an aging report must filter closedDate IS NULL itself.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'closedType'
    , @Description = N'WHY the activity stopped: dbo.MtbApprovalTaskList.TaskDesc for the same reference task that supplied closedDate -- the two columns are one probe and are always both NULL or both populated, so they can be read as a pair without a join. A DESCRIPTION AND NOT A CODE: it is free text of up to 100 characters carried from REF.mtb_approval_task_list, so group on it only after checking the distinct values, and expect wording rather than a controlled vocabulary. Where an activity has several close tasks completed this names only the first one (see closedDate for the tie-break); the others are not projected. A row added to dbo.MtbApprovalTaskList with IsCloseTask = 1, or an existing row''s IsCloseTask flipped, changes this column and closedDate on existing history with no change to the view -- which is the point of holding the rule in a table, and the reason a published closure figure should record the date it was taken.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'days_used_qty'
    , @Description = N'Days consumed by the activity as EPAL_ISSI records it, passed through untouched: the MAX of DAYS_USED_QTY across the activity''s reference task 1000000002 rows, MAX rather than SUM because duplicate rows read as re-creations of one task and SUM would double-count. This is a WORKING-TIME clock -- it can be stopped while the department waits on an information request -- which is why it is not the same measure as calendar_days_qty and why the two must not be averaged together or used to check each other. NULL on 120,381 of 191,603 rows (63%) because the source does not populate it, NOT because the task is missing: the task''s presence is a condition of appearing here at all. Nothing is filled in; use calendar_days_qty where coverage matters more than matching the programs'' own figure. Population is very uneven by program (98% of tasks in program 32, 33 of 12,799 in program 21), so a department-wide aggregate over this column is really an aggregate over the programs that populate it -- count the NULLs per program first. Extreme values are not credible either, reaching 40,610 days.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'calendar_days_qty'
    , @Description = N'Wall-clock days from application_received to approval_issued, or to TODAY where the activity is still running: DATEDIFF (day, application_received, COALESCE (approval_issued, CAST (SYSDATETIME () AS date))). This view''s own arithmetic, not a source value, and a DIFFERENT MEASURE from days_used_qty rather than a substitute for it -- the calendar never stops where a working-time clock can. Populated on all 159,020 rows that have a std_turnaround_time and NULL on the other 32,583; that restriction is deliberate (an elapsed time with no standard to compare it against invites a meaningless average) and is one line to remove. Present where days_used_qty is NULL, so it covers 2.9x the activities: of rows with a standard it puts 119,321 of 157,890 inside standard (75.6%) against days_used_qty''s 43,943 of 54,194 (81.1%). Where both exist and the activity has completed they agree exactly on 62% of rows and this column is the LARGER on 18,254 against 346, so it cannot flatter performance -- but it will not reconcile row by row and is not a check on the recorded figure. THREE CAUTIONS. It makes the view NON-DETERMINISTIC: the 11,946 rows with no approval date grow by one every day (only 5,931 of them genuinely open -- see closedDate), so a published figure must be materialised with its as-of date, while an aging or backlog question wants exactly this behaviour. It is NEGATIVE on 1,130 rows whose approval_issued precedes their application_received -- an EPAL_ISSI ordering violation, deliberately shown rather than hidden -- and a negative is <= every standard, so those rows count as compliant unless you add  calendar_days_qty >= 0. And the extremes are not credible, running to 37,195 days off far-future COMPLETED_DATE values in the source, so bound the range before averaging; the 11,776 zeroes, by contrast, are genuine same-day completions.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'derived_days_qty'
    , @Description = N'days_used_qty where EPAL_ISSI records it, otherwise calendar_days_qty: COALESCE (days_used_qty, calendar_days_qty). A BLEND OF TWO DIFFERENT MEASURES -- a working-time clock on 71,222 rows and wall-clock days on 104,826 -- so tell them apart with days_used_qty IS NULL and say which in any report that aggregates it. NULL on 15,555 rows that have neither. On the rows it takes from calendar_days_qty it inherits that column''s cautions: negatives where the source dates are reversed (add derived_days_qty >= 0 to any compliance test) and daily growth where the activity is unissued.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'turnaround_time'
    , @Description = N'The matched standard''s published turnaround_time in days, straight from dbo.stdPermitTT and NOT the resolved value -- read std_turnaround_time for what this activity is actually measured against. Exposed so the taskIDs / alt branch is visible rather than inferred. Always populated where a standard matched (the column is NOT NULL on the table); NULL only where the activity matched no standard. Every value is in days: the 2026-09-11 build converted the 144 source rows expressed in months at a flat 30 and pins turnaround_time_unit to ''Days''.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'alt_turnaround_time'
    , @Description = N'The matched standard''s alternative turnaround_time in days, straight from dbo.stdPermitTT, which replaces turnaround_time only when the standard names reference task ids in taskIDs and ALL of them have a completed date on this activity. NULL on 311 of the 377 active standards. Of the 66 that carry it, 63 set it EQUAL to their own turnaround_time and name no taskIDs, so their alternative is redundant rather than unreachable; only 3 carry a value that DIFFERS, and each of those does have a taskIDs. CAUTION: std_turnaround_time = alt_turnaround_time does NOT identify the alternative branch, precisely because of those 63 -- the equality holds on about 101,500 activities while the branch fires on 72. Test alt_turnaround_time <> turnaround_time first; where the two are equal the branch is unobservable and makes no difference to the result.';
GO

EXEC util.uspSetObjectDescription
      @SchemaName  = N'dbo'
    , @ObjectType  = N'VIEW'
    , @ObjectName  = N'vwPermitTurnaroundPerformance'
    , @ColumnName  = N'std_turnaround_time'
    , @Description = N'The standard this activity is measured against, in days: dbo.stdPermitTT.alt_turnaround_time when the standard names reference task ids in taskIDs and ALL of them have a completed date on this activity, otherwise turnaround_time. NULL for the roughly 32,600 activities matching no standard -- filter on IS NOT NULL for comparable rows only.';
GO
