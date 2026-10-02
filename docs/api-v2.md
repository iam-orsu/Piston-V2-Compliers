# Piston API v2 — Reference

Base path: `/api/v2/`
All request bodies must be `Content-Type: application/json`.
All error responses return `{ "message": "..." }` with a 4xx or 5xx status code.

---

## Quick mental model

```
files[]           → everything written to the sandbox before the job runs
workspace_files[] → subset of files[] carried over from a previous run
output_files[]    → files created/modified during the run, returned to you
```

**Multi-file / OOP in one run** — just put all source files in `files[]`. No `workspace_files` needed.

**Cross-run persistence** — take `output_files` from a response, inject them back into `files[]` on the next request, and list their names in `workspace_files`. Piston will re-capture them after each run so you always get the latest version back.

---

## Runtimes

### `GET /api/v2/runtimes`

Returns all installed language runtimes.

#### Response

| Field | Type | Description |
|---|---|---|
| `[].language` | string | Canonical language name |
| `[].version` | string | Runtime version |
| `[].aliases` | string[] | Alternative names accepted by the execute endpoint |
| `[].runtime` | string? | Runtime engine name (only when alternatives exist) |

#### Example

```
GET /api/v2/runtimes
```

```json
HTTP/1.1 200 OK

[
  { "language": "python",     "version": "3.12.0",  "aliases": ["py", "python3"] },
  { "language": "java",       "version": "15.0.2",  "aliases": ["java"] },
  { "language": "javascript", "version": "20.11.1", "aliases": ["js", "node"], "runtime": "node" }
]
```

---

## Execute

### `POST /api/v2/execute`

Compiles (if needed) and runs code inside an isolated sandbox. Returns stdout, stderr, exit code, and any files the program created.

#### Request fields

| Field | Type | Required | Description |
|---|---|---|---|
| `language` | string | ✓ | Language name or alias from `/runtimes` |
| `version` | string | ✓ | SemVer selector, e.g. `"3.12.0"` or `"*"` for latest |
| `files` | array | ✓ | Files to write into the sandbox. First file is the entry point. |
| `files[].name` | string | | Filename (default: random). Must match public class name in Java. |
| `files[].content` | string | ✓ | File content |
| `files[].encoding` | string | | `"utf8"` (default), `"base64"`, or `"hex"` |
| `workspace_files` | string[] | | Names of files in `files[]` that came from a previous run's `output_files`. See [Workspace](#workspace--cross-run-persistence). |
| `stdin` | string | | Text piped into stdin. Default: `""` |
| `args` | string[] | | Command-line arguments. Default: `[]` |
| `run_timeout` | number | | Max ms for run stage. Must not exceed server limit. |
| `compile_timeout` | number | | Max ms for compile stage. Must not exceed server limit. |
| `run_memory_limit` | number | | Max bytes for run stage. `-1` = no limit. |
| `compile_memory_limit` | number | | Max bytes for compile stage. `-1` = no limit. |

#### Response fields

| Field | Type | Description |
|---|---|---|
| `language` | string | Canonical language name used |
| `version` | string | Runtime version used |
| `run` | object | Results from the run stage |
| `run.stdout` | string | stdout output |
| `run.stderr` | string | stderr output |
| `run.output` | string | stdout + stderr interleaved |
| `run.code` | number? | Exit code, or `null` if killed by signal |
| `run.signal` | string? | Signal name if killed, otherwise `null` |
| `compile` | object? | Only present for compiled languages (Java, C, C++, Go, Rust, …) |
| `compile.stdout` | string | Compiler stdout |
| `compile.stderr` | string | Compiler stderr (errors/warnings) |
| `compile.output` | string | Combined compiler output |
| `compile.code` | number? | Compiler exit code |
| `compile.signal` | string? | Signal if compiler was killed |
| `output_files` | array | Files created or modified during the run. Always present; empty array if none. Capped at 20 files / 1 MB per file / 5 MB total. |
| `output_files[].name` | string | Path relative to working dir (e.g. `report.txt`, `data/out.csv`) |
| `output_files[].content` | string | UTF-8 text as-is, or base64 for binary files |
| `output_files[].encoding` | string | `"utf8"` or `"base64"` |
| `output_files[].size` | number | File size in bytes |

