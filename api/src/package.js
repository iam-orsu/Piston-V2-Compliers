const logger = require('logplease').create('package');
const semver = require('semver');
const config = require('./config');
const globals = require('./globals');
const path = require('path');
const fs = require('fs/promises');
const fss = require('fs');

// Air-gap mode: package management is entirely local.
// POST /packages and DELETE /packages are permanently blocked (return 403).
// GET /packages reads from the pre-baked packages directory on disk —
// no remote index, no outbound HTTP calls, no node-fetch.

class Package {
    constructor({ language, version }) {
        this.language = language;
        this.version = semver.parse(version);
    }

    get installed() {
        return fss.exists_sync(
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
}

module.exports = Package;
