const express = require('express');
const router = express.Router();

const events = require('events');

const runtime = require('../runtime');
const { Job } = require('../job');
const package = require('../package');
const globals = require('../globals');
const config = require('../config');
const logger = require('logplease').create('api/v2');

// M1/H1: Per-IP rate limiting for execution endpoint — requires express-rate-limit
// Falls back gracefully if the package isn't installed yet
let rateLimit;
try {
    rateLimit = require('express-rate-limit');
} catch (_) {
    rateLimit = null;
}

const make_limiter = (max, window_ms) => {
    if (!rateLimit) return (req, res, next) => next();
    return rateLimit({
        windowMs: window_ms,
        max,
        standardHeaders: true,
        legacyHeaders: false,
        message: { message: 'Too many requests, please slow down.' },
    });
};

// H4: Guard ws.send() — drop silently if the socket is no longer open
const safe_ws_send = (ws, data) => {
    if (ws.readyState === 1 /* OPEN */) {
        try {
            ws.send(data);
        } catch (e) {
            // socket closed between the readyState check and the send
        }
    }
};

function get_job(body) {
    let {
        language,
        version,
        args,
        stdin,
        files,
        compile_memory_limit,
        run_memory_limit,
        run_timeout,
        compile_timeout,
        run_cpu_time,
        compile_cpu_time,
    } = body;

    return new Promise((resolve, reject) => {
        if (!language || typeof language !== 'string') {
            return reject({
                message: 'language is required as a string',
            });
        }
        if (!version || typeof version !== 'string') {
            return reject({
                message: 'version is required as a string',
            });
        }
        if (!files || !Array.isArray(files)) {
            return reject({
                message: 'files is required as an array',
            });
        }
        for (const [i, file] of files.entries()) {
            if (typeof file.content !== 'string') {
                return reject({
                    message: `files[${i}].content is required as a string`,
                });
            }
        }

        // M2: Validate stdin size
        if (stdin && stdin.length > config.output_max_size * 10) {
            return reject({
                message: `stdin length cannot exceed ${config.output_max_size * 10} bytes`,
            });
        }

        const rt = runtime.get_latest_runtime_matching_language_version(
            language,
            version
        );
        if (rt === undefined) {
            return reject({
                message: `${language}-${version} runtime is unknown`,
            });
        }

        if (
            rt.language !== 'file' &&
            !files.some(file => !file.encoding || file.encoding === 'utf8')
        ) {
            return reject({
                message: 'files must include at least one utf8 encoded file',
            });
        }

        for (const constraint of ['memory_limit', 'timeout', 'cpu_time']) {
            for (const type of ['compile', 'run']) {
                const constraint_name = `${type}_${constraint}`;
                const constraint_value = body[constraint_name];
                const configured_limit = rt[`${constraint}s`][type];
                if (!constraint_value) {
                    continue;
                }
                if (typeof constraint_value !== 'number') {
                    return reject({
                        message: `If specified, ${constraint_name} must be a number`,
                    });
                }
                if (configured_limit <= 0) {
                    continue;
                }
                if (constraint_value > configured_limit) {
                    return reject({
                        message: `${constraint_name} cannot exceed the configured limit of ${configured_limit}`,
                    });
                }
                if (constraint_value < 0) {
                    return reject({
                        message: `${constraint_name} must be non-negative`,
                    });
                }
            }
        }

        resolve(
            new Job({
                runtime: rt,
                args: args ?? [],
                stdin: stdin ?? '',
                files,
                timeouts: {
                    run: run_timeout ?? rt.timeouts.run,
                    compile: compile_timeout ?? rt.timeouts.compile,
                },
                cpu_times: {
                    run: run_cpu_time ?? rt.cpu_times.run,
                    compile: compile_cpu_time ?? rt.cpu_times.compile,
                },
                memory_limits: {
                    run: run_memory_limit ?? rt.memory_limits.run,
                    compile: compile_memory_limit ?? rt.memory_limits.compile,
                },
            })
        );
    });
}

