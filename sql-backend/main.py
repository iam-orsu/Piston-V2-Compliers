"""
PistonSQL backend — stateless FastAPI service wrapping Piston's sqlite3 runtime.

State model:
  The caller (browser) supplies the current database state as a SQL dump string and
  receives the new state after the query runs. Nothing is stored server-side. The
  browser keeps state in sessionStorage (cleared on page refresh, so students always
  start from the pre-seeded dataset).

Request/response per query:
  POST /api/execute  { state: "<SQL dump from last run>", query: "<student SQL>" }
    → Piston executes: state_sql + user_query + sentinel-framed .dump
    → backend parses results + new_state from stdout
  response: { ok, new_state, parsed: {sets, raw}, error, warning, schema }

POST /api/upload  (multipart)
  → validates + converts .csv or .sql to SQL text
  → returns { ok, seed_sql, schema }  — browser stores seed_sql in sessionStorage
"""

import csv
import io
import json
import logging
import os
import re
import secrets
from contextlib import asynccontextmanager
from typing import Any, Optional

import httpx
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PISTON_URL = os.getenv("PISTON_URL", "http://piston:2000")
PISTON_SQLITE_VERSION = os.getenv("PISTON_SQLITE_VERSION", "*")

LOG_PISTON_PAYLOAD = os.getenv("PISTON_LOG_PAYLOAD", "").strip().lower() in {"1", "true", "yes", "on"}
LOG_PISTON_PAYLOAD_MAX = int(os.getenv("PISTON_LOG_PAYLOAD_MAX", "8000"))

EXECUTE_TIMEOUT = float(os.getenv("EXECUTE_TIMEOUT", "30"))
RUN_CPU_TIME    = float(os.getenv("RUN_CPU_TIME", "10"))
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", str(8 * 1024 * 1024)))   # 8 MB upload cap
MAX_STATE_BYTES  = int(os.getenv("MAX_STATE_BYTES",  str(4 * 1024 * 1024)))   # 4 MB max state round-trip

MAX_RESULT_ROWS       = int(os.getenv("MAX_RESULT_ROWS", "1000"))
MAX_RESULT_SETS       = int(os.getenv("MAX_RESULT_SETS", "25"))
MAX_TOTAL_RESULT_ROWS = int(os.getenv("MAX_TOTAL_RESULT_ROWS", "5000"))

# Piston queues jobs when max_concurrent_jobs is reached, so we budget extra time
# on top of the run timeout for the queuing wait.
QUEUE_HEADROOM      = float(os.getenv("QUEUE_HEADROOM", "20"))
PISTON_MAX_CONNECTIONS = int(os.getenv("PISTON_MAX_CONNECTIONS", "64"))

PISTON_CALL_TIMEOUT = EXECUTE_TIMEOUT + QUEUE_HEADROOM

CSV_INSERT_CHUNK = int(os.getenv("CSV_INSERT_CHUNK", "250"))

http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(
            connect=10.0,
            read=PISTON_CALL_TIMEOUT,
            write=30.0,
            pool=PISTON_CALL_TIMEOUT,
        ),
        limits=httpx.Limits(
            max_connections=PISTON_MAX_CONNECTIONS,
            max_keepalive_connections=max(8, PISTON_MAX_CONNECTIONS // 2),
        ),
    )
    try:
        yield
    finally:
        await http_client.aclose()


