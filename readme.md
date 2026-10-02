# Piston IDE — Frontend Developer Guide

> A self-hosted code execution API. Send code, get output. Supports 15+ languages, multi-file projects, OOP, folder hierarchies, and cross-run file persistence.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Running Code — HTTP](#running-code--http)
4. [Running Code — WebSocket (live output)](#running-code--websocket-live-output)
5. [Multi-file Projects & OOP](#multi-file-projects--oop)
6. [Folder / Directory Support](#folder--directory-support)
7. [Workspace Persistence](#workspace-persistence)
8. [Saving Files Without Running](#saving-files-without-running)
9. [Language Reference](#language-reference)
10. [Security Rules](#security-rules)
11. [Limits & Rate Limits](#limits--rate-limits)
12. [PistonSession — JS Client Class](#pistonsession--js-client-class)

---

## Quick Start

```bash
# Check available runtimes
GET /api/v2/runtimes

# Run code
POST /api/v2/execute
Content-Type: application/json
```

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py", "content": "print('Hello, World!')" }
  ]
}
```

```json
{
  "language": "python",
  "version": "3.12.0",
  "run": { "stdout": "Hello, World!\n", "stderr": "", "code": 0 },
  "output_files": []
}
```

---

## Core Concepts

```
files[]            →  everything written to the sandbox before the job runs
workspace_files[]  →  names of files in files[] that came from a previous run
output_files[]     →  files created/modified during the run, returned to you
```

- **`files[0]`** is always the entry point (the file that gets executed or compiled first).
- Files exist only for the duration of one run. The sandbox is destroyed immediately after.
- Nothing is stored on the server between runs — you manage state client-side.

---

## Running Code — HTTP

### `POST /api/v2/execute`

#### Request fields

| Field | Type | Required | Description |
|---|---|---|---|
| `language` | string | ✓ | Language name or alias (from `/runtimes`) |
| `version` | string | ✓ | SemVer string, e.g. `"3.12.0"` or `"*"` for latest |
| `files` | array | ✓ | Files to write into the sandbox. First file is entry point. |
| `files[].name` | string | | Filename or path (`src/Main.java`). Defaults to `file0.code`. |
| `files[].content` | string | ✓ | File content |
| `files[].encoding` | string | | `utf8` (default), `base64`, or `hex` |
| `workspace_files` | string[] | | Full paths of files in `files[]` that came from a previous run |
| `stdin` | string | | Text piped to stdin. Default `""` |
| `args` | string[] | | Command-line arguments. Default `[]` |
| `run_timeout` | number | | Max ms for run stage |
| `compile_timeout` | number | | Max ms for compile stage |
| `run_memory_limit` | number | | Max bytes for run stage. `-1` = no limit |
| `compile_memory_limit` | number | | Max bytes for compile stage. `-1` = no limit |

#### Response fields

| Field | Type | Description |
|---|---|---|
| `language` | string | Canonical language name |
| `version` | string | Runtime version used |
| `run.stdout` | string | Standard output |
| `run.stderr` | string | Standard error |
| `run.code` | number? | Exit code (`null` if killed by signal) |
| `run.signal` | string? | Signal name if killed |
| `compile` | object? | Compile stage results (compiled languages only) |
| `compile.stdout` | string | Compiler stdout |
| `compile.stderr` | string | Compiler errors/warnings |
| `compile.code` | number? | Compiler exit code |
| `output_files` | array | Files created or modified during the run |
| `output_files[].name` | string | Relative path, e.g. `report.csv` or `data/out.txt` |
| `output_files[].content` | string | UTF-8 text as-is; binary files as base64 |
| `output_files[].encoding` | string | `utf8` or `base64` |
| `output_files[].size` | number | File size in bytes |

---

## Running Code — WebSocket (live output)

### `WS /api/v2/connect`

Use the WebSocket endpoint when you need:
- Live streaming stdout/stderr as the program runs
- Interactive programs that accept stdin input
- Real-time terminal experience

### Message flow

```
Client                          Server
  |                               |
  |  { type: "init", ... }  →     |   (send immediately after onopen)
  |                          ←    |  { type: "runtime", language, version }
  |                          ←    |  { type: "stage", stage: "compile" }   (compiled langs only)
  |                          ←    |  { type: "exit", stage: "compile", code: 0 }
  |                          ←    |  { type: "stage", stage: "run" }
  |                          ←    |  { type: "data", stream: "stdout", data: "..." }
  |  { type: "data",         →    |   (send stdin at any time)
  |    stream: "stdin",           |
  |    data: "Alice\n" }          |
  |                          ←    |  { type: "data", stream: "stdout", data: "Hello, Alice!\n" }
  |                          ←    |  { type: "exit", stage: "run", code: 0 }
  |                          ←    |  { type: "output_files", files: [...] }  (if any files created)
  |                          ←    |  { type: "exit", stage: "done" }
  |                          ←    |  [connection closed 4999]
```

### Client → Server messages

| `type` | Fields | Description |
|---|---|---|
| `init` | same as HTTP execute body | Start the job. Send once after `onopen`. |
| `data` | `stream: "stdin"`, `data: string` | Send input to the running program |
| `signal` | `signal: string` | Send a signal, e.g. `"SIGINT"` to kill |

### Server → Client messages

| `type` | Fields | Description |
|---|---|---|
| `runtime` | `language`, `version` | Job accepted, runtime confirmed |
| `stage` | `stage: "compile"` or `"run"` | Stage starting |
| `data` | `stream`, `data` | Live output chunk (stdout or stderr) |
| `exit` | `stage`, `code`, `signal` | Stage finished |
| `output_files` | `files: [...]` | Files created during run (same shape as HTTP) |
| `error` | `message`, `code?` | Error — connection will close |

### WebSocket close codes

| Code | Meaning |
|---|---|
| `4999` | Job completed successfully |
| `4001` | No `init` received within 10 seconds |
| `4002` | Execution error (see preceding `error` message) |
| `4003` | Message sent before `init` |
| `4004` | Invalid stream (only `stdin` is writable) |
| `4005` | Invalid signal |
| `4429` | Server at capacity — retry after 5 s |

### Minimal WebSocket example

```js
const ws = new WebSocket('ws://localhost/api/v2/connect');

ws.onopen = () => {
  ws.send(JSON.stringify({
    type: 'init',
    language: 'python',
    version: '*',
    files: [{ name: 'main.py', content: 'name = input("Name: ")\nprint(f"Hello, {name}!")' }],
    workspace_files: [],
    stdin: '',
    args: [],
  }));
};

ws.onmessage = ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.type === 'data') process.stdout.write(msg.data);
  if (msg.type === 'output_files') saveWorkspace(msg.files);
};

// Send stdin when user types
function sendInput(text) {
  ws.send(JSON.stringify({ type: 'data', stream: 'stdin', data: text }));
}
```

---

## Multi-file Projects & OOP

Put all source files in `files[]`. The **first file** is the entry point. All other files are compiled or imported automatically.

### How compilation works

| File type | Passed to compiler? |
|---|---|
| Entry-point source (`files[0]`) | ✓ always |
| Workspace file — same extension as entry point (e.g. `Helper.java` when entry is `.java`) | ✓ compiled together |
| Workspace file — different extension (e.g. `data.txt`, `config.csv`) | ✗ written to sandbox for reading only |
| Header files (`.h`) | ✗ written to sandbox for `#include` only, never a compiler arg |

### Java — two classes

```json
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
      "content": "public class Greeter {\n    private String name;\n    public Greeter(String n) { this.name = n; }\n    public String greet() { return \"Hello, \" + name + \"!\"; }\n}"
    }
  ]
}
```

> `Greeter.java` does **not** need a `main` method. It is compiled alongside `Main.java` because they share the `.java` extension.

### Java — inheritance (three classes)

```json
{
  "language": "java",
  "version": "*",
  "files": [
    { "name": "Main.java",   "content": "public class Main { public static void main(String[] a) { new Dog(\"Rex\").speak(); } }" },
    { "name": "Animal.java", "content": "public abstract class Animal { protected String name; public Animal(String n){name=n;} public abstract void speak(); }" },
    { "name": "Dog.java",    "content": "public class Dog extends Animal { public Dog(String n){super(n);} public void speak(){System.out.println(name+\": Woof!\");} }" }
  ]
}
```

### C — entry point + implementation + header

```json
{
  "language": "c",
  "version": "*",
  "files": [
    { "name": "main.c",       "content": "#include <stdio.h>\n#include \"utils.h\"\nint main(){printf(\"%d\\n\",add(3,4));return 0;}" },
    { "name": "utils.c",      "content": "#include \"utils.h\"\nint add(int a,int b){return a+b;}" },
    { "name": "utils.h",      "content": "int add(int a,int b);" }
  ]
}
```

Compiled as: `gcc main.c utils.c -o a.out` — `utils.h` is in the sandbox but not a compiler arg.

### C++ — multiple source files

```json
{
  "language": "c++",
  "version": "*",
  "files": [
    { "name": "main.cpp",   "content": "#include \"vector.h\"\n#include <iostream>\nint main(){Vector v{1,2,3};std::cout<<v.len()<<'\\n';}" },
    { "name": "vector.h",  "content": "#pragma once\n#include <cmath>\nstruct Vector{double x,y,z;double len(){return std::sqrt(x*x+y*y+z*z);}};"}
  ]
}
```

### Python — module import

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py",   "content": "from shapes import Circle\nprint(f'Area: {Circle(5).area():.2f}')" },
    { "name": "shapes.py", "content": "import math\nclass Circle:\n    def __init__(self,r):self.r=r\n    def area(self):return math.pi*self.r**2" }
  ]
}
```

### JavaScript — require

```json
{
  "language": "javascript",
  "version": "*",
  "files": [
    { "name": "index.js",  "content": "const {add}=require('./utils');console.log(add(3,4));" },
    { "name": "utils.js",  "content": "module.exports={add:(a,b)=>a+b};" }
  ]
}
```

---

## Folder / Directory Support

Set `files[].name` to a forward-slash path. Piston creates every intermediate directory automatically — no extra API call needed.

```
"src/Main.java"            →   /box/submission/src/Main.java
"com/example/App.java"     →   /box/submission/com/example/App.java
"utils/math/vector.py"     →   /box/submission/utils/math/vector.py
```

### Python — module in subfolder

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py",          "content": "from utils.math import add\nprint(add(3, 4))" },
    { "name": "utils/math.py",    "content": "def add(a, b): return a + b" }
  ]
}
```

Import maps directly to path: `utils/math.py` → `from utils.math import add`.

> Python 3 namespace packages work without `__init__.py`. Add one only when you need package-level imports.

### Java — package in subdirectory

```json
{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "import com.example.Greeter;\npublic class Main { public static void main(String[] a){System.out.println(new Greeter().greet());} }"
    },
    {
      "name": "com/example/Greeter.java",
      "content": "package com.example;\npublic class Greeter { public String greet(){return \"Hello from package!\";} }"
    }
  ]
}
```

> Java rule: `package` declaration must match the directory path. `com/example/Greeter.java` → `package com.example;`

### Deep hierarchy

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py",                  "content": "from app.models.user import User\nprint(User('Alice'))" },
    { "name": "app/__init__.py",          "content": "" },
    { "name": "app/models/__init__.py",   "content": "" },
    { "name": "app/models/user.py",       "content": "class User:\n    def __init__(self,n):self.name=n\n    def __repr__(self):return f'User({self.name!r})'" }
  ]
}
```

Sandbox layout:
```
submission/
  main.py
  app/
    __init__.py
    models/
      __init__.py
      user.py
```

### Folders with workspace persistence

Folder paths work identically in `workspace_files`. Use the full path:

```json
{
  "workspace_files": ["utils/math.py", "com/example/Greeter.java"]
}
```

`output_files[]` returns files with their full relative paths preserved, so re-injecting on the next run automatically recreates the same folder structure.

---

## Workspace Persistence

Use `workspace_files` to persist files across separate runs — accumulate logs, maintain a shared state file, keep compiled helper classes around, etc.

### Pattern

```
Run 1  →  output_files: [{ name: "log.txt", content: "entry 1\n" }]
              ↓  store client-side
Run 2  →  files: [main.py, log.txt],  workspace_files: ["log.txt"]
          output_files: [{ name: "log.txt", content: "entry 1\nentry 2\n" }]
              ↓
Run 3  →  files: [main.py, log.txt],  workspace_files: ["log.txt"]
          ...
```

Piston re-captures workspace files after each run and returns the latest version in `output_files` — even if the code didn't modify them. This means you always get the current version back without tracking changes yourself.

### Example — Python: accumulating a log

**Run 1:**

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py", "content": "with open('log.txt','w') as f:\n    f.write('entry 1\\n')\nprint('done')" }
  ]
}
```

Response: `output_files: [{ "name": "log.txt", "content": "entry 1\n" }]`

**Run 2:**

```json
{
  "language": "python",
  "version": "*",
  "files": [
    { "name": "main.py",  "content": "with open('log.txt','a') as f:\n    f.write('entry 2\\n')\nprint(open('log.txt').read())" },
    { "name": "log.txt",  "content": "entry 1\n" }
  ],
  "workspace_files": ["log.txt"]
}
```

Response stdout: `entry 1\nentry 2\n`

### Example — Java: persistent helper class across sessions

User saves `Greeter.java` client-side (no `main` method — can't run it alone). On the next request, inject it as a workspace file:

```json
{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "public class Main {\n    public static void main(String[] a){\n        System.out.println(new Greeter(\"World\").greet());\n    }\n}"
    },
    {
      "name": "Greeter.java",
      "content": "public class Greeter {\n    private String name;\n    public Greeter(String n){this.name=n;}\n    public String greet(){return \"Hello, \"+name+\"!\";}\n}"
    }
  ],
  "workspace_files": ["Greeter.java"]
}
```

`Greeter.java` shares the `.java` extension → compiled: `javac Main.java Greeter.java`. Output: `Hello, World!`

---

## Saving Files Without Running

Sometimes you want to save a helper file client-side without executing it — for example a Java class with no `main` method, or a Python module.

There is no API call for this. Store the file in your own client state and inject it on the next run as a workspace file.

### In the Piston IDE (built-in)

1. Type your helper code in the editor
2. Rename the tab to the desired filename (e.g. `Greeter.java`)
3. Click **+ Save to Workspace** — the file is stored in `localStorage`, no server call made
4. Rename the tab to your entry point (e.g. `Main.java`)
5. Write your main code and click **Run** — both files are sent together

### In your own frontend

```js
// Store client-side — no API call
function saveToWorkspace(workspace, filename, content) {
    workspace[filename] = {
        name:     filename,
        content,
        encoding: 'utf8',
        size:     new TextEncoder().encode(content).length,
    };
}

// On run, inject all workspace files except the current entry point
function buildRequest(language, version, filename, code, workspace) {
    const wsFiles = Object.values(workspace).filter(f => f.name !== filename);
    return {
        language,
        version,
        files:           [{ name: filename, content: code }, ...wsFiles],
        workspace_files: wsFiles.map(f => f.name),
    };
}
```

---

## Language Reference

### OOP / multi-file support

| Language | Multi-file | Folders | Import syntax |
|---|---|---|---|
| Java | ✓ — all `.java` files compiled together | ✓ — use Java packages | `import com.example.Class;` |
| C | ✓ — all `.c` files compiled together; `.h` in sandbox | ✓ — `#include "lib/utils.h"` | `#include "utils.h"` |
| C++ | ✓ — all `.cpp` files compiled together; `.h` in sandbox | ✓ | `#include "vec.h"` |
| Python | ✓ — all `.py` files in same dir | ✓ — maps to package path | `from utils.math import add` |
| JavaScript | ✓ — all `.js` files in same dir | ✓ — relative paths | `require('./utils')` |

### File naming rules

| Language | Entry point constraint |
|---|---|
| Java | Filename **must** match public class name: `Main.java` → `public class Main` |
| C / C++ | Any `.c` / `.cpp` filename |
| Python | Any `.py` filename |
| JavaScript | Any `.js` filename |

---

## Security Rules

Path validation is applied to both `files[].name` and `workspace_files[]` entries.

| Path | Allowed | Reason |
|---|---|---|
| `main.py` | ✓ | Plain filename |
| `src/Main.java` | ✓ | Forward-slash relative path |
| `com/example/App.java` | ✓ | Deep path |
| `../secret.txt` | ✗ | Path traversal |
| `/etc/passwd` | ✗ | Absolute path |
| `path\file.txt` | ✗ | Backslash separator |
| `src/../other.py` | ✗ | Traversal segment within path |
| `.` | ✗ | Single-dot segment |

Invalid entries in `workspace_files[]` are silently dropped. Invalid `files[].name` values fall back to a safe default.

---

## Limits & Rate Limits

### Resource limits

| Resource | Default |
|---|---|
| Run wall time | 30 s |
| Compile wall time | 30 s |
| Run memory | 256 MB |
| Compile memory | 512 MB |
| `output_files` count | 20 files per run |
| `output_files` single file | 1 MB |
| `output_files` total | 5 MB per run |
| stdin / request body | 2 MB |
| Networking inside sandbox | Disabled |

### Rate limits

| Endpoint | Limit |
|---|---|
| `POST /api/v2/execute` | 60 req/min per IP |
| `WS /api/v2/connect` | global cap: `max_concurrent_jobs × 2` |
| `GET /api/v2/packages` | 30 req/min per IP |
| `POST /api/v2/packages` | 5 req/min per IP |

Rate-limited requests return `429` with `Retry-After: 5`.
Queue-full requests return `503` with `Retry-After: 5` and `{ "message": "...", "code": "queue_full" }`.

---

## PistonSession — JS Client Class

A drop-in class that manages workspace state, injects files on each run, and updates the workspace from `output_files` automatically.

```js
class PistonSession {
    constructor(host) {
        this.host = host;
        // { [filename]: { name, content, encoding, size } }
        this.workspace = {};
    }

    /**
     * Run code via WebSocket. Streams output in real time.
     * @param {string} language   - e.g. "python", "java"
     * @param {string} version    - e.g. "3.12.0" or "*"
     * @param {string} filename   - entry-point filename, e.g. "main.py"
     * @param {string} code       - source code for the entry point
     * @param {function} onOutput - (stream: "stdout"|"stderr", data: string) => void
     * @returns {Promise<void>}   - resolves when job completes
     */
    run(language, version, filename, code, onOutput) {
        return new Promise((resolve, reject) => {
            const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const ws = new WebSocket(`${proto}//${this.host}/api/v2/connect`);

            // All workspace files except the current entry point
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
                        // Merge post-run versions back into workspace
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

    /**
     * Send stdin to the currently running program.
     * Call this from a terminal input handler.
     */
    sendStdin(ws, text) {
        ws.send(JSON.stringify({ type: 'data', stream: 'stdin', data: text }));
    }

    /**
     * Save a file to the workspace client-side without running it.
     * Useful for helper classes (e.g. Greeter.java) that have no main method.
     * The file will be injected on the next run() call automatically.
     */
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

### Usage — Java OOP across two runs

```js
const session = new PistonSession('localhost');

// Step 1: save the helper class client-side (no API call)
session.saveToWorkspace('Greeter.java', `
public class Greeter {
    private String name;
    public Greeter(String n) { this.name = n; }
    public String greet() { return "Hello, " + name + "!"; }
}
`);

// Step 2: run Main.java — Greeter.java is injected and compiled automatically
await session.run(
    'java', '*', 'Main.java',
    `public class Main {
        public static void main(String[] args) {
            System.out.println(new Greeter("World").greet());
        }
    }`,
    (stream, data) => console.log(data)
);
// Output: Hello, World!
```

### Usage — Python with folders

```js
// Save a module in a subfolder
session.saveToWorkspace('utils/math.py', 'def add(a, b): return a + b');

// Run main.py — utils/math.py is injected at utils/math.py in the sandbox
await session.run(
    'python', '*', 'main.py',
    'from utils.math import add\nprint(add(3, 4))',
    (stream, data) => console.log(data)
);
// Output: 7
```

### Usage — accumulating state across runs

```js
// Run 1 — creates notes.txt
await session.run('python', '*', 'main.py',
    "with open('notes.txt','w') as f: f.write('note 1\\n')",
    () => {}
);
// session.workspace now contains { "notes.txt": { ... "entry 1\n" } }

// Run 2 — notes.txt is re-injected automatically
await session.run('python', '*', 'main.py',
    "with open('notes.txt','a') as f: f.write('note 2\\n')\nprint(open('notes.txt').read())",
    (_, data) => console.log(data)
);
// Output: note 1\nnote 2\n
```

---

## Health endpoint

```
GET /api/v2/health
```

```json
{
  "status":    "ok",
  "runtimes":  12,
  "active":    3,
  "queued":    0,
  "capacity":  32,
  "queue_max": 64
}
```

Returns `503` with `"status": "degraded"` when the queue is at capacity.

---

> Full API reference: [`docs/api-v2.md`](docs/api-v2.md)
