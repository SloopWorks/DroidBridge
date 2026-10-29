import AppKit
import DroidBridgeCore

/// One GUI task drains explicit requests and finite maintenance batches. Shared
/// preferences and the Core actuation mutex coordinate independent wrappers.
@MainActor final class PhoneDisplayControls {
    private struct Request {let device:AndroidDevice;let token=UUID()}
    private let power:PhoneDisplayPower
    private var running:[String:AndroidDevice]=[:],known:[String:AndroidDevice]=[:]
    private var pendingOn:[String:Request]=[:],pendingOff:[String:Request]=[:]
    private var due:[String:Date]=[:],failures:[String:Int]=[:]
    private var work:Task<Void,Never>?
    private var stopped=false
    var onMessage:((String)->Void)?
    init(toolchain:Toolchain) {power=PhoneDisplayPower(toolchain:toolchain)}
    func request(device:AndroidDevice,off:Bool,immediate:Bool=true) throws {
        try AndroidDiscovery.validateSerial(device.serial)
        try DroidBridgePreferences.update {prefs in
            if off {prefs.screenOffDeviceSerials.insert(device.serial)} else {prefs.screenOffDeviceSerials.remove(device.serial)}
        }
        if off {
            pendingOn.removeValue(forKey:device.serial)
            if immediate {pendingOff[device.serial]=Request(device:device)}
        } else {pendingOff.removeValue(forKey:device.serial);pendingOn[device.serial]=Request(device:device)}
        due[device.serial] = .distantPast;failures.removeValue(forKey:device.serial)
        drain()
    }
    func poll(runningDevices:[AndroidDevice],knownDevices:[AndroidDevice]) {
        running=Dictionary(runningDevices.map{($0.serial,$0)},uniquingKeysWith:{first,_ in first})
        known=Dictionary(knownDevices.map{($0.serial,$0)},uniquingKeysWith:{first,_ in first})
        drain()
    }
    private func drain() {
        guard !stopped,work==nil,let prefs=try? DroidBridgePreferences.load() else {return}
        for serial in Array(pendingOn.keys) where prefs.screenOffDeviceSerials.contains(serial) {pendingOn.removeValue(forKey:serial)}
        for serial in Array(pendingOff.keys) where !prefs.screenOffDeviceSerials.contains(serial) {pendingOff.removeValue(forKey:serial)}
        let live=Set(running.keys).union(pendingOn.keys).union(pendingOff.keys)
        due=due.filter{live.contains($0.key)};failures=failures.filter{live.contains($0.key)}
        var off=running.filter{prefs.screenOffDeviceSerials.contains($0.key)}
        for (serial,request) in pendingOff {off[serial]=request.device}
        let onKeys=pendingOn.keys.filter{Date()>=(due[$0] ?? .distantPast)}.sorted()
        let offKeys=off.keys.filter{Date()>=(due[$0] ?? .distantPast) && pendingOn[$0]==nil}.sorted()
        let requests=(onKeys.map{($0,false)}+offKeys.map{($0,true)}).prefix(2)
        guard !requests.isEmpty else {return}
        let batch=Array(requests)
        work=Task { [self] in
            defer {work=nil;if !stopped {drain()}}
            for (serial,offRequested) in batch {
                guard !stopped,!Task.isCancelled else {break}
                guard let current=try? DroidBridgePreferences.load(),current.screenOffDeviceSerials.contains(serial)==offRequested else {continue}
                let request=offRequested ? pendingOff[serial] : pendingOn[serial]
                guard let device=known[serial] ?? request?.device ?? running[serial] else {continue}
                do {
                    let result=try await (offRequested ? power.setScreenOffIfRequested(device:device) : power.turnScreenOn(device:device))
                    if offRequested {
                        if pendingOff[serial]?.token==request?.token {pendingOff.removeValue(forKey:serial)}
                    } else if pendingOn[serial]?.token==request?.token {pendingOn.removeValue(forKey:serial)}
                    failures.removeValue(forKey:serial);due[serial]=Date().addingTimeInterval(10)
                    if request != nil {
                        switch result {
                        case .offVerified:onMessage?("\(device.model): phone screen OFF verified. Mac app sessions continue.")
                        case .onVerified:onMessage?("\(device.model): phone screen ON verified.")
                        case .intentNoLongerRequested:break
                        }
                    }
                } catch is CancellationError {break}
                  catch {
                    // An ON action remains queued across transport/lock errors.
                    // A newer OFF preference supersedes it in drain().
                    if (try? DroidBridgePreferences.load().screenOffDeviceSerials.contains(serial))==false {
                        if pendingOn[serial]==nil {pendingOn[serial]=Request(device:device)}
                    }
                    let count=min(4,(failures[serial] ?? 0)+1);failures[serial]=count
                    due[serial]=Date().addingTimeInterval(min(60,5*pow(2,Double(count-1))))
                    if !stopped {onMessage?("\(device.model): phone screen request will retry. \(String(error.localizedDescription.prefix(350)))")}
                }
            }
        }
    }
    func cancel() {stopped=true;work?.cancel()}
    func cancelAndWait() async {cancel();if let work {await work.value}}
}

extension LauncherController {
    func phoneDisplayDevice() ->AndroidDevice? {
        if let focused=hosts.values.first(where:{$0.window === NSApp.keyWindow}) {return focused.session.descriptor.device}
        if isWrapper,let serial=preferredSerial {
            return devices.first{$0.serial==serial} ?? sessions.values.first{$0.descriptor.device.serial==serial}?.descriptor.device ?? AndroidDevice(serial:serial,model:"Android device")
        }
        return selectedDevice
    }
    func pollPhoneDisplayControls() {
        guard !quitting else {return}
        let active=sessions.values.filter{$0.state == .running}.map{$0.descriptor.device}
        phoneDisplayControls.poll(runningDevices:active,knownDevices:devices)
        let device=phoneDisplayDevice()
        phoneScreenPreference.isEnabled=device != nil
        phoneScreenPreference.state=device.map{((try? DroidBridgePreferences.load().screenOffDeviceSerials.contains($0.serial))==true) ? .on : .off} ?? .off
    }
    @objc func phoneScreenPreferenceChanged(_ sender:NSButton) {
        guard let device=phoneDisplayDevice() else {return}
        do {try phoneDisplayControls.request(device:device,off:sender.state == .on,immediate:sender.state == .off);pollPhoneDisplayControls()}
        catch {status.stringValue=error.localizedDescription;pollPhoneDisplayControls()}
    }
    @objc func turnPhoneScreenOff() {
        guard let device=phoneDisplayDevice() else {status.stringValue="Select a connected Android device first.";return}
        do {try phoneDisplayControls.request(device:device,off:true);pollPhoneDisplayControls()}
        catch {status.stringValue=error.localizedDescription}
    }
    @objc func turnPhoneScreenOn() {
        guard let device=phoneDisplayDevice() else {status.stringValue="Select a connected Android device first.";return}
        do {try phoneDisplayControls.request(device:device,off:false);pollPhoneDisplayControls()}
        catch {status.stringValue=error.localizedDescription}
    }
}
