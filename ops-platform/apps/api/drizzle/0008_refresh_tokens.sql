CREATE TABLE "refresh_tokens" (
  "id" varchar(64) PRIMARY KEY NOT NULL,
  "user_id" varchar(64) NOT NULL,
  "token_hash" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "revoked_at" timestamp with time zone,
  "replaced_by_token_hash" text,
  "ip_address" varchar(120),
  "user_agent" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE "refresh_tokens" ADD CONSTRAINT "refresh_tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;

CREATE UNIQUE INDEX "refresh_tokens_token_hash_unique" ON "refresh_tokens" ("token_hash");
CREATE INDEX "refresh_tokens_user_idx" ON "refresh_tokens" ("user_id");
CREATE INDEX "refresh_tokens_expires_idx" ON "refresh_tokens" ("expires_at");
