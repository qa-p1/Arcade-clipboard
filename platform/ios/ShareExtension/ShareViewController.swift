import UIKit
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var completed = false
    private let shareQueue = DispatchQueue(label: "dev.arcade.clipboard.share", qos: .userInitiated)
    private var activeLoadID: UUID?
    private let maximumPayloadBytes = 16 * 1024 * 1024

    private struct LoadedShare {
        let text: String
        let representations: [MobileSharedStore.Representation]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        loadSharedContent()
    }

    private func buildView() {
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, detailLabel, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "Add to your mesh"
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        closeButton.setTitle("Close", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])
        spinner.startAnimating()
        detailLabel.text = "Saving this share…"
    }

    private func loadSharedContent() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            showError("This share has no content.")
            return
        }
        guard providers.count <= 32 else {
            showError("Share up to 32 items at a time.")
            return
        }
        shareQueue.async { [weak self] in
            self?.loadNext(providers: providers, index: 0, text: "", representations: [])
        }
    }

    private func loadNext(providers: [NSItemProvider], index: Int, text: String,
                          representations: [MobileSharedStore.Representation]) {
        guard index < providers.count else {
            activeLoadID = nil
            do {
                let source = UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
                _ = try MobileSharedStore().enqueue(representations: representations, text: text, sourceName: source)
                DispatchQueue.main.async { [weak self] in self?.showQueued() }
            } catch { showError(error.localizedDescription) }
            return
        }
        let token = UUID()
        activeLoadID = token
        shareQueue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.activeLoadID == token else { return }
            self.activeLoadID = nil
            self.showError("The shared item took too long to load. Try sharing it again.")
        }
        loadProvider(providers[index], groupFiles: providers.count > 1) { [weak self] outcome in
            guard let self else { return }
            self.shareQueue.async {
                guard self.activeLoadID == token else { return }
                self.activeLoadID = nil
                do {
                    let piece = try outcome.get()
                    let nextText = [text, piece.text].filter { !$0.isEmpty }.joined(separator: "\n")
                    guard nextText.utf8.count <= 32 * 1024 else {
                        throw MobileSharedStore.StoreError.invalid("This text exceeds 32 KB.")
                    }
                    let nextFormats = representations + piece.representations
                    let nextBytes = nextText.utf8.count + nextFormats.reduce(0) {
                        $0 + (Data(base64Encoded: $1.data_base64)?.count ?? self.maximumPayloadBytes + 1)
                    }
                    guard nextBytes <= self.maximumPayloadBytes else {
                        throw MobileSharedStore.StoreError.invalid("This share exceeds 16 MB.")
                    }
                    self.loadNext(providers: providers, index: index + 1, text: nextText,
                                  representations: nextFormats)
                } catch { self.showError(error.localizedDescription) }
            }
        }
    }

    private func loadProvider(_ provider: NSItemProvider, groupFiles: Bool,
                              completion: @escaping (Result<LoadedShare, Error>) -> Void) {
        // File URLs are read only within the provider callback, while their
        // temporary or security-scoped access is still valid.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, error in
                guard let self else { return }
                completion(Result {
                    if let error { throw error }
                    guard let url = value as? URL else {
                        throw MobileSharedStore.StoreError.invalid("The shared file is no longer available.")
                    }
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try self.boundedFileData(url)
                    let name = self.safeFilename(url.lastPathComponent, fallback: "shared-file")
                    let mime = self.fileMimeType(url, bytes: bytes)
                    return LoadedShare(text: "", representations: [self.representation(bytes, mime: mime, name: name)])
                })
            }
            return
        }
        if let imageType = [UTType.png.identifier, UTType.jpeg.identifier].first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) ?? provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            provider.loadFileRepresentation(forTypeIdentifier: imageType) { [weak self] url, error in
                guard let self else { return }
                completion(Result {
                    if let error { throw error }
                    guard let url else { throw MobileSharedStore.StoreError.invalid("The shared image could not be loaded.") }
                    var bytes = try self.boundedFileData(url)
                    var mime = imageType == UTType.jpeg.identifier ? "image/jpeg" : "image/png"
                    if imageType != UTType.png.identifier && imageType != UTType.jpeg.identifier {
                        // HEIC and other camera formats become JPEG: a 12–48 MP
                        // photo as PNG would exceed the 16 MB clip limit.
                        bytes = try self.convertImageToJPEG(bytes)
                        mime = "image/jpeg"
                    }
                    var name = groupFiles ? self.safeFilename(provider.suggestedName ?? url.lastPathComponent, fallback: "image.jpg") : nil
                    if let originalName = name, imageType != UTType.png.identifier && imageType != UTType.jpeg.identifier {
                        var stem = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
                        while stem.utf8.count > 251 { stem.removeLast() }
                        name = self.safeFilename(stem + ".jpg", fallback: "image.jpg")
                    }
                    return LoadedShare(text: "", representations: [self.representation(bytes, mime: mime, name: name)])
                })
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadObject(ofClass: NSURL.self) { value, error in
                completion(Result {
                    if let error { throw error }
                    guard let url = value as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw MobileSharedStore.StoreError.invalid("This share has an unsupported link.")
                    }
                    return LoadedShare(text: url.absoluteString, representations: [])
                })
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadObject(ofClass: NSString.self) { [weak self] value, error in
                guard let self else { return }
                if let error { completion(.failure(error)); return }
                guard let text = value as? String, text.utf8.count <= 32 * 1024 else {
                    completion(.failure(MobileSharedStore.StoreError.invalid("The shared text is missing or exceeds 32 KB.")))
                    return
                }
                self.loadRichRepresentation(provider, text: text, completion: completion)
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
            loadRichRepresentation(provider, text: "", completion: completion)
            return
        }
        if let fileType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
            provider.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] url, error in
                guard let self else { return }
                completion(Result {
                    if let error { throw error }
                    guard let url else { throw MobileSharedStore.StoreError.invalid("The shared file could not be loaded.") }
                    let bytes = try self.boundedFileData(url)
                    let name = self.safeFilename(provider.suggestedName ?? url.lastPathComponent, fallback: "shared-file")
                    return LoadedShare(text: "", representations: [self.representation(bytes, mime: self.fileMimeType(url, bytes: bytes), name: name)])
                })
            }
            return
        }
        completion(.failure(MobileSharedStore.StoreError.invalid("This content type cannot be shared yet.")))
    }

    private func loadRichRepresentation(_ provider: NSItemProvider, text: String,
                                        completion: @escaping (Result<LoadedShare, Error>) -> Void) {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) ? UTType.html : UTType.rtf
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
            completion(.success(LoadedShare(text: text, representations: [])))
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, error in
            guard let self else { return }
            // Plain text remains usable when an optional rich format fails.
            guard error == nil, let data, data.count <= self.maximumPayloadBytes,
                  String(data: data, encoding: .utf8) != nil else {
                if !text.isEmpty { completion(.success(LoadedShare(text: text, representations: []))) }
                else { completion(.failure(MobileSharedStore.StoreError.invalid("The shared rich text could not be loaded."))) }
                return
            }
            completion(.success(LoadedShare(text: text, representations: [self.representation(data, mime: type == .html ? "text/html" : "text/rtf", name: nil)])))
        }
    }

    private func boundedFileData(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw MobileSharedStore.StoreError.invalid("The shared file is not local.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumPayloadBytes else {
            throw MobileSharedStore.StoreError.invalid("Share a file of 16 MB or less.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maximumPayloadBytes - bytes.count else {
                throw MobileSharedStore.StoreError.invalid("This share exceeds 16 MB.")
            }
            bytes.append(chunk)
        }
        return bytes
    }

    private func convertImageToJPEG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw MobileSharedStore.StoreError.invalid("The image could not be read.")
        }
        // Decode straight to a bounded size so large photos stay within the
        // share extension's memory limit; orientation is applied here.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 4096)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MobileSharedStore.StoreError.invalid("The image could not be converted.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MobileSharedStore.StoreError.invalid("The image could not be converted.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumPayloadBytes else {
            throw MobileSharedStore.StoreError.invalid("The converted image exceeds 16 MB.")
        }
        return output as Data
    }

    private func representation(_ bytes: Data, mime: String, name: String?) -> MobileSharedStore.Representation {
        MobileSharedStore.Representation(mime_type: mime, data_base64: bytes.base64EncodedString(), name: name)
    }

    private func safeFilename(_ proposed: String, fallback: String) -> String {
        var name = URL(fileURLWithPath: proposed).lastPathComponent
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        while name.utf8.count > 255 { name.removeLast() }
        return name.isEmpty || name == "." || name == ".." ? fallback : name
    }

    private func fileMimeType(_ url: URL, bytes: Data) -> String {
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if type.hasPrefix("text/"), String(data: bytes, encoding: .utf8) == nil { return "application/octet-stream" }
        return type
    }

    private func showQueued() {
        completed = true
        spinner.stopAnimating()
        titleLabel.text = "Saved on this device"
        detailLabel.text = "Open Arcade Clipboard to finish syncing this share."
        closeButton.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.finishIfQueued()
        }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.titleLabel.text = "Couldn’t add this share"
            self.detailLabel.text = message
            self.closeButton.isHidden = false
        }
    }

    private func finishIfQueued() {
        guard completed else { return }
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func close() {
        if completed {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
