import Foundation

extension MedtrumKitPackets {
    static func parsePrimePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState.rawValue >= PatchState.filled.rawValue else {
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )

            logger.warning("Rejecting prime command - Current state: \(params.pumpManager.state.patchState)")
            return
        }

        params.pumpManager.state.patchState = .priming
        params.pumpManager.state.primeProgress = 1
        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )

        triggerPrimeUpdate(params, bluetoothManager)
    }
    
    static func parseActivePacket(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.state.patchState.rawValue < PatchState.active.rawValue else {
            bluetoothManager.writeResponse(
                data: Data(),
                status: .invalidState,
                params.responseParam
            )

            logger.warning("Rejecting activate command - Current state: \(params.pumpManager.state.patchState)")
            return
        }
        
        // TODO: Parse request data for patch settings
        params.pumpManager.state.patchState = .active
        params.pumpManager.notifyStateDidUpdate()
        
        // TODO: Generate response :)
        
        bluetoothManager.writeResponse(
            data: Data(),
            status: .ok,
            params.responseParam
        )
    }

    private static func triggerPrimeUpdate(_ params: MedtrumKitPacketRequest, _ bluetoothManager: MedtrumKitBluetoothManager) {
        guard params.pumpManager.isRunning else {
            // Kill Async task
            return
        }

        if let primeProgress = params.pumpManager.state.primeProgress {
            params.pumpManager.state.primeProgress = primeProgress + 2

            if primeProgress > 100 {
                params.pumpManager.state.patchState = .ejected
                params.pumpManager.state.primeProgress = nil

                logger.info("Priming completed!")
            } else {
                logger.info("Updated priming progress...")

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now().advanced(by: .milliseconds(500))) {
                    triggerPrimeUpdate(params, bluetoothManager)
                }
            }
        } else {
            params.pumpManager.state.primeProgress = 1
            logger.info("Updated priming progress...")

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now().advanced(by: .milliseconds(500))) {
                triggerPrimeUpdate(params, bluetoothManager)
            }
        }

        params.pumpManager.notifyStateDidUpdate()

        bluetoothManager.writeResponse(
            data: MedtrumKitPackets.generateSynchronizePacket(state: params.pumpManager.state),
            status: .stateUpdate,
            params.updateParam
        )
    }
}
