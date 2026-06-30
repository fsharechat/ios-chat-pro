import UIKit
import MapKit
import CoreLocation

final class LocationPickerViewController: UIViewController {
    var onPicked: ((_ lat: Double, _ lng: Double, _ title: String, _ thumbnail: Data) -> Void)?

    private let mapView = MKMapView()
    private let pinImageView = UIImageView(image: UIImage(systemName: "mappin"))
    private let infoView = UIView()
    private let titleLabel = UILabel()
    private let coordLabel = UILabel()
    private let sendButton = UIBarButtonItem()
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var isGeocoding = false
    private var pendingGeocode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "发送位置"
        view.backgroundColor = Theme.backgroundPrimary
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(cancelTapped)
        )
        sendButton.title = "发送"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.isEnabled = false
        navigationItem.rightBarButtonItem = sendButton

        layoutViews()
        setupLocationManager()
    }

    private func layoutViews() {
        mapView.delegate = self
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        // Fixed center pin (not an annotation — stays centered as map moves)
        pinImageView.tintColor = .systemRed
        pinImageView.contentMode = .scaleAspectFit
        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pinImageView)

        infoView.backgroundColor = Theme.backgroundSecondary
        infoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.text = "定位中…"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        coordLabel.font = .systemFont(ofSize: 12)
        coordLabel.textColor = .secondaryLabel
        coordLabel.translatesAutoresizingMaskIntoConstraints = false

        infoView.addSubview(titleLabel)
        infoView.addSubview(coordLabel)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: infoView.topAnchor),

            pinImageView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor, constant: -12),
            pinImageView.widthAnchor.constraint(equalToConstant: 28),
            pinImageView.heightAnchor.constraint(equalToConstant: 36),

            infoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            infoView.heightAnchor.constraint(equalToConstant: 80),

            titleLabel.leadingAnchor.constraint(equalTo: infoView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: infoView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: infoView.topAnchor, constant: 14),

            coordLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            coordLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            coordLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }

    private func reverseGeocodeCenter() {
        guard !isGeocoding else { pendingGeocode = true; return }
        isGeocoding = true
        pendingGeocode = false
        let center = mapView.centerCoordinate
        let loc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let self else { return }
            self.isGeocoding = false
            let poi = placemarks?.first.flatMap { p in
                [p.name, p.thoroughfare, p.locality].compactMap { $0 }.first
            } ?? "未知位置"
            self.titleLabel.text = poi
            self.coordLabel.text = String(format: "%.5f, %.5f", center.latitude, center.longitude)
            self.sendButton.isEnabled = true
            if self.pendingGeocode { self.reverseGeocodeCenter() }
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        sendButton.isEnabled = false
        let center = mapView.centerCoordinate
        let title = titleLabel.text ?? "位置"
        let region = mapView.region
        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = CGSize(width: 200, height: 120)
        opts.scale = 2
        MKMapSnapshotter(options: opts).start { [weak self] snapshot, _ in
            let image = snapshot?.image ?? UIImage()
            guard let jpeg = image.jpegData(compressionQuality: 0.75), !jpeg.isEmpty else {
                DispatchQueue.main.async { self?.sendButton.isEnabled = true }
                return
            }
            DispatchQueue.main.async {
                self?.onPicked?(center.latitude, center.longitude, title, jpeg)
                self?.dismiss(animated: true)
            }
        }
    }
}

extension LocationPickerViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        let coord = loc.coordinate
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: true)
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            titleLabel.text = "定位权限被拒绝，请在设置中开启"
            sendButton.isEnabled = false
        default:
            break
        }
    }
}

extension LocationPickerViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        reverseGeocodeCenter()
    }
}
