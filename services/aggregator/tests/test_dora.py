import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dora import DAY, HOUR, Deployment, caused_incident, dora, lead_time_level  # noqa: E402
from slo import Incident  # noqa: E402

T0 = 1_700_000_000
WINDOW = 30 * DAY


def deploy(at: int, lead_h: float = 1, ok: bool = True) -> Deployment:
    return Deployment(deployed_at=at, commit_at=at - int(lead_h * HOUR), ok=ok, kind="site")


class DoraTest(unittest.TestCase):
    def test_daily_deploys_are_elite_frequency(self):
        result = dora([deploy(T0 + i * DAY) for i in range(30)], [], None, WINDOW)
        self.assertEqual(result["deployments"], 30)
        self.assertEqual(result["deploys_per_week"], 7.0)
        self.assertEqual(result["deploy_frequency_level"], "elite")

    def test_weekly_deploys_are_high_frequency(self):
        result = dora([deploy(T0 + i * 7 * DAY) for i in range(5)], [], None, WINDOW)
        self.assertEqual(result["deploy_frequency_level"], "high")

    def test_lead_time_is_median(self):
        result = dora([deploy(T0, 1), deploy(T0 + DAY, 3), deploy(T0 + 2 * DAY, 100)], [], None, WINDOW)
        self.assertEqual(result["lead_time_h"], 3)
        self.assertEqual(result["lead_time_level"], "elite")
        self.assertEqual(lead_time_level(2 * DAY), "high")

    def test_change_failure_counts_failed_jobs_and_incidents(self):
        deploys = [deploy(T0), deploy(T0 + DAY, ok=False), deploy(T0 + 2 * DAY), deploy(T0 + 3 * DAY)]
        incidents = [Incident(T0 + 2 * DAY + 600, T0 + 2 * DAY + 1200)]  # 10 min after the 3rd deploy
        result = dora(deploys, incidents, 600, WINDOW)
        self.assertEqual(result["change_failure_rate"], 0.5)
        self.assertEqual(result["change_failure_rate_level"], "low")
        self.assertEqual(result["deployments"], 3)
        self.assertEqual(result["time_to_restore_min"], 10)
        self.assertEqual(result["time_to_restore_level"], "elite")

    def test_incident_long_after_deploy_is_not_attributed(self):
        self.assertFalse(caused_incident(deploy(T0), [Incident(T0 + 2 * HOUR, None)]))

    def test_no_deployments(self):
        result = dora([], [], None, WINDOW)
        self.assertIsNone(result["change_failure_rate"])
        self.assertIsNone(result["lead_time_h"])
        self.assertIsNone(result["deploy_frequency_level"])


if __name__ == "__main__":
    unittest.main()
