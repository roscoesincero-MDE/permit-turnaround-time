# PTT — Permit Turnaround Performance

Measures how long MDE permit applications in ETS take from receipt to approval, against the published standard
turnaround time that was in force when each application was received, and reports it by program, permit category and
permit type for a chosen period. It replaces `MDEServ.proc_wetland_detailed_listing_STT_by_fiscal_year_rs` as the
source of the permit turnaround view, and is delivered as SQL Server objects in `MDE_ETSReport` plus one SSRS report,
`TurnaroundPerformance.rdl`.

## Status

| | |
|---|---|
| Visibility | Private, internal to MDE |
| Production target | SQL Server 2019 (`MDE-ETSSQL01P`, version 15.0, compatibility level 150) |
| Report | SSRS / Report Builder, RDL 2016 schema |
| Build / CI | None. Scripts are deployed by hand. |

## Prerequisites

**Database server**

- **SQL Server 2019 or later.** Production is 2019, so deploy from `SqlServer2019-sql/` wherever a file exists there.
  The copies in `sql/` use SQL Server 2022 features (`LEAST`, `DATETRUNC`, `IS DISTINCT FROM`) and will not compile on
  2019.
- **The `MDE_ETSReport` database**, containing:
  - Local synonyms onto `EPAL_ISSI`: `dbo.DSK_CENTRAL_FILE`, `dbo.ACTIVITY_TASK_LIST`, `dbo.DSK_DOCUMENT_ATTRIBUTE`,
    `dbo.DSKMTB_ACTIVITY_TYPE`, `dbo.MTB_PROGRAM`, `dbo.MTB_DEFINED_TASK_LIST`, `dbo.MTB_DEFINED_TASK_LISTS_XREF` and
    `dbo.MTB_DEFINED_TASK_EXTEND_LIST`. These are the only permitted access path to `EPAL_ISSI`; the scripts use no
    three-part names and create no synonyms. `dbo.MTB_DEFINED_TASK_EXTEND_LIST` was added for the pause/resume tabs
    and is the only one that did not already exist on `MDE-ETSSQL01P`. Create it once with:

    ```sql
    CREATE SYNONYM dbo.MTB_DEFINED_TASK_EXTEND_LIST FOR [EPAL_ISSI].[dbo].[MTB_DEFINED_TASK_EXTEND_LIST];
    ```
  - Local source tables: `dbo.MTB_MDE_STT`, `dbo.MTB_MDE_WWP_STT`, `dbo.MTB_MDE_ACTIVITY`, and
    `REF.mtb_approval_task_list` (the source for `dbo.MtbApprovalTaskList`), and `dbo.AiExclusionList` (maintained
    outside this repository).
  - The `db_executor` role. The scripts grant `EXECUTE` to it if it exists.

**Access**

- **To deploy:** rights to create schemas, tables, views, procedures and triggers in `MDE_ETSReport`.
- **To run anything that reads the view:** read access to the `EPAL_ISSI` tables behind the synonyms. Access to
  `MDE_ETSReport` alone is not enough; querying the view without it fails with error 916.
- **To clone the repository:** an account on `state-of-maryland.ghe.com` with access to `Roscoe-Sincero/permit-turnaround-time`.

**Tools**

- **`sqlcmd`** (ODBC driver 17 or 18) or SQL Server Management Studio, to run the scripts.
- **Report Builder** (authored with version 15), or an SSRS report server, for the report.
- **Git**, and optionally the GitHub CLI (`gh`).
- **Python 3**, only if you use Claude Code with this repository. It runs the SQL validation hook in `.claude/hooks/`.

## Installation / setup

### 1. Get the code

```bash
git clone https://state-of-maryland.ghe.com/Roscoe-Sincero/permit-turnaround-time.git
cd permit-turnaround-time
```

### 2. Deploy the database objects, in this order

The scripts are written to be re-run safely: procedures, views and triggers use `CREATE OR ALTER`, and reference data
is loaded with `MERGE`. The `sqlcmd` switches below do the following:

