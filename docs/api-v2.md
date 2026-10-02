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
