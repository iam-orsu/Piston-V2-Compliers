# Instacks Compilers

A fully re-engineered, hardened Piston execution engine and sandboxed terminal system for Instacks.

Everything runs through a single port: **8080**.

---

## How to Run

```bash
./deploy.sh start      # Starts all services
./deploy.sh stop       # Stops all services
./deploy.sh restart    # Restarts all services
./deploy.sh status     # Checks status
```

---

## Frontend Developer Integration Guide

Frontend developers can build their own UI (React, Vue, Next.js, etc.) and connect directly to these endpoints on port 8080. CORS is enabled globally.

### 1. List Available Compilers

**Endpoint:** `GET http://<SERVER_IP>:8080/api/v2/runtimes`

Use this to populate the language selector dropdown.

**Response:**
```json
[
  { "language": "python", "version": "3.12.0" },
  { "language": "c++",    "version": "10.2.0" },
  { "language": "java",   "version": "15.0.2" }
]
```

---

### 2. Run Code (Stateless REST)

**Endpoint:** `POST http://<SERVER_IP>:8080/api/v2/execute`

**Request:**
```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [{ "name": "main.py", "content": "print('Hello world')" }],
  "stdin": ""
}
```

**Response:** Returns `stdout`, `stderr`, exit code, and execution time.

```json
{
  "language": "python",
  "version": "3.12.0",
  "run": {
    "stdout": "Hello world\n",
    "stderr": "",
    "code": 0,
    "cpu_time": 47,
    "wall_time": 66
  }
}
```

---

### 3. Run Code (Interactive WebSocket with Live Stdin/Stdout)

**Endpoint:** `WS ws://<SERVER_IP>:8080/api/v2/connect`

**Protocol:**

1. Send init message after connecting:
```json
{
  "type": "init",
  "language": "python",
  "version": "3.12.0",
  "files": [{ "name": "main.py", "content": "name = input()\nprint(name)" }]
}
```

2. Receive live output:
```json
{ "type": "data", "stream": "stdout", "data": "..." }
{ "type": "data", "stream": "stderr", "data": "..." }
```

3. Send stdin while the program is running:
```json
{ "type": "data", "stream": "stdin", "data": "input text\n" }
```

4. Receive exit event when the program finishes:
```json
{ "type": "exit", "stage": "run", "code": 0 }
```

---

### 4. Live Sandboxed Linux Shell

**Endpoint:** `WS ws://<SERVER_IP>:8080/terminal`

Connects to an isolated Debian bash container. The container is destroyed when the session ends.

**Server sends:**
```json
{ "type": "ready",  "sessionId": "a1b2c3d4" }
{ "type": "output", "data": "sandbox:~$ " }
{ "type": "killed", "reason": "idle_timeout" }
```

**Client sends:**
```json
{ "type": "input",  "data": "ls -la\n" }
{ "type": "resize", "cols": 80, "rows": 24 }
{ "type": "seed",   "filename": "main.py", "content": "print('hello')" }
```

- `input` - raw keystrokes as the user types
- `resize` - send whenever the terminal element is resized
- `seed` - writes a file into the sandbox home directory (use this to sync the editor contents into the shell)

Sessions are killed automatically after 5 minutes of inactivity or 30 minutes total.

---

## Pre-seeding Custom Files and Starter Code (Dev Guide)

This section explains how to dynamically load any file, starter code, or problem boilerplate from your database into both the compiler and the live terminal. No backend changes are needed. The backend accepts any filename and any content on every endpoint.

---

### Seeding Files into the Compiler

Applies to both:
- `POST http://<SERVER_IP>:8080/api/v2/execute`
- `WS ws://<SERVER_IP>:8080/api/v2/connect` (inside the `init` message)

Pass your files in the `files` array. The `name` field is the filename. The `content` field is the full source code as a string. There are no restrictions on filenames.

**Single file:**
```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [
    { "name": "solution.py", "content": "# your starter code here\nprint('hello')" }
  ]
}
```

**Multiple files (e.g. Java with a helper class):**
```json
{
  "language": "java",
  "version": "15.0.2",
  "files": [
    { "name": "Solution.java", "content": "public class Solution { public static void main(String[] args) { Helper.run(); } }" },
    { "name": "Helper.java",   "content": "public class Helper { public static void run() { System.out.println(\"hi\"); } }" }
  ]
}
```

