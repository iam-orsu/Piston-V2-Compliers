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

## How to Deploy a Custom UI

**Option 1 - Replace the frontend folder:**
Run `npm run build` on your React/Vue app and place the output into `./frontend/`. The server serves it automatically on port 8080.

**Option 2 - Host externally:**
Host your frontend on any platform (Vercel, Netlify, another server) and point API and WebSocket calls directly at `http://<SERVER_IP>:8080`. CORS is open, no configuration needed.
