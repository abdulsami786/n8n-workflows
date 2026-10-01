#!/bin/sh
# Runs once, on the first start of an empty Postgres volume.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d n8n -c "CREATE DATABASE leadops;"
