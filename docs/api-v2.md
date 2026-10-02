# API

Piston exposes an API for managing packages and executing user-defined code.

The API is broken in to 2 main sections - packages and jobs.

The API is exposed from the container, by default on port 2000, at `/api/v2/`.

All inputs are validated, and if an error occurs, a 4xx or 5xx status code is returned.
In this case, a JSON payload is sent back containing the error message as `message`

## Runtimes

### `GET /api/v2/runtimes`

Returns a list of available languages, including the version, runtime and aliases.

#### Response

-   `[].language`: Name of the language
-   `[].version`: Version of the runtime
-   `[].aliases`: List of alternative names that can be used for the language
-   `[].runtime` (_optional_): Name of the runtime used to run the langage, only provided if alternative runtimes exist for the language

#### Example

```
GET /api/v2/runtimes
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

[
  {
    "language": "bash",
    "version": "5.1.0",
    "aliases": ["sh"]
  },
  {
    "language": "javascript",
    "version": "15.10.0",
    "aliases": ["node-javascript", "node-js", "javascript", "js"],
    "runtime": "node"
  }
]
```

## Execute

### `POST /api/v2/execute`

Runs the given code, using the given runtime and arguments, returning the result.

#### Request

-   `language`: Name or alias of a language listed in [runtimes](#runtimes)
-   `version`: SemVer version selector of a language listed in [runtimes](#runtimes)
-   `files`: An array of files which should be uploaded into the job context
-   `files[].name` (_optional_): Name of file to be written, if none a random name is picked
-   `files[].content`: Content of file to be written
-   `files[].encoding` (_optional_): The encoding scheme used for the file content. One of `base64`, `hex` or `utf8`. Defaults to `utf8`.
-   `stdin` (_optional_): Text to pass into stdin of the program. Defaults to blank string.
-   `args` (_optional_): Arguments to pass to the program. Defaults to none
-   `run_timeout` (_optional_): The maximum allowed time in milliseconds for the compile stage to finish before bailing out. Must be a number, less than or equal to the configured maximum timeout.
-   `compile_timeout` (_optional_): The maximum allowed time in milliseconds for the run stage to finish before bailing out. Must be a number, less than or equal to the configured maximum timeout. Defaults to maximum.
-   `compile_memory_limit` (_optional_): The maximum amount of memory the compile stage is allowed to use in bytes. Must be a number, less than or equal to the configured maximum. Defaults to maximum, or `-1` (no limit) if none is configured.
-   `run_memory_limit` (_optional_): The maximum amount of memory the run stage is allowed to use in bytes. Must be a number, less than or equal to the configured maximum. Defaults to maximum, or `-1` (no limit) if none is configured.

#### Response

-   `language`: Name (not alias) of the runtime used
-   `version`: Version of the used runtime
-   `run`: Results from the run stage
-   `run.stdout`: stdout from run stage process
-   `run.stderr`: stderr from run stage process
-   `run.output`: stdout and stderr combined in order of data from run stage process
-   `run.code`: Exit code from run process, or null if signal is not null
-   `run.signal`: Signal from run process, or null if code is not null
-   `compile` (_optional_): Results from the compile stage, only provided if the runtime has a compile stage
-   `compile.stdout`: stdout from compile stage process
-   `compile.stderr`: stderr from compile stage process
-   `compile.output`: stdout and stderr combined in order of data from compile stage process
-   `compile.code`: Exit code from compile process, or null if signal is not null
-   `compile.signal`: Signal from compile process, or null if code is not null
-   `output_files`: Array of files created by the program during the run stage. Always present; empty array `[]` if no files were written. Capped at 20 files and 5 MB total. Files over 1 MB each are silently skipped. Symlinks are never followed.
-   `output_files[].name`: Relative path of the file within the job's working directory (e.g. `report.txt`, `data/output.csv`)
-   `output_files[].content`: File content as a string. Text files (valid UTF-8) are returned as-is. Binary files are base64-encoded.
-   `output_files[].encoding`: `"utf8"` for text files, `"base64"` for binary files
-   `output_files[].size`: File size in bytes

#### Output Files — Language Notes

| Language | Compile stage | What `output_files` contains |
|---|---|---|
| Python, JavaScript, Node, Ruby, etc. | No | Files your code created with `open()`, `fs.writeFile()`, etc. |
| C, C++ | Yes | Files created during `main()` — compiled binary is excluded from diff |
| Java | Yes | Files created at runtime — `.class` files are excluded from diff |

The diff is taken **after compile and before run**, so compiled artifacts (`.class`, `.o`, binaries) never appear in `output_files` regardless of language.

---

## Multi-file Compilation & OOP (Cross-file Classes)

Piston supports multi-file projects — multiple source files compiled together in one job. This enables OOP patterns: define a class in one file, use it in another.

### How It Works

Pass all source files in the `files[]` array. The **first file** is always the entry point (the one with `main()` / `public static void main`). Additional source files can be any order.

Additionally, set `workspace_files` to the list of file names that come from a previous run's `output_files` (your persistent workspace). Piston automatically:
- Writes all files to the sandbox before compilation
- Passes same-extension source files to the compiler alongside the entry point
- Data files (`.txt`, `.csv`, etc.) are written to the sandbox for reading but **not** passed to the compiler

### File Naming Rules

| Language | Entry point name | Why |
|---|---|---|
| Java | **Must match the public class name** — e.g. `Main.java` for `public class Main` | Java compiler enforces this |
| C / C++ | Any `.c` / `.cpp` name — e.g. `main.c` | No constraint |
| Python / JS / etc. | Any valid filename | Interpreter accepts any name |

### Example — Java OOP (Two Classes)

Define a `Greeter` class in `Greeter.java` and use it from `Main.java`:

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
  "run": {
    "stdout": "Hello, World!\n",
    "stderr": "", "code": 0, "signal": null, "output": "Hello, World!\n"
  },
  "output_files": []
}
```

### Example — C Multi-file (Header + Implementation)

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

> **Note:** `.h` header files are written to the sandbox (so `#include "math_utils.h"` resolves) but are **not** passed to the compiler as source files — only `.c` files matching the entry-point extension are compiled.

### Example — Python Multi-file (Module Import)

Python has no compile stage — all files land in the same working directory. `import` works out of the box.

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
      "content": "import math\n\nclass Circle:\n    def __init__(self, r):\n        self.r = r\n    def area(self):\n        return math.pi * self.r ** 2"
    }
  ]
}
```

---

## Workspace — Cross-run File Persistence

The workspace API lets you persist files across multiple runs. Files created in run 1 are injected back into run 2's sandbox, enabling stateful sessions (read/write the same file across runs, grow a database, accumulate outputs, etc.).

### Request Fields

-   `workspace_files` (_optional_): Array of file name strings. Each name must match a file already present in `files[]`. These files are treated as **workspace files** — they existed before this run (carried over from a previous run's `output_files`).

### Behaviour

| File type | In sandbox? | Passed to compiler? | Captured in `output_files`? |
|---|---|---|---|
| Entry-point source file | ✓ | ✓ | ✗ (excluded by pre-run snapshot) |
| Same-extension workspace source (e.g. `Helper.java`) | ✓ | ✓ | ✓ (re-captured to detect modifications) |
| Different-extension workspace data (e.g. `data.txt`) | ✓ | ✗ | ✓ (re-captured to detect modifications) |
| Files created during run | ✓ | — | ✓ |

### Workflow

```
Run 1: files=[main.py], workspace_files=[]
       → output_files=[report.txt]

