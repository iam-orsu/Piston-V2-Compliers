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
const crypto = require('crypto');

const REPO_URL = 'https://github.com/engineer-man/piston/releases/download/pkgs';

// Fetch a URL as a string, following redirects.
// Hard cap of 10 hops prevents infinite-redirect loops from a compromised registry.
function fetch_text(url) {
    return new Promise((resolve, reject) => {
        const follow = (u, hops = 0) => {
            if (hops > 10) return reject(new Error(`Too many redirects fetching ${url}`));
            const lib = u.startsWith('https') ? https : http;
            lib.get(u, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    return follow(res.headers.location, hops + 1);
                }
                if (res.statusCode !== 200) {
                    return reject(new Error(`HTTP ${res.statusCode} fetching ${u}`));
                }
                const chunks = [];
                res.on('data', chunk => { chunks.push(chunk); });
                res.on('end', () => resolve(Buffer.concat(chunks).toString()));
                res.on('error', reject);
            }).on('error', reject);
        };
        follow(url);
    });
}

// Download a URL to a local file path, following redirects.
function download_file(url, dest) {
    return new Promise((resolve, reject) => {
        const follow = (u, hops = 0) => {
            if (hops > 10) return reject(new Error(`Too many redirects downloading ${url}`));
            const lib = u.startsWith('https') ? https : http;
            lib.get(u, (res) => {
                if (res.statusCode === 301 || res.statusCode === 302) {
                    return follow(res.headers.location, hops + 1);
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

// exec wrapped as a promise — kept for env diffing where shell is intentional.
function exec_promise(cmd, opts = {}) {
    return new Promise((resolve, reject) => {
        cp.exec(cmd, { timeout: 300000, ...opts }, (err, stdout, stderr) => {
            if (err) reject(new Error(`Command failed: ${cmd}\n${stderr}`));
            else resolve(stdout);
        });
    });
}

// Shell-safe exec using execFile — use this instead of exec_promise whenever
// arguments come from untrusted or user-controlled data (paths, versions, etc.).
// No shell is spawned, so metacharacters in arguments cannot cause injection.
function exec_file_promise(file, args, opts = {}) {
    return new Promise((resolve, reject) => {
        cp.execFile(file, args, { timeout: 300000, ...opts }, (err, stdout, stderr) => {
            if (err) reject(new Error(`Command failed: ${file}\n${stderr}`));
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

        // Fetch the CSV package index from the registry.
        // Format per line: language,version,sha256,download_url
        const index_text = await fetch_text(`${REPO_URL}/index`);
        const index = index_text.trim().split('\n')
            .filter(l => l.trim())
            .map(line => {
                const [language, version, sha256, url] = line.split(',');
                return { language, version, sha256: (sha256 || '').trim(), url };
            });

        // Find matching entry — exact version match
        const entry = index.find(
            p => p.language === this.language && p.version === this.version.raw
        );
        if (!entry) {
            throw new Error(
                `Package ${this.language}-${this.version.raw} not found in registry`
            );
        }

        // Download the tarball using the URL from the index
        const tarball_name = `${entry.language}-${entry.version}.pkg.tar.gz`;
        const tmp_path = `/tmp/${tarball_name}`;
        logger.info(`Downloading ${tarball_name}...`);
        await download_file(entry.url, tmp_path);

        // Verify SHA256 integrity before extracting.
        // Stream the file through the hash rather than loading it into RAM —
        // Java/Rust tarballs can be 400–500 MB, and buffering all of that would
        // spike resident memory by that amount on every install.
        if (entry.sha256 && entry.sha256.length === 64) {
            const actual = await new Promise((resolve, reject) => {
                const hash = crypto.createHash('sha256');
                const stream = fss.createReadStream(tmp_path);
                stream.on('data', d => hash.update(d));
                stream.on('end', () => resolve(hash.digest('hex')));
                stream.on('error', reject);
            });
            if (actual !== entry.sha256) {
                await fs.unlink(tmp_path).catch(() => {});
                throw new Error(
                    `SHA256 mismatch for ${tarball_name}: expected ${entry.sha256}, got ${actual}`
                );
            }
            logger.info(`SHA256 verified for ${tarball_name}`);
        } else {
            logger.warn(`No SHA256 in registry for ${tarball_name} — skipping integrity check`);
        }

        // Create install directory and extract.
        // Use execFile (not exec) so spaces or special characters in the path
        // cannot be interpreted as shell metacharacters.
        await fs.mkdir(this.install_path, { recursive: true });
        await exec_file_promise('tar', ['-xzf', tmp_path, '-C', this.install_path]);

        // Clean up tarball
        await fs.unlink(tmp_path).catch(() => {});

        // Run the build script if the package includes one.
        // execFile avoids shell interpretation of the absolute path.
        const build_script = path.join(this.install_path, 'build');
        if (fss.existsSync(build_script)) {
            logger.info(`Running build script for ${this.language}-${this.version.raw}`);
            await fs.chmod(build_script, 0o755);
            await exec_file_promise(build_script, [], { cwd: this.install_path });
        }

        // Generate .env from the 'environment' bash script so runtime.js can
        // read PATH/LD_LIBRARY_PATH without shelling out at execution time.
        // We source with cwd=install_path so $PWD resolves to the package dir.
        const env_script_path = path.join(this.install_path, 'environment');
        if (fss.existsSync(env_script_path)) {
            try {
                const to_map = s => {
                    const m = new Map();
                    s.split('\n').filter(Boolean).forEach(line => {
                        const idx = line.indexOf('=');
                        if (idx > 0) m.set(line.slice(0, idx), line.slice(idx + 1));
                    });
                    return m;
                };
                const base = to_map(await exec_promise('env'));
                const sourced = to_map(
                    await exec_promise(`bash -c 'source ./environment 2>/dev/null; env'`,
                        { cwd: this.install_path })
                );
                const env_lines = [];
                for (const [k, v] of sourced) {
                    if (base.get(k) !== v) env_lines.push(`${k}=${v}`);
                }
                if (env_lines.length > 0) {
                    await fs.writeFile(
                        path.join(this.install_path, '.env'),
                        env_lines.join('\n') + '\n'
                    );
                }
            } catch (_) { /* skip if environment script can't be sourced */ }
        }

        // Mark as installed
        await fs.writeFile(path.join(this.install_path, globals.pkg_installed_file), '');

        logger.info(`Installed ${this.language}-${this.version.raw}`);
        return { language: this.language, version: this.version.raw };
    }

    // Enumerate all packages from the local packages directory.
    // Reads pkg-info.json from every language/version subdirectory in parallel.
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

        // Read all language dirs in parallel, then all version dirs in parallel
        const per_lang = await Promise.all(
            lang_dirs.map(async lang => {
                let version_dirs;
                try {
                    version_dirs = await fs.readdir(path.join(pkgdir, lang));
                } catch (_) {
                    return [];
                }

                return Promise.all(
                    version_dirs.map(async ver => {
                        const info_path = path.join(pkgdir, lang, ver, 'pkg-info.json');
                        try {
                            const info = JSON.parse(await fs.readFile(info_path, 'utf8'));
                            const pkg = new Package({
                                language: info.language,
                                version: info.version,
                            });
                            // A corrupt or hand-edited pkg-info.json with an invalid
                            // semver version would yield pkg.version === null, which
                            // would crash pkg.version.raw in the caller. Drop it here.
                            return pkg.version !== null ? pkg : null;
                        } catch (_) {
                            return null; // skip dirs without a valid pkg-info.json
                        }
                    })
                );
            })
        );

        return per_lang.flat().filter(Boolean);
    }

    // Fetch all available packages from the remote registry.
    static async get_package_list_remote() {
        const index_text = await fetch_text(`${REPO_URL}/index`);
        return index_text.trim().split('\n')
            .filter(l => l.trim())
            .map(line => {
                const [language, version] = line.split(',');
                return new Package({ language, version });
            });
    }
}

module.exports = Package;
