#!/usr/bin/env python
"""
PostToolUse hook: validate .sql files against this project's SQL Server conventions.

Reads the Claude Code hook payload on stdin, checks the edited .sql file, and writes any
violations to stderr with exit code 2 so they are fed back to the model as a defect list.

Conventions enforced (see .claude/skills/ponytail-sql-objects/SKILL.md, which is the
authority on all of them — there is no separate requirements document):
  - the 7 standard audit columns on every CREATE TABLE
  - DF_<schema>_<table>_<field> constraint naming, with the correct schema and table
  - MS_Description extended properties on tables and columns
  - object header block on views / procedures / functions / triggers
  - no hard DELETE, no ON DELETE CASCADE
  - no SQL Server 2025-only features (target is SQL Server 2022)
  - unique indexes filtered on IsDeleted = 0
  - re-runnable DDL: a developer runs these scripts by hand, so CREATE must be guarded,
    views/procedures/functions/triggers use CREATE OR ALTER, extended properties go through
    util.uspSetObjectDescription, and nothing is dropped or truncated to make a script re-run
"""

import json
import re
import sys
from pathlib import Path

AUDIT_COLUMNS = [
    "IsDeleted",
    "auditDeletedBy",
    "auditDeletedDateUtc",
    "auditCreatedBy",
    "auditCreatedDateUtc",
    "auditModifiedBy",
    "auditModifiedDateUtc",
]

AUDIT_BY_COLUMNS = ["auditDeletedBy", "auditCreatedBy", "auditModifiedBy"]

# DEFAULT (ORIGINAL_LOGIN()) returns sysname, which is NVARCHAR(128). Anything narrower
# makes the default itself raise a truncation error and fail the insert.
AUDIT_BY_MIN_WIDTH = 128

# The five consumer schemas, plus the three the row-history arrangement requires. A temporal table
# keeps its system-versioned base table in <schema>Data and its history table in history, with a
# view in the consumer schema as the only write path -- so a table in dbo that opts into row history
# touches dbo, dboData and history. Those three are structural to that feature, not drift: they are
# where templates/table-temporal.sql and scripts/logdBChanges.sql put their base and history tables,
# and without them the skill's own scripts cannot pass the gate they are the reference for.
#
# Stored in their real casing so the violation message names the schema a developer would type;
# compared case-insensitively through the lowered set below, because SQL Server object names are.
VALID_SCHEMAS = {"dbo", "auth", "logs", "config", "util", "dboData", "logsData", "history"}

VALID_SCHEMAS_LOWER = {s.lower() for s in VALID_SCHEMAS}

# SQL Server 2025-only features. UAT and Production are SQL Server 2022.
FORBIDDEN_2025 = [
    (r"\bREGEXP_(LIKE|REPLACE|SUBSTR|COUNT|INSTR|MATCHES|SPLIT_TO_TABLE)\s*\(",
     "regex function is SQL Server 2025 only; use LIKE/PATINDEX or validate in the .NET loader"),
    (r"\bJSON_(OBJECTAGG|ARRAYAGG|CONTAINS)\s*\(",
     "SQL Server 2025 only; not available on 2022"),
    (r"\bVECTOR_(DISTANCE|NORM|NORMALIZE)\s*\(",
     "vector functions are SQL Server 2025 only"),
    (r"\bOPTIMIZED_LOCKING\b",
     "OPTIMIZED_LOCKING is SQL Server 2025 only"),
    (r"^\s*\w+\s+json\s*(,|$|\s+(NOT\s+)?NULL)",
     "native json type is SQL Server 2025 only; use NVARCHAR(MAX) with CHECK (ISJSON(col) = 1)"),
    (r"\bVECTOR\s*\(\s*\d+\s*\)",
     "the VECTOR type is SQL Server 2025 only"),
]

# Cross-database references. Every object must resolve inside its own database. A second database
# that shares the developer's single instance is routinely on a DIFFERENT SQL Server in UAT and
# Production, so a three-part name that works locally fails there — and fails at run time, not at
# deploy time, which is what makes it worth catching here. Move data between databases through the
# application, not through a name.
#
# To forbid one database by name as well, add its own rule: (r"\bthat_database\b", "why not").
CROSS_DATABASE = [
    # server.database.schema.object
    (r"\b\[?\w+\]?\.\[?\w*\]?\.\[?\w+\]?\.\[?\w+\]?\b(?!\s*\()",
     "four-part name reaches another server through a linked server; not permitted"),
    # FROM/JOIN/INTO/UPDATE/MERGE/EXEC database.schema.object
    (r"\b(?:FROM|JOIN|INTO|UPDATE|MERGE|EXEC|EXECUTE)\s+\[?(\w+)\]?\.\[?\w+\]?\.\[?\w+\]?\b",
     "three-part name references another database; every object must resolve inside its own"),
    (r"\bCREATE\s+SYNONYM\b[\s\S]{0,200}?\bFOR\s+\[?\w+\]?\.\[?\w+\]?\.\[?\w+\]?",
     "a synonym pointing outside this database hides a cross-database dependency behind a "
     "local-looking name; that is worse than the three-part name it replaces"),
    (r"\bOPEN(QUERY|DATASOURCE|ROWSET)\s*\(",
     "ad-hoc distributed query; these objects read no other server"),
]

