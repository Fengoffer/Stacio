ALTER TABLE "feedback_comments" ADD COLUMN "notification_id" varchar(64);--> statement-breakpoint
ALTER TABLE "feedback_comments" ADD COLUMN "delivery_status" varchar(32);--> statement-breakpoint
ALTER TABLE "feedback_items" ADD COLUMN "deleted_at" timestamp with time zone;