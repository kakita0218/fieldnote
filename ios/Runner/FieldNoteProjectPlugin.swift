import Flutter
import PDFKit
import PencilKit
import UIKit

final class FieldNoteProjectPlugin: NSObject, FlutterPlugin {
  private weak var viewController: UIViewController?
  private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextBackgroundTaskToken = 1

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "jp.fieldnote/project",
      binaryMessenger: registrar.messenger()
    )
    let instance = FieldNoteProjectPlugin()
    instance.viewController = registrar.viewController()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "beginBackgroundSave":
      beginBackgroundSave(call, result: result)
    case "endBackgroundSave":
      endBackgroundSave(call, result: result)
    case "writeAnnotatedPdf":
      writeAnnotatedPdf(call, result: result)
    case "synchronizePencilDrawings":
      synchronizePencilDrawings(call, result: result)
    case "openPencilEditor":
      openPencilEditor(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func arguments(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) -> [String: Any]? {
    guard let arguments = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "引数を読み取れませんでした。",
          details: nil
        )
      )
      return nil
    }
    return arguments
  }

  private func beginBackgroundSave(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let arguments = call.arguments as? [String: Any]
    let reason = arguments?["reason"] as? String ?? "FieldNote save"
    result(startBackgroundTask(named: reason))
  }

  private func startBackgroundTask(named reason: String) -> Int? {
    let token = nextBackgroundTaskToken
    nextBackgroundTaskToken += 1
    var identifier = UIBackgroundTaskIdentifier.invalid
    identifier = UIApplication.shared.beginBackgroundTask(withName: reason) {
      if let expired = self.backgroundTasks.removeValue(forKey: token) {
        UIApplication.shared.endBackgroundTask(expired)
      }
    }
    guard identifier != .invalid else { return nil }
    backgroundTasks[token] = identifier
    return token
  }

  private func finishBackgroundTask(_ token: Int?) {
    guard
      let token,
      let identifier = backgroundTasks.removeValue(forKey: token)
    else {
      return
    }
    UIApplication.shared.endBackgroundTask(identifier)
  }

  private func endBackgroundSave(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = arguments(call, result: result),
      let value = arguments["identifier"] as? Int
    else {
      result(nil)
      return
    }
    finishBackgroundTask(value)
    result(nil)
  }

  private func writeAnnotatedPdf(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let arguments = arguments(call, result: result) else { return }
    guard
      let sourcePath = arguments["sourcePath"] as? String,
      let outputPath = arguments["outputPath"] as? String,
      let pins = arguments["pins"] as? [[String: Any]],
      let strokes = arguments["strokes"] as? [[String: Any]]
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "PDF保存に必要な情報が不足しています。",
          details: nil
        )
      )
      return
    }

    let task = startBackgroundTask(named: "FieldNote PDF save")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try FieldNotePdfWriter.write(
          sourceURL: URL(fileURLWithPath: sourcePath),
          outputURL: URL(fileURLWithPath: outputPath),
          pins: pins,
          strokes: strokes
        )
        DispatchQueue.main.async {
          self.finishBackgroundTask(task)
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          self.finishBackgroundTask(task)
          result(
            FlutterError(
              code: "pdf_write_failed",
              message: "PDFを保存できませんでした。",
              details: error.localizedDescription
            )
          )
        }
      }
    }
  }

  private func openPencilEditor(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let arguments = arguments(call, result: result) else { return }
    guard
      let sourcePath = arguments["sourcePath"] as? String,
      let presenter = topViewController(from: viewController)
    else {
      result(
        FlutterError(
          code: "editor_unavailable",
          message: "手書き画面を開けませんでした。",
          details: nil
        )
      )
      return
    }
    guard #available(iOS 16.0, *) else {
      result(
        FlutterError(
          code: "unsupported_ios",
          message: "純正手書き機能にはiPadOS 16以降が必要です。",
          details: nil
        )
      )
      return
    }

    let title = arguments["title"] as? String ?? "手書き"
    do {
      let editor = try FieldNotePencilEditorViewController(
        sourceURL: URL(fileURLWithPath: sourcePath),
        documentTitle: title
      )
      editor.completion = { saved in
        result(saved)
      }
      let navigation = UINavigationController(rootViewController: editor)
      navigation.modalPresentationStyle = .fullScreen
      presenter.present(navigation, animated: true)
    } catch {
      result(
        FlutterError(
          code: "editor_open_failed",
          message: "PDFを手書き画面で開けませんでした。",
          details: error.localizedDescription
        )
      )
    }
  }

  private func synchronizePencilDrawings(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let arguments = arguments(call, result: result) else { return }
    guard let sourcePath = arguments["sourcePath"] as? String else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "手書きの復元先が見つかりません。",
          details: nil
        )
      )
      return
    }
    guard #available(iOS 16.0, *) else {
      result(nil)
      return
    }
    do {
      try FieldNotePencilEditorViewController.synchronizePendingDrawing(
        sourceURL: URL(fileURLWithPath: sourcePath)
      )
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "pencil_sync_failed",
          message: "自動保存した手書きを復元できませんでした。",
          details: error.localizedDescription
        )
      )
    }
  }

  private func topViewController(from root: UIViewController?) -> UIViewController? {
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    return root
  }
}

