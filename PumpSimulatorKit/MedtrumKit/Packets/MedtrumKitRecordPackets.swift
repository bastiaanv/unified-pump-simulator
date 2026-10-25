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
        if let record = state.recordLog.record(number) {
            response = record.encode(serial: state.serialNumber, patchId: state.patchId)
            logger.info("Processed GetRecord message! Record #\(number): \(record.typeName)")
        } else {
            response = MedtrumKitRecord.emptySlot(number: number, serial: state.serialNumber, patchId: state.patchId)
            logger
                .warning("GetRecord for #\(number), which this patch has no record of (newest #\(state.recordLog.newestWritten))")
        }

        bluetoothManager.writeResponse(data: response, status: .ok, params.responseParam)
    }
}
