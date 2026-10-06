import XCTest
@testable import HomeCortex

final class AppMetadataTests: XCTestCase {
    func testMetadataComesFromApplicationBundle() {
        let metadata = AppMetadata()

        XCTAssertEqual(metadata.version, "0.1.0")
        XCTAssertEqual(metadata.build, "1")
        XCTAssertEqual(metadata.versionDescription, "Version 0.1.0 (build 1)")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Home Cortex")
    }

    func testApplicationSupportsBothDeviceFamilies() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int], [1, 2])
    }
}
