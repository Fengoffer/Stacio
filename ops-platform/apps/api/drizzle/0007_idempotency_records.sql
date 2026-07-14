CREATE TABLE "idempotency_records" (
  "scope" varchar(160) NOT NULL,
  "idempotency_key" varchar(200) NOT NULL,
  "request_hash" text NOT NULL,
  "status_code" integer NOT NULL,
  "response_body" jsonb NOT NULL,
  "expires_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "idempotency_records_scope_key_pk" PRIMARY KEY("scope", "idempotency_key")
);

CREATE INDEX "idempotency_records_expires_idx" ON "idempotency_records" ("expires_at");
