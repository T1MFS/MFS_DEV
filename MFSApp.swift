import SwiftUI
import AVFoundation
import Vision
import UIKit

private enum MFSSection: String, CaseIterable, Identifiable {
    case manage = "Manage"
    case food = "Food"
    case evaluate = "Evaluate"
    case carbRatio = "Carb Ratio"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .manage: return "slider.horizontal.3"
        case .food: return "fork.knife"
        case .evaluate: return "chart.bar.xaxis"
        case .carbRatio: return "divide"
        }
    }
}

@main
struct MFSApp: App {
    @StateObject private var foodStore = AcceptedFoodStore()
    @State private var selectedSection: MFSSection = .manage
    @State private var managePath = NavigationPath()
    @State private var foodPath = NavigationPath()
    @State private var evaluatePath = NavigationPath()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedSection) {
                NavigationStack(path: $managePath) {
                    SectionRootView(section: .manage)
                }
                .tabItem {
                    Label(MFSSection.manage.rawValue, systemImage: MFSSection.manage.symbol)
                }
                .tag(MFSSection.manage)

                NavigationStack(path: $foodPath) {
                    SectionRootView(section: .food)
                }
                .tabItem {
                    Label(MFSSection.food.rawValue, systemImage: MFSSection.food.symbol)
                }
                .tag(MFSSection.food)

                NavigationStack(path: $evaluatePath) {
                    SectionRootView(section: .evaluate)
                }
                .tabItem {
                    Label(MFSSection.evaluate.rawValue, systemImage: MFSSection.evaluate.symbol)
                }
                .tag(MFSSection.evaluate)

                NavigationStack {
                    CarbRatioView()
                }
                .tabItem { Label("Carb Ratio", systemImage: "divide") }
                .tag(MFSSection.carbRatio)
            }
            .tint(Color(red: 0.16, green: 0.39, blue: 0.82))
            .preferredColorScheme(.light)
            .environmentObject(foodStore)
            .onChange(of: foodStore.food?.id) { _, id in
                guard id != nil else { return }
                managePath = NavigationPath()
                selectedSection = .manage
            }
        }
    }
}

private final class AcceptedFoodStore: ObservableObject {
    @Published private(set) var food: AcceptedFood?
    @Published private(set) var tidepoolDraft: TidepoolPreparedFood?

    func accept(_ food: AcceptedFood) {
        tidepoolDraft = TidepoolPreparedFood(food: food)
        self.food = food
    }
}

private struct ManageView: View {
    @EnvironmentObject private var store: AcceptedFoodStore
    @AppStorage(CarbRatioSettings.key) private var ratio = CarbRatioSettings.defaultValue
    @State private var useNet = false

