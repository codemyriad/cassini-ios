import UIKit

/// Opens Cassini's page in the Settings app.
@MainActor func openSystemSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}
