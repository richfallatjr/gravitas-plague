# Mind's Eye manual mouth-frame overrides

Optional owner-reviewed overrides are named `<pr-id>.json`. Each operation uses
`startFrame`, `endFrameExclusive`, one of `rest/small/wide/round/teeth`, and a
nonempty `reason`. Operations must be sorted, in range, and nonoverlapping.
The compiler never creates overrides automatically.
