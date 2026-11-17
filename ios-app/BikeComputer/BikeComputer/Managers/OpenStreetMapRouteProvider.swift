import Foundation

/// Calculates cycling directions from OpenStreetMap data through Valhalla.
@MainActor
final class OpenStreetMapRouteProvider: NavigationRouteProvider {
    let metadata = RouteProviderPolicyV1.openStreetMap

    private let endpoint: URL
    private let session: URLSession
    private let clock = ContinuousClock()
    private var nextRequestTime: ContinuousClock.Instant?
    private var activeRequest: Task<[NavigationRouteV1], Error>?

    init(
        endpoint: URL = URL(string: "https://valhalla1.openstreetmap.de/route")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func routes(for request: NavigationRouteRequestV1) async throws -> [NavigationRouteV1] {
        try Task.checkCancellation()
        cancel()
        let task = Task {
            if let nextRequestTime {
                try await clock.sleep(until: nextRequestTime)
            }
            try Task.checkCancellation()
            nextRequestTime = clock.now.advanced(by: .seconds(1))
            let (data, response) = try await session.data(for: makeRequest(request))
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                guard let route = try? Self.decodeRoute(data, request: request) else {
                    throw RoutingError.invalidRoute
                }
                return [route]
            case 400: throw RoutingError.noRoute
            case 429: throw RoutingError.busy
            default: throw RoutingError.unavailable
            }
        }
        activeRequest = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        activeRequest?.cancel()
        activeRequest = nil
    }

    private func makeRequest(_ route: NavigationRouteRequestV1) throws -> URLRequest {
        struct Location: Encodable {
            let lat: Double
            let lon: Double

            init(_ endpoint: RouteEndpointV1) {
                lat = endpoint.coordinate.latitude
                lon = endpoint.coordinate.longitude
            }
        }
        struct Body: Encodable {
            let locations: [Location]
            let costing = "bicycle"
            let units = "kilometers"
            let language: String
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("open-bike-computer-osm-fork", forHTTPHeaderField: "X-Client-Id")
        request.setValue(
            "OpenBikeComputer-OSM (https://github.com/meirkeller/open-bike-computer)",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONEncoder().encode(Body(
            locations: [Location(route.source), Location(route.destination)],
            language: route.localeIdentifier.replacingOccurrences(of: "_", with: "-")
        ))
        return request
    }

    static func decodeRoute(_ data: Data, request: NavigationRouteRequestV1) throws -> NavigationRouteV1 {
        let trip = try JSONDecoder().decode(Response.self, from: data).trip
        guard trip.status == 0, trip.units == "kilometers", trip.legs.count == 1,
              let leg = trip.legs.first,
              leg.maneuvers.count <= NavigationRouteLimitsV1.production.maximumSteps else {
            throw RoutingError.invalidRoute
        }

        let points = try decodeShape(leg.shape)
        guard let start = points.first, let end = points.last,
              let bounds = RouteBoundsV1.enclosing(points) else {
            throw RoutingError.invalidRoute
        }

        let steps = leg.maneuvers.enumerated().map { index, maneuver in
            NavigationRouteStepV1(
                id: UInt32(index + 1),
                geometryStartIndex: maneuver.begin_shape_index,
                geometryEndIndex: maneuver.end_shape_index,
                instruction: maneuver.instruction,
                maneuver: maneuver.kind,
                distanceMeters: maneuver.length * 1_000
            )
        }

        let route = NavigationRouteV1(
            id: UUID(), revision: 1, provider: RouteProviderPolicyV1.openStreetMap,
            localeIdentifier: trip.language ?? "en-US", transportType: request.transportType,
            source: RouteEndpointV1(coordinate: start, label: request.source.label),
            destination: RouteEndpointV1(coordinate: end, label: request.destination.label),
            bounds: bounds, distanceMeters: trip.summary.length * 1_000,
            expectedTravelTimeSeconds: trip.summary.time,
            name: nil, points: points, steps: steps, normalizationVersion: 1
        )
        try route.validate()
        return route
    }

    /// Valhalla encodes latitude and longitude deltas at six decimal places.
    private static func decodeShape(_ shape: String) throws -> [RouteCoordinateV1] {
        var bytes = shape.utf8.makeIterator()
        func readDelta(startingWith firstByte: UInt8) throws -> Int64 {
            var byte = firstByte
            var value: Int64 = 0
            for shift in stride(from: 0, through: 30, by: 5) {
                guard (63...126).contains(byte) else { throw RoutingError.invalidRoute }
                let chunk = Int64(byte - 63)
                value |= (chunk & 31) << shift
                if chunk < 32 {
                    return value & 1 == 0 ? value >> 1 : ~(value >> 1)
                }
                guard let next = bytes.next() else { throw RoutingError.invalidRoute }
                byte = next
            }
            throw RoutingError.invalidRoute
        }

        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var points: [RouteCoordinateV1] = []
        while let firstByte = bytes.next() {
            latitude += try readDelta(startingWith: firstByte)
            guard let longitudeByte = bytes.next() else { throw RoutingError.invalidRoute }
            longitude += try readDelta(startingWith: longitudeByte)
            let point = RouteCoordinateV1(
                latitude: Double(latitude) / 1_000_000,
                longitude: Double(longitude) / 1_000_000
            )
            guard point.isValid, points.count < NavigationRouteLimitsV1.production.maximumPoints else {
                throw RoutingError.invalidRoute
            }
            points.append(point)
        }
        return points
    }

    private struct Response: Decodable {
        let trip: Trip

        struct Trip: Decodable {
            let status: Int
            let units: String
            let language: String?
            let summary: Summary
            let legs: [Leg]
        }

        struct Summary: Decodable {
            let length: Double
            let time: Double
        }

        struct Leg: Decodable {
            let shape: String
            let maneuvers: [Maneuver]
        }

        struct Maneuver: Decodable {
            let begin_shape_index: Int
            let end_shape_index: Int
            let instruction: String
            let length: Double
            let type: Int

            var kind: ManeuverV1 {
                switch type {
                case 4...6: .arrive
                case 9, 18, 23, 37: .slightRight
                case 10, 20: .right
                case 11: .sharpRight
                case 12...13: .uTurn
                case 14: .sharpLeft
                case 15, 21: .left
                case 16, 19, 24, 38: .slightLeft
                case 26...27: .roundabout
                default: .straight
                }
            }
        }
    }

    enum RoutingError: LocalizedError {
        case noRoute, busy, unavailable, invalidRoute

        var errorDescription: String? {
            switch self {
            case .noRoute: "No OpenStreetMap cycling route was found."
            case .busy: "OpenStreetMap cycling routing is busy. Wait a moment, then try again."
            case .unavailable: "OpenStreetMap cycling routing could not be reached."
            case .invalidRoute: "OpenStreetMap cycling routing returned an unusable route."
            }
        }
    }
}
