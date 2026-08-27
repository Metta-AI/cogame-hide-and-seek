## 17. The five borrowed upstream facts. A shipped constant edited without
## editing its citation fails here.

import std/strutils
import helpers
import hns/[sim_types, upstream]

block everyFactIsTranscribed:
  check UpstreamFacts.len == 5, "the upstream table lost a row"
  for fact in UpstreamFacts:
    check fact.id.len > 0, "an upstream fact has no id"
    check fact.claim.len > 40, "upstream fact " & fact.id & " has no claim"
    check fact.landing.len > 20, "upstream fact " & fact.id & " has no landing"
    check "Baker et al. 2019" in fact.citation,
      "upstream fact " & fact.id & " is not cited to Baker et al. 2019"

block twoPhaseEpisode:
  let fact = upstreamFact("two-phase-episode")
  check UpstreamPrepPhaseFrozenSeekers,
    "the prep phase no longer freezes the seekers: " & fact.claim
  var config = defaultGameConfig()
  check config.prepTurns > 0,
    "the shipped default has no preparation phase at all"
  check config.huntTurns > 0, "the shipped default has no hunt phase"

block teamRewardPerTick:
  let fact = upstreamFact("team-reward-per-timestep")
  check UpstreamRewardPerTick == 1,
    "the per-timestep reward is no longer +/-1: " & fact.claim
  check UpstreamRewardIsTeamWide,
    "the reward is no longer team-wide: " & fact.claim
  # +/-1 per tick, team-wide, means an all-unseen game is exactly +1000
  # permille and an all-seen game exactly -1000.
  check marginPermille(720, 0, 720) == 1000, "an all-unseen game is not +1"
  check marginPermille(0, 720, 720) == -1000, "an all-seen game is not -1"

block lineOfSightCone:
  let fact = upstreamFact("line-of-sight-cone")
  check UpstreamVisionIsCone, "vision is no longer a cone: " & fact.claim
  check UpstreamVisionConeHalfDeg == VisionConeDeg,
    "the upstream table and sim_types disagree about the cone half-angle"
  check VisionConeDeg > 0 and VisionConeDeg < 90,
    "the cone half-angle left the range a cone can have"
  check SightRange > 0, "the cone has no range"

block objectsMovableAndLockable:
  let fact = upstreamFact("objects-movable-and-lockable")
  check UpstreamLockIsTeamExclusive,
    "the lock is no longer team-exclusive: " & fact.claim
  check UpstreamLockOwners == 3,
    "lockedBy is no longer none/hiders/seekers"
  check ord(high(LockOwner)) + 1 == UpstreamLockOwners,
    "the LockOwner enum and the upstream table disagree"

block rampsCrossBarriers:
  let fact = upstreamFact("ramps-cross-barriers")
  check UpstreamRampsCrossBarriers,
    "ramps no longer cross barriers: " & fact.claim
  check UpstreamVaultSpanPx == VaultSpanPx,
    "the upstream table and sim_types disagree about vaultSpanPx"
  check VaultSpanPx > 0, "a ramp can no longer carry a cog over anything"

block boxSurfingIsNotClaimed:
  for fact in UpstreamFacts:
    check "surf" notin fact.claim.toLowerAscii(),
      "box surfing is out of scope; it must not be claimed as reproduced"

echo "test_hns_upstream: ok"
