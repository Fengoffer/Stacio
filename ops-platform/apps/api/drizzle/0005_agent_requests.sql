CREATE TABLE "agent_requests" (
  "id" varchar(64) PRIMARY KEY NOT NULL,
  "product_id" varchar(64) NOT NULL,
  "target_type" varchar(64) NOT NULL,
  "target_id" varchar(64) NOT NULL,
  "request_type" varchar(80) NOT NULL,
  "agent_hint" varchar(160),
  "prompt" text NOT NULL,
  "status" varchar(32) DEFAULT 'queued' NOT NULL,
  "requested_by" varchar(64),
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE "agent_requests" ADD CONSTRAINT "agent_requests_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;
ALTER TABLE "agent_requests" ADD CONSTRAINT "agent_requests_requested_by_users_id_fk" FOREIGN KEY ("requested_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
CREATE INDEX "agent_requests_target_idx" ON "agent_requests" USING btree ("product_id","target_type","target_id");
CREATE INDEX "agent_requests_status_idx" ON "agent_requests" USING btree ("product_id","status","created_at");