private enum FieldNotePdfError: LocalizedError {
  case cannotOpenSource
  case cannotCreateData

  var errorDescription: String? {
    switch self {
    case .cannotOpenSource:
      return "元のPDFを開けません。"
    case .cannotCreateData:
      return "PDFデータを生成できません。"
    }
  }
}

private enum FieldNotePdfWriter {
  private static let exportPrefix = "fieldnote-export:"

  static func write(
    sourceURL: URL,
    outputURL: URL,
    pins: [[String: Any]],
    strokes: [[String: Any]]
  ) throws {
    guard let document = PDFDocument(url: sourceURL) else {
      throw FieldNotePdfError.cannotOpenSource
    }
    removePreviousExportAnnotations(from: document)
    addStrokes(strokes, to: document)
    addPins(pins, to: document)

    guard let data = document.dataRepresentation() else {
      throw FieldNotePdfError.cannotCreateData
    }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)
  }

  private static func removePreviousExportAnnotations(from document: PDFDocument) {
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        let name = annotation.value(forAnnotationKey: .name) as? String
        if name?.hasPrefix(exportPrefix) == true {
          page.removeAnnotation(annotation)
        }
      }
    }
  }

  private static func addStrokes(
    _ strokes: [[String: Any]],
    to document: PDFDocument
  ) {
    for stroke in strokes {
      guard
        let pageNumber = number(stroke["pageNumber"])?.intValue,
        pageNumber > 0,
        pageNumber <= document.pageCount,
        let page = document.page(at: pageNumber - 1),
        let rawPoints = stroke["points"] as? [[String: Any]],
        rawPoints.count > 1
      else {
        continue
      }
      let pageBounds = page.bounds(for: .mediaBox)
      let path = UIBezierPath()
      for (index, rawPoint) in rawPoints.enumerated() {
        guard
          let x = number(rawPoint["x"])?.doubleValue,
          let y = number(rawPoint["y"])?.doubleValue
        else {
          continue
        }
        let point = CGPoint(
          x: CGFloat(x) * pageBounds.width,
          y: (1 - CGFloat(y)) * pageBounds.height
        )
        if index == 0 {
          path.move(to: point)
        } else {
          path.addLine(to: point)
        }
      }
      let annotation = PDFAnnotation(
        bounds: CGRect(origin: .zero, size: pageBounds.size),
        forType: .ink,
        withProperties: nil
      )
      annotation.add(path)
      annotation.color = color(from: stroke["color"])
      let border = PDFBorder()
      border.lineWidth = CGFloat(number(stroke["width"])?.doubleValue ?? 3)
      annotation.border = border
      setName(
        "\(exportPrefix)stroke:\(stroke["id"] as? String ?? UUID().uuidString)",
        on: annotation
      )
      page.addAnnotation(annotation)
    }
  }

  private static func addPins(
    _ pins: [[String: Any]],
    to document: PDFDocument
  ) {
    for pin in pins {
      guard
        let pageNumber = number(pin["pageNumber"])?.intValue,
        pageNumber > 0,
        pageNumber <= document.pageCount,
        let page = document.page(at: pageNumber - 1),
        let x = number(pin["xRatio"])?.doubleValue,
        let y = number(pin["yRatio"])?.doubleValue
      else {
        continue
      }
      let pageBounds = page.bounds(for: .mediaBox)
      let center = CGPoint(
        x: CGFloat(x) * pageBounds.width,
        y: (1 - CGFloat(y)) * pageBounds.height
      )
      let pinColor = color(from: pin["colorValue"])
      let edgeColor = readableEdgeColor(for: pinColor)
      let pinId = pin["id"] as? String ?? UUID().uuidString
      let numberText = "\(number(pin["number"])?.intValue ?? 0)"
      let radius: CGFloat = 12
      let circleBounds = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )

      let circle = PDFAnnotation(
        bounds: circleBounds,
        forType: .circle,
        withProperties: nil
      )
      circle.color = edgeColor
      circle.interiorColor = pinColor
      let circleBorder = PDFBorder()
      circleBorder.lineWidth = 1.8
      circle.border = circleBorder
      setName("\(exportPrefix)pin-circle:\(pinId)", on: circle)
      page.addAnnotation(circle)

      let label = PDFAnnotation(
        bounds: circleBounds,
        forType: .freeText,
        withProperties: nil
      )
      label.contents = numberText
      label.font = .boldSystemFont(ofSize: numberText.count >= 3 ? 9 : 11)
      label.fontColor = readableTextColor(for: pinColor)
      label.alignment = .center
      label.color = .clear
      let labelBorder = PDFBorder()
      labelBorder.lineWidth = 0
      label.border = labelBorder
      setName("\(exportPrefix)pin-label:\(pinId)", on: label)
      page.addAnnotation(label)

      let direction =
        CGFloat(number(pin["directionDegrees"])?.doubleValue ?? 0) * .pi / 180
      let forward = CGPoint(x: sin(direction), y: cos(direction))
      let side = CGPoint(x: cos(direction), y: -sin(direction))
      let shaftStart = CGPoint(
        x: center.x + forward.x * (radius + 2),
        y: center.y + forward.y * (radius + 2)
      )
      let shaftEnd = CGPoint(
        x: center.x + forward.x * (radius + 11),
        y: center.y + forward.y * (radius + 11)
      )
      let arrowPath = UIBezierPath()
      arrowPath.move(to: shaftStart)
      arrowPath.addLine(to: shaftEnd)
      let arrowBack = CGPoint(
        x: shaftEnd.x - forward.x * 5,
        y: shaftEnd.y - forward.y * 5
      )
      arrowPath.move(
        to: CGPoint(
          x: arrowBack.x + side.x * 3,
          y: arrowBack.y + side.y * 3
        )
      )
      arrowPath.addLine(to: shaftEnd)
      arrowPath.addLine(
        to: CGPoint(
          x: arrowBack.x - side.x * 3,
          y: arrowBack.y - side.y * 3
        )
      )
      let arrow = PDFAnnotation(
        bounds: CGRect(origin: .zero, size: pageBounds.size),
        forType: .ink,
        withProperties: nil
      )
      arrow.add(arrowPath)
      arrow.color = pinColor
      let arrowBorder = PDFBorder()
      arrowBorder.lineWidth = max(1.2, radius * 0.16)
      arrow.border = arrowBorder
      setName("\(exportPrefix)pin-direction:\(pinId)", on: arrow)
      page.addAnnotation(arrow)
    }
  }

  private static func setName(_ name: String, on annotation: PDFAnnotation) {
    _ = annotation.setValue(name, forAnnotationKey: .name)
  }

  private static func number(_ value: Any?) -> NSNumber? {
    if let value = value as? NSNumber { return value }
    if let value = value as? Int { return NSNumber(value: value) }
    if let value = value as? Double { return NSNumber(value: value) }
    return nil
  }

  private static func color(from value: Any?) -> UIColor {
    guard let raw = number(value) else { return .systemBlue }
    let argb = UInt32(bitPattern: Int32(truncating: raw))
    return UIColor(
      red: CGFloat((argb >> 16) & 0xff) / 255,
      green: CGFloat((argb >> 8) & 0xff) / 255,
      blue: CGFloat(argb & 0xff) / 255,
      alpha: CGFloat((argb >> 24) & 0xff) / 255
    )
  }

  private static func readableTextColor(for color: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: nil)
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance > 0.62 ? .black : .white
  }

  private static func readableEdgeColor(for color: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: nil)
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance > 0.62
      ? UIColor(red: 0.23, green: 0.20, blue: 0.13, alpha: 1)
      : .white
  }
}

