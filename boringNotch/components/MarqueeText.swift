//
//  MarqueeText.swift
//  boringNotch
//
//  Minimal marquee: scrolls only when the text overflows its frame,
//  with a pause at each end. Spring-free linear glide is intentional —
//  it's a conveyor, not an interaction.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium, design: .rounded)
    var color: Color = .white.opacity(0.6)

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear { textWidth = textGeo.size.width }
                            .onChange(of: text) { textWidth = textGeo.size.width }
                    }
                )
                .offset(x: offset)
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .task(id: "\(text)-\(overflow > 0)") {
                    offset = 0
                    guard overflow > 0 else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        withAnimation(.linear(duration: Double(overflow) / 25)) {
                            offset = -overflow
                        }
                        try? await Task.sleep(for: .seconds(Double(overflow) / 25 + 1.5))
                        guard !Task.isCancelled else { return }
                        withAnimation(.linear(duration: 0.3)) {
                            offset = 0
                        }
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                }
        }
    }
}
