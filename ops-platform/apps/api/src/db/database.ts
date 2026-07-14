import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import * as schema from "./schema.js";

export type OpsDatabase = NodePgDatabase<typeof schema>;

export interface DatabaseRuntime {
  db: OpsDatabase;
  pool: Pool;
}

export function createDatabaseRuntime(databaseUrl: string): DatabaseRuntime {
  const ssl =
    process.env.DATABASE_SSL === "true"
      ? {
          rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED !== "false"
        }
      : undefined;

  const pool = new Pool({
    connectionString: databaseUrl,
    max: Number(process.env.DATABASE_POOL_MAX ?? 10),
    idleTimeoutMillis: Number(process.env.DATABASE_IDLE_TIMEOUT_MS ?? 30_000),
    connectionTimeoutMillis: Number(process.env.DATABASE_CONNECT_TIMEOUT_MS ?? 10_000),
    ssl
  });

  return {
    pool,
    db: drizzle(pool, { schema })
  };
}
