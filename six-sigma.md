# Applying Six Sigma to Permit Turnaround Performance

**Short answer: yes.** Permit processing is a repeatable process with a clear start (application received), a clear
end (approval issued or closed), and a published target (the standard turnaround time). That is all Six Sigma needs.
This project already provides most of the **Measure** phase. It records the turnaround time for every permit-family
activity in ETS and compares it with the standard that was in force when the application arrived.

Six Sigma suits an administrative process like this. The *Lean* half of Lean Six Sigma will probably pay off more
than the statistics, because most of the time in a permit's life is spent waiting rather than being worked on.

---

## 1. Defining a "defect"

Six Sigma counts defects against a specification limit. Here the limit is already published:

| Six Sigma term | In this project |
|---|---|
| Unit | One permit activity (`INT_DOC_ID` in `dbo.vwPermitTurnaroundPerformance`) |
| Upper specification limit (USL) | `std_turnaround_time`, the standard in force on `application_received` |
| Measurement | `derived_days_qty`, or one clock chosen on purpose (see section 3) |
| Defect | An issued permit whose turnaround time is greater than `std_turnaround_time` |
| Opportunity | One per permit. Each permit either meets the standard or does not. |

From these definitions you can calculate the standard Six Sigma figures for any program, permit type, or period:

- **Defect rate**: late permits ÷ permits issued
- **DPMO** (defects per million opportunities): defect rate × 1,000,000
- **Sigma level**: the normal quantile of (1 − defect rate), plus the conventional 1.5 shift. For example, 31% late is
  about 2.0σ, 6.7% is about 3.0σ, 0.6% is about 4.0σ, and 3.4 per million is 6.0σ.

A realistic goal is to move each permit type up one sigma level. Six sigma itself (3.4 late permits per million) is
not a sensible target for a regulatory process.

A starting query for the defect rate. It uses the same population as the Summary procedure (issued in the period,
with a received date and a standard):

```sql
SELECT v.program_desc
     , v.permit_type
     , v.std_turnaround_time
     , COUNT (*)                                                              AS issued_qty
     , SUM (IIF (v.derived_days_qty > v.std_turnaround_time, 1, 0))           AS late_qty
     , 1.0 * SUM (IIF (v.derived_days_qty > v.std_turnaround_time, 1, 0))
           / COUNT (*)                                                        AS defect_rate
  FROM dbo.vwPermitTurnaroundPerformance AS v
 WHERE v.approval_issued >= '2025-07-01' AND v.approval_issued < '2026-07-01'   -- state FY 2026
   AND v.application_received IS NOT NULL
   AND v.std_turnaround_time IS NOT NULL
   AND v.derived_days_qty >= 0                                                  -- exclude reversed dates
 GROUP BY v.program_desc, v.permit_type, v.std_turnaround_time
 ORDER BY defect_rate DESC;
```

---

## 2. DMAIC, phase by phase

### Define

- **Project charter, one per program or permit type.** Write the problem as a number, for example "Tidal Wetlands
  licenses: X% exceeded the standard in FY 2026". Pick high-volume, high-defect permit types first. The Summary tab
  of the report already ranks them by volume.
- **Voice of the customer.** Applicants care about predictability as well as averages. A permit that is usually 30
  days but sometimes 200 is worse for them than one that is reliably 60. The standards are the agency's published
  promise, so they are the natural critical-to-quality (CTQ) measure.
- **SIPOC** (suppliers, inputs, process, outputs, customers): the applicant (supplier), the application and supporting
  documents (inputs), the ETS task sequence in `ACTIVITY_TASK_LIST` (process), the approval or closure (output), and
  the applicant and the public (customers).
- **Scope boundaries.** Decide up front whether the clock is calendar time or EPAL_ISSI's working-time clock. This
  decision is a definition, not a technicality (see section 3).

### Measure

- **The baseline already exists.** Run the report for the last full fiscal year and record the defect rate, DPMO and
  sigma level for each permit type. That becomes the "before" figure.
- **Measurement system analysis (MSA).** In Six Sigma you have to show the measurement can be trusted before you act
  on it. Section 3 lists the measurement problems this project has already found.
