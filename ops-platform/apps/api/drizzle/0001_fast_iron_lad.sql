CREATE TABLE "customer_notes" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"customer_id" varchar(64) NOT NULL,
	"author_id" varchar(64),
	"body" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
DROP INDEX "customers_email_unique";--> statement-breakpoint
ALTER TABLE "customers" ADD COLUMN "product_id" varchar(64);--> statement-breakpoint
UPDATE "customers" AS customer
SET "product_id" = license."product_id"
FROM "licenses" AS license
WHERE license."customer_id" = customer."id"
  AND customer."product_id" IS NULL;--> statement-breakpoint
UPDATE "customers"
SET "product_id" = (
  SELECT "id"
  FROM "products"
  ORDER BY "created_at" ASC
  LIMIT 1
)
WHERE "product_id" IS NULL;--> statement-breakpoint
ALTER TABLE "customers" ALTER COLUMN "product_id" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "customers" ADD COLUMN "merged_into_id" varchar(64);--> statement-breakpoint
ALTER TABLE "notifications" ADD COLUMN "customer_id" varchar(64);--> statement-breakpoint
ALTER TABLE "customer_notes" ADD CONSTRAINT "customer_notes_customer_id_customers_id_fk" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "customer_notes" ADD CONSTRAINT "customer_notes_author_id_users_id_fk" FOREIGN KEY ("author_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "customer_notes_customer_created_idx" ON "customer_notes" USING btree ("customer_id","created_at");--> statement-breakpoint
ALTER TABLE "customers" ADD CONSTRAINT "customers_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "notifications" ADD CONSTRAINT "notifications_customer_id_customers_id_fk" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "customers_product_email_unique" ON "customers" USING btree ("product_id","email");--> statement-breakpoint
CREATE INDEX "customers_product_status_idx" ON "customers" USING btree ("product_id","status");--> statement-breakpoint
CREATE INDEX "notifications_customer_idx" ON "notifications" USING btree ("customer_id","created_at");
