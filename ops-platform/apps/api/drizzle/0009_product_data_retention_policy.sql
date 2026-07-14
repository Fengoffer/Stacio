ALTER TABLE "products" ADD COLUMN "data_retention_policy" jsonb DEFAULT '{}'::jsonb NOT NULL;
