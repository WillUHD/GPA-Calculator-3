//
//  ContentView.swift
//  GPACalc
//
//  Created by willuhd on 3/4/26
//  Original project by LegitMichel777
//
//  Copyright (c) 2026, under the GPA Calculator project.
//  Proprietary, internal use only. All Rights Reserved.
//

import SwiftUI
import Combine
import UIKit

enum ScoreDisplay: Int, CaseIterable, Hashable {
    case percentage = 0
    case letter = 1
}

struct ContentView: View {
    @StateObject private var backend = Backend.shared
    @State private var showingCustomize = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text("GPA Calculator")
                    .font(.system(size: 32, weight: .semibold))
                    .padding(.top, 20)

                Text(backend.calculationResultText)
                    .font(.system(size: 18))
                    .foregroundColor(backend.isInvalidated ? .red : .secondary)

                HStack(spacing: 16) {
                    Button(action: {
                        Haptic.medium()
                        showingCustomize = true
                    }) {
                        Text("Customize")
                            .font(.system(size: 18, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .background(Color("btnColor"))
                    .foregroundColor(.primary)
                    .cornerRadius(8)

                    Button(action: {
                        Haptic.medium()
                        for idx in 0..<backend.activeSubjects.count {
                            backend.setScoreIndex(0, for: idx)
                            backend.setLevelIndex(0, for: idx)
                        }
                    }) {
                        Text("Reset")
                            .font(.system(size: 18, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .background(Color("btnColor"))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }.padding(.horizontal, 16)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(backend.activeSubjects.enumerated()), id: \.1.stableId) { idx, subject in
                            SubjectRowView(subject: subject, index: idx, backend: backend)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }.background(Color("presetFloat"))
            }
            .navigationTitle("")
            .sheet(isPresented: $showingCustomize) {
                CustomizeView().environmentObject(backend)
            }.onAppear { backend.loadInitialData() }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SubjectRowView: View {
    let subject: CourseModel.Subject
    let index: Int
    @ObservedObject var backend: Backend

    // compute a dynamic index each time the view renders so bindings remain correct
    private var dynamicIndex: Int {
        backend.activeSubjects.firstIndex(where: { $0.stableId == subject.stableId }) ?? index
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(subject.name)
                    .font(.system(size: 24, weight: .regular))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .foregroundColor(backend.requiredSubjectIDs.contains(subject.id) ? .red : .primary)

                ResponsiveSelector(
                    items: subject.levels.map { $0.name },
                    selectedIndex: Binding(
                        get: { backend.selectedLevelIndex(for: dynamicIndex) },
                        set: { new in
                            backend.setLevelIndex(new, for: dynamicIndex)
                        }
                    )
                )
                .frame(maxWidth: .infinity)

            }

            let mapForSubject = backend.scoreMapForSubject(subject)

            let scoreItems = mapForSubject.map { backend.scoreDisplay == .percentage ? $0.percent : $0.letter }
            ResponsiveSelector(
                items: scoreItems,
                selectedIndex: Binding(
                    get: { backend.selectedScoreIndex(for: dynamicIndex) },
                    set: { new in
                        backend.setScoreIndex(new, for: dynamicIndex)
                    }
                )
            )
        }
        .padding()
        .background(Color("backgroundColor"))
        .cornerRadius(10)
        .opacity(0.95)
    }
}

// MARK: - CustomizeView

struct CustomizeView: View {
    @EnvironmentObject var backend: Backend
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    ScoreFormatBar()
                    if let warn = backend.requirementWarning {
                        Text(warn)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    PresetGrid()
                    ChoiceModulesSection()
                    CatalogFooter()
                }.padding(.vertical, 12)
            }
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        Haptic.medium()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - ScoreFormatBar
// has own typechecking scope

private struct ScoreFormatBar: View {
    @EnvironmentObject var backend: Backend

    var body: some View {
        HStack(spacing: 12) {
            Text("Score Format")
                .font(.system(size: 16, weight: .semibold))
                .layoutPriority(1)
            
            TrackToggleSlot(
                track: backend.currentPreset?.track,
                isActive: backend.trackActive,
                onToggle: {
                    Haptic.medium()
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        backend.setTrackActive(!backend.trackActive)
                    }
                }
            )
            .layoutPriority(1)

            ScoreFormatPicker()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.top, 0)
        .padding(.vertical, 6)
    }
}

// MARK: - TrackToggleSlot

private struct TrackToggleSlot: View {
    let track: CourseModel.PresetTrack?
    let isActive: Bool
    let onToggle: () -> Void

    var body: some View {
        if let track {
            TrackToggleButton(
                label: "Use \(track.displayName)",
                isActive: isActive,
                action: onToggle
            )
        }
    }
}

// MARK: - ScoreFormatPicker

private struct ScoreFormatPicker: View {
    @EnvironmentObject var backend: Backend

    var body: some View {
        ResponsiveSelector(
            items: ["Percentage", "Letter"],
            selectedIndex: Binding(
                get: { backend.scoreDisplay.rawValue },
                set: { new in
                    if let newDisplay = ScoreDisplay(rawValue: new) {
                        backend.scoreDisplay = newDisplay
                    }
                }
            )
        )
    }
}
// MARK: - TrackToggleButton

struct TrackToggleButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.blue : Color(UIColor.systemGray5))
                )
                .foregroundColor(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PresetGrid

private struct PresetGrid: View {
    @EnvironmentObject var backend: Backend

    var body: some View {
        VStack(spacing: 12) {
            let presets = backend.root?.presets ?? []
            let columns = [
                GridItem(.flexible(), spacing: 13),
                GridItem(.flexible(), spacing: 13)
            ]

            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(presets, id: \.id) { p in
                    let isSelected = (backend.currentPreset?.id == p.id)

                    Button(action: {
                        Haptic.medium()
                        withTransaction(Transaction(animation: nil)) {
                            backend.selectPreset(p.id)
                    }}) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(isSelected ? .primary : .blue)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(p.subtitle ?? "\(p.modules.reduce(0) { $0 + $1.subjects.count }) items")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color("subttl"))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(isSelected ? .primary : .gray)
                        }
                        .padding()
                        .frame(height: 70)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? Color("btnColor") : Color("presetFloat"))
                        .cornerRadius(8)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
    }
}

