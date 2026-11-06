# webtrees-docker

A lean, hardened container image for [webtrees](https://webtrees.net/) built on
**nginx + php-fpm** (Alpine) instead of Apache.

- Official webtrees release zip, verified by SHA-256
- PHP 8.4 on Alpine with only the required extensions
- nginx and php-fpm run as an unprivileged user under `tini`: `www-data` by
  default, or any UID/GID via `PUID`/`PGID` or compose `user:`
- Application code is owned by a separate user, so PHP cannot modify it
- Works with a read-only root filesystem, a non-root user and all capabilities dropped
- Only `index.php` is executable. `app/`, `data/`, `vendor/`, dotfiles and
  module PHP files are never served
- Configured from `.env`: database, pretty URLs, base URL, proxies, the admin
  user and any webtrees site setting
- Extra modules can be installed with composer, either baked in at build time
  or installed at container start
- MySQL/MariaDB, PostgreSQL, SQLite and SQL Server (config only)

## Quick start

```sh
cp .env.example .env          # edit passwords, BASE_URL, ...
docker compose up -d --build
```

Open <http://localhost:8080> and log in with `WT_USER` / `WT_PASS`.

## Configuration

All options go in `.env` (see [`.env.example`](.env.example)). Any variable can
be given as `NAME_FILE=/path` to read it from a file, for example Docker secrets.

### config.ini.php

`data/config.ini.php` is regenerated from these variables on every start. If
`DB_TYPE` and `DB_HOST` are both empty, the web setup wizard runs instead.

| Variable | Default | Description |
|---|---|---|
| `DB_TYPE` | | `mysql` (or `mariadb`), `pgsql`, `sqlite`, `sqlsrv` |
| `DB_HOST` / `DB_PORT` | | Database server |
| `DB_NAME` | `webtrees` | Database name. For SQLite, the file is `data/<DB_NAME>.sqlite` |
| `DB_USER` / `DB_PASS` | | Credentials (`DB_PASSWORD` is also accepted) |
| `DB_PREFIX` | `wt_` | Table prefix |
| `DB_KEY` / `DB_CERT` / `DB_CA` / `DB_VERIFY` | | TLS to the database |
| `DB_WAIT_TIMEOUT` | `60` | Seconds to wait for the database at startup |
| `BASE_URL` | | Public URL with no trailing slash. Needed for pretty URLs |
| `PRETTY_URLS` | `false` | Use pretty URLs (`/tree/...` instead of `index.php?route=`) |
| `TRUSTED_PROXIES` | | Comma-separated proxy IPs/CIDRs |
| `TRUSTED_HEADERS` | | Forwarded headers to trust, e.g. `X-Forwarded-For` |
| `BLOCK_ASN` | | Comma-separated ASNs to block |
| `WT_DEBUG` | `false` | Debug mode |

### Administrator

`WT_USER`, `WT_NAME`, `WT_EMAIL` and `WT_PASS` (at least 8 characters) create
the first administrator. The account is only created if it doesn't exist, and
the password is never reset afterwards.

### Site settings

Any `WT_SITE_<SETTING>=value` is written to webtrees' `site_setting` table on
every start, for example `WT_SITE_TIMEZONE=Europe/London` or
`WT_SITE_LANGUAGE=en-GB`.

The image has no local `sendmail`, so configure SMTP for email:

```ini
WT_SITE_SMTP_ACTIVE=external
WT_SITE_SMTP_HOST=smtp.example.com
WT_SITE_SMTP_PORT=587
WT_SITE_SMTP_SSL=tls
WT_SITE_SMTP_AUTH=1
WT_SITE_SMTP_AUTH_USER=webtrees@example.com
WT_SITE_SMTP_AUTH_PASS=secret
```

### PHP / nginx tuning

| Variable | Default |
|---|---|
| `PHP_MEMORY_LIMIT` | `256M` |
| `PHP_MAX_EXECUTION_TIME` | `60` (nginx timeout is this value + 30s) |
| `PHP_UPLOAD_MAX_FILESIZE` / `PHP_POST_MAX_SIZE` | `64M` |
| `NGINX_CLIENT_MAX_BODY_SIZE` | `PHP_POST_MAX_SIZE` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `1` |
| `FPM_PM`, `FPM_PM_MAX_CHILDREN`, `FPM_PM_START_SERVERS`, `FPM_PM_MIN_SPARE_SERVERS`, `FPM_PM_MAX_SPARE_SERVERS`, `FPM_PM_MAX_REQUESTS` | `dynamic`, `10`, `2`, `1`, `3`, `500` |
| `NGINX_ACCESS_LOG` | `true` |

## Modules

Modules published on Packagist as `webtrees-module` packages, using
[magicsunday's installer plugin](https://github.com/magicsunday/webtrees-module-installer-plugin),
are installed into `modules_v4/` by composer. This covers most of the popular
third-party modules. Separate packages with spaces or commas, and add
`:constraint` to pin a version.

**At build time (recommended).** The image stays immutable and can run read-only.

```ini
WEBTREES_BUILD_MODULES=magicsunday/webtrees-fan-chart magicsunday/webtrees-pedigree-chart:^3.0
```

```sh
docker compose up -d --build
```

**At container start.** No rebuild is needed, but the container needs network
access at startup and can't use a read-only root filesystem.

```ini
WEBTREES_MODULES=magicsunday/webtrees-fan-chart
```

Modules are only installed when the list changes. To remove a module, take it
off the list and run `docker compose up -d --force-recreate`.

**Modules not on Packagist** (zip downloads) can be bind-mounted:

```yaml
volumes:
  - ./modules/my-module:/var/www/webtrees/modules_v4/my-module:ro
```

If a module needs another composer plugin, allow it with
`WEBTREES_COMPOSER_ALLOW_PLUGINS=vendor/plugin`. Use the build arg of the same
name for build-time installs.

## Security model

- The entrypoint starts as root only to fix volume ownership and install
  runtime modules, then drops to `PUID:PGID` (see below). Compose drops all
  capabilities except the few this needs, and sets `no-new-privileges`.
- Code in `/var/www/webtrees` belongs to `webtrees` (uid 10001) and is
  read-only to PHP. Only `data/` is writable.
- nginx hides its version and blocks access to everything except the front
  controller and static assets. webtrees sends its own security headers.

### Choosing the user (PUID/PGID or `user:`)

nginx and php-fpm run as one unprivileged user, which also owns `data/`.
There are two ways to choose it:

**`PUID` / `PGID` (default `82` / `82`, Alpine's `www-data`).** The container
starts as root, changes ownership of `data/` to this user if needed, installs
any runtime modules, then drops privileges for good. Use this to match
existing files on the host, e.g. `PUID=1000`. Numeric IDs are used directly,
so no `/etc/passwd` edits are needed and a read-only root filesystem still
works. `0` and `10001` (the code owner) are rejected.

**Compose `user:` (strictest).** The container never runs as root. Bake
modules into the image, and make sure `data/` is already owned by that user
(`chown -R 1000:1000 ./data`), since the container can't fix it:

```yaml
user: "1000:1000"
read_only: true
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
tmpfs:
  - /tmp
  - /run/webtrees
```

`PUID`/`PGID` are ignored in this mode. With the bundled compose file, also set
`WEBTREES_READ_ONLY=true` and remove `cap_add`.

## Reverse proxy

Put the container behind Traefik, Caddy, nginx or similar, and set:

```ini
BASE_URL=https://tree.example.com
TRUSTED_PROXIES=172.16.0.0/12
TRUSTED_HEADERS=X-Forwarded-For
```

`X-Forwarded-Proto: https` is forwarded to PHP as `HTTPS=on`.

## Command line

The webtrees CLI is available as `webtrees-cli`:

```sh
docker compose exec webtrees webtrees-cli list
docker compose exec webtrees webtrees-cli tree-list
docker compose exec webtrees webtrees-cli tree-import mytree /var/www/webtrees/data/family.ged
docker compose exec webtrees webtrees-cli user admin --password 'new-password'
```

## Upgrading webtrees

Build with a different version and its zip checksum. Pass an empty
`WEBTREES_SHA256` to skip the check.

```sh
docker build \
  --build-arg WEBTREES_VERSION=2.2.7 \
  --build-arg WEBTREES_SHA256=<sha256 of webtrees-2.2.7.zip> \
  -t webtrees-nginx:local .
```

Database migrations run automatically on start. Back up the `webtrees-data`
and `db-data` volumes first.

## Development

```sh
docker build --build-arg WEBTREES_MODULES=magicsunday/webtrees-pedigree-chart -t webtrees-nginx:test .
IMAGE=webtrees-nginx:test bash tests/smoke.sh
```

CI builds and smoke-tests every push. Pushes to `main` and `v*` tags publish a
multi-arch (amd64/arm64) image to `ghcr.io/vytux-com/webtrees`. The package is
private by default and can be made public under the package settings on GitHub.

## License

The webtrees application is GPL-3.0-or-later. The files in this repository are
provided under the same license.
