CREATE TABLE "website_events" (
  "product_id" varchar(64) NOT NULL REFERENCES "products"("id") ON DELETE CASCADE,
  "event_id" varchar(96) NOT NULL,
  "type" varchar(48) NOT NULL,
  "path" text NOT NULL,
  "referrer" text,
  "visitor_hash" varchar(64) NOT NULL,
  "session_hash" varchar(64),
  "release_id" varchar(64),
  "platform" varchar(120),
  "architecture" varchar(80),
  "ip_address" varchar(120) NOT NULL,
  "ip_hash" varchar(64) NOT NULL,
  "browser_name" varchar(80) NOT NULL,
  "browser_version" varchar(80),
  "operating_system" varchar(160) NOT NULL,
  "device_type" varchar(24) NOT NULL,
  "occurred_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "website_events_product_id_event_id_pk" PRIMARY KEY("product_id", "event_id")
);
CREATE INDEX "website_events_product_occurred_idx" ON "website_events" USING btree ("product_id", "occurred_at");
CREATE INDEX "website_events_product_type_occurred_idx" ON "website_events" USING btree ("product_id", "type", "occurred_at");
