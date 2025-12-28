#!/usr/bin/env bash
set -e

# Setup test database for Chosen tests
# Assumes PostgreSQL is running on localhost:5432 with postgres/postgres credentials

DB_NAME="chosen_test"
DB_USER="postgres"
DB_PASS="postgres"
DB_HOST="localhost"
DB_PORT="5432"

echo "Setting up test database: $DB_NAME"

# Drop database if it exists
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -c "DROP DATABASE IF EXISTS $DB_NAME;" postgres

# Create database
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -c "CREATE DATABASE $DB_NAME;" postgres

echo "✓ Test database '$DB_NAME' created successfully"