# Re-runnable DDL. The developer runs every script by hand, so a second run must be a
# no-op. The usual shortcut for making a script re-runnable — DROP then CREATE — destroys real
# data and is forbidden outright; this database has no hard deletes anywhere.
DESTRUCTIVE_DDL = [
    (r"\bDROP\s+TABLE\b",
     "DROP TABLE destroys data; guard the CREATE with OBJECT_ID instead of dropping to re-run"),
    (r"\bTRUNCATE\s+TABLE\b",
     "TRUNCATE TABLE is a hard delete; set IsDeleted = 1 instead"),
    (r"\bALTER\s+TABLE\b[\s\S]{0,200}?\bDROP\s+COLUMN\b",
     "DROP COLUMN destroys data; deprecate the column instead"),
    (r"\bDROP\s+DATABASE\b",
     "DROP DATABASE is never part of a deployment script"),
    (r"\bDROP\s+SCHEMA\b",
     "DROP SCHEMA is never part of a deployment script"),
]

# These object kinds are replaced in place, preserving object_id and extended properties.
OR_ALTER_KINDS = {"VIEW", "PROCEDURE", "PROC", "FUNCTION", "TRIGGER"}

# How far back to look for the IF-guard that makes a CREATE re-runnable.
GUARD_LOOKBEHIND = 400

HEADER_FIELDS = ["ObjectName:", "Author:", "CreateDate:", "Description:", "Modification History:"]

# Procedures exempt from the "every procedure records its own errors" rule, and the only ones.
# The four logging procedures cannot call the logging procedures -- uspRecordExecutionError calling
# itself from its own CATCH is an unbounded recursion on the very failure it exists to survive --
# and util.uspSetObjectDescription is deployed before logs.ExecutionLog exists, so it cannot call
# into it either. This list is closed: a sixth entry is a design change, not a fix.
INSTRUMENTATION_EXEMPT = {
    "logs.uspStartExecutionLoggingInsert",
    "logs.uspStartExecutionLogging",
    "logs.uspRecordExecutionErrorUpdate",
    "logs.uspRecordExecutionError",
    "util.uspSetObjectDescription",
}

OBJECT_PREFIX = {
    "VIEW": "vw",
    "PROCEDURE": "usp",
    "PROC": "usp",
    # FUNCTION is resolved per object by function_prefix(): udf when scalar, tvf when
    # table-valued. It is absent from this map on purpose -- a single entry would enforce
    # the wrong one on half the functions in the database.
}

# The prefix is not the whole convention: what follows it is PascalCase. Enforced for the four
# kinds SKILL.md names a prefix for. Triggers are deliberately absent -- the conventions do not
# specify a trigger prefix, and inventing one in the gate is not the place to decide it.
PASCAL_AFTER_PREFIX = re.compile(r"[A-Z][A-Za-z0-9]*\Z")

# How far past CREATE FUNCTION <name> to look for the RETURNS clause that says scalar or table.
# Generous, because the parameter list sits in between and can be long.
FUNCTION_RETURNS_LOOKAHEAD = 4000


def strip_strings_and_comments(sql: str) -> str:
    """Blank out block comments, line comments and string literals so keyword scans
    do not fire on prose or sample data. Length is preserved so line numbers stay valid."""
    out = list(sql)
    i, n = 0, len(sql)
    while i < n:
        two = sql[i:i + 2]
        if two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                if sql[j:j + 2] == "/*":
                    depth, j = depth + 1, j + 2
                elif sql[j:j + 2] == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif two == "--":
            j = sql.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif sql[i] == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'" and sql[j:j + 2] != "''":
                    j += 1
                    break
                j += 2 if sql[j:j + 2] == "''" else 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def is_guarded(code: str, pos: int) -> bool:
    """True if this CREATE sits inside an existence check, which is what makes the script
    safe to run a second time. Looks back a short way for an IF whose test is an OBJECT_ID /
    COL_LENGTH / sys.* NOT EXISTS probe."""
    window = code[max(0, pos - GUARD_LOOKBEHIND):pos]
    if not re.search(r"\bIF\b", window, re.I):
        return False
    return bool(re.search(r"OBJECT_ID\s*\(|COL_LENGTH\s*\(|NOT\s+EXISTS\s*\(|"
                          r"\bIS\s+NULL\b|SCHEMA_ID\s*\(|DB_ID\s*\(", window, re.I))


