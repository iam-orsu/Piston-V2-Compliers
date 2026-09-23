"""
PistonSQL backend - a small FastAPI service that fronts an *unmodified*
Piston engine (ghcr.io/engineer-man/piston). Piston itself is never patched;
we only POST to /api/v2/execute.

Two things make the persistence story work:

1. `build_script` composes the script handed to Piston:
       seed data -> user query -> sentinel markers -> `.dump`
   We capture the resulting database state from `.dump` and store it in Redis,
   so the next run starts from where the previous one ended. That is what makes
   INSERT/UPDATE/DELETE persist between runs.

2. The dump is framed by *random, per-request* sentinel markers on stdout
   instead of being read off stderr. stderr also carries SQL error text, so
   treating stderr as "the state" (as an earlier revision did) meant a single
   typo overwrote the session's dataset with a parse-error message. Errors are
   now reported separately and can never contaminate stored state.
"""

import asyncio
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
import redis.asyncio as aioredis
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PISTON_URL = os.getenv("PISTON_URL", "http://piston:2000")
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
# "*" lets Piston resolve whichever sqlite3 build is actually installed, so the
# backend does not have to be kept in lockstep with the engine's package list.
PISTON_SQLITE_VERSION = os.getenv("PISTON_SQLITE_VERSION", "*")

# Opt-in request logging: prints the exact HTTP body this service POSTs to the
# engine. Off by default, because that body contains the student's own SQL and
# their dataset. Turn it on deliberately (PISTON_LOG_PAYLOAD=true) when you want
# to inspect what the engine receives, then turn it back off.
LOG_PISTON_PAYLOAD = os.getenv("PISTON_LOG_PAYLOAD", "").strip().lower() in {
    "1", "true", "yes", "on",
}
LOG_PISTON_PAYLOAD_MAX = int(os.getenv("PISTON_LOG_PAYLOAD_MAX", "8000"))

SESSION_TTL = int(os.getenv("SESSION_TTL", "3600"))
EXECUTE_TIMEOUT = float(os.getenv("EXECUTE_TIMEOUT", "30"))
RUN_CPU_TIME = float(os.getenv("RUN_CPU_TIME", "10"))
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", str(8 * 1024 * 1024)))
MAX_SEED_BYTES = int(os.getenv("MAX_SEED_BYTES", str(4 * 1024 * 1024)))

# Result shaping. A room full of students all running `SELECT *` on a wide
# table must not be able to hand the browser hundreds of thousands of cells to
# lay out, or blow up this process's memory building the JSON.
MAX_RESULT_ROWS = int(os.getenv("MAX_RESULT_ROWS", "1000"))
MAX_RESULT_SETS = int(os.getenv("MAX_RESULT_SETS", "25"))
MAX_TOTAL_RESULT_ROWS = int(os.getenv("MAX_TOTAL_RESULT_ROWS", "5000"))

# Piston queues jobs once max_concurrent_jobs is reached, so the time a request
# may spend waiting for a free slot has to be budgeted on top of its own run
# timeout - otherwise a busy engine looks like a hung engine.
QUEUE_HEADROOM = float(os.getenv("QUEUE_HEADROOM", "20"))
PISTON_MAX_CONNECTIONS = int(os.getenv("PISTON_MAX_CONNECTIONS", "64"))

# Rows per INSERT when turning a CSV into seed SQL. Kept well under SQLite's
# SQLITE_MAX_COMPOUND_SELECT default so it stays safe on every build.
CSV_INSERT_CHUNK = int(os.getenv("CSV_INSERT_CHUNK", "250"))

STATE_KEY = "pistonsql:state:{sid}"

redis_client: Optional[aioredis.Redis] = None
http_client: Optional[httpx.AsyncClient] = None

PISTON_CALL_TIMEOUT = EXECUTE_TIMEOUT + QUEUE_HEADROOM
# How long a request waits for its session's guard before giving up. Longer
# than one full engine call, so a queued request still gets its turn.
SESSION_LOCK_TIMEOUT = PISTON_CALL_TIMEOUT + 5


