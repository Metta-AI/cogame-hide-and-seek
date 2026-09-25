## Every test in one binary, for a local `nim c -r tests/tests.nim` from the
## repo ROOT. CI runs each file separately, in debug AND release.

import
  test_hns_sim,
  test_hns_room,
  test_hns_upstream,
  test_hns_seeding,
  test_hns_determinism,
  test_hns_vision,
  test_hns_control,
  test_hns_external,
  test_hns_events,
  test_hns_engine,
  test_hns_replay,
  test_hns_manifest,
  test_hns_viewer,
  test_hns_endcard_labels,
  test_hns_renderer_fixture

echo "all tests: ok"
