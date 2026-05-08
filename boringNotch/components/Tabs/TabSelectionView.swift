//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
    let isVisible: Bool
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var ntfyModel = NtfyStateViewModel.shared
    @StateObject var shelfModel = ShelfStateViewModel.shared
    @Namespace var animation
    @Default(.boringShelf) var boringShelf
    @Default(.boringNtfy) var boringNtfy

    private var showNtfy: Bool { boringNtfy && (coordinator.alwaysShowTabs || ntfyModel.unreadCountAll > 0) }
    private var showShelf: Bool { boringShelf && (coordinator.alwaysShowTabs || !shelfModel.isEmpty) }

    private var tabs: [TabModel] {
        [
            TabModel(label: "Home", icon: "house.fill", view: .home, isVisible: showNtfy || showShelf),
            TabModel(label: "Ntfy", icon: "text.bubble.fill", view: .ntfy, isVisible: showNtfy),
            TabModel(label: "Shelf", icon: "tray.fill", view: .shelf, isVisible: showShelf)
        ]
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                if tab.isVisible {
                    TabButton(
                        label: tab.label,
                        icon: tab.icon,
                        selected: coordinator.currentView == tab.view,
                        showDot: tab.view == .ntfy && ntfyModel.unreadCountAll > 0
                    ) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