class SessionBusy(Exception):
    """Raised when a session's guard cannot be taken within the timeout."""


class _SessionLock:
    """A per-session lock plus a count of the callers currently referencing it."""

    __slots__ = ("lock", "refs")

    def __init__(self) -> None:
        self.lock = asyncio.Lock()
        self.refs = 0


# Serialises read-modify-write cycles per session. Without this, two concurrent
# runs against the same session both read the same seed and the slower one
# overwrites the other's committed changes.
#
# Entries are reference counted rather than pruned on a size threshold. A lock
# may only be removed once nobody references it *and* it is unlocked, so it can
# never be dropped while a coroutine is still queued on it - which would hand
# two callers different locks for the same session and silently break mutual
# exclusion.
_session_locks: dict[str, _SessionLock] = {}
_session_locks_guard = asyncio.Lock()


@asynccontextmanager
async def session_guard(session_id: str, timeout: float):
    async with _session_locks_guard:
        entry = _session_locks.get(session_id)
        if entry is None:
            entry = _SessionLock()
            _session_locks[session_id] = entry
        entry.refs += 1

    acquired = False
    try:
        try:
            await asyncio.wait_for(entry.lock.acquire(), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise SessionBusy() from exc
        acquired = True
        yield
    finally:
        if acquired:
            entry.lock.release()
        async with _session_locks_guard:
            entry.refs -= 1
            if entry.refs <= 0 and not entry.lock.locked():
                _session_locks.pop(session_id, None)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client, http_client
    redis_client = aioredis.from_url(
        REDIS_URL, decode_responses=True, socket_connect_timeout=5
    )
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
        await redis_client.aclose()
        await http_client.aclose()


app = FastAPI(title="PistonSQL Backend", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

_IDENT_RE = re.compile(r"[^A-Za-z0-9_]")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_INT_RE = re.compile(r"^[+-]?\d+$")
_REAL_RE = re.compile(r"^[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?$")

# Constraint keywords that terminate a column's declared type.
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
# Table-level constraints (PRIMARY KEY (a, b), FOREIGN KEY (...) REFERENCES ...)
# sit in the same comma-separated list as the columns but are not columns. Left
# alone they show up in the schema panel as a bogus "FOREIGN" or "PRIMARY" column.
_TABLE_CONSTRAINT_RE = re.compile(
    r"^(?:CONSTRAINT\s+\S+\s+)?(?:PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|KEY)\b",
    re.IGNORECASE,
)

# Things a query may not do. The isolate sandbox is the real boundary; this is
# defence in depth so a crafted query cannot break the state-capture harness or
# touch the sandbox filesystem through SQLite's shell helper functions.
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
    """Turn arbitrary user text into a safe bare SQL identifier."""
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
    """Return an error message when the SQL is not allowed, else None."""
    for pattern, message in _FORBIDDEN_QUERY:
        if pattern.search(sql):
            return message
    return None


def infer_column_type(values: list[str]) -> str:
    """Infer an SQLite affinity from sample values. Unknown -> TEXT."""
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
    """Split on commas that are not inside parens or quotes."""
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
# Dataset conversion + schema introspection
# ---------------------------------------------------------------------------

def _csv_cell_literal(cell: str) -> str:
    """A blank CSV cell becomes NULL rather than an empty string."""
    value = cell.strip()
    return "NULL" if value == "" else sql_literal(value)


def csv_to_sql(table_name: str, csv_text: str) -> str:
    """
    Convert CSV text into CREATE TABLE + INSERT statements.

    Empty cells become NULL rather than ''. Treating a blank as "no value" is
    what a CSV import normally means, and it makes `WHERE col IS NULL` behave
    the way a student practising SQL would predict.
    """
    text = csv_text.lstrip("\ufeff")
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

    column_types = [
        infer_column_type([row[i] for row in body]) for i in range(width)
    ]

    column_defs = ", ".join(
        f"{quote_ident(name)} {ctype}"
        for name, ctype in zip(headers, column_types)
    )
    statements = [f"CREATE TABLE IF NOT EXISTS {quote_ident(table_name)} ({column_defs});"]

    # Several INSERTs instead of one enormous VALUES list: each statement stays
    # small, and it keeps clear of SQLite's compound-SELECT term limit on older
    # builds (the engine runs 3.36.0, this was developed against 3.53).
    for start in range(0, len(body), CSV_INSERT_CHUNK):
        chunk = body[start:start + CSV_INSERT_CHUNK]
        values_sql = ",\n".join(
            "(" + ", ".join(_csv_cell_literal(cell) for cell in row) + ")"
            for row in chunk
        )
        statements.append(
            f"INSERT INTO {quote_ident(table_name)} VALUES\n{values_sql};"
        )

    return "\n".join(statements) + "\n"


def sql_file_to_seed(sql_text: str) -> str:
    """Validate an uploaded .sql file and return it as seed data."""
    reason = check_query_safety(sql_text)
    if reason:
        raise ValueError(f"The uploaded .sql file contains something unsafe: {reason}")
    return sql_text if sql_text.endswith("\n") else sql_text + "\n"


def extract_schema(dump: str) -> list[dict[str, Any]]:
    """Parse CREATE TABLE statements out of a dump into table schemas."""
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
# Piston script composition + result parsing
# ---------------------------------------------------------------------------

def build_script(seed_sql: str, user_query: str, nonce: str) -> dict[str, str]:
    """
    Compose the script handed to Piston, returning it with its sentinel markers.

    The sentinels are emitted under `.mode list` with an empty separator so each
    one lands on its own line as a bare string. That matters: under `.mode json`
    a marker is echoed as `[{"'<marker>'":"<marker>"}]`, so a naive `find()`
    lands in the middle of that object and line arithmetic has to compensate.
    Bare markers make extraction depend only on the marker text - which is
    random per request - rather than on how a given SQLite build formats output.

    The two `DROP TABLE IF EXISTS argv` statements are also deliberate. Piston's
    sqlite3 `run` script begins every job with `create table argv (arg text);`,
    without IF NOT EXISTS, before our code runs. A saved dump would contain that
    table too, so re-feeding it would fail with "table argv already exists" on
    every run after the first. Dropping it up front avoids the collision, and
    dropping it again before the dump keeps it out of the state we persist.
    """
    results_end = f"__PSQL_{nonce}_RESULTS_END__"
    dump_begin = f"__PSQL_{nonce}_DUMP_BEGIN__"
    dump_end = f"__PSQL_{nonce}_DUMP_END__"

    parts = [
        ".headers off",
        ".mode json",
        "DROP TABLE IF EXISTS argv;",
        seed_sql.rstrip("\n"),
        "",
        "-- ==== user query ====",
        user_query.rstrip("\n"),
        "",
        "-- ==== state capture (never shown to the user) ====",
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


def parse_piston_stdout(
    stdout: str, markers: dict[str, str]
) -> tuple[str, Optional[str]]:
    """
    Split Piston's stdout into (results_text, db_state).

    `db_state` is None when a trailing sentinel is missing, which is what
    happens if the engine truncates its output. Callers must NOT persist state
    in that case: a half-captured dump would corrupt the whole session.
    """
    results_at = stdout.find(markers["results_end"])
    if results_at == -1:
        # No sentinel at all: the run died before it could report anything.
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
    """
    Decode json-mode output into result sets.

    SQLite's json mode pretty-prints, so a single result set can span many
    lines (one object per row) and an empty result emits nothing at all. We
    therefore scan with JSONDecoder.raw_decode rather than parsing line by line.
    """
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
    """Render result sets as readable, column-aligned text for the Raw view."""
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
        header = " | ".join(c.ljust(widths[i]) for i, c in enumerate(columns))
        divider = "-+-".join("-" * w for w in widths)
        lines = [header, divider]
        for row in rows:
            lines.append(
                " | ".join(
                    (row[i] or "NULL").ljust(widths[i]) for i in range(len(columns))
                )
            )
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

def state_key(session_id: str) -> str:
    return STATE_KEY.format(sid=session_id)


def valid_session_id(session_id: str) -> bool:
    return bool(SESSION_ID_RE.match(session_id or ""))


async def read_state(session_id: str) -> str:
    value = await redis_client.get(state_key(session_id))
    return value or ""


async def write_state(session_id: str, state: str) -> None:
    await redis_client.setex(state_key(session_id), SESSION_TTL, state)


class PistonUnavailable(Exception):
    pass


async def execute_on_piston(script: str) -> dict[str, Any]:
    payload = {
        "language": "sqlite3",
        "version": PISTON_SQLITE_VERSION,
        "files": [{"name": "main.sql", "content": script}],
        "stdin": "",
        "args": [],
        # The per-request timeouts do override the engine's config defaults
        # (api/v2.js: `run_timeout ?? rt.timeouts.run`), but the CPU-time limit
        # does not inherit from run_timeout, so it has to be set explicitly or
        # a heavy query dies after the stock 3 seconds.
        "run_timeout": int(EXECUTE_TIMEOUT * 1000),
        "run_cpu_time": int(RUN_CPU_TIME * 1000),
    }

    if LOG_PISTON_PAYLOAD:
        body = json.dumps(payload, indent=2)
        truncated = len(body) > LOG_PISTON_PAYLOAD_MAX
        logger.info(
            ">>> POST %s/api/v2/execute  body=%d bytes%s\n%s",
            PISTON_URL,
            len(body),
            " (truncated)" if truncated else "",
            body[:LOG_PISTON_PAYLOAD_MAX],
        )

    try:
        response = await http_client.post(
            f"{PISTON_URL}/api/v2/execute", json=payload
        )
    except httpx.TimeoutException as exc:
        raise PistonUnavailable(
            "The execution engine timed out. Try a smaller dataset or simpler query."
        ) from exc
    except httpx.HTTPError as exc:
        raise PistonUnavailable(
            "Cannot reach the execution engine. Is the Piston container running?"
        ) from exc

    if response.status_code == 400:
        detail = _piston_error_detail(response)
        logger.error("Piston rejected the request: %s", detail)
        raise PistonUnavailable(
            f"The execution engine rejected the request: {detail} "
            "This usually means the sqlite3 runtime is not installed yet."
        )
    if response.status_code != 200:
        logger.error("Piston returned %s: %s", response.status_code, response.text[:500])
        raise PistonUnavailable(
            f"The execution engine returned HTTP {response.status_code}."
        )

    return response.json().get("run", {}) or {}


def _piston_error_detail(response: httpx.Response) -> str:
    try:
        body = response.json()
        return str(body.get("message") or body)[:300]
    except Exception:
        return response.text[:300]


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    """Cheap liveness probe used by the container healthcheck."""
    return {"status": "ok", "service": "PistonSQL"}


@app.get("/api/ready")
async def ready():
    """Deeper readiness probe: Redis reachable and sqlite3 installed in Piston."""
    problems: list[str] = []
    try:
        await redis_client.ping()
    except Exception as exc:
        problems.append(f"redis unreachable: {exc}")

    runtime_ok = False
    try:
        response = await http_client.get(f"{PISTON_URL}/api/v2/runtimes")
        if response.status_code == 200:
            runtimes = response.json()
            runtime_ok = any(
                item.get("language") == "sqlite3"
                for item in runtimes
                if isinstance(item, dict)
            )
        if not runtime_ok:
            problems.append("sqlite3 runtime is not installed in Piston")
    except Exception as exc:
        problems.append(f"piston unreachable: {exc}")

    return JSONResponse(
        status_code=200 if not problems else 503,
        content={"ok": not problems, "problems": problems},
    )


@app.post("/api/upload")
async def upload_dataset(
    file: UploadFile = File(...),
    session_id: str = Form(...),
    table_name: str = Form(default=""),
):
    """Load a .csv or .sql file as the session's starting database state."""
    if not valid_session_id(session_id):
        return JSONResponse(status_code=400, content={"error": "Invalid session id"})

    raw = await file.read()
    if len(raw) > MAX_UPLOAD_BYTES:
        return JSONResponse(
            status_code=413,
            content={"error": f"File is larger than {MAX_UPLOAD_BYTES // (1024 * 1024)} MB."},
        )

    content = raw.decode("utf-8-sig", errors="replace")
    filename = file.filename or ""

    if LOG_PISTON_PAYLOAD:
        logger.info(
            ">>> POST /api/upload  filename=%s  bytes=%d  table=%r\n%s",
            filename or "(none)",
            len(raw),
            table_name,
            content[:LOG_PISTON_PAYLOAD_MAX],
        )

    try:
        if filename.lower().endswith(".csv"):
            name = sanitize_identifier(
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

    if len(seed_sql.encode("utf-8")) > MAX_SEED_BYTES:
        return JSONResponse(
            status_code=413,
            content={"error": "That dataset is too large to keep in a browser session."},
        )

    try:
        async with session_guard(session_id, timeout=SESSION_LOCK_TIMEOUT):
            await write_state(session_id, seed_sql)
    except SessionBusy:
        return JSONResponse(
            status_code=429,
            content={"error": "Another query is running for this session. Try again."},
        )

    return {
        "ok": True,
        "schema": extract_schema(seed_sql),
        "session_id": session_id,
    }


@app.get("/api/schema/{session_id}")
async def get_schema(session_id: str):
    if not valid_session_id(session_id):
        return JSONResponse(status_code=400, content={"error": "Invalid session id"})
    state = await read_state(session_id)
    return {"schema": extract_schema(state) if state else []}


class ExecuteRequest(BaseModel):
    session_id: str = Field(min_length=1, max_length=64)
    query: str = Field(min_length=1, max_length=100_000)


def _limit_result_sets(
    sets: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], bool]:
    """
    Bound what gets handed back to the browser.

    A student can put any number of statements into one script, so without a
    ceiling a single run could return hundreds of thousands of cells - which
    this process has to serialise and the browser then has to lay out.
    """
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
        cap = min(MAX_RESULT_ROWS, budget)
        if len(rows) > cap:
            rows = rows[:cap]
            trimmed = True
        budget -= len(rows)
        output.append({"columns": result["columns"], "rows": rows})
    return output, trimmed


async def _run_query(session_id: str, query: str) -> JSONResponse:
    """Execute one query against a session and persist the resulting state."""
    seed_sql = await read_state(session_id)
    if len(seed_sql.encode("utf-8")) > MAX_SEED_BYTES:
        return JSONResponse(
            status_code=413,
            content={
                "error": "This session's stored data has grown too large to re-run. "
                "Upload a smaller dataset or reset the session."
            },
        )

    nonce = secrets.token_hex(8)
    markers = build_script(seed_sql, query, nonce)

    try:
        run = await execute_on_piston(markers["script"])
    except PistonUnavailable as exc:
        return JSONResponse(status_code=503, content={"error": str(exc)})

    stdout = run.get("stdout", "") or ""
    stderr = run.get("stderr", "") or ""
    exit_code = run.get("code", 0)

    results_text, new_state = parse_piston_stdout(stdout, markers)

    # A missing closing sentinel means the engine truncated its output. We must
    # not persist a partial dump, or the session would be corrupted.
    state_captured = new_state is not None
    if state_captured:
        await write_state(session_id, new_state)
    else:
        logger.warning("State capture failed for session %s", session_id)

    result_sets, rows_trimmed = _limit_result_sets(parse_result_sets(results_text))
    raw = render_sets_as_text(result_sets)
    error_text = stderr.strip()

    # Piston reports its own limit breaches via `status`, which is far more
    # precise than inferring them from stdout. Relevant codes:
    #   OL stdout too large, EL stderr too large, TO timeout, SG signalled.
    engine_status = run.get("status")
    engine_message = run.get("message")

    if engine_status == "OL":
        error_text = (
            "The result was too large for the execution engine to return. "
            "Try adding a LIMIT clause, or select fewer columns."
        )
    elif engine_status == "EL":
        error_text = "The query produced too much error output to return."
    elif engine_status == "TO":
        error_text = "The query was stopped because it exceeded the time limit."
    elif engine_status == "SG":
        error_text = (
            f"The query was killed by the engine{': ' + engine_message if engine_message else ''}. "
            "It may have used too much memory."
        )
    elif engine_status == "XX":
        error_text = f"The execution engine hit an internal error{': ' + engine_message if engine_message else ''}."

    warning = ""
    if not state_captured:
        warning = (
            "The execution engine truncated its output, so this run's changes "
            "were not saved. Raise PISTON_OUTPUT_MAX_SIZE or use a smaller dataset."
        )
    if rows_trimmed:
        warning = (warning + " " if warning else "") + (
            f"Results were trimmed (at most {MAX_RESULT_ROWS} rows per statement, "
            f"{MAX_TOTAL_RESULT_ROWS} rows and {MAX_RESULT_SETS} statements per run)."
        )

    return JSONResponse(
        content={
            "ok": exit_code == 0 and not error_text,
            "output": raw,
            "parsed": {"sets": result_sets, "raw": raw},
            "error": error_text,
            "warning": warning,
            "schema": extract_schema(
                new_state if new_state is not None else seed_sql
            ),
        }
    )


@app.post("/api/execute")
async def execute_query(req: ExecuteRequest):
    """Run a query against the session's database and persist the new state."""
    if not valid_session_id(req.session_id):
        return JSONResponse(status_code=400, content={"error": "Invalid session id"})

    query = req.query.strip()
    if not query:
        return JSONResponse(status_code=400, content={"error": "Empty query."})

    reason = check_query_safety(query)
    if reason:
        return JSONResponse(status_code=400, content={"error": reason})

    if LOG_PISTON_PAYLOAD:
        body = json.dumps({"session_id": req.session_id, "query": query})
        logger.info(
            ">>> POST /api/execute  body=%d bytes\n%s",
            len(body),
            body[:LOG_PISTON_PAYLOAD_MAX],
        )

    # The read -> execute -> write cycle has to be atomic per session, otherwise
    # two concurrent runs both read the same seed and the slower one overwrites
    # the other's committed changes.
    try:
        async with session_guard(req.session_id, timeout=SESSION_LOCK_TIMEOUT):
            return await _run_query(req.session_id, query)
    except SessionBusy:
        return JSONResponse(
            status_code=429,
            content={"error": "Another query is already running for this session."},
        )


@app.post("/api/reset/{session_id}")
async def reset_session(session_id: str):
    """Clear a session's stored database."""
    if not valid_session_id(session_id):
        return JSONResponse(status_code=400, content={"error": "Invalid session id"})
    # Take the guard so an in-flight query cannot write the old state back
    # after the delete, which would silently resurrect the session.
    try:
        async with session_guard(session_id, timeout=SESSION_LOCK_TIMEOUT):
            await redis_client.delete(state_key(session_id))
    except SessionBusy:
        return JSONResponse(
            status_code=429,
            content={"error": "A query is still running for this session. Try again."},
        )
    return {"ok": True}


@app.post("/api/extend/{session_id}")
async def extend_session(session_id: str):
    """Refresh a session's TTL."""
    if not valid_session_id(session_id):
        return JSONResponse(status_code=400, content={"error": "Invalid session id"})
    await redis_client.expire(state_key(session_id), SESSION_TTL)
    return {"ok": True}
