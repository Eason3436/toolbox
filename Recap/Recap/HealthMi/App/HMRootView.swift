import SwiftUI

struct HMRootView: View {
    @Environment(HMAppModel.self) private var model

    var body: some View {
        Group {
            if model.isConfigured {
                DashboardView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isConfigured)
    }
}