// MARK: - ChoiceModulesSection

private struct ChoiceModulesSection: View {
    @EnvironmentObject var backend: Backend

    var body: some View {
        VStack(spacing: 12) {
            ForEach(backend.choiceModules, id: \.modIndex) { mod in
                ModuleSelector(
                    module: mod.module,
                    modIndex: mod.modIndex,
                    backend: backend
                ).padding(.horizontal)
            }
        }
    }
}

// MARK: - CatalogFooter

private struct CatalogFooter: View {
    @EnvironmentObject var backend: Backend

    var body: some View {
        VStack {
            let catalog = backend.root?.catalogName ?? "Unspecified catalog"
            let version = backend.root?.version ?? "??"
            let lastUpdated = backend.root?.lastUpdated ?? "idk"
            let credit = backend.root?.credit ?? "Original project by Michel"

            Text("\(catalog)\nVersion \(version), last updated \(lastUpdated)\n\(credit)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .padding(.top, 8)
                .padding(.horizontal)
        }
    }
}

// MARK: - ResponsiveSelector

struct ResponsiveSelector: View {
    let items: [String]
    @Binding var selectedIndex: Int

    private static let labelFont = UIFont.systemFont(ofSize: 14, weight: .regular)
    private let paddingPerSegment: CGFloat = 24
    private let extraTotalPadding: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.width)

            let textWidths = items.map { $0.width(usingFont: Self.labelFont) }
            let maxTextWidth = textWidths.max() ?? 0
            let totalTextWidth = textWidths.reduce(0, +)

            let compactWidth = totalTextWidth + (CGFloat(items.count) * paddingPerSegment) + extraTotalPadding
            let evenWidth = (maxTextWidth + paddingPerSegment) * CGFloat(items.count) + extraTotalPadding

            if items.isEmpty {
                EmptyView()
            } else if available < compactWidth && items.count > 1 {
                Menu {
                    ForEach(0..<items.count, id: \.self) { i in
                        Button(items[i]) {
                            Haptic.light()
                            selectedIndex = i
                        }
                    }
                } label: {
                    HStack {
                        Text(items[safe: selectedIndex] ?? items[0])
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
            } else {
                let isEven = available >= evenWidth
                Selector(
                    items: items,
                    selectedIndex: $selectedIndex,
                    evenlySpaced: isEven
                )
                .frame(width: available, height: 36)
            }
        }
        .frame(minHeight: 36)
    }
}