---

## Multi-file Projects & OOP

Pass all source files in `files[]`. The **first file** is the entry point. No `workspace_files` needed.

Piston's compile stage receives only the files that share the same extension as the entry point (e.g. all `.java` files, all `.c` files). Data files (`.txt`, `.h`, `.csv`, etc.) are written to the sandbox so code can read them but are never passed to the compiler.

### File naming rules

| Language | Entry point constraint | Reason |
|---|---|---|
| Java | Filename must match `public class` name — `Main.java` for `public class Main` | Java compiler requirement |
| C / C++ | Any `.c` / `.cpp` filename | No constraint |
| Python, JS, Ruby, etc. | Any filename | Interpreter accepts any name |

### Example — Java: Two classes

`Greeter.java` defines the class; `Main.java` uses it. Both compile in one request.

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "public class Main {\n    public static void main(String[] args) {\n        Greeter g = new Greeter(\"World\");\n        System.out.println(g.greet());\n    }\n}"
    },
    {
      "name": "Greeter.java",
      "content": "public class Greeter {\n    private String name;\n    public Greeter(String name) { this.name = name; }\n    public String greet() { return \"Hello, \" + name + \"!\"; }\n}"
    }
  ]
}
```

```json
HTTP/1.1 200 OK

{
  "language": "java",
  "version": "15.0.2",
  "compile": { "stdout": "", "stderr": "", "code": 0, "signal": null, "output": "" },
  "run": { "stdout": "Hello, World!\n", "stderr": "", "code": 0, "signal": null, "output": "Hello, World!\n" },
  "output_files": []
}
```

> **Key point:** `Greeter.java` does NOT need a `main` method. It is not the entry point — it is compiled alongside `Main.java` simply because it shares the `.java` extension.

### Example — Java: Three classes (inheritance)

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "public class Main {\n    public static void main(String[] args) {\n        Animal dog = new Dog(\"Rex\");\n        System.out.println(dog.speak());\n    }\n}"
    },
    {
      "name": "Animal.java",
      "content": "public abstract class Animal {\n    protected String name;\n    public Animal(String name) { this.name = name; }\n    public abstract String speak();\n}"
    },
    {
      "name": "Dog.java",
      "content": "public class Dog extends Animal {\n    public Dog(String name) { super(name); }\n    public String speak() { return name + \" says: Woof!\"; }\n}"
    }
  ]
}
```

Output: `Rex says: Woof!`

### Example — C: Entry point + implementation + header

`.h` header files are written to the sandbox so `#include` resolves, but only `.c` files are passed to `gcc`.

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "c",
  "version": "*",
  "files": [
    {
      "name": "main.c",
      "content": "#include <stdio.h>\n#include \"math_utils.h\"\n\nint main() {\n    printf(\"Square of 5: %d\\n\", square(5));\n    return 0;\n}"
    },
    {
      "name": "math_utils.c",
      "content": "#include \"math_utils.h\"\n\nint square(int n) { return n * n; }"
    },
    {
      "name": "math_utils.h",
      "content": "#ifndef MATH_UTILS_H\n#define MATH_UTILS_H\nint square(int n);\n#endif"
    }
  ]
}
```

Compiled as: `gcc main.c math_utils.c -o a.out`
Header `math_utils.h` is in the sandbox but not a compiler argument.

### Example — Python: Module import

Python has no compile stage. All files land in the working directory. `import` works out of the box.

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "*",
  "files": [
    {
      "name": "main.py",
      "content": "from shapes import Circle\n\nc = Circle(5)\nprint(f'Area: {c.area():.2f}')"
    },
    {
      "name": "shapes.py",
      "content": "import math\n\nclass Circle:\n    def __init__(self, r): self.r = r\n    def area(self): return math.pi * self.r ** 2"
    }
  ]
}
```

Output: `Area: 78.54`

---

## Folder / Directory Support

Files can live in subdirectories. Use forward-slash paths in `files[].name` and `workspace_files[]` — Piston creates the directory structure automatically inside the sandbox.

```
files[].name: "src/Main.java"   →   sandbox: /box/submission/src/Main.java
files[].name: "utils/helpers.py" →  sandbox: /box/submission/utils/helpers.py
```

