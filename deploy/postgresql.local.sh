#!/bin/bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
    CREATE USER networthjwt WITH PASSWORD 'networthjwt';
    CREATE DATABASE networthjwt OWNER networthjwt;

    CREATE USER networthdb WITH PASSWORD 'networthdb';
    CREATE DATABASE networthdb OWNER networthdb;

    CREATE USER networthsync WITH PASSWORD 'networthsync';
    CREATE DATABASE networthsync OWNER networthsync;
EOSQL
