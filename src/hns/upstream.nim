## The five facts this game borrows from Baker et al. 2019, *Emergent Tool Use
## From Multi-Agent Autocurricula* (github.com/openai/multi-agent-emergence-
## environments), each transcribed with its citation beside it.
##
## This is a RULES-IDIOM reimplementation, not a port: MuJoCo's physics, the
## 3-D geometry, the RL observation vectors and box surfing are not
## reproduced (`docs/RULES.md` §Divergences). What IS reproduced is the five
## constants below, and `tests/test_hns_upstream.nim` asserts the shipped
## engine still matches them. Editing a constant here without editing its
## citation fails that test.

import sim_types

type
  UpstreamFact* = object
    id*: string
    claim*: string      ## what upstream does.
    landing*: string    ## how it lands in this repo.
    citation*: string   ## where upstream says it.

const UpstreamFacts*: array[5, UpstreamFact] = [
  UpstreamFact(
    id: "two-phase-episode",
    claim: "The episode opens with a PREPARATION PHASE during which the " &
      "seekers are immobilised and cannot observe; the hiders have the " &
      "environment to themselves.",
    landing: "prepTurns turns of frozen, unobserving seekers; the seekers " &
      "are released at tick == prepTicks and scoring starts on the first " &
      "hunt tick.",
    citation: "Baker et al. 2019, sec. 3 (Hide and Seek): 'hiders are " &
      "given a preparation phase ... during which seekers are immobilized'."
  ),
  UpstreamFact(
    id: "team-reward-per-timestep",
    claim: "The reward is +/-1 PER TIMESTEP and TEAM-BASED: hiders get +1 " &
      "if ALL hiders are hidden from all seekers and -1 otherwise; the " &
      "seekers get the negation.",
    landing: "hiddenTicks / seenTicks accumulated over the hunt phase and " &
      "turned into a zero-sum permille margin from the hiding trio's view.",
    citation: "Baker et al. 2019, sec. 3: 'Hiders are given a reward of 1 " &
      "if all hiders are hidden and -1 if any hider is seen ... Seekers " &
      "are given the opposite reward'."
  ),
  UpstreamFact(
    id: "line-of-sight-cone",
    claim: "Visibility is a LINE-OF-SIGHT CONE with a limited range, " &
      "blocked by objects.",
    landing: "the starter's recursive shadowcast plus applyFovCone, " &
      "retargeted to visionConeDeg / sightRange / visionBubble; boxes are " &
      "opaque AND dynamic.",
    citation: "Baker et al. 2019, sec. 3: agents 'observe ... objects " &
      "within a 135 degree cone in front of them and within a fixed range', " &
      "with line of sight blocked by objects."
  ),
  UpstreamFact(
    id: "objects-movable-and-lockable",
    claim: "Boxes and ramps are MOVABLE and LOCKABLE; a locked object can " &
      "only be unlocked by the team that locked it.",
    landing: "grab on button C, lock on button A, lockedBy in " &
      "{none, hiders, seekers}; the other team's grab, push and unlock are " &
      "refused.",
    citation: "Baker et al. 2019, sec. 3: agents 'can lock objects in " &
      "place, which can only be unlocked by agents on the team that " &
      "locked them'."
  ),
  UpstreamFact(
    id: "ramps-cross-barriers",
    claim: "RAMPS let an agent cross a barrier it otherwise could not, and " &
      "the hiders' counter is to lock the ramps away.",
    landing: "the vault rule: a cog running up a ramp with a barrier at " &
      "most vaultSpanPx thick beyond its head goes airborne and crosses.",
    citation: "Baker et al. 2019, sec. 4 (emergent strategies): seekers " &
      "'learn to use a ramp to jump over the walls of the shelter', after " &
      "which hiders 'learn to move the ramps ... and lock them in place'."
  )
]

const
  UpstreamPrepPhaseFrozenSeekers* = true
  UpstreamRewardPerTick* = 1
  UpstreamRewardIsTeamWide* = true
  UpstreamVisionIsCone* = true
  UpstreamLockIsTeamExclusive* = true
  UpstreamRampsCrossBarriers* = true

  ## The shipped engine values the facts above pin. Kept here so a change to
  ## sim_types.nim that contradicts an upstream claim fails a test instead of
  ## silently rewriting what this coworld says it reproduces.
  UpstreamVisionConeHalfDeg* = VisionConeDeg
  UpstreamVaultSpanPx* = VaultSpanPx
  UpstreamLockOwners* = 3       ## none / hiders / seekers.

proc upstreamFact*(id: string): UpstreamFact =
  for fact in UpstreamFacts:
    if fact.id == id:
      return fact
  raise newException(HnsError, "unknown upstream fact: " & id)