// MARK: - Selector

struct Selector: UIViewRepresentable {
    let items: [String]
    @Binding var selectedIndex: Int
    let evenlySpaced: Bool

    func makeUIView(context: Context) -> UISegmentedControl {
        let sc = UISegmentedControl(items: items)
        sc.selectedSegmentIndex = selectedIndex
        sc.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        sc.translatesAutoresizingMaskIntoConstraints = false
        return sc
    }

    func updateUIView(_ uiView: UISegmentedControl, context: Context) {
        if uiView.numberOfSegments != items.count {
            uiView.removeAllSegments()
            for (i, title) in items.enumerated() {
                uiView.insertSegment(withTitle: title, at: i, animated: false)
            }
        } else {
            for (i, title) in items.enumerated() {
                uiView.setTitle(title, forSegmentAt: i)
            }
        }
        uiView.selectedSegmentIndex = selectedIndex
        uiView.apportionsSegmentWidthsByContent = !evenlySpaced
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        let parent: Selector
        init(_ parent: Selector) { self.parent = parent }
        @objc func changed(_ sc: UISegmentedControl) {
            parent.selectedIndex = sc.selectedSegmentIndex
            Haptic.light()
        }
    }
}

// MARK: - ModuleSelector

struct ModuleSelector: View {
    let module: CourseModel.Module
    let modIndex: Int
    @ObservedObject var backend: Backend

    @State private var expanded = false
    @State private var collapseObserver: AnyCancellable?

    var body: some View {
        let isLocked = backend.publishedEffectiveLimit(for: modIndex) == 0
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.name ?? "Module")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(
                            backend.modulesRequiringSelection.contains(modIndex)
                            ? .red
                            : (isLocked ? .gray : .primary)
                        )
                    Text(backend.moduleStatusText(modIndex: modIndex))
                        .font(.system(size: 14))
                        .foregroundColor(backend.moduleStatusColor(modIndex: modIndex))
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundColor(.gray)
            }
            .padding()
            .background(Color("presetFloat"))
            .cornerRadius(8)
            .opacity(isLocked ? 0.6 : 1.0)
            .onTapGesture {
                if isLocked {
                    Haptic.error()
                    return
                }
                Haptic.light()
                withAnimation { expanded.toggle() }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(module.subjects.enumerated()), id: \.1.stableId) { idx, subj in
                        let disabled = backend.isDisabled(modIndex: modIndex, itemIndex: idx)
                        Button(action: {
                            Haptic.medium()
                            backend.toggleSelection(modIndex: modIndex, itemIndex: idx)
                        }) {
                            HStack {
                                Text(subj.name)
                                    .foregroundColor(
                                        backend.requiredSubjectIDs.contains(subj.id)
                                        ? .red
                                        : (disabled ? .gray : .primary)
                                    )
                                Spacer()
                                if backend.isSelected(modIndex: modIndex, itemIndex: idx) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                } else if disabled {
                                    Image(systemName: "lock.fill").foregroundColor(.gray)
                                } else {
                                    Image(systemName: "circle").foregroundColor(.gray)
                                }
                            }.padding()
                        }
                        .disabled(disabled || isLocked)
                        .opacity((disabled || isLocked) ? 0.5 : 1.0)
                        Divider().padding(.leading, 15)
                    }
                }
                .background(Color(UIColor.systemBackground))
                .cornerRadius(8)
            }
        }.onAppear {
            collapseObserver = NotificationCenter.default.publisher(for: Notification.Name("ModuleShouldCollapse"))
                .receive(on: RunLoop.main)
                .sink { note in
                    if let info = note.userInfo, let idx = info["moduleIndex"] as? Int, idx == modIndex {
                        withAnimation { expanded = false }
                    }
                }
        }.onDisappear {
            collapseObserver?.cancel()
            collapseObserver = nil
        }
    }
}

// MARK: - Haptics

enum Haptic {
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Helpers

private extension String {
    func width(usingFont font: UIFont) -> CGFloat {
        let attributes = [NSAttributedString.Key.font: font]
        let size = (self as NSString).size(withAttributes: attributes)
        return ceil(size.width)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
