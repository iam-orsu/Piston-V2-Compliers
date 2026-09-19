'use strict';

const pty              = require('node-pty');
const { execSync, exec, spawn } = require('child_process');
const { randomBytes }  = require('crypto');

const SANDBOX_IMAGE = process.env.SANDBOX_IMAGE || 'piston-sandbox:latest';
const IDLE_MS       = parseInt(process.env.IDLE_TIMEOUT_MS  || '300000');   // 5 min
const MAX_MS        = parseInt(process.env.MAX_LIFETIME_MS  || '1800000');  // 30 min

const activeSessions = new Map();

class Session {
    constructor(ws) {
        this.id            = randomBytes(4).toString('hex');
        this.containerName = `student-${this.id}`;
        this.ws            = ws;
        this.dead          = false;
        this.lastInput     = Date.now();
        this._pty          = null;
        this._maxTimer     = null;
        this._idleInterval = null;
        this._seededFile   = null;  // last file written into sandbox home
    }

    async start() {
        // All security constraints applied here — students can't change these
        const dockerArgs = [
            'run', '--rm', '-it',
            '--name',         this.containerName,
            '--hostname',     'sandbox',

            // Filesystem: read-only image, two small tmpfs mounts
            '--read-only',
            '--tmpfs', '/home/sandbox:rw,size=64m,uid=1000,gid=1000,mode=0700',
            '--tmpfs', '/tmp:rw,size=32m,mode=1777',

            // Network: completely isolated — no internet, no host reach
            '--network', 'none',

            // Process limits: kills fork bombs before they spread
            '--pids-limit', '100',

            // Memory: 128 MB cap, no swap
            '--memory',      '128m',
            '--memory-swap', '128m',

            // CPU: 0.5 vCPU max — fair share across students
            '--cpus', '0.5',

            // ulimits: belt-and-suspenders on processes + file descriptors
            '--ulimit', 'nproc=100:100',
            '--ulimit', 'nofile=256:256',

            // Capabilities: drop everything — bash needs none of them
            '--cap-drop', 'ALL',

            // Prevent setuid binaries from escalating privileges
            '--security-opt', 'no-new-privileges',

            // Run as unprivileged user (sandbox, uid 1000)
            '--user', '1000:1000',

            SANDBOX_IMAGE,
            '/bin/bash', '--login',
        ];

        this._pty = pty.spawn('docker', dockerArgs, {
            name: 'xterm-256color',
            cols: 80,
            rows: 24,
            env: {
                HOME: '/home/sandbox',
                TERM: 'xterm-256color',
                LANG: 'C.UTF-8',
                PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            },
        });

        // Stream PTY output → WebSocket
        this._pty.onData(data => {
            if (this.ws.readyState === 1) {
                this.ws.send(JSON.stringify({ type: 'output', data }));
            }
        });

        this._pty.onExit(({ exitCode, signal }) => {
            if (this.dead) return;
            this.dead = true;  // set early — prevents double-destroy if close triggers synchronously
            if (this.ws.readyState === 1) {
                this.ws.send(JSON.stringify({ type: 'exit', code: exitCode, signal: signal || null }));
                this.ws.close();
            }
            this._cleanup();
        });

        this._startTimers();
        activeSessions.set(this.id, this);

        this.ws.send(JSON.stringify({ type: 'ready', sessionId: this.id }));
        console.log(`[session ${this.id}] started → container ${this.containerName}`);
    }

    write(data) {
        if (this.dead || !this._pty) return;
        this.lastInput = Date.now();
        this._pty.write(data);
    }

    resize(cols, rows) {
        if (this.dead || !this._pty) return;
        try { this._pty.resize(Number(cols) || 80, Number(rows) || 24); } catch (_) {}
    }

    seedFile(filename, content) {
        if (this.dead) return;
        // Only allow safe filenames (e.g. main.py, Main.java, main.ts)
        if (!/^[a-zA-Z][a-zA-Z0-9_.\-]*$/.test(filename)) return;
        if (typeof content !== 'string' || content.length > 65536) return;
        const prevFile = (this._seededFile !== filename) ? this._seededFile : null;
        this._seededFile = filename;
        this._doSeed(filename, content, prevFile, 5);
    }

    _doSeed(filename, content, prevFile, retriesLeft) {
        if (this.dead || retriesLeft <= 0) return;
        // Remove previous language's file first so sandbox home only ever has one file
        const cmd = prevFile
            ? `rm -f /home/sandbox/${prevFile} && cat > /home/sandbox/${filename}`
            : `cat > /home/sandbox/${filename}`;
        const child = spawn('docker', [
            'exec', '-i', this.containerName,
            'sh', '-c', cmd,
        ]);
        child.stdin.write(content, 'utf8');
        child.stdin.end();
        child.on('exit', (code) => {
            if (code !== 0 && !this.dead) {
                setTimeout(() => this._doSeed(filename, content, prevFile, retriesLeft - 1), 400);
            } else if (code === 0) {
                const cleaned = prevFile ? ` (removed ${prevFile})` : '';
                console.log(`[session ${this.id}] seeded ${filename}${cleaned}`);
            }
        });
        child.on('error', () => {
            if (!this.dead) setTimeout(() => this._doSeed(filename, content, prevFile, retriesLeft - 1), 400);
        });
    }

    destroy(reason = 'unknown') {
        if (this.dead) return;
        console.log(`[session ${this.id}] destroyed: ${reason}`);
        if (this.ws.readyState === 1) {
            this.ws.send(JSON.stringify({ type: 'killed', reason }));
            this.ws.close();
        }
        this._cleanup();
    }

    _cleanup() {
        if (this.dead) return;
        this.dead = true;
        clearTimeout(this._maxTimer);
        clearInterval(this._idleInterval);
        try { this._pty?.kill(); } catch (_) {}
        exec(`docker rm -f ${this.containerName} 2>/dev/null`);  // async — never blocks event loop
        activeSessions.delete(this.id);
        console.log(`[session ${this.id}] cleaned up`);
    }

    _startTimers() {
        // Hard cap: session dies after MAX_MS regardless of activity
        this._maxTimer = setTimeout(() => {
            this.destroy('max_lifetime');
        }, MAX_MS);

        // Idle check: kill if no keystrokes for IDLE_MS
        this._idleInterval = setInterval(() => {
            if (Date.now() - this.lastInput > IDLE_MS) {
                this.destroy('idle_timeout');
            }
        }, 60_000);
    }
}

async function createSession(ws) {
    const session = new Session(ws);
    await session.start();
    return session;
}

// Kill orphaned student containers left from previous crash
function cleanupOrphans() {
    try {
        const out = execSync('docker ps -q --filter "name=student-"').toString().trim();
        if (out) {
            execSync(`docker rm -f ${out.split('\n').join(' ')} 2>/dev/null`);
            console.log('[terminal-service] cleaned up orphaned containers');
        }
    } catch (_) {}
}

// Graceful shutdown
function shutdown() {
    console.log('[terminal-service] shutting down — destroying all sessions');
    for (const s of activeSessions.values()) s._cleanup();
    process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);

cleanupOrphans();

module.exports = { createSession, activeSessions };
