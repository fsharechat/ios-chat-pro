import UIKit
import MapKit

final class LocationPreviewViewController: UIViewController {
    private let lat: Double
    private let lng: Double
    private let poiTitle: String
    private let mapView = MKMapView()

    init(lat: Double, lng: Double, title: String) {
        self.lat = lat
        self.lng = lng
        self.poiTitle = title
        super.init(nibName: nil, bundle: nil)
        self.title = title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: false)

        let annotation = MKPointAnnotation()
        annotation.coordinate = coord
        annotation.title = poiTitle
        mapView.addAnnotation(annotation)
        mapView.selectAnnotation(annotation, animated: false)
    }
}
