import UIKit

final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let globe = UIButton(type: .system)
        globe.setTitle("🌐", for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(globe)
        NSLayoutConstraint.activate([
            globe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            globe.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }
}