- **Process capability.** For each permit type, calculate **Ppk = (USL − mean) ÷ 3σ**, using `std_turnaround_time` as
  the USL. A Ppk below 1.0 means the process, as it currently runs, cannot reliably meet its own standard. That is a
  stronger claim than "it was late last quarter". Turnaround data is right-skewed, so use the non-normal method: fit a
  lognormal or Weibull distribution, or use percentiles.
- **Collection plan.** The view is evaluated live, so a measurement taken today will differ slightly from one taken
  next month (open rows keep aging). For a fixed baseline, take a snapshot of the report output and store it with the
  date.

### Analyze

- **Pareto charts.** Rank late permits by program, permit category, permit type, and `project_type`. A few
  combinations usually account for most of the late permits.
- **Stratification and hypothesis tests.** Compare groups the view can already separate: tidal and nontidal, major and
  minor, new and renewal (`permit_class`), and period or fiscal year. Turnaround times are not normally distributed,
  so use Mann–Whitney or Kruskal–Wallis tests on medians rather than t-tests.
- **Where the time goes.** `ACTIVITY_TASK_LIST` holds a completed date for every task. Splitting each permit's
  timeline into the gaps between tasks shows where the days are spent, for example "completeness review to technical
  review averages 40 days, of which 35 are queue time". This is the most useful analysis that isn't built yet, and it
  needs a new view at task level (see section 4).
- **Cause-and-effect (fishbone) diagram.** Run a workshop with permit staff using the Pareto results. Typical
  branches: incomplete applications, additional-information requests, staffing and workload, handoffs between
  programs, public notice periods, and outside agency reviews.
- **Regression.** Model turnaround time against workload at the time of receipt, application completeness, project
  type and season. This separates causes the agency controls from those it doesn't.
- **Right-censoring.** Permits still open have no end date yet. Leaving them out makes performance look better than it
  is. Survival analysis (Kaplan–Meier curves) handles open permits correctly. The view's `closedDate` column identifies
  the population that is genuinely still open.

### Improve

- **Lean waste removal.** Use the task-gap analysis to target queue time, handoffs, rework (repeated
  information requests), and batching (for example, applications reviewed only at a weekly meeting).
- **Mistake-proofing (poka-yoke) at intake.** If incomplete applications drive delays, completeness checklists or
  required fields at submission prevent the defect rather than detecting it later.
- **Triage by complexity.** Route simple renewals and minor permits on a fast track so they don't queue behind complex
  ones. A different `std_turnaround_time` for each permit type already shows the standards treat them differently.
- **Workload leveling.** If regression shows turnaround tracks the incoming volume, balance assignments across staff or
  regions.
- **Pilot and verify.** Change one program first. Then compare the before and after defect rates and sigma levels
  with the same report and parameters, and test whether the difference is statistically significant.

### Control

- **The report is the control plan's measuring tool.** It can be rerun for any period with the same definitions,
  and it uses the standard in force for each permit, so later changes to the standards don't distort earlier periods.
- **Control charts (statistical process control).**
  - A **p-chart** of the monthly late percentage for each program. Use fiscal period codes 6–17 to run month by month.
  - An **XmR chart** (individuals and moving range) of monthly median turnaround time.
  - Points outside the control limits signal a special cause that is worth investigating. Points inside the limits
    are common-cause variation and shouldn't trigger a reaction.
- **An aging (backlog) chart** of open permits that are approaching their standard. This is a leading indicator: it
  warns before a defect happens. Use the open population, `closedDate IS NULL AND approval_issued IS NULL`.
- **Response plan.** Write down who acts, and how, when a chart signals.
- **Audit trail.** `logs.ExecutionLog` now records who ran the report and when (`ReportUser=` in `KeyParameters`).
  This shows whether the control plan is actually being followed, for example whether a program manager reviews the
  monthly figures.

---

## 3. Measurement system issues to resolve first

These come from the view's own documentation. Each one could cause a wrong conclusion if it is ignored.

