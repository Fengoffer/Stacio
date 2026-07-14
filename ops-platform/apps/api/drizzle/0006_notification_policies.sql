CREATE TABLE "notification_policies" (
  "product_id" varchar(64) PRIMARY KEY NOT NULL,
  "quiet_hours_enabled" boolean DEFAULT false NOT NULL,
  "quiet_hours_start" varchar(5) DEFAULT '22:00' NOT NULL,
  "quiet_hours_end" varchar(5) DEFAULT '08:00' NOT NULL,
  "quiet_hours_time_zone" varchar(80) DEFAULT 'Asia/Shanghai' NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE "notification_policies" ADD CONSTRAINT "notification_policies_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;
