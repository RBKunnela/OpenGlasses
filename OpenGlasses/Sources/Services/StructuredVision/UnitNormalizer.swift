import Foundation

/// Deterministic unit normalization for the "read the instrument" capability
/// (see docs/plans/structured-vision-assessment.md). Pure and headless — no model involvement —
/// so range checks, HUD, and audit records are unit-stable regardless of what the gauge displays.
///
/// Canonical units per dimension: temperature → °C, pressure → kPa, mass → kg, brix → °Bx,
/// voltage → V. Unrecognised units return `nil` (the caller keeps the displayed value).
enum UnitNormalizer {

    /// Converts `value` (in `unit`) to its canonical unit. Returns `nil` for unknown units.
    static func canonical(value: Double, unit: String) -> (value: Double, unit: String)? {
        guard let def = def(for: unit) else { return nil }
        return (def.toCanonical(value), canonicalUnit(for: def.dimension))
    }

    /// Converts `value` from one unit to another within the same dimension. Returns `nil` if either
    /// unit is unknown or they belong to different dimensions.
    static func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let src = def(for: from), let dst = def(for: to), src.dimension == dst.dimension else { return nil }
        return dst.fromCanonical(src.toCanonical(value))
    }

    /// The canonical display unit for a dimension.
    static func canonicalUnit(for dimension: Dimension) -> String {
        switch dimension {
        case .temperature: return "°C"
        case .pressure: return "kPa"
        case .mass: return "kg"
        case .brix: return "°Bx"
        case .voltage: return "V"
        }
    }

    enum Dimension { case temperature, pressure, mass, brix, voltage }

    // MARK: - Unit table

    private struct UnitDef {
        let dimension: Dimension
        let toCanonical: (Double) -> Double
        let fromCanonical: (Double) -> Double
    }

    private static func def(for unit: String) -> UnitDef? { table[token(unit)] }

    /// Normalize a free-form unit string to a lookup token: lowercase, trim, drop the degree sign
    /// and a trailing period, then fold common synonyms.
    private static func token(_ unit: String) -> String {
        var t = unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "°", with: "")
        if t.hasSuffix(".") { t.removeLast() }
        switch t {
        case "f", "fahrenheit", "degf", "deg f": return "degf"
        case "c", "celsius", "centigrade", "degc", "deg c": return "degc"
        case "psi", "psig", "psia", "pounds per square inch": return "psi"
        case "kpa", "kilopascal", "kilopascals": return "kpa"
        case "bar", "bars": return "bar"
        case "inhg", "in hg", "inches of mercury", "inhg.": return "inhg"
        case "lb", "lbs", "pound", "pounds": return "lb"
        case "kg", "kilogram", "kilograms", "kgs": return "kg"
        case "g", "gram", "grams": return "g"
        case "oz", "ounce", "ounces": return "oz"
        case "bx", "brix", "°bx": return "bx"
        case "v", "volt", "volts": return "v"
        default: return t
        }
    }

    private static let table: [String: UnitDef] = [
        // Temperature (canonical °C) — affine.
        "degf": UnitDef(dimension: .temperature, toCanonical: { ($0 - 32) * 5 / 9 }, fromCanonical: { $0 * 9 / 5 + 32 }),
        "degc": UnitDef(dimension: .temperature, toCanonical: { $0 }, fromCanonical: { $0 }),
        // Pressure (canonical kPa). psig is treated as a magnitude in psi for canonicalisation.
        "psi":  UnitDef(dimension: .pressure, toCanonical: { $0 * 6.894757 }, fromCanonical: { $0 / 6.894757 }),
        "kpa":  UnitDef(dimension: .pressure, toCanonical: { $0 }, fromCanonical: { $0 }),
        "bar":  UnitDef(dimension: .pressure, toCanonical: { $0 * 100 }, fromCanonical: { $0 / 100 }),
        "inhg": UnitDef(dimension: .pressure, toCanonical: { $0 * 3.386389 }, fromCanonical: { $0 / 3.386389 }),
        // Mass (canonical kg).
        "lb":   UnitDef(dimension: .mass, toCanonical: { $0 * 0.45359237 }, fromCanonical: { $0 / 0.45359237 }),
        "kg":   UnitDef(dimension: .mass, toCanonical: { $0 }, fromCanonical: { $0 }),
        "g":    UnitDef(dimension: .mass, toCanonical: { $0 / 1000 }, fromCanonical: { $0 * 1000 }),
        "oz":   UnitDef(dimension: .mass, toCanonical: { $0 * 0.0283495231 }, fromCanonical: { $0 / 0.0283495231 }),
        // Dimensionless-ish (identity, canonical = itself).
        "bx":   UnitDef(dimension: .brix, toCanonical: { $0 }, fromCanonical: { $0 }),
        "v":    UnitDef(dimension: .voltage, toCanonical: { $0 }, fromCanonical: { $0 }),
    ]
}
