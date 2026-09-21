#!/usr/bin/env node
require('nocamel');
const Logger = require('logplease');
const express = require('express');
const expressWs = require('express-ws');
const globals = require('./globals');
const config = require('./config');
const path = require('path');
const fs = require('fs/promises');
const fss = require('fs');
const body_parser = require('body-parser');
const runtime = require('./runtime');

const logger = Logger.create('index');
const app = express();
expressWs(app);

// C1: Global crash handlers — prevent a single error from killing all users' sessions
process.on('unhandledRejection', (reason) => {
    logger.error('Unhandled Promise Rejection:', reason);
});

process.on('uncaughtException', (err) => {
    logger.error('Uncaught Exception — shutting down gracefully:', err);
    // Give in-flight requests up to 5s to drain, then exit
    server_ref?.close(() => process.exit(1));
    setTimeout(() => process.exit(1), 5000).unref();
});

let server_ref = null;

(async () => {
    logger.info('Setting loglevel to', config.log_level);
    Logger.setLogLevel(config.log_level);
    logger.debug('Ensuring data directories exist');

    Object.values(globals.data_directories).for_each(dir => {
        let data_path = path.join(config.data_directory, dir);

        logger.debug(`Ensuring ${data_path} exists`);

        if (!fss.exists_sync(data_path)) {
            logger.info(`${data_path} does not exist.. Creating..`);

            try {
                fss.mkdir_sync(data_path);
            } catch (e) {
                logger.error(`Failed to create ${data_path}: `, e.message);
            }
        }
    });

    logger.info('Loading packages');
    const pkgdir = path.join(
        config.data_directory,
        globals.data_directories.packages
    );

    const pkglist = await fs.readdir(pkgdir);

    const languages = await Promise.all(
        pkglist.map(lang => {
            return fs.readdir(path.join(pkgdir, lang)).then(x => {
                return x.map(y => path.join(pkgdir, lang, y));
            });
        })
    );

    const installed_languages = languages
        .flat()
        .filter(pkg =>
            fss.exists_sync(path.join(pkg, globals.pkg_installed_file))
        );

    installed_languages.for_each(pkg => runtime.load_package(pkg));

    logger.info('Starting API Server');
    logger.debug('Constructing Express App');
    logger.debug('Registering middleware');

    // C5: Explicit body size limits — prevent OOM bomb via large request bodies
    app.use(body_parser.urlencoded({ extended: true, limit: '1mb' }));
    app.use(body_parser.json({ limit: '1mb' }));

    logger.debug('Registering Routes');

    const api_v2 = require('./api/v2');
    app.use('/api/v2', api_v2);

    const { version } = require('../package.json');

    app.get('/', (req, res, next) => {
        return res.status(200).send({ message: `Piston v${version}` });
    });

    app.use((req, res, next) => {
        return res.status(404).send({ message: 'Not Found' });
    });

    // C6: Error handler AFTER routes, no stack leak to client
    app.use((err, req, res, next) => {
        logger.error('Unhandled route error:', err);
        return res.status(500).send({ message: 'Internal Server Error' });
    });

    logger.debug('Calling app.listen');
    const [address, port] = config.bind_address.split(':');

    const server = app.listen(port, address, () => {
        logger.info('API server started on', config.bind_address);
    });

    server_ref = server;

    // M7: HTTP timeouts — prevent slow clients from holding connections indefinitely
    server.setTimeout(30000);
    server.keepAliveTimeout = 65000;
    server.headersTimeout = 66000;

    process.on('SIGTERM', () => {
        server.close();
        process.exit(0);
    });
})();
