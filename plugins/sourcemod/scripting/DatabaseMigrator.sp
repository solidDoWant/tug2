// (C) 2025 DatabaseMigrator sdw
// SourceMod Database Schema Migration Plugin
// Applies SQL migration scripts to PostgreSQL databases

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION        "1.0.0"
#define MAX_DATABASES         32
#define MAX_MIGRATIONS_PER_DB 128
#define MAX_PATH_LENGTH       PLATFORM_MAX_PATH
#define SQL_BUFFER_SIZE       16384
#define SQL_LINE_SIZE         1024

public Plugin myinfo =
{
    name        = "[INS] Database Migrator",
    author      = "sdw",
    description = "Applies SQL migration scripts to databases on plugin load",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// =====================================================
// Data Structures
// =====================================================

enum struct MigrationFile
{
    char filePath[MAX_PATH_LENGTH];
    bool executed;
    bool succeeded;
    char errorMessage[512];
}

enum struct DatabaseMigration
{
    char      databaseName[64];
    Database  dbHandle;
    bool      connected;
    bool      connectionFailed;
    char      connectionError[512];
    ArrayList migrations;    // ArrayList of MigrationFile structs
}

// =====================================================
// Global Variables
// =====================================================

ArrayList g_Databases;    // ArrayList of DatabaseMigration structs. Needed because the datapacks used by the database call chain cannot contain complex types.
bool      g_MigrationInProgress;
bool      g_MigrationFailed;
int       g_PendingConnections;
int       g_PendingExecutions;

// =====================================================
// Plugin Lifecycle
// =====================================================
public void OnPluginStart()
{
    CreateConVar("sm_dbmigrator_version", PLUGIN_VERSION, "Database Migrator version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // Clean up any existing global state (in case of reload)
    CleanupDatabases();

    g_Databases           = new ArrayList(sizeof(DatabaseMigration));
    g_MigrationInProgress = false;
    g_MigrationFailed     = false;
    g_PendingConnections  = 0;
    g_PendingExecutions   = 0;

    LogMessage("Database Migrator v%s loaded", PLUGIN_VERSION);

    // Start migration process
    StartMigration();
}

public void OnPluginEnd()
{
    CleanupDatabases();
}

// =====================================================
// Migration Process
// =====================================================

/**
 * Cleans up all database connections and migration data
 * Used by both OnPluginStart and OnPluginEnd to ensure proper cleanup
 */
void CleanupDatabases()
{
    if (g_Databases == null) return;

    int dbCount = g_Databases.Length;
    for (int i = 0; i < dbCount; i++)
    {
        DatabaseMigration dbMigration;
        g_Databases.GetArray(i, dbMigration);

        if (dbMigration.dbHandle != null)
        {
            delete dbMigration.dbHandle;
        }

        if (dbMigration.migrations != null)
        {
            delete dbMigration.migrations;
        }
    }

    delete g_Databases;
    g_Databases = null;
}

void StartMigration()
{
    if (g_MigrationInProgress)
    {
        LogError("Migration already in progress!");
        return;
    }

    g_MigrationInProgress = true;
    g_MigrationFailed     = false;

    LogMessage("=================================================");
    LogMessage("=      Starting database migration process      =");
    LogMessage("=================================================");

    // Load migration configuration
    if (LoadMigrationConfig())
    {
        // Connect to all databases
        ConnectDatabases();
        return;
    }

    LogError("Failed to load migration configuration!");
    g_MigrationInProgress = false;
    g_MigrationFailed     = true;
    SetFailState("Database migration configuration could not be loaded");
}

/**
 * Loads migration configuration from database-migrations.cfg
 *
 * Parses the KeyValues config file to build a list of databases and their
 * associated migration files. Each database section can contain any number
 * of key-value pairs where values are relative paths to SQL files.
 *
 * @return True if config loaded successfully and contains at least one database, false otherwise
 */
bool LoadMigrationConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/database-migrations.cfg");

    if (!FileExists(configPath))
    {
        LogError("Migration config file not found: %s", configPath);
        return false;
    }

    KeyValues kv = new KeyValues("Migrations");

    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to parse migration config file: %s", configPath);
        delete kv;
        return false;
    }

    // Iterate through databases
    if (!kv.GotoFirstSubKey())
    {
        LogError("No databases found in migration config");
        delete kv;
        return false;
    }

    do
    {
        DatabaseMigration dbMigration;
        kv.GetSectionName(dbMigration.databaseName, sizeof(dbMigration.databaseName));
        dbMigration.dbHandle           = null;
        dbMigration.connected          = false;
        dbMigration.connectionFailed   = false;
        dbMigration.connectionError[0] = '\0';
        dbMigration.migrations         = new ArrayList(sizeof(MigrationFile));

        LogMessage("Loading migrations for database: %s", dbMigration.databaseName);

        // Read migration files
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char key[32];
                char relativePath[MAX_PATH_LENGTH];
                kv.GetSectionName(key, sizeof(key));
                kv.GetString(NULL_STRING, relativePath, sizeof(relativePath));

                if (relativePath[0] == '\0') continue;

                MigrationFile migration;
                BuildPath(Path_SM, migration.filePath, sizeof(migration.filePath), relativePath);
                migration.executed        = false;
                migration.succeeded       = false;
                migration.errorMessage[0] = '\0';

                if (!FileExists(migration.filePath))
                {
                    LogError("  - Migration file not found: %s", migration.filePath);
                    g_MigrationFailed = true;
                    continue;
                }

                dbMigration.migrations.PushArray(migration);
                LogMessage("  - Added migration: %s", migration.filePath);
            }
            while (kv.GotoNextKey(false));

            kv.GoBack();
        }

        if (dbMigration.migrations.Length == 0)
            LogMessage("  - No migrations configured for this database");

        g_Databases.PushArray(dbMigration);
    }
    while (kv.GotoNextKey());

    delete kv;

    LogMessage("Loaded configuration for %d database(s)", g_Databases.Length);
    return g_Databases.Length > 0;
}

