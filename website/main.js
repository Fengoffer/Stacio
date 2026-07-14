(() => {
      const header = document.querySelector('.site-header');
      const brandLink = document.querySelector('.brand');
      const menuButton = document.querySelector('.menu-button');
      const navLinks = document.querySelector('.nav-links');
      const workflowSteps = Array.from(document.querySelectorAll('.workflow-step'));
      const themeButton = document.querySelector('.theme-toggle');
      const languageButton = document.querySelector('.language-toggle');
      const platformButtons = Array.from(document.querySelectorAll('.platform-option'));
      const archPicker = document.getElementById('arch-picker');
      const detectedLabel = document.getElementById('detected-label');
      const priceLabel = document.getElementById('price-label');
      const packageTitle = document.getElementById('package-title');
      const packageMeta = document.getElementById('package-meta');
      const statusLabel = document.getElementById('status-label');
      const downloadButton = document.getElementById('download-button');
      const downloadCard = document.querySelector('.download-card');
      const downloadConsole = document.querySelector('.download-console');
      const releaseLinks = Array.from(document.querySelectorAll('[data-event="homepage_release_notes_clicked"]'));
      const releaseModal = document.getElementById('release-modal');
      const releasePanel = releaseModal?.querySelector('.release-modal');
      const releaseClose = releaseModal?.querySelector('.modal-close');
      const releaseDone = releaseModal?.querySelector('[data-od-id="release-modal-done"]');
      const releaseTitle = document.getElementById('release-modal-title');
      const releaseCopy = document.getElementById('release-modal-copy');
      const releaseNotes = document.getElementById('release-notes');
      const releaseGitHub = document.querySelector('[data-od-id="release-modal-github"]');
      const publicApiBase = (document.documentElement.dataset.publicApiBase || '/api/v1').replace(/\/+$/, '');
      const publicProductId = document.documentElement.dataset.publicProductId || 'stacio';
      const publicApiOrigin = new URL(publicApiBase, window.location.origin).origin;
      const publicApiUrl = (path) => `${publicApiBase}${path}`;
      const externalApiUrl = (path) => path.startsWith('/api/v1/') ? `${publicApiOrigin}${path}` : publicApiUrl(path);
      const releasesEndpoint = publicApiUrl(`/public/products/${publicProductId}/releases`);
      const telemetryEndpoint = publicApiUrl(`/public/products/${publicProductId}/telemetry`);
      const primaryMacosDownload = {
        url: '/downloads/latest-macos.dmg',
        name: 'Stacio.dmg'
      };
      const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
      let lastReleaseTrigger = null;
      let releaseNotesRequest = null;
      let latestPublicRelease = null;

      const copy = {
        zh: {
          title: 'Stacio - 原生远程操作工作台',
          meta: 'Stacio 是一个本地优先的 macOS 远程操作工作台，整合终端、远程文件、SCP 传输、隧道、设备指标、诊断和 AI 辅助排查。',
          brand: { aria: 'Stacio 首页', logoAlt: 'Stacio 标志' },
          theme: { auto: '自动', light: '浅色', dark: '深色', ariaAuto: '主题：跟随系统', ariaLight: '主题：浅色', ariaDark: '主题：深色' },
          nav: { aria: '主导航', features: '能力', workflow: '流程', security: '安全', releases: '版本', download: '下载', menu: '打开导航' },
          hero: { eyebrow: 'LOCAL-FIRST MACOS WORKBENCH', tagline: 'Native remote operations station for macOS.', copy: '把终端、远程文件、SCP 传输、隧道、设备看板和 AI 辅助排查放进一个本地优先的 Mac 工作台。', download: '下载适合当前设备的版本', releaseNotes: '查看更新日志', trustAria: '产品状态', platform: 'macOS 14+ 当前可用', distribution: 'GitHub Releases / DMG' },
          workflow: { eyebrow: 'WORKFLOW', title: '一次远程操作，从连接到解决。', lead: 'Stacio 把 SSH、文件、传输、隧道和诊断放进同一个操作循环，减少在终端、Finder、脚本和笔记之间来回切换。', connectTitle: 'Connect', connectCopy: '从保存会话或快速连接进入本地/远程终端。', inspectTitle: 'Inspect', inspectCopy: '查看终端上下文、远程目录、日志和设备状态。', transferTitle: 'Transfer', transferCopy: '通过 Stacio 内置 SCP 工作流上传、下载和跟踪传输。', tunnelTitle: 'Tunnel', tunnelCopy: '创建并监控 SSH 隧道，避免后台连接失控。', resolveTitle: 'Resolve', resolveCopy: '结合诊断信息和 AI 建议完成排查。' },
          features: { eyebrow: 'CAPABILITIES', title: '不是终端外壳，是完整远程工作台。', lead: '每个能力块都对应真实产品表面：终端、文件、传输、隧道、指标、AI 建议和本地凭据管理。', terminalTitle: 'Terminal Workspace', terminalCopy: '本地终端、远程 SSH、标签页、会话侧栏和终端上下文联动。', filesTitle: 'Remote Files / SCP', filesCopy: '浏览远程目录、编辑文本文件、上传下载、查看传输队列。默认走 Stacio 内置 SCP / SSH 路径。', tunnelsTitle: 'Tunnels', tunnelsCopy: '管理 local / remote / dynamic forward，显示状态、日志和关闭提醒。', metricsTitle: 'Device Metrics', metricsCopy: '查看 CPU、内存、磁盘、网络和 I/O 指标，辅助判断机器状态。', aiTitle: 'AI-Assisted Troubleshooting', aiCopy: 'AI 可以读取可见终端上下文，生成排查建议和可执行命令卡片。', aiCue: '建议命令需确认后执行 · sensitive actions stay controlled', securityTitle: 'Local-First Security', securityCopy: '会话数据保存在本地，凭据走 macOS Keychain，诊断和日志默认脱敏。' },
          security: { eyebrow: 'SECURITY', title: '本地优先，敏感操作始终由用户确认。', lead: 'Stacio 把远程工作流收进同一个 macOS 应用，但凭据、会话和敏感动作仍遵循本地优先与显式确认。', proof1: '凭据交给 macOS Keychain，本地会话元数据不默认外传。', proof2: 'AI 建议只生成排查思路和命令卡片，敏感命令需要用户确认后执行。', proof3: '诊断、日志和设备信息默认脱敏，减少复制粘贴排查时的泄露风险。', proof4: 'Windows / Linux 入口保持预留状态，不写成已开放安装包。' },
          releases: { eyebrow: 'BETA TRUST', title: '当前是 Beta，适合先试核心工作流。', lead: 'Stacio 正在快速迭代。Beta 版本适合试用核心工作流，并通过 GitHub Issues 或应用反馈提交问题。', statusLabel: 'Status', statusCopy: '围绕远程操作主链路持续迭代。', platformLabel: 'Platform', platformValue: 'macOS 14+ 当前可用', platformCopy: '当前仅提供 macOS Apple Silicon 安装包，Intel、Windows 和 Linux 版本敬请期待。', distributionLabel: 'Distribution', distributionValue: 'GitHub Releases / DMG', distributionCopy: '下载、更新日志和反馈路径保持公开可查。' },
          download: { eyebrow: 'DOWNLOAD', title: '下载适合当前设备的 Stacio。', copy: '页面会自动识别你的系统和 CPU 架构，优先显示匹配版本；也可以手动切换到 macOS、Windows 或 Linux。', detectedLabel: '已识别', platformAria: '选择下载平台', archAria: '选择 CPU 架构', github: '查看 GitHub', releaseNotes: '阅读更新日志', available: '当前可用', planned: '敬请期待', beta: 'Beta', pendingPrice: '敬请期待', downloadAction: '下载 Stacio DMG', notifyAction: '敬请期待' },
          modal: { eyebrow: 'UPDATE NOTES', title: '当前 Beta 更新清单', copy: '这些是官网当前公开给 Beta 用户的更新重点；完整版本记录会继续同步到 GitHub Releases。', close: '关闭更新清单', itemWorkbenchTitle: '远程工作台主链路', itemWorkbenchCopy: '终端、远程文件、SCP 传输、隧道和设备指标整合到同一个 macOS 工作区。', itemDownloadTitle: '下载识别与平台预留', itemDownloadCopy: '自动识别系统与 CPU 架构，macOS 版本优先展示，Windows / Linux 保留发布计划状态。', itemThemeTitle: 'Liquid Glass 与双主题', itemThemeCopy: '导航、卡片和下载面板统一到 macOS 27 风格，并默认跟随系统深浅色。', itemFeedbackTitle: 'Beta 反馈路径', itemFeedbackCopy: 'GitHub、更新记录和问题反馈入口保持公开，便于追踪每次修正。', github: '打开 GitHub Releases', done: '知道了' },
          footer: { tagline: 'Stacio · Native remote operations station for macOS.', download: '下载', releaseNotes: '更新日志', feedback: '反馈问题' }
        },
        en: {
          title: 'Stacio - Native Remote Operations Station',
          meta: 'Stacio is a local-first macOS remote operations workbench that brings terminal, remote files, SCP transfer, tunnels, device metrics, diagnostics, and AI-assisted troubleshooting together.',
          brand: { aria: 'Stacio home', logoAlt: 'Stacio logo' },
          theme: { auto: 'Auto', light: 'Light', dark: 'Dark', ariaAuto: 'Theme: follow system', ariaLight: 'Theme: light', ariaDark: 'Theme: dark' },
          nav: { aria: 'Main navigation', features: 'Features', workflow: 'Workflow', security: 'Security', releases: 'Releases', download: 'Download', menu: 'Open navigation' },
          hero: { eyebrow: 'LOCAL-FIRST MACOS WORKBENCH', tagline: 'Native remote operations station for macOS.', copy: 'Bring terminal, remote files, SCP transfers, tunnels, device metrics, and AI-assisted troubleshooting into one local-first Mac workbench.', download: 'Download for this device', releaseNotes: 'View release notes', trustAria: 'Product status', platform: 'macOS 14+ available now', distribution: 'GitHub Releases / DMG' },
          workflow: { eyebrow: 'WORKFLOW', title: 'One remote operation, from connect to resolve.', lead: 'Stacio puts SSH, files, transfers, tunnels, and diagnostics into one operating loop, reducing the jump between Terminal, Finder, scripts, and notes.', connectTitle: 'Connect', connectCopy: 'Start from saved sessions or quick connect into local and remote terminals.', inspectTitle: 'Inspect', inspectCopy: 'Read terminal context, remote directories, logs, and device status together.', transferTitle: 'Transfer', transferCopy: 'Upload, download, and track transfers through Stacio built-in SCP workflows.', tunnelTitle: 'Tunnel', tunnelCopy: 'Create and monitor SSH tunnels so background connections stay visible.', resolveTitle: 'Resolve', resolveCopy: 'Use diagnostics and AI suggestions to finish troubleshooting with control.' },
          features: { eyebrow: 'CAPABILITIES', title: 'Not a terminal wrapper. A complete remote workbench.', lead: 'Each capability maps to a real product surface: terminal, files, transfers, tunnels, metrics, AI suggestions, and local credential management.', terminalTitle: 'Terminal Workspace', terminalCopy: 'Local terminal, remote SSH, tabs, session sidebar, and terminal context stay connected.', filesTitle: 'Remote Files / SCP', filesCopy: 'Browse remote directories, edit text files, upload, download, and track the transfer queue. Stacio defaults to built-in SCP / SSH flows.', tunnelsTitle: 'Tunnels', tunnelsCopy: 'Manage local, remote, and dynamic forwarding with status, logs, and shutdown reminders.', metricsTitle: 'Device Metrics', metricsCopy: 'Read CPU, memory, disk, network, and I/O metrics to understand machine state.', aiTitle: 'AI-Assisted Troubleshooting', aiCopy: 'AI can read visible terminal context and produce troubleshooting suggestions plus command cards.', aiCue: 'Commands require confirmation · sensitive actions stay controlled', securityTitle: 'Local-First Security', securityCopy: 'Sessions stay local, credentials use macOS Keychain, and diagnostics plus logs are redacted by default.' },
          security: { eyebrow: 'SECURITY', title: 'Local-first by default, sensitive actions stay confirmed.', lead: 'Stacio brings remote workflows into one macOS app while credentials, sessions, and sensitive actions stay local-first and explicitly controlled.', proof1: 'Credentials use macOS Keychain, and local session metadata is not sent out by default.', proof2: 'AI produces troubleshooting ideas and command cards; sensitive commands still require user confirmation.', proof3: 'Diagnostics, logs, and device data are redacted by default to reduce copy-paste leakage during troubleshooting.', proof4: 'Windows / Linux entries remain planned states, without pretending those packages are available today.' },
          releases: { eyebrow: 'BETA TRUST', title: 'Currently in Beta, ready for core workflows.', lead: 'Stacio is moving quickly. The Beta is for trying core workflows and sending issues through GitHub Issues or in-app feedback.', statusLabel: 'Status', statusCopy: 'Iterating around the main remote-operations loop.', platformLabel: 'Platform', platformValue: 'macOS 14+ available now', platformCopy: 'Only the macOS Apple Silicon installer is available today. Intel, Windows, and Linux builds are coming soon.', distributionLabel: 'Distribution', distributionValue: 'GitHub Releases / DMG', distributionCopy: 'Downloads, release notes, and feedback paths remain public and traceable.' },
          download: { eyebrow: 'DOWNLOAD', title: 'Download the right Stacio build for this device.', copy: 'The page detects your OS and CPU architecture, shows the matching build first, and still lets you switch between macOS, Windows, and Linux manually.', detectedLabel: 'Detected', platformAria: 'Choose download platform', archAria: 'Choose CPU architecture', github: 'View GitHub', releaseNotes: 'Read release notes', available: 'Available now', planned: 'Coming soon', beta: 'Beta', pendingPrice: 'Coming soon', downloadAction: 'Download Stacio DMG', notifyAction: 'Coming soon' },
          modal: { eyebrow: 'UPDATE NOTES', title: 'Current Beta update list', copy: 'These are the update highlights currently published for Beta users. Full release records will continue on GitHub Releases.', close: 'Close update list', itemWorkbenchTitle: 'Remote workbench loop', itemWorkbenchCopy: 'Terminal, remote files, SCP transfers, tunnels, and device metrics are integrated into one macOS workspace.', itemDownloadTitle: 'Download detection and platform planning', itemDownloadCopy: 'The page detects OS and CPU architecture, prioritizes the macOS build, and keeps Windows / Linux release-plan states visible.', itemThemeTitle: 'Liquid Glass and dual themes', itemThemeCopy: 'Navigation, cards, and the download panel follow the macOS 27 visual language and default to system light / dark mode.', itemFeedbackTitle: 'Beta feedback path', itemFeedbackCopy: 'GitHub, update records, and issue reporting stay public so each fix remains traceable.', github: 'Open GitHub Releases', done: 'Got it' },
          footer: { tagline: 'Stacio · Native remote operations station for macOS.', download: 'Download', releaseNotes: 'Release Notes', feedback: 'Report issue' }
        }
      };

      const packages = {
        macos: {
          label: 'macOS',
          formats: { arm64: 'DMG · macOS 14+ · Apple Silicon', x64: 'DMG · macOS 14+ · Intel' },
          arch: ['arm64', 'x64'],
          statusByArch: { arm64: 'available', x64: 'planned' },
          priceByArch: { arm64: 'Beta', x64: 'planned' },
          hrefByArch: { arm64: primaryMacosDownload.url, x64: '#download' },
          downloadName: primaryMacosDownload.name
        },
        windows: {
          label: 'Windows',
          formats: { x64: 'MSI · Windows 11 · x64', arm64: 'MSIX · Windows on ARM · arm64' },
          arch: ['x64', 'arm64'],
          statusByArch: { x64: 'planned', arm64: 'planned' },
          priceByArch: { x64: 'planned', arm64: 'planned' },
          hrefByArch: { x64: '#download', arm64: '#download' }
        },
        linux: {
          label: 'Linux',
          formats: { x64: 'AppImage / deb · x64', arm64: 'AppImage / deb · arm64' },
          arch: ['x64', 'arm64'],
          statusByArch: { x64: 'planned', arm64: 'planned' },
          priceByArch: { x64: 'planned', arm64: 'planned' },
          hrefByArch: { x64: '#download', arm64: '#download' }
        }
      };

      const state = {
        lang: localStorage.getItem('stacio:lang') || ((navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en'),
        theme: localStorage.getItem('stacio:theme') || 'auto',
        platform: 'macos',
        arch: 'arm64'
      };
      if (!['auto', 'light', 'dark'].includes(state.theme)) state.theme = 'auto';

      const persistentId = (key) => {
        try {
          const current = localStorage.getItem(key);
          if (current) return current;
          const next = crypto.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
          localStorage.setItem(key, next);
          return next;
        } catch (_) {
          return crypto.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
        }
      };
      const visitorId = persistentId('stacio:website-visitor');
      const sessionId = persistentId('stacio:website-session');
      const trackWebsiteEvent = (type, extra = {}) => {
        const payload = {
          eventId: crypto.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
          type,
          path: window.location.pathname || '/',
          visitorId,
          sessionId,
          platform: state.platform,
          architecture: state.arch,
          referrer: document.referrer || undefined,
          ...extra
        };
        const body = JSON.stringify(payload);
        try {
          if (navigator.sendBeacon) {
            navigator.sendBeacon(telemetryEndpoint, new Blob([body], { type: 'application/json' }));
            return;
          }
          void fetch(telemetryEndpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body,
            keepalive: true
          });
        } catch (_) {}
      };

      const themeMedia = window.matchMedia('(prefers-color-scheme: dark)');

      const getCopy = (key) => key.split('.').reduce((value, part) => value && value[part], copy[state.lang]) || key;
      const formatCopy = (key, values) => Object.entries(values).reduce((text, [name, value]) => text.replace(`{${name}}`, value), getCopy(key));

      const detectDevice = () => {
        const ua = navigator.userAgent.toLowerCase();
        const platform = navigator.userAgentData?.platform?.toLowerCase() || navigator.platform?.toLowerCase() || '';
        const source = `${ua} ${platform}`;
        let os = 'macos';
        if (source.includes('win')) os = 'windows';
        else if (source.includes('linux') || source.includes('x11')) os = 'linux';
        const arch = source.includes('arm') || source.includes('aarch64') || source.includes('apple') ? 'arm64' : source.includes('x86_64') || source.includes('win64') || source.includes('amd64') ? 'x64' : os === 'macos' ? 'arm64' : 'x64';
        return { os, arch };
      };

      const refineArchitecture = async () => {
        if (!navigator.userAgentData?.getHighEntropyValues) return;
        try {
          const values = await navigator.userAgentData.getHighEntropyValues(['architecture']);
          const architecture = (values.architecture || '').toLowerCase();
          if (architecture.includes('arm')) state.arch = 'arm64';
          else if (architecture.includes('x86')) state.arch = 'x64';
          if (!packages[state.platform].arch.includes(state.arch)) state.arch = packages[state.platform].arch[0];
          renderDownload();
        } catch (_) {}
      };

      const applyLanguage = () => {
        document.documentElement.lang = state.lang === 'zh' ? 'zh-CN' : 'en';
        document.title = copy[state.lang].title;
        document.querySelector('meta[name="description"]')?.setAttribute('content', copy[state.lang].meta);
        document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = getCopy(el.dataset.i18n); });
        document.querySelectorAll('[data-i18n-attr]').forEach((el) => {
          el.dataset.i18nAttr.split(',').forEach((pair) => {
            const [attr, key] = pair.split(':').map((item) => item.trim());
            if (attr && key) el.setAttribute(attr, getCopy(key));
          });
        });
        if (languageButton) languageButton.textContent = state.lang === 'zh' ? 'EN' : '中';
        updateThemeButton();
        renderDownload();
      };

      const resolveTheme = () => state.theme === 'auto' ? (themeMedia.matches ? 'dark' : 'light') : state.theme;

      const themeIcons = {
        auto: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9"/><path d="M12 3v4"/><path d="m16 4 2 2-2 2"/></svg>',
        light: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></svg>',
        dark: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5 7 7 0 1 0 20.5 14.5Z"/></svg>'
      };

      const applyTheme = () => {
        const resolved = resolveTheme();
        document.documentElement.dataset.theme = resolved;
        document.querySelector('meta[name="theme-color"]')?.setAttribute('content', resolved === 'dark' ? '#141923' : '#f4f7fb');
        updateThemeButton();
      };

      const updateThemeButton = () => {
        if (!themeButton) return;
        const label = getCopy(`theme.${state.theme}`);
        themeButton.innerHTML = themeIcons[state.theme] || themeIcons.auto;
        themeButton.setAttribute('aria-label', getCopy(`theme.aria${state.theme.charAt(0).toUpperCase()}${state.theme.slice(1)}`));
        themeButton.setAttribute('title', label);
        themeButton.dataset.mode = state.theme;
      };

      const renderDownload = () => {
        const pkg = packages[state.platform];
        if (!pkg) return;
        if (!pkg.arch.includes(state.arch)) state.arch = pkg.arch[0];
        platformButtons.forEach((button) => {
          const selected = button.dataset.platform === state.platform;
          button.classList.toggle('is-selected', selected);
          button.setAttribute('aria-selected', String(selected));
          button.setAttribute('tabindex', selected ? '0' : '-1');
        });
        const archLabel = state.arch === 'x64' ? 'Intel / x64' : 'ARM64';
        archPicker.innerHTML = pkg.arch.map((arch) => {
          const selected = arch === state.arch;
          const label = arch === 'x64' ? 'Intel / x64' : 'ARM64';
          return `<button class="arch-option${selected ? ' is-selected' : ''}" type="button" data-arch="${arch}" aria-pressed="${selected}">${label}</button>`;
        }).join('');
        detectedLabel.textContent = `${pkg.label} · ${archLabel}`;
        packageTitle.textContent = `Stacio for ${pkg.label}`;
        packageMeta.textContent = pkg.formats[state.arch];
        const status = pkg.statusByArch?.[state.arch] || 'planned';
        const price = pkg.priceByArch?.[state.arch] || status;
        const href = pkg.hrefByArch?.[state.arch] || '#download';
        const available = status === 'available';
        downloadCard?.classList.toggle('is-planned', !available);
        statusLabel.textContent = available ? getCopy('download.available') : getCopy('download.planned');
        priceLabel.textContent = price === 'Beta' ? price : getCopy('download.pendingPrice');
        downloadButton.textContent = available ? getCopy('download.downloadAction') : getCopy('download.notifyAction');
        downloadButton.href = href;
        downloadButton.dataset.availability = available ? 'available' : 'planned';
        downloadButton.setAttribute('aria-disabled', String(!available));
        downloadButton.removeAttribute('download');
      };

      const pulseDownload = () => {
        if (!downloadConsole || reduceMotion.matches) return;
        downloadConsole.classList.remove('is-updating');
        void downloadConsole.offsetWidth;
        downloadConsole.classList.add('is-updating');
      };

      const focusableModalItems = () => Array.from(releaseModal?.querySelectorAll('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])') || []);

      const appendInlineMarkdown = (parent, text) => {
        text.split(/(`[^`]+`)/g).forEach((part) => {
          if (!part) return;
          if (part.startsWith('`') && part.endsWith('`')) {
            const code = document.createElement('code');
            code.textContent = part.slice(1, -1);
            parent.append(code);
            return;
          }
          parent.append(document.createTextNode(part));
        });
      };

      const parseReleaseBody = (body) => {
        const lines = String(body || '').split(/\r?\n/);
        let title = '';
        let lead = '';
        const content = [];
        let sawTitle = false;
        let sawLead = false;
        lines.forEach((line) => {
          const trimmed = line.trim();
          if (!sawTitle && /^#\s+/.test(trimmed)) {
            title = trimmed.replace(/^#\s+/, '');
            sawTitle = true;
            return;
          }
          if (!sawLead) {
            if (!trimmed) return;
            if (/^#{2,4}\s+/.test(trimmed) || /^-\s+/.test(trimmed)) {
              sawLead = true;
              content.push(line);
              return;
            }
            lead = trimmed;
            sawLead = true;
            return;
          }
          content.push(line);
        });
        return { title, lead, content };
      };

      const renderReleaseMarkdown = (lines, target) => {
        if (!target) return;
        target.innerHTML = '';
        let section = null;
        let list = null;
        let lastItem = null;
        const ensureSection = () => {
          if (!section) {
            section = document.createElement('section');
            section.className = 'release-note-section';
            target.append(section);
          }
          return section;
        };
        const closeList = () => {
          list = null;
          lastItem = null;
        };
        lines.forEach((line) => {
          const trimmed = line.trim();
          if (!trimmed) {
            closeList();
            return;
          }
          if (/^##\s+/.test(trimmed)) {
            section = document.createElement('section');
            section.className = 'release-note-section';
            const heading = document.createElement('h3');
            appendInlineMarkdown(heading, trimmed.replace(/^##\s+/, ''));
            section.append(heading);
            target.append(section);
            closeList();
            return;
          }
          if (/^###\s+/.test(trimmed)) {
            const heading = document.createElement('h4');
            appendInlineMarkdown(heading, trimmed.replace(/^###\s+/, ''));
            ensureSection().append(heading);
            closeList();
            return;
          }
          const nestedBullet = /^\s+-\s+/.test(line) && !/^-/.test(line);
          if (/^-\s+/.test(trimmed) || nestedBullet) {
            const owner = ensureSection();
            if (nestedBullet && lastItem) {
              const nestedList = lastItem.querySelector('ul') || document.createElement('ul');
              if (!nestedList.parentNode) lastItem.append(nestedList);
              const nestedItem = document.createElement('li');
              appendInlineMarkdown(nestedItem, trimmed.replace(/^-\s+/, ''));
              nestedList.append(nestedItem);
              return;
            }
            if (!list) {
              list = document.createElement('ul');
              owner.append(list);
            }
            const item = document.createElement('li');
            appendInlineMarkdown(item, trimmed.replace(/^-\s+/, ''));
            list.append(item);
            lastItem = item;
            return;
          }
          const paragraph = document.createElement('p');
          appendInlineMarkdown(paragraph, trimmed);
          ensureSection().append(paragraph);
          closeList();
        });
      };

      const renderReleaseNotes = (release) => {
        if (!release) return;
        const parsed = parseReleaseBody(release.releaseNotes || '');
        if (releaseTitle) releaseTitle.textContent = parsed.title || `Stacio ${release.version || 'Beta'} 更新清单`;
        if (releaseCopy && parsed.lead) {
          releaseCopy.textContent = '';
          appendInlineMarkdown(releaseCopy, parsed.lead);
        }
        if (parsed.content.length > 0) renderReleaseMarkdown(parsed.content, releaseNotes);
      };

      const configureLatestPublicRelease = (release) => {
        if (!release?.downloadUrl) return;
        latestPublicRelease = release;
        packages.macos.hrefByArch.arm64 = `${externalApiUrl(release.downloadUrl)}?${new URLSearchParams({
          visitorId,
          sessionId,
          platform: 'macOS',
          architecture: 'arm64'
        })}`;
        packages.macos.downloadName = release.artifactName || 'Stacio.dmg';
        renderDownload();
      };

      const loadLatestReleaseNotes = () => {
        if (releaseNotesRequest || !releaseNotes) return releaseNotesRequest;
        releaseNotesRequest = fetch(releasesEndpoint)
          .then((response) => response.ok ? response.json() : Promise.reject(new Error(`Release catalog request failed: ${response.status}`)))
          .then((payload) => {
            const releases = Array.isArray(payload?.data?.releases) ? payload.data.releases : [];
            const release = releases.find((item) => item.channel === 'stable' && item.downloadAvailable)
              || releases.find((item) => item.downloadAvailable)
              || null;
            configureLatestPublicRelease(release);
            renderReleaseNotes(release);
          })
          .catch(() => {
            releaseNotesRequest = null;
          });
        return releaseNotesRequest;
      };

      const openReleaseModal = (trigger) => {
        if (!releaseModal || !releasePanel) return;
        loadLatestReleaseNotes();
        lastReleaseTrigger = trigger || document.activeElement;
        releaseModal.hidden = false;
        document.body.classList.add('modal-open');
        requestAnimationFrame(() => {
          releaseModal.classList.add('is-open');
          releasePanel.focus({ preventScroll: true });
        });
      };

      const closeReleaseModal = () => {
        if (!releaseModal) return;
        releaseModal.classList.remove('is-open');
        document.body.classList.remove('modal-open');
        const restoreFocus = () => {
          releaseModal.hidden = true;
          if (lastReleaseTrigger && typeof lastReleaseTrigger.focus === 'function') lastReleaseTrigger.focus({ preventScroll: true });
        };
        if (reduceMotion.matches) restoreFocus();
        else window.setTimeout(restoreFocus, 220);
      };

      const setupReveals = () => {
        const revealTargets = Array.from(document.querySelectorAll('.section-head, .workflow-step, .capability-card, .why-panel, .beta-card, .final-cta'));
        revealTargets.forEach((el, index) => {
          el.dataset.motion = 'reveal';
          el.style.setProperty('--motion-delay', `${Math.min(index % 5, 4) * 55}ms`);
        });
        if (reduceMotion.matches || !('IntersectionObserver' in window)) {
          revealTargets.forEach((el) => el.classList.add('is-visible'));
          return;
        }
        const observer = new IntersectionObserver((entries) => {
          entries.forEach((entry) => {
            if (!entry.isIntersecting) return;
            entry.target.classList.add('is-visible');
            observer.unobserve(entry.target);
          });
        }, { threshold: 0.14, rootMargin: '0px 0px -8% 0px' });
        revealTargets.forEach((el) => observer.observe(el));
      };

      const setScrolled = () => {
        header.classList.toggle('is-scrolled', window.scrollY > 8);
      };

      const scrollToSection = (target) => {
        if (!target) return;
        const label = target.querySelector('.eyebrow') || target;
        const headerBottom = header ? header.getBoundingClientRect().bottom : 0;
        const top = label.getBoundingClientRect().top + window.scrollY - headerBottom - 2;
        window.scrollTo({ top: Math.max(0, top), behavior: reduceMotion.matches ? 'auto' : 'smooth' });
      };

      window.addEventListener('scroll', setScrolled, { passive: true });
      setScrolled();

      menuButton?.addEventListener('click', () => {
        const open = !document.body.classList.contains('nav-open');
        document.body.classList.toggle('nav-open', open);
        menuButton.setAttribute('aria-expanded', String(open));
      });

      navLinks?.addEventListener('click', (event) => {
        const link = event.target.closest('a[href^="#"]');
        if (!link) return;
        const target = document.querySelector(link.getAttribute('href'));
        if (!target) return;
        event.preventDefault();
        document.body.classList.remove('nav-open');
        menuButton?.setAttribute('aria-expanded', 'false');
        scrollToSection(target);
        history.replaceState(null, '', link.getAttribute('href'));
      });

      const returnHome = (event) => {
        event.preventDefault();
        event.stopPropagation();
        document.body.classList.remove('nav-open');
        menuButton?.setAttribute('aria-expanded', 'false');
        if (location.hash) history.replaceState(null, '', location.pathname + location.search);
        window.scrollTo({ top: 0, left: 0, behavior: 'auto' });
        requestAnimationFrame(() => window.scrollTo({ top: 0, left: 0, behavior: 'auto' }));
      };

      document.addEventListener('click', (event) => {
        const link = event.target.closest?.('[data-od-id="brand-link"]');
        if (!link) return;
        returnHome(event);
      }, true);

      workflowSteps.forEach((step) => {
        step.addEventListener('mouseenter', () => {
          workflowSteps.forEach((item) => item.classList.toggle('is-active', item === step));
        });
        step.addEventListener('focusin', () => {
          workflowSteps.forEach((item) => item.classList.toggle('is-active', item === step));
        });
        step.setAttribute('tabindex', '0');
      });

      languageButton?.addEventListener('click', () => {
        state.lang = state.lang === 'zh' ? 'en' : 'zh';
        localStorage.setItem('stacio:lang', state.lang);
        applyLanguage();
      });

      themeButton?.addEventListener('click', () => {
        const order = ['auto', 'light', 'dark'];
        state.theme = order[(order.indexOf(state.theme) + 1) % order.length];
        localStorage.setItem('stacio:theme', state.theme);
        applyTheme();
      });

      themeMedia.addEventListener?.('change', () => {
        if (state.theme === 'auto') applyTheme();
      });

      platformButtons.forEach((button) => {
        button.addEventListener('click', () => {
          state.platform = button.dataset.platform;
          state.arch = packages[state.platform].arch[0];
          renderDownload();
          pulseDownload();
        });

        button.addEventListener('keydown', (event) => {
          if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
          event.preventDefault();
          const current = platformButtons.indexOf(button);
          const next = event.key === 'Home' ? 0 : event.key === 'End' ? platformButtons.length - 1 : event.key === 'ArrowRight' ? (current + 1) % platformButtons.length : (current - 1 + platformButtons.length) % platformButtons.length;
          platformButtons[next].focus();
          platformButtons[next].click();
        });
      });

      document.addEventListener('keydown', (event) => {
        if (releaseModal?.classList.contains('is-open') && event.key === 'Tab') {
          const items = focusableModalItems();
          if (!items.length) return;
          const first = items[0];
          const last = items[items.length - 1];
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
          }
          return;
        }
        if (event.key !== 'Escape') return;
        if (releaseModal?.classList.contains('is-open')) closeReleaseModal();
        document.body.classList.remove('nav-open');
        menuButton?.setAttribute('aria-expanded', 'false');
      });

      archPicker?.addEventListener('click', (event) => {
        const button = event.target.closest('[data-arch]');
        if (!button) return;
        state.arch = button.dataset.arch;
        renderDownload();
        pulseDownload();
      });

      downloadButton?.addEventListener('click', (event) => {
        if (downloadButton.dataset.availability !== 'planned') return;
        event.preventDefault();
        event.stopPropagation();
        pulseDownload();
      });

      releaseLinks.forEach((link) => {
        link.addEventListener('click', (event) => {
          event.preventDefault();
          document.body.classList.remove('nav-open');
          menuButton?.setAttribute('aria-expanded', 'false');
          openReleaseModal(link);
        });
      });

      releaseClose?.addEventListener('click', closeReleaseModal);
      releaseDone?.addEventListener('click', closeReleaseModal);
      releaseModal?.addEventListener('click', (event) => {
        if (event.target === releaseModal) closeReleaseModal();
      });

      document.querySelectorAll('[data-event]').forEach((el) => {
        el.addEventListener('click', () => {
          if (!reduceMotion.matches) {
            el.classList.remove('is-pressed');
            void el.offsetWidth;
            el.classList.add('is-pressed');
          }
          window.stacioEvents = window.stacioEvents || [];
          window.stacioEvents.push({ name: el.dataset.event, at: new Date().toISOString() });
          if (el.dataset.event?.includes('github')) {
            trackWebsiteEvent('github_release_clicked', { releaseId: latestPublicRelease?.id });
          }
        });
      });

      const detected = detectDevice();
      state.platform = detected.os;
      state.arch = packages[detected.os]?.arch.includes(detected.arch) ? detected.arch : packages[detected.os]?.arch[0] || 'arm64';
      applyTheme();
      applyLanguage();
      setupReveals();
      trackWebsiteEvent('page_view');
      loadLatestReleaseNotes();
      refineArchitecture();
    })();
