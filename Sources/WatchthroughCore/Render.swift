import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct StripRenderOptions: Equatable, Sendable {
    public static let hardMaximumCells = 20
    public static let hardMaximumStripWidth = 6_000

    public var maximumCellsPerSheet: Int
    public var preferredCellWidth: Int
    public var minimumCellWidth: Int
    public var maximumCellWidth: Int
    public var maximumCaptionLines: Int

    public init(
        maximumCellsPerSheet: Int = 15,
        preferredCellWidth: Int = 360,
        minimumCellWidth: Int = 280,
        maximumCellWidth: Int = 420,
        maximumCaptionLines: Int = 4
    ) {
        self.maximumCellsPerSheet = min(Self.hardMaximumCells, max(1, maximumCellsPerSheet))
        self.minimumCellWidth = min(420, max(280, minimumCellWidth))
        self.maximumCellWidth = min(420, max(self.minimumCellWidth, maximumCellWidth))
        self.preferredCellWidth = min(self.maximumCellWidth, max(self.minimumCellWidth, preferredCellWidth))
        self.maximumCaptionLines = min(4, max(1, maximumCaptionLines))
    }
}

/// Renders one-row, transcript-captioned PNG strips without invoking a second
/// image tool. Pages are balanced rather than leaving a nearly empty last page.
public enum StripRenderer {
    public static func balancedPageSizes(itemCount: Int, maximumPerPage: Int = 15) -> [Int] {
        guard itemCount > 0 else { return [] }
        let maximum = min(StripRenderOptions.hardMaximumCells, max(1, maximumPerPage))
        let pageCount = Int(ceil(Double(itemCount) / Double(maximum)))
        let base = itemCount / pageCount
        let remainder = itemCount % pageCount
        return (0..<pageCount).map { base + ($0 < remainder ? 1 : 0) }
    }

    public static func balancedPages<Element>(
        _ elements: [Element],
        maximumPerPage: Int = 15
    ) -> [[Element]] {
        var offset = 0
        return balancedPageSizes(itemCount: elements.count, maximumPerPage: maximumPerPage).map { count in
            defer { offset += count }
            return Array(elements[offset..<(offset + count)])
        }
    }

