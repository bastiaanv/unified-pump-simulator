import Foundation

extension MedtrumKitPackets {
    /// GET_RECORD: the record number (2 bytes) and the low two bytes of the patch id the phone believes in. Answered with
    /// the record, or an empty slot for a number the patch holds no record under.
    static func parseGetRecordPacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.data.count >= 8 else {
            logger.warning("GetRecord message too short: \(params.data.hexString())")
            bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
            return
        }

        let number = params.data.toUInt16(offset: 4)
        let requestedPatchId = params.data.toUInt16(offset: 6)
        let state = params.pumpManager.state

        if requestedPatchId != UInt16(truncatingIfNeeded: state.patchId) {
            logger.warning("GetRecord for patch \(requestedPatchId), this is patch \(state.patchId): answering from this patch")
        }

        let response: Data
        let faults = params.pumpManager.patchFaults
        if let record = state.recordLog.record(number),
           let fault = faults.update({ settings -> RecordReadFault? in
               guard settings.recordFault != .normal,
                     settings.recordFaultNumber.map({ $0 == number }) ??
                     settings.recordTarget.matches(record, number: settings.recordTargetNumber)
               else {
                   return nil
               }
               let fault = settings.recordFault
               if settings.recordFaultSticks {
                   // Every read of this record from now on
                   settings.recordFaultNumber = number
               } else {
                   // Used up by this read
                   settings.recordFault = .normal
               }
               return fault
           })
        {
            switch fault {
            case .emptySlot:
                response = MedtrumKitRecord.emptySlot(number: number, serial: state.serialNumber, patchId: state.patchId)
            case .badCrc:
                response = record.encode(serial: state.serialNumber, patchId: state.patchId, corruptCrc: true)
            case .otherPatchId:
                response = record.encode(serial: state.serialNumber, patchId: state.patchId &+ 1)
            case .truncated:
                response = record.encode(serial: state.serialNumber, patchId: state.patchId, truncated: true)
            case .normal:
                response = record.encode(serial: state.serialNumber, patchId: state.patchId)
            }
            logger.warning("[FAULT] GetRecord #\(number) (\(record.typeName)) answered with: \(fault.title)")
            params.pumpManager.notifyStateDidUpdate()
        } else if let ring = ringSlot(of: number, faults.current, state.recordLog) {
            // Fallen out of the ring the patch keeps its records in
            guard let stale = ring.stale else {
                logger.warning(
                    "[FAULT] GetRecord #\(number): out of the \(ring.capacity) records the patch keeps, answered with code 8"
                )
                bluetoothManager.writeResponse(data: Data(), status: .invalidState, params.responseParam)
                return
            }
            if let record = state.recordLog.record(stale) {
                response = record.encode(serial: state.serialNumber, patchId: state.patchId)
                logger.warning(
                    "[FAULT] GetRecord #\(number): out of the \(ring.capacity) records the patch keeps, answered with #\(stale) " +
                        "(\(record.typeName)), the record now in its slot"
                )
            } else {
                response = MedtrumKitRecord.emptySlot(number: number, serial: state.serialNumber, patchId: state.patchId)
                logger.warning(
                    "[FAULT] GetRecord #\(number): out of the \(ring.capacity) records the patch keeps, its slot's #\(stale) " +
                        "not held either: an empty slot"
                )
            }
        } else if let record = state.recordLog.record(number) {
            response = record.encode(serial: state.serialNumber, patchId: state.patchId)
            logger.info("Processed GetRecord message! Record #\(number): \(record.typeName)")
        } else {
            response = MedtrumKitRecord.emptySlot(number: number, serial: state.serialNumber, patchId: state.patchId)
            logger
                .warning("GetRecord for #\(number), which this patch has no record of (newest #\(state.recordLog.newestWritten))")
        }

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
    }

    /// Whether record `number` fell out of the record ring armed (`PatchFaultSettings.ringEnabled`): older than the newest
    /// `ringCapacity`. Its slot then holds the newest record of the same slot - `number` plus a multiple of the capacity -
    /// which a stale slot answers with; nil if the ring answers an error.
    private static func ringSlot(
        of number: UInt16,
        _ settings: PatchFaultSettings,
        _ log: MedtrumKitRecordLog
    ) -> (capacity: Int, stale: UInt16?)? {
        let capacity = settings.ringCapacity
        let newest = Int(log.newestWritten)
        guard settings.ringEnabled, capacity > 0, number > 0, Int(number) <= newest - capacity else {
            return nil
        }

        guard settings.ringAnswer == .staleSlot else {
            return (capacity, nil)
        }
        let laps = (newest - Int(number)) / capacity
        return (capacity, UInt16(Int(number) + laps * capacity))
    }
}
