import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

final class TerminalThemeImportTests: XCTestCase {
    func testTerminalCommandHighlighterClassifiesCommonOpsCommands() throws {
        let docker = TerminalCommandHighlighter.highlight("sudo docker compose up -d --remove-orphans")
        XCTAssertEqual(docker.primaryCommand, "docker")
        XCTAssertEqual(docker.tokens.map(\.text), ["sudo", "docker", "compose", "up", "-d", "--remove-orphans"])
        XCTAssertTrue(docker.tokens.contains { $0.kind == .command && $0.text == "docker" })
        XCTAssertTrue(docker.tokens.contains { $0.kind == .subcommand && $0.text == "compose" })
        XCTAssertTrue(docker.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "up" })
        XCTAssertTrue(docker.tokens.contains { $0.kind == .flag && $0.text == "--remove-orphans" })

        let kubectl = TerminalCommandHighlighter.highlight("kubectl delete pod api-0 -n prod")
        XCTAssertEqual(kubectl.primaryCommand, "kubectl")
        XCTAssertEqual(kubectl.risk, .destructive)
        XCTAssertTrue(kubectl.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "delete" })
        XCTAssertTrue(kubectl.tokens.contains { $0.kind == .flag && $0.text == "-n" })

        let systemd = TerminalCommandHighlighter.highlight("systemctl restart nginx.service")
        XCTAssertEqual(systemd.primaryCommand, "systemctl")
        XCTAssertEqual(systemd.risk, .network)
        XCTAssertTrue(systemd.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "restart" })

        for command in [
            "journalctl --no-pager -u sshd",
            "yum install -y docker",
            "dnf update -y",
            "apt-get install nginx",
            "rpm -qa | grep openssl",
            "git status --short",
            "docker-compose ps",
            "compose logs --tail 20",
            "firewall-cmd --list-all",
            "service nginx status",
            "ip addr show eth0"
        ] {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertNotNil(result.primaryCommand, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .command }, command)
        }
    }

    func testTerminalCommandHighlighterMarksPathsAndAssignments() throws {
        let result = TerminalCommandHighlighter.highlight("VAR=1 docker run -v /srv/app:/app nginx:latest")

        XCTAssertEqual(result.primaryCommand, "docker")
        XCTAssertTrue(result.tokens.contains { $0.kind == .environmentAssignment && $0.text == "VAR=1" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .path && $0.text == "/srv/app:/app" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .flag && $0.text == "-v" })
    }

    func testTerminalCommandHighlighterMarksRichShellSyntaxAndNestedSubstitutions() throws {
        let result = TerminalCommandHighlighter.highlight(#"FOO=42 echo "user=$USER count=$(printf '%02d' 7)" *.log > /tmp/out.log # done"#)

        XCTAssertEqual(result.primaryCommand, nil)
        XCTAssertTrue(result.tokens.contains { $0.kind == .environmentAssignment && $0.text == "FOO=42" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .numberLiteral && $0.text == "42" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .stringLiteral && $0.text == "user=$USER count=$(printf '%02d' 7)" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .variableReference && $0.text == "$USER" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .commandSubstitution && $0.text == "$(printf '%02d' 7)" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .stringLiteral && $0.text == "%02d" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .numberLiteral && $0.text == "7" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .globPattern && $0.text == "*.log" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .operatorToken && $0.text == ">" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .redirectionTarget && $0.text == "/tmp/out.log" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .comment && $0.text == "# done" })
    }

    func testTerminalCommandHighlighterMarksBackticksHeredocAndDangerousSubcommands() throws {
        let result = TerminalCommandHighlighter.highlight(#"kubectl delete pod `cat pod.txt` --grace-period=0 <<EOF"#)

        XCTAssertEqual(result.primaryCommand, "kubectl")
        XCTAssertEqual(result.risk, .destructive)
        XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "delete" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .commandSubstitution && $0.text == "`cat pod.txt`" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .numberLiteral && $0.text == "0" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .operatorToken && $0.text == "<<" })
        XCTAssertTrue(result.tokens.contains { $0.kind == .heredocMarker && $0.text == "EOF" })
    }

    func testTerminalSemanticOutputHighlighterColorsPlainOpsOutput() {
        let text = """
        ● docker.service - Docker Application Container Engine
           Active: active (running) since 2026-06-08
        Jun 08 localhost dockerd[2405]: time="2026-06-08T11:45:54+08:00" level=info msg="ignoring event" container=6fb15493
        Error response from daemon: No such container: clickhouse
        /opt/ncompass/app.sh: line 244: artisan: command not found
        Docs: https://docs.docker.com
        """

        XCTAssertEqual(TerminalSemanticOutputHighlighter.highlight(text, level: .ansiOnly), text)

        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .tokyoNight
        )

        XCTAssertTrue(highlighted.containsStyledToken("● docker.service"))
        XCTAssertTrue(highlighted.containsStyledToken("active (running)"))
        XCTAssertTrue(highlighted.containsStyledToken("time=\"2026-06-08T11:45:54+08:00\""))
        XCTAssertTrue(highlighted.containsStyledToken("level=info"))
        XCTAssertTrue(highlighted.containsStyledToken("container=6fb15493"))
        XCTAssertTrue(highlighted.containsStyledToken("Error response from daemon"))
        XCTAssertTrue(highlighted.containsStyledToken("command not found"))
        XCTAssertTrue(highlighted.containsStyledToken("https://docs.docker.com"))
    }

    func testTerminalSemanticOutputHighlighterColorsUbuntuMotdLikeNyaTerm() {
        let text = """
        Welcome to Ubuntu 25.10 (GNU/Linux 6.17.0-35-generic x86_64)

        * Documentation:  https://docs.ubuntu.com
        * Management:     https://landscape.canonical.com
        * Support:        https://ubuntu.com/pro

        System information as of Thu Jul  9 04:36:17 UTC 2026

        System load:  0.21              Processes:              307
        Usage of /:   12.5% of 95.90GB  Users logged in:        0
        Memory usage: 5%                IPv4 address for ens160: 172.16.10.250
        Swap usage:   0%

        sudo apt install --update rust-coreutils
        42 updates can be applied immediately.
        New release '26.04 LTS' available.
        To see these additional updates run: apt list --upgradable
        """

        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .systemAdaptivePreview
        )

        [
            "25.10",
            "6.17.0-35-generic",
            "https://docs.ubuntu.com",
            "information",
            "0.21",
            "307",
            "12.5%",
            "95.90GB",
            "172.16.10.250",
            "--update",
            "42",
            "release",
            "26.04",
            "--upgradable"
        ].forEach { token in
            XCTAssertTrue(highlighted.containsStyledToken(token), token)
        }
        XCTAssertTrue(highlighted.containsStyleCode("38;2;0;122;120", before: "https://docs.ubuntu.com"))
        XCTAssertTrue(highlighted.containsStyleCode("38;2;124;58;237", before: "25.10"))
        XCTAssertTrue(highlighted.containsStyleCode("38;2;180;83;9", before: "172.16.10.250"))
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), text)
    }

    func testTerminalSemanticOutputHighlighterLeavesAnsiAndDisabledModesUnchanged() {
        let ansiText = "\u{001B}[31mError\u{001B}[0m response from daemon\n"
        XCTAssertEqual(
            TerminalSemanticOutputHighlighter.highlight(ansiText, level: .ansiOnly),
            ansiText
        )
        XCTAssertEqual(
            TerminalSemanticOutputHighlighter.highlight("Error response from daemon\n", level: .off),
            "Error response from daemon\n"
        )
    }

    func testTerminalSemanticOutputHighlighterHighlightsShellPromptsWithBackground() {
        let text = """
        [root@localhost ~]# yum update
        [root@localhost etc]# ls
        [root@localhost home]# cd /
        deploy@example.com:/srv/app$ git status
        FengLee@FengStor:/home$ ls -la
        mac@192 / % pwd
        """

        let ansiOnly = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .ansiOnly,
            richHighlightingEnabled: true,
            theme: .systemAdaptivePreview
        )

        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("[root@localhost ~]# "))
        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("[root@localhost etc]# "))
        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("[root@localhost home]# "))
        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("deploy@example.com:/srv/app$ "))
        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("FengLee@FengStor:/home$ "))
        XCTAssertTrue(ansiOnly.containsBackgroundStyledToken("mac@192 / % "))
        XCTAssertFalse(ansiOnly.containsBackgroundStyledToken("yum update"))
        XCTAssertFalse(ansiOnly.containsBackgroundStyledToken("cd /"))
        XCTAssertFalse(ansiOnly.containsBackgroundStyledToken("git status"))
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: ansiOnly), text)

        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .tokyoNight
        )

        XCTAssertTrue(highlighted.containsBackgroundStyledToken("[root@localhost ~]# "))
        XCTAssertTrue(highlighted.containsBackgroundStyledToken("[root@localhost etc]# "))
        XCTAssertTrue(highlighted.containsBackgroundStyledToken("[root@localhost home]# "))
        XCTAssertTrue(highlighted.containsBackgroundStyledToken("deploy@example.com:/srv/app$ "))
        XCTAssertTrue(highlighted.containsBackgroundStyledToken("FengLee@FengStor:/home$ "))
        XCTAssertTrue(highlighted.containsBackgroundStyledToken("mac@192 / % "))
        XCTAssertFalse(highlighted.containsBackgroundStyledToken("yum update"))
        XCTAssertFalse(highlighted.containsBackgroundStyledToken("cd /"))
        XCTAssertFalse(highlighted.containsBackgroundStyledToken("git status"))
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), text)
    }

    func testTerminalSemanticOutputHighlighterHighlightsSinglePromptWithoutNewline() {
        for prompt in [
            "[root@localhost ~]# ",
            "[root@localhost etc]# ",
            "[root@localhost home]# ",
            "deploy@example.com:/srv/app$ ",
            "mac@192 / % "
        ] {
            let highlighted = TerminalSemanticOutputHighlighter.highlight(
                prompt,
                level: .ansiOnly,
                richHighlightingEnabled: true,
                theme: .systemAdaptivePreview
            )

            XCTAssertTrue(highlighted.containsBackgroundStyledToken(prompt), prompt)
            XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), prompt)
            XCTAssertEqual(
                TerminalSemanticOutputHighlighter.highlight(prompt, level: .off),
                prompt
            )
        }
    }

    func testTerminalSemanticOutputHighlighterHighlightsPromptsWhenRichHighlightingIsDisabled() {
        let prompt = "[root@localhost ~]# "
        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            prompt,
            level: .ansiOnly,
            richHighlightingEnabled: false,
            theme: .systemAdaptivePreview
        )

        XCTAssertTrue(highlighted.containsBackgroundStyledToken(prompt))
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), prompt)

        let regularOutput = "Error response from daemon\n"
        XCTAssertEqual(
            TerminalSemanticOutputHighlighter.highlight(
                regularOutput,
                level: .commandLineEnhanced,
                richHighlightingEnabled: false,
                theme: .systemAdaptivePreview
            ),
            regularOutput
        )
    }

    func testTerminalSemanticOutputHighlighterHighlightsPromptsAfterShellControlPrefixes() {
        let cases: [(raw: String, visiblePrompt: String)] = [
            (
                "\u{001B}]0;root@localhost:~\u{0007}[root@localhost ~]# ",
                "[root@localhost ~]# "
            ),
            (
                "\u{001B}]0;root@localhost:/etc\u{0007}[root@localhost etc]# ",
                "[root@localhost etc]# "
            ),
            (
                "\u{001B}[?2004h[root@localhost ~]# ",
                "[root@localhost ~]# "
            ),
            (
                "\u{001B}[32m[root@localhost ~]# ",
                "[root@localhost ~]# "
            ),
            (
                "\u{001B}[32m[root@\u{001B}[1mlocalhost\u{001B}[0m ~]# ",
                "[root@localhost ~]# "
            )
        ]

        for (raw, visiblePrompt) in cases {
            let highlighted = TerminalSemanticOutputHighlighter.highlight(
                raw,
                level: .ansiOnly,
                richHighlightingEnabled: false,
                theme: .systemAdaptivePreview
            )

            XCTAssertTrue(highlighted.containsPromptBlueBackgroundCode(), raw)
            if raw.contains("\u{001B}[1m") == false {
                XCTAssertTrue(highlighted.containsBackgroundStyledToken(visiblePrompt), raw)
            }
            XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), raw)
        }
    }

    func testTerminalSemanticOutputHighlighterPromptBackgroundReachesLocalAndRemoteTerminalCells() {
        let suiteName = "StacioPromptBackgroundTerminalCells-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .ansiOnly
            settings.terminalRichHighlightingEnabled = false
        }
        let raw = "\u{001B}]0;root@localhost:/etc\u{0007}\u{001B}[32m[root@localhost etc]# "
        let prompt = "[root@localhost etc]# "

        let localTerminal = StacioLocalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        localTerminal.fontZoomSettingsStore = settingsStore
        localTerminal.dataReceived(slice: ArraySlice(Array(raw.utf8)))
        assertPromptCellsHaveBlueBackground(in: localTerminal.terminal, prompt: prompt)

        let remoteTerminal = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        remoteTerminal.fontZoomSettingsStore = settingsStore
        remoteTerminal.feedRemoteOutput(Array(raw.utf8))
        assertPromptCellsHaveBlueBackground(in: remoteTerminal.terminal, prompt: prompt)
    }

    func testRemotePromptHighlightingDoesNotInsertBlankRowsBetweenRapidPrompts() {
        let suiteName = "StacioRapidPromptRows-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
            settings.terminalRichHighlightingEnabled = true
        }
        let terminal = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        terminal.fontZoomSettingsStore = settingsStore
        terminal.terminal.resize(cols: 80, rows: 24)
        let osc7Prompt = "\u{001B}]7;file://user/root\u{001B}\\root@user:~# "
        terminal.feedRemoteOutput(Array(osc7Prompt.utf8))

        for _ in 0..<8 {
            terminal.feedRemoteOutput(Array("\r\n\(osc7Prompt)".utf8))
        }

        let text = String(
            decoding: terminal.terminal.getBufferAsData(kind: .active, encoding: .utf8),
            as: UTF8.self
        )
        let promptRows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 == "root@user:~# " }

        XCTAssertEqual(promptRows.count, 9)
        XCTAssertFalse(text.contains("root@user:~# \n\nroot@user:~# "))
    }

    func testTerminalSemanticOutputHighlighterDoesNotBackgroundPromptLikeLogValues() {
        let text = """
        deploy@example.com:/tmp is a log value
        [root@localhost booting] info
        2026-06-10 deploy@example.com:/srv/app health check passed
        """

        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .tokyoNight
        )

        XCTAssertFalse(highlighted.contains("48;2;"))
        XCTAssertFalse(
            TerminalSemanticOutputHighlighter.highlight(
                text,
                level: .ansiOnly,
                richHighlightingEnabled: true,
                theme: .systemAdaptivePreview
            ).contains("48;2;")
        )
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), text)
    }

    func testTerminalSemanticOutputHighlighterMarksCommonOpsOutputWithThemePalette() {
        let text = """
        git branch main ahead 2 behind 1 commit deadbeef
        modified Sources/App.swift untracked tmp.log
        2026-06-09T10:12:44Z pid=2405 status=1 exit code 127 CPU 14%
        tcp 192.168.8.10:8080 [fe80::1]:443 1.30G -rwxr-xr-x 0755 deploy:staff
        OK PASS WARN DENIED ERROR
        """

        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .tokyoNight
        )

        [
            "main",
            "ahead",
            "behind",
            "deadbeef",
            "modified",
            "untracked",
            "2026-06-09T10:12:44Z",
            "pid=2405",
            "status=1",
            "exit code 127",
            "14%",
            "192.168.8.10:8080",
            "[fe80::1]:443",
            "1.30G",
            "-rwxr-xr-x",
            "0755",
            "deploy:staff",
            "OK",
            "PASS",
            "WARN",
            "DENIED",
            "ERROR"
        ].forEach { token in
            XCTAssertTrue(highlighted.containsStyledToken(token), token)
        }
    }

    func testTerminalSemanticOutputHighlighterCanDefensivelyStripOnlyStacioDisplayMarkup() {
        let nativeANSI = "\u{001B}[31mNative red\u{001B}[0m"
        let nativeTrueColorANSI = "\u{001B}[38;2;1;2;3mNative truecolor\u{001B}[0m"
        let nativeOSC8 = "\u{001B}]8;;https://example.com\u{0007}docs\u{001B}]8;;\u{0007}"
        let text = "\(nativeANSI) \(nativeTrueColorANSI) ERROR status=1 /var/log/app.log \(nativeOSC8)\n"
        let highlighted = TerminalSemanticOutputHighlighter.highlight(
            text,
            level: .commandLineEnhanced,
            richHighlightingEnabled: true,
            theme: .tokyoNight
        )

        XCTAssertNotEqual(highlighted, text)
        XCTAssertTrue(highlighted.containsStyledToken("ERROR"))
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: highlighted), text)
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: nativeANSI), nativeANSI)
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: nativeTrueColorANSI), nativeTrueColorANSI)
        XCTAssertEqual(TerminalSemanticOutputHighlighter.strippingStacioDisplayMarkup(from: nativeOSC8), nativeOSC8)
    }

    func testTerminalSemanticOutputHighlighterSkipsOversizedLinesAndChunks() {
        let longLine = String(repeating: "ERROR /var/log/app.log ", count: 450)
        XCTAssertEqual(
            TerminalSemanticOutputHighlighter.highlight(
                longLine,
                level: .commandLineEnhanced,
                richHighlightingEnabled: true,
                theme: .tokyoNight
            ),
            longLine
        )

        let oversizedChunk = String(repeating: "ERROR /var/log/app.log status=1\n", count: 18_000)
        XCTAssertGreaterThan(oversizedChunk.utf8.count, 512 * 1_024)
        XCTAssertEqual(
            TerminalSemanticOutputHighlighter.highlight(
                oversizedChunk,
                level: .commandLineEnhanced,
                richHighlightingEnabled: true,
                theme: .tokyoNight
            ),
            oversizedChunk
        )
    }

    func testTerminalHighlightPaletteKeepsSemanticRolesReadableAcrossThemes() {
        let custom = TerminalColorTheme(
            name: "High Contrast Test",
            sourceFormat: .portDesk,
            foregroundHex: "#F5F5F5",
            backgroundHex: "#050505",
            ansiColorHexes: [
                "#050505", "#661111", "#116611", "#666611",
                "#111166", "#661166", "#116666", "#CCCCCC",
                "#777777", "#FF5555", "#55FF55", "#FFFF55",
                "#5599FF", "#FF55FF", "#55FFFF", "#FFFFFF"
            ]
        )
        let themes: [TerminalColorTheme] = [.solarizedLight, .tokyoNight, custom]

        for theme in themes {
            let palette = TerminalHighlightPalette(theme: theme)
            for role in TerminalHighlightSemanticRole.allCases {
                let ratio = palette.contrastRatio(for: role)
                let minimum = role.allowsMutedContrast ? 3.0 : 4.5
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(theme.name) \(role)")
            }
        }
    }

    func testTerminalCommandHighlighterCoversOpsRiskBoundaries() throws {
        let destructiveCases = [
            "docker compose down --volumes",
            "docker volume prune -f",
            "docker network prune --force",
            "docker container rm web-1",
            "docker swarm leave --force",
            "apt-get remove nginx",
            "dnf remove docker",
            "yum erase httpd",
            "git clean -fd",
            "docker-compose down --volumes",
            "compose --project-name api down",
            "firewall-cmd --permanent --remove-service=http"
        ]
        for command in destructiveCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .destructive, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand }, command)
        }

        let networkCases = [
            "docker compose restart api",
            "docker service update --image app:2 api",
            "docker login registry.example.com",
            "systemctl start nginx",
            "systemctl enable nginx",
            "kubectl rollout restart deployment/api",
            "git push origin main",
            "service nginx restart",
            "firewall-cmd --reload",
            "ip link set eth0 down"
        ]
        for command in networkCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .network, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand }, command)
        }

        let readOnlyCases = [
            "journalctl -u sshd --no-pager",
            "docker compose ps",
            "docker service ls",
            "docker image inspect nginx:latest",
            "rpm -qa | grep openssl",
            "kubectl get pods -n prod",
            "systemctl status nginx",
            "docker-compose ps",
            "compose logs --tail 20",
            "firewall-cmd --list-all",
            "ip addr show eth0",
            "du -sh ./* 2>/dev/null | sort -h | tail -20",
            "docker images | head -20",
            "free -h"
        ]
        for command in readOnlyCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .readOnly, command)
            XCTAssertNotNil(result.primaryCommand, command)
        }
    }

    func testTerminalCommandHighlighterMarksNestedDockerActions() throws {
        let serviceUpdate = TerminalCommandHighlighter.highlight("docker service update --image app:2 api")
        XCTAssertEqual(serviceUpdate.primaryCommand, "docker")
        XCTAssertTrue(serviceUpdate.tokens.contains { $0.kind == .subcommand && $0.text == "service" })
        XCTAssertTrue(serviceUpdate.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "update" })
        XCTAssertTrue(serviceUpdate.tokens.contains { $0.kind == .flag && $0.text == "--image" })

        let volumePrune = TerminalCommandHighlighter.highlight("docker volume prune -f")
        XCTAssertEqual(volumePrune.risk, .destructive)
        XCTAssertTrue(volumePrune.tokens.contains { $0.kind == .subcommand && $0.text == "volume" })
        XCTAssertTrue(volumePrune.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "prune" })

        let composeRestart = TerminalCommandHighlighter.highlight("docker compose restart api")
        XCTAssertEqual(composeRestart.risk, .network)
        XCTAssertTrue(composeRestart.tokens.contains { $0.kind == .subcommand && $0.text == "compose" })
        XCTAssertTrue(composeRestart.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "restart" })
    }

    func testTerminalCommandHighlighterCoversDockerPluginAndBuildxWorkflows() throws {
        let buildxBake = TerminalCommandHighlighter.highlight("docker buildx bake --file docker-bake.hcl")
        XCTAssertEqual(buildxBake.primaryCommand, "docker")
        XCTAssertTrue(buildxBake.tokens.contains { $0.kind == .subcommand && $0.text == "buildx" })
        XCTAssertTrue(buildxBake.tokens.contains { $0.kind == .subcommand && $0.text == "bake" })
        XCTAssertTrue(buildxBake.tokens.contains { $0.kind == .flag && $0.text == "--file" })
        XCTAssertTrue(buildxBake.tokens.contains { $0.kind == .argument && $0.text == "docker-bake.hcl" })

        let contextUse = TerminalCommandHighlighter.highlight("docker context use production")
        XCTAssertEqual(contextUse.risk, .network)
        XCTAssertTrue(contextUse.tokens.contains { $0.kind == .subcommand && $0.text == "context" })
        XCTAssertTrue(contextUse.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "use" })

        let pluginDisable = TerminalCommandHighlighter.highlight("docker plugin disable rexray/ebs")
        XCTAssertEqual(pluginDisable.risk, .network)
        XCTAssertTrue(pluginDisable.tokens.contains { $0.kind == .subcommand && $0.text == "plugin" })
        XCTAssertTrue(pluginDisable.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "disable" })

        let manifestPush = TerminalCommandHighlighter.highlight("docker manifest push registry.example.com/app:latest")
        XCTAssertEqual(manifestPush.risk, .network)
        XCTAssertTrue(manifestPush.tokens.contains { $0.kind == .subcommand && $0.text == "manifest" })
        XCTAssertTrue(manifestPush.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "push" })

        let composeProfile = TerminalCommandHighlighter.highlight("docker compose --profile prod up -d")
        XCTAssertEqual(composeProfile.risk, .network)
        XCTAssertTrue(composeProfile.tokens.contains { $0.kind == .subcommand && $0.text == "compose" })
        XCTAssertTrue(composeProfile.tokens.contains { $0.kind == .flag && $0.text == "--profile" })
        XCTAssertTrue(composeProfile.tokens.contains { $0.kind == .argument && $0.text == "prod" })
        XCTAssertTrue(composeProfile.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "up" })
        XCTAssertFalse(composeProfile.summary.contains("prod"))
    }

    func testTerminalCommandHighlighterCoversContainerRuntimeCLIs() throws {
        let nerdctlLogs = TerminalCommandHighlighter.highlight("nerdctl compose logs --tail 100 api")
        XCTAssertEqual(nerdctlLogs.primaryCommand, "nerdctl")
        XCTAssertEqual(nerdctlLogs.risk, .readOnly)
        XCTAssertTrue(nerdctlLogs.tokens.contains { $0.kind == .subcommand && $0.text == "compose" })
        XCTAssertTrue(nerdctlLogs.tokens.contains { $0.kind == .subcommand && $0.text == "logs" })
        XCTAssertTrue(nerdctlLogs.tokens.contains { $0.kind == .flag && $0.text == "--tail" })

        let crictlStop = TerminalCommandHighlighter.highlight("crictl stop 8f3a")
        XCTAssertEqual(crictlStop.primaryCommand, "crictl")
        XCTAssertEqual(crictlStop.risk, .network)
        XCTAssertTrue(crictlStop.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "stop" })

        let ctrRemove = TerminalCommandHighlighter.highlight("ctr images rm registry.example.com/app:old")
        XCTAssertEqual(ctrRemove.primaryCommand, "ctr")
        XCTAssertEqual(ctrRemove.risk, .destructive)
        XCTAssertTrue(ctrRemove.tokens.contains { $0.kind == .subcommand && $0.text == "images" })
        XCTAssertTrue(ctrRemove.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "rm" })
    }

    func testTerminalCommandHighlighterMatchesKubectlAndSystemctlClassifierVocabulary() throws {
        for command in [
            "kubectl patch deployment api -p '{}'",
            "kubectl edit deployment/api",
            "kubectl set image deployment/api api=registry.example.com/api:2",
            "kubectl label pod api-0 tier=frontend --overwrite",
            "kubectl annotate deployment api owner=ops",
            "kubectl cp ./config.yaml prod/api-0:/tmp/config.yaml",
            "kubectl port-forward svc/api 8080:80",
            "kubectl replace -f deployment.yaml",
            "kubectl expose deployment api --port 80"
        ] {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.primaryCommand, "kubectl", command)
            XCTAssertEqual(result.risk, .network, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand }, command)
        }

        let readOnlySystemd = [
            "systemctl is-active nginx",
            "systemctl list-units --type service",
            "systemctl show nginx.service",
            "systemctl cat nginx.service"
        ]
        for command in readOnlySystemd {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.primaryCommand, "systemctl", command)
            XCTAssertEqual(result.risk, .readOnly, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .subcommand }, command)
        }

        let daemonReload = TerminalCommandHighlighter.highlight("systemctl daemon-reload")
        XCTAssertEqual(daemonReload.risk, .network)
        XCTAssertTrue(daemonReload.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "daemon-reload" })
    }

    func testTerminalCommandHighlighterCoversLinuxFirewallAndPackageManagers() throws {
        let readOnlyCases = [
            "iptables -L -n",
            "nft list ruleset",
            "ufw status verbose",
            "apk info",
            "zypper search nginx",
            "pacman -Qs openssl"
        ]
        for command in readOnlyCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .readOnly, command)
            XCTAssertNotNil(result.primaryCommand, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .command }, command)
        }

        let networkCases = [
            "iptables -A INPUT -p tcp --dport 443 -j ACCEPT",
            "nft add rule inet filter input tcp dport 443 accept",
            "ufw allow 443/tcp",
            "apk add curl",
            "zypper update -y",
            "pacman -Syu"
        ]
        for command in networkCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .network, command)
            XCTAssertNotNil(result.primaryCommand, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand }, command)
        }

        let destructiveCases = [
            "iptables -D INPUT 1",
            "nft delete rule inet filter input handle 3",
            "ufw delete allow 443/tcp",
            "apk del oldpkg",
            "zypper remove nginx",
            "pacman -Rns oldpkg"
        ]
        for command in destructiveCases {
            let result = TerminalCommandHighlighter.highlight(command)
            XCTAssertEqual(result.risk, .destructive, command)
            XCTAssertNotNil(result.primaryCommand, command)
            XCTAssertTrue(result.tokens.contains { $0.kind == .dangerousSubcommand }, command)
        }
    }

    func testTerminalCommandHighlighterDoesNotTreatFlagValuesAsSubcommands() throws {
        let rollout = TerminalCommandHighlighter.highlight("kubectl -n prod rollout restart deployment/api")
        XCTAssertEqual(rollout.primaryCommand, "kubectl")
        XCTAssertTrue(rollout.tokens.contains { $0.kind == .flag && $0.text == "-n" })
        XCTAssertTrue(rollout.tokens.contains { $0.kind == .argument && $0.text == "prod" })
        XCTAssertTrue(rollout.tokens.contains { $0.kind == .subcommand && $0.text == "rollout" })
        XCTAssertTrue(rollout.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "restart" })
        XCTAssertFalse(rollout.summary.contains("prod"))

        let logs = TerminalCommandHighlighter.highlight("journalctl -u sshd --since yesterday --no-pager")
        XCTAssertEqual(logs.primaryCommand, "journalctl")
        XCTAssertTrue(logs.tokens.contains { $0.kind == .flag && $0.text == "-u" })
        XCTAssertTrue(logs.tokens.contains { $0.kind == .argument && $0.text == "sshd" })
        XCTAssertTrue(logs.tokens.contains { $0.kind == .argument && $0.text == "yesterday" })
        XCTAssertFalse(logs.summary.contains("sshd"))
        XCTAssertFalse(logs.summary.contains("yesterday"))

        let composeLogs = TerminalCommandHighlighter.highlight("docker compose logs --tail 100 --since 10m api")
        XCTAssertEqual(composeLogs.primaryCommand, "docker")
        XCTAssertTrue(composeLogs.tokens.contains { $0.kind == .subcommand && $0.text == "compose" })
        XCTAssertTrue(composeLogs.tokens.contains { $0.kind == .subcommand && $0.text == "logs" })
        XCTAssertTrue(composeLogs.tokens.contains { $0.kind == .flag && $0.text == "--tail" })
        XCTAssertTrue(composeLogs.tokens.contains { $0.kind == .argument && $0.text == "100" })
        XCTAssertTrue(composeLogs.tokens.contains { $0.kind == .argument && $0.text == "10m" })
        XCTAssertFalse(composeLogs.summary.contains("100"))

        let describe = TerminalCommandHighlighter.highlight("kubectl --namespace prod describe pod api-0")
        XCTAssertEqual(describe.primaryCommand, "kubectl")
        XCTAssertTrue(describe.tokens.contains { $0.kind == .argument && $0.text == "prod" })
        XCTAssertTrue(describe.tokens.contains { $0.kind == .subcommand && $0.text == "describe" })
        XCTAssertFalse(describe.summary.contains("prod"))

        let nginx = TerminalCommandHighlighter.highlight("sudo nginx -t -c /etc/nginx/nginx.conf")
        XCTAssertEqual(nginx.primaryCommand, "nginx")
        XCTAssertEqual(nginx.risk, .readOnly)
        XCTAssertTrue(nginx.tokens.contains { $0.kind == .flag && $0.text == "-c" })
        XCTAssertTrue(nginx.tokens.contains { $0.kind == .path && $0.text == "/etc/nginx/nginx.conf" })

        let firewall = TerminalCommandHighlighter.highlight("firewall-cmd --zone public --add-service http")
        XCTAssertEqual(firewall.primaryCommand, "firewall-cmd")
        XCTAssertEqual(firewall.risk, .network)
        XCTAssertTrue(firewall.tokens.contains { $0.kind == .flag && $0.text == "--zone" })
        XCTAssertTrue(firewall.tokens.contains { $0.kind == .argument && $0.text == "public" })
        XCTAssertTrue(firewall.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "--add-service" })
    }

    func testTerminalCommandHighlighterKeepsQuotedFlagValuesTogether() throws {
        let journal = TerminalCommandHighlighter.highlight(#"journalctl --since "2 hours ago" -u sshd --no-pager"#)
        XCTAssertEqual(journal.primaryCommand, "journalctl")
        XCTAssertTrue(journal.tokens.contains { $0.kind == .flag && $0.text == "--since" })
        XCTAssertTrue(journal.tokens.contains { $0.kind == .argument && $0.text == "2 hours ago" })
        XCTAssertTrue(journal.tokens.contains { $0.kind == .flag && $0.text == "-u" })
        XCTAssertTrue(journal.tokens.contains { $0.kind == .argument && $0.text == "sshd" })
        XCTAssertFalse(journal.tokens.contains { $0.kind == .subcommand && $0.text == "hours" })
        XCTAssertFalse(journal.tokens.contains { $0.kind == .subcommand && $0.text == "ago\"" })
        XCTAssertFalse(journal.summary.contains("2 hours ago"))

        let docker = TerminalCommandHighlighter.highlight(#"VAR="hello world" docker run --name "api server" -v "/srv/app data:/app data" nginx:latest"#)
        XCTAssertEqual(docker.primaryCommand, "docker")
        XCTAssertTrue(docker.tokens.contains { $0.kind == .environmentAssignment && $0.text == "VAR=hello world" })
        XCTAssertTrue(docker.tokens.contains { $0.kind == .argument && $0.text == "api server" })
        XCTAssertTrue(docker.tokens.contains { $0.kind == .path && $0.text == "/srv/app data:/app data" })
        XCTAssertFalse(docker.summary.contains("api server"))
    }

    func testTerminalCommandHighlighterSurfacesShellWrappedRisk() throws {
        let destructive = TerminalCommandHighlighter.highlight(#"sh -c "rm -rf /tmp/build""#)
        XCTAssertEqual(destructive.primaryCommand, "sh")
        XCTAssertEqual(destructive.risk, .destructive)
        XCTAssertTrue(destructive.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "rm -rf /tmp/build" })

        let network = TerminalCommandHighlighter.highlight(#"bash -lc "systemctl restart nginx""#)
        XCTAssertEqual(network.primaryCommand, "bash")
        XCTAssertEqual(network.risk, .network)
        XCTAssertTrue(network.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "systemctl restart nginx" })

        let diagnostic = TerminalCommandHighlighter.highlight(#"echo "rm -rf /tmp/build""#)
        XCTAssertNil(diagnostic.primaryCommand)
        XCTAssertEqual(diagnostic.risk, .readOnly)
    }

    func testTerminalCommandHighlighterSurfacesCommandsAfterPipesAndChains() throws {
        let chainedDocker = TerminalCommandHighlighter.highlight("docker ps -q | xargs docker rm -f")

        XCTAssertEqual(chainedDocker.primaryCommand, "docker")
        XCTAssertEqual(chainedDocker.commands, ["docker", "xargs", "docker"])
        XCTAssertEqual(chainedDocker.risk, .destructive)
        XCTAssertTrue(chainedDocker.tokens.contains { $0.kind == .operatorToken && $0.text == "|" })
        XCTAssertTrue(chainedDocker.tokens.contains { $0.kind == .command && $0.text == "xargs" })
        XCTAssertTrue(chainedDocker.tokens.contains { $0.kind == .command && $0.text == "docker" })
        XCTAssertTrue(chainedDocker.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "rm" })
        XCTAssertTrue(chainedDocker.summary.contains("命令：docker, xargs"))
        XCTAssertTrue(chainedDocker.summary.contains("子命令：ps, rm"))

        let chainedSystemd = TerminalCommandHighlighter.highlight("journalctl -u nginx --no-pager && systemctl restart nginx")

        XCTAssertEqual(chainedSystemd.commands, ["journalctl", "systemctl"])
        XCTAssertEqual(chainedSystemd.risk, .network)
        XCTAssertTrue(chainedSystemd.tokens.contains { $0.kind == .operatorToken && $0.text == "&&" })
        XCTAssertTrue(chainedSystemd.tokens.contains { $0.kind == .command && $0.text == "systemctl" })
        XCTAssertTrue(chainedSystemd.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "restart" })
        XCTAssertTrue(chainedSystemd.summary.contains("命令：journalctl, systemctl"))
    }

    func testTerminalCommandHighlighterCoversIaCServiceDatabaseAndCloudTools() throws {
        let terraform = TerminalCommandHighlighter.highlight("terraform apply -auto-approve")
        XCTAssertEqual(terraform.primaryCommand, "terraform")
        XCTAssertEqual(terraform.risk, .network)
        XCTAssertTrue(terraform.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "apply" })

        let ansible = TerminalCommandHighlighter.highlight("ansible all -m service -a 'name=nginx state=restarted'")
        XCTAssertEqual(ansible.primaryCommand, "ansible")
        XCTAssertEqual(ansible.risk, .network)
        XCTAssertTrue(ansible.tokens.contains { $0.kind == .flag && $0.text == "-m" })
        XCTAssertTrue(ansible.tokens.contains { $0.kind == .subcommand && $0.text == "service" })

        let pm2 = TerminalCommandHighlighter.highlight("pm2 delete api")
        XCTAssertEqual(pm2.primaryCommand, "pm2")
        XCTAssertEqual(pm2.risk, .destructive)
        XCTAssertTrue(pm2.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "delete" })

        let redis = TerminalCommandHighlighter.highlight("redis-cli flushall")
        XCTAssertEqual(redis.primaryCommand, "redis-cli")
        XCTAssertEqual(redis.risk, .destructive)
        XCTAssertTrue(redis.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "flushall" })

        let aws = TerminalCommandHighlighter.highlight("aws s3 sync ./dist s3://prod-bucket/dist")
        XCTAssertEqual(aws.primaryCommand, "aws")
        XCTAssertEqual(aws.risk, .network)
        XCTAssertTrue(aws.tokens.contains { $0.kind == .subcommand && $0.text == "s3" })
        XCTAssertTrue(aws.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "sync" })

        let rsync = TerminalCommandHighlighter.highlight("rsync -av --delete ./dist/ host:/srv/app/")
        XCTAssertEqual(rsync.primaryCommand, "rsync")
        XCTAssertEqual(rsync.risk, .destructive)
        XCTAssertTrue(rsync.tokens.contains { $0.kind == .dangerousSubcommand && $0.text == "--delete" })
    }

    func testImportsKittyThemeConfiguration() throws {
        let source = """
        foreground #cdd6f4
        background #1e1e2e
        cursor #f5e0dc
        selection_background #45475a
        color0 #45475a
        color1 #f38ba8
        color2 #a6e3a1
        color3 #f9e2af
        color4 #89b4fa
        color5 #f5c2e7
        color6 #94e2d5
        color7 #bac2de
        color8 #585b70
        color9 #f38ba8
        color10 #a6e3a1
        color11 #f9e2af
        color12 #89b4fa
        color13 #f5c2e7
        color14 #94e2d5
        color15 #a6adc8
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: "Catppuccin Mocha",
            fileExtension: "conf"
        )

        XCTAssertEqual(theme.name, "Catppuccin Mocha")
        XCTAssertEqual(theme.sourceFormat, .kitty)
        XCTAssertEqual(theme.foregroundHex, "#CDD6F4")
        XCTAssertEqual(theme.backgroundHex, "#1E1E2E")
        XCTAssertEqual(theme.cursorHex, "#F5E0DC")
        XCTAssertEqual(theme.selectionBackgroundHex, "#45475A")
        XCTAssertEqual(theme.ansiColorHexes[0], "#45475A")
        XCTAssertEqual(theme.ansiColorHexes[15], "#A6ADC8")
    }

    func testExportsAndImportsStacioThemeJSON() throws {
        let theme = TerminalColorTheme(
            name: "Ops Dark",
            sourceFormat: .ghostty,
            foregroundHex: "#D6DEEB",
            backgroundHex: "#011627",
            cursorHex: "#FFCC00",
            selectionBackgroundHex: "#1D3B53",
            ansiColorHexes: [
                "#000000", "#CC0000", "#00CC00", "#CCCC00",
                "#0000CC", "#CC00CC", "#00CCCC", "#CCCCCC",
                "#555555", "#FF5555", "#55FF55", "#FFFF55",
                "#5555FF", "#FF55FF", "#55FFFF", "#FFFFFF"
            ]
        )

        let data = try TerminalThemeExporter.exportStacioTheme(theme)
        let imported = try TerminalThemeImporter.importTheme(
            data: data,
            suggestedName: nil,
            fileExtension: "staciotheme"
        )

        XCTAssertEqual(imported.name, "Ops Dark")
        XCTAssertEqual(imported.sourceFormat, .portDesk)
        XCTAssertEqual(imported.foregroundHex, "#D6DEEB")
        XCTAssertEqual(imported.backgroundHex, "#011627")
        XCTAssertEqual(imported.cursorHex, "#FFCC00")
        XCTAssertEqual(imported.selectionBackgroundHex, "#1D3B53")
        XCTAssertEqual(imported.ansiColorHexes[9], "#FF5555")
        XCTAssertEqual(imported.ansiColorHexes[15], "#FFFFFF")
    }

    func testImportsWindowsTerminalSchemeJSON() throws {
        let source = """
        {
          "name": "Stacio Night",
          "foreground": "#d6deeb",
          "background": "#011627",
          "cursorColor": "#80a4c2",
          "selectionBackground": "#1d3b53",
          "black": "#011627",
          "red": "#ef5350",
          "green": "#22da6e",
          "yellow": "#addb67",
          "blue": "#82aaff",
          "purple": "#c792ea",
          "cyan": "#21c7a8",
          "white": "#ffffff",
          "brightBlack": "#575656",
          "brightRed": "#ef5350",
          "brightGreen": "#22da6e",
          "brightYellow": "#ffeb95",
          "brightBlue": "#82aaff",
          "brightPurple": "#c792ea",
          "brightCyan": "#7fdbca",
          "brightWhite": "#ffffff"
        }
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: nil,
            fileExtension: "json"
        )

        XCTAssertEqual(theme.name, "Stacio Night")
        XCTAssertEqual(theme.sourceFormat, .windowsTerminal)
        XCTAssertEqual(theme.foregroundHex, "#D6DEEB")
        XCTAssertEqual(theme.backgroundHex, "#011627")
        XCTAssertEqual(theme.cursorHex, "#80A4C2")
        XCTAssertEqual(theme.selectionBackgroundHex, "#1D3B53")
        XCTAssertEqual(theme.ansiColorHexes[1], "#EF5350")
        XCTAssertEqual(theme.ansiColorHexes[12], "#82AAFF")
    }

    func testImportsITerm2ColorPreset() throws {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Foreground Color</key>
            <dict>
                <key>Red Component</key><real>0.8392156863</real>
                <key>Green Component</key><real>0.8705882353</real>
                <key>Blue Component</key><real>0.9215686275</real>
            </dict>
            <key>Background Color</key>
            <dict>
                <key>Red Component</key><real>0.1176470588</real>
                <key>Green Component</key><real>0.1176470588</real>
                <key>Blue Component</key><real>0.1803921569</real>
            </dict>
            <key>Ansi 0 Color</key>
            <dict>
                <key>Red Component</key><real>0.0</real>
                <key>Green Component</key><real>0.0</real>
                <key>Blue Component</key><real>0.0</real>
            </dict>
            <key>Ansi 15 Color</key>
            <dict>
                <key>Red Component</key><real>1.0</real>
                <key>Green Component</key><real>1.0</real>
                <key>Blue Component</key><real>1.0</real>
            </dict>
        </dict>
        </plist>
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: "Imported iTerm",
            fileExtension: "itermcolors"
        )

        XCTAssertEqual(theme.name, "Imported iTerm")
        XCTAssertEqual(theme.sourceFormat, .iterm2)
        XCTAssertEqual(theme.foregroundHex, "#D6DEEB")
        XCTAssertEqual(theme.backgroundHex, "#1E1E2E")
        XCTAssertEqual(theme.ansiColorHexes[0], "#000000")
        XCTAssertEqual(theme.ansiColorHexes[15], "#FFFFFF")
    }

    func testImportsAlacrittyTomlTheme() throws {
        let source = """
        [colors.primary]
        foreground = "#839496"
        background = "#002b36"

        [colors.cursor]
        cursor = "#93a1a1"

        [colors.selection]
        background = "#073642"

        [colors.normal]
        black = "#073642"
        red = "#dc322f"
        green = "#859900"
        yellow = "#b58900"
        blue = "#268bd2"
        magenta = "#d33682"
        cyan = "#2aa198"
        white = "#eee8d5"

        [colors.bright]
        black = "#002b36"
        red = "#cb4b16"
        green = "#586e75"
        yellow = "#657b83"
        blue = "#839496"
        magenta = "#6c71c4"
        cyan = "#93a1a1"
        white = "#fdf6e3"
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: "Solarized Dark",
            fileExtension: "toml"
        )

        XCTAssertEqual(theme.name, "Solarized Dark")
        XCTAssertEqual(theme.sourceFormat, .alacritty)
        XCTAssertEqual(theme.foregroundHex, "#839496")
        XCTAssertEqual(theme.backgroundHex, "#002B36")
        XCTAssertEqual(theme.cursorHex, "#93A1A1")
        XCTAssertEqual(theme.selectionBackgroundHex, "#073642")
        XCTAssertEqual(theme.ansiColorHexes[3], "#B58900")
        XCTAssertEqual(theme.ansiColorHexes[15], "#FDF6E3")
    }

    func testImportsGhosttyPaletteTheme() throws {
        let source = """
        foreground = #d6deeb
        background = #011627
        cursor-color = #80a4c2
        selection-background = #1d3b53
        palette = 0=#011627
        palette = 1=#ef5350
        palette = 2=#22da6e
        palette = 3=#addb67
        palette = 4=#82aaff
        palette = 5=#c792ea
        palette = 6=#21c7a8
        palette = 7=#ffffff
        palette = 8=#575656
        palette = 9=#ef5350
        palette = 10=#22da6e
        palette = 11=#ffeb95
        palette = 12=#82aaff
        palette = 13=#c792ea
        palette = 14=#7fdbca
        palette = 15=#ffffff
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: "Ghostty Night",
            fileExtension: "ghostty"
        )

        XCTAssertEqual(theme.sourceFormat, .ghostty)
        XCTAssertEqual(theme.foregroundHex, "#D6DEEB")
        XCTAssertEqual(theme.backgroundHex, "#011627")
        XCTAssertEqual(theme.cursorHex, "#80A4C2")
        XCTAssertEqual(theme.selectionBackgroundHex, "#1D3B53")
        XCTAssertEqual(theme.ansiColorHexes[14], "#7FDBCA")
    }

    func testImportsWezTermTomlTheme() throws {
        let source = """
        [colors]
        foreground = "#c0caf5"
        background = "#1a1b26"
        cursor_bg = "#c0caf5"
        selection_bg = "#33467c"
        ansi = [
          "#15161e", "#f7768e", "#9ece6a", "#e0af68",
          "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
        ]
        brights = [
          "#414868", "#f7768e", "#9ece6a", "#e0af68",
          "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
        ]
        """

        let theme = try TerminalThemeImporter.importTheme(
            data: Data(source.utf8),
            suggestedName: "Tokyo Night",
            fileExtension: "toml"
        )

        XCTAssertEqual(theme.sourceFormat, .wezTerm)
        XCTAssertEqual(theme.foregroundHex, "#C0CAF5")
        XCTAssertEqual(theme.backgroundHex, "#1A1B26")
        XCTAssertEqual(theme.cursorHex, "#C0CAF5")
        XCTAssertEqual(theme.selectionBackgroundHex, "#33467C")
        XCTAssertEqual(theme.ansiColorHexes[4], "#7AA2F7")
        XCTAssertEqual(theme.ansiColorHexes[15], "#C0CAF5")
    }

    func testAppSettingsStorePersistsImportedTerminalTheme() throws {
        let suiteName = "StacioCustomThemeStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let theme = TerminalColorTheme(
            name: "Solarized Portable",
            sourceFormat: .alacritty,
            foregroundHex: "#839496",
            backgroundHex: "#002B36",
            cursorHex: "#93A1A1",
            selectionBackgroundHex: "#073642",
            ansiColorHexes: [
                "#073642", "#DC322F", "#859900", "#B58900",
                "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                "#002B36", "#CB4B16", "#586E75", "#657B83",
                "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
            ]
        )

        store.update { settings in
            settings.terminalTheme = .custom
            settings.customTerminalTheme = theme
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.terminalTheme, .custom)
        XCTAssertEqual(snapshot.customTerminalTheme, theme)
    }

    func testBuiltInTerminalThemesProvideMultipleHighlightPalettes() throws {
        let themes = TerminalColorTheme.builtInThemes

        XCTAssertGreaterThanOrEqual(themes.count, 16)
        XCTAssertEqual(themes.first?.id, "stacio-dark")
        XCTAssertTrue(themes.map(\.name).contains("Solarized Dark"))
        XCTAssertTrue(themes.map(\.name).contains("Solarized Light"))
        XCTAssertTrue(themes.map(\.name).contains("Nordic Ops"))
        XCTAssertTrue(themes.map(\.name).contains("Graphite"))
        XCTAssertTrue(themes.map(\.name).contains("Flexoki Dark"))
        XCTAssertTrue(themes.map(\.name).contains("Hacker Green"))
        XCTAssertTrue(themes.map(\.name).contains("Cyberpunk"))
        XCTAssertTrue(themes.map(\.name).contains("Tokyo Night"))
        XCTAssertTrue(themes.map(\.name).contains("Gruvbox Dark"))
        XCTAssertNotNil(TerminalColorTheme.builtInTheme(id: "solarized-dark"))
        XCTAssertNotNil(TerminalColorTheme.builtInTheme(id: "nordic-ops"))
        XCTAssertNotNil(TerminalColorTheme.builtInTheme(id: "tokyo-night"))
    }

    func testAppSettingsStorePersistsBuiltInTerminalThemeSelection() throws {
        let suiteName = "StacioBuiltInThemeStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)

        store.update { settings in
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "nordic-ops"
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.terminalTheme, .dark)
        XCTAssertEqual(snapshot.terminalBuiltInThemeID, "nordic-ops")
    }

    func testTerminalAppearanceKeepsSystemAdaptiveThemeAsDefault() throws {
        let terminalView = StacioLocalTerminalView(frame: .zero)

        TerminalAppearanceApplier.apply(settings: AppSettings(), to: terminalView)

        XCTAssertEqual(AppSettings().terminalTheme, .system)
        XCTAssertEqual(terminalView.nativeForegroundColor, StacioDesignSystem.resolvedColor(.textColor, for: terminalView))
        XCTAssertEqual(terminalView.nativeBackgroundColor, StacioDesignSystem.resolvedColor(.textBackgroundColor, for: terminalView))
        XCTAssertEqual(
            terminalView.selectedTextBackgroundColor,
            StacioDesignSystem.resolvedColor(.selectedTextBackgroundColor, for: terminalView)
        )
    }

    func testTerminalAppearanceOnlyEnablesMetalWhenSwiftTermResourcesAreLoadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioSwiftTermResources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            TerminalAppearanceApplier.shouldEnableMetal(
                requested: true,
                bundleURL: root
            )
        )

        let resourceBundle = root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
        try "shader".write(
            to: resourceBundle.appendingPathComponent("Shaders.metal"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            TerminalAppearanceApplier.shouldEnableMetal(
                requested: true,
                bundleURL: root
            )
        )
        XCTAssertFalse(
            TerminalAppearanceApplier.shouldEnableMetal(
                requested: false,
                bundleURL: root
            )
        )
    }

    func testTerminalAppearanceSystemAdaptiveResetsNativeCursorAndSelectionColors() throws {
        let terminalView = StacioLocalTerminalView(frame: .zero)

        TerminalAppearanceApplier.apply(
            settings: AppSettings(terminalTheme: .dark, terminalBuiltInThemeID: "tokyo-night"),
            to: terminalView
        )
        TerminalAppearanceApplier.apply(settings: AppSettings(terminalTheme: .system), to: terminalView)

        XCTAssertEqual(terminalView.nativeForegroundColor, StacioDesignSystem.resolvedColor(.textColor, for: terminalView))
        XCTAssertEqual(terminalView.nativeBackgroundColor, StacioDesignSystem.resolvedColor(.textBackgroundColor, for: terminalView))
        XCTAssertEqual(terminalView.caretColor, StacioDesignSystem.resolvedColor(.textColor, for: terminalView))
        XCTAssertEqual(
            terminalView.selectedTextBackgroundColor,
            StacioDesignSystem.resolvedColor(.selectedTextBackgroundColor, for: terminalView)
        )
    }

    func testTerminalAppearanceAppliesCustomThemeColors() throws {
        let theme = TerminalColorTheme(
            name: "Stacio Test",
            sourceFormat: .portDesk,
            foregroundHex: "#D6DEEB",
            backgroundHex: "#011627",
            cursorHex: "#FFCC00",
            selectionBackgroundHex: "#1D3B53",
            ansiColorHexes: [
                "#000000", "#CC0000", "#00CC00", "#CCCC00",
                "#0000CC", "#CC00CC", "#00CCCC", "#CCCCCC",
                "#555555", "#FF5555", "#55FF55", "#FFFF55",
                "#5555FF", "#FF55FF", "#55FFFF", "#FFFFFF"
            ]
        )
        let terminalView = StacioLocalTerminalView(frame: .zero)

        TerminalAppearanceApplier.apply(
            settings: AppSettings(terminalTheme: .custom, customTerminalTheme: theme),
            to: terminalView
        )

        XCTAssertTrue(terminalView.nativeForegroundColor.portDeskHexString == "#D6DEEB")
        XCTAssertTrue(terminalView.nativeBackgroundColor.portDeskHexString == "#011627")
        XCTAssertTrue(terminalView.caretColor.portDeskHexString == "#FFCC00")
        XCTAssertTrue(terminalView.selectedTextBackgroundColor.portDeskHexString == "#1D3B53")
    }

    func testTerminalAppearanceAppliesSelectedBuiltInThemeColors() throws {
        let theme = try XCTUnwrap(TerminalColorTheme.builtInTheme(id: "solarized-dark"))
        let terminalView = StacioLocalTerminalView(frame: .zero)

        TerminalAppearanceApplier.apply(
            settings: AppSettings(terminalTheme: .dark, terminalBuiltInThemeID: "solarized-dark"),
            to: terminalView
        )

        XCTAssertEqual(terminalView.nativeForegroundColor.portDeskHexString, theme.foregroundHex)
        XCTAssertEqual(terminalView.nativeBackgroundColor.portDeskHexString, theme.backgroundHex)
        XCTAssertEqual(terminalView.caretColor.portDeskHexString, theme.cursorHex)
        XCTAssertEqual(terminalView.selectedTextBackgroundColor.portDeskHexString, theme.selectionBackgroundHex)
    }
}

