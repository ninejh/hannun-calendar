import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasSuffix(".png") else {
    print("Usage: MakeIcon /path/to/generated-icon.png")
    exit(64)
}
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
@MainActor func roundRect(_ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}
let green = color(54, 95, 73)
let paper = color(252, 252, 248)
roundRect(CGRect(x: 60, y: 60, width: 904, height: 904), 208, green)
roundRect(CGRect(x: 218, y: 222, width: 588, height: 572), 72, paper)
context.setFillColor(green)
context.fill(CGRect(x: 250, y: 640, width: 524, height: 14))
roundRect(CGRect(x: 328, y: 738, width: 36, height: 104), 18, paper)
roundRect(CGRect(x: 660, y: 738, width: 36, height: 104), 18, paper)
for row in 0..<2 {
    for column in 0..<3 {
        roundRect(CGRect(x: 310 + column * 150, y: 326 + row * 155, width: 100, height: 100), 24,
                  row == 0 && column == 1 ? color(212, 110, 72) : green)
    }
}
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("아이콘 생성 실패") }
