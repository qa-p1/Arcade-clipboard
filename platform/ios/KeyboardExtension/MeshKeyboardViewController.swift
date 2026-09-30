import UIKit

final class MeshKeyboardViewController: UIInputViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    private let titleLabel = UILabel()
    private let searchField = UITextField()
    private let switchButton = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var items: [MobileSharedStore.KeyboardItem] = []
    private var filteredItems: [MobileSharedStore.KeyboardItem] = []
    private var activeStore: MobileSharedStore?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        let height = view.heightAnchor.constraint(equalToConstant: 290)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshClips()
    }

    private func buildView() {
        view.backgroundColor = UIColor.secondarySystemBackground

        let header = UIStackView(arrangedSubviews: [titleLabel, switchButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "Mesh clipboard"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        switchButton.setTitle("🌐", for: .normal)
        switchButton.accessibilityLabel = "Switch keyboard"
        switchButton.titleLabel?.font = .systemFont(ofSize: 22)
        switchButton.addTarget(self, action: #selector(handleInputModeListAction(_:with:)), for: .allTouchEvents)
        switchButton.isHidden = !needsInputModeSwitchKey

        searchField.placeholder = "Search shared clips"
        searchField.borderStyle = .roundedRect
        searchField.backgroundColor = .systemBackground
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.accessibilityLabel = "Search shared clips"

        stateLabel.font = .preferredFont(forTextStyle: .footnote)
        stateLabel.textColor = .secondaryLabel
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.isHidden = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "clip")
        tableView.keyboardDismissMode = .onDrag

        let stack = UIStackView(arrangedSubviews: [header, searchField, stateLabel, tableView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 38),
            switchButton.widthAnchor.constraint(equalToConstant: 52),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            stateLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
    }

    private func refreshClips() {
        do {
            let store = try MobileSharedStore()
            activeStore = store
            let snapshot = try store.readKeyboardHistory()
            items = snapshot.paused ? [] : snapshot.items
            filterItems()
            if snapshot.paused {
                showState("Mesh is paused.")
            } else if items.isEmpty {
                showState("No shared clips yet.")
            }
        } catch {
            activeStore = nil
            items = []
            showState("Shared clips aren’t available. Open Arcade Clipboard and try again.")
        }
    }

    @objc private func searchChanged() {
        filterItems()
    }

    private func filterItems() {
        let query = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filteredItems = items.filter { item in
            query.isEmpty || item.text.localizedCaseInsensitiveContains(query) ||
                item.sourceName.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
        if filteredItems.isEmpty, !items.isEmpty {
            showState("No matching clips.")
        } else if !items.isEmpty {
            stateLabel.isHidden = true
        }
    }

    private func showState(_ message: String) {
        stateLabel.text = message
        stateLabel.isHidden = false
        tableView.reloadData()
    }

    @objc private func handleInputModeListAction(_ sender: UIButton, with event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        filterItems()
        return true
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
        let item = filteredItems[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.text.replacingOccurrences(of: "\n", with: " ")
        content.textProperties.numberOfLines = 2
        content.secondaryText = subtitle(for: item)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.color = .label
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessoryType = item.pinned ? .bookmark : .none
        cell.accessibilityLabel = "\(subtitle(for: item)), \(item.text.prefix(120)). Tap to insert."
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let store = activeStore else { return }
        do {
            let snapshot = try store.readKeyboardHistory()
            guard !snapshot.paused,
                  let latest = snapshot.items.first(where: { $0.id == filteredItems[indexPath.row].id }) else {
                refreshClips()
                return
            }
            // Never read before/after-cursor text or send typed input to the app. Insert only the selected clip.
            textDocumentProxy.insertText(latest.text)
        } catch {
            showState("Shared clips aren’t available. Open Arcade Clipboard and try again.")
        }
    }

    private func subtitle(for item: MobileSharedStore.KeyboardItem) -> String {
        let date = Date(timeIntervalSince1970: Double(item.createdAt) / 1000)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return [item.sourceName, relative].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
