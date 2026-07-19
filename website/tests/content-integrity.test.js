const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const websiteRoot = path.resolve(__dirname, '..');
const indexHTML = fs.readFileSync(path.join(websiteRoot, 'index.html'), 'utf8');
const mainJS = fs.readFileSync(path.join(websiteRoot, 'main.js'), 'utf8');
const stylesCSS = fs.readFileSync(path.join(websiteRoot, 'styles.css'), 'utf8');
const nginxConfig = fs.readFileSync(path.join(websiteRoot, 'nginx.conf'), 'utf8');

const publishedTextExtensions = new Set([
  '.html',
  '.js',
  '.md',
  '.txt',
  '.xml',
  '.webmanifest'
]);

function publishedTextFiles() {
  return fs.readdirSync(websiteRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && publishedTextExtensions.has(path.extname(entry.name)))
    .map((entry) => path.join(websiteRoot, entry.name));
}

test('homepage does not render the SEO search-intent section', () => {
  assert.doesNotMatch(indexHTML, /id="use-cases"/);
  assert.doesNotMatch(indexHTML, /data-od-id="nav-use-cases"/);
  assert.doesNotMatch(mainJS, /\buseCases\s*:/);
});

test('security panel does not render platform availability messaging', () => {
  assert.doesNotMatch(indexHTML, /Windows \/ Linux 入口保持预留状态/);
  assert.doesNotMatch(mainJS, /Windows \/ Linux entries remain planned states/);
  assert.doesNotMatch(mainJS, /proof4:/);
});

test('published website does not claim database or Redis capabilities', () => {
  const unsupportedCapability = /数据库|\bdatabase\b|\bredis(?:-cli)?\b|\bpostgres(?:ql)?\b|\bmysql\b|\bpsql\b/iu;
  const offenders = publishedTextFiles()
    .filter((file) => unsupportedCapability.test(fs.readFileSync(file, 'utf8')))
    .map((file) => path.basename(file));

  assert.deepEqual(offenders, []);
});

test('unsupported database and Redis landing pages are removed', () => {
  assert.equal(fs.existsSync(path.join(websiteRoot, 'mac-database-management-tool.html')), false);
  assert.equal(fs.existsSync(path.join(websiteRoot, 'mac-redis-management-visualization.html')), false);
});

test('top navigation omits visible FAQ and keeps Gitee after GitHub', () => {
  const navigation = indexHTML.match(/<nav class="nav-links"[\s\S]*?<\/nav>/)?.[0] ?? '';
  const itemIDs = [...navigation.matchAll(/<a[^>]+data-od-id="([^"]+)"/g)].map((match) => match[1]);

  assert.deepEqual(itemIDs, [
    'nav-features',
    'nav-workflow',
    'nav-security',
    'nav-releases',
    'nav-github',
    'nav-gitee'
  ]);
});

test('homepage hides the FAQ section while retaining FAQ structured data', () => {
  assert.doesNotMatch(indexHTML, /data-od-id="nav-faq"/);
  assert.doesNotMatch(indexHTML, /data-od-id="faq-section"/);
  assert.doesNotMatch(indexHTML, /<section class="section faq-section"/);
  assert.match(indexHTML, /"@type": "FAQPage"/);
});

