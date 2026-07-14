import { createDatabaseRuntime } from "./database.js";
import { migrateDatabase } from "./migrate.js";
import { seedDatabase } from "./seed.js";

async function main() {
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    throw new Error("DATABASE_URL is required");
  }

  const command = process.argv[2];
  const runtime = createDatabaseRuntime(databaseUrl);

  try {
    if (command === "migrate") {
      await migrateDatabase(runtime.db);
      console.log("Database migrations completed.");
      return;
    }

    if (command === "seed") {
      await seedDatabase(runtime.db);
      console.log("Database seed completed.");
      return;
    }

    throw new Error("Expected command: migrate or seed");
  } finally {
    await runtime.pool.end();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
