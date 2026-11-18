import CoreLocation
import MapKit

/// 反查地名，用座標快取（地圖反查有次數限制）
@MainActor
final class PlaceLookup {
    static let shared = PlaceLookup()

    struct Place: Equatable {
        /// 卡片上的短地名，例如「彰化縣南瑤里」
        var short: String
        var full: String?
        var district: String?
    }

    private var cache: [String: Place] = [:]

    func place(for location: CLLocation) async -> Place? {
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        if let hit = cache[key] { return hit }
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        let full = item.address?.fullAddress
        let short = full.flatMap(PlaceFormatter.short(fromFull:))
            ?? item.address?.shortAddress
            ?? item.name
        guard let short, !short.isEmpty else { return nil }
        let place = Place(short: short, full: full, district: full.flatMap(PlaceFormatter.district(fromFull:)))
        cache[key] = place
        return place
    }
}