/**
 * Initiates asynchronous connections to all configured databases
 *
 * Starts Database.Connect() for each database in parallel. Callbacks will be
 * received via OnDatabaseConnected(). Once all connections complete (success or failure),
 * migration execution begins automatically.
 */
void ConnectDatabases()
{
    int dbCount          = g_Databases.Length;
    g_PendingConnections = dbCount;

    LogMessage("Connecting to %d database(s)...", dbCount);

    for (int i = 0; i < dbCount; i++)
    {
        DatabaseMigration dbMigration;
        g_Databases.GetArray(i, dbMigration);

        LogMessage("Connecting to database: %s", dbMigration.databaseName);

        // Pass the index directly as the data parameter
        Database.Connect(OnDatabaseConnected, dbMigration.databaseName, i);
    }
}

/**
 * Callback handler for database connections
 *
 * Called asynchronously for each Database.Connect() attempt. Tracks connection status
 * and triggers migration execution once all databases have completed connection attempts.
 *
 * @param db       Database handle (null if connection failed)
 * @param error    Error message (empty string if successful)
 * @param data     Integer containing the database index
 */
void OnDatabaseConnected(Database db, const char[] error, any data)
{
    int               dbIndex = data;

    DatabaseMigration dbMigration;
    g_Databases.GetArray(dbIndex, dbMigration);

    g_PendingConnections--;

    if (db == null)
    {
        LogError("Failed to connect to database '%s': %s", dbMigration.databaseName, error);
        dbMigration.connectionFailed = true;
        strcopy(dbMigration.connectionError, sizeof(dbMigration.connectionError), error);
        g_MigrationFailed = true;
        g_Databases.SetArray(dbIndex, dbMigration);
    }
    else
    {
        LogMessage("Successfully connected to database: %s", dbMigration.databaseName);
        dbMigration.dbHandle  = db;
        dbMigration.connected = true;
        g_Databases.SetArray(dbIndex, dbMigration);
    }

    // If all connections are done, start executing migrations
    if (g_PendingConnections <= 0)
        ExecuteMigrations();
}

