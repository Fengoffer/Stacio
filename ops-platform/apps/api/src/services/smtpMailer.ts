import nodemailer from "nodemailer";

export interface MailMessage {
  to: string;
  subject: string;
  html: string;
  text?: string;
}

export interface MailSendResult {
  status: "sent" | "dry_run";
  provider: "smtp";
  providerMessageId?: string;
}

export class SmtpConfigurationError extends Error {
  constructor(message = "SMTP is not configured") {
    super(message);
    this.name = "SmtpConfigurationError";
  }
}

function boolFromEnv(value: string | undefined, fallback = false) {
  if (value === undefined) return fallback;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

export function isSmtpConfigured() {
  return Boolean(process.env.SMTP_HOST && process.env.SMTP_FROM);
}

export async function sendSmtpMail(message: MailMessage, options: { dryRun?: boolean } = {}): Promise<MailSendResult> {
  const dryRun = options.dryRun ?? boolFromEnv(process.env.SMTP_DRY_RUN);
  if (dryRun) {
    return {
      status: "dry_run",
      provider: "smtp",
      providerMessageId: `dry-run-${Date.now()}`
    };
  }

  if (!isSmtpConfigured()) {
    throw new SmtpConfigurationError();
  }

  const port = Number(process.env.SMTP_PORT ?? 587);
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASSWORD;
  const transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port,
    secure: boolFromEnv(process.env.SMTP_SECURE, port === 465),
    auth: user && pass ? { user, pass } : undefined
  });

  const result = await transporter.sendMail({
    from: process.env.SMTP_FROM,
    to: message.to,
    subject: message.subject,
    html: message.html,
    text: message.text
  });

  return {
    status: "sent",
    provider: "smtp",
    providerMessageId: result.messageId
  };
}
