'use strict';

const express   = require('express');
const expressWs = require('express-ws');
const { createSession, activeSessions } = require('./session');

const app  = express();
expressWs(app);

// ── Health check — nginx wait-for-backends.sh polls this ────────────────────
app.get('/health', (req, res) => {
    res.json({ status: 'ok', sessions: activeSessions.size });
});

// ── Stats — useful for monitoring ──────────────────────────────────────────
app.get('/stats', (req, res) => {
    res.json({ active_sessions: activeSessions.size });
});

// ── WebSocket terminal endpoint ─────────────────────────────────────────────
//
// Protocol (JSON over WebSocket):
//
//   CLIENT → SERVER
//   { "type": "input",  "data": "ls -la\n" }       keyboard input
//   { "type": "resize", "cols": 120, "rows": 30 }   terminal resize
//
//   SERVER → CLIENT
//   { "type": "ready",  "sessionId": "a1b2c3d4" }   sandbox ready
//   { "type": "output", "data": "..." }              terminal output
//   { "type": "exit",   "code": 0, "signal": null }  bash exited normally
//   { "type": "killed", "reason": "idle_timeout"|"max_lifetime"|"client_disconnect" }
//   { "type": "error",  "message": "..." }           startup failure
//
app.ws('/terminal', async (ws, req) => {
    let session = null;

    try {
        session = await createSession(ws);
    } catch (err) {
        console.error('[terminal-service] session create error:', err.message);
        if (ws.readyState === 1) {
            ws.send(JSON.stringify({ type: 'error', message: 'Failed to start sandbox: ' + err.message }));
            ws.close();
        }
        return;
    }

    ws.on('message', (raw) => {
        if (!session || session.dead) return;
        let msg;
        try { msg = JSON.parse(raw); } catch (_) {
            session.write(String(raw));
            return;
        }
        if (msg.type === 'input')  session.write(msg.data);
        if (msg.type === 'resize') session.resize(msg.cols, msg.rows);
    });

    ws.on('close', () => {
        if (session && !session.dead) session.destroy('client_disconnect');
    });

    ws.on('error', (err) => {
        console.error(`[session ${session?.id}] ws error:`, err.message);
        if (session && !session.dead) session.destroy('ws_error');
    });
});

const PORT = parseInt(process.env.PORT || '3000');
app.listen(PORT, () => {
    console.log(`[terminal-service] listening on :${PORT}`);
    console.log(`[terminal-service] sandbox image: ${process.env.SANDBOX_IMAGE || 'piston-sandbox:latest'}`);
});
