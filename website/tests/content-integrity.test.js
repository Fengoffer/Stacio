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

test('top navigation places FAQ after releases and Gitee after GitHub', () => {
  const navigation = indexHTML.match(/<nav class="nav-links"[\s\S]*?<\/nav>/)?.[0] ?? '';
  const itemIDs = [...navigation.matchAll(/<a[^>]+data-od-id="([^"]+)"/g)].map((match) => match[1]);

  assert.deepEqual(itemIDs, [
    'nav-features',
    'nav-workflow',
    'nav-security',
    'nav-releases',
    'nav-faq',
    'nav-github',
    'nav-gitee'
  ]);
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

test('current release notes cover user outcomes and the unnotarized launch instruction', () => {
  const releaseModal = indexHTML.match(/<div class="modal-backdrop"[\s\S]*?<script src=/)?.[0] ?? '';

  assert.match(releaseModal, /终端任务完成/);
  assert.match(releaseModal, /完成标记分散在多段输出/);
  assert.match(releaseModal, /自动继续并给出总结/);
  assert.match(releaseModal, /终端输出回传与会话完成状态/);
  assert.match(releaseModal, /减少任务停留在等待状态或需要手动确认/);
  assert.match(releaseModal, /Apple Silicon 与 Intel Mac 的独立安装包/);
  assert.match(releaseModal, /远程会话、文件面板和 AI 助手的稳定性/);
  assert.match(releaseModal, /当前包未公证/);
  assert.match(releaseModal, /Finder 中右键 <code>Stacio\.app<\/code> 并选择“打开”/);
  assert.doesNotMatch(releaseModal, /CI|Tests\/|ViewController|Coordinator|Orchestrator/);
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

test('stable download catalog exposes verified Apple Silicon and Intel release assets', () => {
  const expectedAssets = [
    {
      arch: 'arm64',
      filename: 'Stacio-0.13.3-arm64.dmg',
      primaryUrl: 'https://gitee.com/fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-arm64.dmg',
      fallbackUrl: 'https://github.com/Fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-arm64.dmg',
      sha256: '623fe3b24bfe47937ad39f4f85b321fa42538f266162fa3dabcc7c25a1036ab5',
      bytes: 15911885
    },
    {
      arch: 'x64',
      filename: 'Stacio-0.13.3-x86_64.dmg',
      primaryUrl: 'https://gitee.com/fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-x86_64.dmg',
      fallbackUrl: 'https://github.com/Fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-x86_64.dmg',
      sha256: '4824882e84fe435f0d98f2d8c4f7b967858475c2216667650a2a96b1e973d3bd',
      bytes: 16213214
    }
  ];

  for (const asset of expectedAssets) {
    assert.ok(mainJS.includes(`${asset.arch}: {`));
    assert.ok(mainJS.includes(`filename: '${asset.filename}'`));
    assert.ok(mainJS.includes(`primaryUrl: '${asset.primaryUrl}'`));
    assert.ok(mainJS.includes(`fallbackUrl: '${asset.fallbackUrl}'`));
    assert.ok(mainJS.includes(`sha256: '${asset.sha256}'`));
    assert.ok(mainJS.includes(`bytes: ${asset.bytes}`));
  }

  assert.match(mainJS, /statusByArch: \{ arm64: 'available', x64: 'available' \}/);
  assert.match(mainJS, /priceByArch: \{ arm64: 'stable', x64: 'stable' \}/);
  assert.match(indexHTML, /id="download-fallback-button"/);
  assert.match(indexHTML, /id="download-filename"/);
  assert.match(indexHTML, /id="download-filesize"/);
  assert.match(indexHTML, /id="download-checksum"/);
});

test('default and architecture download routes no longer point to a Beta package', () => {
  const latestRoute = nginxConfig.match(/location = \/downloads\/latest-macos\.dmg \{[\s\S]*?\n    \}/)?.[0] ?? '';

  assert.match(latestRoute, /Stacio-0\.13\.3-arm64\.dmg/);
  assert.doesNotMatch(latestRoute, /Beta/i);
  assert.match(nginxConfig, /location = \/downloads\/Stacio-0\.13\.3-arm64\.dmg \{/);
  assert.match(nginxConfig, /location = \/downloads\/Stacio-0\.13\.3-x86_64\.dmg \{/);
  assert.doesNotMatch(mainJS, /latest-macos\.dmg|0\.13\.2-Beta/i);
});
