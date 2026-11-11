import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var model = ReceiptViewModel()
    @State private var selection: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Strings.workflow).font(.headline)
                    Text(Strings.workflowDetail).font(.caption).foregroundStyle(.secondary)
                    Text(model.status)
                    if model.isBusy {
                        ProgressView()
                        Button(Strings.cancel, role: .cancel) { model.cancel() }
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(Strings.select, systemImage: "photo")
                    }
                    .disabled(model.isBusy)
                    if let image = model.preview {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                            .accessibilityLabel(Strings.selectedReceipt)
                    }
                    Button(Strings.run) { model.run() }.disabled(!model.canRun)
                }
                Section(Strings.stageTimes) {
                    TimelineView(.animation(minimumInterval: 0.2, paused: model.recognitionStarted == nil)) { _ in
                        VStack(spacing: 10) {
                            ForEach(ReceiptStage.allCases) { stage in
                                HStack {
                                    Text(Strings.title(stage))
                                    Spacer()
                                    Text(model.timeText(for: stage)).monospacedDigit()
                                }
                            }
                            Divider()
                            HStack {
                                Text(Strings.totalTime)
                                Spacer()
                                Text(model.totalTimeText).monospacedDigit()
                            }.fontWeight(.semibold)
                        }
                    }
                    Text(Strings.timing).font(.caption).foregroundStyle(.secondary)
                }
                Section(Strings.result) {
                    if let parsed = model.finalParse {
                        Label(parsed.passed ? Strings.passed : Strings.manualReview,
                              systemImage: parsed.passed ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(parsed.passed ? .green : .orange)
                        Text(Strings.arithmeticNotice).font(.caption).foregroundStyle(.secondary)
                        if !parsed.issues.isEmpty {
                            DisclosureGroup(Strings.checks) {
                                ForEach(Array(parsed.issues.enumerated()), id: \.offset) { _, issue in
                                    Text(issue).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    Text(model.result.isEmpty ? Strings.placeholder : model.result)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    ForEach(model.notices, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                if model.needsManualReview {
                    Section(Strings.manualDraft) {
                        Text(Strings.manualInstructions).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.manualDraft)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 240)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel(Strings.manualDraft)
                        Button(Strings.checkCorrections) { model.validateManualDraft() }
                        if let validation = model.manualValidation {
                            Label(validation.passed ? Strings.correctionPassed : Strings.manualReview,
                                  systemImage: validation.passed ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(validation.passed ? .green : .orange)
                            ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if model.firstParse != nil || !model.visionText.isEmpty {
                    Section(Strings.evidence) {
                        DisclosureGroup(Strings.visionEvidence) { evidenceText(model.visionText) }
                        DisclosureGroup(Strings.visionCoordinates) {
                            Text(Strings.coordinateDescription).font(.caption).foregroundStyle(.secondary)
                            evidenceText(model.visionCoordinates)
                        }
                        if !model.amountJSON.isEmpty {
                            DisclosureGroup(Strings.amountEvidence) { evidenceText(model.amountJSON) }
                        }
                        if !model.detailJSON.isEmpty {
                            DisclosureGroup(Strings.detailEvidence) { evidenceText(model.detailJSON) }
                        }
                        if let first = model.firstParse {
                            DisclosureGroup(Strings.initialJSON) {
                                evidenceText(first.output.text)
                                ForEach(Array(first.issues.enumerated()), id: \.offset) { _, issue in
                                    Text(issue).foregroundStyle(.orange)
                                }
                            }
                        }
                        if let final = model.finalParse {
                            DisclosureGroup(Strings.rawJSON) { evidenceText(final.output.text) }
                        }
                    }
                }
                if model.isBusy || !model.diagnostics.isEmpty {
                    Section {
                        Button(Strings.copyDiagnostics) { model.copyDiagnostics() }
                        if !model.diagnostics.isEmpty {
                            DisclosureGroup(Strings.diagnostics) { evidenceText(model.diagnostics) }
                        }
                    }
                }
            }
            .navigationTitle(Strings.title)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                model.applicationWillResignActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.recordMemoryWarning()
            }
            .onChange(of: selection) { _, item in
                if let item { model.select(item) }
            }
        }
    }

    private func evidenceText(_ text: String) -> some View {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
}

#Preview { ContentView() }