### Rules

| Allowed | Blocked |
|---|---|
| `src/Main.java` | `../etc/passwd` (traversal) |
| `com/example/App.java` | `/absolute/path.txt` (absolute) |
| `utils/math/vector.py` | `path\\windows.txt` (backslash) |

### Example — Python: module in a subdirectory

**File layout:**
```
main.py          ← entry point
utils/math.py    ← helper module
```

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "*",
  "files": [
    {
      "name": "main.py",
      "content": "from utils.math import add\nprint(add(3, 4))"
    },
    {
      "name": "utils/math.py",
      "content": "def add(a, b):\n    return a + b"
    }
  ]
}
```

Output: `7`

> **Note:** Python imports follow the directory structure. `utils/math.py` is imported as `from utils.math import ...`. An `__init__.py` is not required for Python 3 (namespace packages).

### Example — Java: packages

```json
{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "import com.example.Greeter;\npublic class Main {\n    public static void main(String[] args) {\n        System.out.println(new Greeter().greet());\n    }\n}"
    },
    {
      "name": "com/example/Greeter.java",
      "content": "package com.example;\npublic class Greeter {\n    public String greet() { return \"Hello from a package!\"; }\n}"
    }
  ]
}
```

> **Java package note:** When files are in subdirectories, `javac` receives the full relative path (`com/example/Greeter.java`). The `package` declaration in the file must match the directory path.

### Folders with workspace persistence

Folder paths work exactly the same in `workspace_files`. List the full path:

```json
{
  "workspace_files": ["utils/math.py", "com/example/Greeter.java"]
}
```

Piston re-captures these files (including their folder paths) in `output_files` after each run, so clients can persist and re-inject them on the next request.

---

## Workspace — Cross-run Persistence

Use `workspace_files` when you want files to survive across separate runs — read a file written in run 1 during run 2, accumulate logs, maintain a database, etc.

### How it works

1. **Run 1** — your code creates files. They come back in `output_files`.
2. **Run 2** — put those files back in `files[]` AND list their names in `workspace_files`.
   - Piston writes them to the sandbox before execution (so code can read them).
   - After the run, Piston re-captures them and returns them in `output_files` again — even if the code didn't modify them — so you always get the current version back.
3. Repeat for run 3, 4, …

```
Run 1  →  output_files: [notes.txt]
           ↓ (store client-side)
Run 2  →  files: [main.py, notes.txt],  workspace_files: ["notes.txt"]
           →  output_files: [notes.txt]   (updated version)
           ↓
Run 3  →  files: [main.py, notes.txt],  workspace_files: ["notes.txt"]
           → ...
```

### Compiler behaviour with workspace files

| File | Passed to compiler? |
|---|---|
| Entry-point source (always `files[0]`) | ✓ |
| Workspace file, same extension (e.g. `Helper.java`) | ✓ — compiled alongside entry point |
| Workspace file, different extension (e.g. `data.txt`) | ✗ — in sandbox for reading only |
| Header file (`.h`) | ✗ — in sandbox for `#include` only |

### Example — Python: Write then read across runs

**Run 1 — write a file:**

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "*",
  "files": [
    {
      "name": "main.py",
      "content": "with open('log.txt', 'w') as f:\n    f.write('entry 1\\n')\nprint('Written.')"
    }
  ]
}
```

```json
HTTP/1.1 200 OK

{
  "run": { "stdout": "Written.\n", "code": 0 },
  "output_files": [
    { "name": "log.txt", "content": "entry 1\n", "encoding": "utf8", "size": 8 }
  ]
}
```

**Run 2 — read and append:**

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "*",
  "files": [
    {
      "name": "main.py",
      "content": "with open('log.txt', 'a') as f:\n    f.write('entry 2\\n')\nwith open('log.txt') as f:\n    print(f.read())"
    },
    {
      "name": "log.txt",
      "content": "entry 1\n",
      "encoding": "utf8"
    }
  ],
  "workspace_files": ["log.txt"]
}
```

