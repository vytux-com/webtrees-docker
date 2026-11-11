<?php

/**
 * Configure webtrees from environment variables (runs at container start).
 *
 * - writes data/config.ini.php (environment is the source of truth)
 * - waits for the database, creates/updates the schema
 * - creates the initial administrator account
 * - applies WT_SITE_* site settings
 *
 * If no DB_TYPE/DB_HOST is set, nothing is done and the normal webtrees setup
 * wizard runs on first visit.
 */

declare(strict_types=1);

use Fisharebest\Webtrees\Contracts\UserInterface;
use Fisharebest\Webtrees\DB;
use Fisharebest\Webtrees\I18N;
use Fisharebest\Webtrees\Registry;
use Fisharebest\Webtrees\Services\MigrationService;
use Fisharebest\Webtrees\Services\UserService;
use Fisharebest\Webtrees\Site;
use Fisharebest\Webtrees\Webtrees;

require (getenv('WEBTREES_HOME') ?: '/var/www/webtrees') . '/vendor/autoload.php';

function info(string $message): void
{
    fwrite(STDERR, '[webtrees] ' . $message . PHP_EOL);
}

function fail(string $message): never
{
    info('ERROR: ' . $message);
    exit(1);
}

/** Read NAME, or the contents of the file named by NAME_FILE (Docker secrets). */
function env(string $name, string $default = ''): string
{
    $file = getenv($name . '_FILE');

    if (is_string($file) && $file !== '') {
        $value = @file_get_contents($file);

        if ($value === false) {
            fail($name . '_FILE: cannot read ' . $file);
        }

        return rtrim($value, "\r\n");
    }

    $value = getenv($name);

    return is_string($value) && $value !== '' ? $value : $default;
}

function flag(string $name, bool $default): bool
{
    $value = strtolower(trim(env($name)));

    if ($value === '') {
        return $default;
    }

    return in_array($value, ['1', 'true', 'yes', 'on'], true);
}

// ---------------------------------------------------------------------------
// 1. data/config.ini.php
// ---------------------------------------------------------------------------

$db_type = strtolower(env('DB_TYPE'));

if ($db_type === '' && env('DB_HOST') === '') {
    if (file_exists(Webtrees::CONFIG_FILE)) {
        info('DB_TYPE/DB_HOST not set; using existing data/config.ini.php');
    } else {
        info('DB_TYPE/DB_HOST not set; the setup wizard will run on first visit');
    }

    exit(0);
}

$db_type = match ($db_type) {
    '', 'mysql', 'mariadb'                => DB::MYSQL,
    'pgsql', 'postgres', 'postgresql'     => DB::POSTGRESQL,
    'sqlite', 'sqlite3'                   => DB::SQLITE,
    'sqlsrv', 'mssql', 'sqlserver'        => DB::SQL_SERVER,
    default                               => fail('unsupported DB_TYPE "' . $db_type . '"'),
};

$default_ports = [DB::MYSQL => '3306', DB::POSTGRESQL => '5432', DB::SQL_SERVER => '1433', DB::SQLITE => ''];

$config = [
    'dbtype'       => $db_type,
    'dbhost'       => $db_type === DB::SQLITE ? '' : env('DB_HOST'),
    'dbport'       => $db_type === DB::SQLITE ? '' : env('DB_PORT', $default_ports[$db_type]),
    'dbuser'       => env('DB_USER'),
    'dbpass'       => env('DB_PASS', env('DB_PASSWORD')),
    'dbname'       => env('DB_NAME', 'webtrees'),
    'tblpfx'       => env('DB_PREFIX', 'wt_'),
    'dbkey'        => env('DB_KEY'),
    'dbcert'       => env('DB_CERT'),
    'dbca'         => env('DB_CA'),
    'dbverify'     => flag('DB_VERIFY', false) ? '1' : '0',
    'base_url'     => rtrim(env('BASE_URL'), '/'),
    'rewrite_urls' => flag('PRETTY_URLS', false) ? '1' : '0',
];

// Optional keys: webtrees treats "present but empty" differently from "absent".
$optional = [
    'block_asn'       => env('BLOCK_ASN'),
    'trusted_proxies' => env('TRUSTED_PROXIES'),
    'trusted_headers' => env('TRUSTED_HEADERS'),
    'debug'           => flag('WT_DEBUG', false) ? '1' : '',
];
$config += array_filter($optional, static fn (string $value): bool => $value !== '');

if ($db_type !== DB::SQLITE && $config['dbhost'] === '') {
    fail('DB_HOST is required for DB_TYPE=' . $db_type);
}

if ($config['base_url'] === '') {
    info('WARNING: BASE_URL is not set; it will be guessed from each request');
    if ($config['rewrite_urls'] === '1') {
        info('WARNING: PRETTY_URLS requires BASE_URL to be set');
    }
}

$ini = '; <?php return; ?> DO NOT DELETE THIS LINE' . PHP_EOL;
foreach ($config as $key => $value) {
    if (str_contains($value, "\n") || str_contains($value, "\r")) {
        fail('configuration value for "' . $key . '" contains a newline');
    }
    $ini .= $key . '="' . addcslashes($value, '"') . '"' . PHP_EOL;
}

