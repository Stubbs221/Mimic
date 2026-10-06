//
//  AIUsageTrendViews.swift
//  Mimic
//
//  Created by Василий Маслов on 05.10.2026.
// Chart presentation adapted from OpenUsage 0.7.13 (MIT), Robin Ebers.
import AppKit
import SwiftUI
import MimicCore

/// The inline chart and native detail consume the same ordered calendar points.
struct AIUsageTrendView: View {
    let provider: AIProvider
    let points: [AIUsageDailyPoint]
    let unknownModels: [String]
    @StateObject private var hover: AIUsageTrendPopoverState
    init(provider: AIProvider, points: [AIUsageDailyPoint], unknownModels: [String]) {
        self.provider = provider; self.points = points; self.unknownModels = unknownModels
        self._hover = StateObject(wrappedValue: AIUsageTrendPopoverState(points: points))
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(text("usage.trend")).fontWeight(.semibold)
            Spacer(minLength: 8)
            if self.points.isEmpty {
                Text(text("usage.trend.empty")).foregroundStyle(.secondary)
            } else {
                Button { self.hover.toggleExplicit() } label: {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(self.points, id: \.date) { point in
                            RoundedRectangle(cornerRadius: 1).fill(Color.blue)
                                .frame(minWidth: 2, maxWidth: .infinity)
                                .frame(height: AIUsageTrendFormat.barHeight(point.tokens, peak: self.points.map(\.tokens).max() ?? 0, height: 18, floor: 0.18))
                        }
                    }.frame(minWidth: 90, maxWidth: 150).frame(height: 18, alignment: .bottom)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            .padding(.horizontal, -7).padding(.vertical, -4)
                            .opacity(self.hover.overInline || self.hover.isPresented ? 1 : 0)
                    }
                    .background(AIUsageTrendPopoverAnchor(provider: self.provider, state: self.hover))
                    .onContinuousHover { phase in
                        if case .active = phase { self.hover.inlineHover(true) } else { self.hover.inlineHover(false) }
                    }
                    .accessibilityLabel(text("usage.trend.open"))
                    .accessibilityValue(AIUsageTrendFormat.description(self.points, provider: self.provider))
                    .accessibilityIdentifier("usage.trend.open." + self.provider.rawValue)
            }
            if !self.unknownModels.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .help(text("usage.trend.unknownModels") + " " + self.unknownModels.joined(separator: ", "))
                    .accessibilityLabel(text("usage.trend.unknownModels") + " " + self.unknownModels.joined(separator: ", "))
            }
        }.font(MimicMetrics.secondary).padding(.vertical, 4).mimicImmediate()
            .accessibilityElement(children: .contain)
            .onChange(of: self.points) { _, points in self.hover.replacePoints(points) }
    }
}

/// A larger chart with full-height hover columns, keyboard selection and exact accessible values.
struct AIUsageTrendDetail: View {
    let provider: AIProvider
    @ObservedObject var state: AIUsageTrendPopoverState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    self.title.fixedSize(); Spacer(minLength: 8); self.readout.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) { self.title; self.readout }
            }
            self.chart
            HStack {
                Text(self.state.points.first.map { AIUsageTrendFormat.date($0.date) } ?? "")
                Spacer()
                Text(self.state.points.last.map { AIUsageTrendFormat.date($0.date) } ?? "")
            }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Text(AIUsageTrendFormat.source(self.provider)).font(.system(size: 10))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }.padding(12).frame(width: 340).fixedSize(horizontal: false, vertical: true).mimicImmediate()
            .onContinuousHover { phase in
                guard self.state.isPresented else { return }
                if case .active = phase { self.state.detailHover(true) } else { self.state.detailHover(false) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("usage.trend.detail." + self.provider.rawValue)
    }
    private var title: some View { Text(text("usage.trend")).font(.system(size: 13, weight: .semibold)) }
    private var readout: some View {
        Text(self.state.selectedPoint.map { AIUsageTrendFormat.readout($0) } ?? text("usage.trend.empty"))
            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(self.state.selectedPoint.map { AIUsageTrendFormat.exact($0) } ?? text("usage.trend.empty"))
    }
    private var chart: some View {
        let points = self.state.points, peak = points.map(\.tokens).max() ?? 0
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(points.indices, id: \.self) { index in
                Color.clear.frame(maxWidth: .infinity).frame(height: 76)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.blue)
                            .frame(height: AIUsageTrendFormat.barHeight(points[index].tokens, peak: peak, height: 76, floor: 0.06))
                            .padding(.horizontal, 1)
                            .opacity(self.state.activeIndex == nil || self.state.activeIndex == index ? 1 : 0.35)
                    }.contentShape(Rectangle())
                    .onContinuousHover { phase in if case .active = phase { self.state.select(index) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AIUsageTrendFormat.exact(points[index]))
                    .accessibilityAddTraits(self.state.selectedIndex == index ? [.isSelected] : [])
            }
        }.frame(height: 76)
            .onContinuousHover { phase in if self.state.isPresented, case .ended = phase { self.state.clearSelection() } }
    }
}

/// Shared formatting keeps visible summaries compact while assistive readouts retain exact counts.
@MainActor
enum AIUsageTrendFormat {
    static func date(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }
    static func readout(_ point: AIUsageDailyPoint) -> String {
        let count = point.tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        return self.date(point.date) + " · " + String(format: text("usage.trend.compactTokens"), count)
    }
    static func exact(_ point: AIUsageDailyPoint) -> String {
        point.date.formatted(date: .abbreviated, time: .omitted) + " · " + point.tokens.formatted() + " " + text("usage.tokens")
    }
    static func source(_ provider: AIProvider) -> String { text("usage.trend.source." + provider.rawValue) }
    static func description(_ points: [AIUsageDailyPoint], provider: AIProvider) -> String {
        guard let first = points.first, let last = points.last else { return text("usage.trend.empty") }
        let peak = points.reduce(first) { $1.tokens >= $0.tokens ? $1 : $0 }
        return [text("usage.trend"), self.date(first.date) + " — " + self.date(last.date), text("usage.trend.peak") + " " + self.exact(peak), self.source(provider)].joined(separator: "\n")
    }
    static func barHeight(_ tokens: Int, peak: Int, height: CGFloat, floor: CGFloat) -> CGFloat {
        guard tokens > 0 else { return 2 }
        return max(height * floor, height * min(1, CGFloat(tokens) / CGFloat(max(1, peak))))
    }
}
