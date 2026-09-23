import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading for direct routes: canonical paths, listings and metadata. Nothing here opens a file's contents except
/// ImageIO's header read for local images, and nothing downloads an iCloud file whose contents aren't on this Mac.
extension FileManagerFileSystem {
    /// "st_flags" bit for a dataless (evicted iCloud) file; reading its contents would download it.
    private static let datalessFileFlag: UInt32 = 0x4000_0000

    func canonicalPathKeepingLastComponent(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if path == "/" { return "/" }
        let lastComponent = (path as NSString).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else { return nil }
        guard let canonicalParentPath = Self.resolvedPath((path as NSString).deletingLastPathComponent) else { return nil }
        return UploadFileAllowlist.normalizedPath((canonicalParentPath as NSString).appendingPathComponent(lastComponent))
    }

    func canonicalExistingFolderPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), let resolvedPath = Self.resolvedPath(path) else { return nil }
        let canonicalPath = UploadFileAllowlist.normalizedPath(resolvedPath)
        return existingItemKind(atCanonicalPath: canonicalPath) == .folder ? canonicalPath : nil
    }

    /// The device number of the item, or of its nearest existing ancestor when it doesn't exist yet (a destination),
    /// since that is the volume a new item would land on.
    func volumeIdentifier(ofCanonicalPath canonicalPath: String) -> String? {
        var candidatePath = canonicalPath
        while true {
            var fileStatus = stat()
            if lstat(candidatePath, &fileStatus) == 0 { return String(fileStatus.st_dev) }
            if candidatePath == "/" || candidatePath.isEmpty { return nil }
            candidatePath = (candidatePath as NSString).deletingLastPathComponent
        }
    }

    func listFolder(atCanonicalPath canonicalPath: String, depth: Int, includesHiddenItems: Bool,
                    maximumEntryCount: Int, abortSignal: TaskAbortSignal) async throws -> FolderListing {
        try await listFolderOffMainActor(atCanonicalPath: canonicalPath, depth: depth, includesHiddenItems: includesHiddenItems,
                                         maximumEntryCount: maximumEntryCount, abortSignal: abortSignal)
    }

    /// Listing a large folder (or one on a slow volume) blocks, and the planner calls from the main actor, so the work
    /// runs on the concurrent pool.
    @concurrent
    private func listFolderOffMainActor(atCanonicalPath canonicalPath: String, depth: Int, includesHiddenItems: Bool,
                                        maximumEntryCount: Int, abortSignal: TaskAbortSignal) async throws -> FolderListing {
        var listedEntries: [FolderListingEntry] = []
        var omittedEntryCount = 0
        try appendEntries(ofFolderAtCanonicalPath: canonicalPath, currentDepth: 1, maximumDepth: max(1, depth),
                          includesHiddenItems: includesHiddenItems, maximumEntryCount: maximumEntryCount,
                          abortSignal: abortSignal, listedEntries: &listedEntries, omittedEntryCount: &omittedEntryCount)
        return FolderListing(folderPath: canonicalPath, entries: listedEntries, omittedEntryCount: omittedEntryCount)
    }

    private func appendEntries(ofFolderAtCanonicalPath folderPath: String, currentDepth: Int, maximumDepth: Int,
                               includesHiddenItems: Bool, maximumEntryCount: Int, abortSignal: TaskAbortSignal,
                               listedEntries: inout [FolderListingEntry], omittedEntryCount: inout Int) throws {
        let entryNames: [String]
        do {
            entryNames = try FileManager.default.contentsOfDirectory(atPath: folderPath)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw Self.mutationError(forFoundationError: error)
        }
        for entryName in entryNames {
            try abortSignal.throwIfAborted()
            let entryPath = (folderPath as NSString).appendingPathComponent(entryName)
            guard let entryKind = existingItemKind(atCanonicalPath: entryPath) else { continue }
            let entryIsHidden = entryName.hasPrefix(".") || Self.hasHiddenFlag(atPath: entryPath)
            if entryIsHidden && !includesHiddenItems { continue }
            guard listedEntries.count < maximumEntryCount else {
                omittedEntryCount += 1
                continue
            }
            listedEntries.append(FolderListingEntry(path: entryPath, kind: entryKind, isHidden: entryIsHidden, depth: currentDepth))
            // Packages are listed as one item and symbolic links are never followed.
            if entryKind == .folder && currentDepth < maximumDepth {
                try appendEntries(ofFolderAtCanonicalPath: entryPath, currentDepth: currentDepth + 1, maximumDepth: maximumDepth,
                                  includesHiddenItems: includesHiddenItems, maximumEntryCount: maximumEntryCount,
                                  abortSignal: abortSignal, listedEntries: &listedEntries, omittedEntryCount: &omittedEntryCount)
            }
        }
    }

    func readMetadata(ofCanonicalPaths canonicalPaths: [String], abortSignal: TaskAbortSignal) async throws -> [FileMetadataRecord] {
        try await readMetadataOffMainActor(ofCanonicalPaths: canonicalPaths, abortSignal: abortSignal)
    }

    @concurrent
    private func readMetadataOffMainActor(ofCanonicalPaths canonicalPaths: [String], abortSignal: TaskAbortSignal) async throws -> [FileMetadataRecord] {
        var metadataRecords: [FileMetadataRecord] = []
        for canonicalPath in canonicalPaths {
            try abortSignal.throwIfAborted()
            guard let metadataRecord = metadataRecord(atCanonicalPath: canonicalPath) else { continue }
            metadataRecords.append(metadataRecord)
        }
        return metadataRecords
    }

    private func metadataRecord(atCanonicalPath canonicalPath: String) -> FileMetadataRecord? {
        guard let itemKind = existingItemKind(atCanonicalPath: canonicalPath) else { return nil }
        var fileStatus = stat()
        guard lstat(canonicalPath, &fileStatus) == 0 else { return nil }
        let itemURL = URL(fileURLWithPath: canonicalPath, isDirectory: itemKind == .folder || itemKind == .package)
        let resourceValues = try? itemURL.resourceValues(forKeys: [
            .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey,
            .contentTypeKey, .tagNamesKey,
        ])
        // Asked separately: on a file outside iCloud Drive, requesting the ubiquity keys together with the others
        // leaves tagNames empty (seen on macOS 27).
        let ubiquityValues = try? itemURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])

        let isDatalessFile = (fileStatus.st_flags & Self.datalessFileFlag) != 0
        // `.downloaded` (a local copy that isn't the newest version) is local too; only `.notDownloaded` isn't.
        let isUbiquitousButNotDownloaded = ubiquityValues?.isUbiquitousItem == true
            && ubiquityValues?.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.notDownloaded
        let contentIsNotLocal = isDatalessFile || isUbiquitousButNotDownloaded

        let contentType = resourceValues?.contentType
        var conformingTypeIdentifiers: [String] = []
        if let contentType {
            conformingTypeIdentifiers = [contentType.identifier] + contentType.supertypes.map(\.identifier).sorted()
        }

        var imageProperties = ImageHeaderProperties()
        if itemKind == .regularFile, !contentIsNotLocal, contentType?.conforms(to: .image) == true {
            imageProperties = Self.imageHeaderProperties(ofImageAt: itemURL)
        }

        return FileMetadataRecord(
            path: canonicalPath,
            kind: itemKind,
            isHidden: (canonicalPath as NSString).lastPathComponent.hasPrefix(".") || resourceValues?.isHidden == true,
            sizeInBytes: itemKind == .regularFile ? Int64(fileStatus.st_size) : resourceValues?.fileSize.map(Int64.init),
            createdAt: resourceValues?.creationDate,
            modifiedAt: resourceValues?.contentModificationDate,
            addedToFolderAt: resourceValues?.addedToDirectoryDate,
            contentTypeIdentifier: contentType?.identifier,
            conformingTypeIdentifiers: conformingTypeIdentifiers,
            imageCaptureDate: imageProperties.captureDate,
            imagePixelWidth: imageProperties.pixelWidth,
            imagePixelHeight: imageProperties.pixelHeight,
            finderTags: resourceValues?.tagNames ?? [],
            contentIsNotLocal: contentIsNotLocal,
            volumeIdentifier: String(fileStatus.st_dev))
    }

    private struct ImageHeaderProperties {
        var captureDate: Date?
        var pixelWidth: Int?
        var pixelHeight: Int?
    }

    /// Reads only the image's header properties; kCGImageSourceShouldCache false keeps ImageIO from decoding pixels.
    private static func imageHeaderProperties(ofImageAt imageURL: URL) -> ImageHeaderProperties {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions),
              CGImageSourceGetCount(imageSource) > 0,
              let imagePropertyDictionary = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, sourceOptions) as? [CFString: Any] else {
            return ImageHeaderProperties()
        }
        var headerProperties = ImageHeaderProperties()
        headerProperties.pixelWidth = (imagePropertyDictionary[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        headerProperties.pixelHeight = (imagePropertyDictionary[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        if let exifDictionary = imagePropertyDictionary[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let originalDateText = exifDictionary[kCGImagePropertyExifDateTimeOriginal] as? String {
            headerProperties.captureDate = exifCaptureDate(
                dateTimeText: originalDateText, offsetText: exifDictionary[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }
        return headerProperties
    }

    /// EXIF writes "2026:09:03 14:02:11" with no zone; OffsetTimeOriginal ("-03:00"), when present, gives it.
    /// Otherwise the camera's clock is taken to be in the current time zone.
    static func exifCaptureDate(dateTimeText: String, offsetText: String?) -> Date? {
        let exifDateFormatter = DateFormatter()
        exifDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        exifDateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDateFormatter.timeZone = offsetText.flatMap(timeZone(fromEXIFOffsetText:)) ?? TimeZone.current
        return exifDateFormatter.date(from: dateTimeText.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)))
    }

    private static func timeZone(fromEXIFOffsetText offsetText: String) -> TimeZone? {
        let trimmedOffsetText = offsetText.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard trimmedOffsetText.count == 6, let signCharacter = trimmedOffsetText.first, signCharacter == "+" || signCharacter == "-" else {
            return nil
        }
        let offsetParts = trimmedOffsetText.dropFirst().split(separator: ":")
        guard offsetParts.count == 2, let offsetHours = Int(offsetParts[0]), let offsetMinutes = Int(offsetParts[1]) else { return nil }
        let offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (signCharacter == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: offsetSeconds)
    }

    /// realpath: every symlink in the path resolved; nil when the path doesn't exist.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolvedPathPointer = realpath(path, nil) else { return nil }
        defer { free(resolvedPathPointer) }
        return String(cString: resolvedPathPointer)
    }

    private static func hasHiddenFlag(atPath path: String) -> Bool {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0 else { return false }
        return (fileStatus.st_flags & UInt32(UF_HIDDEN)) != 0
    }
}
