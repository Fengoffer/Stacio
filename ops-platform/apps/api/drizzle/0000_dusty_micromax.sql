CREATE TABLE "ai_analysis_results" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"target_type" varchar(64) NOT NULL,
	"target_id" varchar(64) NOT NULL,
	"agent_identity" varchar(160) NOT NULL,
	"provider" varchar(80),
	"model" varchar(160),
	"analysis_type" varchar(80) NOT NULL,
	"input_references" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"output_body" jsonb NOT NULL,
	"confidence" varchar(32),
	"adoption_state" varchar(32) DEFAULT 'pending' NOT NULL,
	"adopted_by" varchar(64),
	"adopted_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ai_proposed_actions" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"analysis_id" varchar(64) NOT NULL,
	"action_type" varchar(80) NOT NULL,
	"payload" jsonb NOT NULL,
	"status" varchar(32) DEFAULT 'pending' NOT NULL,
	"reviewed_by" varchar(64),
	"reviewed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "api_keys" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"owner_type" varchar(32) NOT NULL,
	"owner_id" varchar(64) NOT NULL,
	"product_id" varchar(64),
	"name" varchar(160) NOT NULL,
	"key_prefix" varchar(32) NOT NULL,
	"key_hash" text NOT NULL,
	"scopes" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"expires_at" timestamp with time zone,
	"last_used_at" timestamp with time zone,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "appcast_entries" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"channel_id" varchar(64) NOT NULL,
	"release_id" varchar(64) NOT NULL,
	"xml" text NOT NULL,
	"object_key" text,
	"published_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "audit_logs" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"actor_type" varchar(32) NOT NULL,
	"actor_id" varchar(64),
	"action" varchar(120) NOT NULL,
	"target_type" varchar(64) NOT NULL,
	"target_id" varchar(64),
	"product_id" varchar(64),
	"before_value" jsonb,
	"after_value" jsonb,
	"ip_address" varchar(80),
	"user_agent" text,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "connectors" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64),
	"type" varchar(64) NOT NULL,
	"name" varchar(160) NOT NULL,
	"encrypted_secrets" text,
	"config" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" varchar(32) DEFAULT 'unconfigured' NOT NULL,
	"last_success_at" timestamp with time zone,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "customers" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"email" varchar(320) NOT NULL,
	"name" varchar(160) NOT NULL,
	"company" varchar(200),
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"notes" text,
	"risk_flag" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "entitlements" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"key" varchar(120) NOT NULL,
	"name" varchar(160) NOT NULL,
	"description" text,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "feedback_attachments" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"feedback_id" varchar(64) NOT NULL,
	"object_key" text NOT NULL,
	"file_name" text NOT NULL,
	"content_type" varchar(160) NOT NULL,
	"size_bytes" integer NOT NULL,
	"sha256" varchar(64),
	"redacted_at" timestamp with time zone,
	"deleted_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "feedback_comments" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"feedback_id" varchar(64) NOT NULL,
	"author_type" varchar(32) NOT NULL,
	"author_id" varchar(64),
	"visibility" varchar(32) DEFAULT 'internal' NOT NULL,
	"body" text NOT NULL,
	"delivery_id" varchar(64),
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "feedback_items" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"customer_id" varchar(64),
	"title" text NOT NULL,
	"description" text NOT NULL,
	"type" varchar(32) NOT NULL,
	"status" varchar(32) NOT NULL,
	"priority" varchar(8) NOT NULL,
	"source" varchar(32) NOT NULL,
	"contact_email" varchar(320),
	"app_version" varchar(80),
	"build_number" varchar(80),
	"os_version" varchar(160),
	"license_state" varchar(32),
	"license_key_hash" text,
	"anonymous_device_id" varchar(160),
	"diagnostics_summary" jsonb,
	"ai_summary" text,
	"ai_classification" varchar(80),
	"ai_suggested_priority" varchar(8),
	"assigned_user_id" varchar(64),
	"duplicate_of_id" varchar(64),
	"related_release_id" varchar(64),
	"last_activity_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "github_issue_links" (
	"feedback_id" varchar(64) NOT NULL,
	"github_issue_id" varchar(64) NOT NULL,
	"created_by" varchar(64),
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "github_issue_links_feedback_id_github_issue_id_pk" PRIMARY KEY("feedback_id","github_issue_id")
);
--> statement-breakpoint
CREATE TABLE "github_issues" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"github_issue_id" varchar(80) NOT NULL,
	"number" integer NOT NULL,
	"title" text NOT NULL,
	"body" text,
	"labels" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"author" varchar(160),
	"state" varchar(32) NOT NULL,
	"comments_count" integer DEFAULT 0 NOT NULL,
	"url" text NOT NULL,
	"github_created_at" timestamp with time zone,
	"github_updated_at" timestamp with time zone,
	"github_closed_at" timestamp with time zone,
	"synced_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "github_sync_runs" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"trigger" varchar(32) NOT NULL,
	"status" varchar(32) NOT NULL,
	"fetched_count" integer DEFAULT 0 NOT NULL,
	"changed_count" integer DEFAULT 0 NOT NULL,
	"error" text,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "license_activations" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"license_id" varchar(64) NOT NULL,
	"anonymous_device_id" varchar(160),
	"machine_fingerprint_hash" text,
	"first_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"reset_at" timestamp with time zone,
	"risk_signals" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "license_validation_logs" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"license_id" varchar(64),
	"product_id" varchar(64) NOT NULL,
	"key_prefix" varchar(32),
	"email" varchar(320),
	"anonymous_device_id" varchar(160),
	"machine_fingerprint_hash" text,
	"result" varchar(32) NOT NULL,
	"reason" varchar(160),
	"app_version" varchar(80),
	"build_number" varchar(80),
	"ip_address" varchar(80),
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "licenses" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"customer_id" varchar(64),
	"plan_id" varchar(64),
	"customer_name" varchar(160) NOT NULL,
	"customer_email" varchar(320) NOT NULL,
	"username" varchar(160) NOT NULL,
	"key_prefix" varchar(32) NOT NULL,
	"key_hash" text NOT NULL,
	"plan" varchar(64) NOT NULL,
	"entitlements" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"status" varchar(32) NOT NULL,
	"seats" integer DEFAULT 1 NOT NULL,
	"devices" integer DEFAULT 0 NOT NULL,
	"max_devices" integer DEFAULT 1 NOT NULL,
	"offline_grace_days" integer DEFAULT 14 NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"suspended_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "notification_deliveries" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"notification_id" varchar(64) NOT NULL,
	"provider" varchar(64) NOT NULL,
	"attempt" integer DEFAULT 1 NOT NULL,
	"status" varchar(32) NOT NULL,
	"provider_message_id" varchar(255),
	"error" text,
	"sent_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "notification_templates" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"type" varchar(80) NOT NULL,
	"subject_template" text NOT NULL,
	"html_template" text NOT NULL,
	"text_template" text,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "notifications" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"type" varchar(80) NOT NULL,
	"recipient" varchar(320) NOT NULL,
	"payload" jsonb NOT NULL,
	"priority" varchar(16) DEFAULT 'normal' NOT NULL,
	"status" varchar(32) DEFAULT 'queued' NOT NULL,
	"scheduled_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "plan_entitlements" (
	"plan_id" varchar(64) NOT NULL,
	"entitlement_id" varchar(64) NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "plan_entitlements_plan_id_entitlement_id_pk" PRIMARY KEY("plan_id","entitlement_id")
);
--> statement-breakpoint
CREATE TABLE "plans" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"name" varchar(120) NOT NULL,
	"description" text,
	"max_devices" integer DEFAULT 1 NOT NULL,
	"max_seats" integer DEFAULT 1 NOT NULL,
	"trial_days" integer DEFAULT 0 NOT NULL,
	"offline_grace_days" integer DEFAULT 14 NOT NULL,
	"allowed_channels" jsonb DEFAULT '["stable"]'::jsonb NOT NULL,
	"supported_version_range" varchar(160),
	"payment_provider" varchar(64),
	"provider_plan_id" varchar(160),
	"price_minor" integer,
	"currency" varchar(8),
	"billing_interval" varchar(32),
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "products" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"name" varchar(160) NOT NULL,
	"platform" varchar(80) NOT NULL,
	"bundle_id" varchar(255) NOT NULL,
	"icon_url" text,
	"description" text,
	"support_email" varchar(320) NOT NULL,
	"current_stable_version" varchar(80) DEFAULT '' NOT NULL,
	"current_beta_version" varchar(80) DEFAULT '' NOT NULL,
	"github_owner" varchar(160),
	"github_repository" varchar(160),
	"update_base_url" text,
	"appcast_base_url" text,
	"feedback_api_key_hash" text,
	"license_policy" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"email_brand" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"object_storage_prefix" text,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "release_artifacts" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"release_id" varchar(64) NOT NULL,
	"object_key" text,
	"url" text NOT NULL,
	"file_name" text NOT NULL,
	"content_type" varchar(160),
	"size_bytes" integer,
	"sha256" varchar(64),
	"signature_evidence" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "release_channels" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"name" varchar(64) NOT NULL,
	"appcast_url" text,
	"current_release_id" varchar(64),
	"allowed_plan_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"minimum_upgradable_version" varchar(80),
	"rollout_percentage" integer DEFAULT 100 NOT NULL,
	"auto_download_allowed" boolean DEFAULT false NOT NULL,
	"force_update_prompt" boolean DEFAULT false NOT NULL,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "releases" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"product_id" varchar(64) NOT NULL,
	"channel" varchar(64) NOT NULL,
	"version" varchar(80) NOT NULL,
	"build_number" varchar(80) NOT NULL,
	"minimum_system_version" varchar(80),
	"artifact_name" text NOT NULL,
	"artifact_url" text,
	"artifact_type" varchar(64),
	"artifact_size" integer,
	"sparkle_eddsa_signature" text,
	"release_notes" text,
	"ai_release_summary" text,
	"ai_risk_summary" text,
	"preflight_evidence" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"status" varchar(32) DEFAULT 'draft' NOT NULL,
	"created_by" varchar(64),
	"published_by" varchar(64),
	"published_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "roles" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"name" varchar(64) NOT NULL,
	"description" text,
	"permissions" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "user_roles" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"user_id" varchar(64) NOT NULL,
	"role_id" varchar(64) NOT NULL,
	"product_id" varchar(64),
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" varchar(64) PRIMARY KEY NOT NULL,
	"email" varchar(320) NOT NULL,
	"name" varchar(160) NOT NULL,
	"password_hash" text NOT NULL,
	"status" varchar(32) DEFAULT 'active' NOT NULL,
	"last_login_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "ai_analysis_results" ADD CONSTRAINT "ai_analysis_results_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_analysis_results" ADD CONSTRAINT "ai_analysis_results_adopted_by_users_id_fk" FOREIGN KEY ("adopted_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_proposed_actions" ADD CONSTRAINT "ai_proposed_actions_analysis_id_ai_analysis_results_id_fk" FOREIGN KEY ("analysis_id") REFERENCES "public"."ai_analysis_results"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ai_proposed_actions" ADD CONSTRAINT "ai_proposed_actions_reviewed_by_users_id_fk" FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "api_keys" ADD CONSTRAINT "api_keys_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "appcast_entries" ADD CONSTRAINT "appcast_entries_channel_id_release_channels_id_fk" FOREIGN KEY ("channel_id") REFERENCES "public"."release_channels"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "appcast_entries" ADD CONSTRAINT "appcast_entries_release_id_releases_id_fk" FOREIGN KEY ("release_id") REFERENCES "public"."releases"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "audit_logs" ADD CONSTRAINT "audit_logs_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "connectors" ADD CONSTRAINT "connectors_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "entitlements" ADD CONSTRAINT "entitlements_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_attachments" ADD CONSTRAINT "feedback_attachments_feedback_id_feedback_items_id_fk" FOREIGN KEY ("feedback_id") REFERENCES "public"."feedback_items"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_comments" ADD CONSTRAINT "feedback_comments_feedback_id_feedback_items_id_fk" FOREIGN KEY ("feedback_id") REFERENCES "public"."feedback_items"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_items" ADD CONSTRAINT "feedback_items_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_items" ADD CONSTRAINT "feedback_items_customer_id_customers_id_fk" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_items" ADD CONSTRAINT "feedback_items_assigned_user_id_users_id_fk" FOREIGN KEY ("assigned_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "github_issue_links" ADD CONSTRAINT "github_issue_links_feedback_id_feedback_items_id_fk" FOREIGN KEY ("feedback_id") REFERENCES "public"."feedback_items"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "github_issue_links" ADD CONSTRAINT "github_issue_links_github_issue_id_github_issues_id_fk" FOREIGN KEY ("github_issue_id") REFERENCES "public"."github_issues"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "github_issue_links" ADD CONSTRAINT "github_issue_links_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "github_issues" ADD CONSTRAINT "github_issues_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "github_sync_runs" ADD CONSTRAINT "github_sync_runs_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "license_activations" ADD CONSTRAINT "license_activations_license_id_licenses_id_fk" FOREIGN KEY ("license_id") REFERENCES "public"."licenses"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "license_validation_logs" ADD CONSTRAINT "license_validation_logs_license_id_licenses_id_fk" FOREIGN KEY ("license_id") REFERENCES "public"."licenses"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "license_validation_logs" ADD CONSTRAINT "license_validation_logs_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "licenses" ADD CONSTRAINT "licenses_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "licenses" ADD CONSTRAINT "licenses_customer_id_customers_id_fk" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "licenses" ADD CONSTRAINT "licenses_plan_id_plans_id_fk" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "notification_deliveries" ADD CONSTRAINT "notification_deliveries_notification_id_notifications_id_fk" FOREIGN KEY ("notification_id") REFERENCES "public"."notifications"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "notification_templates" ADD CONSTRAINT "notification_templates_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "notifications" ADD CONSTRAINT "notifications_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "plan_entitlements" ADD CONSTRAINT "plan_entitlements_plan_id_plans_id_fk" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "plan_entitlements" ADD CONSTRAINT "plan_entitlements_entitlement_id_entitlements_id_fk" FOREIGN KEY ("entitlement_id") REFERENCES "public"."entitlements"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "plans" ADD CONSTRAINT "plans_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "release_artifacts" ADD CONSTRAINT "release_artifacts_release_id_releases_id_fk" FOREIGN KEY ("release_id") REFERENCES "public"."releases"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "release_channels" ADD CONSTRAINT "release_channels_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "releases" ADD CONSTRAINT "releases_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "releases" ADD CONSTRAINT "releases_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "releases" ADD CONSTRAINT "releases_published_by_users_id_fk" FOREIGN KEY ("published_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_roles" ADD CONSTRAINT "user_roles_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_roles" ADD CONSTRAINT "user_roles_role_id_roles_id_fk" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_roles" ADD CONSTRAINT "user_roles_product_id_products_id_fk" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ai_analysis_target_idx" ON "ai_analysis_results" USING btree ("target_type","target_id");--> statement-breakpoint
CREATE INDEX "ai_proposed_actions_status_idx" ON "ai_proposed_actions" USING btree ("status","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "api_keys_prefix_unique" ON "api_keys" USING btree ("key_prefix");--> statement-breakpoint
CREATE INDEX "api_keys_owner_idx" ON "api_keys" USING btree ("owner_type","owner_id");--> statement-breakpoint
CREATE UNIQUE INDEX "appcast_entries_channel_release_unique" ON "appcast_entries" USING btree ("channel_id","release_id");--> statement-breakpoint
CREATE INDEX "audit_logs_product_created_idx" ON "audit_logs" USING btree ("product_id","created_at");--> statement-breakpoint
CREATE INDEX "audit_logs_actor_idx" ON "audit_logs" USING btree ("actor_type","actor_id");--> statement-breakpoint
CREATE UNIQUE INDEX "connectors_product_type_unique" ON "connectors" USING btree ("product_id","type");--> statement-breakpoint
CREATE UNIQUE INDEX "customers_email_unique" ON "customers" USING btree ("email");--> statement-breakpoint
CREATE UNIQUE INDEX "entitlements_product_key_unique" ON "entitlements" USING btree ("product_id","key");--> statement-breakpoint
CREATE INDEX "feedback_attachments_feedback_idx" ON "feedback_attachments" USING btree ("feedback_id");--> statement-breakpoint
CREATE INDEX "feedback_comments_feedback_idx" ON "feedback_comments" USING btree ("feedback_id","created_at");--> statement-breakpoint
CREATE INDEX "feedback_product_status_idx" ON "feedback_items" USING btree ("product_id","status");--> statement-breakpoint
CREATE INDEX "feedback_product_priority_idx" ON "feedback_items" USING btree ("product_id","priority");--> statement-breakpoint
CREATE INDEX "feedback_contact_email_idx" ON "feedback_items" USING btree ("contact_email");--> statement-breakpoint
CREATE INDEX "feedback_last_activity_idx" ON "feedback_items" USING btree ("last_activity_at");--> statement-breakpoint
CREATE UNIQUE INDEX "github_issues_product_issue_unique" ON "github_issues" USING btree ("product_id","github_issue_id");--> statement-breakpoint
CREATE UNIQUE INDEX "github_issues_product_number_unique" ON "github_issues" USING btree ("product_id","number");--> statement-breakpoint
CREATE INDEX "github_sync_runs_product_started_idx" ON "github_sync_runs" USING btree ("product_id","started_at");--> statement-breakpoint
CREATE INDEX "license_activations_license_idx" ON "license_activations" USING btree ("license_id");--> statement-breakpoint
CREATE INDEX "license_validation_logs_product_created_idx" ON "license_validation_logs" USING btree ("product_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "licenses_key_prefix_unique" ON "licenses" USING btree ("key_prefix");--> statement-breakpoint
CREATE INDEX "licenses_product_status_idx" ON "licenses" USING btree ("product_id","status");--> statement-breakpoint
CREATE INDEX "licenses_customer_email_idx" ON "licenses" USING btree ("customer_email");--> statement-breakpoint
CREATE INDEX "notification_deliveries_notification_idx" ON "notification_deliveries" USING btree ("notification_id","attempt");--> statement-breakpoint
CREATE UNIQUE INDEX "notification_templates_product_type_unique" ON "notification_templates" USING btree ("product_id","type");--> statement-breakpoint
CREATE INDEX "notifications_status_scheduled_idx" ON "notifications" USING btree ("status","scheduled_at");--> statement-breakpoint
CREATE UNIQUE INDEX "plans_product_id_unique" ON "plans" USING btree ("product_id","id");--> statement-breakpoint
CREATE INDEX "release_artifacts_release_idx" ON "release_artifacts" USING btree ("release_id");--> statement-breakpoint
CREATE UNIQUE INDEX "release_channels_product_name_unique" ON "release_channels" USING btree ("product_id","name");--> statement-breakpoint
CREATE UNIQUE INDEX "releases_product_channel_build_unique" ON "releases" USING btree ("product_id","channel","build_number");--> statement-breakpoint
CREATE INDEX "releases_product_status_idx" ON "releases" USING btree ("product_id","status");--> statement-breakpoint
CREATE UNIQUE INDEX "roles_name_unique" ON "roles" USING btree ("name");--> statement-breakpoint
CREATE UNIQUE INDEX "user_roles_assignment_unique" ON "user_roles" USING btree ("user_id","role_id","product_id");--> statement-breakpoint
CREATE UNIQUE INDEX "users_email_unique" ON "users" USING btree ("email");