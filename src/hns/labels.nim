## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and anything that reads the wire. A label is
## not a debug tag: it is the observation schema, and renaming one is a
## breaking change to every consumer.
##
## The failure mode this module exists to prevent is SILENT: labels are
## computed at render time and never serialized, nothing type-checks a label
## string, and a lookup for a name that no longer exists simply returns
## nothing. Hoisting the strings to consts makes producer and consumer share
## one definition, and `tests/test_hns_labels.nim` guards the rest against
## `tests/label_manifest.txt`.
##
## Renaming anything here is a three-surface change in one commit: this
## module, `tests/label_manifest.txt`, and `docs/RULES.md`.
##
## This module must keep ZERO imports.

const
  LabelCog* = "cog"
    ## One cog body, drawn in its role kit and turned to its aim.
  LabelCrate* = "crate"
  LabelPanel* = "panel"
  LabelRamp* = "ramp"
  LabelLockedCrate* = "locked crate"
  LabelLockedPanel* = "locked panel"
  LabelLockedRamp* = "locked ramp"
    ## An object the padlock overlay is drawn on: the LOCK STATE is part of
    ## the label, because a spectator and a reader both need it and the
    ## outline colour alone is not machine-readable.
  LabelPadlock* = "padlock"
  LabelVisionCone* = "vision cone"
    ## One cog's torch beam, drawn as a translucent wedge.
  LabelTether* = "carry tether"
    ## The line from a dragging cog to the thing it holds.
  LabelVaultArc* = "vault arc"
  LabelShoutBubble* = "shout bubble"
  LabelMapBand* = "map band"
  LabelBroadcastChrome* = "broadcast chrome"
  LabelSpottedRing* = "spotted ring"
    ## The red ring a hider wears while a cone is on it.

  LabelAimPrefix* = "own aim "
    ## `own aim <brads>` — the readback marker the Sprite v1 protocol section
    ## of docs/PROTOCOL.md documents, kept verbatim from the starter.

const LabelVocabulary*: array[15, string] = [
  LabelCog, LabelCrate, LabelPanel, LabelRamp,
  LabelLockedCrate, LabelLockedPanel, LabelLockedRamp, LabelPadlock,
  LabelVisionCone, LabelTether, LabelVaultArc, LabelShoutBubble,
  LabelMapBand, LabelBroadcastChrome, LabelSpottedRing
]
  ## The whole emitted contract vocabulary. `tests/label_manifest.txt` is the
  ## golden copy; the test regenerates nothing, it only compares.
