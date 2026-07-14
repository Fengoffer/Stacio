import { resolve } from "node:path";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import type { OpsDatabase } from "./database.js";

export async function migrateDatabase(db: OpsDatabase) {
  const migrationsFolder =
    process.env.DATABASE_MIGRATIONS_DIR ?? resolve(process.cwd(), "apps/api/drizzle");

  await migrate(db, {
    migrationsFolder
  });
}