- `-b` stops at the first error.
- `-C` trusts the server certificate, which `MDE-ETSSQL01P` needs.
- `-I` turns on `QUOTED_IDENTIFIER`, which `sqlcmd` leaves off by default. The scripts also set it themselves.

```bash
S="-S MDE-ETSSQL01P -d MDE_ETSReport -E -C -b -I"

sqlcmd $S -i sql/010_util.uspSetObjectDescription.sql                      # description helper; must run first
sqlcmd $S -i SqlServer2019-sql/015_logs.ExecutionLogging.sql               # logs.ExecutionLog + logging procedures
sqlcmd $S -i SqlServer2019-sql/020_dbo.uspBuildStdPermitTT.sql             # the procedure that builds the standards table
sqlcmd $S -Q "EXEC dbo.uspBuildStdPermitTT;"                               # creates and loads dbo.stdPermitTT
sqlcmd $S -i sql/030_dbo.trg_au_updt_stdPermitTT.sql                       # audit trigger; needs the table from the step above
sqlcmd $S -i SqlServer2019-sql/035_dbo.MtbApprovalTaskList.sql             # creates AND populates the approval task list
sqlcmd $S -i sql/040_dbo.vwPermitTurnaroundPerformance.sql                 # the view
sqlcmd $S -i sql/045_dbo.vwClockPauseResumeTask.sql                        # ETS clock pause/resume pairs
sqlcmd $S -i SqlServer2019-sql/050_dbo.uspPermitTurnaroundPerformance.sql  # detail report procedure
sqlcmd $S -i SqlServer2019-sql/051_dbo.uspPermitTurnaroundPerformanceSummary.sql  # summary report procedure
sqlcmd $S -i SqlServer2019-sql/052_dbo.uspPermitTurnaroundStandardReduction.sql   # standard reduction what-if procedure
sqlcmd $S -i SqlServer2019-sql/053_dbo.uspPermitTurnaroundPauseResumeTasks.sql    # pause/resume tasks procedure
sqlcmd $S -i SqlServer2019-sql/054_dbo.uspPermitTurnaroundNoPauseResume.sql       # no pause/resume procedure
sqlcmd $S -i SqlServer2019-sql/055_dbo.uspPermitTurnaroundPending.sql             # pending applications procedure
```

`010`, `030`, `040` and `045` have no 2019 copy because they need nothing newer than 2019; deploy them from `sql/`. On a
SQL Server 2022 server, every script can come from `sql/`.

The order matters:

- `030` refuses to run until `dbo.stdPermitTT` exists. That table is created by *executing* `dbo.uspBuildStdPermitTT`,
  not by deploying `020`.
- `040` refuses to run until `dbo.stdPermitTT`, `dbo.MtbApprovalTaskList`, `dbo.AiExclusionList` and all three
  `EPAL_ISSI` synonyms it reads exist. It names whatever is missing.
- `045` refuses to run until its three `EPAL_ISSI` synonyms exist, including the new `dbo.MTB_DEFINED_TASK_EXTEND_LIST`.
  `053` and `054` refuse to run until the views, table and synonyms they read exist. Each names whatever is missing.

### 3. Publish the report