    /// Renders all packet cells and returns the PNG paths in page order.
    public static func render(
        cells: [PacketCell],
        framesBaseURL: URL,
        destinationDirectory: URL,
        basename: String = "strip",
        options: StripRenderOptions = StripRenderOptions()
    ) throws -> [URL] {
        guard !basename.isEmpty,
              !basename.contains("/"),
              !basename.contains(":") else {
            throw WatchthroughFailure(.usage, "Strip basename must be one safe file name component.")
        }
        guard !cells.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let pages = balancedPages(cells, maximumPerPage: options.maximumCellsPerSheet)
        var output: [URL] = []
        for (index, page) in pages.enumerated() {
            let suffix = String(format: "%02d", index + 1)
            let destination = destinationDirectory.appendingPathComponent("\(basename)-\(suffix).png")
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw WatchthroughFailure(.operation, "Refusing to overwrite existing strip at \(destination.path).")
            }
            try renderPage(
                cells: page,
                framesBaseURL: framesBaseURL,
                destination: destination,
                options: options
            )
            output.append(destination)
        }
        return output
    }

    private static func renderPage(
        cells: [PacketCell],
        framesBaseURL: URL,
        destination: URL,
        options: StripRenderOptions
    ) throws {
        let desiredCellWidth = min(
            options.maximumCellWidth,
            max(
                options.minimumCellWidth,
                min(options.preferredCellWidth, StripRenderOptions.hardMaximumStripWidth / cells.count)
            )
        )
        let actualCellWidth = min(
            desiredCellWidth,
            StripRenderOptions.hardMaximumStripWidth / cells.count
        )
        let stripWidth = actualCellWidth * cells.count
        let frameURLs = cells.map { resolve(path: $0.framePath, relativeTo: framesBaseURL) }
        let geometries = try frameURLs.map { try imageGeometry(at: $0) }
        let imageHeights = geometries.map { geometry in
            max(1, Int((Double(actualCellWidth) * Double(geometry.height) / Double(geometry.width)).rounded()))
        }
        let imageAreaHeight = imageHeights.max() ?? 1
        let captionLineHeight = 18
        let captionHeight = 12 + 17 + 5 + options.maximumCaptionLines * captionLineHeight + 12
        let stripHeight = imageAreaHeight + captionHeight

        guard let context = CGContext(
            data: nil,
            width: stripWidth,
            height: stripHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WatchthroughFailure(.operation, "Could not allocate the strip image canvas.")
        }

        context.setFillColor(CGColor(red: 0.976, green: 0.973, blue: 0.957, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: stripWidth, height: stripHeight))
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        for (index, cell) in cells.enumerated() {
            let x = index * actualCellWidth
            let frameHeight = imageHeights[index]
            let frameY = captionHeight + (imageAreaHeight - frameHeight) / 2

            context.setFillColor(CGColor(gray: 0.055, alpha: 1))
            context.fill(CGRect(x: x, y: captionHeight, width: actualCellWidth, height: imageAreaHeight))
            let thumbnailSize = max(actualCellWidth, frameHeight) * 2
            let image = try loadImage(at: frameURLs[index], maximumPixelSize: thumbnailSize)
            context.draw(
                image,
                in: CGRect(x: x, y: frameY, width: actualCellWidth, height: frameHeight)
            )

            context.setFillColor(CGColor(red: 0.976, green: 0.973, blue: 0.957, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: actualCellWidth, height: captionHeight))
            drawCaption(
                cell: cell,
                context: context,
                rect: CGRect(x: x + 12, y: 0, width: actualCellWidth - 24, height: captionHeight),
                maximumLines: options.maximumCaptionLines,
                lineHeight: CGFloat(captionLineHeight)
            )

            context.setStrokeColor(CGColor(gray: 0.76, alpha: 1))
            context.setLineWidth(1)
            context.stroke(CGRect(
                x: CGFloat(x) + 0.5,
                y: 0.5,
                width: CGFloat(actualCellWidth - 1),
                height: CGFloat(stripHeight - 1)
            ))
        }

        guard let image = context.makeImage(),
              let destinationWriter = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw WatchthroughFailure(.operation, "Could not create PNG output at \(destination.path).")
        }
        CGImageDestinationAddImage(destinationWriter, image, nil)
        guard CGImageDestinationFinalize(destinationWriter) else {
            throw WatchthroughFailure(.operation, "Could not finish PNG output at \(destination.path).")
        }
    }

    private static func resolve(path: String, relativeTo base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    private static func imageGeometry(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw WatchthroughFailure(.operation, "Could not read frame image at \(url.path).")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return (max(1, height.intValue), max(1, width.intValue))
        }
        return (max(1, width.intValue), max(1, height.intValue))
    }

    private static func loadImage(at url: URL, maximumPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WatchthroughFailure(.operation, "Could not open frame image at \(url.path).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WatchthroughFailure(.operation, "Could not decode frame image at \(url.path).")
        }
        return image
    }

    private static func drawCaption(
        cell: PacketCell,
        context: CGContext,
        rect: CGRect,
        maximumLines: Int,
        lineHeight: CGFloat
    ) {
        let timestampFont = CTFontCreateWithName("SFMono-Semibold" as CFString, 12, nil)
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let dark = CGColor(red: 0.105, green: 0.102, blue: 0.094, alpha: 1)
        let muted = CGColor(red: 0.38, green: 0.37, blue: 0.34, alpha: 1)
        context.textMatrix = .identity

        let timestamp = NSAttributedString(
            string: cell.timestamp,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): timestampFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): muted,
            ]
        )
        let timestampLine = CTLineCreateWithAttributedString(timestamp)
        context.textPosition = CGPoint(x: rect.minX, y: rect.maxY - 24)
        CTLineDraw(timestampLine, context)

        let normalized = cell.caption
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return }
        let caption = normalized
        let captionColor = dark
        let attributed = NSAttributedString(
            string: caption,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): bodyFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): captionColor,
            ]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let fullLength = attributed.length
        var position = 0
        var lineNumber = 0
        var baseline = rect.maxY - 48
        while position < fullLength, lineNumber < maximumLines {
            let remaining = fullLength - position
            let suggested = max(1, CTTypesetterSuggestLineBreak(typesetter, position, Double(rect.width)))
            let isLastAllowedLine = lineNumber == maximumLines - 1
            let line: CTLine
            if isLastAllowedLine, suggested < remaining {
                let remainingLine = CTTypesetterCreateLine(typesetter, CFRange(location: position, length: remaining))
                let ellipsis = NSAttributedString(
                    string: "…",
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): bodyFont,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): captionColor,
                    ]
                )
                let ellipsisLine = CTLineCreateWithAttributedString(ellipsis)
                line = CTLineCreateTruncatedLine(remainingLine, Double(rect.width), .end, ellipsisLine)
                    ?? CTTypesetterCreateLine(typesetter, CFRange(location: position, length: suggested))
                position = fullLength
            } else {
                line = CTTypesetterCreateLine(typesetter, CFRange(location: position, length: min(suggested, remaining)))
                position += min(suggested, remaining)
                while position < fullLength,
                      (attributed.string as NSString).character(at: position) == 32 {
                    position += 1
                }
            }
            context.textPosition = CGPoint(x: rect.minX, y: baseline)
            CTLineDraw(line, context)
            baseline -= lineHeight
            lineNumber += 1
        }
    }
}

