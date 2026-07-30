import Flutter
import PDFKit
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testPdfGeometryMapsBoxOriginAndPageRotation() {
    let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
    let expected: [Int: CGPoint] = [
      0: CGPoint(x: 60, y: 80),
      90: CGPoint(x: 90, y: 45),
      180: CGPoint(x: 160, y: 60),
      270: CGPoint(x: 130, y: 95),
    ]

    for (rotation, point) in expected {
      let geometry = FieldNotePdfPageGeometry(
        bounds: bounds,
        rotation: rotation
      )
      guard
        let actual = geometry.point(xRatio: 0.25, yRatio: 0.4)
      else {
        XCTFail("Expected a mapped point for rotation \(rotation)")
        continue
      }
      XCTAssertEqual(actual.x, point.x, accuracy: 0.000_1)
      XCTAssertEqual(actual.y, point.y, accuracy: 0.000_1)
    }
  }

  func testPdfGeometryUsesMediaBoxRatherThanCropBox() {
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: 300, height: 400)
    ).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
    }
    guard let page = PDFPage(image: image) else {
      XCTFail("Expected a PDF page backed by the test image")
      return
    }

    let mediaBox = CGRect(x: 10, y: 20, width: 300, height: 400)
    let cropBox = CGRect(x: 40, y: 60, width: 200, height: 250)
    page.setBounds(mediaBox, for: .mediaBox)
    page.setBounds(cropBox, for: .cropBox)
    page.rotation = 90

    let geometry = FieldNotePdfPageGeometry(page: page)
    XCTAssertEqual(geometry.bounds, mediaBox)
    XCTAssertEqual(geometry.rotation, 90)
    let point = geometry.point(xRatio: 0.25, yRatio: 0.4)
    XCTAssertEqual(point?.x ?? .nan, 130, accuracy: 0.000_1)
    XCTAssertEqual(point?.y ?? .nan, 120, accuracy: 0.000_1)
  }

  func testPdfGeometryRotatesPinDirectionWithPage() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
    let expected: [Int: CGPoint] = [
      0: CGPoint(x: 0, y: 1),
      90: CGPoint(x: -1, y: 0),
      180: CGPoint(x: 0, y: -1),
      270: CGPoint(x: 1, y: 0),
    ]

    for (rotation, direction) in expected {
      let geometry = FieldNotePdfPageGeometry(
        bounds: bounds,
        rotation: rotation
      )
      let actual = geometry.direction(degrees: 0)
      XCTAssertEqual(actual.x, direction.x, accuracy: 0.000_1)
      XCTAssertEqual(actual.y, direction.y, accuracy: 0.000_1)
    }
  }

}
