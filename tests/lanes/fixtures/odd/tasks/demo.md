# demo — lanes fixture

Objective: exercise every route the lanes autopilot handles.
Runner: `test -d src`

## Specs

- **S1** User (verbatim): "a must hold a marker per task"
  Derived: one file per task under src/a.
- **S2** User (verbatim): "b must hold a marker per task"
- S3 High-risk data rule (verbatim): "c is data; verify it independently"

## Tasks

- [ ] T1 S1 Marker in a (route: write; risk: low; In: src/a; commit: pending)
- [ ] T2 S2 Marker in b (route: write; risk: low; In: src/b; commit: pending)
- [ ] T3 S3 Data marker in c (route: inline; risk: high(data); In: src/c; after: T1; commit: pending)

## Log

- L1 User request (verbatim): "build the demo"
