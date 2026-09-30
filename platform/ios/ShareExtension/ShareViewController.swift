import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        loadSharedText()
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
        detailLabel.text = "Saving this share on your iPhone…"
    }

    private func loadSharedText() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadObject(ofClass: NSURL.self) { [weak self] object, error in
                let text = (object as? URL)?.absoluteString ?? (object as? NSURL)?.absoluteString
                self?.save(text: text, error: error)
            }
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                let text = (object as? String) ?? (object as? NSString).map(String.init(_:))
                if let text {
                    self?.save(text: text, error: error)
                } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
                    provider.loadObject(ofClass: NSAttributedString.self) { [weak self] richText, richError in
                        self?.save(text: richText?.string, error: richError ?? error)
                    }
                } else {
                    self?.save(text: nil, error: error)
                }
            }
            return
        }
        showError("This share doesn’t contain supported text yet.")
    }

    private func save(text: String?, error: Error?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result {
                guard error == nil else { throw error! }
                guard let text else {
                    throw MobileSharedStore.StoreError.invalid("This share doesn’t contain supported text yet.")
                }
                _ = try MobileSharedStore().enqueue(text: text)
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    self.showQueued()
                case .failure(let failure):
                    self.showError((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            }
        }
    }

    private func showQueued() {
        completed = true
        spinner.stopAnimating()
        titleLabel.text = "Saved on this iPhone"
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
