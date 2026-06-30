import UIKit
import MapKit
import CoreLocation

// File-scope so both LocationPickerViewController and POICell can reference it.
private struct POIItem {
    let coordinate: CLLocationCoordinate2D
    let name: String
    let address: String
}

final class LocationPickerViewController: UIViewController {
    var onPicked: ((_ lat: Double, _ lng: Double, _ title: String, _ thumbnail: Data) -> Void)?

    private let mapView = MKMapView()
    private let pinImageView: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "mappin"))
        iv.tintColor = .systemRed
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()
    private let locateButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        b.setImage(UIImage(systemName: "location.fill", withConfiguration: cfg), for: .normal)
        b.backgroundColor = .systemBackground
        b.tintColor = .systemBlue
        b.layer.cornerRadius = 22
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.18
        b.layer.shadowRadius = 4
        b.layer.shadowOffset = CGSize(width: 0, height: 2)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let sendButton = UIBarButtonItem()

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var isGeocoding = false
    private var pendingGeocode = false
    private var nearbySearch: MKLocalSearch?
    private var lastGPSCoordinate: CLLocationCoordinate2D?

    private var poiItems: [POIItem] = [] { didSet { tableView.reloadData() } }
    private var selectedIndex = 0 { didSet { tableView.reloadData() } }

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

        setupLayout()
        setupLocationManager()
    }

    private func setupLayout() {
        mapView.delegate = self
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)
        view.addSubview(pinImageView)

        locateButton.addTarget(self, action: #selector(locateTapped), for: .touchUpInside)
        view.addSubview(locateButton)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(POICell.self, forCellReuseIdentifier: POICell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 62
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 40, bottom: 0, right: 0)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.45),

            tableView.topAnchor.constraint(equalTo: mapView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            pinImageView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor, constant: -14),
            pinImageView.widthAnchor.constraint(equalToConstant: 28),
            pinImageView.heightAnchor.constraint(equalToConstant: 36),

            locateButton.trailingAnchor.constraint(equalTo: mapView.trailingAnchor, constant: -12),
            locateButton.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -12),
            locateButton.widthAnchor.constraint(equalToConstant: 44),
            locateButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }

    @objc private func locateTapped() {
        if let coord = lastGPSCoordinate {
            let region = MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
            mapView.setRegion(region, animated: true)
        } else {
            locationManager.startUpdatingLocation()
        }
    }

    private func reverseGeocodeCenter() {
        guard !isGeocoding else { pendingGeocode = true; return }
        isGeocoding = true
        pendingGeocode = false
        let center = mapView.centerCoordinate
        sendButton.isEnabled = false

        // Reset item 0 to a loading placeholder while keeping existing nearby rows.
        let placeholder = POIItem(coordinate: center, name: "定位中…", address: "")
        poiItems = [placeholder] + Array(poiItems.dropFirst())
        selectedIndex = 0

        geocoder.reverseGeocodeLocation(CLLocation(latitude: center.latitude, longitude: center.longitude)) { [weak self] placemarks, _ in
            guard let self else { return }
            self.isGeocoding = false
            let name = placemarks?.first.flatMap { p in
                [p.name, p.thoroughfare, p.locality].compactMap { $0 }.first
            } ?? "未知位置"
            let addrParts = [placemarks?.first?.thoroughfare, placemarks?.first?.subLocality, placemarks?.first?.locality].compactMap { $0 }
            let addr = addrParts.isEmpty ? String(format: "%.5f, %.5f", center.latitude, center.longitude) : addrParts.joined(separator: ", ")
            let item = POIItem(coordinate: center, name: name, address: addr)
            self.poiItems = [item] + Array(self.poiItems.dropFirst())
            self.sendButton.isEnabled = true
            if self.pendingGeocode { self.reverseGeocodeCenter() }
        }

        searchNearbyPOIs(center: center)
    }

    private func searchNearbyPOIs(center: CLLocationCoordinate2D) {
        nearbySearch?.cancel()
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 800, longitudinalMeters: 800)
        let req = MKLocalSearch.Request()
        req.region = region
        req.resultTypes = .pointOfInterest
        nearbySearch = MKLocalSearch(request: req)
        nearbySearch?.start { [weak self] response, _ in
            guard let self, let response else { return }
            let items = response.mapItems.prefix(8).compactMap { item -> POIItem? in
                guard let name = item.name, !name.isEmpty else { return nil }
                let parts = [item.placemark.thoroughfare, item.placemark.subLocality, item.placemark.locality]
                    .compactMap { $0 }
                let addr = parts.isEmpty ? (item.placemark.title ?? "") : parts.joined(separator: ", ")
                return POIItem(coordinate: item.placemark.coordinate, name: name, address: addr)
            }
            DispatchQueue.main.async {
                let centerItem = self.poiItems.first ?? POIItem(coordinate: center, name: "未知位置", address: "")
                self.poiItems = [centerItem] + items
            }
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        guard selectedIndex < poiItems.count else { return }
        sendButton.isEnabled = false
        let selected = poiItems[selectedIndex]
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(center: selected.coordinate, latitudinalMeters: 500, longitudinalMeters: 500)
        opts.size = CGSize(width: 200, height: 120)
        opts.scale = 2
        MKMapSnapshotter(options: opts).start { [weak self] snapshot, _ in
            let image = snapshot?.image ?? UIImage()
            guard let jpeg = image.jpegData(compressionQuality: 0.75), !jpeg.isEmpty else {
                DispatchQueue.main.async { self?.sendButton.isEnabled = true }
                return
            }
            DispatchQueue.main.async {
                self?.onPicked?(selected.coordinate.latitude, selected.coordinate.longitude, selected.name, jpeg)
                self?.dismiss(animated: true)
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationPickerViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        lastGPSCoordinate = loc.coordinate
        let region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: true)
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            poiItems = [POIItem(coordinate: mapView.centerCoordinate, name: "定位权限被拒绝，请在设置中开启", address: "")]
            sendButton.isEnabled = false
        default:
            break
        }
    }
}

// MARK: - MKMapViewDelegate
extension LocationPickerViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        reverseGeocodeCenter()
    }
}

// MARK: - UITableView
extension LocationPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        poiItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: POICell.reuseID, for: indexPath) as! POICell
        cell.configure(with: poiItems[indexPath.row], selected: indexPath.row == selectedIndex)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedIndex = indexPath.row
    }
}

// MARK: - POICell
private final class POICell: UITableViewCell {
    static let reuseID = "POICell"

    private let dotView = UIView()
    private let nameLabel = UILabel()
    private let addressLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        dotView.layer.cornerRadius = 6
        dotView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addressLabel.font = .systemFont(ofSize: 12)
        addressLabel.textColor = .secondaryLabel
        addressLabel.numberOfLines = 2
        addressLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(dotView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(addressLabel)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            dotView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 12),
            dotView.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            addressLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            addressLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            addressLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            addressLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: POIItem, selected: Bool) {
        nameLabel.text = item.name
        addressLabel.text = item.address
        addressLabel.isHidden = item.address.isEmpty
        if selected {
            dotView.backgroundColor = .systemBlue
            dotView.layer.borderWidth = 0
            nameLabel.textColor = .systemBlue
        } else {
            dotView.backgroundColor = .clear
            dotView.layer.borderColor = UIColor.systemGray3.cgColor
            dotView.layer.borderWidth = 1.5
            nameLabel.textColor = .label
        }
    }
}
