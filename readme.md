# Piston Compilers

A production-ready code execution engine built on top of Piston. Runs 3 load-balanced API replicas behind nginx, supports 30+ languages, and handles interactive stdin/stdout over WebSockets.

---

## Deployment

```bash
./deploy.sh start      # first-time setup, installs runtimes automatically
./deploy.sh stop       # stop all containers
./deploy.sh restart    # restart everything
./deploy.sh status     # check container health
```

---

## Ports

| Port | What it serves |
|------|----------------|
| `80` | Built-in frontend UI + all API routes |
| `2000` | API only (no UI) — use this port if you are building your own frontend |

CORS is open on both ports. No API keys required.

---

## API Routes

Base URL for external frontends: `http://<YOUR_SERVER_IP>:2000`

| Method | Route | Description |
|--------|-------|-------------|
| `GET` | `/api/v2/runtimes` | List all installed languages and versions |
| `POST` | `/api/v2/execute` | Run code and get back the full output |
| `WS` | `/api/v2/connect` | Run code interactively with live stdin/stdout |
| `GET` | `/api/v2/health` | Health check, returns 200 if the API is up |

---

## 1. List Available Languages

```
GET /api/v2/runtimes
```

Use this to populate a language selector in your UI.

**Response:**
```json
[
  { "language": "python",     "version": "3.12.0", "aliases": ["python3"] },
  { "language": "javascript", "version": "20.11.1", "aliases": ["js", "node"] },
  { "language": "java",       "version": "15.0.2",  "aliases": [] }
]
```

---

## 2. Run Code (Simple, No Stdin)

Use this for code that does not need user input at runtime.

```
POST /api/v2/execute
Content-Type: application/json
```

**Request:**
```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [
    { "name": "main.py", "content": "print('Hello, World!')" }
  ],
  "stdin": "",
  "args": []
}
```

**Response:**
```json
{
  "language": "python",
  "version": "3.12.0",
  "run": {
    "stdout": "Hello, World!\n",
    "stderr": "",
    "output": "Hello, World!\n",
    "code": 0,
    "signal": null
  }
}
```

For compiled languages (Java, C, C++, etc.) you also get a `compile` object alongside `run`:
```json
{
  "compile": { "stdout": "", "stderr": "", "code": 0, "signal": null },
  "run":     { "stdout": "Hello\n", "stderr": "", "code": 0, "signal": null }
}
```

You can also pass `stdin` as a string to pre-feed input:
```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [{ "name": "main.py", "content": "name = input()\nprint(f'Hello, {name}!')" }],
  "stdin": "Alice\n"
}
```

---

## 3. Run Code Interactively (WebSocket, Live Stdin/Stdout)

Use this when students need to type input while the program is running.

```
WS ws://<YOUR_SERVER_IP>:2000/api/v2/connect
```

### Step 1 - Connect and send init

Right after the connection opens, send this:

```json
{
  "type": "init",
  "language": "python",
  "version": "3.12.0",
  "files": [
    { "name": "main.py", "content": "name = input('Enter name: ')\nprint(f'Hello, {name}!')" }
  ],
  "args": [],
  "stdin": ""
}
```

### Step 2 - Receive messages from server

```json
{ "type": "runtime", "language": "python", "version": "3.12.0" }
{ "type": "stage",   "stage": "run" }
{ "type": "data",    "stream": "stdout", "data": "Enter name: " }
{ "type": "exit",    "stage": "run", "code": 0, "signal": null }
```

| type | When it fires |
|------|---------------|
| `runtime` | First message, confirms the language being used |
| `stage` | Fired when execution moves to `compile` or `run` stage |
| `data` | A chunk of stdout or stderr output |
| `exit` | The stage finished, includes exit code |

The WebSocket closes with code `4999` when the job completes normally.

### Step 3 - Send stdin while the program is running

When the user types into your terminal component, send:

```json
{ "type": "data", "stream": "stdin", "data": "Alice\n" }
```

Send each keystroke or line as the user types it. Always include the newline `\n` if the program is waiting for a full line of input.

### Full example (JavaScript)

```js
const ws = new WebSocket('ws://<YOUR_SERVER_IP>:2000/api/v2/connect');

ws.onopen = () => {
  ws.send(JSON.stringify({
    type:     'init',
    language: 'python',
    version:  '3.12.0',
    files:    [{ name: 'main.py', content: 'name = input()\nprint(f"Hello, {name}!")' }],
    args:     [],
    stdin:    '',
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);

  if (msg.type === 'data') {
    // append msg.data to your terminal display
    terminal.write(msg.data);
  }

  if (msg.type === 'exit') {
    console.log('exited with code', msg.code);
  }
};

// call this when the user types
function sendInput(text) {
  ws.send(JSON.stringify({ type: 'data', stream: 'stdin', data: text }));
}
```

---

## 4. Sending Multiple Files

Both `/api/v2/execute` and `/api/v2/connect` accept a `files` array. The first file in the array is the entry point.

**Java example (requires filename to match class name):**
```json
{
  "language": "java",
  "version": "15.0.2",
  "files": [
    { "name": "Main.java",   "content": "public class Main { public static void main(String[] args) { Helper.greet(); } }" },
    { "name": "Helper.java", "content": "public class Helper { public static void greet() { System.out.println(\"Hello!\"); } }" }
  ]
}
```

**Subdirectory paths also work:**
```json
{
  "language": "python",
  "version": "3.12.0",
  "files": [
    { "name": "main.py",           "content": "from src.utils import greet\ngreet()" },
    { "name": "src/utils.py",      "content": "def greet(): print('Hello!')" },
    { "name": "data/input.txt",    "content": "42\n" }
  ]
}
```

Parent directories are created automatically. No extra config needed.

---

## 5. Timeout and Memory Limits

The server default is 30 seconds per run and 256 MB memory. You can override per request (up to the server max):

```json
{
  "language": "python",
  "version":  "3.12.0",
  "files":    [{ "name": "main.py", "content": "print('hi')" }],
  "run_timeout":          10000,
  "compile_timeout":      10000,
  "run_memory_limit":     134217728,
  "compile_memory_limit": 268435456
}
```

| Field | Unit | Default |
|-------|------|---------|
| `run_timeout` | milliseconds | 30000 |
| `compile_timeout` | milliseconds | 30000 |
| `run_memory_limit` | bytes | 268435456 (256 MB) |
| `compile_memory_limit` | bytes | 536870912 (512 MB) |

---

## 6. Deploying Your Own Frontend

**Option 1 - Replace the built-in UI:**

Build your React/Vue/Next app and drop the output into `./frontend/`. It will be served on port 80 automatically.

```bash
npm run build
cp -r dist/* ./path/to/piston/frontend/
```

**Option 2 - Host separately:**

Host your frontend anywhere (Vercel, Netlify, your own server) and point your API and WebSocket calls at `http://<YOUR_SERVER_IP>:2000`. CORS is open, no configuration needed on the server side.

---

## Supported Languages

Python, JavaScript (Node), TypeScript, Java, C, C++, C#, Go, Rust, Ruby, PHP, Kotlin, Swift, Scala, Haskell, Lua, Perl, R, Bash, Dart, Julia, Elixir, Erlang, OCaml, Pascal, Nim, SQLite, Brainfuck, NASM, Zig, V, CoffeeScript, Crystal, Clojure, Groovy, Lisp, Prolog, COBOL, Fortran, and more.

Run `GET /api/v2/runtimes` to get the exact list of what is installed on your deployment.
