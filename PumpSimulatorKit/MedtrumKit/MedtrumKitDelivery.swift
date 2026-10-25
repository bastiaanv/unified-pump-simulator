import Foundation

/// What the patch delivers, as basal segments and boluses, and the records it writes as each ends.
///
/// The patch runs one basal segment at a time: the schedule (STANDARD) or a temp basal (ABSOLUTE_TEMP). A segment ends
/// when another starts, at a suspend or a halt, at local midnight, and - a STANDARD one - at a block of the schedule;
/// the patch then writes its record. A suspended span has no record of its own. What follows is modelled on real
/// patches' records and answers as MedtrumKit's and AndroidAPS's `GetRecordPacket` read them:
/// - a temp basal set over the schedule writes the schedule's record, its cancel the temp basal's, both SUCCESS;
/// - a suspend writes the running segment's record (SUSPEND_MANUAL), then an ALARM record; a resume starts the
///   schedule again and writes an AUTO3 record;
/// - at midnight the running segment is split, then a type 10 record and the day's TDD are written.
///
/// Everything here runs on the pump manager's queue (`MedtrumKitPumpManager.queue`).
extension MedtrumKitState {
    /// Running a basal segment: active, not suspended, halted or in setup
    var isDeliveringBasal: Bool {
        patchState == .active || patchState == .active_alt
    }

    /// Active or suspended: past setup, not halted or stopped
    var isPatchRunning: Bool {
        isDeliveringBasal || patchState.isSuspended || patchState == .paused
    }

    var isBolusRunning: Bool {
        bolusStart != nil && bolusTotal != nil
    }

    var segmentType: BasalType {
        tempBasalRate != nil ? .ABSOLUTE_TEMP : .STANDARD
    }

    var segmentRate: Double {
        tempBasalRate ?? scheduledRate(at: basalSince)
    }

    var tempBasalEnd: Date? {
        guard let tempBasalStart, let tempBasalDuration, tempBasalRate != nil else {
            return nil
        }

        return tempBasalStart.addingTimeInterval(tempBasalDuration)
    }

    /// What the running segment has delivered since it started, in the patch's 0.05 U steps
    func segmentDelivered(until date: Date) -> Double {
        let units = if let tempBasalRate {
            tempBasalRate * max(0, date.timeIntervalSince(basalSince)) / 3600
        } else {
            scheduledInsulin(from: basalSince, to: date)
        }

        return Self.roundToSteps(units)
    }

    // MARK: - Commands

    /// SetTempBasal: ends the running segment - the schedule's, or a temp basal's - and starts the temp basal
    func setTempBasal(rate: Double, duration: TimeInterval, at date: Date) {
        endSegment(at: date, reason: .SUCCESS)

        tempBasalRate = rate
        tempBasalStart = date
        tempBasalDuration = duration
        startSegment(at: date)
    }

    /// CancelTempBasal: ends the temp basal, the schedule takes over. With none running nothing changes - the answer
    /// then names the running segment as it is.
    func cancelTempBasal(at date: Date) {
        guard isDeliveringBasal, tempBasalRate != nil else {
            return
        }

        endSegment(at: date, reason: .SUCCESS)
        clearTempBasal()
        startSegment(at: date)
    }

    /// SuspendPump: the running segment ends, then an ALARM record. A running bolus is ended first by the caller
    /// (`MedtrumKitPackets.endBolus`), which owns its timer.
    func suspend(for duration: TimeInterval, at date: Date) {
        endSegment(at: date, reason: .SUSPEND_MANUAL)
        clearTempBasal()

        patchState = .suspended
        suspendedSince = date
        suspendedDuration = duration
        appendRecord(.other(type: MedtrumKitRecord.typeAlarm), at: date)
    }

    /// ResumePump, or a suspend running out: the schedule again, a temp basal before it is gone for good
    func resume(at date: Date) {
        patchState = .active
        suspendedSince = nil
        suspendedDuration = nil
        clearTempBasal()

        startSegment(at: date)
        appendRecord(.other(type: MedtrumKitRecord.typeAuto3), at: date)
    }

    /// The patch stops delivering on its own: an occlusion, the hourly maximum, ... A running bolus is ended first by
    /// the caller (`MedtrumKitPackets.endBolus`), which owns its timer.
    func halt(_ haltState: PatchState, reason: BasalEndReason, at date: Date) {
        endSegment(at: date, reason: reason)
        clearTempBasal()

        patchState = haltState
        appendRecord(.other(type: MedtrumKitRecord.typeAlarm), at: date)
    }

