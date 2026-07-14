CREATE TABLE "release_publications" (
  "id" varchar(64) PRIMARY KEY NOT NULL,
  "product_id" varchar(64) NOT NULL REFERENCES "products"("id") ON DELETE CASCADE,
  "release_id" varchar(64) NOT NULL REFERENCES "releases"("id") ON DELETE CASCADE,
  "target" varchar(48) NOT NULL,
  "status" varchar(32) NOT NULL DEFAULT 'queued',
  "attempts" integer NOT NULL DEFAULT 0,
  "object_key" text,
  "external_url" text,
  "last_error" text,
  "metadata" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "started_at" timestamp with time zone,
  "completed_at" timestamp with time zone,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "release_publications_release_target_unique" UNIQUE("release_id", "target")
);
CREATE INDEX "release_publications_product_release_idx" ON "release_publications" USING btree ("product_id", "release_id");