@available(iOS 16.0, *)
private final class FieldNotePencilEditorViewController:
  UIViewController,
  PDFPageOverlayViewProvider,
  PKCanvasViewDelegate
{
  var completion: ((Bool) -> Void)?

  private static let drawingPrefix = "fieldnote-drawing:"
  private static let drawingDataKey =
    PDFAnnotationKey(rawValue: "FieldNoteDrawingData")

  private let sourceURL: URL
  private let document: PDFDocument
  private let pdfView = PDFView()
  private let toolPicker = PKToolPicker()
  private var drawings: [Int: PKDrawing] = [:]
  private var canvases: [Int: PKCanvasView] = [:]
  private var pendingSaveWorkItem: DispatchWorkItem?
  private var completed = false

  init(sourceURL: URL, documentTitle: String) throws {
    guard let document = PDFDocument(url: sourceURL) else {
      throw FieldNotePdfError.cannotOpenSource
    }
    self.sourceURL = sourceURL
    self.document = document
    super.init(nibName: nil, bundle: nil)
    title = documentTitle
    loadStoredDrawings()
    loadSidecarDrawings()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "キャンセル",
      style: .plain,
      target: self,
      action: #selector(cancel)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完了",
      style: .done,
      target: self,
      action: #selector(save)
    )

    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.document = document
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageOverlayViewProvider = self
    view.addSubview(pdfView)
    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(checkpointPendingDrawing),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
  }

  deinit {
    pendingSaveWorkItem?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    let index = document.index(for: page)
    if let existing = canvases[index] { return existing }
    let canvas = PKCanvasView(frame: .zero)
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    canvas.drawingPolicy = .pencilOnly
    canvas.drawing = drawings[index] ?? PKDrawing()
    canvas.delegate = self
    canvases[index] = canvas
    return canvas
  }

  func pdfView(
    _ pdfView: PDFView,
    willDisplayOverlayView overlayView: UIView,
    for page: PDFPage
  ) {
    guard let canvas = overlayView as? PKCanvasView else { return }
    toolPicker.addObserver(canvas)
    toolPicker.setVisible(true, forFirstResponder: canvas)
    canvas.becomeFirstResponder()
  }

  func pdfView(
    _ pdfView: PDFView,
    willEndDisplayingOverlayView overlayView: UIView,
    for page: PDFPage
  ) {
    guard let canvas = overlayView as? PKCanvasView else { return }
    drawings[document.index(for: page)] = canvas.drawing
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    pendingSaveWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.checkpointPendingDrawing()
    }
    pendingSaveWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(350),
      execute: workItem
    )
  }

  private func loadStoredDrawings() {
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        let name = annotation.value(forAnnotationKey: .name) as? String
        guard name?.hasPrefix(Self.drawingPrefix) == true else { continue }
        if
          let data = annotation.value(forAnnotationKey: Self.drawingDataKey)
            as? Data,
          let drawing = try? PKDrawing(data: data)
        {
          drawings[pageIndex] = drawing
        }
        page.removeAnnotation(annotation)
      }
    }
  }

  private func loadSidecarDrawings() {
    if
      let saved = try? Self.readDrawings(
        from: Self.canonicalSidecarURL(for: sourceURL)
      )
    {
      drawings.merge(saved) { _, latest in latest }
    }
    if
      let pending = try? Self.readDrawings(
        from: Self.pendingSidecarURL(for: sourceURL)
      )
    {
      drawings.merge(pending) { _, latest in latest }
    }
  }

  private func collectVisibleDrawings() {
    for (pageIndex, canvas) in canvases {
      drawings[pageIndex] = canvas.drawing
    }
  }

  @objc private func cancel() {
    pendingSaveWorkItem?.cancel()
    try? FileManager.default.removeItem(
      at: Self.pendingSidecarURL(for: sourceURL)
    )
    finish(saved: false)
  }

  @objc private func save() {
    pendingSaveWorkItem?.cancel()
    collectVisibleDrawings()
    do {
      try Self.writeDrawings(
        drawings,
        to: Self.pendingSidecarURL(for: sourceURL)
      )
      Self.replaceDrawingAnnotations(in: document, drawings: drawings)
      guard let data = document.dataRepresentation() else {
        throw FieldNotePdfError.cannotCreateData
      }
      try data.write(to: sourceURL, options: .atomic)
      try Self.writeDrawings(
        drawings,
        to: Self.canonicalSidecarURL(for: sourceURL)
      )
      try? FileManager.default.removeItem(
        at: Self.pendingSidecarURL(for: sourceURL)
      )
      finish(saved: true)
    } catch {
      let alert = UIAlertController(
        title: "保存できませんでした",
        message: error.localizedDescription,
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "閉じる", style: .default))
      present(alert, animated: true)
    }
  }

  @objc private func checkpointPendingDrawing() {
    collectVisibleDrawings()
    try? Self.writeDrawings(
      drawings,
      to: Self.pendingSidecarURL(for: sourceURL)
    )
  }

  private func finish(saved: Bool) {
    guard !completed else { return }
    completed = true
    dismiss(animated: true) { [completion] in
      completion?(saved)
    }
  }

  private static func canonicalSidecarURL(for sourceURL: URL) -> URL {
    sourceURL.appendingPathExtension("pencilkit")
  }

  private static func pendingSidecarURL(for sourceURL: URL) -> URL {
    sourceURL.appendingPathExtension("pencilkit.pending")
  }

  private static func readDrawings(from url: URL) throws -> [Int: PKDrawing] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    guard let values = propertyList as? [String: Any] else { return [:] }
    var result: [Int: PKDrawing] = [:]
    for (key, value) in values {
      guard
        let pageIndex = Int(key),
        let drawingData = value as? Data,
        let drawing = try? PKDrawing(data: drawingData)
      else {
        continue
      }
      result[pageIndex] = drawing
    }
    return result
  }

  private static func writeDrawings(
    _ drawings: [Int: PKDrawing],
    to url: URL
  ) throws {
    let values = Dictionary(
      uniqueKeysWithValues: drawings.map {
        (String($0.key), $0.value.dataRepresentation())
      }
    )
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .binary,
      options: 0
    )
    try data.write(to: url, options: .atomic)
  }

  private static func replaceDrawingAnnotations(
    in document: PDFDocument,
    drawings: [Int: PKDrawing]
  ) {
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        let name = annotation.value(forAnnotationKey: .name) as? String
        if name?.hasPrefix(drawingPrefix) == true {
          page.removeAnnotation(annotation)
        }
      }
      guard
        let drawing = drawings[pageIndex],
        !drawing.strokes.isEmpty
      else {
        continue
      }
      let annotation = FieldNoteDrawingAnnotation(
        bounds: drawing.bounds,
        drawing: drawing
      )
      _ = annotation.setValue(
        "\(drawingPrefix)\(pageIndex)",
        forAnnotationKey: .name
      )
      _ = annotation.setValue(
        drawing.dataRepresentation(),
        forAnnotationKey: drawingDataKey
      )
      page.addAnnotation(annotation)
    }
  }

  static func synchronizePendingDrawing(sourceURL: URL) throws {
    let pendingURL = pendingSidecarURL(for: sourceURL)
    guard FileManager.default.fileExists(atPath: pendingURL.path) else {
      return
    }
    guard let document = PDFDocument(url: sourceURL) else {
      throw FieldNotePdfError.cannotOpenSource
    }
    var drawings =
      (try? readDrawings(from: canonicalSidecarURL(for: sourceURL))) ?? [:]
    let pending = try readDrawings(from: pendingURL)
    drawings.merge(pending) { _, latest in latest }
    replaceDrawingAnnotations(in: document, drawings: drawings)
    guard let data = document.dataRepresentation() else {
      throw FieldNotePdfError.cannotCreateData
    }
    try data.write(to: sourceURL, options: .atomic)
    try writeDrawings(drawings, to: canonicalSidecarURL(for: sourceURL))
    try? FileManager.default.removeItem(at: pendingURL)
  }
}

@available(iOS 16.0, *)
private final class FieldNoteDrawingAnnotation: PDFAnnotation {
  private let drawing: PKDrawing

  init(bounds: CGRect, drawing: PKDrawing) {
    self.drawing = drawing
    super.init(bounds: bounds, forType: .stamp, withProperties: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    let image = drawing.image(from: drawing.bounds, scale: 1)
    UIGraphicsPushContext(context)
    context.saveGState()
    image.draw(in: drawing.bounds)
    context.restoreGState()
    UIGraphicsPopContext()
  }
}
