import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./apps/api/src/db/schema.ts",
  out: "./apps/api/drizzle",
  dbCredentials: {
    url: process.env.DATABASE_URL ?? "postgres://stacio_ops:change-me@127.0.0.1:5432/stacio_ops"
  },
  strict: true,
  verbose: true
});
