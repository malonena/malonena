import HaishinKit
import SwiftUI

struct PreviewView: UIViewRepresentable {
    let view: MTHKView

    func makeUIView(context: Context) -> MTHKView {
        view.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTHKView, context: Context) {}
}
