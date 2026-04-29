//
//  SceneType.swift
//  Display labels + system icons for the 8 scene types defined in
//  ar_capture_to_splat/scripts/session_layer/scene_types.py.
//

import Foundation

enum SceneType: String, CaseIterable, Identifiable {
    case room
    case object
    case small_object_turntable
    case corridor
    case storefront
    case outdoor_facade
    case vehicle
    case large_indoor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .room:                   return "Room"
        case .object:                 return "Object"
        case .small_object_turntable: return "Small object"
        case .corridor:               return "Corridor"
        case .storefront:             return "Storefront"
        case .outdoor_facade:         return "Façade"
        case .vehicle:                return "Vehicle"
        case .large_indoor:           return "Large interior"
        }
    }

    var systemImage: String {
        switch self {
        case .room:                   return "house.fill"
        case .object:                 return "cube.fill"
        case .small_object_turntable: return "circle.hexagonpath.fill"
        case .corridor:               return "rectangle.portrait.fill"
        case .storefront:             return "storefront.fill"
        case .outdoor_facade:         return "building.2.fill"
        case .vehicle:                return "car.fill"
        case .large_indoor:           return "building.columns.fill"
        }
    }
}