private extension String {
    func containsStyledToken(_ token: String) -> Bool {
        styledSequence(before: token).map { $0 != "\u{001B}[0m" } ?? false
    }

    func containsBackgroundStyledToken(_ token: String) -> Bool {
        styledSequence(before: token)?.contains("48;2;") == true
    }

    func containsPromptBlueBackgroundCode() -> Bool {
        contains("48;2;213;236;255")
    }

    func containsStyleCode(_ code: String, before token: String) -> Bool {
        styledSequence(before: token)?.contains(code) == true
    }

    private func styledSequence(before token: String) -> String? {
        guard let tokenRange = range(of: token) else {
            return nil
        }
        let prefix = String(self[..<tokenRange.lowerBound])
        guard let sequenceStart = prefix.range(of: "\u{001B}[", options: .backwards),
              let sequenceEnd = prefix[sequenceStart.lowerBound...].firstIndex(of: "m")
        else {
            return nil
        }
        return String(prefix[sequenceStart.lowerBound...sequenceEnd])
    }
}

private func assertPromptCellsHaveBlueBackground(
    in terminal: Terminal,
    prompt: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for (column, character) in prompt.enumerated() {
        let charData = terminal.getCharData(col: column, row: 0)
        XCTAssertEqual(
            charData.map { String(terminal.getCharacter(for: $0)) },
            String(character),
            file: file,
            line: line
        )
        XCTAssertTrue(
            charData.map { isPromptBlueBackground($0.attribute.bg) } ?? false,
            file: file,
            line: line
        )
    }
}

private func isPromptBlueBackground(_ color: Attribute.Color) -> Bool {
    if case .trueColor(let red, let green, let blue) = color {
        return red == 213 && green == 236 && blue == 255
    }
    return false
}
