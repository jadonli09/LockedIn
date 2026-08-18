//
//  MarqueeText.swift
//  LockedIn
//
//  Continuous marquee: when the text overflows its frame it slides left
//  forever as a conveyor — two copies with a gap, snapping seamlessly once
//  the first copy has passed — with soft fades at both edges. Text that fits
//  simply sits still. Linear glide is intentional: it's a conveyor, not an
//  interaction.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium, design: .rounded)
    var color: Color = .white.opacity(0.6)
    /// Points per second.
    var speed: CGFloat = 24

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 40
    private let fadeWidth: CGFloat = 14
    private let initialPause: TimeInterval = 1.2

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width
            let cycle = textWidth + gap

            HStack(spacing: gap) {
                label
                    .background(
                        GeometryReader { textGeo in
                            Color.clear
                                .onAppear { textWidth = textGeo.size.width }
                                .onChange(of: text) { textWidth = textGeo.size.width }
                        }
                    )
                if overflow {
                    label
                }
            }
            .fixedSize()
            .offset(x: overflow ? -offset : 0)
            .frame(width: geo.size.width, alignment: .leading)
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow ? fadeWidth : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow ? fadeWidth : 0)
                }
            )
            .task(id: "\(text)-\(overflow)-\(Int(cycle))") {
                offset = 0
                guard overflow, cycle > 0 else { return }
                try? await Task.sleep(for: .seconds(initialPause))
                guard !Task.isCancelled else { return }
                // One cycle moves the conveyor by exactly one copy + gap, so
                // the second copy lands where the first started — invisible loop.
                while !Task.isCancelled {
                    withAnimation(.linear(duration: Double(cycle / speed))) {
                        offset = cycle
                    }
                    try? await Task.sleep(for: .seconds(Double(cycle / speed)))
                    guard !Task.isCancelled else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { offset = 0 }
                }
            }
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}