    var body: some View {
        List {
            if let food = store.food {
                Section("Accepted food") {
                    Text(food.product.name)
                    LabeledContent("Servings", value: food.servings.formatted())
                    LabeledContent("Total carbs", value: food.totalCarbohydrates.map { "\($0.formatted()) g" } ?? "Unavailable")
                    LabeledContent("Net carbs", value: food.netCarbohydrates.map { "\($0.formatted()) g" } ?? "Unavailable")
                }
                Section("Carbs to use") {
                    carbOption("Total carbs", net: false)
                    carbOption("Net carbs", net: true)
                    Text("Net carbs = total carbs − ½ fiber.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Result") {
                    if let result = food.ratioResult(ratio: ratio, useNet: useNet) {
                        Text(result.formatted(.number.precision(.fractionLength(0...2))))
                            .font(.title2.bold())
                        Text("\(useNet ? "Net" : "Total") carbs ÷ \(ratio.formatted())")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Missing nutrition or serving size for this calculation.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let draft = store.tidepoolDraft {
                    Section("Tidepool preparation") {
                        Text(draft.nutritionJSON == nil ? "Needs more information" : "Nutrition prepared locally")
                        Text("Not uploaded. A complete food event still needs meal and event details.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(Array(draft.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Scan a food and tap Accept to bring it here.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Carb ratio", value: ratio.formatted())
                Text("Change this in the Carb Ratio tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func carbOption(_ title: String, net: Bool) -> some View {
        Button { useNet = net } label: {
            HStack {
                Image(systemName: useNet == net ? "largecircle.fill.circle" : "circle")
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(useNet == net ? .isSelected : [])
    }

}

private struct CarbRatioView: View {
    @AppStorage(CarbRatioSettings.key) private var savedRatio = CarbRatioSettings.defaultValue
    @State private var entry = ""
    @State private var saved = false
    @FocusState private var editing: Bool

    private var parsed: Double? {
        guard let number = try? Double(entry, format: .number.locale(.current)),
              number.isFinite, number > 0 else { return nil }
        return number
    }

    var body: some View {
        Form {
            Section("Carb ratio") {
                HStack {
                    Text("Ratio")
                    TextField("30", text: $entry)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($editing)
                        .accessibilityIdentifier("settings.carbRatio")
                }
                Text("Default: 30. Your saved value is kept between app launches.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !entry.isEmpty && parsed == nil {
                    Text("Enter a number greater than zero.")
                        .foregroundStyle(.red)
                }
                Button(saved ? "Saved" : "Save ratio") {
                    guard let parsed, CarbRatioSettings().save(parsed) else { return }
                    savedRatio = parsed
                    saved = true
                    editing = false
                }
                .disabled(parsed == nil)
            }
        }
        .navigationTitle("Carb Ratio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entry = CarbRatioSettings().value.formatted(.number.grouping(.never)) }
        .onChange(of: entry) { _, _ in saved = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }
}

private struct SectionRootView: View {
    let section: MFSSection

    var body: some View {
        Group {
            if section == .food {
                FoodSectionView()
            } else if section == .manage {
                ManageView()
            } else {
                ZStack {
                    Color(red: 0.96, green: 0.97, blue: 0.99)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color(red: 0.16, green: 0.39, blue: 0.82))
                            .frame(width: 72, height: 72)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        Text(section.rawValue)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.10, green: 0.14, blue: 0.22))
                    }
                }
            }
        }
        .navigationTitle(section.rawValue)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct FoodSectionView: View {
    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(geometry.size.width * 0.86, 440.0)
            let panelHeight = min(geometry.size.height * 0.88, 740.0)
            let tileWidth = min(panelWidth * 0.45, 158.0)
            let tileHeight = min(panelHeight * 0.22, 150.0)

            ZStack {
                Color(red: 0.96, green: 0.97, blue: 0.99)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .overlay {
                        Rectangle().stroke(.black, lineWidth: 4)
                    }
                    .frame(width: panelWidth, height: panelHeight)
                    .overlay {
                        GeometryReader { panel in
                            ZStack {
                                NavigationLink {
                                    FoodOptionView(title: "Text", symbol: "text.cursor")
                                } label: {
                                    FoodMenuTile(title: "Text", color: Color(red: 0.98, green: 0.66, blue: 0.04), width: tileWidth, height: tileHeight)
                                }
                                .position(x: panel.size.width * 0.34, y: panel.size.height * 0.30)

                                NavigationLink {
                                    FoodScanView()
                                } label: {
                                    FoodMenuTile(title: "Scan", color: Color(red: 0.10, green: 0.43, blue: 0.91), width: tileWidth, height: tileHeight)
                                }
                                .position(x: panel.size.width * 0.68, y: panel.size.height * 0.52)

                                NavigationLink {
                                    FoodOptionView(title: "Image Match", symbol: "photo.on.rectangle.angled")
                                } label: {
                                    FoodMenuTile(title: "Image Match", color: Color(red: 0.20, green: 0.72, blue: 0.18), width: tileWidth, height: tileHeight)
                                }
                                .position(x: panel.size.width * 0.36, y: panel.size.height * 0.75)
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Food")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct FoodMenuTile: View {
    let title: String
    let color: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .multilineTextAlignment(.center)
            .frame(width: width, height: height)
            .background(color)
            .overlay {
                Rectangle().stroke(.black, lineWidth: 4)
            }
            .contentShape(Rectangle())
    }
}

private struct FoodOptionView: View {
    let title: String
    let symbol: String

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99)
                .ignoresSafeArea()

            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color(red: 0.16, green: 0.39, blue: 0.82))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FoodScanView: View {
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @StateObject private var camera = FoodCameraModel()
    @FocusState private var editingServings: Bool
    private let ink = Color(red: 0.10, green: 0.14, blue: 0.22)
    private let green = Color(red: 0.20, green: 0.72, blue: 0.18)

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !editingServings { cameraPreview }
                    if let productName = camera.productName {
                        productSummary(productName)
                    }
                    servingsArea
                    nutritionFacts
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !editingServings { actionButtons }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingServings = false }
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var cameraPreview: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreview(session: camera.session)
                .frame(height: 120)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !camera.isReady {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.70))
                    .overlay {
                        Text(camera.cameraMessage)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(20)
                    }
            }

            Text("Center barcode here")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(12)
        }
        .frame(height: 120)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ink.opacity(0.16), lineWidth: 1)
        }
    }

    private func productSummary(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            if let barcode = camera.barcode {
                Text("Barcode: \(barcode)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var servingsArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Number of servings")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                TextField("Count", text: $camera.servingsText)
                    .font(.system(size: 14))
                    .keyboardType(.decimalPad)
                    .focused($editingServings)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("scan.servings")
                    .disabled(camera.isScanning || camera.productName == nil)
            }
            if let size = camera.servingSize {
                Text("Serving size: \(size)")
                    .font(.system(size: 12))
            }
            Text(camera.packageServings.map {
                "Package total: \($0.formatted(.number.precision(.fractionLength(0...4)))) servings."
            } ?? "Package count unavailable — enter servings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !camera.servingsText.isEmpty && camera.selectedServings == nil {
                Text("Enter a number greater than zero.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .foregroundStyle(ink)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var nutritionFacts: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nutrition Facts")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text("Open Food Facts")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(ink.opacity(0.75)).frame(height: 2)

            HStack(spacing: 8) {
                Text("Nutrient").frame(maxWidth: .infinity, alignment: .leading)
                Text("1 serving").frame(width: 76)
                Text("Per package").frame(width: 76)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                ForEach(NutritionField.allCases) { field in
                    nutritionRow(field)
                }
            }

            Link("About Open Food Facts data", destination: URL(string: "https://world.openfoodfacts.org/data")!)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.84, green: 0.86, blue: 0.90), lineWidth: 1)
        }
    }

    private func nutritionRow(_ field: NutritionField) -> some View {
        HStack(spacing: 8) {
            Text(field.label)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(camera.servingValues[field] ?? "—")
                .frame(width: 76)
            Text(camera.packageValues[field] ?? "—")
                .frame(width: 76)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(red: 0.86, green: 0.88, blue: 0.91)).frame(height: 1)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            if let message = camera.statusMessage {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(camera.scanFailed ? .red : ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 14) {
                Button {
                    editingServings = false
                    if let food = camera.acceptResults() { foodStore.accept(food) }
                } label: {
                    Text(camera.didAccept ? "Accepted" : "Accept")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(camera.values.isEmpty || camera.selectedServings == nil || camera.isScanning)
                .opacity(camera.values.isEmpty || camera.selectedServings == nil || camera.isScanning ? 0.55 : 1)

                Button {
                    editingServings = false
                    camera.captureAndReadLabel()
                } label: {
                    HStack(spacing: 8) {
                        if camera.isScanning {
                            ProgressView().tint(.white)
                        }
                        Text(camera.isScanning ? "Scanning…" : "Scan")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady || camera.isScanning)
                .opacity((!camera.isReady || camera.isScanning) ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

private final class FoodCameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    @Published private(set) var isReady = false
    @Published private(set) var cameraMessage = "Starting camera…"
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var scanFailed = false
    @Published private(set) var values: [NutritionField: String] = [:]
    @Published private(set) var productName: String?
    @Published private(set) var barcode: String?
    @Published private(set) var didAccept = false
    @Published var servingsText = "" {
        didSet {
            if didAccept { statusMessage = "Servings changed. Tap Accept to confirm." }
            didAccept = false
            acceptedServings = nil
        }
    }
    @Published private(set) var servingValues: [NutritionField: String] = [:]
    @Published private(set) var packageValues: [NutritionField: String] = [:]
    @Published private(set) var packageServings: Double?
    @Published private(set) var servingSize: String?
    private(set) var acceptedServings: Double?
    private var scannedProduct: OpenFoodFactsProduct?

    var selectedServings: Double? {
        let text = servingsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? Double(text, format: .number.locale(.current)),
              value.isFinite, value > 0 else { return nil }
        return value
    }


    private let sessionQueue = DispatchQueue(label: "com.example.mfs.food-camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            cameraMessage = "Requesting camera access…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async {
                        self.cameraMessage = "Camera access is off. Allow it in Settings to scan a barcode."
                    }
                }
            }
        case .denied, .restricted:
            cameraMessage = "Camera access is off. Allow it in Settings to scan a barcode."
        @unknown default:
            cameraMessage = "Camera access is unavailable."
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func captureAndReadLabel() {
        guard isReady, !isScanning else { return }
        isScanning = true
        didAccept = false
        scanFailed = false
        statusMessage = "Taking photo…"
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func acceptResults() -> AcceptedFood? {
        guard !values.isEmpty, !isScanning, let selectedServings, let scannedProduct else { return nil }
        acceptedServings = selectedServings
        didAccept = true
        statusMessage = "Nutrition values accepted for \(selectedServings.formatted()) servings."
        scanFailed = false
        return AcceptedFood(product: scannedProduct, servings: selectedServings)
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isConfigured else {
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isReady = true }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.cameraMessage = "No camera is available on this device." }
                    return
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.cameraMessage = "The camera could not be started." }
                    return
                }
                self.session.addInput(input)
                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.cameraMessage = "Photo capture is unavailable." }
                    return
                }
                self.session.addOutput(self.photoOutput)
                self.session.commitConfiguration()
                self.isConfigured = true
                self.session.startRunning()
                DispatchQueue.main.async { self.isReady = true }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.cameraMessage = "Could not start the camera: \(error.localizedDescription)" }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.isScanning = false
                self.scanFailed = true
                self.statusMessage = error?.localizedDescription ?? "The camera could not capture an image. Try again."
            }
            return
        }

        processCapturedImage(data)
    }

    func processCapturedImage(_ data: Data) {
        isScanning = true
        scanFailed = false
        statusMessage = "Reading barcode and looking up Open Food Facts…"
        servingsText = ""
        packageServings = nil
        servingSize = nil
        acceptedServings = nil
        scannedProduct = nil
        didAccept = false
        values = [:]
        servingValues = [:]
        packageValues = [:]
        productName = nil
        barcode = nil

        Task {
            do {
                let product = try await NutritionBarcodeScanner.lookupProduct(
                    fromCapturedImage: data,
                    using: OpenFoodFactsClient()
                )
                await MainActor.run {
                    self.isScanning = false
                    self.didAccept = false
                    guard let product else {
                        self.productName = nil
                        self.barcode = nil
                        self.values = [:]
                        self.scanFailed = true
                        self.statusMessage = "Product not found in Open Food Facts."
                        return
                    }
                    self.scannedProduct = product
                    self.productName = product.name
                    self.barcode = product.barcode
                    self.values = product.nutritionValues
                    self.servingValues = product.nutritionPerServing
                    self.packageValues = product.nutritionPerPackage
                    self.servingSize = product.servingSize
                    self.packageServings = product.servingsInPackage
                    self.servingsText = product.servingsInPackage.map {
                        $0.formatted(.number.grouping(.never).precision(.fractionLength(0...8)))
                    } ?? ""
                    self.scanFailed = product.nutritionValues.isEmpty
                    self.statusMessage = product.nutritionValues.isEmpty
                        ? "Found the product, but it has no nutrition data."
                        : "Product found."
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.scanFailed = true
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