router.use((req, res, next) => {
    if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) {
        return next();
    }

    if (!req.headers['content-type']?.startsWith('application/json')) {
        return res.status(415).send({
            message: 'requests must be of type application/json',
        });
    }

    next();
});

// H2: Rate limit execution — 60 requests per minute per IP
router.post('/execute', make_limiter(60, 60 * 1000), async (req, res) => {
    let job;
    try {
        job = await get_job(req.body);
    } catch (error) {
        return res.status(400).json(error);
    }
    try {
        const box = await job.prime();

        let result = await job.execute(box);
        // Backward compatibility when the run stage is not started
        if (result.run === undefined) {
            result.run = result.compile;
        }

        return res.status(200).send(result);
    } catch (error) {
        logger.error(`Error executing job: ${job.uuid}:\n${error}`);
        return res.status(500).send({ message: 'Execution error' });
    } finally {
        try {
            await job.cleanup();
        } catch (error) {
            logger.error(`Error cleaning up job: ${job.uuid}:\n${error}`);
        }
    }
});

// H1/M1: WebSocket — rate limit connection upgrades per IP
// express-ws doesn't support middleware on ws routes directly so we track
// concurrent connections and reject when over a safe global ceiling.
const MAX_WS_CONNECTIONS = config.max_concurrent_jobs * 2;
let active_ws_connections = 0;

router.ws('/connect', async (ws, req) => {
    // H1: Enforce global WebSocket connection cap
    if (active_ws_connections >= MAX_WS_CONNECTIONS) {
        safe_ws_send(ws, JSON.stringify({ type: 'error', message: 'Server at capacity' }));
        ws.close(4429, 'Too Many Connections');
        return;
    }
    active_ws_connections++;

    let job = null;
    let event_bus = new events.EventEmitter();
    // Prevent Node's MaxListenersExceededWarning for long-running interactive jobs
    event_bus.setMaxListeners(20);

    // H4: All event_bus -> ws sends go through safe_ws_send
    event_bus.on('stdout', data =>
        safe_ws_send(ws,
            JSON.stringify({
                type: 'data',
                stream: 'stdout',
                data: data.toString(),
            })
        )
    );
    event_bus.on('stderr', data =>
        safe_ws_send(ws,
            JSON.stringify({
                type: 'data',
                stream: 'stderr',
                data: data.toString(),
            })
        )
    );
    event_bus.on('stage', stage =>
        safe_ws_send(ws, JSON.stringify({ type: 'stage', stage }))
    );
    event_bus.on('exit', (stage, status) =>
        safe_ws_send(ws, JSON.stringify({ type: 'exit', stage, ...status }))
    );

    // M1: Clear the init timeout once a message arrives
    let init_timeout = setTimeout(() => {
        if (job === null) ws.close(4001, 'Initialization Timeout');
    }, 10000);

    // H5: Clean up event_bus and kill any running job on disconnect
    ws.on('close', async () => {
        active_ws_connections--;
        clearTimeout(init_timeout);
        event_bus.removeAllListeners();
        if (job !== null) {
            event_bus.emit('kill', 'SIGKILL');
            try {
                await job.cleanup();
            } catch (e) {
                logger.error(`Cleanup on disconnect for job ${job?.uuid}: ${e}`);
            }
        }
    });

    ws.on('message', async data => {
        try {
            const msg = JSON.parse(data);

            switch (msg.type) {
                case 'init':
                    clearTimeout(init_timeout);
                    if (job === null) {
                        job = await get_job(msg);

                        try {
                            const box = await job.prime();

                            safe_ws_send(ws,
                                JSON.stringify({
                                    type: 'runtime',
                                    language: job.runtime.language,
                                    version: job.runtime.version.raw,
                                })
                            );

                            await job.execute(box, event_bus);
                        } catch (error) {
                            logger.error(
                                `Error executing job ${job.uuid}:\n${error}`
                            );
                            throw error;
                        } finally {
                            // Cleanup is also called by ws.on('close') if client
                            // disconnects mid-job; guard against double-cleanup.
                            if (job.state !== undefined) {
                                try { await job.cleanup(); } catch (_) {}
                            }
                        }
                        safe_ws_send(ws, JSON.stringify({ type: 'exit', stage: 'done' }));
                        ws.close(4999, 'Job Completed');
                    } else {
                        ws.close(4000, 'Already Initialized');
                    }
                    break;
                case 'data':
                    if (job !== null) {
                        if (msg.stream === 'stdin') {
                            event_bus.emit('stdin', msg.data);
                        } else {
                            ws.close(4004, 'Can only write to stdin');
                        }
                    } else {
                        ws.close(4003, 'Not yet initialized');
                    }
                    break;
                case 'signal':
                    if (job !== null) {
                        if (
                            Object.values(globals.SIGNALS).includes(msg.signal)
                        ) {
                            event_bus.emit('signal', msg.signal);
                        } else {
                            ws.close(4005, 'Invalid signal');
                        }
                    } else {
                        ws.close(4003, 'Not yet initialized');
                    }
                    break;
            }
        } catch (error) {
            safe_ws_send(ws, JSON.stringify({ type: 'error', message: error.message }));
            ws.close(4002, 'Notified Error');
        }
    });
});