def function_prefix(code: str, pos: int) -> str:
    """'tvf' for a table-valued function, 'udf' for a scalar one, decided by the RETURNS clause.
    Both inline (RETURNS TABLE) and multi-statement (RETURNS @t TABLE) forms are table-valued.

    Only the FIRST RETURNS after the name is consulted -- a function has exactly one, and a
    plain search across the lookahead window happily finds a LATER function's RETURNS TABLE and
    calls this one table-valued. Measured: a scalar udfIsValid two objects above a tvf was
    reported as needing the 'tvf' prefix. 'RETURN' in a body does not match \\bRETURNS\\b."""
    window = code[pos:pos + FUNCTION_RETURNS_LOOKAHEAD]
    first = re.search(r"\bRETURNS\b", window, re.I)
    if not first:
        return "udf"
    return "tvf" if re.match(r"RETURNS\s+(@\w+\s+)?TABLE\b",
                             window[first.start():], re.I) else "udf"


def pascal_suggestion(prefix: str, name: str) -> str:
    """A usable replacement name for the message, rather than a lowercased run-on. Swaps a
    sibling prefix rather than stacking on top of it, and capitalizes across underscores."""
    for sibling in ("usp", "tvf", "udf", "vw"):
        if name.startswith(sibling):
            name = name[len(sibling):]
            break
    words = [w for w in name.split("_") if w]
    return prefix + "".join(w[:1].upper() + w[1:] for w in words) if words else prefix + "Name"