```json
HTTP/1.1 200 OK

{
  "run": { "stdout": "entry 1\nentry 2\n", "code": 0 },
  "output_files": [
    { "name": "log.txt", "content": "entry 1\nentry 2\n", "encoding": "utf8", "size": 16 }
  ]
}
```

### Example — Java: Persistent helper class across sessions

The user wrote `Greeter.java` in a previous session (saved client-side). On this run, inject it as a workspace file — it will be compiled alongside `Main.java`.

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "public class Main {\n    public static void main(String[] args) {\n        System.out.println(new Greeter(\"World\").greet());\n    }\n}"
    },
    {
      "name": "Greeter.java",
      "content": "public class Greeter {\n    private String name;\n    public Greeter(String name) { this.name = name; }\n    public String greet() { return \"Hello, \" + name + \"!\"; }\n}",
      "encoding": "utf8"
    }
  ],
  "workspace_files": ["Greeter.java"]
}
```

`Greeter.java` shares the `.java` extension → compiled: `javac Main.java Greeter.java`. Output: `Hello, World!`

---

## WebSocket — Interactive Execution

### `GET /api/v2/connect` (WebSocket upgrade)

Streams stdout/stderr in real time and accepts stdin. Use this for interactive programs or when you want live output.

### Message protocol

All messages are JSON.

#### Client → Server

| Message | Fields | Description |
|---|---|---|
| `init` | (all execute fields) | Start the job. Send once immediately after `onopen`. |
| `data` | `stream: "stdin"`, `data: string` | Send stdin to a running program. |
| `signal` | `signal: string` | Send a signal (e.g. `"SIGINT"`) to the running process. |

**`init` message fields** are identical to the HTTP `/execute` request body, plus `type: "init"`:

```json
{
  "type": "init",
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py", "content": "name = input('Name: ')\nprint(f'Hello, {name}!')" }
  ],
  "workspace_files": [],
  "stdin": "",
  "args": []
}
```

#### Server → Client

| Message | Fields | Description |
|---|---|---|
| `runtime` | `language`, `version` | Sent after init is accepted. Confirms resolved runtime. |
| `stage` | `stage: "compile"` or `"run"` | Signals which stage is starting. |
| `data` | `stream: "stdout"/"stderr"`, `data: string` | Live program output. |
| `exit` | `stage`, `code`, `signal` | Stage finished. `stage: "run"` → program exited. |
| `output_files` | `files: [...]` | Files created during run. Sent **before** `exit:done`. Same structure as HTTP `output_files`. |
| `exit` | `stage: "done"` | Job complete. Server closes the connection after this. |
| `error` | `message`, `code?` | Error during init or execution. |

#### Close codes

| Code | Meaning |
|---|---|
| 4999 | Job completed successfully |
| 4001 | Initialization timeout (no `init` message received within 10 s) |
| 4002 | Error — see preceding `error` message |
| 4003 | Not yet initialized |
| 4004 | Invalid stream (only `stdin` is writable) |
| 4005 | Invalid signal |
| 4429 | Server at capacity — retry after 5 s |

### Full client example (JavaScript)

```js
class PistonSession {
    constructor(host) {
        this.host = host;
        this.workspace = {}; // { [filename]: { name, content, encoding, size } }
    }

    run(language, version, filename, code, onOutput) {
        return new Promise((resolve, reject) => {
            const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const ws = new WebSocket(`${proto}//${this.host}/api/v2/connect`);

            // Workspace files to inject (all except the current entry point)
            const wsFiles = Object.values(this.workspace)
                .filter(f => f.name !== filename)
                .map(f => ({ name: f.name, content: f.content, encoding: f.encoding }));

            ws.onopen = () => {
                ws.send(JSON.stringify({
                    type:            'init',
                    language,
                    version,
                    files:           [{ name: filename, content: code }, ...wsFiles],
                    workspace_files: wsFiles.map(f => f.name),
                    stdin:           '',
                    args:            [],
                }));
            };

            ws.onmessage = ({ data }) => {
                const msg = JSON.parse(data);
                switch (msg.type) {
                    case 'data':
                        onOutput(msg.stream, msg.data);
                        break;
                    case 'output_files':
                        // Merge new/modified files into workspace
                        for (const f of msg.files) {
                            this.workspace[f.name] = f;
                        }
                        break;
                    case 'exit':
                        if (msg.stage === 'done') resolve();
                        break;
                    case 'error':
                        reject(new Error(msg.message));
                        break;
                }
            };

            ws.onerror = () => reject(new Error('WebSocket error'));
        });
    }

