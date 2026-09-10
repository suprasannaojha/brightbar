import Foundation

/// Sunrise and sunset for a civil date, using the NOAA Solar Calculator.
///
/// Algorithm: NOAA Global Monitoring Laboratory solar equations
/// (same model as the NOAA Solar Calculator spreadsheet / `solcalc`).
/// - https://gml.noaa.gov/grad/solcalc/solareqns.PDF
/// - https://gml.noaa.gov/grad/solcalc/calcdetails.html
///
/// Times are returned as absolute `Date`s. `timeZone` is used only to pick
/// the year-month-day that `date` falls on. Longitude is **east-positive**
/// (NOAA convention). Returns `nil` for polar day/night, when the sunrise
/// hour-angle equation has no real solution (`|cos H| > 1`).
enum SunCalculator {
    /// Apparent zenith at rise/set: 90° + 0.833°.
    /// 0.833° ≈ 16′ solar radius + 50′ average atmospheric refraction.
    private static let zenithDegrees = 90.833

    static func sunTimes(
        for date: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone = .current
    ) -> (sunrise: Date, sunset: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }

        // Julian Day at 00:00 UTC of this civil Y-M-D (NOAA treats the local
        // calendar date as the date numbers fed into the JD formula).
        let jd = julianDay(year: year, month: month, day: Double(day))

        guard
            let sunriseFirst = sunriseSetUTC(rise: true, julianDay: jd, latitude: latitude, longitude: longitude),
            let sunsetFirst = sunriseSetUTC(rise: false, julianDay: jd, latitude: latitude, longitude: longitude)
        else {
            return nil
        }

        // Second pass at the actual moment, so the Julian century matches
        // sunrise/sunset rather than midnight (NOAA `calcSunriseSet`).
        let sunriseMinutes = sunriseSetUTC(
            rise: true,
            julianDay: jd + sunriseFirst / 1440,
            latitude: latitude,
            longitude: longitude
        ) ?? sunriseFirst
        let sunsetMinutes = sunriseSetUTC(
            rise: false,
            julianDay: jd + sunsetFirst / 1440,
            latitude: latitude,
            longitude: longitude
        ) ?? sunsetFirst

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone.gmt
        var midnightComponents = DateComponents()
        midnightComponents.year = year
        midnightComponents.month = month
        midnightComponents.day = day
        midnightComponents.hour = 0
        midnightComponents.minute = 0
        midnightComponents.second = 0
        guard let midnightUTC = utcCalendar.date(from: midnightComponents) else { return nil }

