import { createMemoryAuthStore, createPostgresAuthStore, type AuthStore } from "../auth/store.js";
import { createMemoryStore, type OpsStore } from "../data/store.js";
import { createPostgresStore } from "../data/postgresStore.js";
import { createDatabaseRuntime } from "./database.js";
import { migrateDatabase } from "./migrate.js";
import { seedDatabase } from "./seed.js";

export interface RuntimeStore {
  store: OpsStore;
  authStore: AuthStore;
  persistence: "memory" | "postgres";
  close(): Promise<void>;
}

export async function createRuntimeStore(): Promise<RuntimeStore> {
  const databaseUrl = process.env.DATABASE_URL;
  const forceMemory = process.env.USE_MEMORY_STORE === "true";

  if (!databaseUrl || forceMemory) {
    return {
      store: createMemoryStore(),
      authStore: createMemoryAuthStore(),
      persistence: "memory",
      async close() {}
    };
  }

  const runtime = createDatabaseRuntime(databaseUrl);

  if (process.env.DATABASE_AUTO_MIGRATE !== "false") {
    await migrateDatabase(runtime.db);
  }

  if (process.env.DATABASE_SEED_DEFAULTS !== "false") {
    await seedDatabase(runtime.db);
  }

  return {
    store: createPostgresStore(runtime.db),
    authStore: createPostgresAuthStore(runtime.db),
    persistence: "postgres",
    async close() {
      await runtime.pool.end();
    }
  };
}
