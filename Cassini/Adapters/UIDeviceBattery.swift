import UIKit
import CassiniEngine

/// The battery level for the progress card. iOS reports it in steps of 5 % and not at all in the simulator.
@MainActor final class UIDeviceBattery: BatteryMonitoring {
    init() { UIDevice.current.isBatteryMonitoringEnabled = true }

    func reading() -> (percent: Int, charging: Bool)? {
        let device = UIDevice.current
        guard device.batteryState != .unknown, device.batteryLevel >= 0 else { return nil }
        let charging = device.batteryState == .charging || device.batteryState == .full
        return (Int((device.batteryLevel * 100).rounded()), charging)
    }
}
