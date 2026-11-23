import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel

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

@MainActor
struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environmentObject(AppModel())
    }
}
