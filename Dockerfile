# syntax=docker/dockerfile:1.7

ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.22

###############################################################################
# Stage 1: download and verify the official webtrees release
###############################################################################
FROM alpine:${ALPINE_VERSION} AS source

ARG WEBTREES_VERSION=2.2.6
# SHA-256 of webtrees-${WEBTREES_VERSION}.zip. Set to "" to skip verification
# when building a different version.
ARG WEBTREES_SHA256=c6b82f0269733b71de1a160a93eb32029e3467674e9bbfe3956d46a8bb04f925

RUN apk add --no-cache curl unzip

WORKDIR /src
RUN set -eux; \
    curl -fsSL -o webtrees.zip \
      "https://github.com/fisharebest/webtrees/releases/download/${WEBTREES_VERSION}/webtrees-${WEBTREES_VERSION}.zip"; \
    if [ -n "${WEBTREES_SHA256}" ]; then echo "${WEBTREES_SHA256}  webtrees.zip" | sha256sum -c -; fi; \
    unzip -q webtrees.zip; \
    rm webtrees.zip; \
    # The release zip ships vendor/ but not composer.json/lock. Add them (from the
    # same tag) so composer can add modules on top of the exact locked versions.
    curl -fsSL -o webtrees/composer.json \
      "https://raw.githubusercontent.com/fisharebest/webtrees/${WEBTREES_VERSION}/composer.json"; \
    curl -fsSL -o webtrees/composer.lock \
      "https://raw.githubusercontent.com/fisharebest/webtrees/${WEBTREES_VERSION}/composer.lock"; \
    # Apache-only files are irrelevant with nginx.
    find webtrees -name .htaccess -delete

###############################################################################
# Stage 2: runtime image
###############################################################################
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION}

ARG WEBTREES_VERSION=2.2.6
# Space/comma/newline separated composer packages baked into the image, e.g.
# "magicsunday/webtrees-fan-chart:^3.0 magicsunday/webtrees-descendants-chart"
ARG WEBTREES_MODULES=""
ARG WEBTREES_COMPOSER_ALLOW_PLUGINS=""
ARG PHP_EXTENSION_INSTALLER_VERSION=2.13.2

LABEL org.opencontainers.image.title="webtrees" \
      org.opencontainers.image.description="Lean nginx + php-fpm image for webtrees" \
      org.opencontainers.image.version="${WEBTREES_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/vytux-com/webtrees-docker"

ENV WEBTREES_VERSION=${WEBTREES_VERSION} \
    WEBTREES_HOME=/var/www/webtrees \
    COMPOSER_HOME=/var/cache/composer \
    COMPOSER_CACHE_DIR=/var/cache/composer/cache \
    COMPOSER_NO_INTERACTION=1 \
    COMPOSER_ALLOW_SUPERUSER=0 \
    # PHP / FPM tunables (read via ${VAR} in the ini/pool files)
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=60 \
    PHP_UPLOAD_MAX_FILESIZE=64M \
    PHP_POST_MAX_SIZE=64M \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    FPM_PM=dynamic \
    FPM_PM_MAX_CHILDREN=10 \
    FPM_PM_START_SERVERS=2 \
    FPM_PM_MIN_SPARE_SERVERS=1 \
    FPM_PM_MAX_SPARE_SERVERS=3 \
    FPM_PM_MAX_REQUESTS=500 \
    FPM_ERROR_LOG=/run/webtrees/php-fpm.log

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ADD --chmod=0755 \
    https://github.com/mlocati/docker-php-extension-installer/releases/download/${PHP_EXTENSION_INSTALLER_VERSION}/install-php-extensions \
    /usr/local/bin/install-php-extensions

RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache nginx tini su-exec; \
    # pdo_sqlite, mbstring, curl, iconv, ctype, dom, xml, session, fileinfo
    # are already compiled into the official image.
    install-php-extensions gd intl zip exif opcache pdo_mysql pdo_pgsql; \
    rm /usr/local/bin/install-php-extensions; \
    # Replace the stock FPM pools (which listen on TCP :9000) with our own.
    rm -f /usr/local/etc/php-fpm.d/*.conf; \
    mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    # Remove the stock nginx configuration; ours lives in /etc/nginx/nginx.conf.
    rm -rf /etc/nginx/http.d /etc/nginx/conf.d /var/www/localhost; \
    # Unprivileged owner of the application code. The runtime user (PUID,
    # default www-data) can read, but not modify, the code. Deliberately not
    # 1000, the usual first user on a host.
    addgroup -S -g 10001 webtrees; \
    adduser -S -D -H -u 10001 -G webtrees -h /var/cache/composer -s /sbin/nologin webtrees; \
    mkdir -p /var/cache/composer /run/webtrees; \
    chown webtrees:webtrees /var/cache/composer

COPY --from=source --chown=webtrees:webtrees /src/webtrees ${WEBTREES_HOME}
COPY --chmod=0755 rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/usr/local/lib/webtrees-docker/ /usr/local/lib/webtrees-docker/
COPY rootfs/usr/local/etc/ /usr/local/etc/
COPY rootfs/etc/nginx/ /etc/nginx/

RUN set -eux; \
    chown -R www-data:www-data "${WEBTREES_HOME}/data"; \
    chmod 0750 "${WEBTREES_HOME}/data"; \
    if [ -n "${WEBTREES_MODULES}" ]; then \
      su-exec webtrees webtrees-install-modules ${WEBTREES_MODULES}; \
      rm -rf /var/cache/composer/cache; \
    fi; \
    # Sanity checks, validated as an arbitrary unprivileged uid (logging to
    # /dev/null, as the log FIFOs only exist at runtime).
    NGINX_ACCESS_LOG=false webtrees-render-config; \
    php -r 'foreach (["gd","intl","zip","exif","pdo_mysql","pdo_pgsql","pdo_sqlite","sqlite3","Zend OPcache"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "missing extension $e\n"); exit(1); } }'; \
    chown -R 12345:12345 /run/webtrees /tmp/nginx; \
    FPM_ERROR_LOG=/dev/null su-exec 12345:12345 php-fpm -t; \
    su-exec 12345:12345 nginx -e stderr -t; \
    rm -rf /run/webtrees/* /tmp/nginx; \
    # Writable by any uid (sticky, like /tmp), for `user:` with an arbitrary uid.
    chown root:root /run/webtrees; \
    chmod 1777 /run/webtrees

WORKDIR ${WEBTREES_HOME}
VOLUME ["${WEBTREES_HOME}/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint"]
CMD ["webtrees"]