Run 2: files=[main.py, report.txt], workspace_files=["report.txt"]
       → report.txt is in sandbox, user code can open() it
       → output_files=[report.txt]  ← includes any modifications made during run
```

### Example — Python: Write then Read Across Runs

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
      "content": "with open('notes.txt', 'w') as f:\n    f.write('Line 1\\nLine 2\\n')\nprint('Written.')"
    }
  ],
  "workspace_files": []
}
```

```json
{
  "run": { "stdout": "Written.\n", "code": 0, ... },
  "output_files": [
    { "name": "notes.txt", "content": "Line 1\nLine 2\n", "encoding": "utf8", "size": 14 }
  ]
}
```

**Run 2 — read it back (inject `output_files` from Run 1 into `files`):**

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "*",
  "files": [
    {
      "name": "main.py",
      "content": "with open('notes.txt') as f:\n    print(f.read())"
    },
    {
      "name": "notes.txt",
      "content": "Line 1\nLine 2\n",
      "encoding": "utf8"
    }
  ],
  "workspace_files": ["notes.txt"]
}
```

```json
{
  "run": { "stdout": "Line 1\nLine 2\n", "code": 0, ... },
  "output_files": [
    { "name": "notes.txt", "content": "Line 1\nLine 2\n", "encoding": "utf8", "size": 14 }
  ]
}
```

### Example — Java: Workspace + OOP in the Same Run

You can combine both features — inject a saved `.java` source file from the workspace AND compile it alongside the new entry point:

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "java",
  "version": "*",
  "files": [
    {
      "name": "Main.java",
      "content": "public class Main {\n    public static void main(String[] args) {\n        Counter c = new Counter();\n        c.increment();\n        c.increment();\n        System.out.println(c.get());\n    }\n}"
    },
    {
      "name": "Counter.java",
      "content": "public class Counter {\n    private int n = 0;\n    public void increment() { n++; }\n    public int get() { return n; }\n}",
      "encoding": "utf8"
    }
  ],
  "workspace_files": ["Counter.java"]
}
```

> `Counter.java` is a workspace file (came from a previous run). It shares the `.java` extension with the entry point, so it is compiled together with `Main.java`. Output: `2`.

### WebSocket — `output_files` Message

When using `/api/v2/connect`, output files arrive as a dedicated message **before** `exit:done`:

```json
{ "type": "output_files", "files": [ { "name": "report.txt", "content": "...", "encoding": "utf8", "size": 42 } ] }
```

Only sent when at least one file was captured. Integrate it like this:

