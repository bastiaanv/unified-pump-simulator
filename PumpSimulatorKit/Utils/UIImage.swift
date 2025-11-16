import SwiftUI
import AppKit

extension Image {
    init(imageName: String) {
        self.init(imageName, bundle: Bundle(for: PumpImage.self))
    }
}

class PumpImage {}
