//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let showDot: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            ZStack {
                Image(systemName: icon)
                    .padding(.horizontal, 15)
                    .contentShape(Capsule())
                if showDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 8, y: -6)
                }
            }
            .animation(.smooth, value: showDot)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true, showDot: true) {
        print("Tapped")
    }
}