```js
ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);

    switch (msg.type) {
        case 'output_files':
            // Merge into your workspace store, keyed by msg.files[i].name
            for (const f of msg.files) {
                workspace[f.name] = f;
            }
            break;

        case 'exit':
            if (msg.stage === 'done') {
                // Run complete — workspace is up to date
            }
            break;
    }
};
```

**On the next run**, pass the accumulated workspace back:

```js
const workspaceFiles = Object.values(workspace); // [{name, content, encoding, size}, ...]

ws.send(JSON.stringify({
    type: 'init',
    language: 'java',
    version: '15.0.2',
    files: [
        { name: 'Main.java', content: editorCode },
        ...workspaceFiles.map(f => ({ name: f.name, content: f.content, encoding: f.encoding })),
    ],
    workspace_files: workspaceFiles.map(f => f.name),
}));
```

#### Example — File I/O (Python)

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "python",
  "version": "3.12.0",
  "files": [
    {
      "name": "main.py",
      "content": "with open('hello.txt', 'w') as f:\n    f.write('Hello, World!')\nprint('File written.')"
    }
  ]
}
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

{
  "language": "python",
  "version": "3.12.0",
  "run": {
    "stdout": "File written.\n",
    "stderr": "",
    "code": 0,
    "signal": null,
    "output": "File written.\n"
  },
  "output_files": [
    {
      "name": "hello.txt",
      "content": "Hello, World!",
      "encoding": "utf8",
      "size": 13
    }
  ]
}
```

#### Example — No files created (JavaScript)

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "javascript",
  "version": "20.11.1",
  "files": [{ "name": "main.js", "content": "console.log('hi')" }]
}
```

```json
HTTP/1.1 200 OK

{
  "language": "javascript",
  "version": "20.11.1",
  "run": { "stdout": "hi\n", "stderr": "", "code": 0, "signal": null, "output": "hi\n" },
  "output_files": []
}
```

#### WebSocket — `output_files` message

When using the `/api/v2/connect` WebSocket endpoint, output files are delivered as a separate message **before** the `{ "type": "exit", "stage": "done" }` close message:

```json
{ "type": "output_files", "files": [ { "name": "report.txt", "content": "...", "encoding": "utf8", "size": 42 } ] }
```

This message is only sent if at least one file was captured. Listen for it in your `onmessage` handler:

```js
ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'output_files') {
        // msg.files is the same array as output_files in the HTTP response
        renderFileExplorer(msg.files);
    }
};
```

#### Example — original JS example (no file I/O)

```json
POST /api/v2/execute
Content-Type: application/json

{
  "language": "js",
  "version": "15.10.0",
  "files": [
    {
      "name": "my_cool_code.js",
      "content": "console.log(process.argv)"
    }
  ],
  "stdin": "",
  "args": ["1", "2", "3"],
  "compile_timeout": 10000,
  "run_timeout": 3000,
  "compile_memory_limit": -1,
  "run_memory_limit": -1
}
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

{
  "run": {
    "stdout": "[\n  '/piston/packages/node/15.10.0/bin/node',\n  '/piston/jobs/e87afa0d-6c2a-40b8-a824-ffb9c5c6cb64/my_cool_code.js',\n  '1',\n  '2',\n  '3'\n]\n",
    "stderr": "",
    "code": 0,
    "signal": null,
    "output": "[\n  '/piston/packages/node/15.10.0/bin/node',\n  '/piston/jobs/e87afa0d-6c2a-40b8-a824-ffb9c5c6cb64/my_cool_code.js',\n  '1',\n  '2',\n  '3'\n]\n"
  },
  "output_files": [],
  "language": "javascript",
  "version": "15.10.0"
}
```

## Packages

### `GET /api/v2/packages`

Returns a list of all possible packages, and whether their installation status.

#### Response

-   `[].language`: Name of the contained runtime
-   `[].language_version`: Version of the contained runtime
-   `[].installed`: Status on the package being installed

#### Example

```
GET /api/v2/packages
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

[
  {
    "language": "node",
    "language_version": "15.10.0",
    "installed": true
  },
  {
    "language": "bash",
    "language_version": "5.1.0",
    "installed": true
  }
]
```

### `POST /api/v2/packages`

Install the given package.

#### Request

-   `language`: Name of package from [package list](#get-apiv2packages)
-   `version`: SemVer version selector for package from [package list](#get-apiv2packages)

#### Response

-   `language`: Name of package installed
-   `version`: Version of package installed

#### Example

```json
POST /api/v2/packages
Content-Type: application/json

{
  "language": "bash",
  "version": "5.x"
}
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

{
  "language": "bash",
  "version": "5.1.0"
}
```

### `DELETE /api/v2/packages`

Uninstall the given package.

#### Request

-   `language`: Name of package from [package list](#get-apiv2packages)
-   `version`: SemVer version selector for package from [package list](#get-apiv2packages)

#### Response

-   `language`: Name of package uninstalled
-   `version`: Version of package uninstalled

#### Example

```json
DELETE /api/v2/packages
Content-Type: application/json

{
  "language": "bash",
  "version": "5.x"
}
```

```json
HTTP/1.1 200 OK
Content-Type: application/json

{
  "language": "bash",
  "version": "5.1.0"
}
```