The runtime uses the first file as the entry point. Pass files in the order you want them compiled.

---

### Seeding Files into the Live Terminal Shell

**Endpoint:** `WS ws://<SERVER_IP>:8080/terminal`

After connecting, wait for the server to send the `ready` event, then immediately send a `seed` message. This writes your file into `/home/sandbox/<filename>` inside the student's live shell.

**Step 1 - Wait for ready:**
```json
{ "type": "ready", "sessionId": "a1b2c3d4" }
```

**Step 2 - Send the seed immediately after:**
```json
{
  "type": "seed",
  "filename": "Solution.java",
  "content": "public class Solution {\n  public static void main(String[] args) {\n    // starter code\n  }\n}"
}
```

The file appears instantly in the student's shell at `/home/sandbox/Solution.java`. The student can run `cat Solution.java`, compile it, or edit it.

**Rules for the filename field:**
- Must start with a letter or number: `a-z`, `A-Z`, or `0-9`
- Can contain letters, numbers, underscores, dots, hyphens, and forward slashes for nested paths: `Solution.java`, `main_v2.py`, `src/models/user.py`
- No spaces, backslashes, or other special characters
- No `..` or `.` path components — blocked to prevent sandbox escapes
- No leading slash, no double slashes, no trailing slash
- Max length is not enforced but keep it sane

**Re-seeding:** You can send another `seed` message at any time to update the file as the student edits in the browser. Send it on every editor change or on a debounce.

---

### Seeding Nested Folders and Directory Structures

Both the compiler and the terminal fully support subdirectory paths. You are not limited to flat files in the root.

**Compiler (`POST /api/v2/execute` and `WS /api/v2/connect`):**

Pass the relative path including folders in the `name` field. Parent directories are created automatically.

```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [
    { "name": "src/models/user.py",  "content": "class User: pass" },
    { "name": "src/utils/helper.py", "content": "def greet(): print('hi')" },
    { "name": "tests/test_main.py",  "content": "from src.models.user import User" },
    { "name": "data/input.txt",      "content": "42\n" }
  ]
}
```

The first file in the array is treated as the entry point.

**Terminal (`WS ws://<SERVER_IP>:8080/terminal`):**

Send one `seed` message per file. Each file is written into the student's sandbox at `/home/sandbox/<filename>`. Parent directories are created automatically with `mkdir -p`.

```json
{ "type": "seed", "filename": "src/models/user.py",  "content": "class User: pass" }
{ "type": "seed", "filename": "tests/test_main.py",  "content": "import unittest" }
{ "type": "seed", "filename": "data/input.txt",      "content": "42\n" }
```

After seeding, the student's shell will have:
```
/home/sandbox/
  src/
    models/
      user.py
  tests/
    test_main.py
  data/
    input.txt
```

**Filename rules for nested paths:**
- Use forward slashes only: `src/models/user.py`
- Each component must start with a letter or number
- Allowed characters per component: letters, numbers, underscores, dots, hyphens
- No `..` or `.` components — these are blocked to prevent escaping the sandbox
- No leading slash, no double slashes, no trailing slash
- Examples that work: `src/main.py`, `com/example/Main.java`, `data/input/test_1.txt`
- Examples that are blocked: `../escape.py`, `/etc/passwd`, `a//b.py`

**Typical integration pattern for a problem with multiple files:**
```js
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data)
  if (msg.type === 'ready') {
    // Seed every file from your problem database
    for (const file of problem.files) {
      ws.send(JSON.stringify({
        type:     'seed',
        filename: file.path,    // e.g. "src/Solution.java"
        content:  file.content  // starter boilerplate
      }))
    }
  }
}
```

---

## How to Deploy a Custom UI

**Option 1 - Replace the frontend folder:**
Run `npm run build` on your React/Vue app and place the output into `./frontend/`. The server serves it automatically on port 8080.

**Option 2 - Host externally:**
Host your frontend on any platform (Vercel, Netlify, another server) and point API and WebSocket calls directly at `http://<SERVER_IP>:8080`. CORS is open, no configuration needed.
