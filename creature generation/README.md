# Xenobiology — Cuboid Creature Lab

Open `index.html` in a modern WebGL browser. Internet required for pinned Three.js
0.170.0 CDN imports. If local-file modules are restricted:

```sh
python3 -m http.server 8080 --directory "creature generation"
```

Open http://localhost:8080. No build step or voxel-engine changes.

## Controls

- **Random creature / Space:** search for a visually distinct genome.
- **Body plan:** constrain the broad locomotion family.
- **Genome + Grow:** reproduce that genome with the selected family.
- **Silhouette:** inspect primary shape without color or surface markings.
- Drag to orbit; scroll/pinch to zoom; toggle auto orbit.
- Bookmark the URL fragment to retain genome and family.

## Linked anatomy

Ecology and locomotion are sampled first. Cuboid masses and a weighted longitudinal
center-of-mass proxy determine supporting feet, neck reinforcement and tail size.
Large skulls shorten/thicken necks and enlarge counterweight tails. Tailless bodies
shorten and widen. Heavy land builds override agile stances with pillar legs.
Front/rear focal bodies target a 70:30 split between the two main torso masses;
this excludes appendages and overlapping volume, not a physical volume guarantee.

Spring-jointed runners, columnar heavy builds, low sprawling bodies, knuckle walkers,
stilt walkers and buoyant forms break the shared silhouette. Front/rear loading
changes which legs carry enlarged muscles. One foot advances, head cocks, and
asymmetric tusk wear / crushing claws / flank scars break rigid symmetry.

Skull ancestry (cetacean, mantis, tapir, ray, reptile) is independent of locomotion.
Feeding role then determines functional anatomy:

- Predators: forward eyes, broad gape, jaw muscles and teeth.
- Browsers: lateral eyes, raised carriage, grinding plates.
- Detritivores: reduced side eyes, underslung mouths, barbels and dorsal armor.

Desert cooling sails, wetland throat sacs, reef rib spiracles, highland mantles and
buoyant air sacs express ecology. One defense system and one physiological system
replace blanket decorative spikes. Sparse low-contrast 16×16 skin markings and
localized wear preserve the primary/secondary/detail hierarchy. All parts remain
cuboids; tiled wings are instanced and base box geometry is shared.

These are art-direction constraints and approximate mass/leverage calculations,
not validated biomechanics, gravity simulation or an evolutionary biology model.
The displayed mass is a design proxy, not a physical measurement.

## Diversity archive

A MAP-Elites-inspired local archive stores at most 160 descriptor niches, using
body aspect, clearance, head fraction, focal zone, tail length, skull aspect,
leg count, limb spread and tail thickness. Niche occupants retain the higher
heuristic anatomy-quality score. Random evaluates up to 36 cheap genomes before
building one mesh; it prioritizes empty niches and distance from archived shapes.
If no sufficiently novel candidate is found, it takes the most novel candidate
within that fixed budget. This is not a full evolutionary MAP-Elites search or
rendered-silhouette comparison, and cannot guarantee every creature is unique.

Archive persists in browser localStorage when available; denied storage falls back
to memory. Explicit seeds bypass novelty selection and stay deterministic. Version
3 anatomy intentionally changes older seeds' appearances. Materials, skin textures
and wing instance buffers are disposed when replacing creatures. Pixel ratio caps
at 1.75. No external models, images or extra libraries.

## Fauna families (version 3)

Eleven selectable families now include five distinct construction systems:

- **Beaked bipeds:** two planted legs, hooked/spear/scoop beaks, feathered side wings,
  grasping toes, crest and tail fan; strider, raptor and wader labels.
- **Dragons / wyverns:** four- or two-leg stance, long reinforced neck, paired horn
  crowns, cheek fins, dorsal plates, ribbed wing membranes and toothed jaws.
- **Tentacled walkers:** tall mantle, eight multi-segment arms, suckers, siphon,
  conspicuous side eyes and central beak. Arms support the silhouette near ground.
- **Land leviathans:** massive elongated trunk, heavy legs, blunt cetacean skull,
  flank folds and dorsal breathing aperture.
- **Mantis hunters:** upright narrow frame, paired folding raptorial arms with
  gripping spines, antennae and large eyes.

Existing grazers, runners, crawlers, amphibians, gliders and floaters remain.
All families share a redesigned face system: projecting muzzle or beak, separated
upper/lower jaws, dark mouth cavity, tongue, nostrils, jaw muscles, feeding-specific
teeth or grinding plates, and slow jaw articulation. Eyes use dark sockets, pale
sclera, colored irises, pupils, highlights and brows. Detail remains cuboid.

Archive niches now include family and variant. Random discourages repeating the
currently displayed family when Surprise me is selected. New visitors start with
a dragon; select Surprise me to explore all families. Seeded bookmarks still work,
but version 3 changes earlier anatomy. Syntax checked; visual review remains manual.
