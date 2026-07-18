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
      const downloadButtonLabel = document.getElementById('download-button-label');
      const downloadVerification = document.getElementById('download-verification');
      const downloadFilename = document.getElementById('download-filename');
      const downloadFilesize = document.getElementById('download-filesize');
      const downloadChecksum = document.getElementById('download-checksum');
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
      const publicApiUrl = (path) => `${publicApiBase}${path}`;
      const telemetryEndpoint = publicApiUrl(`/public/products/${publicProductId}/telemetry`);
      const stableMacosDownloads = {
        arm64: {
          filename: 'Stacio-0.13.3-arm64.dmg',
          primaryUrl: 'https://stacio.cn-nb1.rains3.com/products/stacio/releases/stable/0.13.3/arm64/Stacio-0.13.3-arm64.dmg',
          sha256: 'd51ab1784c6a0d0ad2462111c74875d4045384ae610c2f87f37964ef9be0b49c',
          bytes: 15900263
        },
        x64: {
          filename: 'Stacio-0.13.3-x86_64.dmg',
          primaryUrl: 'https://stacio.cn-nb1.rains3.com/products/stacio/releases/stable/0.13.3/x86_64/Stacio-0.13.3-x86_64.dmg',
          sha256: '2adbca74889f840fd7aad854a16137470ddf1b43429b1cf83e86e6b3dea3c885',
          bytes: 16202365
        }
      };
      const currentStableVersion = '0.13.3';
      const currentStableBuildNumber = '245';
      const githubReleaseEndpoint = `https://api.github.com/repos/Fengoffer/Stacio/releases/tags/v${currentStableVersion}`;
      const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
      let lastReleaseTrigger = null;
      let releaseNotesRequest = null;
      let latestPublicRelease = null;

      const copy = {
        zh: {
          title: 'Stacio - Mac SSH 客户端与远程运维工作台',
          meta: 'Stacio 是原生 macOS SSH 客户端与服务器远程运维工作台，整合 SSH/Telnet/串口连接、终端分屏与同步执行、远程文件、SCP 传输、SSH 隧道、设备监控、内置浏览器和 AI 辅助运维。',
          brand: { aria: 'Stacio 首页', logoAlt: 'Stacio 标志' },
          theme: { auto: '自动', light: '浅色', dark: '深色', ariaAuto: '主题：跟随系统', ariaLight: '主题：浅色', ariaDark: '主题：深色' },
          nav: { aria: '主导航', features: '能力', workflow: '流程', security: '安全', faq: 'FAQ', releases: '版本', download: '下载', menu: '打开导航' },
          hero: { eyebrow: 'NATIVE REMOTE OPS STATION FOR MAC', tagline: '不只是 SSH 客户端。Stacio 是你的完整远程运维工作台。', copy: '会话分组、终端分屏、多终端同步执行。SSH/Telnet/串口连接、SCP 文件与文件夹传输、远程文件在线编辑、设备实时监控、内置浏览器和 AI 辅助运维——全部整合在一个原生 Mac 工作台中。', download: '下载适合当前设备的版本', releaseNotes: '查看更新日志', trustAria: '产品状态', release: 'Stacio 0.13.3 正式版', platform: '支持 macOS 14 及以上', distribution: '官方 DMG 下载' },
          workflow: { eyebrow: 'WORKFLOW', title: '从连接到解决，全程在一个工作台。', lead: 'Stacio 把 SSH 连接、分屏终端、文件传输、远程编辑、隧道、设备监控和 AI 诊断放进同一个操作闭环，告别多工具来回切换。', connectTitle: 'Connect', connectCopy: '从保存会话快速连接，SSH/Telnet/串口三合一，会话分组一目了然。', inspectTitle: 'Inspect', inspectCopy: '终端分屏查看多台设备上下文，远程目录、日志和状态同屏展示。', transferTitle: 'Transfer', transferCopy: '通过内置 SCP 工作流上传下载文件和文件夹，传输队列实时可查。', tunnelTitle: 'Tunnel', tunnelCopy: '创建并监控 SSH 隧道，local / remote / dynamic forward 集中管控。', resolveTitle: 'Resolve', resolveCopy: 'AI Agent 结合终端上下文生成排查建议，本地 Agent 协助分析和修复。' },
          features: { eyebrow: 'CAPABILITIES', title: '不是 SSH 外壳，是完整远程运维工作台。', lead: '终端管理、分屏协作、同步执行、文件编辑、SCP 传输、内置浏览器、设备告警和 AI Agent——所有远程操作能力收进一个原生 macOS 工作台。', terminalTitle: 'SSH 远程终端管理', terminalCopy: '支持 SSH/Telnet/串口连接与会话分组管理，提供图形化界面管理远程终端，告别纯命令行切换。保存的会话可按项目、环境或团队组织，一键连接。', splitSyncTitle: '终端分屏与同步执行', splitSyncCopy: '支持水平/垂直分屏，同时查看多台服务器终端输出。选中多台会话同步输入命令，一次操作批量执行。', transferTitle: 'SCP 文件与文件夹传输', transferCopy: '内置 SCP 文件与文件夹传输引擎，支持拖拽上传下载，传输队列实时跟踪进度。', editorTitle: '远程文件在线编辑器', editorCopy: '在线编辑远程服务器配置文件，支持实时保存和语法高亮。提供本地与远端双端备份恢复机制，误改可回滚。', browserTitle: '内置浏览器', browserCopy: '在 Stacio 中直接访问远端服务器的 Web 服务，无需切换浏览器。适合调试内部 API、Webhook 和管理面板。', tunnelsTitle: 'SSH 隧道管理', tunnelsCopy: '管理 local / remote / dynamic forward，显示连接状态、转发日志和关闭提醒。', dashboardTitle: '设备看板与实时告警', dashboardCopy: '仪表盘实时展示 CPU、内存、磁盘、网络 I/O 等资源指标。支持自定义阈值告警通知，设备异常时及时感知。', aiTitle: 'AI Agent 辅助运维', aiCopy: '内置 AI Agent 读取当前可见终端上下文，生成排查建议和可执行命令卡片。建议命令需用户确认后执行，敏感操作始终受控。', localAgentTitle: '本地 Agent 集成', localAgentCopy: '支持直接调用本地安装的 Codex、Claude、OpenCode、MiMo Code、ZCode、Qwen Code 等 Agent 工具，在 Stacio 中完成 AI 辅助运维与代码分析。', aiCue: '建议命令需确认后执行 · sensitive actions stay controlled' },
          security: { eyebrow: 'SECURITY', title: '本地优先，敏感操作始终由用户确认。', lead: 'Stacio 把远程工作流收进同一个 macOS 应用，但凭据、会话和敏感动作仍遵循本地优先与显式确认。', proof1: '凭据交给 macOS Keychain，会话数据和本地 Agent 调用记录均保存在本地，不默认外传。', proof2: 'AI 建议和本地 Agent 生成的命令均需用户确认后执行，敏感操作始终受控。', proof3: '诊断、日志和设备信息默认脱敏，减少复制粘贴排查时的泄露风险。' },
          releases: { eyebrow: 'STABLE RELEASE', title: 'Stacio 0.13.3 正式版', lead: '当前稳定版本为构建号 245，支持 macOS 14 及以上。', statusLabel: 'Status', statusValue: '正式版', statusCopy: 'Stacio 0.13.3 · 构建号 245', platformLabel: 'Platform', platformValue: 'macOS 14 及以上', platformCopy: '提供 Apple Silicon 与 Intel Mac 的独立安装包。', distributionLabel: 'Install', distributionValue: '当前安装包未公证', distributionCopy: '首次打开如被 macOS 拦截，请在 Finder 中右键 Stacio.app 并选择“打开”。' },
          download: { eyebrow: 'DOWNLOAD', title: '下载适合当前设备的 Stacio。', copy: '页面会自动识别你的系统和 CPU 架构，优先显示匹配版本；也可以手动切换到 macOS、Windows 或 Linux。', detectedLabel: '已识别', platformAria: '选择下载平台', archAria: '选择 CPU 架构', github: '查看 GitHub', gitee: '查看 Gitee', releaseNotes: '阅读更新日志', available: '当前可用', planned: '敬请期待', stable: '正式版', pendingPrice: '敬请期待', primaryAction: '下载 DMG', fileLabel: '文件名', sizeLabel: '文件大小', checksumLabel: 'SHA-256', notifyAction: '敬请期待' },
          faq: { eyebrow: 'FAQ', title: '关于 Stacio 的常见问题。', lead: '了解连接能力、服务器远程管理方式、Cron 工作流、平台支持和当前下载状态。', sshQuestion: 'Stacio 是 Mac SSH 客户端吗？', sshAnswer: '是。Stacio 面向 macOS，把 SSH 连接、Shell/Terminal、会话、远程文件、SCP 传输、SSH 隧道和设备指标放在同一个本地优先工作台中。', xshellQuestion: 'Stacio 可以作为 Xshell 的 Mac 替代工具吗？', xshellAnswer: '如果你在 Mac 上寻找 Xshell 替代、服务器远程工具或 SSH 客户端，Stacio 提供原生 macOS 体验，并覆盖 SSH 终端、SCP 文件传输、远程文件、隧道和诊断场景。', terminalQuestion: 'Stacio 和 macOS 自带 Terminal 有什么区别？', terminalAnswer: 'Terminal 更偏基础 Shell 入口；Stacio 面向服务器远程管理，把连接、终端上下文、远程文件、传输队列、隧道、设备指标和 AI 辅助排查整合到一个工作流。', cronQuestion: 'Cron 表达式和计划任务怎么用 Stacio 管理？', cronAnswer: '可以通过 Stacio 的 SSH 终端查看 crontab、编辑远程脚本和配置、复用终端宏执行检查命令，并让 AI 辅助解释 Cron 表达式或生成排查步骤。', platformQuestion: 'Stacio 支持 Windows 和 Linux 吗？', platformAnswer: '当前稳定版为 Stacio 0.13.3，构建号 245，支持 macOS 14 及以上，并分别提供 Apple Silicon 与 Intel Mac 安装包。Windows 和 Linux 版本显示为敬请期待。' },
          modal: { eyebrow: 'UPDATE NOTES', title: 'Stacio 0.13.3 更新说明', copy: '正式版 · 构建号 245 · 支持 macOS 14 及以上', close: '关闭更新说明', github: '打开 GitHub Releases', done: '知道了' },
          footer: { tagline: 'Stacio · Native remote operations station for macOS.', download: '下载', releaseNotes: '更新日志', cron: 'Cron 工具', feedback: '反馈问题' }
        },
        en: {
          title: 'Stacio - Mac SSH Client and Remote Operations Workbench',
          meta: 'Stacio is a native macOS SSH client and remote operations workbench for SSH, Telnet, Serial, split terminals, sync execution, remote files, SCP transfers, tunnels, device monitoring, a built-in browser, and AI-assisted troubleshooting.',
          brand: { aria: 'Stacio home', logoAlt: 'Stacio logo' },
          theme: { auto: 'Auto', light: 'Light', dark: 'Dark', ariaAuto: 'Theme: follow system', ariaLight: 'Theme: light', ariaDark: 'Theme: dark' },
          nav: { aria: 'Main navigation', features: 'Features', workflow: 'Workflow', security: 'Security', faq: 'FAQ', releases: 'Releases', download: 'Download', menu: 'Open navigation' },
          hero: { eyebrow: 'NATIVE REMOTE OPS STATION FOR MAC', tagline: 'More than an SSH client. Your complete remote operations workbench.', copy: 'Session groups, split terminals, and multi-terminal sync execution. SSH, Telnet, and Serial connections, SCP file and folder transfers, remote file editing, device monitoring, a built-in browser, and AI-assisted troubleshooting—all in one native Mac workbench.', download: 'Download for this device', releaseNotes: 'View release notes', trustAria: 'Product status', release: 'Stacio 0.13.3 stable', platform: 'macOS 14 or later', distribution: 'Official DMG download' },
          workflow: { eyebrow: 'WORKFLOW', title: 'From connect to resolve, all in one workbench.', lead: 'Stacio puts SSH connections, split terminals, file transfers, remote editing, tunnels, device monitoring, and AI diagnostics into one closed loop—no more switching between tools.', connectTitle: 'Connect', connectCopy: 'Quick connect from saved sessions—SSH, Telnet, and Serial in one place, organized by groups.', inspectTitle: 'Inspect', inspectCopy: 'Split terminals to view multiple devices side by side, with remote directories, logs, and status together.', transferTitle: 'Transfer', transferCopy: 'Upload and download files and folders through built-in SCP workflows with real-time queue tracking.', tunnelTitle: 'Tunnel', tunnelCopy: 'Create and monitor SSH tunnels—local, remote, and dynamic forwarding in one panel.', resolveTitle: 'Resolve', resolveCopy: 'AI Agent generates troubleshooting suggestions from terminal context; local Agents assist with analysis and fixes.' },
          features: { eyebrow: 'CAPABILITIES', title: 'Not an SSH wrapper. A complete remote operations workbench.', lead: 'Terminal management, split views, sync execution, file editing, SCP transfers, a built-in browser, device alerts, and AI Agents—every remote capability in one native macOS workbench.', terminalTitle: 'SSH Remote Terminal Management', terminalCopy: 'Connect through SSH, Telnet, or Serial with session group management. Organize saved sessions by project, environment, or team and connect in one click.', splitSyncTitle: 'Split Terminal & Sync Execution', splitSyncCopy: 'Split views horizontally or vertically to monitor multiple servers simultaneously. Select multiple sessions and broadcast commands for batch operations.', transferTitle: 'SCP File & Folder Transfers', transferCopy: 'Use Stacio’s built-in SCP engine for file and folder uploads and downloads, with drag-and-drop interaction and a real-time transfer queue.', editorTitle: 'Remote File Editor', editorCopy: 'Edit remote server configuration files with real-time save and syntax highlighting. Local and remote backups make changes recoverable.', browserTitle: 'Built-in Browser', browserCopy: 'Access remote web services directly inside Stacio. It is useful for debugging internal APIs, webhooks, and admin panels without changing apps.', tunnelsTitle: 'SSH Tunnel Management', tunnelsCopy: 'Manage local, remote, and dynamic forwarding with connection status, forwarding logs, and shutdown reminders.', dashboardTitle: 'Device Dashboard & Alerts', dashboardCopy: 'Monitor CPU, memory, disk, and network I/O in real time. Custom threshold alerts notify you when a device becomes abnormal.', aiTitle: 'AI Agent Assisted Operations', aiCopy: 'The built-in AI Agent reads visible terminal context and generates troubleshooting suggestions with executable command cards. Commands require user confirmation, keeping sensitive actions controlled.', localAgentTitle: 'Local Agent Integration', localAgentCopy: 'Call locally installed Agent tools directly from Stacio, including Codex, Claude, OpenCode, MiMo Code, ZCode, and Qwen Code, for AI-assisted operations and code analysis.', aiCue: 'Commands require confirmation · sensitive actions stay controlled' },
          security: { eyebrow: 'SECURITY', title: 'Local-first by default, sensitive actions stay confirmed.', lead: 'Stacio brings remote workflows into one macOS app while credentials, sessions, and sensitive actions stay local-first and explicitly controlled.', proof1: 'Credentials use macOS Keychain; session data and local Agent call logs stay local and are not sent out by default.', proof2: 'Commands generated by AI suggestions and local Agents require user confirmation before execution—sensitive actions stay controlled.', proof3: 'Diagnostics, logs, and device data are redacted by default to reduce copy-paste leakage during troubleshooting.' },
          releases: { eyebrow: 'STABLE RELEASE', title: 'Stacio 0.13.3 stable release', lead: 'The current stable build is 245 and supports macOS 14 or later.', statusLabel: 'Status', statusValue: 'Stable', statusCopy: 'Stacio 0.13.3 · Build 245', platformLabel: 'Platform', platformValue: 'macOS 14 or later', platformCopy: 'Separate installers are provided for Apple Silicon and Intel Macs.', distributionLabel: 'Install', distributionValue: 'Not notarized', distributionCopy: 'If macOS blocks the first launch, right-click Stacio.app in Finder and choose Open.' },
          download: { eyebrow: 'DOWNLOAD', title: 'Download the right Stacio build for this device.', copy: 'The page detects your OS and CPU architecture, shows the matching build first, and still lets you switch between macOS, Windows, and Linux manually.', detectedLabel: 'Detected', platformAria: 'Choose download platform', archAria: 'Choose CPU architecture', github: 'View GitHub', gitee: 'View Gitee', releaseNotes: 'Read release notes', available: 'Available now', planned: 'Coming soon', stable: 'Stable', pendingPrice: 'Coming soon', primaryAction: 'Download DMG', fileLabel: 'Filename', sizeLabel: 'File size', checksumLabel: 'SHA-256', notifyAction: 'Coming soon' },
          faq: { eyebrow: 'FAQ', title: 'Common questions about Stacio.', lead: 'Learn about connection capabilities, remote server workflows, cron troubleshooting, platform support, and the current download.', sshQuestion: 'Is Stacio a Mac SSH client?', sshAnswer: 'Yes. Stacio is built for macOS and combines SSH connections, Shell/Terminal, sessions, remote files, SCP transfer, SSH tunnels, and device metrics in one local-first workbench.', xshellQuestion: 'Can Stacio be used as an Xshell alternative for Mac?', xshellAnswer: 'If you are looking for an Xshell alternative, remote server tool, or SSH client on Mac, Stacio provides a native macOS experience with SSH terminal, SCP file transfer, remote files, tunnels, and diagnostics.', terminalQuestion: 'How is Stacio different from macOS Terminal?', terminalAnswer: 'Terminal is a basic shell entry point. Stacio is built for remote server management and combines connections, terminal context, remote files, transfer queues, tunnels, device metrics, and AI-assisted troubleshooting into one workflow.', cronQuestion: 'How can Stacio help with cron expressions and scheduled jobs?', cronAnswer: 'You can inspect crontab through SSH terminals, edit remote scripts and config, reuse terminal macros for checks, and ask AI to explain cron expressions or generate troubleshooting steps.', platformQuestion: 'Does Stacio support Windows and Linux?', platformAnswer: 'Stacio 0.13.3 build 245 is the current stable release for macOS 14 or later, with separate Apple Silicon and Intel Mac installers. Windows and Linux builds are marked as coming soon.' },
          modal: { eyebrow: 'UPDATE NOTES', title: 'Stacio 0.13.3 release notes', copy: 'Stable · Build 245 · macOS 14 or later', close: 'Close release notes', github: 'Open GitHub Releases', done: 'Got it' },
          footer: { tagline: 'Stacio · Native remote operations station for macOS.', download: 'Download', releaseNotes: 'Release Notes', cron: 'Cron', feedback: 'Report issue' }
        }
      };

      const packages = {
        macos: {
          label: 'macOS',
          formats: { arm64: 'DMG · macOS 14+ · Apple Silicon/ARM', x64: 'DMG · macOS 14+ · Intel Mac' },
          arch: ['arm64', 'x64'],
          statusByArch: { arm64: 'available', x64: 'available' },
          priceByArch: { arm64: 'stable', x64: 'stable' },
          downloadByArch: stableMacosDownloads
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
        const archLabel = state.platform === 'macos'
          ? (state.arch === 'x64' ? 'Intel Mac' : 'Apple Silicon/ARM')
          : (state.arch === 'x64' ? 'x64' : 'ARM64');
        archPicker.innerHTML = pkg.arch.map((arch) => {
          const selected = arch === state.arch;
          const label = state.platform === 'macos'
            ? (arch === 'x64' ? 'Intel Mac' : 'Apple Silicon/ARM')
            : (arch === 'x64' ? 'x64' : 'ARM64');
          return `<button class="arch-option${selected ? ' is-selected' : ''}" type="button" data-arch="${arch}" aria-pressed="${selected}">${label}</button>`;
        }).join('');
        detectedLabel.textContent = `${pkg.label} · ${archLabel}`;
        packageTitle.textContent = `Stacio for ${pkg.label}`;
        packageMeta.textContent = pkg.formats[state.arch];
        const status = pkg.statusByArch?.[state.arch] || 'planned';
        const price = pkg.priceByArch?.[state.arch] || status;
        const asset = pkg.downloadByArch?.[state.arch] || null;
        const available = status === 'available' && Boolean(asset);
        downloadCard?.classList.toggle('is-planned', !available);
        statusLabel.textContent = available ? getCopy('download.available') : getCopy('download.planned');
        priceLabel.textContent = price === 'stable' ? getCopy('download.stable') : getCopy('download.pendingPrice');
        if (downloadButtonLabel) downloadButtonLabel.textContent = available ? getCopy('download.primaryAction') : getCopy('download.notifyAction');
        downloadButton.href = asset?.primaryUrl || '#download';
        downloadButton.dataset.availability = available ? 'available' : 'planned';
        downloadButton.setAttribute('aria-disabled', String(!available));
        if (available) {
          downloadButton.setAttribute('download', asset.filename);
          downloadButton.setAttribute('aria-label', `${getCopy('download.primaryAction')} · ${asset.filename}`);
        } else {
          downloadButton.removeAttribute('download');
          downloadButton.removeAttribute('aria-label');
        }
        if (downloadVerification) downloadVerification.hidden = !available;
        if (downloadFilename) downloadFilename.textContent = asset?.filename || '';
        if (downloadFilesize) downloadFilesize.textContent = asset ? `${asset.bytes.toLocaleString(state.lang === 'zh' ? 'zh-CN' : 'en-US')} bytes` : '';
        if (downloadChecksum) downloadChecksum.textContent = asset?.sha256 || '';
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
        if (releaseTitle) releaseTitle.textContent = parsed.title || `Stacio ${release.version || currentStableVersion} 更新说明`;
        if (releaseCopy && parsed.lead) {
          releaseCopy.textContent = '';
          appendInlineMarkdown(releaseCopy, parsed.lead);
        }
        if (parsed.content.length > 0) renderReleaseMarkdown(parsed.content, releaseNotes);
      };

      const configureLatestPublicRelease = (release) => {
        if (!release) return;
        latestPublicRelease = release;
        if (releaseGitHub && release.releaseUrl) releaseGitHub.href = release.releaseUrl;
      };

      const normalizeGitHubRelease = (payload) => {
        const version = String(payload?.tag_name || '').replace(/^v/i, '');
        if (version !== currentStableVersion || !String(payload?.body || '').trim()) return null;
        return {
          id: payload.id,
          version,
          releaseNotes: payload.body,
          releaseUrl: payload.html_url
        };
      };

      const loadLatestReleaseNotes = () => {
        if (releaseNotesRequest || !releaseNotes) return releaseNotesRequest;
        releaseNotesRequest = fetch(githubReleaseEndpoint, {
          headers: { Accept: 'application/vnd.github+json' }
        })
          .then((response) => response.ok ? response.json() : Promise.reject(new Error(`Release catalog request failed: ${response.status}`)))
          .then((payload) => {
            const release = normalizeGitHubRelease(payload);
            if (!release) throw new Error('Matching GitHub release is unavailable');
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
        const revealTargets = Array.from(document.querySelectorAll('.section-head, .workflow-step, .capability-card, .why-panel, .beta-card, .final-cta, .faq-item'));
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

      [downloadButton].forEach((button) => {
        button?.addEventListener('click', (event) => {
          if (button.dataset.availability !== 'planned') return;
          event.preventDefault();
          event.stopPropagation();
          pulseDownload();
        });
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