app = FastAPI(title="PistonSQL Backend", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_IDENT_RE = re.compile(r"[^A-Za-z0-9_]")
_INT_RE  = re.compile(r"^[+-]?\d+$")
_REAL_RE = re.compile(r"^[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?$")

_CONSTRAINT_RE = re.compile(
    r"\b(PRIMARY\s+KEY|NOT\s+NULL|UNIQUE|CHECK|FOREIGN\s+KEY|CONSTRAINT|"
    r"DEFAULT|COLLATE|REFERENCES|GENERATED|AUTOINCREMENT)\b",
    re.IGNORECASE,
)
_CREATE_TABLE_RE = re.compile(
    r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?'
    r'("[^"]+"|`[^`]+`|\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*;',
    re.IGNORECASE | re.DOTALL,
)
_COL_NAME_RE = re.compile(
    r'^(?:"([^"]+)"|`([^`]+)`|\[([^\]]+)\]|([A-Za-z_][A-Za-z0-9_]*))\s*(.*)$',
    re.DOTALL,
)
_TABLE_CONSTRAINT_RE = re.compile(
    r"^(?:CONSTRAINT\s+\S+\s+)?(?:PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|KEY)\b",
    re.IGNORECASE,
)

_FORBIDDEN_QUERY = (
    (re.compile(r"^\s*\.", re.MULTILINE),
     "sqlite3 shell dot-commands (lines starting with '.') are not allowed"),
    (re.compile(r"\bATTACH\s+(?:DATABASE\s+)?", re.IGNORECASE),
     "ATTACH is not allowed"),
    (re.compile(r"\bDETACH\s+(?:DATABASE\s+)?", re.IGNORECASE),
     "DETACH is not allowed"),
    (re.compile(r"\b(?:readfile|writefile)\s*\(", re.IGNORECASE),
     "readfile() and writefile() are not allowed"),
    (re.compile(r"\bload_extension\s*\(", re.IGNORECASE),
     "load_extension() is not allowed"),
)


def sanitize_identifier(raw: str, fallback: str = "data") -> str:
    name = _IDENT_RE.sub("_", (raw or "").strip())
    name = re.sub(r"_+", "_", name).strip("_")
    if not name:
        return fallback
    if name[0].isdigit():
        name = f"t_{name}"
    return name[:63]


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def check_query_safety(sql: str) -> Optional[str]:
    for pattern, message in _FORBIDDEN_QUERY:
        if pattern.search(sql):
            return message
    return None


def infer_column_type(values: list[str]) -> str:
    saw_value = False
    all_int = True
    all_numeric = True
    for raw in values:
        value = raw.strip()
        if not value:
            continue
        saw_value = True
        if all_int and not _INT_RE.match(value):
            all_int = False
        if all_numeric and not (_INT_RE.match(value) or _REAL_RE.match(value)):
            all_numeric = False
            break
    if not saw_value:
        return "TEXT"
    if all_int:
        return "INTEGER"
    if all_numeric:
        return "REAL"
    return "TEXT"


def split_top_level(text: str) -> list[str]:
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    quote: Optional[str] = None
    for ch in text:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ('"', "'", "`"):
            quote = ch
            buf.append(ch)
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


# ---------------------------------------------------------------------------
# Dataset conversion + schema
# ---------------------------------------------------------------------------

def _csv_cell_literal(cell: str) -> str:
    value = cell.strip()
    return "NULL" if value == "" else sql_literal(value)


def csv_to_sql(table_name: str, csv_text: str) -> str:
    text = csv_text.lstrip("﻿")
    reader = csv.reader(io.StringIO(text))
    rows = [r for r in reader if any(cell.strip() for cell in r)]
    if not rows:
        raise ValueError("The CSV file is empty.")

    raw_header = rows[0]
    headers: list[str] = []
    seen: dict[str, int] = {}
    for index, cell in enumerate(raw_header):
        name = sanitize_identifier(cell, fallback=f"column_{index + 1}")
        if name in seen:
            seen[name] += 1
            name = f"{name}_{seen[name]}"
        else:
            seen[name] = 0
        headers.append(name)

    width = len(headers)
    body: list[list[str]] = []
    for row in rows[1:]:
        cells = list(row[:width]) + [""] * max(0, width - len(row))
        body.append(cells)

    column_types = [infer_column_type([row[i] for row in body]) for i in range(width)]
    column_defs = ", ".join(
        f"{quote_ident(name)} {ctype}"
        for name, ctype in zip(headers, column_types)
    )
    statements = [f"CREATE TABLE IF NOT EXISTS {quote_ident(table_name)} ({column_defs});"]

    for start in range(0, len(body), CSV_INSERT_CHUNK):
        chunk = body[start:start + CSV_INSERT_CHUNK]
        values_sql = ",\n".join(
            "(" + ", ".join(_csv_cell_literal(cell) for cell in row) + ")"
            for row in chunk
        )
        statements.append(f"INSERT INTO {quote_ident(table_name)} VALUES\n{values_sql};")

    return "\n".join(statements) + "\n"


def sql_file_to_seed(sql_text: str) -> str:
    reason = check_query_safety(sql_text)
    if reason:
        raise ValueError(f"The uploaded .sql file contains something unsafe: {reason}")
    return sql_text if sql_text.endswith("\n") else sql_text + "\n"


def extract_schema(dump: str) -> list[dict[str, Any]]:
    tables: list[dict[str, Any]] = []
    for match in _CREATE_TABLE_RE.finditer(dump):
        raw_name = match.group(1)
        name = raw_name.strip('"`[]')
        if name.lower().startswith("sqlite_"):
            continue
        columns: list[dict[str, str]] = []
        for part in split_top_level(match.group(2)):
            if _TABLE_CONSTRAINT_RE.match(part):
                continue
            col = _COL_NAME_RE.match(part)
            if not col:
                continue
            col_name = next((g for g in col.groups()[:4] if g), None)
            if not col_name:
                continue
            remainder = col.group(5) or ""
            ctype = _CONSTRAINT_RE.split(remainder)[0].strip()
            ctype = re.sub(r"\s+", " ", ctype).upper() or "ANY"
            columns.append({"name": col_name, "type": ctype})
        if columns:
            tables.append({"name": name, "columns": columns})
    return tables


# ---------------------------------------------------------------------------
# Piston script + result parsing
# ---------------------------------------------------------------------------

def build_script(state_sql: str, user_query: str, nonce: str) -> dict[str, str]:
    """
    Compose the sqlite3 script handed to Piston.

    Layout:
      1. Drop argv (Piston's sqlite3 runner pre-creates it; re-feeding a dump
         would fail with "table already exists" without this drop).
      2. state_sql  — the student's accumulated database from prior runs.
      3. user_query — what the student typed this run.
      4. Sentinel + .dump — captures the updated database state for the browser
         to store and send back on the next run.

    Sentinels are emitted under `.mode list` with an empty separator so each
    lands as a bare string on its own line. Under `.mode json` a sentinel would
    be wrapped in JSON brackets, making extraction depend on how a given SQLite
    build formats output. Bare mode avoids that dependency entirely.
    """
    results_end = f"__PSQL_{nonce}_RESULTS_END__"
    dump_begin  = f"__PSQL_{nonce}_DUMP_BEGIN__"
    dump_end    = f"__PSQL_{nonce}_DUMP_END__"

    parts = [
        ".headers off",
        ".mode json",
        "DROP TABLE IF EXISTS argv;",
        state_sql.rstrip("\n"),
        "",
        "-- ==== user query ====",
        user_query.rstrip("\n"),
        "",
        "-- ==== state capture ====",
        ".mode list",
        ".separator ''",
        f"SELECT {sql_literal(results_end)};",
        f"SELECT {sql_literal(dump_begin)};",
        "DROP TABLE IF EXISTS argv;",
        ".dump",
        f"SELECT {sql_literal(dump_end)};",
    ]

    return {
        "script": "\n".join(parts) + "\n",
        "results_end": results_end,
        "dump_begin": dump_begin,
        "dump_end": dump_end,
    }


def parse_piston_stdout(stdout: str, markers: dict[str, str]) -> tuple[str, Optional[str]]:
    """
    Split Piston's stdout into (results_text, new_state).

    Returns new_state=None when a trailing sentinel is missing, which means the
    engine truncated its output. Callers must NOT replace the stored state in that
    case — a partial dump would corrupt the session.
    """
    results_at = stdout.find(markers["results_end"])
    if results_at == -1:
        return stdout, None
    results_text = stdout[:results_at]

    begin_at = stdout.find(markers["dump_begin"], results_at)
    if begin_at == -1:
        return results_text, None
    state_start = stdout.find("\n", begin_at)
    if state_start == -1:
        return results_text, None

    end_at = stdout.find(markers["dump_end"], state_start)
    if end_at == -1:
        return results_text, None

    state = stdout[state_start + 1:end_at].strip()
    return results_text, state


def parse_result_sets(results_text: str) -> list[dict[str, Any]]:
    decoder = json.JSONDecoder()
    sets: list[dict[str, Any]] = []
    index = 0
    length = len(results_text)

    while index < length:
        if results_text[index] != "[":
            index += 1
            continue
        try:
            payload, end = decoder.raw_decode(results_text, index)
        except json.JSONDecodeError:
            index += 1
            continue
        index = end

        if not isinstance(payload, list) or not payload:
            continue
        if not isinstance(payload[0], dict):
            continue

        columns = list(payload[0].keys())
        rows = [
            [_cell_to_text(row.get(col)) for col in columns]
            for row in payload
            if isinstance(row, dict)
        ]
        sets.append({"columns": columns, "rows": rows})

    return sets


def _cell_to_text(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def render_sets_as_text(sets: list[dict[str, Any]]) -> str:
    if not sets:
        return ""
    blocks: list[str] = []
    for result in sets:
        columns = result["columns"]
        rows = result["rows"]
        widths = [
            max(len(columns[i]), *(len(r[i] or "NULL") for r in rows))
            if rows else len(columns[i])
            for i in range(len(columns))
        ]
        header  = " | ".join(c.ljust(widths[i]) for i, c in enumerate(columns))
        divider = "-+-".join("-" * w for w in widths)
        lines   = [header, divider]
        for row in rows:
            lines.append(
                " | ".join((row[i] or "NULL").ljust(widths[i]) for i in range(len(columns)))
            )
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _limit_result_sets(sets: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], bool]:
    trimmed = False
    if len(sets) > MAX_RESULT_SETS:
        sets = sets[:MAX_RESULT_SETS]
        trimmed = True

    budget = MAX_TOTAL_RESULT_ROWS
    output: list[dict[str, Any]] = []
    for result in sets:
        if budget <= 0:
            trimmed = True
            break
        rows = result["rows"]
        cap  = min(MAX_RESULT_ROWS, budget)
        if len(rows) > cap:
            rows    = rows[:cap]
            trimmed = True
        budget -= len(rows)
        output.append({"columns": result["columns"], "rows": rows})
    return output, trimmed


# ---------------------------------------------------------------------------
# Piston call
# ---------------------------------------------------------------------------

class PistonUnavailable(Exception):
    pass


async def execute_on_piston(script: str) -> dict[str, Any]:
    payload = {
        "language": "sqlite3",
        "version": PISTON_SQLITE_VERSION,
        "files": [{"name": "main.sql", "content": script}],
        "stdin": "",
        "args": [],
        "run_timeout": int(EXECUTE_TIMEOUT * 1000),
        "run_cpu_time": int(RUN_CPU_TIME * 1000),
    }

    if LOG_PISTON_PAYLOAD:
        body = json.dumps(payload, indent=2)
        truncated = len(body) > LOG_PISTON_PAYLOAD_MAX
        logger.info(
            ">>> POST %s/api/v2/execute  body=%d bytes%s\n%s",
            PISTON_URL, len(body),
            " (truncated)" if truncated else "",
            body[:LOG_PISTON_PAYLOAD_MAX],
        )

    try:
        response = await http_client.post(f"{PISTON_URL}/api/v2/execute", json=payload)
    except httpx.TimeoutException as exc:
        raise PistonUnavailable(
            "The execution engine timed out. Try a simpler query or smaller dataset."
        ) from exc
    except httpx.HTTPError as exc:
        raise PistonUnavailable(
            "Cannot reach the execution engine. Is the Piston container running?"
        ) from exc

    if response.status_code == 400:
        try:
            body = response.json()
            detail = str(body.get("message") or body)[:300]
        except Exception:
            detail = response.text[:300]
        logger.error("Piston rejected the request: %s", detail)
        raise PistonUnavailable(
            f"The execution engine rejected the request: {detail}. "
            "This usually means the sqlite3 runtime is not installed yet."
        )
    if response.status_code != 200:
        logger.error("Piston returned %s: %s", response.status_code, response.text[:500])
        raise PistonUnavailable(
            f"The execution engine returned HTTP {response.status_code}."
        )

    return response.json().get("run", {}) or {}


# ---------------------------------------------------------------------------
# Core query runner (stateless)
# ---------------------------------------------------------------------------

async def _run_query(state: str, query: str) -> JSONResponse:
    """
    Execute one query and return the updated state to the caller.

    The caller supplies the current DB state (a .dump-format SQL string from the
    previous run, or the pre-seeded data on first run). The updated state is
    returned in the response and stored by the browser — nothing is written
    server-side.
    """
    nonce   = secrets.token_hex(8)
    markers = build_script(state, query, nonce)

    try:
        run = await execute_on_piston(markers["script"])
    except PistonUnavailable as exc:
        return JSONResponse(status_code=503, content={"error": str(exc)})

    stdout    = run.get("stdout", "") or ""
    stderr    = run.get("stderr", "") or ""
    exit_code = run.get("code", 0)

    results_text, new_state = parse_piston_stdout(stdout, markers)

    # If capture fails (truncated output), preserve the original state rather
    # than returning None — the browser should keep what it had, not lose data.
    state_captured = new_state is not None
    if not state_captured:
        logger.warning("State capture failed — output likely truncated by engine")
        new_state = state

    result_sets, rows_trimmed = _limit_result_sets(parse_result_sets(results_text))
    raw        = render_sets_as_text(result_sets)
    error_text = stderr.strip()

    engine_status  = run.get("status")
    engine_message = run.get("message")

    if engine_status == "OL":
        error_text = (
            "The result was too large for the execution engine. "
            "Try adding a LIMIT clause or selecting fewer columns."
        )
    elif engine_status == "EL":
        error_text = "The query produced too much error output."
    elif engine_status == "TO":
        error_text = "The query was stopped because it exceeded the time limit."
    elif engine_status == "SG":
        error_text = (
            f"The query was killed by the engine"
            f"{': ' + engine_message if engine_message else ''}. "
            "It may have used too much memory."
        )
    elif engine_status == "XX":
        error_text = (
            f"The execution engine hit an internal error"
            f"{': ' + engine_message if engine_message else ''}."
        )

    warning = ""
    if not state_captured:
        warning = (
            "Output was truncated by the engine — your changes were not saved. "
            "Raise PISTON_OUTPUT_MAX_SIZE or simplify your query."
        )
    if rows_trimmed:
        warning = (warning + " " if warning else "") + (
            f"Results trimmed to {MAX_RESULT_ROWS} rows per statement, "
            f"{MAX_TOTAL_RESULT_ROWS} rows and {MAX_RESULT_SETS} statements per run."
        )

    return JSONResponse(content={
        "ok":       exit_code == 0 and not error_text,
        "new_state": new_state,
        "output":   raw,
        "parsed":   {"sets": result_sets, "raw": raw},
        "error":    error_text,
        "warning":  warning,
        "schema":   extract_schema(new_state),
    })


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    return {"status": "ok", "service": "PistonSQL"}


@app.get("/api/ready")
async def ready():
    """Deep readiness probe: check Piston is reachable and sqlite3 is installed."""
    problems: list[str] = []
    try:
        response = await http_client.get(f"{PISTON_URL}/api/v2/runtimes")
        if response.status_code == 200:
            runtimes = response.json()
            if not any(
                isinstance(item, dict) and item.get("language") == "sqlite3"
                for item in runtimes
            ):
                problems.append("sqlite3 runtime is not installed in Piston")
        else:
            problems.append(f"Piston runtimes returned HTTP {response.status_code}")
    except Exception as exc:
        problems.append(f"piston unreachable: {exc}")

    return JSONResponse(
        status_code=200 if not problems else 503,
        content={"ok": not problems, "problems": problems},
    )


class ExecuteRequest(BaseModel):
    # State is the SQL dump from the browser's sessionStorage. Empty string means
    # a fresh session (browser will pass the pre-seeded dataset SQL on first run).
    state: str = Field(default="", max_length=4_000_000)
    query: str = Field(min_length=1, max_length=100_000)


@app.post("/api/execute")
async def execute_query(req: ExecuteRequest):
    """Run a query against the caller-supplied database state."""
    query = req.query.strip()
    if not query:
        return JSONResponse(status_code=400, content={"error": "Empty query."})

    reason = check_query_safety(query)
    if reason:
        return JSONResponse(status_code=400, content={"error": reason})

    state = req.state or ""
    if len(state.encode("utf-8")) > MAX_STATE_BYTES:
        return JSONResponse(
            status_code=413,
            content={"error": "Database state is too large. Reset to start fresh."},
        )

    return await _run_query(state, query)


@app.post("/api/upload")
async def upload_dataset(
    file: UploadFile = File(...),
    table_name: str = Form(default=""),
):
    """
    Convert an uploaded .csv or .sql file to seed SQL and return it.

    The seed SQL is returned to the browser, which stores it in sessionStorage.
    Nothing is written server-side — the endpoint is a pure conversion function.
    """
    raw = await file.read()
    if len(raw) > MAX_UPLOAD_BYTES:
        return JSONResponse(
            status_code=413,
            content={"error": f"File is larger than {MAX_UPLOAD_BYTES // (1024 * 1024)} MB."},
        )

    content  = raw.decode("utf-8-sig", errors="replace")
    filename = file.filename or ""

    try:
        if filename.lower().endswith(".csv"):
            name     = sanitize_identifier(
                table_name.strip() or filename.rsplit(".", 1)[0], fallback="dataset"
            )
            seed_sql = csv_to_sql(name, content)
        elif filename.lower().endswith(".sql"):
            seed_sql = sql_file_to_seed(content)
        else:
            return JSONResponse(
                status_code=400,
                content={"error": "Only .csv and .sql files are supported."},
            )
    except ValueError as exc:
        return JSONResponse(status_code=400, content={"error": str(exc)})
    except csv.Error as exc:
        return JSONResponse(status_code=400, content={"error": f"Malformed CSV: {exc}"})

    if len(seed_sql.encode("utf-8")) > MAX_STATE_BYTES:
        return JSONResponse(
            status_code=413,
            content={"error": "That dataset is too large (max 4 MB as SQL)."},
        )

    return {
        "ok":       True,
        "seed_sql": seed_sql,
        "schema":   extract_schema(seed_sql),
    }
