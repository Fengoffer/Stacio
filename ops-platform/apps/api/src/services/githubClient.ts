import type { UpsertGitHubIssueInput } from "../data/store.js";

export interface GitHubIssueFetchInput {
  owner?: string;
  repository?: string;
  state?: "open" | "closed" | "all";
  labels?: string[];
  perPage?: number;
}

export interface GitHubIssueCommentInput {
  owner?: string;
  repository?: string;
  issueNumber: number;
  body: string;
}

export interface GitHubIssueUpdateInput {
  owner?: string;
  repository?: string;
  issueNumber: number;
  labels?: string[];
  state?: "open" | "closed";
}

interface GitHubIssueResponse {
  id: number;
  number: number;
  title: string;
  body?: string | null;
  labels?: Array<string | { name?: string | null }>;
  user?: { login?: string | null };
  state: "open" | "closed";
  comments?: number;
  html_url: string;
  created_at?: string;
  updated_at?: string;
  closed_at?: string | null;
  pull_request?: unknown;
}

interface GitHubIssueCommentResponse {
  id: number;
  html_url: string;
  body?: string | null;
}

export class GitHubConfigurationError extends Error {
  constructor(message = "GitHub owner and repository are not configured") {
    super(message);
    this.name = "GitHubConfigurationError";
  }
}

export class GitHubFetchError extends Error {
  constructor(
    message: string,
    readonly statusCode?: number
  ) {
    super(message);
    this.name = "GitHubFetchError";
  }
}

function issueLabels(labels: GitHubIssueResponse["labels"]) {
  return (labels ?? [])
    .map((label) => (typeof label === "string" ? label : label.name))
    .filter((label): label is string => Boolean(label));
}

function trimBaseUrl(value: string) {
  return value.replace(/\/+$/, "");
}

export async function fetchGitHubIssues(input: GitHubIssueFetchInput = {}): Promise<UpsertGitHubIssueInput[]> {
  const owner = input.owner ?? process.env.GITHUB_OWNER;
  const repository = input.repository ?? process.env.GITHUB_REPOSITORY;
  if (!owner || !repository) {
    throw new GitHubConfigurationError();
  }

  const apiBase = trimBaseUrl(process.env.GITHUB_API_BASE_URL ?? "https://api.github.com");
  const url = new URL(`${apiBase}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}/issues`);
  url.searchParams.set("state", input.state ?? "open");
  url.searchParams.set("per_page", String(input.perPage ?? 100));
  if (input.labels && input.labels.length > 0) {
    url.searchParams.set("labels", input.labels.join(","));
  }

  const response = await fetch(url, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "stacio-ops-platform",
      ...(process.env.GITHUB_TOKEN ? { Authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {})
    }
  });

  if (!response.ok) {
    throw new GitHubFetchError(`GitHub API returned ${response.status}`, response.status);
  }

  const body = (await response.json()) as GitHubIssueResponse[];
  return body
    .filter((issue) => !issue.pull_request)
    .map((issue) => ({
      githubIssueId: String(issue.id),
      number: issue.number,
      title: issue.title,
      body: issue.body ?? undefined,
      labels: issueLabels(issue.labels),
      author: issue.user?.login ?? undefined,
      state: issue.state,
      commentsCount: issue.comments ?? 0,
      url: issue.html_url,
      githubCreatedAt: issue.created_at,
      githubUpdatedAt: issue.updated_at,
      githubClosedAt: issue.closed_at ?? undefined
    }));
}

export async function postGitHubIssueComment(input: GitHubIssueCommentInput) {
  const owner = input.owner ?? process.env.GITHUB_OWNER;
  const repository = input.repository ?? process.env.GITHUB_REPOSITORY;
  const token = process.env.GITHUB_TOKEN;
  if (!owner || !repository || !token) {
    throw new GitHubConfigurationError("GitHub owner, repository, and token are required to post comments");
  }

  const apiBase = trimBaseUrl(process.env.GITHUB_API_BASE_URL ?? "https://api.github.com");
  const url = `${apiBase}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}/issues/${input.issueNumber}/comments`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "stacio-ops-platform"
    },
    body: JSON.stringify({ body: input.body })
  });

  if (!response.ok) {
    throw new GitHubFetchError(`GitHub API returned ${response.status}`, response.status);
  }

  const body = (await response.json()) as GitHubIssueCommentResponse;
  return {
    commentId: String(body.id),
    url: body.html_url,
    body: body.body ?? input.body
  };
}

export async function updateGitHubIssue(input: GitHubIssueUpdateInput): Promise<UpsertGitHubIssueInput> {
  const owner = input.owner ?? process.env.GITHUB_OWNER;
  const repository = input.repository ?? process.env.GITHUB_REPOSITORY;
  const token = process.env.GITHUB_TOKEN;
  if (!owner || !repository || !token) {
    throw new GitHubConfigurationError("GitHub owner, repository, and token are required to update issues");
  }

  const payload: Record<string, unknown> = {};
  if (input.labels) payload.labels = input.labels;
  if (input.state) payload.state = input.state;

  const apiBase = trimBaseUrl(process.env.GITHUB_API_BASE_URL ?? "https://api.github.com");
  const url = `${apiBase}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}/issues/${input.issueNumber}`;
  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "stacio-ops-platform"
    },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    throw new GitHubFetchError(`GitHub API returned ${response.status}`, response.status);
  }

  const issue = (await response.json()) as GitHubIssueResponse;
  return {
    githubIssueId: String(issue.id),
    number: issue.number,
    title: issue.title,
    body: issue.body ?? undefined,
    labels: issueLabels(issue.labels),
    author: issue.user?.login ?? undefined,
    state: issue.state,
    commentsCount: issue.comments ?? 0,
    url: issue.html_url,
    githubCreatedAt: issue.created_at,
    githubUpdatedAt: issue.updated_at,
    githubClosedAt: issue.closed_at ?? undefined
  };
}