def check(sql: str, path: str) -> list[str]:
    code = strip_strings_and_comments(sql)
    problems: list[str] = []

    def add(line: int | None, msg: str) -> None:
        problems.append(f"{path}:{line}: {msg}" if line else f"{path}: {msg}")

    # ---- every deployment script sets QUOTED_IDENTIFIER ON itself -------------------------
    # sqlcmd defaults QUOTED_IDENTIFIER OFF where every other client defaults it ON, and the
    # setting is BAKED IN at CREATE time and stored in sys.sql_modules. A module -- or the
    # session running plain DML -- carrying it OFF cannot write to a table with a filtered
    # index: error 1934. EVERY unique constraint in this database is a filtered index
    # (WHERE IsDeleted = 0), so that is every table.
    #
    # A deployment script can pass -I every time, and the rule exists because that is not
    # enough: a human runs these scripts BY HAND, and a hand-typed sqlcmd line without -I
    # deployed logs.uspStartLoadRun and logs.uspGetFacilityLoadResumeSet compiled OFF. The
    # scripts then failed at run time, well away from the command that broke them, on an
    # UPDATE inside a procedure that reads perfectly correctly. A script whose correctness
    # depends on which client invoked it is not re-runnable in the sense this rule means.
    if re.search(r"(?im)^\s*CREATE\s+(OR\s+ALTER\s+)?"
                 r"(TABLE|PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER|SCHEMA)\b", code) \
            and not re.search(r"(?im)^\s*SET\s+QUOTED_IDENTIFIER\s+ON\s*;", sql):
        add(None, "this script does not SET QUOTED_IDENTIFIER ON. sqlcmd defaults it OFF, the "
                  "setting is baked in at CREATE time, and a module or session carrying it OFF "
                  "cannot run DML against a table with a filtered index (error 1934) — which is "
                  "every table here. Put 'SET QUOTED_IDENTIFIER ON;' beside SET XACT_ABORT ON, "
                  "so a hand run without sqlcmd -I cannot get it wrong")

    # ---- CREATE TABLE checks -------------------------------------------------------------
    tables = list(re.finditer(
        r"CREATE\s+TABLE\s+(?:\[?(\w+)\]?\.)?\[?(\w+)\]?", code, re.I))

    # The row-history arrangement's base tables, by name. A table opting into row history lives in
    # <schema>Data and is fronted by a view in the consumer schema that carries THE TABLE'S OWN
    # NAME -- dboData.Permit under dbo.Permit -- because the view is the only write path and every
    # consumer is meant to read it without knowing the table is temporal. Renaming that view to
    # vwPermit would defeat the whole arrangement, so the prefix rule below exempts a view whose
    # name matches one of these.
    #
    # Scoped to tables created in THIS file, which is what makes the exemption narrow: it cannot be
    # claimed by a view that merely shares a name with a base table somewhere else in the estate.
    # Both the skill's template and scripts/logdBChanges.sql keep the pair in one script, so the
    # file is the right unit; a wrapper view split from its base table would have to be told about
    # here instead.
    row_history_tables = {m.group(2) for m in tables
                          if (m.group(1) or "").lower().endswith("data")}

    # AND the same arrangement arrived at by RETROFIT, which is how an existing populated table joins it:
    # templates/table-temporal.sql section 3 moves the table with ALTER SCHEMA dboData TRANSFER rather than
    # creating it, precisely so the data and the indexes survive, and there is then no CREATE TABLE in the
    # file for the rule above to find. Measured on database/_tests/080_clean_water_wrapper.sql: the wrapper
    # view was reported as needing the 'vw' prefix, which is the one name it must NOT have -- it carries the
    # table's own name so that every consumer written against the table keeps working, which is the whole
    # point of doing the conversion this way. The gate was reading a documented migration path as drift.
    #
    # Same file scoping, and so the same narrowness, as the CREATE TABLE case: the TRANSFER has to be in
    # this file. Both forms of the statement are matched -- the bare name and the OBJECT:: prefix.
    row_history_tables |= {
        m.group(2) for m in re.finditer(
            r"ALTER\s+SCHEMA\s+\[?(\w+)\]?\s+TRANSFER\s+(?:OBJECT\s*::\s*)?\[?\w+\]?\.\[?(\w+)\]?",
            code, re.I)
        if m.group(1).lower().endswith("data")}

    for m in tables:
        schema, table = (m.group(1) or "dbo"), m.group(2)
        ln = line_of(code, m.start())

        if schema.lower() not in VALID_SCHEMAS_LOWER:
            add(ln, f"schema '{schema}' is not one of {sorted(VALID_SCHEMAS)}")

        if not re.match(r"^[A-Z][A-Za-z0-9]*$", table):
            add(ln, f"table '{table}' should be PascalCase with no type prefix")

        # Body of this CREATE TABLE: up to the next CREATE TABLE or end of file.
        nxt = next((t.start() for t in tables if t.start() > m.start()), len(code))
        body = code[m.start():nxt]

        for col in AUDIT_COLUMNS:
            if not re.search(rf"\b{col}\b", body):
                add(ln, f"table {schema}.{table} is missing required audit column '{col}'")

        # audit*By must be wide enough to hold whatever ORIGINAL_LOGIN() returns.
        for bm in re.finditer(
                rf"\b({'|'.join(AUDIT_BY_COLUMNS)})\b\s+"
                r"(N?VARCHAR|N?CHAR)\s*\(\s*(MAX|\d+)\s*\)", body, re.I):
            col, typ, width = bm.group(1), bm.group(2).upper(), bm.group(3).upper()
            bl = line_of(code, m.start() + bm.start())
            if not typ.startswith("N"):
                add(bl, f"{col} is {typ}({width}); must be NVARCHAR because "
                        f"ORIGINAL_LOGIN() returns sysname (NVARCHAR({AUDIT_BY_MIN_WIDTH}))")
            elif width != "MAX" and int(width) < AUDIT_BY_MIN_WIDTH:
                add(bl, f"{col} is NVARCHAR({width}); must be at least "
                        f"NVARCHAR({AUDIT_BY_MIN_WIDTH}) or DEFAULT (ORIGINAL_LOGIN()) "
                        f"can itself raise a truncation error and fail the insert")

        # Constraint naming: DF_<schema>_<table>_<field>
        for dm in re.finditer(r"CONSTRAINT\s+\[?(DF_\w+)\]?", body, re.I):
            name = dm.group(1)
            expected_prefix = f"DF_{schema}_{table}_"
            if not name.startswith(expected_prefix):
                add(line_of(code, m.start() + dm.start()),
                    f"constraint '{name}' must be named "
                    f"'{expected_prefix}<fieldName>' for table {schema}.{table} "
                    f"(default constraint names must be unique per database)")

        if not re.search(r"uspSetObjectDescription", sql, re.I):
            add(ln, f"table {schema}.{table} has no MS_Description extended property "
                    f"(set it with util.uspSetObjectDescription)")

    # ---- unique indexes must be filtered on IsDeleted ------------------------------------
    for um in re.finditer(r"CREATE\s+UNIQUE\s+(?:CLUSTERED\s+|NONCLUSTERED\s+)?INDEX"
                          r"[\s\S]{0,400}?;", code, re.I):
        if not re.search(r"WHERE[\s\S]*IsDeleted\s*=\s*0", um.group(0), re.I):
            add(line_of(code, um.start()),
                "unique index must be filtered WHERE IsDeleted = 0, or a soft-deleted row "
                "will block re-creation of the same key")

    # ---- soft delete only ----------------------------------------------------------------
    # "DELETE FROM x", or a statement-position "DELETE x". Deliberately does not match the
    # mid-clause "ON DELETE CASCADE", which is reported separately below.
    delete_stmt = (
        r"\bDELETE\s+(?:TOP\s*\([^)]*\)\s*)?FROM\b"
        r"|(?:^|;)\s*DELETE\s+(?!FROM\b)\[?\w"
    )
    for dm in re.finditer(delete_stmt, code, re.I | re.M):
        add(line_of(code, dm.start()),
            "hard DELETE is not permitted; set IsDeleted = 1 instead")

    for dm in re.finditer(r"ON\s+DELETE\s+CASCADE", code, re.I):
        add(line_of(code, dm.start()),
            "ON DELETE CASCADE is not permitted; this database has no hard deletes")

    # ---- re-runnable DDL (a human runs these scripts by hand) ---------------------------
    for pattern, msg in DESTRUCTIVE_DDL:
        for dm in re.finditer(pattern, code, re.I):
            add(line_of(code, dm.start()), msg)

    # CREATE TABLE / SCHEMA / INDEX must sit behind an existence check.
    for gm in re.finditer(r"CREATE\s+(TABLE|SCHEMA)\b"
                          r"|CREATE\s+(?:UNIQUE\s+)?(?:CLUSTERED\s+|NONCLUSTERED\s+)?(INDEX)\b",
                          code, re.I):
        if is_guarded(code, gm.start()):
            continue

        # A temp table is not a re-run hazard. #Name is scoped to the session, a procedure that
        # creates one gets a fresh empty table on every call, and the name shadows anything the
        # caller made. Guarding it with IF OBJECT_ID (N'tempdb..#Name') IS NULL would be worse than
        # pointless: inside a procedure it would ADOPT the caller's table, rows and all, so the
        # guard the rule asks for is the bug. Measured on _tests/100_clean_water_procedures.sql,
        # where dbo.uspInsertCleanWaterProject must create #ReturnedIdentity to learn the new key --
        # SCOPE_IDENTITY () is NULL after an insert through an INSTEAD OF trigger.
        if re.match(r"CREATE\s+TABLE\s+#", code[gm.start():gm.start() + 40], re.I):
            continue

        what = (gm.group(1) or gm.group(2)).upper()
        hint = {
            "TABLE": "IF OBJECT_ID (N'<schema>.<Table>', N'U') IS NULL",
            "SCHEMA": "IF SCHEMA_ID (N'<schema>') IS NULL EXEC (N'CREATE SCHEMA ...') "
                      "-- CREATE SCHEMA must be alone in its batch, hence the EXEC",
            "INDEX": "IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = ... "
                     "AND object_id = OBJECT_ID (...))",
        }[what]
        add(line_of(code, gm.start()),
            f"unguarded CREATE {what}; the script must be safe to run twice. Wrap it: {hint}")

    # Extended properties are the most common re-run failure: sp_addextendedproperty succeeds
    # once and errors on every run after that. The one legitimate caller is the add-or-update
    # helper itself, so a file that defines it is exempt.
    defines_helper = re.search(r"CREATE\s+(?:OR\s+ALTER\s+)?PROCEDURE\s+"
                               r"\[?util\]?\.\[?uspSetObjectDescription\b", code, re.I)
    if not defines_helper:
        for em in re.finditer(r"sp_(add|update)extendedproperty", code, re.I):
            add(line_of(code, em.start()),
                f"sp_{em.group(1)}extendedproperty is not re-runnable "
                f"(add fails if the property exists, update fails if it does not); "
                f"call util.uspSetObjectDescription instead")

    # ---- JSON payloads, not table-valued parameters ---------------------------------------
    # Both halves are flagged, because either one alone leaves the design half-made. A user-defined
    # table type needs EXECUTE granted on the TYPE separately from the procedure -- a grant no
    # deployment script here issues, so a TVP procedure would fail for both application logins with
    # a permission error that names the type rather than the procedure. And a TVP parameter is
    # READONLY, which is the only place that keyword appears in T-SQL, so it catches a procedure
    # taking a type declared in some other file.
    for tm in re.finditer(r"\bCREATE\s+TYPE\b[\s\S]{0,300}?\bAS\s+TABLE\b", code, re.I):
        add(line_of(code, tm.start()),
            "CREATE TYPE ... AS TABLE: these conventions take an NVARCHAR (MAX) JSON payload "
            "over a table-valued parameter. Send a JSON array and shred it with OPENJSON, gated by "
            "ISJSON (@Payload, ARRAY) = 0")

    for rm in re.finditer(r"\bREADONLY\b", code, re.I):
        add(line_of(code, rm.start()),
            "READONLY is a table-valued-parameter modifier; these conventions take a JSON "
            "payload instead. Declare the parameter NVARCHAR (MAX)")

    # ---- SQL Server 2022 target ----------------------------------------------------------
    for pattern, msg in FORBIDDEN_2025:
        flags = re.I | (re.M if pattern.startswith("^") else 0)
        for fm in re.finditer(pattern, code, flags):
            add(line_of(code, fm.start()), f"{fm.group(0).strip()}: {msg}")

    # ---- everything resolves inside this database ----------------------------------------
    for pattern, msg in CROSS_DATABASE:
        for cm in re.finditer(pattern, code, re.I):
            add(line_of(code, cm.start()), f"{cm.group(0).strip()}: {msg}")

    # ---- object header block -------------------------------------------------------------
    # The header search window runs from the END of the previous object's CREATE to the start of
    # this one, NOT from the start of the file. With a whole-file prefix every object after the
    # first inherits the earlier objects' header fields, so a file whose first object is
    # documented lets every later object ship with no header at all -- measured: three headerless
    # objects following one documented procedure produced no output whatever.
    #
    # Note what is NOT wrong here, because an earlier revision of this note said it was:
    # slicing the original `sql` with an offset taken from `code` is sound, because
    # strip_strings_and_comments preserves length in every branch, including on an unterminated
    # comment or string literal. Line numbers do not drift. Slicing `sql` rather than `code` is in
    # fact required -- the header lives inside a comment, so `code` has blanked it out.
    prev_object_end = 0

    modules = list(re.finditer(
        r"CREATE\s+(OR\s+ALTER\s+)?(VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+"
        r"(?:\[?(\w+)\]?\.)?\[?(\w+)\]?", code, re.I))

    for om in modules:
        or_alter, kind = om.group(1), om.group(2).upper()
        schema, name = (om.group(3) or "dbo"), om.group(4)
        ln = line_of(code, om.start())

        if kind in OR_ALTER_KINDS and not or_alter:
            add(ln, f"CREATE {kind} {schema}.{name} must be CREATE OR ALTER {kind} — a human "
                    f"re-runs these scripts by hand, and OR ALTER keeps the object_id so grants "
                    f"and extended properties survive")

        preceding_start = prev_object_end
        preceding = sql[prev_object_end:om.start()]
        prev_object_end = om.end()

        if not all(f in preceding for f in HEADER_FIELDS):
            missing = [f.rstrip(':') for f in HEADER_FIELDS if f not in preceding]
            add(ln, f"{kind} {schema}.{name} is missing the standard header block "
                    f"(absent: {', '.join(missing)})")
        else:
            # ---- and the header must be in the SAME BATCH as the CREATE -------------------
            # sys.sql_modules stores only the batch that contains CREATE. A header separated
            # from it by a GO is present in the file and absent from the database, so
            # sp_helptext, OBJECT_DEFINITION and SSMS "Script as CREATE" all show an object
            # with no header -- which is where a maintainer actually reads one.
            #
            # This is not hypothetical and it is why the rule exists: all eleven procedures in
            # this database were deployed with no stored header at all, for exactly this
            # reason, while every view kept its own because nothing separated the two. The fix
            # in each file was to move the script-level SET XACT_ABORT ON / GO ABOVE the
            # header rather than to drop it.
            batch_breaks = list(re.finditer(r"(?im)^\s*GO\s*(?:--.*)?$", preceding))
            if batch_breaks:
                last_break = batch_breaks[-1].end()
                stranded = [f.rstrip(':') for f in HEADER_FIELDS
                            if f not in preceding[last_break:]]
                if stranded:
                    go_line = line_of(sql, preceding_start + batch_breaks[-1].start())
                    add(ln, f"{kind} {schema}.{name} has its header block separated from the "
                            f"CREATE by the GO on line {go_line}, so these fields never reach "
                            f"sys.sql_modules and the deployed object has no header: "
                            f"{', '.join(stranded)}. Move SET XACT_ABORT ON / GO ABOVE the "
                            f"header block — the header must be the last thing before CREATE")

        # ---- the @ProcName fallback must be THIS object's own name ----------------------
        # OBJECT_NAME (@@PROCID) returns NULL for a principal denied metadata visibility, and
        # the permission model denies exactly that to both application logins -- measured: a
        # read-only application login holds EXECUTE on a procedure and still reads NULL from
        # OBJECT_ID on it: a permission on an object is not permission to see its name. So the
        # COALESCE fallback is not a guard for ad-hoc batches; it is the branch every application call
        # takes, and a placeholder there logs every call anonymously into the one column the
        # monitoring web app groups by. This fired for real on two procedures under review.
        #
        # The body is sliced out of the ORIGINAL sql, not out of `code`: the literal being checked
        # IS a string literal, so `code` has blanked it. Offsets correspond -- see the note above.
        #
        # Matched on OBJECT_NAME (@@PROCID) rather than on @@PROCID alone, because @@PROCID has a
        # second, unrelated use that this rule must not fire on: TRIGGER_NESTLEVEL (@@PROCID,
        # 'AFTER', 'DML'), which is how the audit trigger in templates/table.sql section 4 guards
        # against re-firing under RECURSIVE_TRIGGERS. That trigger derives no @ProcName and logs
        # nothing, so demanding a COALESCE fallback of it asked for a string literal with no reader
        # -- measured: it was one of the 25 violations the gate reported against its own skill, and
        # it would now fire on all twelve audit triggers in database/135_audit_triggers.sql.
        body_end = next((n.start() for n in modules if n.start() > om.start()), len(code))
        if re.search(r"OBJECT_NAME\s*\(\s*@@PROCID\s*\)", code[om.end():body_end], re.I):
            expected = f"N'[{schema}].[{name}]'"
            if expected not in sql[om.end():body_end]:
                add(ln, f"{kind} {schema}.{name} derives @ProcName from @@PROCID but its COALESCE "
                        f"fallback is not {expected}. OBJECT_NAME (@@PROCID) is NULL for a "
                        f"principal denied metadata visibility, which is what the application "
                        f"logins are, so the fallback is what actually gets logged — a "
                        f"placeholder, or a name copied from another procedure, means "
                        f"logs.ExecutionLog.ProcedureName is wrong on every call the applications "
                        f"make")

        # ---- every procedure must RECORD its own errors, reads included -------------------
        # A review finding, 2026-09-05, from another application in the same estate: a procedure
        # whose body was a single SELECT called a scalar UDF inside that SELECT, the UDF errored,
        # and nothing was recorded anywhere -- because "it only reads" had been taken to mean "it
        # cannot fail
        # in a way worth recording". A read owns no INSERT, but a UDF, a view over a view, a
        # conversion, a deadlock or a permission it turns out not to hold can all fail inside one.
        #
        # So the requirement is not "instrumented" -- a read still skips the start row and the
        # completion UPDATE, which is a settled review decision and a cost question. The rule is
        # that the CATCH exists and CALLS uspRecordExecutionError. A CATCH holding only ;THROW; is
        # what this rule is aimed at as much as a missing CATCH is: it looks handled and records
        # nothing.
        if kind in ("PROCEDURE", "PROC") and f"{schema}.{name}" not in INSTRUMENTATION_EXEMPT:
            body = code[om.end():body_end]
            if not re.search(r"\bBEGIN\s+TRY\b", body, re.I):
                add(ln, f"PROCEDURE {schema}.{name} has no BEGIN TRY. Every procedure records its "
                        f"own errors, a read-only one included — a review found a procedure "
                        f"whose body was one SELECT calling a UDF, and when the UDF errored "
                        f"nothing was recorded anywhere. A read may skip the start row and the "
                        f"completion UPDATE; it may not skip the CATCH")
            elif not re.search(r"uspRecordExecutionError\b", body, re.I):
                add(ln, f"PROCEDURE {schema}.{name} has a TRY/CATCH that never calls "
                        f"logs.uspRecordExecutionError, so an error reaches the caller and leaves "
                        f"no row behind. A CATCH holding only ;THROW; is the case this rule "
                        f"exists for: it looks handled and records nothing. For a read-only "
                        f"procedure pass @ExecutionLogId = NULL — the MERGE in "
                        f"logs.uspRecordExecutionErrorUpdate inserts an orphan row on purpose")
            elif not re.search(r";\s*THROW\s*;", body, re.I):
                add(ln, f"PROCEDURE {schema}.{name} records its error but does not re-raise it "
                        f"with a bare ';THROW;', so the caller is told the call succeeded. "
                        f"RAISERROR is not a substitute — it replaces the error number with "
                        f"50000, and the client branches on 1205 (deadlock, retry) versus 2627 "
                        f"and 547 (constraint, do not)")

        # ---- a procedure rolls back only what it opened -----------------------------------
        # Found 2026-09-05 by a probe script, in logs.uspGetLoadRunPage and
        # logs.uspGetFacilityLoadStatusPage. Both were reads that opened a transaction "for template
        # fidelity" and carried the writers' `IF XACT_STATE () <> 0 ROLLBACK TRANSACTION;`. Two
        # separate defects came out of that one copied line:
        #
        #   1. XACT_STATE () <> 0 is true when the CALLER has a transaction open. Every validation
        #      refusal throws BEFORE the BEGIN TRANSACTION, so on the likeliest failure the procedure
        #      owned nothing and rolled back somebody else's work -- a read discarding a writer's
        #      uncommitted rows because it was handed a misspelled @SortBy.
        #   2. ROLLBACK is illegal inside INSERT ... EXEC (error 8004). It RAISED, replaced the error
        #      being reported, and aborted the CATCH before uspRecordExecutionError ran. The error was
        #      recorded nowhere, which is the exact omission the rule above exists to prevent -- so a
        #      procedure could satisfy that rule and still record nothing.
        #
        # The rule is deliberately about ownership rather than about reads: a procedure that opens its
        # own transaction still must roll it back, and all nineteen writers do. Only the pairing is
        # checked, because "did this ROLLBACK belong to this procedure" is not decidable from a
        # keyword scan and the pairing is what was actually wrong. Scoped to procedures: a ROLLBACK in
        # a TRIGGER aborts the firing statement by design and owns nothing.
        if kind in ("PROCEDURE", "PROC"):
            body = code[om.end():body_end]
            rb = re.search(r"\bROLLBACK\b", body, re.I)
            if rb and not re.search(r"\bBEGIN\s+TRAN(SACTION)?\b", body, re.I):
                add(line_of(code, om.end() + rb.start()),
                    f"PROCEDURE {schema}.{name} rolls back a transaction it never opened — there is "
                    f"a ROLLBACK but no BEGIN TRANSACTION. XACT_STATE () <> 0 is also true when the "
                    f"CALLER owns the transaction, so this discards work the procedure never did; "
                    f"and inside INSERT ... EXEC the ROLLBACK itself raises error 8004, which "
                    f"replaces the error being reported and aborts the CATCH before "
                    f"logs.uspRecordExecutionError can run. A read needs no transaction and no "
                    f"rollback: capture the ERROR_* values, record, ';THROW;'. If the procedure does "
                    f"need a transaction, open one")

        want = function_prefix(code, om.end()) if kind == "FUNCTION" else OBJECT_PREFIX.get(kind)

        # The one view that does not take the 'vw' prefix: the row-history wrapper, which carries
        # its base table's name on purpose. See row_history_tables above.
        if kind == "VIEW" and name in row_history_tables:
            want = None

        if want:
            if not name.startswith(want):
                extra = (" — table-valued functions take 'tvf', scalar functions 'udf'"
                         if kind == "FUNCTION" else "")
                add(ln, f"{kind} '{name}' should be prefixed '{want}' "
                        f"(e.g. {pascal_suggestion(want, name)}){extra}")
            elif not PASCAL_AFTER_PREFIX.match(name[len(want):]):
                add(ln, f"{kind} '{name}' is not PascalCase after the '{want}' prefix — the "
                        f"prefix must be followed by an initial capital, then letters or digits "
                        f"only (e.g. {pascal_suggestion(want, name)})")

    return problems


