import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from slo import (  # noqa: E402
    BUCKETS_MS,
    Incident,
    Probe,
    availability,
    burn_rate,
    count_minutes,
    find_incidents,
    histogram,
    merge_histograms,
    minute_status,
    mtbf_hours,
    mttr_minutes,
    percentile,
    percentile_from_histogram,
)

T0 = 1_700_000_000 - 1_700_000_000 % 60  # minute-aligned


def probes(minute: int, results: dict[str, bool]) -> list[Probe]:
    return [Probe(T0 + minute * 60 + 5, region, ok, 100.0) for region, ok in results.items()]


class MinuteStatusTest(unittest.TestCase):
    def test_majority_failure_is_bad(self):
        status = minute_status(probes(0, {"eu": False, "us": False, "ap": True}))
        self.assertEqual(status, {T0: True})

    def test_single_region_failure_is_not_bad(self):
        status = minute_status(probes(0, {"eu": False, "us": True, "ap": True}))
        self.assertEqual(status, {T0: False})

    def test_one_of_two_is_not_majority(self):
        status = minute_status(probes(0, {"eu": False, "us": True}))
        self.assertEqual(status, {T0: False})

    def test_minute_with_one_region_is_not_evaluated(self):
        self.assertEqual(minute_status(probes(0, {"eu": False})), {})


class BudgetTest(unittest.TestCase):
    def test_availability_and_burn_rate(self):
        status = {T0 + i * 60: i < 2 for i in range(1000)}  # 2 bad of 1000
        evaluated, bad = count_minutes(status, T0, T0 + 1000 * 60)
        self.assertEqual((evaluated, bad), (1000, 2))
        self.assertAlmostEqual(availability(evaluated, bad), 0.998)
        # 0.2% errors against a 0.1% allowance burns twice as fast as sustainable
        self.assertAlmostEqual(burn_rate(evaluated, bad, 0.999), 2.0)

    def test_count_minutes_respects_window(self):
        status = {T0: True, T0 + 60: False, T0 + 120: True}
        self.assertEqual(count_minutes(status, T0 + 60, T0 + 180), (2, 1))

    def test_no_data(self):
        self.assertIsNone(availability(0, 0))
        self.assertIsNone(burn_rate(0, 0, 0.999))


class LatencyTest(unittest.TestCase):
    def test_histogram_bucket_bounds_are_inclusive(self):
        h = histogram([25, 26, 10_001])
        self.assertEqual(h[0], 1)
        self.assertEqual(h[1], 1)
        self.assertEqual(h[-1], 1)
        self.assertEqual(len(h), len(BUCKETS_MS) + 1)

    def test_percentile_from_histogram_interpolates(self):
        h = histogram([60] * 100)  # all in (50, 75]
        self.assertAlmostEqual(percentile_from_histogram(h, 0.5), 62.5)
        self.assertAlmostEqual(percentile_from_histogram(h, 1.0), 75.0)

    def test_merge_histograms(self):
        merged = merge_histograms([histogram([10]), histogram([10, 60])])
        self.assertEqual(merged[0], 2)
        self.assertEqual(merged[2], 1)

    def test_exact_percentile_nearest_rank(self):
        values = list(range(1, 101))
        self.assertEqual(percentile(values, 0.95), 95)
        self.assertEqual(percentile(values, 0.5), 50)
        self.assertIsNone(percentile([], 0.5))

    def test_empty_histogram(self):
        self.assertIsNone(percentile_from_histogram([0] * (len(BUCKETS_MS) + 1), 0.95))


class IncidentTest(unittest.TestCase):
    def test_incident_ends_after_sustained_recovery(self):
        pattern = [False, True, True, False, True, False, False, False]
        status = {T0 + i * 60: bad for i, bad in enumerate(pattern)}
        self.assertEqual(find_incidents(status), [Incident(T0 + 60, T0 + 5 * 60)])

    def test_ongoing_incident_has_no_end(self):
        status = {T0: False, T0 + 60: True}
        self.assertEqual(find_incidents(status), [Incident(T0 + 60, None)])

    def test_two_separate_incidents(self):
        pattern = [True, False, False, True, False, False]
        status = {T0 + i * 60: bad for i, bad in enumerate(pattern)}
        self.assertEqual(len(find_incidents(status)), 2)

    def test_mttr_and_mtbf(self):
        incidents = [Incident(T0, T0 + 600), Incident(T0 + 3600, T0 + 3600 + 1200)]
        self.assertAlmostEqual(mttr_minutes(incidents), 15.0)
        window = 30 * 86400
        self.assertAlmostEqual(mtbf_hours(incidents, window, T0), (window - 1800) / 2 / 3600)
        self.assertIsNone(mttr_minutes([Incident(T0, None)]))
        self.assertIsNone(mtbf_hours([], window, T0))


if __name__ == "__main__":
    unittest.main()
