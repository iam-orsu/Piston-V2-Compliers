const logger = require('logplease').create('package');
const semver = require('semver');
const config = require('./config');
const globals = require('./globals');
const path = require('path');
const fs = require('fs/promises');
const fss = require('fs');
const https = require('https');
const http = require('http');
const cp = require('child_process');

const REPO_URL = 'https://github.com/engineer-man/piston/releases/download/pkgs';

// Fetch a URL as a string, following redirects.
function fetch_text(url) {
    return new Promise((resolve, reject) => {
        const follow = (u) => {
            const lib = u.startsWith('https') ? https : http;
            lib.get(u, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    return follow(res.headers.location);
                }
                if (res.statusCode !== 200) {
                    return reject(new Error(`HTTP ${res.statusCode} fetching ${u}`));
                }
                let data = '';
                res.on('data', chunk => { data += chunk; });
                res.on('end', () => resolve(data));
                res.on('error', reject);
            }).on('error', reject);
        };
        follow(url);
    });
}

// Download a URL to a local file path, following redirects.
function download_file(url, dest) {
    return new Promise((resolve, reject) => {
        const follow = (u) => {
            const lib = u.startsWith('https') ? https : http;
            lib.get(u, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    return follow(res.headers.location);
                }
                if (res.statusCode !== 200) {
                    return reject(new Error(`HTTP ${res.statusCode} downloading ${u}`));
                }
                const ws = fss.createWriteStream(dest);
                res.pipe(ws);
                ws.on('finish', resolve);
                ws.on('error', reject);
                res.on('error', reject);
            }).on('error', reject);
        };
        follow(url);
    });
}

// exec wrapped as a promise
function exec_promise(cmd, opts = {}) {
    return new Promise((resolve, reject) => {
        cp.exec(cmd, { timeout: 300000, ...opts }, (err, stdout, stderr) => {
            if (err) reject(new Error(`Command failed: ${cmd}\n${stderr}`));
            else resolve(stdout);
        });
    });
}

class Package {
    constructor({ language, version }) {
        this.language = language;
        this.version = semver.parse(version);
    }

    get installed() {
        return fss.existsSync(
            path.join(this.install_path, globals.pkg_installed_file)
        );
    }

    get install_path() {
        return path.join(
            config.data_directory,
            globals.data_directories.packages,
            this.language,
            this.version.raw
        );
    }

    async install() {
        if (this.installed) {
            return { language: this.language, version: this.version.raw };
        }

        logger.info(`Installing ${this.language}-${this.version.raw}`);

        // Fetch the NDJSON package index from the registry
        const index_text = await fetch_text(`${REPO_URL}/index`);
        const index = index_text.trim().split('\n').map(line => JSON.parse(line));

        // Find matching entry — exact version match
        const entry = index.find(
            p => p.language === this.language && p.language_version === this.version.raw
        );
        if (!entry) {
            throw new Error(
                `Package ${this.language}-${this.version.raw} not found in registry`
            );
        }

        // Download the tarball
        const tarball_name = `${entry.language}-${entry.language_version}.tar.gz`;
        const tmp_path = `/tmp/${tarball_name}`;
        logger.info(`Downloading ${tarball_name}...`);
        await download_file(`${REPO_URL}/${tarball_name}`, tmp_path);

        // Create install directory and extract
        await fs.mkdir(this.install_path, { recursive: true });
        await exec_promise(`tar -xzf ${tmp_path} -C ${this.install_path}`);

        // Clean up tarball
        await fs.unlink(tmp_path).catch(() => {});

        // Run the build script if the package includes one
        const build_script = path.join(this.install_path, 'build');
        if (fss.existsSync(build_script)) {
            logger.info(`Running build script for ${this.language}-${this.version.raw}`);
            await fs.chmod(build_script, 0o755);
            await exec_promise(build_script, { cwd: this.install_path });
        }

        // Mark as installed
        await fs.writeFile(path.join(this.install_path, globals.pkg_installed_file), '');

        logger.info(`Installed ${this.language}-${this.version.raw}`);
        return { language: this.language, version: this.version.raw };
    }

    // Enumerate all packages from the local packages directory.
    // Reads pkg-info.json from every language/version subdirectory.
    static async get_package_list() {
        const pkgdir = path.join(
            config.data_directory,
            globals.data_directories.packages
        );

        let lang_dirs;
        try {
            lang_dirs = await fs.readdir(pkgdir);
        } catch (_) {
            return [];
        }

        const packages = [];

        for (const lang of lang_dirs) {
            let version_dirs;
            try {
                version_dirs = await fs.readdir(path.join(pkgdir, lang));
            } catch (_) {
                continue;
            }

            for (const ver of version_dirs) {
                const pkg_dir = path.join(pkgdir, lang, ver);
                const info_path = path.join(pkg_dir, 'pkg-info.json');
                try {
                    const info = JSON.parse(
                        await fs.readFile(info_path, 'utf8')
                    );
                    packages.push(
                        new Package({
                            language: info.language,
                            version: info.version,
                        })
                    );
                } catch (_) {
                    // skip directories without a valid pkg-info.json
                }
            }
        }

        return packages;
    }

    // Fetch all available packages from the remote registry.
    static async get_package_list_remote() {
        const index_text = await fetch_text(`${REPO_URL}/index`);
        return index_text.trim().split('\n').map(line => {
            const p = JSON.parse(line);
            return new Package({ language: p.language, version: p.language_version });
        });
    }
}

module.exports = Package;
