# Mind's Eye authoring toolchain

Run `Gravitas Plague/Scripts/bootstrap_mind_eye_lipsync.sh`. The bootstrap uses
an isolated repository-local micromamba prefix and Python virtual environment,
verifies every required version/model, and atomically regenerates the committed
locks. Never install this stack into system Python or a user's base conda
environment.