    /// StopPatch: what was running ends here. A running bolus is ended first by the caller.
    func stop(at date: Date) {
        endSegment(at: date, reason: .STOP_DISCARD)
        clearTempBasal()
    }

    /// A new patch: a new id (`MedtrumKitPumpManager.nextPatchId`), and records from 1 on - the first one a time
    /// sync, as on real patches
    func activate(patchId: UInt32, at date: Date) {
        self.patchId = patchId
        updateRecordLog { $0.reset() }
        appendRecord(.other(type: MedtrumKitRecord.typeTimeSync), at: date)

        clearTempBasal()
        suspendedSince = nil
        suspendedDuration = nil
        bolusAnsweredNumber = nil
        bolusStart = nil
        bolusTotal = nil
        bolusProgress = nil
        lastBolusDelivered = 0
        lastBolusCause = 0

        dayStart = calendar.startOfDay(for: date)
        dayBolus = 0
        dayBasal = 0

        startSegment(at: date)
    }

    /// SetBasalProfile: the running segment is split - a temp basal goes on
    func basalProfileChanged(at date: Date) {
        guard isDeliveringBasal else {
            return
        }

        endSegment(at: date, reason: .SUCCESS)
        startSegment(at: date)
    }

    /// SetTimeZone: the patch's midnight and schedule blocks follow `offset` (minutes east of UTC) from now on. A
    /// running schedule segment is split if the zone changes, its rate being the old zone's; a temp basal goes on.
    ///
    /// If the new zone's midnight after the day's start has passed already - moving east late in the day, or west by
    /// fewer hours than the day has run - the day closes at the change, as at a midnight (any segment split, type 10
    /// and TDD records), and the next one starts there.
    func setTimeZone(offset: Int, at date: Date) {
        let changed = offset != calendar.timeZone.secondsFromGMT(for: date) / 60
        let closesDay = changed && dayStart.flatMap { nextMidnight(after: $0, offset: offset) }.map { $0 <= date } == true
        let splitsSegment = isDeliveringBasal && (closesDay || (changed && tempBasalRate == nil))

        if splitsSegment {
            endSegment(at: date, reason: .SUCCESS)
        }
        if closesDay {
            // Counted in the old zone, the day's
            closeDay(at: date)
        }
        timeZoneOffset = offset
        if splitsSegment {
            startSegment(at: date)
        }
    }

    /// SetBolus: the answer names the next record number - which the bolus gets only if nothing else is written before
    /// it ends; it takes no number now (device 2026-10-22 13:52: the answer named #1606, a low-reservoir alarm during
    /// the bolus took #1606, the bolus record became #1607)
    func startBolus(amount: Double, at date: Date) -> UInt16 {
        let number = recordLog.nextNumber
        bolusAnsweredNumber = number
        bolusStart = date
        bolusTotal = amount
        bolusProgress = nil
        return number
    }

    /// The bolus ended - delivered in full (cause 0), cancelled (32) or cut by a halt, a suspend or a stop (9) - and is
    /// written under the next number
    func finishBolus(delivered: Double, cause: UInt8, at date: Date) {
        if let start = bolusStart, let requested = bolusTotal {
            appendRecord(
                .bolus(MedtrumKitRecord.Bolus(cause: cause, start: start, requested: requested, delivered: delivered)),
                at: date
            )
            dayBolus += delivered
        }

        lastBolusDelivered = delivered
        lastBolusCause = cause
        bolusAnsweredNumber = nil
        bolusStart = nil
        bolusTotal = nil
        bolusProgress = nil
    }

    // MARK: - Time

    /// Brings the patch up to `now`: temp basals and suspends that ran out, schedule blocks and midnights passed, in
    /// the order they happened - the simulator may have been closed meanwhile. Whether anything changed.
    @discardableResult func advance(to now: Date = .now) -> Bool {
        var changed = false

        // A state saved before records were kept: count from today on
        if dayStart == nil {
            let today = calendar.startOfDay(for: now)
            dayStart = today
            basalSince = max(basalSince, today)
            changed = true
        }

        while let next = nextEvent(), next.date <= now {
            let date = next.date

            switch next.event {
            case .tempBasalEnds:
                endSegment(at: date, reason: .SUCCESS)
                clearTempBasal()
                startSegment(at: date)

            case .suspensionEnds:
                resume(at: date)

            case .scheduleBlock:
                endSegment(at: date, reason: .SUCCESS)
                startSegment(at: date)

            case .midnight:
                passMidnight(date)
            }

            changed = true
        }

        return changed
    }

    private enum TimedEvent {
        case tempBasalEnds
        case suspensionEnds
        case scheduleBlock
        case midnight
    }