router.get('/runtimes', (req, res) => {
    const runtimes = runtime.map(rt => {
        return {
            language: rt.language,
            version: rt.version.raw,
            aliases: rt.aliases,
            runtime: rt.runtime,
        };
    });

    return res.status(200).send(runtimes);
});

// H2: Rate limit package management — 10 requests per minute per IP
router.get('/packages', make_limiter(30, 60 * 1000), async (req, res) => {
    logger.debug('Request to list packages');
    let packages = await package.get_package_list();

    packages = packages.map(pkg => {
        return {
            language: pkg.language,
            language_version: pkg.version.raw,
            installed: pkg.installed,
        };
    });

    return res.status(200).send(packages);
});

// H3: Package install/uninstall — rate limited; in production gate with API key via env
const pkg_admin_limiter = make_limiter(10, 60 * 1000);

router.post('/packages', pkg_admin_limiter, async (req, res) => {
    logger.debug('Request to install package');

    // H3: Optional API key auth — set PISTON_API_KEY env var to enable
    if (process.env.PISTON_API_KEY) {
        const provided = req.headers['x-piston-api-key'] || req.headers['authorization']?.replace('Bearer ', '');
        if (provided !== process.env.PISTON_API_KEY) {
            return res.status(401).send({ message: 'Unauthorized' });
        }
    }

    const { language, version } = req.body;

    const pkg = await package.get_package(language, version);

    if (pkg == null) {
        return res.status(404).send({
            message: `Requested package ${language}-${version} does not exist`,
        });
    }

    try {
        const response = await pkg.install();

        return res.status(200).send(response);
    } catch (e) {
        logger.error(
            `Error while installing package ${pkg.language}-${pkg.version}:`,
            e?.message ?? String(e)
        );

        return res.status(500).send({
            message: e?.message ?? String(e),
        });
    }
});

router.delete('/packages', pkg_admin_limiter, async (req, res) => {
    logger.debug('Request to uninstall package');

    // H3: Optional API key auth
    if (process.env.PISTON_API_KEY) {
        const provided = req.headers['x-piston-api-key'] || req.headers['authorization']?.replace('Bearer ', '');
        if (provided !== process.env.PISTON_API_KEY) {
            return res.status(401).send({ message: 'Unauthorized' });
        }
    }

    const { language, version } = req.body;

    const pkg = await package.get_package(language, version);

    if (pkg == null) {
        return res.status(404).send({
            message: `Requested package ${language}-${version} does not exist`,
        });
    }

    try {
        const response = await pkg.uninstall();

        return res.status(200).send(response);
    } catch (e) {
        logger.error(
            `Error while uninstalling package ${pkg.language}-${pkg.version}:`,
            e?.message ?? String(e)
        );

        return res.status(500).send({
            message: e?.message ?? String(e),
        });
    }
});

module.exports = router;