test('hero preview is a theme-aware HTML and CSS Stacio workbench with demo connection data', () => {
  assert.match(indexHTML, /class="product-workbench"/);
  assert.match(indexHTML, /class="product-workbench-body"/);
  assert.match(indexHTML, /class="product-terminal-code"/);
  assert.match(indexHTML, /class="product-inspector"/);
  assert.match(indexHTML, /class="icon-orb"/);
  assert.match(indexHTML, /203\.0\.113\.42/);
  assert.match(indexHTML, /198\.51\.100\.19/);
  assert.match(indexHTML, /ops@demo-ops-01:~#/);
  assert.doesNotMatch(indexHTML, /154\.37\.212\.69|220\.163\.92\.243|172\.16\.10\.250|192\.168\.124\.100/);
  assert.doesNotMatch(indexHTML, /stacio-workbench-(?:dark|light)\.png/);
  assert.doesNotMatch(stylesCSS, /product-screenshot|product-redaction/);
  assert.equal(fs.existsSync(path.join(websiteRoot, 'assets', 'stacio-workbench-dark.png')), false);
  assert.equal(fs.existsSync(path.join(websiteRoot, 'assets', 'stacio-workbench-light.png')), false);
  assert.match(stylesCSS, /\.app-window--product \{/);
  assert.match(stylesCSS, /html\[data-theme="light"\] \.app-window--product \{/);
  assert.match(stylesCSS, /\.product-workbench-body \{/);
  assert.match(stylesCSS, /\.product-terminal-line \{/);
  assert.match(stylesCSS, /\.app-window--product \.product-workbench \{ transform: scale\(1\.8\)/);
  assert.match(stylesCSS, /@media \(max-width: 760px\) \{[\s\S]*?\.hero \{[\s\S]*?grid-template-columns: minmax\(0, 1fr\);/);
});

test('top navigation Gitee link uses the verified repository and telemetry event', () => {
  const navigation = indexHTML.match(/<nav class="nav-links"[\s\S]*?<\/nav>/)?.[0] ?? '';
  const giteeLink = navigation.match(/<a[^>]+data-od-id="nav-gitee"[^>]*>/)?.[0] ?? '';

  assert.match(giteeLink, /href="https:\/\/gitee\.com\/fengoffer\/Stacio"/);
  assert.match(giteeLink, /data-event="homepage_gitee_clicked"/);
  assert.match(navigation, /class="gitee-link"/);
  assert.match(navigation, /class="gitee-icon"/);
  assert.equal(fs.existsSync(path.join(websiteRoot, 'assets', 'gitee.svg')), true);
});

test('GitHub and Gitee repository actions open safely in a new tab', () => {
  const repositoryActions = [...indexHTML.matchAll(/<a\b[^>]*class="[^"]*\b(?:github-link|gitee-link)\b[^"]*"[^>]*>/g)].map((match) => match[0]);

  assert.equal(repositoryActions.length, 8);
  for (const action of repositoryActions) {
    assert.match(action, /target="_blank"/);
    assert.match(action, /rel="noopener noreferrer"/);
  }
});

test('hero actions place Gitee after GitHub', () => {
  const heroActions = indexHTML.match(/<div class="hero-actions"[\s\S]*?<\/div>/)?.[0] ?? '';
  const itemIDs = [...heroActions.matchAll(/<a[^>]+data-od-id="([^"]+)"/g)].map((match) => match[1]);

  assert.deepEqual(itemIDs, [
    'hero-download',
    'hero-github',
    'hero-gitee',
    'hero-release-notes'
  ]);
  assert.match(heroActions, /href="https:\/\/gitee\.com\/fengoffer\/Stacio"/);
  assert.match(heroActions, /data-event="homepage_gitee_clicked"/);
  assert.match(heroActions, /class="gitee-icon"/);
  assert.match(stylesCSS, /\.hero-actions \{[\s\S]*?gap: 8px;/);
  assert.match(stylesCSS, /\.hero-actions \.btn \{[\s\S]*?padding: 0 14px;/);
  assert.match(stylesCSS, /html\[lang="en"\] \.hero-actions \{ gap: 6px; \}/);
  assert.match(stylesCSS, /html\[lang="en"\] \.hero-actions \.btn \{ padding: 0 10px; font-size: 13px; \}/);
});

test('download console keeps its width and shows equal GitHub and Gitee buttons', () => {
  const downloadConsole = indexHTML.match(/<div class="download-console"[\s\S]*?<\/section>/)?.[0] ?? '';
  const repositoryActions = downloadConsole.match(/<div class="repository-actions"[\s\S]*?<\/div>/)?.[0] ?? '';
  const itemIDs = [...repositoryActions.matchAll(/<a[^>]+data-od-id="([^"]+)"/g)].map((match) => match[1]);

  assert.deepEqual(itemIDs, ['final-github', 'final-gitee']);
  assert.match(repositoryActions, /href="https:\/\/gitee\.com\/fengoffer\/Stacio"/);
  assert.match(repositoryActions, /data-event="homepage_gitee_clicked"/);
  assert.match(stylesCSS, /\.download-console \{[\s\S]*?width: 430px;/);
  assert.match(stylesCSS, /\.repository-actions \{[\s\S]*?grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/);
});

test('repository navigation collapses before tablet labels become cramped', () => {
  assert.match(stylesCSS, /@media \(max-width: 1000px\) \{/);
  assert.match(stylesCSS, /@media \(max-width: 1000px\) \{[\s\S]*?\.menu-button \{[\s\S]*?display: inline-flex;/);
  assert.match(stylesCSS, /@media \(max-width: 1000px\) \{[\s\S]*?body\.nav-open \.nav-links \{ display: flex; \}/);
});

test('homepage promotes Stacio 0.13.3 build 245 as the current stable release', () => {
  const heroTrust = indexHTML.match(/<div class="trust-line"[\s\S]*?<\/div>/)?.[0] ?? '';
  const releaseSection = indexHTML.match(/<section class="section" id="releases"[\s\S]*?<section class="section final-cta"/)?.[0] ?? '';
  const downloadConsole = indexHTML.match(/<div class="download-console"[\s\S]*?<\/section>/)?.[0] ?? '';

  assert.match(indexHTML, /"softwareVersion": "0\.13\.3"/);
  assert.match(indexHTML, /"processorRequirements": "Apple Silicon or Intel"/);
  assert.match(heroTrust, /Stacio 0\.13\.3 正式版/);
  assert.match(releaseSection, /Stacio 0\.13\.3 正式版/);
  assert.match(releaseSection, /构建号 245/);
  assert.match(releaseSection, /macOS 14 及以上/);
  assert.match(releaseSection, /Apple Silicon/);
  assert.match(releaseSection, /Intel Mac/);
  assert.match(downloadConsole, /id="price-label">正式版</);
  assert.match(mainJS, /const currentStableVersion = '0\.13\.3';/);
  assert.match(mainJS, /const currentStableBuildNumber = '245';/);
});

test('current release notes use the GitHub v0.13.3 release body and keep a matching fallback', () => {
  const releaseModal = indexHTML.match(/<div class="modal-backdrop"[\s\S]*?<script src=/)?.[0] ?? '';

  assert.match(mainJS, /githubReleaseEndpoint = `https:\/\/api\.github\.com\/repos\/Fengoffer\/Stacio\/releases\/tags\/v\$\{currentStableVersion\}`/);
  assert.match(mainJS, /normalizeGitHubRelease/);
  assert.doesNotMatch(mainJS, /fetch\(releasesEndpoint\)/);
  assert.match(releaseModal, /本次正式版优化本地 Agent 与终端协作体验/);
  assert.match(releaseModal, /终端审计完成标记/);
  assert.match(releaseModal, /标记分散在多段输出/);
  assert.match(releaseModal, /命令结束后自动继续并返回总结/);
  assert.match(releaseModal, /终端输出回传和会话完成状态/);
  assert.match(releaseModal, /减少排查任务停留在等待或需要手动确认/);
  assert.match(releaseModal, /Apple Silicon 与 Intel Mac 安装包/);
  assert.match(releaseModal, /远程会话、文件面板与 AI 助手的稳定性/);
  assert.match(releaseModal, /当前版本为未公证的 ad-hoc 签名包/);
  assert.match(releaseModal, /Finder 中右键 <code>Stacio\.app<\/code> 并选择“打开”/);
  assert.match(releaseModal, /下载校验/);
  assert.match(releaseModal, /623fe3b24bfe47937ad39f4f85b321fa42538f266162fa3dabcc7c25a1036ab5/);
  assert.match(releaseModal, /4824882e84fe435f0d98f2d8c4f7b967858475c2216667650a2a96b1e973d3bd/);
});

test('default current-version surfaces no longer recommend a Beta release', () => {
  const currentRecommendationFiles = [
    'index.html',
    'main.js',
    'llms.txt',
    'cron-expression-tool.html',
    'mac-server-management-tool.html',
    'mac-ssh-client.html',
    'ssh-client-mac-best.html',
    'xshell-alternative-mac.html'
  ];
  const staleRecommendation = /当前是 Beta|当前提供 macOS Apple Silicon Beta|当前官网只提供 macOS Apple Silicon Beta|BETA TRUST|Currently in Beta|Current Beta update list|current Beta download supports macOS Apple Silicon/iu;
  const offenders = currentRecommendationFiles.filter((file) => staleRecommendation.test(fs.readFileSync(path.join(websiteRoot, file), 'utf8')));

  assert.deepEqual(offenders, []);
});

test('stable download catalog exposes verified Apple Silicon/ARM and Intel object-storage assets', () => {
  const expectedAssets = [
    {
      arch: 'arm64',
      filename: 'Stacio-0.13.3-arm64.dmg',
      primaryUrl: 'https://stacio.cn-nb1.rains3.com/products/stacio/releases/stable/0.13.3/arm64/Stacio-0.13.3-arm64.dmg',
      sha256: 'd51ab1784c6a0d0ad2462111c74875d4045384ae610c2f87f37964ef9be0b49c',
      bytes: 15900263
    },
    {
      arch: 'x64',
      filename: 'Stacio-0.13.3-x86_64.dmg',
      primaryUrl: 'https://stacio.cn-nb1.rains3.com/products/stacio/releases/stable/0.13.3/x86_64/Stacio-0.13.3-x86_64.dmg',
      sha256: '2adbca74889f840fd7aad854a16137470ddf1b43429b1cf83e86e6b3dea3c885',
      bytes: 16202365
    }
  ];

  for (const asset of expectedAssets) {
    assert.ok(mainJS.includes(`${asset.arch}: {`));
    assert.ok(mainJS.includes(`filename: '${asset.filename}'`));
    assert.ok(mainJS.includes(`primaryUrl: '${asset.primaryUrl}'`));
    assert.ok(mainJS.includes(`sha256: '${asset.sha256}'`));
    assert.ok(mainJS.includes(`bytes: ${asset.bytes}`));
  }

  assert.match(mainJS, /statusByArch: \{ arm64: 'available', x64: 'available' \}/);
  assert.match(mainJS, /priceByArch: \{ arm64: 'stable', x64: 'stable' \}/);
  assert.match(indexHTML, /Apple Silicon\/ARM/);
  assert.match(indexHTML, /data-event="homepage_download_object_storage_clicked"/);
  assert.doesNotMatch(indexHTML, /id="download-fallback-button"/);
  assert.match(stylesCSS, /\.download-actions \{[\s\S]*?grid-template-columns: minmax\(0, 1fr\);/);
  assert.match(indexHTML, /id="download-filename"/);
  assert.match(indexHTML, /id="download-filesize"/);
  assert.match(indexHTML, /id="download-checksum"/);
});

test('default and architecture download routes no longer point to a Beta package', () => {
  const latestRoute = nginxConfig.match(/location = \/downloads\/latest-macos\.dmg \{[\s\S]*?\n    \}/)?.[0] ?? '';

  assert.match(latestRoute, /Stacio-0\.13\.3-arm64\.dmg/);
  assert.match(latestRoute, /stacio\.cn-nb1\.rains3\.com/);
  assert.doesNotMatch(latestRoute, /Beta/i);
  assert.match(nginxConfig, /location = \/downloads\/Stacio-0\.13\.3-arm64\.dmg \{/);
  assert.match(nginxConfig, /location = \/downloads\/Stacio-0\.13\.3-x86_64\.dmg \{/);
  assert.doesNotMatch(mainJS, /latest-macos\.dmg|0\.13\.2-Beta/i);
});