    private func nextEvent() -> (date: Date, event: TimedEvent)? {
        var events: [(date: Date, event: TimedEvent)] = []

        if isDeliveringBasal {
            if let tempBasalEnd {
                events.append((tempBasalEnd, .tempBasalEnds))
            } else if let block = nextScheduleBlock(after: basalSince) {
                // A temp basal runs across blocks of the schedule, the schedule itself is split at each
                events.append((block, .scheduleBlock))
            }
        }

        if patchState == .suspended, let suspendedSince, let suspendedDuration {
            events.append((suspendedSince.addingTimeInterval(suspendedDuration), .suspensionEnds))
        }

        if let dayStart, let midnight = nextMidnight(after: dayStart) {
            // Never before the running segment's start (a zone change, `setTimeZone`): no record ends before it starts,
            // and the segment's start never moves back
            events.append((max(midnight, basalSince), .midnight))
        }

        return events.min { $0.date < $1.date }
    }

    /// The running segment split at midnight, then the bookkeeping records and the day's total
    private func passMidnight(_ midnight: Date) {
        if isDeliveringBasal {
            endSegment(at: midnight, reason: .SUCCESS)
            startSegment(at: midnight)
        }

        closeDay(at: midnight)
    }

    /// The day ends at `date` - its midnight, or a zone change: the bookkeeping records and its total (while the
    /// patch runs), and the next day starts there
    private func closeDay(at date: Date) {
        if isPatchRunning, let dayStart {
            let runningSince = max(dayStart, activatedAt ?? dayStart)
            let minutes = UInt16(max(0, min(1440, date.timeIntervalSince(runningSince) / 60)))
            let offset = calendar.timeZone.secondsFromGMT(for: dayStart) / 60

            appendRecord(.other(type: MedtrumKitRecord.typeMidnight), at: date)
            appendRecord(
                .tdd(MedtrumKitRecord.Tdd(
                    dayStart: dayStart,
                    timeZoneOffset: offset,
                    minutes: minutes,
                    total: dayBolus + dayBasal,
                    basal: dayBasal
                )),
                at: date
            )
        }

        dayStart = date
        dayBolus = 0
        dayBasal = 0
    }

    // MARK: - Segments

    /// Writes the record of the running segment, ending at `date`
    private func endSegment(at date: Date, reason: BasalEndReason) {
        guard isDeliveringBasal else {
            return
        }

        let delivered = segmentDelivered(until: date)
        appendRecord(
            .basal(MedtrumKitRecord.Basal(
                type: segmentType.rawValue,
                endReason: reason,
                start: basalSince,
                end: date,
                rate: segmentRate,
                delivered: delivered
            )),
            at: date
        )
        dayBasal += delivered
    }

    private func startSegment(at date: Date) {
        basalSince = date
        basalSequence = recordLog.newestWritten
    }

    private func clearTempBasal() {
        tempBasalRate = nil
        tempBasalStart = nil
        tempBasalDuration = nil
    }

    private func appendRecord(_ kind: MedtrumKitRecord.Kind, at date: Date) {
        updateRecordLog { $0.append(kind, at: date) }
    }

    // MARK: - Schedule

    /// The patch's first midnight after `dayStart`. A day after it, unless the phone moved the patch to another zone
    /// since: then that zone's next midnight - the day running shorter or longer. `offset`: in that zone instead of
    /// the patch's.
    func nextMidnight(after dayStart: Date, offset: Int? = nil) -> Date? {
        var calendar = calendar
        if let offset, let zone = TimeZone(secondsFromGMT: offset * 60) {
            calendar.timeZone = zone
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart.addingTimeInterval(1)))
    }

    /// The next start of a block of the schedule after `date`, the same day - midnight is not one of them, it splits
    /// every segment (`passMidnight`)
    private func nextScheduleBlock(after date: Date) -> Date? {
        let dayStart = calendar.startOfDay(for: date)
        let offset = date.timeIntervalSince(dayStart)

        return basal.map(\.start)
            .filter { $0 > 0 && $0 > offset && $0 < .hours(24) }
            .min()
            .map { dayStart.addingTimeInterval($0) }
    }

    /// What the schedule delivers between two dates
    private func scheduledInsulin(from start: Date, to end: Date) -> Double {
        var units = 0.0
        var time = start

        while time < end {
            let dayStart = calendar.startOfDay(for: time)
            let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let next = min(end, nextScheduleBlock(after: time) ?? nextMidnight, nextMidnight)

            units += scheduledRate(at: time) * next.timeIntervalSince(time) / 3600
            time = next
        }

        return units
    }

    static func roundToSteps(_ units: Double) -> Double {
        (units / 0.05).rounded() * 0.05
    }
}
