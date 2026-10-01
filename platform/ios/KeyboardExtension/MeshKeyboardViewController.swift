import UIKit

final class MeshKeyboardViewController: UIInputViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    private let titleLabel = UILabel()
    private let searchField = UITextField()
    private let switchButton = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchKeys = UIStackView()
    private let modeControl = UISegmentedControl(items: ["Recent", "Pinned"])
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

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Only reliable once the keyboard is in a window: devices with a
        // system globe key below the keyboard must not show a second one.
        switchButton.isHidden = !needsInputModeSwitchKey
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
        searchField.inputView = UIView() // Search is edited by our own keys.

        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(searchChanged), for: .valueChanged)
        searchKeys.axis = .vertical
        searchKeys.spacing = 5
        searchKeys.isHidden = true
        for letters in [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")] {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 3
            row.distribution = .fillEqually
            for letter in letters { row.addArrangedSubview(searchKey(String(letter))) }
            row.heightAnchor.constraint(equalToConstant: 31).isActive = true
            searchKeys.addArrangedSubview(row)
        }
        let controls = UIStackView(arrangedSubviews: [searchKey("Space"), searchKey("⌫"), searchKey("Clear"), searchKey("Done")])
        controls.axis = .horizontal
        controls.spacing = 4
        controls.distribution = .fillEqually
        controls.heightAnchor.constraint(equalToConstant: 32).isActive = true
        searchKeys.addArrangedSubview(controls)

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

        let stack = UIStackView(arrangedSubviews: [header, searchField, modeControl, stateLabel, tableView, searchKeys])
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
            let store = try MobileSharedStore(readOnly: true)
            activeStore = store
            let snapshot = try store.readKeyboardHistory()
            items = snapshot.paused ? [] : snapshot.items
            filterItems()
            if snapshot.paused {
                showState("Mesh is paused.")
            } else if snapshot.needsRefresh {
                showState(hasFullAccess
                    ? "Open Arcade Clipboard to refresh shared clips."
                    : "Open Arcade Clipboard to refresh shared clips. If they still don’t appear, turn on Allow Full Access for this keyboard in Settings.")
            } else if items.isEmpty {
                showState("No shared clips yet.")
            }
        } catch {
            activeStore = nil
            items = []
            showState(unavailableMessage)
        }
    }

    private var unavailableMessage: String {
        hasFullAccess
            ? "Shared clips aren’t available. Open Arcade Clipboard and try again."
            : "Shared clips aren’t available. Turn on Allow Full Access for this keyboard in Settings › General › Keyboard › Keyboards, then try again."
    }

    @objc private func searchChanged() {
        filterItems()
    }

    private func filterItems() {
        let query = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filteredItems = items.filter { item in
            (modeControl.selectedSegmentIndex != 1 || item.pinned) &&
                (query.isEmpty || item.text.localizedCaseInsensitiveContains(query) ||
                item.sourceName.localizedCaseInsensitiveContains(query))
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

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        searchKeys.isHidden = false
        tableView.isHidden = true
        modeControl.isHidden = true
        stateLabel.isHidden = true
        return false // Keep the host field as the textDocumentProxy target.
    }

    private func searchKey(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 5
        button.accessibilityLabel = title == "⌫" ? "Delete search character" : title
        button.addTarget(self, action: #selector(searchKeyPressed(_:)), for: .touchUpInside)
        return button
    }

    @objc private func searchKeyPressed(_ button: UIButton) {
        let key = button.title(for: .normal) ?? ""
        var query = searchField.text ?? ""
        switch key {
        case "Done":
            searchKeys.isHidden = true
            tableView.isHidden = false
            modeControl.isHidden = false
        case "Clear": query = ""
        case "⌫": if !query.isEmpty { query.removeLast() }
        case "Space": if query.count < 100 { query += " " }
        default: if query.count < 100 { query += key }
        }
        searchField.text = query
        filterItems()
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
        cell.accessoryType = .none
        if item.pinned { content.secondaryText = "Pinned · " + subtitle(for: item); cell.contentConfiguration = content }
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
            showState(unavailableMessage)
        }
    }

    private let relativeFormatter = RelativeDateTimeFormatter()

    private func subtitle(for item: MobileSharedStore.KeyboardItem) -> String {
        let date = Date(timeIntervalSince1970: Double(item.createdAt) / 1000)
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return [item.sourceName, relative].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