void ExecuteMigrations()
{
    LogMessage("=================================================");
    LogMessage("=              Executing migrations             =");
    LogMessage("=================================================");

    int dbCount         = g_Databases.Length;
    g_PendingExecutions = 0;

    // Count total pending executions
    for (int i = 0; i < dbCount; i++)
    {
        DatabaseMigration dbMigration;
        g_Databases.GetArray(i, dbMigration);

        if (dbMigration.connected && dbMigration.migrations.Length > 0)
            g_PendingExecutions += dbMigration.migrations.Length;
    }

    LogMessage("Total migration files to execute: %d", g_PendingExecutions);

    if (g_PendingExecutions == 0)
    {
        FinalizeMigration();
        return;
    }

    // Execute migrations for each database
    for (int i = 0; i < dbCount; i++)
    {
        DatabaseMigration dbMigration;
        g_Databases.GetArray(i, dbMigration);

        if (!dbMigration.connected)
        {
            LogMessage("Skipping migrations for '%s' (not connected)", dbMigration.databaseName);
            continue;
        }

        int migrationCount = dbMigration.migrations.Length;
        if (migrationCount == 0)
        {
            LogMessage("No migrations to execute for database: %s", dbMigration.databaseName);
            continue;
        }

        LogMessage("Executing %d migration(s) for database: %s", migrationCount, dbMigration.databaseName);

        for (int j = 0; j < migrationCount; j++)
        {
            MigrationFile migration;
            dbMigration.migrations.GetArray(j, migration);

            ExecuteMigrationFile(i, j, dbMigration, migration);
        }
    }
}

void ExecuteMigrationFile(int dbIndex, int migrationIndex, DatabaseMigration dbMigration, MigrationFile migration)
{
    LogMessage("  Executing: %s", migration.filePath);

    // Read the SQL file
    File file = OpenFile(migration.filePath, "r");
    if (file == null)
    {
        LogError("  Failed to open migration file: %s", migration.filePath);
        migration.executed  = true;
        migration.succeeded = false;
        strcopy(migration.errorMessage, sizeof(migration.errorMessage), "Failed to open file");

        // Use the passed-in dbMigration parameter directly
        dbMigration.migrations.SetArray(migrationIndex, migration);

        g_MigrationFailed = true;
        g_PendingExecutions--;

        if (g_PendingExecutions <= 0)
            FinalizeMigration();
        return;
    }

    // Check file size to ensure it fits in our buffer
    // Get file size by seeking to end
    file.Seek(0, SEEK_END);
    int fileSize = file.Position;

    // Fail if file is too large for our buffer (leaving room for transaction wrapper)
    if (fileSize >= SQL_BUFFER_SIZE - 256)
    {
        delete file;
        LogError("  Migration file too large (%d bytes, max %d): %s",
                 fileSize, SQL_BUFFER_SIZE - 256, migration.filePath);
        LogError("  Please split this migration into smaller files");

        migration.executed  = true;
        migration.succeeded = false;
        Format(migration.errorMessage, sizeof(migration.errorMessage),
               "File too large: %d bytes (max %d)", fileSize, SQL_BUFFER_SIZE - 256);

        dbMigration.migrations.SetArray(migrationIndex, migration);
        g_MigrationFailed = true;
        g_PendingExecutions--;

        if (g_PendingExecutions <= 0)
            FinalizeMigration();
        return;
    }

    // Reset to the beginning of the file
    file.Seek(0, SEEK_SET);

    // Read entire file into a buffer
    char sqlBuffer[SQL_BUFFER_SIZE];
    char line[SQL_LINE_SIZE];
    sqlBuffer[0] = '\0';

    while (file.ReadLine(line, sizeof(line)))
        StrCat(sqlBuffer, sizeof(sqlBuffer), line);

    delete file;

    // Empty files are treated as successful no-ops (already applied or intentionally empty)
    if (sqlBuffer[0] == '\0')
    {
        migration.executed  = true;
        migration.succeeded = true;

        // Use the passed-in dbMigration parameter directly
        dbMigration.migrations.SetArray(migrationIndex, migration);

        g_PendingExecutions--;

        if (g_PendingExecutions <= 0)
            FinalizeMigration();

        return;
    }

    // Wrap in transaction
    Transaction txn = new Transaction();
    txn.AddQuery(sqlBuffer);

    // Create datapack for callback
    DataPack pack = new DataPack();
    pack.WriteCell(dbIndex);
    pack.WriteCell(migrationIndex);
    pack.WriteString(migration.filePath);
    pack.Reset();

    // Execute the transaction with separate success and error callbacks
    dbMigration.dbHandle.Execute(txn, OnMigrationSuccess, OnMigrationError, pack);
}

