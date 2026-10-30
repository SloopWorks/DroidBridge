import AppKit
import DroidBridgeCore

extension LauncherController {
    @objc func showCompanion() { companion.show() }

    /// A current companion snapshot can improve the visible catalog without
    /// changing ADB readiness or delaying an immutable wrapper launch.
    func acceptCompanionCatalog(serial: String, apps: [CompanionApp]) {
        guard !isWrapper, !quitting, selectedDevice?.serial == serial, readySerials.contains(serial), apps.count <= 4096,
              apps.allSatisfy({ (try? AndroidDiscovery.validatePackage($0.packageName)) != nil }) else { return }
        applications = apps.filter { $0.launchable != false }.map { AndroidApplication(packageName: $0.packageName, name: $0.label) }
        appsDeviceSerial = serial; appsError = nil; filterApps()
    }

    /// The broker has already published accepted policy. This host only
    /// materializes the selected wrapper and reports its actual final result;
    /// it never writes a competing selection decision over a newer broker map.
    func applyCompanionExport(device: AndroidDevice, package: String, selected: Bool) async throws -> [String: CompanionJSON] {
        guard let phone = companion.device(for: device.serial), phone.connected, !quitting else { throw CompanionBoundaryError("phone_unavailable", "Connect the paired phone before updating its Mac app.") }
        let reply = try await companion.broker.request(operation: "export_selection_get", payload: ["device_id": .string(phone.id)])
        guard reply.data["selection"]?.object?[package]?.bool == selected else { throw CompanionBoundaryError("export_superseded", "A newer Spotlight choice superseded this request.") }
        try AndroidDiscovery.validatePackage(package)
        if selected {
            guard (try DroidBridgePreferences.load()).bulkWrapperOnboardingEnabled else {
                return ["phase": .string("saved_disabled"), "selected": .bool(true), "wrapper_created": .bool(false), "message": .string("Selection saved. Enable device apps in Spotlight in the Mac launcher to create the wrapper.")]
            }
            guard !onboarding.isRunning, !onboardingPending, managedNameRepair?.isRunning != true else { throw CompanionBoundaryError("wrapper_update_busy", "Another Mac app update is running. Retry this Spotlight choice after it finishes.", retryable: true) }
            let lease = try DeviceOnboardingLease(root: managedCatalog.paths.privateRoot); defer { lease.release() }
            let known = appsDeviceSerial == device.serial ? applications.first(where: { $0.packageName == package }) : nil
            let app = known ?? AndroidApplication(packageName: package, name: package)
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path })
            let catalog = managedCatalog, chosenBackend = backend
            let reservation = try await Task.detached { try catalog.reserve(device: device, application: app, backend: chosenBackend, runningBundlePaths: running, adoptManualWrappers: true) }.value
            do {
                let png = try await iconProvider.icon(device: device, application: app)
                try Task.checkCancellation(); guard !quitting else { throw CancellationError() }
                _ = try await MacAppWrapper.createManaged(application: reservation.application, device: device, backend: reservation.backend, iconPNG: png, reservation: reservation)
                let latest = try await companion.broker.request(operation: "export_selection_get", payload: ["device_id": .string(phone.id)])
                guard latest.data["selection"]?.object?[package]?.bool == true else { throw CompanionBoundaryError("export_superseded", "The app was deselected before its wrapper was published.") }
                let nowRunning = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path })
                _ = try await Task.detached { try catalog.commit(reservation, runningBundlePaths: nowRunning) }.value
            } catch { try? await Task.detached { try catalog.abandon(reservation) }.value; throw error }
        }
        _ = await availabilityMonitor.cycle()
        let catalog = managedCatalog
        let record = try await Task.detached { try catalog.records().first { $0.deviceSerial == device.serial && $0.packageName == package } }.value
        if selected {
            guard record?.availability == .active else { throw CompanionBoundaryError("wrapper_pending", "The Mac app was built but availability is not active yet. Check Onboarding Details and reconnect the phone.", retryable: true) }
            return ["phase": .string("active"), "selected": .bool(true), "wrapper_created": .bool(true)]
        }
        // Running wrappers may retain a visible location until they quit; the
        // accepted policy still denies fresh admission immediately.
        return ["phase": .string(record?.location == .active ? "hidden_when_closed" : "inactive"), "selected": .bool(false), "message": .string("New launches are disabled. Existing running windows are preserved.")]
    }
}
