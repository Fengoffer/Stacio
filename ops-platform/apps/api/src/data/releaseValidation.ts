import type { ReleaseItem } from "./types.js";
import { generateAppcastXml } from "../services/appcast.js";

export interface ReleasePreflightCheck {
  key: string;
  passed: boolean;
  message: string;
}

export interface ReleasePreflightEvidence extends Record<string, unknown> {
  checks: ReleasePreflightCheck[];
  appcastPreviewXml?: string;
}

function integerBuildNumber(value: string) {
  const trimmed = value.trim();
  return /^\d+$/.test(trimmed) ? Number.parseInt(trimmed, 10) : undefined;
}

function versionLooksValid(value: string) {
  return /^\d+\.\d+(?:\.\d+)?(?:[-.][A-Za-z0-9]+)?$/.test(value.trim());
}

function minimumSystemVersionLooksValid(value?: string) {
  return Boolean(value && /^\d+(?:\.\d+){0,2}$/.test(value.trim()));
}

function appcastPreviewLooksValid(xml: string, release: ReleaseItem) {
  return [
    "<?xml",
    "<rss",
    "<channel>",
    "<item>",
    `<sparkle:version>${release.buildNumber}</sparkle:version>`,
    `<sparkle:shortVersionString>${release.version}</sparkle:shortVersionString>`,
    "<enclosure",
    "sparkle:edSignature="
  ].every((fragment) => xml.includes(fragment));
}

function objectRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function packageSignatureCheck(packageSignatureEvidence?: Record<string, unknown>): ReleasePreflightCheck {
  if (!packageSignatureEvidence) {
    return {
      key: "package_signature_verification",
      passed: true,
      message: "Package signature verification evidence is not attached; attach it when available"
    };
  }

  const status = packageSignatureEvidence.status;
  return {
    key: "package_signature_verification",
    passed: status !== "failed",
    message:
      status === "failed"
        ? "Package signature verification failed"
        : "Package signature verification evidence is attached"
  };
}

function downloadReachabilityCheck(downloadReachabilityEvidence?: Record<string, unknown>): ReleasePreflightCheck {
  if (!downloadReachabilityEvidence) {
    return {
      key: "download_url_reachable",
      passed: false,
      message: "Download reachability evidence must be attached before publishing"
    };
  }

  const status = downloadReachabilityEvidence.status;
  return {
    key: "download_url_reachable",
    passed: status === "reachable",
    message:
      status === "reachable"
        ? "Download URL reachability evidence is attached"
        : "Download URL reachability evidence indicates the artifact is not reachable"
  };
}

function artifactSizeMatchCheck(
  release: ReleaseItem,
  downloadReachabilityEvidence?: Record<string, unknown>
): ReleasePreflightCheck {
  const contentLength = downloadReachabilityEvidence?.contentLength;
  if (typeof contentLength !== "number") {
    return {
      key: "artifact_size_matches",
      passed: false,
      message: "Download Content-Length evidence must be attached before publishing"
    };
  }

  return {
    key: "artifact_size_matches",
    passed: release.artifactSize === contentLength,
    message:
      release.artifactSize === contentLength
        ? "Download Content-Length matches registered artifact size"
        : "Download Content-Length must match registered artifact size"
  };
}

export function validateReleasePreflight(release: ReleaseItem, releases: ReleaseItem[]): ReleasePreflightCheck[] {
  const buildNumber = integerBuildNumber(release.buildNumber);
  const previousBuildNumbers = releases
    .filter(
      (candidate) =>
        candidate.id !== release.id &&
        candidate.productId === release.productId &&
        candidate.channel === release.channel
    )
    .map((candidate) => integerBuildNumber(candidate.buildNumber))
    .filter((value): value is number => value !== undefined);
  const previousMaxBuild = previousBuildNumbers.length > 0
    ? Math.max(...previousBuildNumbers)
    : undefined;

  return [
    {
      key: "artifact_url",
      passed: Boolean(release.artifactUrl?.startsWith("https://")),
      message: "Artifact URL must be HTTPS"
    },
    {
      key: "artifact_size",
      passed: typeof release.artifactSize === "number" && release.artifactSize > 0,
      message: "Artifact size must be present"
    },
    {
      key: "signature",
      passed: Boolean(release.sparkleEdDsaSignature),
      message: "Sparkle EdDSA signature must be present"
    },
    {
      key: "release_notes",
      passed: Boolean(release.releaseNotes?.trim()),
      message: "Release notes must be present"
    },
    {
      key: "build_number",
      passed: buildNumber !== undefined,
      message: "Build number must be a positive integer"
    },
    {
      key: "build_number_gt_previous",
      passed: buildNumber !== undefined && (previousMaxBuild === undefined || buildNumber > previousMaxBuild),
      message: previousMaxBuild === undefined
        ? "Build number is the first for this channel"
        : `Build number must be greater than previous ${release.channel} build ${previousMaxBuild}`
    },
    {
      key: "version_format",
      passed: versionLooksValid(release.version),
      message: "Version must look like 1.2.3 or 1.2.3-Beta"
    },
    {
      key: "minimum_system_version",
      passed: minimumSystemVersionLooksValid(release.minimumSystemVersion),
      message: "Minimum system version must look like 14.0"
    }
  ];
}

export function buildReleasePreflightEvidence(
  productName: string,
  release: ReleaseItem,
  releases: ReleaseItem[],
  existingEvidence: Record<string, unknown> = {}
): ReleasePreflightEvidence {
  const previewReleases = releases.map((candidate) =>
    candidate.id === release.id ? { ...candidate, status: "published" as const } : candidate
  );
  const appcastPreviewXml = generateAppcastXml(productName, release.channel, previewReleases);
  const packageSignatureEvidence = objectRecord(existingEvidence.packageSignatureEvidence);
  const downloadReachabilityEvidence = objectRecord(existingEvidence.downloadReachabilityEvidence);
  const checks = validateReleasePreflight(release, releases);
  checks.push({
    key: "appcast_xml",
    passed: appcastPreviewLooksValid(appcastPreviewXml, release),
    message: "Appcast preview XML must include a Sparkle item for this release"
  });
  checks.push(packageSignatureCheck(packageSignatureEvidence));
  checks.push(downloadReachabilityCheck(downloadReachabilityEvidence));
  checks.push(artifactSizeMatchCheck(release, downloadReachabilityEvidence));

  return {
    checks,
    appcastPreviewXml,
    ...(packageSignatureEvidence ? { packageSignatureEvidence } : {}),
    ...(downloadReachabilityEvidence ? { downloadReachabilityEvidence } : {})
  };
}