1. Open `TurnaroundPerformance.rdl` in Report Builder, or upload it to the report server.
2. Set the credentials for the `ETSProd` data source (see [Configuration](#configuration)).
3. Run it once in preview to confirm the dropdown lists fill and both tables return rows.

## Usage

### The report

Pick a period, optionally narrow it, and run:

| Prompt | Meaning |
|---|---|
| Year Type | Date range, calendar year, state fiscal year (July–June) or federal fiscal year (October–September) |
| Year | The calendar or fiscal year. Ignored for a date range. |
| Quarter/Annual/Month | A quarter of that year, the whole year, or one month |
| Start / End | Only used when Year Type is a date range |
| Program Code | One ETS program, or blank for all |
| Permit Category | One permit category, or blank for all |
| Permit Type | One permit type, or blank for all |
| Standard Reduction % | The cut to the standards that the Standard Reduction tab tests. Default 25. |

What you get:

- **In the browser:** the Summary, Standard Reduction, Detail, Pending, No Pause-Resume and Pause-Resume Tasks tables
  on one page. Column headers stay visible while you scroll.
- **Exported to Excel:** seven tabs.
  - **About** explains the tables and shows the period and filters used for that run, and who ran it and when.
  - **Summary** has one row per program, permit category, class, type and standard. It shows the number of permits
    *issued* in the period and their average turnaround time.
  - **Standard Reduction** is a what-if for lowering the standards by the Standard Reduction %. For the same issued
    permits, one row per program, permit category, permit type and standard shows the share late now and the share that would be late
    against the lower standard, the median and 90th percentile turnaround time, and a readiness label: *Ready now*,
    *Improvement project* or *Redesign needed*. See [six-sigma.md](six-sigma.md#5-evaluating-a-25-cut-to-the-standards).
  - **Detail** has one row per permit application *received*, *issued* or *closed* in the period. Its row count is
    therefore not expected to match the Summary total, and it is not the list of everything pending.
  - **Pending** has one row per permit application that is neither issued nor closed, whenever it was received. It
    ignores the reporting period, so it is the full list of what is pending today. It has the Detail columns except
    approval issued, plus *days left* (the standard less the turnaround time used so far) and *% of std used*. The
    most urgent applications come first, and those at or past their standard are shown in red.
  - **No Pause-Resume** lists the activity types the report measures that have no pause/resume task pair for the ETS
    turnaround clock, so their turnaround time can never leave out time on hold. Each row shows whether ETS runs the
    clock for the type at all, the permits issued in the period, how many of those have an ETS days-used figure, and
    the last application received. It shows ETS as it is set up today; only the issued counts use the period.
  - **Pause-Resume Tasks** lists the pause/resume task pairs set up today for those activity types, named from
    `completed_task_desc` in ETS, with whether each pair is still in use and who last changed it.

### The procedures directly

The three turnaround procedures and `dbo.uspPermitTurnaroundNoPauseResume` take the same parameters, and
`dbo.uspPermitTurnaroundStandardReduction` also takes `@ReductionPercent`. `dbo.uspPermitTurnaroundPauseResumeTasks`
and `dbo.uspPermitTurnaroundPending` take the filters and `@ReportUser` but no period, because they report the ETS
setup and the pending applications as they are today. Every filter is optional, and NULL means all.

```sql
-- Previous calendar quarter (the default)
EXEC dbo.uspPermitTurnaroundPerformance;

-- An explicit date range
EXEC dbo.uspPermitTurnaroundPerformance @FiscalType = -1, @DateStart = '2025-01-01', @DateEnd = '2025-03-31';

-- State fiscal year 2026, Wetlands and Waterways only
EXEC dbo.uspPermitTurnaroundPerformanceSummary @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '33';

-- Federal fiscal year 2026, first quarter, Tidal permits only
EXEC dbo.uspPermitTurnaroundPerformance @FiscalType = 2, @FiscalYear = 2026, @FiscalPeriod = 1,
                                        @PermitCategory = 'Tidal';

-- State fiscal year 2026: which permit types could take a 25% cut to their standard
EXEC dbo.uspPermitTurnaroundStandardReduction @FiscalType = 1, @FiscalYear = 2026, @ReductionPercent = 25;

-- Scrap Tire activity types with no pause/resume pair, with state FY 2026 issued counts
EXEC dbo.uspPermitTurnaroundNoPauseResume @FiscalType = 1, @FiscalYear = 2026, @ProgramCode = '27',
                                          @PermitCategory = 'Scrap Tire';

-- The pause/resume pairs set up today for Wetlands and Waterways
EXEC dbo.uspPermitTurnaroundPauseResumeTasks @ProgramCode = '33';

-- Every Scrap Tire application still pending, most urgent first
EXEC dbo.uspPermitTurnaroundPending @ProgramCode = '27', @PermitCategory = 'Scrap Tire';
```

| Parameter | Values |
|---|---|
| `@FiscalType` | `-1` date range (default), `0` calendar year, `1` state fiscal year, `2` federal fiscal year |
| `@FiscalYear` | The year. Required unless `@FiscalType = -1`. |
| `@FiscalPeriod` | `1`–`4` quarter, `5` whole year (default), `6`–`17` January–December |
| `@DateStart`, `@DateEnd` | Used for a date range. Either may be omitted and defaults to the previous calendar quarter. |
| `@ProgramCode` | `CHAR(2)`, e.g. `'33'` |
| `@PermitCategory`, `@PermitClass`, `@PermitType`, `@SttPermitType` | Exact match |
| `@ReductionPercent` | `uspPermitTurnaroundStandardReduction` only. The cut to test, greater than 0 and less than 100. Default `25`. |
| `@ReportUser` | Who is running the report. It is logged only, not used as a filter. The report passes `User!UserID`. |

Bad arguments raise error 50000 instead of returning an empty result. Every row carries `period_start_date` and
`period_end_date`, so you can see the range a year-based request actually covered.

### Refreshing the standards

When `dbo.MTB_MDE_STT` or `dbo.MTB_MDE_WWP_STT` changes, rebuild the standards table:

```sql
EXEC dbo.uspBuildStdPermitTT;
```

## Configuration

| What | Where | Notes |
|---|---|---|
| Report data source | `ETSProd` in `TurnaroundPerformance.rdl` | `data source=MDE-ETSSQL01P;Initial catalog=MDE_ETSReport`. It uses stored database credentials, so set a user name and password on the report server. That account needs read access to `EPAL_ISSI`. Change the server here to point the report at UAT. |
| Source database | The eight `EPAL_ISSI` synonyms in `MDE_ETSReport` | To point the objects at another ETS database, repoint the synonyms. Do not edit the scripts. |
| Which tasks close an application | `IsCloseTask` in `dbo.MtbApprovalTaskList` | Read by the view at query time, so changing a row changes `closedDate` / `closedType` without a redeploy. Reload it by re-running `035`. |
| Published standards | `dbo.MTB_MDE_STT`, `dbo.MTB_MDE_WWP_STT` | Copied into `dbo.stdPermitTT` by `EXEC dbo.uspBuildStdPermitTT`. Only the `New`, `Renew` and `Renewal` permit classes are measured. |
| Excluded data | `dbo.vwPermitTurnaroundPerformance` | Rows with a date before 1900-01-01 are treated as data-entry errors and excluded. |
| Excluded sites | `dbo.AiExclusionList` | Activities whose `MASTER_AI_ID` is listed with `is_active = 1` are left out of the view and both reports. Read at query time: add a row to exclude a test or functional Agency Interest, or set `is_active = 0` to bring it back, with no redeploy. |
| Logging | `logs.ExecutionLog` (from `015`) | `uspBuildStdPermitTT` and the six report procedures log every run: start and end time (UTC), elapsed milliseconds, success, and the parameters used. For the report procedures, the parameters include `ReportUser=`, the person who ran the report. `auditCreatedBy` only shows the data source's stored login. The report procedures also record the rows returned and the resolved period in `Comments`, or the error and the phase it failed in. |
| Grants | `db_executor` role | `EXECUTE` is granted to it when the role exists, and skipped silently when it does not. |
| Claude Code | `.claude/settings.json` | Runs `.claude/hooks/validate-sql.py` on every `.sql` file Claude writes. The hook checks against SQL Server **2022**, so it will not catch 2022-only syntax in a file meant for the 2019 server. The `ponytail-sql-objects` skill holds the project's SQL conventions. |
| Report display | `TurnaroundPerformance.rdl` | Excel tab names come from the `PageName` of the About rectangle and the six tables. The About tab is hidden in the browser by `=Globals!RenderFormat.IsInteractive`. |
