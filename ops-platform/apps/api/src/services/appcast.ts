import type { ReleaseItem } from "../data/types.js";

function escapeXml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

export function generateAppcastXml(productName: string, channel: string, releases: ReleaseItem[]) {
  const published = releases
    .filter((release) => release.channel === channel && release.status === "published")
    .sort((left, right) => right.buildNumber.localeCompare(left.buildNumber, undefined, { numeric: true }));

  const items = published
    .map((release) => {
      const url = escapeXml(release.artifactUrl ?? release.artifactName);
      const title = escapeXml(`${productName} ${release.version}`);
      const notes = escapeXml(release.releaseNotes ?? "");
      const signature = release.sparkleEdDsaSignature
        ? ` sparkle:edSignature="${escapeXml(release.sparkleEdDsaSignature)}"`
        : "";
      const length = release.artifactSize ? ` length="${release.artifactSize}"` : "";
      return [
        "    <item>",
        `      <title>${title}</title>`,
        `      <sparkle:version>${escapeXml(release.buildNumber)}</sparkle:version>`,
        `      <sparkle:shortVersionString>${escapeXml(release.version)}</sparkle:shortVersionString>`,
        release.minimumSystemVersion ? `      <sparkle:minimumSystemVersion>${escapeXml(release.minimumSystemVersion)}</sparkle:minimumSystemVersion>` : "",
        `      <description>${notes}</description>`,
        `      <enclosure url="${url}"${length} type="${escapeXml(release.artifactType ?? "application/octet-stream")}"${signature} />`,
        "    </item>"
      ]
        .filter(Boolean)
        .join("\n");
    })
    .join("\n");

  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${escapeXml(productName)} ${escapeXml(channel)} updates</title>
${items}
  </channel>
</rss>`;
}
