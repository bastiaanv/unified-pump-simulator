import AppKit
import SwiftUI

extension Image {
    init(imageName: String) {
        self.init(imageName, bundle: Bundle(for: PumpImage.self))
    }
}

class PumpImage {}