$tmp = Webtrees::CONFIG_FILE . '.tmp';
if (file_put_contents($tmp, $ini) === false || !chmod($tmp, 0640) || !rename($tmp, Webtrees::CONFIG_FILE)) {
    fail('cannot write ' . Webtrees::CONFIG_FILE);
}

$check = parse_ini_file(Webtrees::CONFIG_FILE);
if ($check === false || ($check['dbpass'] ?? null) !== $config['dbpass']) {
    fail('data/config.ini.php does not round-trip; avoid "${" and trailing "\\" in values');
}

info('wrote data/config.ini.php (' . $db_type . ', base_url=' . ($config['base_url'] ?: 'auto') . ', pretty_urls=' . $config['rewrite_urls'] . ')');

// ---------------------------------------------------------------------------
// 2. Database connection + schema
// ---------------------------------------------------------------------------

Webtrees::new()->bootstrap();
I18N::init(code: 'en-US', setup: true);

$deadline = time() + (int) env('DB_WAIT_TIMEOUT', '60');

// Like the setup wizard: the SQLite connector requires an existing file.
if ($config['dbtype'] === DB::SQLITE && $config['dbname'] !== ':memory:') {
    $sqlite_file = Webtrees::ROOT_DIR . 'data/' . $config['dbname'] . '.sqlite';
    if (!file_exists($sqlite_file) && !touch($sqlite_file)) {
        fail('cannot create ' . $sqlite_file);
    }
}

while (true) {
    try {
        DB::connect(
            driver: $config['dbtype'],
            host: $config['dbhost'],
            port: $config['dbport'],
            database: $config['dbname'],
            username: $config['dbuser'],
            password: $config['dbpass'],
            prefix: $config['tblpfx'],
            key: $config['dbkey'],
            certificate: $config['dbcert'],
            ca: $config['dbca'],
            verify_certificate: $config['dbverify'] === '1',
        );
        DB::connection()->getPdo();
        break;
    } catch (Throwable $ex) {
        if (time() >= $deadline) {
            fail('cannot connect to the database: ' . $ex->getMessage());
        }
        info('waiting for database: ' . $ex->getMessage());
        sleep(2);
    }
}

$fresh_install = !DB::schema()->hasTable('site_setting');

$migration_service = Registry::container()->get(MigrationService::class);
$migration_service->updateSchema('\Fisharebest\Webtrees\Schema', 'WT_SCHEMA_VERSION', Webtrees::SCHEMA_VERSION);

if ($fresh_install) {
    $migration_service->seedDatabase();
    info('created database tables');
} else {
    info('database schema is up to date');
}

// ---------------------------------------------------------------------------
// 3. Initial administrator
// ---------------------------------------------------------------------------

$user_service = Registry::container()->get(UserService::class);

$wt_user  = env('WT_USER');
$wt_pass  = env('WT_PASS');
$wt_email = env('WT_EMAIL');
$wt_name  = env('WT_NAME', $wt_user);

if ($wt_user !== '' && $wt_pass !== '' && $wt_email !== '') {
    $admin = $user_service->findByUserName($wt_user) ?? $user_service->findByEmail($wt_email);

    if ($admin === null) {
        if (mb_strlen($wt_pass) < 8) {
            fail('WT_PASS must be at least 8 characters');
        }

        $admin = $user_service->create($wt_user, $wt_name, $wt_email, $wt_pass);
        $admin->setPreference(UserInterface::PREF_LANGUAGE, env('WT_SITE_LANGUAGE', 'en-US'));
        $admin->setPreference(UserInterface::PREF_IS_VISIBLE_ONLINE, '1');
        $admin->setPreference(UserInterface::PREF_IS_ADMINISTRATOR, '1');
        $admin->setPreference(UserInterface::PREF_IS_EMAIL_VERIFIED, '1');
        $admin->setPreference(UserInterface::PREF_IS_ACCOUNT_APPROVED, '1');
        info('created administrator "' . $wt_user . '"');
    } else {
        info('administrator "' . $admin->userName() . '" already exists (WT_PASS is only used on first creation)');
    }
} elseif ($user_service->administrators()->isEmpty()) {
    info('WARNING: no administrator account exists. Set WT_USER, WT_PASS and WT_EMAIL');
    info('         (or run: webtrees-cli user --create ... and set canadmin=1).');
}

// ---------------------------------------------------------------------------
// 4. Site settings: WT_SITE_<SETTING>=value (or WT_SITE_<SETTING>_FILE=path)
// ---------------------------------------------------------------------------

foreach (array_keys(getenv()) as $name) {
    if (!str_starts_with($name, 'WT_SITE_')) {
        continue;
    }

    $setting = substr($name, strlen('WT_SITE_'));

    if (str_ends_with($setting, '_FILE')) {
        $setting = substr($setting, 0, -strlen('_FILE'));
        $name    = substr($name, 0, -strlen('_FILE'));
    }

    if ($setting === '') {
        continue;
    }

    Site::setPreference($setting, env($name));
    info('site setting ' . $setting . ' applied');
}
