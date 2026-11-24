import AppKit
import Foundation
import ServiceManagement

/// Sleep, login-item, and polling cadence responsibilities are kept outside
/// the main observable model. The model remains the state owner; this
/// extension groups its lifecycle coordination in one place.
@MainActor
extension DashboardModel {
    func refreshLoginItemStatus() {
        loginItemStatus = loginItemStatus(for: SMAppService.mainApp.status)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func synchronizeLoginItem() {
        let service = SMAppService.mainApp
        loginItemErrorMessage = nil

        do {
            switch (launchAtLoginEnabled, service.status) {
            case (true, .notRegistered), (true, .notFound):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            default:
                break
            }
            refreshLoginItemStatus()
        } catch {
            refreshLoginItemStatus()
            loginItemErrorMessage = "ログイン時起動を変更できませんでした: \(error.localizedDescription)"
        }
    }

    func loginItemStatus(for status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    func installPowerObservers() {
        guard sleepObserver == nil, wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillSleep() }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidWake() }
        }

    }

    func handleWillSleep() {
        guard !isSystemSleeping else { return }
        isSystemSleeping = true
        stopRefreshSchedule()
        stopTemperatureSchedule()
        stopIORegistrySchedule()
        stopIORegistryRetry()
        updateSleepActivity()
    }

    func handleDidWake() {
        isSystemSleeping = false
        stopSleepActivity()

        if backgroundMonitoringEnabled {
            // Refresh identity before collecting cumulative FTL counters.
            freshIdentityContext = nil
            scheduleRefresh()
            scheduleTemperatureRefresh()
            scheduleIORegistryCollection()

            Task { @MainActor [weak self] in
                await self?.refresh(trigger: .wake)
            }
        }
    }

    func updateSleepActivity() {
        guard hasStarted, isSystemSleeping, backgroundMonitoringEnabled,
              sleepMonitoringMode == .bestEffort else {
            stopSleepActivity()
            return
        }
        guard sleepActivity == nil else { return }

        let activity = NSBackgroundActivityScheduler(identifier: Self.sleepActivityIdentifier)
        activity.repeats = true
        activity.interval = Self.sleepActivityInterval
        activity.tolerance = Self.sleepActivityTolerance
        activity.qualityOfService = .background
        activity.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else { completion(.finished); return }
                guard self.isSystemSleeping, self.backgroundMonitoringEnabled,
                      self.sleepMonitoringMode == .bestEffort else {
                    completion(.deferred)
                    return
                }
                await self.refresh(allowDuringSleep: true, trigger: .sleepBestEffort)
                completion(.finished)
            }
        }
        sleepActivity = activity
    }

    func stopSleepActivity() {
        sleepActivity?.invalidate()
        sleepActivity = nil
    }

    func scheduleRefresh() {
        guard !isSystemSleeping else { return }
        stopRefreshSchedule()
        let timer = Timer(timeInterval: refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(trigger: .background) }
        }
        timer.tolerance = refreshInterval.seconds * 0.1
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopRefreshSchedule() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func scheduleTemperatureRefresh() {
        guard !isSystemSleeping else { return }
        stopTemperatureSchedule()
        let timer = Timer(timeInterval: temperatureMonitoringInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshTemperature() }
        }
        timer.tolerance = temperatureMonitoringInterval.seconds * 0.1
        temperatureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopTemperatureSchedule() {
        temperatureTimer?.invalidate()
        temperatureTimer = nil
    }

    func scheduleIORegistryCollection() {
        guard !isSystemSleeping,
              ioRegistryCollectionInterval.isAutomatic else {
            stopIORegistrySchedule()
            return
        }
        stopIORegistrySchedule()
        let timer = Timer(timeInterval: ioRegistryCollectionInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.collectIORegistryProfile(force: true) }
        }
        timer.tolerance = ioRegistryCollectionInterval.seconds * 0.1
        ioRegistryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopIORegistrySchedule() {
        ioRegistryTimer?.invalidate()
        ioRegistryTimer = nil
    }

    func scheduleIORegistryRetryIfNeeded() {
        guard backgroundMonitoringEnabled, !isSystemSleeping,
              ioRegistryRetryTimer == nil else { return }
        let timer = Timer(timeInterval: Self.ioRegistryRetryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // A failed retry finds the timer still set and does not
                // schedule another; clearing it afterwards lets the next
                // daily or wake failure schedule its own single retry.
                await self?.collectIORegistryProfile(force: true)
                self?.ioRegistryRetryTimer = nil
            }
        }
        timer.tolerance = Self.ioRegistryRetryDelay * 0.1
        ioRegistryRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopIORegistryRetry() {
        ioRegistryRetryTimer?.invalidate()
        ioRegistryRetryTimer = nil
    }

}