/**
 * Transaction success callback
 * Called when all queries in the transaction complete successfully
 */
void OnMigrationSuccess(Database db, DataPack pack, int numQueries, DBResultSet[] results, any[] queryData)
{
    int  dbIndex        = pack.ReadCell();
    int  migrationIndex = pack.ReadCell();
    char filePath[MAX_PATH_LENGTH];
    pack.ReadString(filePath, sizeof(filePath));
    delete pack;

    DatabaseMigration dbMigration;
    g_Databases.GetArray(dbIndex, dbMigration);

    MigrationFile migration;
    dbMigration.migrations.GetArray(migrationIndex, migration);

    migration.executed  = true;
    migration.succeeded = true;

    LogMessage("  SUCCESS: %s", filePath);

    dbMigration.migrations.SetArray(migrationIndex, migration);
    g_Databases.SetArray(dbIndex, dbMigration);

    g_PendingExecutions--;

    if (g_PendingExecutions > 0) return;
    FinalizeMigration();
}

/**
 * Transaction error callback
 * Called when any query in the transaction fails
 */
void OnMigrationError(Database db, DataPack pack, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    int  dbIndex        = pack.ReadCell();
    int  migrationIndex = pack.ReadCell();
    char filePath[MAX_PATH_LENGTH];
    pack.ReadString(filePath, sizeof(filePath));
    delete pack;

    DatabaseMigration dbMigration;
    g_Databases.GetArray(dbIndex, dbMigration);

    MigrationFile migration;
    dbMigration.migrations.GetArray(migrationIndex, migration);

    migration.executed  = true;
    migration.succeeded = false;
    strcopy(migration.errorMessage, sizeof(migration.errorMessage), error);

    LogError("  FAILED: %s", filePath);
    LogError("  Error: %s (query %d of %d)", error, failIndex + 1, numQueries);

    dbMigration.migrations.SetArray(migrationIndex, migration);
    g_Databases.SetArray(dbIndex, dbMigration);

    g_MigrationFailed = true;
    g_PendingExecutions--;

    if (g_PendingExecutions > 0) return;
    FinalizeMigration();
}

void FinalizeMigration()
{
    LogMessage("=================================================");
    LogMessage("=           Migration process complete          =");
    LogMessage("=================================================");

    int totalMigrations      = 0;
    int successfulMigrations = 0;
    int failedMigrations     = 0;

    int dbCount              = g_Databases.Length;
    for (int i = 0; i < dbCount; i++)
    {
        DatabaseMigration dbMigration;
        g_Databases.GetArray(i, dbMigration);

        LogMessage("Database: %s", dbMigration.databaseName);

        if (dbMigration.connectionFailed)
        {
            LogMessage("  Status: Connection failed");
            LogMessage("  Error: %s", dbMigration.connectionError);
            continue;
        }

        if (!dbMigration.connected)
        {
            LogMessage("  Status: Not connected");
            continue;
        }

        int migrationCount = dbMigration.migrations.Length;
        LogMessage("  Migrations: %d", migrationCount);

        for (int j = 0; j < migrationCount; j++)
        {
            MigrationFile migration;
            dbMigration.migrations.GetArray(j, migration);

            totalMigrations++;

            if (migration.executed)
            {
                if (migration.succeeded)
                {
                    LogMessage("    ✓ %s", migration.filePath);
                    successfulMigrations++;
                }
                else
                {
                    LogMessage("    ✗ %s", migration.filePath);
                    LogMessage("      Error: %s", migration.errorMessage);
                    failedMigrations++;
                }
            }
            else
            {
                LogMessage("    - %s (not executed)", migration.filePath);
                failedMigrations++;
            }
        }
    }

    LogMessage("=================================================");
    LogMessage("=                   Summary                     =");
    LogMessage("=================================================");
    LogMessage("=  Total migrations: %-26d =", totalMigrations);
    LogMessage("=  Successful:       %-26d =", successfulMigrations);
    LogMessage("=  Failed:           %-26d =", failedMigrations);
    LogMessage("=================================================");

    g_MigrationInProgress = false;

    if (g_MigrationFailed)
    {
        LogError("Migration completed with errors - see above for details");
        return;
    }

    LogMessage("All migrations completed successfully!");
}