def report(path: Path, problems: list[str]) -> None:
    print(f"SQL convention violations in {path.name} "
          f"({len(problems)}) - see .claude/skills/ponytail-sql-objects/SKILL.md:", file=sys.stderr)
    for pr in problems:
        print(f"  - {pr}", file=sys.stderr)


def run_over_files(args: list[str]) -> int:
    """CLI mode. Files and directories are checked directly, so the same rules the hook applies
    to a single edit can be applied to every script at once from a build step. Without
    this, the rules would only ever be enforced on files someone happened to edit through the
    tool -- a script committed by any other route would never be seen."""
    targets: list[Path] = []
    for arg in args:
        p = Path(arg)
        if p.is_dir():
            targets.extend(sorted(p.rglob("*.sql")))
        elif p.is_file():
            targets.append(p)
        else:
            print(f"FAIL  validate-sql: '{arg}' is neither a file nor a directory.",
                  file=sys.stderr)
            return 2

    if not targets:
        # A check that silently examines nothing is worse than no check: it reports success.
        print("FAIL  validate-sql found no .sql files to check.", file=sys.stderr)
        return 2

    total = 0
    failed = 0
    for target in targets:
        problems = check(target.read_text(encoding="utf-8", errors="replace"), str(target))
        if problems:
            report(target, problems)
            total += len(problems)
            failed += 1

    if total:
        # The file count is the number of files that FAILED, not the number scanned. It used to be
        # len(targets), which made every summary overstate the spread: "25 violation(s) in 11
        # file(s)" for 25 violations in three files, and that wording was copied into the tracker's
        # own C-10 row as if eleven files were implicated. Both counts are worth having, so the
        # scanned total is still printed -- it is what says the run examined what you meant it to.
        print(f"FAIL  SQL conventions: {total} violation(s) in {failed} of {len(targets)} "
              f"file(s) checked.", file=sys.stderr)
        return 1

    print(f"PASS  SQL conventions: {len(targets)} file(s), no violations.")
    return 0


def main() -> int:
    # Windows consoles default to cp1252; keep non-ASCII in SQL from breaking the report.
    for stream in (sys.stderr, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass

    if len(sys.argv) > 1:
        return run_over_files(sys.argv[1:])

    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not target.lower().endswith(".sql"):
        return 0

    p = Path(target)
    if not p.is_file():
        return 0

    try:
        sql = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0

    problems = check(sql, p.name)
    if not problems:
        return 0

    print(f"SQL convention violations in {p.name} "
          f"({len(problems)}) - see .claude/skills/ponytail-sql-objects/SKILL.md:", file=sys.stderr)
    for pr in problems:
        print(f"  - {pr}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