/// Human and agent-readable companion to `packet.json`.
public enum PacketMarkdown {
    public static func render(_ packet: InspectionPacket) -> String {
        var lines: [String] = [
            "# Watchthrough inspection packet",
            "",
            "- Selector: `\(inlineCode(packet.selector))`",
            "- Source: `\(inlineCode(packet.sourcePath))`",
            "- Range: \(clock(packet.rangeStartSeconds)) to \(clock(packet.rangeEndSeconds))",
            "- Sampling: `\(inlineCode(packet.sampling))`",
            "- Timing: `\(packet.timingPrecision.rawValue)`",
            "- Largest uncovered gap: \(String(format: "%.2f", packet.largestGapSeconds)) seconds",
            "",
        ]

        if !packet.sheets.isEmpty {
            lines.append("## Contact strips")
            lines.append("")
            for (index, sheet) in packet.sheets.enumerated() {
                lines.append("![Strip page \(index + 1)](<\(markdownDestination(sheet))>)")
                lines.append("")
            }
        }

        lines.append("## Frames")
        lines.append("")
        for cell in packet.cells {
            lines.append("### \(cell.index + 1). \(escapedMarkdown(cell.timestamp))")
            lines.append("")
            lines.append("[Open JPEG](<\(markdownDestination(cell.framePath))>) · frame `\(cell.ordinal)` · interval \(clock(cell.intervalStartSeconds)) to \(clock(cell.intervalEndSeconds))")
            lines.append("")
            let caption = cell.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if caption.isEmpty {
                lines.append("> No transcript for this interval.")
            } else {
                for paragraphLine in caption.components(separatedBy: .newlines) {
                    lines.append("> \(paragraphLine.isEmpty ? " " : escapedMarkdown(paragraphLine))")
                }
            }
            lines.append("")
        }

        if !packet.warnings.isEmpty {
            lines.append("## Warnings")
            lines.append("")
            for warning in packet.warnings {
                let singleLine = warning.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                lines.append("- \(escapedMarkdown(singleLine))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func write(_ packet: InspectionPacket, to destination: URL) throws {
        let data = Data(render(packet).utf8)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw WatchthroughFailure(.operation, "Could not write packet Markdown: \(error.localizedDescription)")
        }
    }

    private static func inlineCode(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "`", with: "′")
    }

    private static func markdownDestination(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "/-._~:@%"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "invalid-path"
    }

    private static func escapedMarkdown(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        for marker in ["`", "*", "_", "[", "]", "(", ")", "#", "!", "|"] {
            escaped = escaped.replacingOccurrences(of: marker, with: "\\\(marker)")
        }
        return escaped
    }

    private static func clock(_ seconds: Double) -> String {
        let formatted = CLIParser.formatTime(seconds)
        return formatted.hasSuffix(".000") ? String(formatted.dropLast(4)) : formatted
    }
}