| Issue | Six Sigma consequence | What to do |
|---|---|---|
| **Two clocks.** `days_used_qty` (EPAL_ISSI's working-time clock) is NULL on most rows. `calendar_days_qty` is calendar time. `derived_days_qty` mixes the two. | Mixing measures inflates variation and makes capability figures meaningless. | Pick one clock per study. For a mixed study, split by `days_used_qty IS NULL`. |
| **Negative durations.** About 1,100 rows have the received and issued dates in the wrong order. | These are data-entry defects. If kept, they distort the mean and standard deviation. | Exclude them with `>= 0`, and report the count as a separate data-quality defect rate. |
| **Open rows keep aging.** `calendar_days_qty` measures to today when there is no approval date. That includes about 6,000 permits that were closed without being issued. | Inflates turnaround for permits that actually stopped. | Use the issued population for capability. Use `closedDate` to separate closed permits from those genuinely open. |
| **Closed without issue** (withdrawn, denied, voided, and so on) | Not a turnaround outcome. Including them blurs the definition of a defect. | Define them out of the turnaround measure, or track them as a separate outcome. |
| **Unmatched standards.** Some activities have no `std_turnaround_time`. | There is no USL to measure them against, so they are left out of the defect count. | Report coverage as its own measure and fix gaps in `MTB_MDE_STT`. |
| **Excluded sites and pre-1900 dates** (`dbo.AiExclusionList`) | The population changes when the list changes, with no redeploy. | Record the exclusion list's contents with every baseline snapshot. |

A Six Sigma practitioner would do a formal gage study here. The practical version is to choose one clock and one
population, write the definitions down, and then keep them fixed between the before and after measurements.

---

## 4. Additions to this project that would support a Six Sigma program

1. **A capability procedure or report tab.** For each permit type: count, median, 90th percentile, defect rate, DPMO,
   sigma level and Ppk.
2. **A monthly trend dataset** for p-charts and XmR charts, using periods 6–17 for each fiscal year.
3. **A task-level view** over `ACTIVITY_TASK_LIST`, with the time between consecutive tasks for each permit. This is
   needed for value-stream mapping and the Analyze phase.
4. **An aging or backlog view** of open permits, with days remaining before their standard. This is the leading
   indicator for the Control phase.
5. **Baseline snapshots.** A table holding the measured figures by date, so that before and after comparisons don't
   drift as live data changes.

---

## 5. Evaluating a 25% cut to the standards

Executive management wants to reduce standard turnaround times by 25% and to use this data to support it.

### As stated, the goal is not a Six Sigma goal

The standard turnaround time is the upper specification limit (USL), the line each permit is judged against. In Six
Sigma the specification is the customer's requirement. You improve the **process** to meet it; you don't improve
performance by moving the line.

Lowering the standard by 25% without changing how permits are processed tightens the specification on the same
process:

- More permits become late.
- The sigma level drops.
- Applicants get nothing faster.

The data would show performance getting worse, which is the opposite of what leadership wants to show.

### Reframed, it fits

Make the target about the process: *"Reduce actual turnaround enough that each permit type reliably meets a standard
25% lower than today's."* That gives a measurable Six Sigma objective: per permit type, a target on-time rate or
capability measured against 0.75 × the current standard.

The data can test this before anyone commits. For every permit type, the question is: **if the standard were 25%
lower today, what share of last year's permits would have been late?**

### Where the answer is

- **The report's Standard Reduction tab.** It runs for any period and filters, and the Standard Reduction % prompt
  sets the cut (default 25). The About tab explains each column for report users.
- **The procedure behind it**, `dbo.uspPermitTurnaroundStandardReduction` (`052`), for anyone working in SQL:

  ```sql
  EXEC dbo.uspPermitTurnaroundStandardReduction @FiscalType = 1, @FiscalYear = 2026, @ReductionPercent = 25;
  ```

The query behind it, for state fiscal year 2026:

```sql
WITH issued AS (
    SELECT v.program_desc
         , v.permit_type
         , v.std_turnaround_time
         , v.derived_days_qty AS days
         , PERCENTILE_CONT (0.5) WITHIN GROUP (ORDER BY v.derived_days_qty)
               OVER (PARTITION BY v.program_desc, v.permit_type, v.std_turnaround_time) AS median_days
         , PERCENTILE_CONT (0.9) WITHIN GROUP (ORDER BY v.derived_days_qty)
               OVER (PARTITION BY v.program_desc, v.permit_type, v.std_turnaround_time) AS p90_days
      FROM dbo.vwPermitTurnaroundPerformance AS v
     WHERE v.approval_issued >= '2025-07-01' AND v.approval_issued < '2026-07-01'   -- state FY 2026
       AND v.application_received IS NOT NULL
       AND v.std_turnaround_time IS NOT NULL
       AND v.derived_days_qty >= 0
)
SELECT i.program_desc
     , COALESCE (i.permit_type, '(no permit type)')                 AS permit_type
     , i.std_turnaround_time
     , i.std_turnaround_time * 0.75                                 AS proposed_std
     , COUNT (*)                                                    AS issued_qty
     , AVG (IIF (i.days > i.std_turnaround_time,        1.0, 0.0)) AS late_rate_now
     , AVG (IIF (i.days > i.std_turnaround_time * 0.75, 1.0, 0.0)) AS late_rate_at_proposed
     , MAX (i.median_days)                                          AS median_days
     , MAX (i.p90_days)                                             AS p90_days
  FROM issued AS i
 GROUP BY i.program_desc, i.permit_type, i.std_turnaround_time
 ORDER BY late_rate_at_proposed DESC;
```

The percentiles are window functions, so nothing is joined back. An earlier draft joined a second grouped set back on
`permit_type`, and that silently dropped every permit with no permit type, because in SQL `NULL = NULL` is not true.
`PARTITION BY` and `GROUP BY` both treat NULLs as one group.

The procedure adds `program_code`, `permit_category`, the late counts and the readiness label to this
query. It also applies the report's
period and filter parameters and logs each run.

### Reading the result

| Readiness | Test | What it means | Action |
|---|---|---|---|
| **Ready now** | 90th percentile ≤ proposed standard | Nine in ten permits already finish within the lower standard | Lower the standard now. This is a quick win. |
| **Improvement project** | Median ≤ proposed < 90th percentile | Typical permits make it, but the slow tail doesn't | A good Six Sigma project: reduce variation and the slow cases |
| **Redesign needed** | Median > proposed standard | Most permits would be late | Needs a process redesign (Lean, removing waiting and handoffs), not a target change |

Each row also shows the share of permits late now and the share that would be late at the proposed standard. The gap
between the two is how many more permits would miss the standard if it were lowered and nothing else changed.

### Points to raise with leadership

- **A flat 25% across the board is arbitrary.** Six Sigma sets targets from data: per permit type, based on current
  capability and on how much of the time the agency controls. Some types may handle 40%; others may have no room at
  all. Use the Standard Reduction % prompt to find the figure each permit type can bear.
- **Some time isn't the agency's to cut.** Public notice and comment periods, and reviews by other agencies, are
  required steps. A 25% cut has to come entirely from the remaining time, so the cut to the agency's own share is
  larger than 25%.
- **Some standards may be fixed by statute or regulation.** Changing them could need a regulatory action, not just a
  data change.
- **Measure before changing the standard.** Lower the standard only after the process has improved, once the data
  shows the new target is being met consistently.
- **Choose one clock.** `derived_days_qty` mixes working days and calendar days (section 3). A 25% target needs to
  name which one it means.
- **Small groups.** A permit type with only a few permits issued can land in any readiness group by chance. Read
  `issued_qty` before the label.
- **The project already supports a fair before-and-after comparison.** Standards are effective-dated, and each permit
  is measured against the standard in force when it was received. New, lower standards can be added with an effective
  date without restating past results.

**Recommendation:** present the goal as "reduce actual turnaround time so standards can be lowered by up to 25% where
the data shows it's achievable". Use the Standard Reduction tab to sort permit types into the three groups, then
focus improvement work on the Improvement project group.

---

## 6. Cautions

- **Averages hide the problem.** The Summary tab reports the average days. Six Sigma is about reducing variation and
  the tail of the distribution, so add the median, 90th percentile and late percentage before drawing conclusions.
- **Small groups.** Many permit types have low volumes. Their sigma level and control limits will be unstable, so
  group them, or use longer periods.
- **Statutory waits are not waste.** Public notice and comment periods, and reviews by other agencies, are required
  steps. Separate them from the time the agency controls before setting improvement targets.
- **Gaming.** A measure that stops the clock invites stopping it early, for example by closing or re-opening
  applications. Monitor closure types alongside the turnaround measure.
