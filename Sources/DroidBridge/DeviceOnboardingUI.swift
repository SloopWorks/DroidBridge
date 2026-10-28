import AppKit
import DroidBridgeCore

extension LauncherController {
    @objc func sharedPreferenceChanged(_ sender: NSButton) {
        do {
            sharedPreferences=try DroidBridgePreferences.update { preferences in
                if sender === bulkPreference { preferences.bulkWrapperOnboardingEnabled=bulkPreference.state == .on }
                if sender === decorationsPreference { preferences.showAndroidSystemDecorations=decorationsPreference.state == .on }
            }
            onboardingButton.isEnabled=sharedPreferences.bulkWrapperOnboardingEnabled && !onboarding.isRunning && !onboardingPending
            if !sharedPreferences.bulkWrapperOnboardingEnabled { cancelOnboarding() }
            Task { _ = await availabilityMonitor.cycle() }
        } catch { status.stringValue="Could not save shared preferences: "+error.localizedDescription }
    }
    @objc func onboardDeviceApps() {
        guard !onboardingPending, !onboarding.isRunning, let device=selectedDevice, appsDeviceSerial == device.serial, !applications.isEmpty else { status.stringValue="Wait for the selected device's complete application list before onboarding."; return }
        let capturedApps=applications, chosenBackend=backend
        onboardingPending=true; onboardingButton.isEnabled=false; onboardingCancel.isEnabled=true
        onboardingStatus.stringValue="Preparing to add \(capturedApps.count) apps from \(device.model)…"
        onboardingAdmissionTask=Task { [weak self] in
            guard let self else { return }
            defer { self.onboardingPending=false; self.onboardingButton.isEnabled=self.bulkPreference.state == .on && !self.onboarding.isRunning; self.onboardingCancel.isEnabled=self.onboarding.isRunning; self.pumpIcons() }
            self.iconQueue.removeAll()
            let pending=Array(self.iconTasks.values); pending.forEach { $0.cancel() }
            for task in pending { await task.value }
            guard !Task.isCancelled, !self.quitting else { return }
            guard await DeviceReadiness.isReady(device:device,toolchain:self.toolchain) else { self.onboardingStatus.stringValue="The captured device is unavailable or still booting. Connect it, then try again."; return }
            guard !Task.isCancelled, !self.quitting else { return }
            do { try self.onboarding.begin(device:device,applications:capturedApps,backend:chosenBackend) }
            catch { self.onboardingStatus.stringValue=error.localizedDescription }
        }
    }
    @objc func cancelOnboarding() { onboardingAdmissionTask?.cancel(); onboarding.cancel() }
    @objc func showOnboardingDetails() {
        let alert=NSAlert(); alert.messageText="Device app onboarding results"
        alert.informativeText="\(onboarding.progress.summary)\n\(onboarding.omittedFailures) earlier details omitted; the most recent 100 are retained."
        let text=NSTextView(frame:NSRect(x:0,y:0,width:620,height:260)); text.isEditable=false; text.font = .monospacedSystemFont(ofSize:11,weight:.regular); text.string=onboarding.failures.isEmpty ? "No per-app errors or icon warnings recorded." : onboarding.failures.joined(separator:"\n\n")
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:640,height:280)); scroll.documentView=text; scroll.hasVerticalScroller=true; alert.accessoryView=scroll
        if let window { alert.beginSheetModal(for:window) } else { alert.runModal() }
    }
}
