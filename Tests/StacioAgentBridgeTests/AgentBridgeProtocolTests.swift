import Foundation
import XCTest
@testable import StacioAgentBridge

final class AgentBridgeProtocolTests: XCTestCase {
    func testRunCommandRequestRoundTripsWithoutSecrets() throws {
        let request = AgentBridgeRequest(
            id: "req-1",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 42),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .currentTerminal,
                    command: "export TOKEN=secret-value && uptime",
                    follow: true
                )
            )
        )

        let data = try JSONEncoder().encode(request.redactedForLog())
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("codex"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertFalse(text.contains("secret-value"))
    }

    func testTerminalOutputRedactionPreservesLineBreaks() {
        let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(
            "CPU 20%\nTOKEN=secret-value\nMemory 40%"
        )

        XCTAssertEqual(redacted, "CPU 20%\n[redacted]\nMemory 40%")
    }

    func testRiskClassifierMarksDestructiveCommands() {
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "rm -rf /tmp/build"),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "uptime"),
            .readOnly
        )
    }

    func testRiskClassifierCoversContainerOperations() {
        for command in [
            "docker volume prune -f",
            "docker network prune --force",
            "docker container rm web-1",
            "docker swarm leave --force",
            "docker plugin remove rexray/ebs"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .destructive, command)
        }

        for command in [
            "docker compose restart api",
            "docker service update --image app:2 api",
            "docker login registry.example.com",
            "docker context use production",
            "docker plugin disable rexray/ebs",
            "docker manifest push registry.example.com/app:latest",
            "docker buildx bake --file docker-bake.hcl",
            "docker compose --profile prod up -d"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .network, command)
        }

        for command in [
            "docker compose ps",
            "docker service ls",
            "docker image inspect nginx:latest",
            "docker context ls",
            "docker buildx inspect",
            "docker plugin ls",
            "docker manifest inspect nginx:latest",
            "docker system df",
            "docker images | head -20",
            "docker info",
            "docker stats --no-stream",
            "free -h"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }
    }

    func testRiskClassifierTreatsDiagnosticStderrDiscardAsReadOnly() {
        for command in [
            "du -sh ./* 2>/dev/null | sort -h | tail -20",
            "find /var/log -type f 2>/dev/null | wc -l"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }
    }

    func testRiskClassifierIgnoresQuotedDiagnosticPatterns() {
        for command in [
            #"echo "rm -rf /tmp/build""#,
            #"grep -R "docker rm" /var/log"#,
            #"printf '%s\n' 'kubectl delete pod api-0'"#,
            #"journalctl -u docker --since "2 hours ago""#
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }
    }

    func testRiskClassifierEscalatesShellWrappedCommands() {
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: #"sh -c "rm -rf /tmp/build""#),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: #"bash -lc "systemctl restart nginx""#),
            .network
        )
    }

    func testRiskClassifierEscalatesCommandsAfterBackgroundSeparator() {
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "uptime & rm -rf /tmp/build"),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "journalctl -u sshd & systemctl restart sshd"),
            .network
        )
    }

    func testRiskClassifierEscalatesCommandsLaunchedThroughXargs() {
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "docker ps -q | xargs docker rm -f"),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "kubectl get pods -o name | xargs -n 1 kubectl delete"),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "printf '%s\\n' nginx | xargs systemctl restart"),
            .network
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "docker ps -q | xargs docker inspect"),
            .readOnly
        )
    }

    func testRiskClassifierStillTreatsStdoutRedirectionAsWrite() {
        for command in [
            "df -h > /tmp/disk.txt",
            "uptime >> /tmp/load.txt",
            "echo ok 1>/tmp/status.txt",
            "journalctl -u sshd &> /tmp/sshd.log"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .write, command)
        }
    }

    func testRiskClassifierHandlesFlagsBeforeOperationalVerbs() {
        for command in [
            "kubectl -n prod delete pod api-0",
            "sudo kubectl --context prod delete deployment api",
            "sudo -n kubectl --context prod delete deployment api",
            "docker --context prod system prune -f",
            "podman --remote volume prune -f",
            "helm -n prod uninstall api",
            "docker-compose down --volumes",
            "compose --project-name api down",
            "firewall-cmd --permanent --remove-service=http"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .destructive, command)
        }

        for command in [
            "kubectl -n prod rollout restart deployment/api",
            "sudo systemctl --user restart nginx.service",
            "systemctl --no-pager enable nginx.service",
            "systemctl daemon-reload",
            "helm --namespace prod upgrade api ./chart",
            "nginx -s reload",
            "service nginx restart",
            "firewall-cmd --reload",
            "ip link set eth0 down"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .network, command)
        }

        for command in [
            "kubectl -n prod get pods",
            "journalctl -u sshd --since yesterday",
            "systemctl --no-pager status nginx.service",
            "helm -n prod status api",
            "nginx -t -c /etc/nginx/nginx.conf",
            "docker-compose ps",
            "compose logs --tail 20",
            "firewall-cmd --list-all",
            "ip addr show eth0"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }
    }

    func testRiskClassifierKeepsRPMFamilyDiagnosticSubcommandsReadOnly() {
        for command in [
            "yum check-update",
            "dnf check-update --security",
            "dnf updateinfo list security",
            "yum history info 42",
            "dnf repoquery --installed nginx",
            "yum list installed docker-ce"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }
    }

    func testRiskClassifierEscalatesCommonKubectlMutatingAndSessionCommands() {
        for command in [
            "kubectl -n prod create configmap api-env --from-literal=A=B",
            "kubectl patch deployment api -p '{\"spec\":{\"replicas\":2}}'",
            "kubectl edit deployment/api",
            "kubectl set image deployment/api api=registry.example.com/api:2",
            "kubectl label pod api-0 tier=frontend --overwrite",
            "kubectl annotate deployment api owner=ops",
            "kubectl exec deploy/api -- touch /tmp/reload",
            "kubectl cp ./config.yaml prod/api-0:/tmp/config.yaml",
            "kubectl port-forward svc/api 8080:80"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .network, command)
        }
    }

    func testRiskClassifierCoversIaCAndConfigurationManagementTools() {
        for command in [
            "terraform validate",
            "terraform plan",
            "tofu show tfplan",
            "ansible-inventory --list",
            "ansible all -m ping",
            "ansible-playbook site.yml --check --diff"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }

        for command in [
            "terraform init -upgrade",
            "terraform plan -out=tfplan",
            "terraform apply -auto-approve",
            "tofu import aws_instance.web i-123456",
            "ansible-playbook site.yml",
            "ansible all -m service -a 'name=nginx state=restarted'"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .network, command)
        }

        for command in [
            "terraform destroy -auto-approve",
            "terraform apply -destroy",
            "terraform state rm aws_instance.old",
            "tofu workspace delete prod",
            "ansible all -m shell -a 'rm -rf /tmp/build'"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .destructive, command)
        }
    }

    func testRiskClassifierCoversProcessManagersDatabaseClientsAndCloudCLIs() {
        for command in [
            "supervisorctl status",
            "pm2 logs api --lines 20",
            "psql -c 'select * from pg_stat_activity'",
            "mysql -e 'show processlist'",
            "redis-cli info",
            "aws s3 ls s3://prod-bucket",
            "gcloud compute instances list",
            "az group list"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .readOnly, command)
        }

        for command in [
            "supervisorctl restart nginx",
            "pm2 restart api",
            "psql -c 'alter table users add column locked boolean'",
            "mysql -e 'update users set disabled=1 where id=42'",
            "redis-cli set feature:on 1",
            "aws s3 cp ./dist s3://prod-bucket/dist --recursive",
            "gcloud container clusters get-credentials prod",
            "az webapp restart --name api --resource-group prod"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .network, command)
        }

        for command in [
            "pm2 delete api",
            "psql -c 'drop database prod'",
            "mysql -e 'delete from users where id=42'",
            "redis-cli flushall",
            "aws s3 rm s3://prod-bucket/dist --recursive",
            "gcloud compute instances delete prod-1 --zone asia-east1-a",
            "az group delete --name prod -y"
        ] {
            XCTAssertEqual(AgentActionClassifier.risk(forCommand: command), .destructive, command)
        }
    }

    func testRiskClassifierCoversRemoteCopyAndSSHNestedCommands() {
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "rsync -av ./dist/ host:/srv/app/"),
            .network
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "rsync -av --delete ./dist/ host:/srv/app/"),
            .destructive
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "scp ./dist/app.tar.gz host:/srv/app/"),
            .network
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "ssh prod 'uptime'"),
            .network
        )
        XCTAssertEqual(
            AgentActionClassifier.risk(forCommand: "ssh prod 'rm -rf /tmp/build'"),
            .destructive
        )
    }

    func testRunCommandParserBuildsFollowRequest() throws {
        let request = try AgentCLIParser.parse([
            "agent", "run", "--target", "current", "--command", "uptime", "--follow"
        ])

        guard case .runCommand(let run) = request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.target, .currentTerminal)
        XCTAssertEqual(run.command, "uptime")
        XCTAssertTrue(run.follow)
    }

    func testRunCommandParserDefaultsToTextOutputMode() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "run", "--target", "current", "--command", "uptime", "--follow"
        ])

        XCTAssertEqual(invocation.outputMode, .text)
        guard case .runCommand(let run) = invocation.request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testRunCommandParserSupportsJsonOutputModeWithoutPassingFlagToCommand() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "run", "--json", "--target", "current", "--command", "uptime", "--follow"
        ])

        XCTAssertEqual(invocation.outputMode, .json)
        guard case .runCommand(let run) = invocation.request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testRunCommandParserSupportsJsonOutputModeBeforeSubcommand() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "--json", "run", "--target", "current", "--command", "uptime", "--follow"
        ])

        XCTAssertEqual(invocation.outputMode, .json)
        guard case .runCommand(let run) = invocation.request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testRunCommandParserSupportsSocketPathBeforeSubcommand() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "--socket", "/tmp/stacio-agent.sock",
            "run", "--target", "current", "--command", "uptime", "--follow"
        ])

        XCTAssertEqual(invocation.socketPath, "/tmp/stacio-agent.sock")
        guard case .runCommand(let run) = invocation.request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testRunCommandParserSupportsSocketPathInsideRunOptionsWithoutPassingFlagToCommand() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "run", "--socket", "/tmp/stacio-agent.sock",
            "--target", "current", "--command", "uptime", "--follow"
        ])

        XCTAssertEqual(invocation.socketPath, "/tmp/stacio-agent.sock")
        guard case .runCommand(let run) = invocation.request.action else {
            return XCTFail("expected runCommand")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testCancelParserBuildsCancelTaskRequest() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "cancel", "--request", "req-background"
        ])

        XCTAssertEqual(invocation.outputMode, .text)
        guard case .cancelTask(let requestID) = invocation.request.action else {
            return XCTFail("expected cancelTask")
        }
        XCTAssertEqual(requestID, "req-background")
    }

    func testPauseParserBuildsPauseTaskRequest() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "pause", "--request-id", "req-visible"
        ])

        XCTAssertEqual(invocation.outputMode, .text)
        guard case .pauseTask(let requestID) = invocation.request.action else {
            return XCTFail("expected pauseTask")
        }
        XCTAssertEqual(requestID, "req-visible")
    }

    func testTakeoverParserBuildsTakeOverTaskRequest() throws {
        let invocation = try AgentCLIParser.parseInvocation([
            "agent", "takeover", "req-background"
        ])

        XCTAssertEqual(invocation.outputMode, .text)
        guard case .takeOverTask(let requestID) = invocation.request.action else {
            return XCTFail("expected takeOverTask")
        }
        XCTAssertEqual(requestID, "req-background")
    }

    func testSocketPathResolutionPrefersExplicitThenEnvironmentThenDefault() {
        XCTAssertEqual(
            AgentBridgeSocketPath.resolve(
                explicitPath: "/tmp/explicit.sock",
                environment: ["STACIO_AGENT_SOCKET": "/tmp/env.sock"]
            ),
            "/tmp/explicit.sock"
        )
        XCTAssertEqual(
            AgentBridgeSocketPath.resolve(
                explicitPath: nil,
                environment: ["STACIO_AGENT_SOCKET": "/tmp/env.sock"]
            ),
            "/tmp/env.sock"
        )
        XCTAssertEqual(
            AgentBridgeSocketPath.resolve(
                explicitPath: nil,
                environment: ["STACIO_AGENT_SOCKET": "/tmp/env.sock"]
            ),
            "/tmp/env.sock"
        )
        XCTAssertEqual(
            AgentBridgeSocketPath.resolve(explicitPath: nil, environment: [:]),
            AgentBridgeSocketPath.defaultPath
        )
    }

    func testSocketClientReportsReadableMessageWhenBridgeIsUnavailable() throws {
        let socketPath = "/tmp/pd-missing-\(UUID().uuidString.prefix(8)).sock"
        let client = AgentBridgeSocketClient(socketPath: socketPath)
        let request = AgentBridgeRequest(
            id: "req-unavailable",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 42),
            action: .listSessions
        )

        XCTAssertThrowsError(try client.send(request: request, onLine: { _ in })) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Stacio Agent Bridge"))
            XCTAssertTrue(message.contains(socketPath))
            XCTAssertTrue(message.contains("打开 Stacio"))
        }
    }

    func testTraceOutputRendererFormatsStreamingEventsForTerminalHumans() throws {
        let event = AgentTraceEvent(
            requestID: "req-1",
            state: .running,
            message: "命令已在终端执行，输出将实时显示",
            redactedCommand: "uptime"
        )
        let line = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        let rendered = AgentCLIOutputRenderer.render(socketLine: line, mode: .text)

        XCTAssertTrue(rendered.contains("[running]"))
        XCTAssertTrue(rendered.contains("命令已在终端执行"))
        XCTAssertTrue(rendered.contains("uptime"))
        XCTAssertFalse(rendered.contains(#""requestID""#))
    }

    func testTraceOutputRendererReturnsExplicitTerminalContentAndStatusToLocalAgent() throws {
        let event = AgentTraceEvent(
            requestID: "req-output",
            state: .completed,
            message: "本次命令已完成：Linux dev 6.8.0",
            redactedCommand: "uname -a",
            metadata: [
                "terminalOutputSummary": "Linux dev 6.8.0",
                "completionConfidence": "observedIdle"
            ]
        )
        let line = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        let rendered = AgentCLIOutputRenderer.render(socketLine: line, mode: .text)

        XCTAssertTrue(rendered.contains("[terminal-status] completed"))
        XCTAssertTrue(rendered.contains("request=req-output"))
        XCTAssertTrue(rendered.contains("[terminal-command] uname -a"))
        XCTAssertTrue(rendered.contains("[terminal-output]\nLinux dev 6.8.0\n[/terminal-output]"))
    }

    func testTraceOutputRendererKeepsRawLinesInJsonMode() throws {
        let event = AgentTraceEvent(
            requestID: "req-1",
            state: .queued,
            message: "已排队",
            redactedCommand: nil
        )
        let line = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        XCTAssertEqual(AgentCLIOutputRenderer.render(socketLine: line, mode: .json), line)
    }

    func testTraceEventSessionMetadataRoundTripsAndRendersForTextMode() throws {
        let event = AgentTraceEvent(
            requestID: "req-sessions",
            state: .completed,
            message: "dev@example.com",
            redactedCommand: nil,
            metadata: [
                "type": "terminalSession",
                "runtimeID": "term_1",
                "title": "dev@example.com",
                "kind": "remote",
                "environment": "development",
                "current": "true",
                "currentDirectory": "/srv/app",
                "subtitle": "ssh · /srv/app"
            ]
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentTraceEvent.self, from: data)
        let rendered = AgentCLIOutputRenderer.render(socketLine: String(decoding: data, as: UTF8.self), mode: .text)

        XCTAssertEqual(decoded.metadata?["runtimeID"], "term_1")
        XCTAssertTrue(rendered.contains("term_1"))
        XCTAssertTrue(rendered.contains("dev@example.com"))
        XCTAssertTrue(rendered.contains("remote"))
        XCTAssertTrue(rendered.contains("development"))
        XCTAssertTrue(rendered.contains("current"))
        XCTAssertTrue(rendered.contains("/srv/app"))
        XCTAssertTrue(rendered.contains("ssh · /srv/app"))
    }

    func testTraceExitStatusRemainsSuccessForRunningAndCompletedEvents() throws {
        var tracker = AgentCLITraceExitStatus()
        tracker.observe(socketLine: traceLine(state: .running, message: "命令已在终端执行"))
        tracker.observe(socketLine: traceLine(state: .completed, message: "完成"))

        XCTAssertEqual(tracker.exitCode, 0)
    }

    func testTraceExitStatusFailsWhenStreamReportsFailedOrCancelledEvents() throws {
        var failedTracker = AgentCLITraceExitStatus()
        failedTracker.observe(socketLine: traceLine(state: .failed, message: "未找到可操作终端"))

        var cancelledTracker = AgentCLITraceExitStatus()
        cancelledTracker.observe(socketLine: traceLine(state: .cancelled, message: "操作已取消"))

        XCTAssertEqual(failedTracker.exitCode, 1)
        XCTAssertEqual(cancelledTracker.exitCode, 1)
    }

    func testTraceExitStatusTreatsSuccessfulCancelControlAsSuccess() throws {
        var tracker = AgentCLITraceExitStatus()
        tracker.observe(socketLine: controlTraceLine(
            state: .cancelled,
            message: "AI 独立任务已取消。",
            control: "cancel"
        ))

        XCTAssertEqual(tracker.exitCode, 0)
    }

    func testTraceOutputRendererShowsRequestIDForControlEvents() throws {
        let rendered = AgentCLIOutputRenderer.render(
            socketLine: controlTraceLine(
                state: .cancelled,
                message: "AI 独立任务已取消。",
                control: "cancel"
            ),
            mode: .text
        )

        XCTAssertTrue(rendered.contains("[cancelled]"))
        XCTAssertTrue(rendered.contains("req-control"))
        XCTAssertTrue(rendered.contains("cancel"))
        XCTAssertTrue(rendered.contains("sleep 60"))
    }

    private func traceLine(state: AgentTraceState, message: String) -> String {
        let event = AgentTraceEvent(
            requestID: "req-exit",
            state: state,
            message: message,
            redactedCommand: "uptime"
        )
        let data = try! JSONEncoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    private func controlTraceLine(state: AgentTraceState, message: String, control: String) -> String {
        let event = AgentTraceEvent(
            requestID: "req-control",
            state: state,
            message: message,
            redactedCommand: "sleep 60",
            metadata: [
                "executionMode": "backgroundTask",
                "control": control
            ]
        )
        let data = try! JSONEncoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }
}
