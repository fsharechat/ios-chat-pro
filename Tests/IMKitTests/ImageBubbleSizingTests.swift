import XCTest
@testable import IMKit

final class ImageBubbleSizingTests: XCTestCase {
    func test_displaySize_squareWithinBounds_keepsNaturalSize() {
        // 100x100 正方形,已经落在 [80,200] 区间内,不放大也不缩小,原样使用
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 100, height: 100))

        XCTAssertEqual(result, CGSize(width: 100, height: 100))
    }

    func test_displaySize_wideImage_scalesDownPreservingAspectRatio() {
        // 800x400,横向 2:1,缩到 200 宽后高 100,均在 [80,200] 区间内,直接采用
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 800, height: 400))

        XCTAssertEqual(result, CGSize(width: 200, height: 100))
    }

    func test_displaySize_tallScreenshot_scalesDownPreservingAspectRatio() {
        // 竖屏截图 900x1600(9:16),缩到高 200 后宽 112.5,均在 [80,200] 区间内
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 900, height: 1600))

        XCTAssertEqual(result.height, 200, accuracy: 0.01)
        XCTAssertEqual(result.width, 112.5, accuracy: 0.01)
    }

    func test_displaySize_tinyImage_growsUpToMinFloor() {
        // 40x40 正方形,小于下限 80,等比放大到 80x80
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 40, height: 40))

        XCTAssertEqual(result, CGSize(width: 80, height: 80))
    }

    func test_displaySize_largeSquare_scalesDownToMaxBox() {
        // 2000x2000,缩到 200x200
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 2000, height: 2000))

        XCTAssertEqual(result, CGSize(width: 200, height: 200))
    }

    func test_displaySize_extremeAspectRatio_isClampedToMaxOnBothAxes() {
        // 极端长图 2000x100(20:1),先等比缩到宽 200 时高只有 10,远小于下限 80;
        // 放大补足下限会让宽超过 200,最终两边都夹到上限 200x200(牺牲精确比例)
        let result = ImageBubbleSizing.displaySize(forNaturalSize: CGSize(width: 2000, height: 100))

        XCTAssertLessThanOrEqual(result.width, 200)
        XCTAssertLessThanOrEqual(result.height, 200)
        XCTAssertGreaterThanOrEqual(result.width, 80)
        XCTAssertGreaterThanOrEqual(result.height, 80)
    }

    func test_fallbackSize_is160x160() {
        XCTAssertEqual(ImageBubbleSizing.fallbackSize, CGSize(width: 160, height: 160))
    }
}
