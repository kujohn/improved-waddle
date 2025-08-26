import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            SharedMetalView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
}
