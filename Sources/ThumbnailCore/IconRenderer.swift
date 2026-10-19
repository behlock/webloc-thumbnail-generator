import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum IconRenderer {
    /// Draw into an owned bitmap, without AppKit drawing or main-actor work.
    public static func render(screenshot: CGImage, websiteURL: URL) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ThumbnailError.message("Couldn’t draw the thumbnail.")
        }
        context.interpolationQuality = .high
        context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: 504, height: 504),
            cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let scale = min(504.0 / Double(screenshot.width), 416.0 / Double(screenshot.height))
        let width = Double(screenshot.width) * scale
        let height = Double(screenshot.height) * scale
        context.draw(screenshot, in: CGRect(x: 256 - width / 2, y: 508 - height, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 4, y: 4, width: 504, height: 88))
        let systemFont = CTFontCreateUIFontForLanguage(.system, 25, nil)!
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.23]
        ] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(systemFont, 25, nil, descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.18, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: websiteURL.host ?? "Website", attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        context.textPosition = CGPoint(x: 26, y: 35)
        CTLineDraw(CTLineCreateTruncatedLine(line, 460, .middle, ellipsis) ?? line, context)
        guard let image = context.makeImage() else { throw ThumbnailError.message("Couldn’t create the thumbnail image.") }
        return image
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ThumbnailError.message("Couldn’t encode the thumbnail.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.message("Couldn’t encode the thumbnail.") }
        return data as Data
    }
}