    // Save a file to the workspace client-side without running it.
    // Useful for helper classes (e.g. Greeter.java) with no main method.
    saveToWorkspace(filename, content, encoding = 'utf8') {
        this.workspace[filename] = {
            name:     filename,
            content,
            encoding,
            size:     new TextEncoder().encode(content).length,
        };
    }

    deleteFromWorkspace(filename) {
        delete this.workspace[filename];
    }

    clearWorkspace() {
        this.workspace = {};
    }
}
```

**Usage:**

```js
const session = new PistonSession('localhost');

// Save a helper class without running it
session.saveToWorkspace('Greeter.java',
    'public class Greeter {\n' +
    '    private String name;\n' +
    '    public Greeter(String name) { this.name = name; }\n' +
    '    public String greet() { return "Hello, " + name + "!"; }\n' +
    '}'
);

// Run Main.java — Greeter.java is automatically compiled alongside it
await session.run('java', '*', 'Main.java',
    'public class Main {\n' +
    '    public static void main(String[] args) {\n' +
    '        System.out.println(new Greeter("World").greet());\n' +
    '    }\n' +
    '}',
    (stream, data) => process.stdout.write(data)
);
// Output: Hello, World!
```

### HTTP execute — equivalent pattern

For stateless HTTP use, manage workspace state on your server:

```js
async function execute(language, version, filename, code, workspace = {}) {
    const wsFiles = Object.entries(workspace)
        .filter(([name]) => name !== filename)
        .map(([, f]) => ({ name: f.name, content: f.content, encoding: f.encoding }));

    const res = await fetch('/api/v2/execute', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            language,
            version,
            files:           [{ name: filename, content: code }, ...wsFiles],
            workspace_files: wsFiles.map(f => f.name),
        }),
    });

    const result = await res.json();

    // Merge output_files back into workspace for next run
    const nextWorkspace = { ...workspace };
    for (const f of result.output_files ?? []) {
        nextWorkspace[f.name] = f;
    }

    return { result, nextWorkspace };
}
```

---

## Packages

### `GET /api/v2/packages`

Lists all available packages and their installation status.

```json
HTTP/1.1 200 OK

[
  { "language": "python",     "language_version": "3.12.0",  "installed": true },
  { "language": "javascript", "language_version": "20.11.1", "installed": true }
]
```

### `POST /api/v2/packages`

Installs a package.

```json
POST /api/v2/packages
Content-Type: application/json

{ "language": "python", "version": "3.12.0" }
```

```json
HTTP/1.1 200 OK

{ "language": "python", "version": "3.12.0" }
```

### `DELETE /api/v2/packages`

Not yet implemented — returns `501`.

---

## Health

### `GET /api/v2/health`

Returns server status and queue metrics. Used by load balancers and monitoring.

```json
HTTP/1.1 200 OK

{
  "status":      "ok",
  "runtimes":    12,
  "active":      3,
  "queued":      0,
  "queue_max":   64
}
```

Returns `503` with `"status": "degraded"` when the queue is full.

---

## Rate limits

| Endpoint | Limit |
|---|---|
| `POST /api/v2/execute` | 30 req/s, burst 500 per IP |
| `GET /api/v2/connect` (WS) | 10 upgrades/s, burst 20 per IP |
| `GET /api/v2/packages` | 30 req/min per IP |
| `POST /api/v2/packages` | 5 req/min per IP |

When rate-limited, the server returns `429` with `Retry-After: 5`.

---

## Limits

| Resource | Limit |
|---|---|
| `output_files` count | 20 files per run |
| `output_files` single file | 1 MB |
| `output_files` total | 5 MB per run |
| Run wall time | 30 s (configurable) |
| Compile wall time | 30 s (configurable) |
| Run memory | 256 MB (configurable) |
| Compile memory | 512 MB (configurable) |
| stdin / request body | 2 MB |
| Networking | Disabled inside sandbox |
