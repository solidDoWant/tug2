# Database Migrator Plugin

A SourceMod plugin that automatically applies SQL migration scripts to PostgreSQL databases when the plugin loads.

## Overview

The Database Migrator plugin provides a simple, automated way to manage database schema migrations for SourceMod servers. It reads migration scripts from configuration, connects to specified databases, and executes SQL files in a transactional manner.

## Features

- **Automatic Execution**: Migrations run automatically when the plugin loads
- **Transaction Safety**: Each migration file is wrapped in a transaction (BEGIN...COMMIT)
- **Error Resilience**: If one migration fails, others continue to execute
- **Multiple Databases**: Support for migrating multiple databases in one run
- **Comprehensive Logging**: Detailed logs of all migration attempts and results
- **PostgreSQL Support**: Designed specifically for PostgreSQL databases

## Installation

1. Compile the plugin:
   ```bash
   spcomp -i /opt/sourcemod/addons/sourcemod/scripting/include/ \
          -i /workspaces/tug2/plugins/sourcemod/scripting/include/ \
          /workspaces/tug2/plugins/sourcemod/scripting/DatabaseMigrator.sp
   ```

2. Copy the compiled `DatabaseMigrator.smx` to `addons/sourcemod/plugins/`

3. Configure your migration scripts (see Configuration below)

4. Restart the server or load the plugin with `sm plugins load DatabaseMigrator`

## Configuration

### Migration Configuration File

Create or edit `addons/sourcemod/configs/database-migrations.cfg`:

```
"Migrations"
{
    "database_name"
    {
        "1"  "configs/sql-init-scripts/pgsql/schema.sql"
        "2"  "configs/sql-init-scripts/pgsql/indexes.sql"
        "3"  "configs/sql-init-scripts/pgsql/seed_data.sql"
    }
    
    "another_database"
    {
        "1"  "configs/sql-init-scripts/pgsql/other_schema.sql"
    }
}
```

**Configuration Notes:**
- Database names must match entries in `addons/sourcemod/configs/databases.cfg`
- File paths are relative to the `addons/sourcemod/` directory
- Numbered keys (1, 2, 3...) help maintain execution order
- Migrations execute in the order they appear in the config

### Database Connection Configuration

Ensure your databases are properly configured in `addons/sourcemod/configs/databases.cfg`:

```
"Databases"
{
    "loadoutsaver"
    {
        "driver"   "pgsql"
        "host"     "localhost"
        "database" "insurgency"
        "user"     "gameserver"
        "pass"     "your_password"
        "port"     "5432"
    }
}
```

## SQL Migration Files

### Best Practices