        let sunrise = midnightUTC.addingTimeInterval(sunriseMinutes * 60)
        let sunset = midnightUTC.addingTimeInterval(sunsetMinutes * 60)
        guard sunrise < sunset else { return nil }
        return (sunrise, sunset)
    }

    // MARK: - NOAA primitives

    /// Julian Day number at 00:00 UTC for the given Gregorian date.
    /// Meeus / NOAA: `floor(365.25(y+4716)) + floor(30.6001(m+1)) + d + B - 1524.5`.
    private static func julianDay(year: Int, month: Int, day: Double) -> Double {
        var y = year
        var m = month
        if m <= 2 {
            y -= 1
            m += 12
        }
        let a = y / 100
        let b = 2 - a + a / 4
        return Foundation.floor(365.25 * Double(y + 4716))
            + Foundation.floor(30.6001 * Double(m + 1))
            + day
            + Double(b)
            - 1524.5
    }

    /// Julian centuries from J2000.0 (`T` in the NOAA spreadsheet).
    private static func julianCentury(_ jd: Double) -> Double {
        (jd - 2_451_545.0) / 36_525.0
    }

    /// Geometric mean longitude of the sun, deg, wrapped to 0...360 (`L0`).
    private static func geomMeanLongSun(t: Double) -> Double {
        var l0 = 280.46646 + t * (36_000.76983 + t * 0.0003032)
        l0 = l0.truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        return l0
    }

    /// Geometric mean anomaly of the sun, deg (`M`).
    private static func geomMeanAnomalySun(t: Double) -> Double {
        357.52911 + t * (35_999.05029 - 0.0001537 * t)
    }

    /// Earth orbit eccentricity (`e`).
    private static func eccentricityEarthOrbit(t: Double) -> Double {
        0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    }

    /// Equation of center, deg (`C`).
    private static func sunEqOfCenter(t: Double) -> Double {
        let m = radians(geomMeanAnomalySun(t: t))
        return sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289
    }

    /// Apparent longitude of the sun, deg (`λ`), with nutation in longitude.
    private static func sunApparentLong(t: Double) -> Double {
        let trueLong = geomMeanLongSun(t: t) + sunEqOfCenter(t: t)
        let omega = 125.04 - 1934.136 * t
        return trueLong - 0.00569 - 0.00478 * sin(radians(omega))
    }

    /// Mean obliquity of the ecliptic, deg (`ε0`).
    private static func meanObliquityOfEcliptic(t: Double) -> Double {
        let seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
        return 23.0 + (26.0 + (seconds / 60.0)) / 60.0
    }

    /// True obliquity, deg (`ε`), with nutation in obliquity.
    private static func obliquityCorrection(t: Double) -> Double {
        let e0 = meanObliquityOfEcliptic(t: t)
        let omega = 125.04 - 1934.136 * t
        return e0 + 0.00256 * cos(radians(omega))
    }

    /// Solar declination, deg (`δ`). `sin δ = sin ε · sin λ`.
    private static func sunDeclination(t: Double) -> Double {
        let e = obliquityCorrection(t: t)
        let lambda = sunApparentLong(t: t)
        return degrees(asin(sin(radians(e)) * sin(radians(lambda))))
    }

    /// Equation of time, minutes (`EqT`). Difference between apparent solar time and mean solar time.
    private static func equationOfTime(t: Double) -> Double {
        let epsilon = obliquityCorrection(t: t)
        let l0 = geomMeanLongSun(t: t)
        let e = eccentricityEarthOrbit(t: t)
        let m = geomMeanAnomalySun(t: t)
        // y = tan²(ε/2), from the spherical-astronomy expansion of the EoT.
        let y = pow(tan(radians(epsilon) / 2.0), 2)
        let sin2l0 = sin(2 * radians(l0))
        let sinM = sin(radians(m))
        let cos2l0 = cos(2 * radians(l0))
        let sin4l0 = sin(4 * radians(l0))
        let sin2m = sin(2 * radians(m))
        let eTime = y * sin2l0
            - 2 * e * sinM
            + 4 * e * y * sinM * cos2l0
            - 0.5 * y * y * sin4l0
            - 1.25 * e * e * sin2m
        return degrees(eTime) * 4.0
    }

    /// Sunrise (or sunset, if `rise` is false) as minutes from 00:00 UTC.
    ///
    /// `H` is the hour angle at the 90.833° zenith:
    /// `cos H = (cos ζ − sin φ sin δ) / (cos φ cos δ)`.
    /// Solar noon in minutes: `720 − 4·(lon + H°) − EqT`.
    private static func sunriseSetUTC(
        rise: Bool,
        julianDay jd: Double,
        latitude: Double,
        longitude: Double
    ) -> Double? {
        let t = julianCentury(jd)
        let eqTime = equationOfTime(t: t)
        let declination = sunDeclination(t: t)
        guard var hourAngle = hourAngleSunrise(latitude: latitude, declination: declination) else {
            return nil
        }
        if !rise { hourAngle = -hourAngle }
        let delta = longitude + degrees(hourAngle)
        let timeUTC = 720 - (4.0 * delta) - eqTime
        guard timeUTC.isFinite else { return nil }
        return timeUTC
    }

    /// Hour angle at sunrise, radians. `nil` when the sun stays above/below the horizon.
    private static func hourAngleSunrise(latitude: Double, declination: Double) -> Double? {
        let lat = radians(latitude)
        let dec = radians(declination)
        let zenith = radians(zenithDegrees)
        let cosHA = cos(zenith) / (cos(lat) * cos(dec)) - tan(lat) * tan(dec)
        guard cosHA.isFinite, cosHA >= -1, cosHA <= 1 else { return nil }
        return acos(cosHA)
    }

    private static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
    private static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
}
