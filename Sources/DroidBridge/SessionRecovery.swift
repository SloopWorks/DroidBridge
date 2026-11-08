import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor extension LauncherController {
    func enqueueRecovery(_ session: BridgeSession, reason: SessionRecoveryReason) {
        let id = session.descriptor.id
        guard !quitting, sessions[id] === session else { return }
        var retry = reconnectRetries[id] ?? ReconnectRetry()
        retry.interrupted(at: Date())
        reconnectRetries[id] = retry
        sessionStates[id] = "disconnected"
        if reason == .deviceSleeping { recoveryWaitingForWake.insert(id) }
        session.recordClientEvent("recovery_enqueued", details: ["reason": reason.rawValue, "attempts": String(retry.failures)])
        presentRecovery(session)
    }

    func presentRecovery(_ session: BridgeSession) {
        let id = session.descriptor.id
        guard sessions[id] === session, let retry = reconnectRetries[id] else { return }
        let message: String
        if reconnect.state != .on {
            message = "Connection interrupted.\nAutomatic recovery is off. Choose Retry."
        } else if retry.failures >= ReconnectRetry.maximumAttempts {
            message = "Recovery paused after three attempts.\nCheck the connection, wake and unlock the phone, then Retry."
        } else if recoveryWaitingForWake.contains(id) {
            message = "Phone is asleep.\nWake and unlock it. This app will reconnect automatically."
        } else {
            message = "Connection interrupted.\nWaiting to reconnect automatically…"
        }
        hosts[id]?.video.statusMessage = message
        hosts[id]?.video.canRetry = !retrying.contains(id)
        status.stringValue = "\(session.descriptor.application.name): \(message.replacingOccurrences(of: "\n", with: " "))"
    }

    /// One refresh owns recovery admission. Every await rechecks the exact
    /// original intent so Close, manual Retry and Quit cannot resurrect it.
    func recoverInterruptedSessions(ready: Set<String>) async {
        var videoReadiness: [String: DeviceVideoReadiness] = [:]
        for session in Array(sessions.values) {
            let id = session.descriptor.id
            guard sessionStates[id] == "disconnected" else { continue }
            presentRecovery(session)
            guard !quitting, !Task.isCancelled, !retrying.contains(id),
                  reconnectRetries[id]?.admits(intentPresent: sessions[id] === session, ready: ready.contains(session.descriptor.device.serial), enabled: reconnect.state == .on, now: Date()) == true else { continue }
            await session.stopAndWait()
            guard !quitting, !Task.isCancelled, sessions[id] === session, !retrying.contains(id), reconnect.state == .on else { continue }
            let device = session.descriptor.device
            let readiness: DeviceVideoReadiness
            if let cached = videoReadiness[device.serial] { readiness = cached }
            else {
                readiness = await DeviceVideoReadiness.probe(device: device, toolchain: toolchain)
                videoReadiness[device.serial] = readiness
            }
            guard !quitting, !Task.isCancelled, sessions[id] === session, !retrying.contains(id), reconnect.state == .on else { continue }
            if readiness == .sleeping {
                if recoveryWaitingForWake.insert(id).inserted {
                    session.recordClientEvent("recovery_waiting_for_wake", details: [:])
                }
                presentRecovery(session)
                continue
            }
            recoveryWaitingForWake.remove(id)
            guard var retry = reconnectRetries[id], retry.admits(intentPresent: true, ready: true, enabled: true, now: Date()) else { continue }
            retry.attempted(at: Date()); reconnectRetries[id] = retry
            session.recordClientEvent("recovery_attempt", details: ["attempt": String(retry.failures)])
            let descriptor = session.descriptor
            _ = await launch(device: device, app: descriptor.application, configuration: descriptor.configuration, readinessChecked: true, replacing: id, replacementReason: "reconnect_replacement", recoveryBudget: retry, admissionCheck: { [weak self] in
                guard let self, !self.quitting, self.reconnect.state == .on, !self.retrying.contains(id) else { throw CancellationError() }
            })
        }
        updateSessions()
    }
}