1. **Use Idempotent Commands**: Use `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, etc.
   ```sql
   CREATE TABLE IF NOT EXISTS users (
       id SERIAL PRIMARY KEY,
       username VARCHAR(64) NOT NULL
   );
   ```

2. **Include Comments**: Document what each migration does
   ```sql
   -- Add email column to users table
   -- Migration: 2025-01-15
   ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255);
   ```

3. **One Logical Change Per File**: Keep migrations focused and atomic

4. **Test Locally First**: Always test migrations on a development database

### Transaction Handling

The plugin automatically wraps each migration file in a transaction:

```sql
BEGIN;
-- Your SQL here
COMMIT;
```

If any error occurs during execution, the transaction is automatically rolled back.

### File Size Limits

- Maximum SQL file size: ~16KB
- If you need larger migrations, split them into multiple files

## Usage

### Loading the Plugin

The plugin executes migrations immediately on load:

```
sm plugins load DatabaseMigrator
```

### Checking Migration Status

Check the server console or logs for migration results:

```
[SM] Database Migrator v1.0.0 loaded
[SM] =================================================
[SM] Starting database migration process
[SM] =================================================
[SM] Loading migrations for database: loadoutsaver
[SM]   - Added migration: configs/sql-init-scripts/pgsql/loadout_saver.sql
[SM] Loaded configuration for 1 database(s)
[SM] Connecting to 1 database(s)...
[SM] Successfully connected to database: loadoutsaver
[SM] =================================================
[SM] Executing migrations
[SM] =================================================
[SM] Total migration files to execute: 1
[SM] Executing 1 migration(s) for database: loadoutsaver
[SM]   Executing: configs/sql-init-scripts/pgsql/loadout_saver.sql
[SM]   SUCCESS: configs/sql-init-scripts/pgsql/loadout_saver.sql
[SM] =================================================
[SM] Migration process complete
[SM] =================================================
[SM] Summary:
[SM]   Total migrations: 1
[SM]   Successful: 1
[SM]   Failed: 0
[SM] =================================================
[SM] All migrations completed successfully!
```

## Error Handling

### Migration Failures

If a migration fails:
1. The specific migration is rolled back (transaction safety)
2. An error message is logged with details
3. Other migrations continue to execute
4. The plugin sets a fail state at the end if any migration failed

Example error output:
```
[SM]   FAILED: configs/sql-init-scripts/pgsql/bad_migration.sql
[SM]   Error: ERROR: syntax error at or near "SELCT"
```

### Connection Failures

If a database connection fails:
1. The error is logged
2. Migrations for that database are skipped
3. Other databases continue to be processed

Example error output:
```
[SM] Failed to connect to database 'mydb': could not connect to server
```

### Plugin Fail State

If ANY migration or connection fails, the plugin will:
1. Log all errors to the console
2. Print a summary showing successes and failures
3. Enter a fail state with `SetFailState()`

This ensures server operators are aware of migration issues.

## Workflow Examples

### Adding a New Migration

1. Create your SQL file:
   ```bash
   nano addons/sourcemod/configs/sql-init-scripts/pgsql/add_user_preferences.sql
   ```

2. Write your migration:
   ```sql
   -- Add user preferences table
   CREATE TABLE IF NOT EXISTS user_preferences (
       steam_id VARCHAR(32) PRIMARY KEY,
       theme VARCHAR(32) DEFAULT 'default',
       language VARCHAR(16) DEFAULT 'en'
   );
   ```

3. Add to configuration:
   ```
   "loadoutsaver"
   {
       "1"  "configs/sql-init-scripts/pgsql/loadout_saver.sql"
       "2"  "configs/sql-init-scripts/pgsql/add_user_preferences.sql"
   }
   ```

4. Reload the plugin:
   ```
   sm plugins reload DatabaseMigrator
   ```

### Migrating Multiple Databases

```
"Migrations"
{
    "loadoutsaver"
    {
        "1"  "configs/sql-init-scripts/pgsql/loadout_saver.sql"
    }
    
    "stats"
    {
        "1"  "configs/sql-init-scripts/pgsql/stats_schema.sql"
        "2"  "configs/sql-init-scripts/pgsql/stats_indexes.sql"
    }
    
    "rankings"
    {
        "1"  "configs/sql-init-scripts/pgsql/rankings_schema.sql"
    }
}
```

## Troubleshooting

### Migration Not Executing

**Symptom**: Migration file doesn't run

**Check**:
- File path in config is correct and relative to `addons/sourcemod/`
- File exists at the specified location
- File has read permissions
- Database name in config matches `databases.cfg`

### SQL Syntax Errors

**Symptom**: Migration fails with syntax error

**Solution**:
- Test SQL manually in a PostgreSQL client first
- Check for PostgreSQL-specific syntax (this plugin only supports PostgreSQL)
- Verify semicolons and proper SQL formatting

### Connection Issues

**Symptom**: "Failed to connect to database"

**Check**:
- Database server is running
- Credentials in `databases.cfg` are correct
- PostgreSQL is configured to accept connections from the game server
- Firewall rules allow the connection

### File Too Large

**Symptom**: Migration truncated or incomplete

**Solution**:
- Split large migrations into multiple smaller files
- Current buffer limit is 16KB

## Advanced Usage

### Conditional Migrations

Use PostgreSQL's conditional logic in your migrations:

```sql
-- Only add column if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'users' AND column_name = 'email'
    ) THEN
        ALTER TABLE users ADD COLUMN email VARCHAR(255);
    END IF;
END $$;
```

### Data Migrations

Migrations can include data changes:

```sql
-- Update existing records
UPDATE users SET status = 'active' WHERE last_login > NOW() - INTERVAL '30 days';

-- Seed default data
INSERT INTO settings (key, value) 
VALUES ('maintenance_mode', 'false')
ON CONFLICT (key) DO NOTHING;
```
