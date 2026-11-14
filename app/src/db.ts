import { fileURLToPath } from "node:url";
import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import pg from "pg";
import { errorMessage, type Logger } from "./log.js";
import * as schema from "./schema.js";

export type Database = NodePgDatabase<typeof schema>;

export interface DatabaseConnection {
  readonly db: Database;
  readonly pool: pg.Pool;
}

// Resolves to app/drizzle from both src/ (tests, tsx) and dist/ (container).
const MIGRATIONS_FOLDER = fileURLToPath(new URL("../drizzle", import.meta.url));

// Serializes concurrent startups: a second replica waits here until the first finishes migrating.
const MIGRATION_LOCK_ID = 7_265_731_001;

/**
 * One connection, replaced automatically if the server drops it (for example during a failover).
 * Fails fast when the database is unreachable, so the caller can crash and be restarted.
 */
export async function connectDatabase(connectionString: string, logger: Logger): Promise<DatabaseConnection> {
  const pool = new pg.Pool({ connectionString, max: 1, connectionTimeoutMillis: 10_000 });
  pool.on("error", (error) => logger.warn("PostgreSQL connection lost; it will be re-established", { reason: errorMessage(error) }));
  try {
    await pool.query("SELECT 1");
  } catch (error) {
    await pool.end();
    throw error;
  }
  return { pool, db: drizzle(pool, { schema }) };
}

/** Applies pending migrations; the database starts without any tables. */
export async function migrateDatabase({ pool }: DatabaseConnection): Promise<void> {
  // The advisory lock belongs to one session, so migrating must use that same connection.
  const client = await pool.connect();
  try {
    await client.query("SELECT pg_advisory_lock($1)", [MIGRATION_LOCK_ID]);
    try {
      await migrate(drizzle(client, { schema }), { migrationsFolder: MIGRATIONS_FOLDER });
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [MIGRATION_LOCK_ID]);
    }
  } finally {
    client.release();
  }
}
